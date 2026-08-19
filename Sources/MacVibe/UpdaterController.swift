import AppKit
import Sparkle

/// Wraps Sparkle's standard updater for a menubar-only (`LSUIElement`) app.
///
/// Two things differ from a normal app: `.accessory` apps aren't activated by
/// default, so Sparkle's windows would open behind whatever the user is
/// working in; and there's no Dock icon to badge, so we lean on Sparkle's
/// "gentle reminder" hooks to surface a pending update in the menubar instead
/// of stealing focus.
@MainActor
final class UpdaterController: NSObject {
    /// Called when a background check finds an update the user hasn't seen
    /// yet, and again with `false` once that update has been handled. The
    /// delegate uses it to mark the menubar icon.
    var onUpdatePending: ((Bool) -> Void)?

    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        // `startingUpdater: true` kicks off the scheduled-check timer. On the
        // very first launch Sparkle asks the user whether to enable automatic
        // checks rather than assuming consent.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// User-initiated check. Brings the app forward first so Sparkle's window
    /// lands in front of the app the user was actually using.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

extension UpdaterController: SPUStandardUserDriverDelegate {
    /// Tells Sparkle we can hold a found update until the user is ready,
    /// instead of interrupting them the moment a background check succeeds.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Let Sparkle show its window immediately only when it already has
        // focus; otherwise we just flag it in the menubar (below).
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            if !state.userInitiated {
                onUpdatePending?(true)
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            onUpdatePending?(false)
        }
    }
}
