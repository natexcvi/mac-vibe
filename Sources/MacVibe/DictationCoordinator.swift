import AppKit
import Carbon.HIToolbox

@MainActor
final class DictationCoordinator {
    enum RuntimeState { case idle, recording, processing }

    var onStatusChange: ((String) -> Void)?
    var refinementEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "refinementEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "refinementEnabled") }
    }

    private var state: RuntimeState = .idle
    /// Dictation is unavailable until the whisper weights are on disk — on a
    /// fresh install that means a ~1.6 GB download.
    private var modelReady = false
    private var setupProgress: Double = 0
    private var downloadStarted = false
    private var setupFailure: String?
    /// Whether the HUD is currently dedicated to download progress. The panel
    /// floats above everything, so we show it briefly and then fall back to
    /// the menubar status rather than parking it on screen for the whole
    /// download.
    private var downloadPopupVisible = false
    private let recorder = AudioRecorder()
    private let transcriber = TranscriptionService()
    private let refiner = RefinementService()
    private let hotkey = HotkeyMonitor()
    private let popup = PopupController()

    /// Frontmost app captured at the moment recording started. We re-activate
    /// it before pasting so ⌘V lands where the user expected, even if focus
    /// briefly shifted while the popup was on screen.
    private var pasteTarget: NSRunningApplication?

    func start() {
        transcriber.onStatusChange = { [weak self] text in
            self?.onStatusChange?(text)
        }

        Task { [weak self] in
            _ = await self?.recorder.requestPermission()
        }

        hotkey.onTap = { [weak self] in
            self?.toggle()
        }
        hotkey.onPermissionDenied = { [weak self] in
            self?.onStatusChange?("needs Accessibility permission")
        }
        hotkey.start()

        Task { [weak self] in
            await self?.prepareModel()
        }
    }

    /// Resolves the speech model — downloading it on first launch — and only
    /// then starts the sidecar. Runs once at startup.
    private func prepareModel() async {
        onStatusChange?("checking speech model…")
        do {
            let modelURL = try await ModelManager.ensureAvailable { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.reportDownloadProgress(fraction)
                }
            }
            modelReady = true
            setupFailure = nil
            if downloadPopupVisible {
                popup.hide()
                downloadPopupVisible = false
            }
            transcriber.launch(modelPath: modelURL)
            onStatusChange?("ready — tap right ⌥")
        } catch {
            let message = error.localizedDescription
            setupFailure = message
            NSLog("Coordinator: model setup failed — %@", message)
            onStatusChange?("model download failed")
            popup.show(.error("Speech model download failed — \(message)"))
            popup.autoHide(after: 6)
            downloadPopupVisible = false
        }
    }

    private func reportDownloadProgress(_ fraction: Double) {
        // The very first callback is what tells us a download is actually
        // happening (an already-installed model reports nothing at all), so
        // it's what raises the HUD.
        if !downloadStarted {
            downloadStarted = true
            setupProgress = fraction
            onStatusChange?("downloading speech model…")
            showDownloadPopup()
            return
        }

        // Afterwards the callback fires per chunk; only act on whole-percent
        // changes so we aren't rebuilding the menu title thousands of times.
        let percent = Int(fraction * 100)
        guard percent != Int(setupProgress * 100) else { return }
        setupProgress = fraction
        onStatusChange?("downloading speech model… \(percent)%")
        if downloadPopupVisible {
            popup.show(.downloadingModel(fraction: fraction))
        }
    }

    /// Puts the progress HUD on screen for a few seconds. Called at the start
    /// of the download, and again if the user taps the hotkey while it runs.
    private func showDownloadPopup() {
        downloadPopupVisible = true
        popup.show(.downloadingModel(fraction: setupProgress))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self = self, self.downloadPopupVisible else { return }
            self.downloadPopupVisible = false
            self.popup.hide()
        }
    }

    func toggle() {
        // Tapping the hotkey before setup finishes should explain itself
        // rather than silently doing nothing.
        guard modelReady else {
            if let failure = setupFailure {
                popup.show(.error(failure))
                popup.autoHide(after: 4)
            } else {
                showDownloadPopup()
            }
            return
        }

        switch state {
        case .idle: beginRecording()
        case .recording: finishRecording()
        case .processing: break
        }
    }

    private func beginRecording() {
        // Snapshot the focus target BEFORE we touch any UI, so we can restore
        // it before pasting. Falls back to whatever's frontmost if nil.
        pasteTarget = NSWorkspace.shared.frontmostApplication
        if let target = pasteTarget {
            NSLog("Coordinator: recording → paste target = %@ (pid %d)",
                  target.localizedName ?? "?", target.processIdentifier)
        }

        do {
            _ = try recorder.start()
            state = .recording
            popup.show(.recording)
            onStatusChange?("recording")
        } catch {
            popup.show(.error(error.localizedDescription))
            popup.autoHide(after: 3)
        }
    }

    private func finishRecording() {
        guard let audioURL = recorder.stop() else {
            state = .idle
            popup.hide()
            return
        }
        state = .processing
        popup.show(.transcribing)
        onStatusChange?("transcribing")

        Task { [weak self] in
            await self?.runPipeline(audioURL: audioURL)
        }
    }

    private func runPipeline(audioURL: URL) async {
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let result: TranscriptionService.Result
        do {
            result = try await transcriber.transcribe(audioURL: audioURL)
        } catch {
            popup.show(.error(error.localizedDescription))
            popup.autoHide(after: 4)
            state = .idle
            onStatusChange?("error")
            return
        }

        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            popup.show(.error("Nothing was heard"))
            popup.autoHide(after: 2)
            state = .idle
            onStatusChange?("ready")
            return
        }

        let final: String
        if refinementEnabled {
            popup.show(.refining(trimmed))
            onStatusChange?("refining")
            final = await refiner.refine(trimmed) { [weak self] partial in
                // Refinement streaming fires off-main; hop back to MainActor
                // before touching AppKit (PopupController is @MainActor).
                Task { @MainActor [weak self] in
                    self?.popup.show(.refining(partial))
                }
            }
        } else {
            final = trimmed
        }

        pasteAndShow(final, detectedLanguage: result.detectedLanguage)
        state = .idle
        onStatusChange?("ready")
    }

    private func pasteAndShow(_ text: String, detectedLanguage: String? = nil) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Hide the popup so the destination app gets clean focus.
        popup.hide()

        // Restore focus to whatever app the user was in when they tapped, then
        // synthesize ⌘V. Without this, focus may have drifted to the popup,
        // a system overlay, or just lost altogether — and the synthesized
        // keystroke goes nowhere.
        let frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        if let target = pasteTarget, !target.isTerminated {
            target.activate()
            NSLog("Coordinator: re-activated %@ (was frontmost: %@)",
                  target.localizedName ?? "?", frontBefore)
            // Activation is async; let AppKit run the activation cycle before
            // the keystroke arrives.
            usleep(150_000)
        } else {
            NSLog("Coordinator: no paste target captured; pasting into current frontmost (%@)", frontBefore)
        }

        let pasted = synthesizeCommandV()
        if pasted {
            // If the user pinned a language and Whisper acoustically heard
            // a different one, surface the disagreement — Whisper's language
            // pin is a soft hint and it'll happily output a different language
            // if the audio overrides. Without this warning the mismatch looks
            // like an inexplicable bug to the user.
            let pinned = Prefs.language
            if pinned != "auto",
               let detected = detectedLanguage,
               detected != pinned {
                NSLog("Coordinator: language mismatch — pinned=%@ detected=%@", pinned, detected)
                popup.show(.doneWithLanguageWarning(text: text, detected: detected, pinned: pinned))
                popup.autoHide(after: 4.0)
            } else {
                popup.show(.done(text))
                popup.autoHide(after: 2.0)
            }
        } else {
            popup.show(.error("Text copied — paste failed (Accessibility?)"))
            popup.autoHide(after: 2.0)
        }
    }

    /// Synthesizes ⌘V to paste into the focused text field. Returns false only
    /// if the event objects couldn't be constructed.
    private func synthesizeCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up   = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else {
            NSLog("Coordinator: failed to construct CGEvent(s)")
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        NSLog("Coordinator: posted ⌘V (HID tap)")
        return true
    }
}
