import Foundation

/// Line-delimited JSON bridge to a transcription sidecar process.
///
/// Requests  (stdin):  {"cmd":"transcribe","id":"<uuid>","audio_path":"/tmp/x.wav"}\n
/// Responses (stdout):
///   {"type":"status","state":"loading|ready|error", ...}
///   {"type":"transcription","id":"<uuid>","text":"..."}
///   {"type":"error","id":"<uuid>","error":"..."}
///
/// The sidecar is expected to run VibeVoice-ASR (see PythonSidecar/transcribe.py).
/// Swapping in a Rust/whisper.cpp sidecar is a drop-in replacement as long as the
/// JSON protocol is preserved.
///
/// Marked `@unchecked Sendable`: all mutable state is touched only from `queue`.
final class TranscriptionService: @unchecked Sendable {
    enum ServiceError: Error, LocalizedError {
        case notLaunched
        case sidecarFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .notLaunched: return "Transcription sidecar not running"
            case .sidecarFailed(let msg): return msg
            case .timeout: return "Transcription timed out"
            }
        }
    }

    struct Result {
        let text: String
        /// Whisper's acoustic guess at the language (separate probe, not the
        /// pinned language). May be nil if detection failed.
        let detectedLanguage: String?
    }

    var onStatusChange: ((String) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "com.libman.macvibe.transcription", qos: .userInitiated)

    private var pending: [String: CheckedContinuation<Result, Error>] = [:]
    private var isReady = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    /// `modelPath` is resolved by `ModelManager` (bundled copy, or the one
    /// downloaded on first launch) and handed to the sidecar explicitly rather
    /// than left to its own filesystem search.
    func launch(modelPath: URL) {
        queue.async { [weak self] in self?.launchInternal(modelPath: modelPath) }
    }

    private func launchInternal(modelPath: URL) {
        guard process == nil else { return }

        // Bundled at <App>/Contents/MacOS/macvibe-asr — helper executables
        // must live under Contents/MacOS to satisfy code-signing and
        // notarization. For dev runs against the source tree, fall back to the
        // cargo build directory.
        let sidecarBin: URL = {
            if let bundled = Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("macvibe-asr"),
               FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
            let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("RustSidecar/target/release/macvibe-asr")
            return dev
        }()

        guard FileManager.default.isExecutableFile(atPath: sidecarBin.path) else {
            NSLog("TranscriptionService: sidecar binary missing at \(sidecarBin.path)")
            onStatusChange?("sidecar missing")
            return
        }

        let proc = Process()
        proc.executableURL = sidecarBin
        proc.arguments = []

        var env = ProcessInfo.processInfo.environment
        env["MACVIBE_MODEL_PATH"] = modelPath.path
        // GGML_METAL_PATH_RESOURCES helps whisper.cpp locate Metal shaders if
        // it's bundled in a non-default layout.
        if let resources = Bundle.main.resourceURL {
            env["GGML_METAL_PATH_RESOURCES"] = resources.path
        }
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consumeStdout(data) }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                NSLog("sidecar: %@", String(line))
            }
        }

        proc.terminationHandler = { [weak self] _ in
            self?.queue.async {
                self?.failAllPending(ServiceError.sidecarFailed("sidecar exited"))
                self?.process = nil
                self?.stdinHandle = nil
                self?.isReady = false
                self?.onStatusChange?("sidecar exited")
            }
        }

        do {
            try proc.run()
            process = proc
            stdinHandle = inPipe.fileHandleForWriting
            onStatusChange?("loading model…")
        } catch {
            NSLog("TranscriptionService: failed to launch sidecar: \(error)")
            onStatusChange?("sidecar failed to launch")
        }
    }

    private func consumeStdout(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            handleMessage(obj)
        }
    }

    private func handleMessage(_ obj: [String: Any]) {
        let type = obj["type"] as? String ?? ""

        switch type {
        case "status":
            let state = obj["state"] as? String ?? ""
            onStatusChange?(state)
            if state == "ready" {
                isReady = true
                let waiters = readyWaiters
                readyWaiters = []
                for w in waiters { w.resume() }
            } else if state == "error" {
                let msg = obj["error"] as? String ?? "sidecar init failed"
                let waiters = readyWaiters
                readyWaiters = []
                for w in waiters { w.resume(throwing: ServiceError.sidecarFailed(msg)) }
            }

        case "transcription":
            guard let id = obj["id"] as? String else { return }
            let cont = pending.removeValue(forKey: id)
            if let text = obj["text"] as? String {
                let detected = obj["detected_language"] as? String
                cont?.resume(returning: Result(text: text, detectedLanguage: detected))
            } else {
                cont?.resume(throwing: ServiceError.sidecarFailed("missing text"))
            }

        case "error":
            let msg = obj["error"] as? String ?? "unknown sidecar error"
            if let id = obj["id"] as? String, let cont = pending.removeValue(forKey: id) {
                cont.resume(throwing: ServiceError.sidecarFailed(msg))
            } else {
                NSLog("sidecar error (unbound): %@", msg)
            }

        default:
            break
        }
    }

    private func failAllPending(_ error: Error) {
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        for w in readyWaiters { w.resume(throwing: error) }
        readyWaiters.removeAll()
    }

    func waitReady(timeout: TimeInterval = 120) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if self.isReady { cont.resume(); return }
                if self.process == nil {
                    cont.resume(throwing: ServiceError.notLaunched)
                    return
                }
                self.readyWaiters.append(cont)
            }
        }
    }

    func transcribe(audioURL: URL) async throws -> Result {
        try await waitReady()
        let id = UUID().uuidString
        var payload: [String: Any] = [
            "cmd": "transcribe",
            "id": id,
            "audio_path": audioURL.path
        ]
        let hotwords = Hotwords.current()
        if !hotwords.isEmpty {
            payload["hotwords"] = hotwords
        }
        // Always include language; "auto" tells the sidecar to let Whisper
        // detect on a per-utterance basis.
        payload["language"] = Prefs.language
        let data = try JSONSerialization.data(withJSONObject: payload)

        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard let handle = self.stdinHandle else {
                    cont.resume(throwing: ServiceError.notLaunched)
                    return
                }
                self.pending[id] = cont
                do {
                    try handle.write(contentsOf: data)
                    try handle.write(contentsOf: Data([0x0A]))
                } catch {
                    self.pending.removeValue(forKey: id)
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let handle = self.stdinHandle {
                let bye = try? JSONSerialization.data(withJSONObject: ["cmd": "shutdown"])
                if let bye = bye {
                    try? handle.write(contentsOf: bye)
                    try? handle.write(contentsOf: Data([0x0A]))
                }
            }
            self.process?.terminate()
        }
    }
}
