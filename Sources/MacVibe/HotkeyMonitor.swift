import AppKit
import Carbon.HIToolbox

/// Watches for a clean tap (press + release, no chord) of the *right* Option key
/// via a low-level CGEventTap. Requires Accessibility permission.
///
/// Why a device-specific flag: NSEvent's `.option` modifier and `CGEventFlags.maskAlternate`
/// cannot distinguish left from right Option. IOKit exposes device-specific modifier masks
/// in the raw flag bits — `NX_DEVICERALTKEYMASK` (0x00000040) is set while the right Option
/// key is physically held.
final class HotkeyMonitor {
    var onTap: (() -> Void)?
    var onPermissionDenied: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightOptionDown = false
    private var chorded = false
    private var downAt: CFAbsoluteTime = 0

    private static let rightOptionDeviceMask: UInt64 = 0x00000040

    private var trustPollTimer: Timer?
    private var lastKnownTrust = false

    func start() {
        let trusted = AXIsProcessTrusted()
        lastKnownTrust = trusted
        NSLog("HotkeyMonitor.start: AXIsProcessTrusted=%@", trusted ? "true" : "false")

        if !trusted {
            // Surface the system prompt and notify the UI; we'll keep polling
            // in the background and re-arm the tap when permission lands.
            let key = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([key: true] as NSDictionary)
            onPermissionDenied?()
        }

        installTap()
        startTrustPolling()
    }

    /// Polls `AXIsProcessTrusted` every 2 s. Tears down and recreates the tap
    /// when permission flips. Necessary because:
    ///   1. tapCreate returns a *non-nil* CFMachPort even when Accessibility is
    ///      denied — the events just never arrive. So we can't tell at create
    ///      time whether the tap will work.
    ///   2. A tap created while denied stays dead even after the user grants
    ///      permission later — it has to be recreated.
    private func startTrustPolling() {
        trustPollTimer?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let trusted = AXIsProcessTrusted()
            if trusted != self.lastKnownTrust {
                NSLog("HotkeyMonitor: AXIsProcessTrusted flipped %@ → %@",
                      self.lastKnownTrust ? "true" : "false",
                      trusted ? "true" : "false")
                self.lastKnownTrust = trusted
                if trusted {
                    self.tearDownTap()
                    self.installTap()
                    // We're trusted; can stop polling.
                    self.trustPollTimer?.invalidate()
                    self.trustPollTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustPollTimer = timer
    }

    private func tearDownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func installTap() {
        if eventTap != nil { return }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        ) else {
            NSLog("HotkeyMonitor: tapCreate returned nil")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source
        let trusted = AXIsProcessTrusted()
        NSLog("HotkeyMonitor: event tap installed (trusted=%@)", trusted ? "true" : "false")
    }

    func stop() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        tearDownTap()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        // If the tap got disabled (timeout, etc.), re-enable it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }

        // Any non-modifier input during an Option-hold disqualifies the tap.
        if rightOptionDown, type == .keyDown || type == .leftMouseDown || type == .rightMouseDown {
            chorded = true
            return
        }

        guard type == .flagsChanged else { return }

        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keycode == kVK_RightOption else { return }

        let isDown = (event.flags.rawValue & Self.rightOptionDeviceMask) != 0

        if isDown, !rightOptionDown {
            rightOptionDown = true
            chorded = false
            downAt = CFAbsoluteTimeGetCurrent()
            NSLog("HotkeyMonitor: right ⌥ DOWN")
            return
        }

        if !isDown, rightOptionDown {
            let elapsed = CFAbsoluteTimeGetCurrent() - downAt
            rightOptionDown = false
            NSLog("HotkeyMonitor: right ⌥ UP after %.0f ms (chorded=%@)", elapsed * 1000, chorded ? "true" : "false")
            // Clean tap: released within 0.6s and no other key/click in between.
            if !chorded, elapsed < 0.6 {
                NSLog("HotkeyMonitor: clean tap → firing onTap")
                DispatchQueue.main.async { [weak self] in
                    self?.onTap?()
                }
            }
        }
    }
}
