import SwiftUI
import AppKit

@main
struct MacVibeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var coordinator: DictationCoordinator!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // `.accessory` apps with no windows are candidates for macOS Automatic
        // Termination. Disable it — we need to keep running to watch the
        // global hotkey and shepherd the Python sidecar.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("MacVibe runs as a background dictation listener")

        // When launched from a terminal (useful for debugging stderr), the
        // process group picks up SIGHUP when the parent shell exits. Ignore it
        // so the app survives after the launching task completes.
        signal(SIGHUP, SIG_IGN)

        // Mirror NSLog output to ~/Library/Logs/MacVibe.log so we can debug
        // runs started via `open …app` without a terminal attached.
        redirectStderrToLogFile()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "MacVibe")
            button.imagePosition = .imageOnly
        }

        let menu = NSMenu()
        // No keyEquivalent — the global hotkey is a clean tap of right ⌥
        // (handled by HotkeyMonitor) and the menu can't display that shape.
        let toggleItem = NSMenuItem(title: "Toggle Dictation  (right ⌥)", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(NSMenuItem.separator())
        let statusMenuItem = NSMenuItem(title: "Status: starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        statusMenuItem.tag = 1001
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        let refineToggle = NSMenuItem(
            title: "Refine with Apple Intelligence",
            action: #selector(toggleRefinement),
            keyEquivalent: ""
        )
        refineToggle.target = self
        refineToggle.tag = 1002
        menu.addItem(refineToggle)

        let langParent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langParent.submenu = makeLanguageMenu()
        menu.addItem(langParent)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Edit Custom Words…", action: #selector(editCustomWords), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Microphone Settings…", action: #selector(openMicrophone), keyEquivalent: "").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit MacVibe", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        coordinator = DictationCoordinator()
        // Reflect persisted refinement preference in the menu.
        refineToggle.state = coordinator.refinementEnabled ? .on : .off
        coordinator.onStatusChange = { [weak statusItem] text in
            DispatchQueue.main.async {
                statusItem?.menu?.item(withTag: 1001)?.title = "Status: \(text)"
            }
        }
        coordinator.start()
    }

    @MainActor @objc private func toggleFromMenu() {
        coordinator.toggle()
    }

    @MainActor @objc private func toggleRefinement(_ sender: NSMenuItem) {
        coordinator.refinementEnabled.toggle()
        sender.state = coordinator.refinementEnabled ? .on : .off
    }

    @MainActor @objc private func editCustomWords() {
        Hotwords.openInEditor()
    }

    private func makeLanguageMenu() -> NSMenu {
        let menu = NSMenu()
        let current = Prefs.language
        for option in Prefs.supportedLanguages {
            let item = NSMenuItem(
                title: option.label,
                action: #selector(selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.code
            item.state = (option.code == current) ? .on : .off
            menu.addItem(item)
            if option.code == "auto" {
                menu.addItem(NSMenuItem.separator())
            }
        }
        return menu
    }

    @MainActor @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Prefs.language = code
        // Refresh checkmarks across the submenu.
        if let parent = sender.menu {
            for item in parent.items {
                item.state = (item.representedObject as? String == code) ? .on : .off
            }
        }
    }

    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openMicrophone() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func redirectStderrToLogFile() {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs")
        guard let logsDir = logsDir else { return }
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("MacVibe.log")
        _ = logFile.path.withCString { path in
            freopen(path, "a", stderr)
        }
        setvbuf(stderr, nil, _IONBF, 0)
        NSLog("MacVibe %@ starting (pid %d)", "0.1.0", getpid())
    }
}
