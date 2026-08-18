import CryptoKit
import Foundation

/// Locates — and on first launch, downloads — the whisper weights the ASR
/// sidecar runs on.
///
/// The model is ~1.6 GB. Bundling it would make every release *and every
/// auto-update* a 1.6 GB download, so the shipped app carries only code and
/// fetches the weights once into Application Support. Dev builds that embed
/// the model (`EMBED_MODEL=1 ./build.sh`) are still honoured — the bundled
/// copy wins and nothing is downloaded.
enum ModelManager {
    /// The model we ship against. `sha256` is the HuggingFace LFS object id,
    /// which lets us verify a 1.6 GB download rather than trusting that the
    /// transfer completed intact.
    struct Spec: Sendable {
        let fileName: String
        let sha256: String
        let byteCount: Int64

        var remoteURL: URL {
            URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
        }
    }

    static let spec = Spec(
        fileName: "ggml-large-v3-turbo.bin",
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        byteCount: 1_624_555_275
    )

    enum ModelError: Error, LocalizedError {
        case checksumMismatch(expected: String, actual: String)
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch:
                return "Downloaded model failed its integrity check"
            case .httpStatus(let code):
                return "Model download failed (HTTP \(code))"
            }
        }
    }

    /// `~/Library/Application Support/MacVibe/models/`.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacVibe/models", isDirectory: true)
    }

    static var installedURL: URL {
        supportDirectory.appendingPathComponent(spec.fileName)
    }

    /// A model embedded in the bundle by `EMBED_MODEL=1 ./build.sh`, or the
    /// dev symlink into `RustSidecar/models`. Any `ggml-*.bin` counts — a dev
    /// who downloaded `ggml-base.en.bin` shouldn't be forced into the 1.6 GB
    /// fetch.
    static var bundledURL: URL? {
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("asr-sidecar/models", isDirectory: true),
            let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { return nil }
        guard let match = names
            .filter({ $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") })
            .sorted()
            .first
        else { return nil }
        return dir.appendingPathComponent(match)
    }

    /// Returns a usable model path, downloading it if this is the first run.
    /// `onProgress` receives 0…1 and fires only while downloading.
    static func ensureAvailable(
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        if let bundled = bundledURL, FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let installed = installedURL
        if FileManager.default.fileExists(atPath: installed.path) {
            return installed
        }

        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

        NSLog("ModelManager: downloading %@ (%.1f GB)", spec.fileName, Double(spec.byteCount) / 1e9)
        let downloaded = try await Downloader(spec: spec, onProgress: onProgress).run()

        // Verify before we install. A truncated or tampered file would
        // otherwise sit in Application Support and fail confusingly at load
        // time on every subsequent launch.
        let digest = try sha256(of: downloaded)
        guard digest == spec.sha256 else {
            try? FileManager.default.removeItem(at: downloaded)
            throw ModelError.checksumMismatch(expected: spec.sha256, actual: digest)
        }

        // Move into place only once verified, so a crash mid-download never
        // leaves a half-file that looks installed.
        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: downloaded, to: installed)
        NSLog("ModelManager: installed %@", installed.path)
        return installed
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSession download wrapped for async/await, with resume across attempts.
///
/// A 1.6 GB transfer over a flaky connection will fail sometimes; discarding
/// a gigabyte of progress on a dropped connection is not acceptable, so we
/// hold onto the resume data and continue from where we stopped.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let spec: ModelManager.Spec
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Where a completed download is parked before checksumming. Not the final
    /// install path — see `ModelManager.ensureAvailable`.
    private let stagingURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("macvibe-model-\(UUID().uuidString).part")

    init(spec: ModelManager.Spec, onProgress: @escaping @Sendable (Double) -> Void) {
        self.spec = spec
        self.onProgress = onProgress
    }

    func run(maxAttempts: Int = 3) async throws -> URL {
        var resumeData: Data?
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                return try await attemptDownload(resumeData: resumeData)
            } catch {
                lastError = error
                // `NSURLSessionDownloadTaskResumeData` is present only when the
                // server supports ranged requests and the failure was
                // recoverable; otherwise we restart from zero.
                resumeData = (error as NSError)
                    .userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                NSLog("ModelManager: download attempt %d/%d failed (%@)%@",
                      attempt, maxAttempts, error.localizedDescription,
                      resumeData != nil ? " — will resume" : "")
            }
        }
        throw lastError ?? URLError(.unknown)
    }

    private func attemptDownload(resumeData: Data?) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let task = resumeData.map { session.downloadTask(withResumeData: $0) }
                ?? session.downloadTask(with: spec.remoteURL)
            task.resume()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // A resumed task reports the *expected* total for the whole file, but
        // some servers report -1; fall back to the size we pinned.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : spec.byteCount
        onProgress(min(1.0, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // `location` is deleted as soon as this method returns, so the move
        // has to happen here rather than in the completion handler.
        if let response = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(response.statusCode) {
            finish(.failure(ModelManager.ModelError.httpStatus(response.statusCode)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: stagingURL)
            try FileManager.default.moveItem(at: location, to: stagingURL)
            finish(.success(stagingURL))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error { finish(.failure(error)) }
    }
}
