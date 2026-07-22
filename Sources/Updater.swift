// SPDX-License-Identifier: GPL-2.0-or-later
import Sparkle

/// Sparkle update checks, driven by events rather than by a timer.
///
/// Sparkle ships its own scheduler (`SUEnableAutomaticChecks` +
/// `SUScheduledCheckInterval`), and it is a repeating timer — the one thing this
/// app's energy rule forbids without proof that no event-driven alternative
/// exists. There is an alternative, because an update check has no deadline: it
/// only has to happen *eventually*, on a machine someone is actually using.
///
/// So automatic checks are off in `Info.plist` and this type re-uses wake-ups the
/// app already receives — launch, `NSWorkspace.didWakeNotification`, and resume
/// from hard suppression — throttled so at most one check happens per
/// `minimumAwakeInterval`. A laptop wakes at least daily, so in practice this
/// checks about as often as Sparkle's daily default while owning **no timer** and
/// doing **zero** work while the machine is idle or the app is off-duty.
///
/// Honest about what this is: the check itself is still an HTTP GET of a static
/// appcast. Sparkle has no push mechanism, and a real one would need APNs or a
/// held-open connection — far more expensive than one request a day. What the
/// event-driven design buys is that nothing fires unless something already woke
/// us for another reason.
@MainActor
internal final class Updater {
    /// Minimum *awake* time between background checks.
    ///
    /// Deliberately measured with `Uptime`, not `Date`: Sparkle's own
    /// `lastUpdateCheckDate` is civil time and inherits the rollback bug this
    /// project has already been bitten by twice. Uptime excludes sleep, so this
    /// counts hours of actual use rather than hours on the wall — the more honest
    /// question anyway, since a sleeping machine had no chance to install
    /// anything.
    private static let minimumAwakeInterval: TimeInterval = 21_600 // 6 hours awake

    // swiftlint:disable weak_delegate - inverted ownership, see the doc comment below
    /// Held strongly for the controller's lifetime.
    ///
    /// `SPUStandardUpdaterController` keeps both delegates **weakly**, so these
    /// two references are the only thing keeping them alive. Making them `weak`
    /// to satisfy the usual rule deallocates them immediately and silently
    /// disables gentle reminders and the error filtering — with nothing to
    /// notice, since a missing delegate is not an error to Sparkle.
    private let updaterDelegate: UpdaterDelegate
    private let userDriverDelegate: UserDriverDelegate
    // swiftlint:enable weak_delegate
    private let controller: SPUStandardUpdaterController
    private var lastCheckUptime: TimeInterval?

    internal init() {
        // Locals first: the delegates must exist before the controller, and Swift
        // forbids reading `self`'s properties while still initialising them.
        // Sparkle takes both only at construction — there is no settable
        // `delegate` property on SPUUpdater.
        let updaterDelegate = UpdaterDelegate()
        let userDriverDelegate = UserDriverDelegate()
        self.updaterDelegate = updaterDelegate
        self.userDriverDelegate = userDriverDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: userDriverDelegate
        )
        // Belt and braces: Info.plist already sets this false, but the value is
        // also a user default, so a stale one could otherwise re-arm the timer.
        controller.updater.automaticallyChecksForUpdates = false
    }

    deinit {
        // Nothing releases this today — the app owns one Updater for its whole
        // lifetime — which is exactly why it must be correct if that changes.
        // The controller owns the updater and its user driver and tears them down
        // itself; the delegates are ours and die with us.
    }

    /// A user asked, from the menu. Ignores the throttle and shows Sparkle's UI,
    /// including the "you're up to date" case the silent path swallows.
    internal func checkNow() {
        controller.updater.checkForUpdates()
    }

    /// Something woke us anyway — piggyback a silent check if one is due.
    ///
    /// Safe to call from every event source: the throttle and the in-flight guard
    /// make repeat calls free.
    internal func checkIfDue() {
        guard !controller.updater.sessionInProgress else {
            return // a check or install is already running
        }
        let now = Uptime.now()
        if let last = lastCheckUptime, now - last < Self.minimumAwakeInterval {
            return
        }
        lastCheckUptime = now
        controller.updater.checkForUpdatesInBackground()
    }
}

/// Filters Sparkle's "no update found", which arrives as an error.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        guard
            nsError.domain != SUSparkleErrorDomain
            || nsError.code != SUError.noUpdateError.rawValue
        else {
            return // "you're up to date" is not a failure
        }
        NSLog("Untracked: update check failed: \(error.localizedDescription)")
    }

    deinit {
        // Stateless; present because required_deinit makes ownership explicit.
    }
}

/// Keeps update prompts out of the user's way.
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// A menu-bar app has no business stealing focus to announce a patch release.
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    /// Only let Sparkle present a scheduled update when the app is already in
    /// front of the user; otherwise it waits until they come to it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    deinit {
        // Stateless; present because required_deinit makes ownership explicit.
    }
}
