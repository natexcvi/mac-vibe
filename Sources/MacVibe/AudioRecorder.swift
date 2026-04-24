import AVFoundation
import Foundation

/// Captures microphone audio and writes a 16 kHz mono PCM WAV file — the format
/// VibeVoice-ASR expects as input.
final class AudioRecorder {
    enum RecorderError: Error {
        case permissionDenied
        case converterUnavailable
        case notRecording
    }

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var fileURL: URL?
    private var converter: AVAudioConverter?
    private var fileProcessingFormat: AVAudioFormat?
    // Settings control the on-disk WAV: 16 kHz mono LPCM, 16-bit. AVAudioFile
    // accepts these settings but its `processingFormat` (what write(from:)
    // expects in memory) is always non-interleaved float32.
    private let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    @discardableResult
    func start() throws -> URL {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-vibe-\(UUID().uuidString).wav")
        self.fileURL = url

        let file = try AVAudioFile(forWriting: url, settings: fileSettings)
        self.audioFile = file

        // `file.processingFormat` is the format write(from:) expects in memory
        // (always non-interleaved float32 for PCM files). We convert from the
        // mic's native format into that format, then let AVAudioFile encode to
        // int16 on disk.
        let processingFormat = file.processingFormat
        self.fileProcessingFormat = processingFormat

        guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer: buffer, inputFormat: inputFormat)
        }

        engine.prepare()
        try engine.start()
        return url
    }

    private func append(buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat) {
        guard let file = audioFile,
              let converter = converter,
              let processingFormat = fileProcessingFormat else { return }

        let ratio = processingFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            NSLog("AudioRecorder: converter error: \(error?.localizedDescription ?? "unknown")")
            return
        }
        if outBuffer.frameLength > 0 {
            do {
                try file.write(from: outBuffer)
            } catch {
                NSLog("AudioRecorder: file write failed: \(error)")
            }
        }
    }

    func stop() -> URL? {
        guard engine.isRunning else { return fileURL }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil  // flushes & closes
        converter = nil
        return fileURL
    }
}
