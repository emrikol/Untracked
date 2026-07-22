import AppKit
import Foundation
import os
import ServiceManagement

private let log = Logger(subsystem: "com.emrikol.Untracked", category: "state")

private let togglBundleID = "com.toggl.daneel"

/// Timing constants. These are the energy-relevant knobs — see CLAUDE.md's
/// "Event-driven, never polling": the fallback is a backstop, not a poll loop,
/// and the tolerances exist so macOS can batch our wake-ups with others.
private enum Timing {
    /// Backstop re-read in case an FSEvent is missed. Long, and only while
    /// monitoring.
    static let fallbackInterval: TimeInterval = 120
    static let fallbackTolerance: TimeInterval = 30
    /// Work-hours boundary timers may drift by this fraction of their delay, to
    /// a ceiling — but only when transitioning *into* work time.
    static let boundaryToleranceFraction = 0.05
    static let maxBoundaryTolerance: TimeInterval = 60
    static let secondsPerMinute: TimeInterval = 60
}

// swiftlint:disable no_magic_numbers - these are the offered durations themselves
/// Snooze durations offered in the menu, in minutes.
private let snoozeOptionsMinutes = [10, 30, 60]
// swiftlint:enable no_magic_numbers

/// `@MainActor` because it owns the status item, menu, timers and overlay. All
/// watcher/config/suppression callbacks are delivered on the main thread, so
/// they re-enter this actor via `MainActor.assumeIsolated` rather than an extra
/// hop — see the `assumeIsolated` note in `applicationDidFinishLaunching`.
@MainActor
internal final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let overlay = OverlayController()
    private let config = ConfigStore()
    private let suppression = SuppressionMonitor()
    private lazy var watcher = TogglWatcher { [weak self] state in
        MainActor.assumeIsolated { self?.apply(state) }
    }

    private var fallback: Timer?
    private var graceTimer: Timer?
    private var boundaryTimer: Timer?
    private var snoozeTimer: Timer?
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var state: TrackingState = .unavailable
    private var settings = Settings.defaults
    private var monitoring = false // are we actively reading Toggl's DB?
    /// Monotonic deadline (see `Uptime`). The menu offers "10/30/60 minutes" —
    /// a *duration*, so anchoring it to the wall clock would let a backward
    /// correction stretch a 10-minute snooze into a 70-minute one.
    private var snoozeUntilUptime: TimeInterval?
    private var paused = false
    /// Wall-clock start of the current not-tracking stretch. Display only
    /// ("not tracking for 12m") — that genuinely is a civil-time question.
    private var notTrackingSince: Date?
    /// Monotonic counterpart, used to admit the grace period (see `Uptime`).
    private var notTrackingSinceUptime: TimeInterval?
    private var warnedUnavailable = false

    // Dynamically-updated menu items. Built here rather than assigned during
    // setup so they need no implicit unwrapping later; `target` still has to be
    // wired in setupStatusItem, since that references self.
    private let statusLine = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "p")
    private let flashTrackingItem = NSMenuItem(
        title: "Flash When Tracking (green)",
        action: #selector(toggleFlashTracking),
        keyEquivalent: ""
    )
    private let flashNotTrackingItem = NSMenuItem(
        title: "Flash When Not Tracking (red)",
        action: #selector(toggleFlashNotTracking),
        keyEquivalent: ""
    )
    private let workHoursItem = NSMenuItem(
        title: "Only Nag During Work Hours",
        action: #selector(toggleWorkHours),
        keyEquivalent: ""
    )
    private let respectDndItem = NSMenuItem(
        title: "Respect Focus / Do Not Disturb",
        action: #selector(toggleRespectDnd),
        keyEquivalent: ""
    )
    private var styleItems: [AlertStyle: NSMenuItem] = [:]

    internal func applicationDidFinishLaunching(_: Notification) {
        Notifier.requestAuthorization()
        setupStatusItem()
        configureLaunchAtLoginOnFirstRun()

        // Load + hot-reload ~/.untracked.json (kqueue watcher, no polling).
        // These three callbacks are delivered on the main thread by their owners,
        // so assumeIsolated re-enters the actor without paying for another hop --
        // and traps loudly if that contract is ever broken.
        config.onChange = { [weak self] settings in
            MainActor.assumeIsolated { self?.applySettings(settings) }
        }
        config.start()
        settings = config.settings // adopt loaded settings now, so the first
        // updateMonitoring() below uses real work-hours (no launch-into-defaults read)

        // Suppress the nag while away / in Focus; re-evaluate when those flip.
        // Started/stopped with monitoring (below), so nothing reacts to lock or
        // Focus events while off-duty.
        suppression.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.evaluateOverlay() }
        }

        // Recompute monitoring when the machine wakes or the clock/timezone
        // changes (covers sleeping across a work-hours boundary — no polling).
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(systemMaybeChanged), name: NSWorkspace.didWakeNotification, object: nil)
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(systemMaybeChanged), name: name, object: nil)
        }

        updateMonitoring() // starts the watcher unless we launch into quiet hours
    }

    deinit {
        // AppDelegate lives for the process, so this is defensive rather than
        // load-bearing: applicationWillTerminate does the real teardown. Observers
        // are removed here because a selector registration outliving the object is
        // the one failure that crashes rather than merely leaking.
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    internal func applicationWillTerminate(_: Notification) {
        watcher.stop()
        fallback?.invalidate()
        graceTimer?.invalidate()
        boundaryTimer?.invalidate()
        snoozeTimer?.invalidate()
    }

    @objc
    private func systemMaybeChanged() {
        updateMonitoring()
    }

    // MARK: Monitoring lifecycle (the "do nothing during quiet hours" logic)

    /// We only read Toggl's DB when a nag is actually possible. When paused or
    /// outside work hours, we stop the watcher + fallback entirely (zero reads,
    /// zero Toggl wake-ups) and rely on a single dated timer + wake/clock
    /// notifications to resume. Idempotent — safe to call from anywhere.
    private func updateMonitoring() {
        let shouldMonitor = !isHardSuppressed()
        if shouldMonitor, !monitoring {
            // A stopped generation's cached state is not presentation authority.
            // Stay quiet until the newly registered watcher completes its refresh.
            state = .unavailable
            notTrackingSince = nil
            notTrackingSinceUptime = nil
            monitoring = true
            suppression.start()
            watcher.start() // registers first, then performs an authoritative read
            startFallback()
        } else if !shouldMonitor, monitoring {
            monitoring = false
            suppression.stop()
            watcher.stop()
            stopFallback()
            // Drop the snooze wake too: while hard-suppressed it can only fire to
            // return early from evaluateOverlay. The monotonic deadline is kept,
            // and evaluateOverlay re-arms on resume via its `snoozeTimer == nil`
            // branch — "never do work when a nag is impossible".
            snoozeTimer?.invalidate()
            snoozeTimer = nil
        }
        scheduleBoundary()
        updateStatusItem()
        evaluateOverlay()
    }

    /// True when a nag can't happen regardless of tracking state, so reading is
    /// pointless. (Away/Focus are deliberately excluded — they're short and
    /// resume on their own events, so we keep monitoring through them.)
    private func isHardSuppressed() -> Bool {
        if paused {
            return true
        }
        if settings.workHoursEnabled, !settings.nagAllowedNow() {
            return true
        }
        return false
    }

    private func startFallback() {
        stopFallback()
        let timer = Timer(timeInterval: Timing.fallbackInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watcher.refresh() }
        }
        timer.tolerance = Timing.fallbackTolerance // backstop for a missed FSEvent; coalesced
        RunLoop.main.add(timer, forMode: .common)
        fallback = timer
    }

    private func stopFallback() {
        fallback?.invalidate()
        fallback = nil
    }

    /// One dated, self-rescheduling timer to the next work-hours transition.
    /// Not polling — a single scheduled wake the OS delivers at that time.
    private func scheduleBoundary() {
        boundaryTimer?.invalidate()
        boundaryTimer = nil
        // Paused has no time boundary (it resumes manually), so don't wake for one.
        guard !paused, let next = settings.nextWorkHoursTransition(after: Date()) else {
            return
        }
        // wall-clock: the boundary is an absolute local instant — 09:00 means
        // 09:00, so this deadline *should* move when the clock is corrected.
        let interval = max(1, next.timeIntervalSinceNow)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMonitoring() }
        }
        let entersQuietTime = settings.nagAllowedNow()
            && !settings.nagAllowedNow(next.addingTimeInterval(1))
        // A late transition into quiet time leaves a visible nag on screen. Only
        // transitions back into working time may trade precision for coalescing.
        timer.tolerance = entersQuietTime
            ? 0
            : min(Timing.maxBoundaryTolerance, interval * Timing.boundaryToleranceFraction)
        RunLoop.main.add(timer, forMode: .common)
        boundaryTimer = timer
    }

    // MARK: State + settings

    private func applySettings(_ new: Settings) {
        settings = new
        overlay.configure(
            style: new.style,
            beatPeriod: new.beatPeriodSeconds,
            thickness: CGFloat(new.borderThickness)
        )
        updateMonitoring() // work-hours change may start/stop monitoring
    }

    private func apply(_ state: TrackingState) {
        if state != self.state {
            log.notice("state -> \(String(describing: state), privacy: .public)")
        }

        let wasNotTracking = Self.isNotTracking(self.state)
        let nowNotTracking = Self.isNotTracking(state)
        if nowNotTracking, !wasNotTracking {
            notTrackingSince = Date()
            notTrackingSinceUptime = Uptime.now()
        }
        if !nowNotTracking {
            notTrackingSince = nil
            notTrackingSinceUptime = nil
        }

        self.state = state
        updateStatusItem()
        checkDataHealth()
        evaluateOverlay()
    }

    private static func isNotTracking(_ s: TrackingState) -> Bool {
        if case .notTracking = s {
            return true
        }
        return false
    }

    /// Single place that decides whether/what the overlay shows.
    private func evaluateOverlay() {
        graceTimer?.invalidate()
        graceTimer = nil

        // Suppressions (quiet) — paused, away, Focus/DnD, outside work hours.
        if paused || suppression.isAway {
            overlay.hide(); return
        }
        if settings.respectDoNotDisturb, suppression.focusActive {
            overlay.hide(); return
        }
        if !settings.nagAllowedNow() {
            overlay.hide(); return
        }

        if let until = snoozeUntilUptime {
            let remaining = until - Uptime.now()
            if remaining > 0 {
                overlay.hide()
                if snoozeTimer == nil {
                    scheduleSnoozeExpiration(after: remaining)
                }
                return
            }
            snoozeUntilUptime = nil
            snoozeTimer?.invalidate()
            snoozeTimer = nil
        }

        switch state {
        case .tracking where settings.flashWhenTracking:
            overlay.show(tint: settings.trackingColor, key: "tr-\(settings.trackingColorHex)")

        case .notTracking where settings.flashWhenNotTracking:
            // Grace period: don't nag for the first N seconds after a timer stops.
            // Monotonic on purpose: with civil `Date` math a backward clock
            // correction turned a 45 s grace into 45 s + the rollback, silencing
            // the nag for as long as the correction was large.
            if let since = notTrackingSinceUptime {
                let elapsed = Uptime.now() - since
                if elapsed < settings.gracePeriodSeconds {
                    overlay.hide()
                    let timer = Timer(
                        timeInterval: settings.gracePeriodSeconds - elapsed,
                        repeats: false
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.evaluateOverlay() }
                    }
                    RunLoop.main.add(timer, forMode: .common) // fire even while a menu is open
                    graceTimer = timer
                    return
                }
            }
            overlay.show(tint: settings.notTrackingColor, key: "nt-\(settings.notTrackingColorHex)")

        default:
            overlay.hide()
        }
    }

    /// #5: if we can't read Toggl's data while Toggl is actually running, the DB
    /// schema probably changed — warn once (otherwise the failure is silent).
    private func checkDataHealth() {
        let togglRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == togglBundleID }
        if case .unavailable = state, togglRunning {
            guard !warnedUnavailable else {
                return
            }
            // Latch the *attempt*, not the delivery. Previously the flag was only
            // set on success, so a failing add() re-submitted on every watcher and
            // fallback read for the whole outage. Recovery resets it below, so a
            // later episode warns again — bounded work, never permanently silent.
            warnedUnavailable = true
            Notifier.post(
                id: "data-unavailable",
                title: "Untracked",
                body: "Can't read Toggl's data — Toggl may have updated. Untracked might need a fix."
            ) { error in
                if let error {
                    NSLog("Untracked: health warning not delivered: \(error)")
                }
            }
        } else {
            warnedUnavailable = false
        }
    }
}

// MARK: - Menu, status presentation, and actions

/// Split out of the main declaration to keep it under the type-length budget.
/// Same file, so `private` members stay reachable — this is a readability
/// boundary (lifecycle and monitoring above, everything the user sees and
/// touches here), not an access-control one.
extension AppDelegate {
    // MARK: Status item + menu

    private func setupStatusItem() {
        updateStatusItem() // touching statusItem here also creates it

        let menu = NSMenu()
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Toggl Track", action: #selector(openToggl), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        // Snooze submenu
        let snoozeMenu = NSMenu()
        for minutes in snoozeOptionsMinutes {
            let item = NSMenuItem(title: "\(minutes) minutes", action: #selector(snooze(_:)), keyEquivalent: "")
            item.tag = minutes
            item.target = self
            snoozeMenu.addItem(item)
        }
        snoozeMenu.addItem(.separator())
        let cancel = NSMenuItem(title: "Cancel Snooze", action: #selector(cancelSnooze), keyEquivalent: "")
        cancel.target = self
        snoozeMenu.addItem(cancel)
        let snoozeRoot = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
        menu.addItem(snoozeRoot)
        menu.setSubmenu(snoozeMenu, for: snoozeRoot)

        // Alert style submenu
        let styleMenu = NSMenu()
        let styles: [(AlertStyle, String)] = [(.border, "Screen Border"), (.menuBar, "Menu Bar Strip"), (.both, "Both")]
        for (style, title) in styles {
            let item = NSMenuItem(title: title, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            item.representedObject = style.rawValue
            item.target = self
            styleItems[style] = item
            styleMenu.addItem(item)
        }
        let styleRoot = NSMenuItem(title: "Alert Style", action: nil, keyEquivalent: "")
        menu.addItem(styleRoot)
        menu.setSubmenu(styleMenu, for: styleRoot)

        // Flash toggles (checkmarks reflect the JSON config)
        flashTrackingItem.target = self
        menu.addItem(flashTrackingItem)

        flashNotTrackingItem.target = self
        menu.addItem(flashNotTrackingItem)

        workHoursItem.target = self
        menu.addItem(workHoursItem)

        respectDndItem.target = self
        menu.addItem(respectDndItem)
        menu.addItem(.separator())

        let editConfig = NSMenuItem(title: "Edit Config…", action: #selector(openConfig), keyEquivalent: ",")
        editConfig.target = self
        menu.addItem(editConfig)

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "Quit Untracked",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    private func updateStatusItem() {
        let (symbol, color): (String, NSColor) = {
            if paused {
                return ("pause.circle", .systemGray)
            }
            // Off-duty (outside work hours): we're not monitoring, so don't imply
            // a live tracking state — show a neutral "quiet" glyph instead.
            if settings.workHoursEnabled, !settings.nagAllowedNow() {
                return ("moon.zzz.fill", .systemGray)
            }
            switch state {
            case .tracking:
                return ("checkmark.circle.fill", .systemGreen)

            case .notTracking:
                return ("record.circle", .systemRed)

            case .unavailable:
                return ("questionmark.circle", .systemGray)
            }
        }()
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Toggl status")?
            .withSymbolConfiguration(config)
    }

    private func statusText() -> String {
        if paused {
            return "⏸ Paused"
        }
        if settings.workHoursEnabled, !settings.nagAllowedNow() {
            if let next = settings.nextWorkHoursTransition(after: Date()) {
                let fmt = DateFormatter()
                fmt.dateFormat = "EEE HH:mm"
                return "🌙 Off duty · back \(fmt.string(from: next))"
            }
            return "🌙 Off duty (outside work hours)"
        }
        switch state {
        case let .tracking(desc):
            return desc.map { "● Tracking: \($0)" } ?? "● Tracking"

        case .notTracking:
            var text = "○ Not tracking"
            if let since = notTrackingSince {
                // wall-clock: display only — never gates the nag.
                let minutes = Int(Date().timeIntervalSince(since) / Timing.secondsPerMinute)
                if minutes >= 1 {
                    text += " for \(minutes)m"
                }
            }
            return text

        case .unavailable:
            return "⚠ Toggl data unavailable"
        }
    }

    /// Why the nag is currently silenced (for the menu), if it is. Excludes
    /// paused / off-hours — statusText() already shows those prominently.
    private func quietNote() -> String? {
        if paused {
            return nil
        }
        if settings.workHoursEnabled, !settings.nagAllowedNow() {
            return nil
        } // shown as "Off duty"
        if suppression.isAway {
            return "quiet: away"
        }
        if settings.respectDoNotDisturb, suppression.focusActive {
            return "quiet: Focus on"
        }
        if let until = snoozeUntilUptime {
            let remaining = until - Uptime.now()
            if remaining > 0 {
                return "snoozed \(Int(remaining / Timing.secondsPerMinute) + 1)m"
            }
        }
        return nil
    }

    /// Called by the menu delegate right before the menu opens, so everything is fresh.
    internal func menuNeedsUpdate(_: NSMenu) {
        var title = statusText()
        if let note = quietNote() {
            title += "  (\(note))"
        }
        statusLine.title = title

        pauseItem.title = paused ? "Resume" : "Pause"
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        for (style, item) in styleItems {
            item.state = (style == settings.style) ? .on : .off
        }
        flashTrackingItem.state = settings.flashWhenTracking ? .on : .off
        flashNotTrackingItem.state = settings.flashWhenNotTracking ? .on : .off
        workHoursItem.state = settings.workHoursEnabled ? .on : .off
        workHoursItem.title = settings.workHoursEnabled
            ? "Only Nag During Work Hours (\(settings.workHours))"
            : "Only Nag During Work Hours"
        respectDndItem.state = settings.respectDoNotDisturb ? .on : .off
    }

    // MARK: Actions

    private func openTogglWeb(reason: String) {
        Notifier.post(id: "toggl-open-fallback", title: "Untracked", body: reason)
        if let url = URL(string: "https://track.toggl.com/timer") {
            NSWorkspace.shared.open(url)
        }
    }

    private func scheduleSnoozeExpiration(after seconds: TimeInterval) {
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        // Snoozing while paused or off-hours records the deadline but arms
        // nothing; resume re-arms it. Same reasoning as updateMonitoring.
        guard !isHardSuppressed() else {
            return
        }
        let timer = Timer(timeInterval: max(0, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else {
                    return
                }
                self.snoozeTimer = nil
                self.evaluateOverlay()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        snoozeTimer = timer
    }

    @objc
    private func openToggl() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: togglBundleID) {
            NSWorkspace.shared.openApplication(
                at: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { [weak self] _, error in
                guard error != nil else {
                    return
                }
                // Launch completions arrive off-main; same re-capture as above.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.openTogglWeb(reason: "Couldn't open Toggl Track — opening the web timer instead.")
                    }
                }
            }
        } else {
            openTogglWeb(reason: "Toggl Track desktop app isn't installed — opening the web timer instead.")
        }
    }

    @objc
    private func togglePause() {
        paused.toggle()
        updateMonitoring() // pausing stops reads too; resuming restarts them
    }

    @objc
    private func snooze(_ sender: NSMenuItem) {
        let seconds = TimeInterval(sender.tag) * Timing.secondsPerMinute
        snoozeUntilUptime = Uptime.now() + seconds
        scheduleSnoozeExpiration(after: seconds)
        evaluateOverlay()
    }

    @objc
    private func cancelSnooze() {
        snoozeUntilUptime = nil
        snoozeTimer?.invalidate()
        snoozeTimer = nil
        evaluateOverlay()
    }

    @objc
    private func chooseStyle(_ sender: NSMenuItem) {
        guard
            let raw = sender.representedObject as? String,
            AlertStyle(rawValue: raw) != nil else {
            return
        }
        config.mutate { $0.alertStyle = raw } // persists to JSON + applies via onChange
    }

    @objc
    private func openConfig() {
        NSWorkspace.shared.open(config.fileURL)
    }

    @objc
    private func toggleFlashTracking() {
        config.mutate { $0.flashWhenTracking.toggle() }
    }

    @objc
    private func toggleFlashNotTracking() {
        config.mutate { $0.flashWhenNotTracking.toggle() }
    }

    @objc
    private func toggleWorkHours() {
        config.mutate { $0.workHoursEnabled.toggle() }
    }

    @objc
    private func toggleRespectDnd() {
        config.mutate { $0.respectDoNotDisturb.toggle() }
    }

    @objc
    private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled:
                try SMAppService.mainApp.unregister()

            case .notRegistered:
                try SMAppService.mainApp.register()
                // register() can land straight in .requiresApproval. Complete the
                // handoff now rather than making the user click a second time to
                // discover the pending status — this mirrors what
                // first-run setup already does.
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }

            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()

            case .notFound:
                NSLog("Untracked: login item service not found")

            @unknown default:
                NSLog("Untracked: unknown login item status")
            }
        } catch {
            NSLog("Untracked: login item toggle failed: \(error)")
        }
    }

    /// #9: turn on Launch at Login once, on first run. The user can disable it
    /// from the menu afterward and we won't re-enable it.
    private func configureLaunchAtLoginOnFirstRun() {
        let key = "initialLoginConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else {
            return
        }
        switch SMAppService.mainApp.status {
        case .enabled:
            UserDefaults.standard.set(true, forKey: key)
            return

        case .requiresApproval:
            // Record first-run setup as done *before* handing off: the automatic
            // prompt fires at most once. If approval is postponed or declined,
            // the menu's Launch at Login item is the retry path — seizing System
            // Settings on every subsequent launch would be hostile.
            UserDefaults.standard.set(true, forKey: key)
            SMAppService.openSystemSettingsLoginItems()
            return

        case .notFound:
            NSLog("Untracked: initial login item service not found")
            return

        case .notRegistered:
            break

        @unknown default:
            NSLog("Untracked: unknown initial login item state")
            return
        }
        do {
            try SMAppService.mainApp.register()
            switch SMAppService.mainApp.status {
            case .enabled:
                UserDefaults.standard.set(true, forKey: key)

            case .requiresApproval:
                // Same rule as the pre-registration branch above: record the
                // one-time setup as done *before* handing off, so a postponed
                // approval doesn't reopen System Settings on every launch.
                UserDefaults.standard.set(true, forKey: key)
                SMAppService.openSystemSettingsLoginItems()

            case .notRegistered, .notFound:
                NSLog("Untracked: initial login item registration did not enable the service")

            @unknown default:
                NSLog("Untracked: unknown initial login item state")
            }
        } catch {
            // Leave the marker unset so a transient registration failure retries
            // automatically on the next launch.
            NSLog("Untracked: initial login item registration failed: \(error)")
        }
    }
}
