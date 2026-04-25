import AppKit
import SwiftUI
import Combine

enum PopupState: Equatable {
    case hidden
    case recording
    case transcribing
    case refining(String)
    case done(String)
    /// Pasted, but the language Whisper acoustically detected disagrees with
    /// what the user pinned in the menu — text is shown alongside the warning.
    case doneWithLanguageWarning(text: String, detected: String, pinned: String)
    case error(String)
}

@MainActor
final class PopupViewModel: ObservableObject {
    @Published var state: PopupState = .hidden
    @Published var pulse: Bool = false
}

@MainActor
final class PopupController {
    private let viewModel = PopupViewModel()
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    func show(_ state: PopupState) {
        hideWorkItem?.cancel()
        hideWorkItem = nil

        ensurePanel()
        viewModel.state = state
        viewModel.pulse = (state == .recording)

        // Only reorder the window when it's not already on screen. Calling
        // orderFrontRegardless on every state tick (e.g. each refinement
        // partial) can briefly steal focus from the app we're about to paste
        // into, even with nonactivatingPanel.
        if let panel = panel, !panel.isVisible {
            positionAtActiveScreen()
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        viewModel.state = .hidden
        panel?.orderOut(nil)
    }

    func autoHide(after seconds: TimeInterval) {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func ensurePanel() {
        if panel != nil { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingView(rootView: PopupView(viewModel: viewModel))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = hosting

        self.panel = panel
    }

    private func positionAtActiveScreen() {
        guard let panel = panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.minY + 140
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
