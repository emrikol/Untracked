import AppKit
import Foundation

/// Tracks conditions under which the nag should be suppressed:
///   • user away  — screen locked, display asleep, or session switched out
///   • Focus/DnD  — a Focus mode is active (best-effort, see note below)
/// `onChange` fires whenever any of these flip so the overlay can re-evaluate.
///
/// Away detection uses proper notifications (rock-solid). Focus has no public
/// API, so it's read heuristically from `~/Library/DoNotDisturb/DB/Assertions.json`
/// (watched via kqueue) and **fails open** — if it can't be read/parsed we report
/// "not in Focus" so the nag still works.
/// Thread confinement: all state is main-thread owned. `focusQueue` only carries
/// kqueue events, which hop straight back to main before touching anything.
/// `@unchecked Sendable` for the same reason as `TogglWatcher` — the confinement
/// is real and deliberate; an actor would buy nothing here.
internal final class SuppressionMonitor: @unchecked Sendable {
    internal var onChange: (@Sendable () -> Void)?

    private var screenLocked = false
    private var displayAsleep = false
    private var sessionInactive = false
    internal private(set) var focusActive = false

    internal var isAway: Bool {
        screenLocked || displayAsleep || sessionInactive
    }

    private let focusFile: URL
    private let focusQueue = DispatchQueue(label: "com.emrikol.Untracked.focus", qos: .utility)
    private var focusSource: DispatchSourceFileSystemObject?
    private var running = false
    private var generation: UInt64 = 0
    /// True only while `Assertions.json` is absent and we're temporarily watching
    /// its parent directory waiting for it to appear (see `armFocusWatch`).
    private var watchingDirectoryFallback = false

    internal init(focusFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")) {
        self.focusFile = focusFile
    }

    deinit {
        // Observers are registered against `self` by selector; a live registration
        // outliving this object is exactly the classic notification crash. The
        // kqueue source likewise holds an open descriptor until cancelled.
        focusSource?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
    }

    /// Idempotent. Started only while we're actively monitoring (see
    /// `updateMonitoring`), so nothing reacts to lock/Focus events while off-duty.
    internal func start() {
        guard !running else {
            return
        }
        running = true
        generation &+= 1

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self,
            selector: #selector(onDisplaySleep),
            name: NSWorkspace.screensDidSleepNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(onDisplayWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(onSessionResign),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspace.addObserver(
            self,
            selector: #selector(onSessionActive),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            self,
            selector: #selector(onScreenLocked),
            name: .init("com.apple.screenIsLocked"),
            object: nil
        )
        distributed.addObserver(
            self,
            selector: #selector(onScreenUnlocked),
            name: .init("com.apple.screenIsUnlocked"),
            object: nil
        )

        readAwayState()
        armFocusWatch(generation: generation)
    }

    internal func stop() {
        guard running else {
            return
        }
        running = false
        generation &+= 1 // invalidate queued reads, retries, and event deliveries
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        focusSource?.cancel()
        focusSource = nil
        // Reset to "present / no Focus" so stale state can't linger into a resume.
        screenLocked = false; displayAsleep = false; sessionInactive = false; focusActive = false
    }

    // MARK: Away

    /// Establish current state before the first overlay evaluation. Notifications
    /// cover later edges, but transitions that happened while stopped need a
    /// synchronous snapshot when a new monitoring generation starts.
    private func readAwayState() {
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            screenLocked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
            if let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool {
                sessionInactive = !onConsole
            }
        }
        displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    @objc
    private func onDisplaySleep() {
        set(\.displayAsleep, true)
    }

    @objc
    private func onDisplayWake() {
        set(\.displayAsleep, false)
    }

    @objc
    private func onSessionResign() {
        set(\.sessionInactive, true)
    }

    @objc
    private func onSessionActive() {
        set(\.sessionInactive, false)
    }

    @objc
    private func onScreenLocked() {
        set(\.screenLocked, true)
    }

    @objc
    private func onScreenUnlocked() {
        set(\.screenLocked, false)
    }

    private func set(_ keyPath: ReferenceWritableKeyPath<SuppressionMonitor, Bool>, _ value: Bool) {
        guard self[keyPath: keyPath] != value else {
            return
        }
        self[keyPath: keyPath] = value
        notify()
    }

    private func notify() {
        DispatchQueue.main.async { [weak self] in self?.onChange?() }
    }

    // MARK: Focus / DnD (best-effort, fail-open)

    private func readFocus() {
        let active = Self.focusIsActive(file: focusFile)
        setFocus(active)
    }

    private func setFocus(_ active: Bool) {
        guard active != focusActive else {
            return
        }
        focusActive = active
        notify()
    }

    /// Active iff the assertions file holds a non-empty `storeAssertionRecords`
    /// (an active Focus). Absent/empty/unreadable → not active.
    private static func focusIsActive(file: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: file),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["data"] as? [[String: Any]] else {
            return false
        }
        for entry in entries {
            if let records = entry["storeAssertionRecords"] as? [Any], !records.isEmpty {
                return true
            }
        }
        return false
    }

    /// Arm the Focus watch, preferring to watch the `Assertions.json` *inode*
    /// directly and only falling back to its parent directory while the file is
    /// absent. Re-arm from the event handler to follow atomic replacements.
    ///
    /// Why inode-first (energy — the project's top priority):
    /// `~/Library/DoNotDisturb/DB/` is a busy directory — iCloud writes
    /// `AssertionSyncMetadata.plist`/`SyncEngineMetadata.plist`, the OS writes
    /// `Metrics.json`, `IconCache/`, `Settings.sqlite-*`, none of which touch
    /// Focus. Watching the directory in steady state would wake us on all of that
    /// churn just to re-read a file that didn't change. Watching the inode wakes
    /// us *only* when `Assertions.json` itself changes. An earlier revision
    /// watched the directory unconditionally (plus a bounded retry timer) to cover
    /// the file being absent at startup — but that traded ongoing energy for a
    /// rare edge, and the retry timer was effectively dead code (the DB directory
    /// is a system dir that always exists). Don't reintroduce a directory watch or
    /// a poll/retry timer here — the parent-dir fallback below covers "absent"
    /// event-drivenly, and Focus-unavailable already fails open (nag anyway).
    ///
    /// Why re-arm on every event: macOS rewrites `Assertions.json` atomically
    /// (write-temp-then-rename), which swaps the inode out from under our fd — so
    /// a plain inode watch goes deaf after the first change unless we re-open the
    /// path. The compensating `readFocus()` *after* `resume()` closes the window
    /// where a replace could land between our existence check and the source going
    /// live, mirroring `ConfigStore.beginWatching`.
    private func armFocusWatch(generation expectedGeneration: UInt64) {
        guard running, generation == expectedGeneration else {
            return
        }
        focusSource?.cancel()
        focusSource = nil

        // Watch the file if it exists; otherwise watch the parent dir (which the
        // OS guarantees) just until the file appears, then switch back.
        //
        // `fileExists` → `open` is NOT atomic, and atomic replacement is exactly
        // how macOS updates this file — the inode we just saw can be unlinked
        // before we get to open it. Treat a failed *file* open as "absent" and
        // fall through to the parent instead of returning unarmed; otherwise a
        // single unlucky interleave leaves this monitoring generation
        // permanently deaf to Focus changes. Still event-driven: the
        // parent watch fires when the replacement lands and re-arms onto it.
        var useDirectory = !FileManager.default.fileExists(atPath: focusFile.path)
        var descriptor = useDirectory ? -1 : open(focusFile.path, O_EVTONLY)
        if descriptor < 0 {
            useDirectory = true
            descriptor = open(focusFile.deletingLastPathComponent().path, O_EVTONLY)
        }
        watchingDirectoryFallback = useDirectory
        guard descriptor >= 0 else {
            // Even the parent dir wouldn't open — shouldn't happen (system dir).
            // Fail open and stop: no retry timer (the project forbids speculative
            // polling). The next monitoring re-gate calls start() → re-arms.
            readFocus()
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: focusQueue
        )
        src.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            DispatchQueue.main.async {
                guard self.running, self.generation == expectedGeneration else {
                    return
                }
                // In the directory fallback, ignore churn from sibling sync/metrics
                // files — only re-arm (onto the inode) once our file appears.
                if
                    self.watchingDirectoryFallback,
                    !FileManager.default.fileExists(atPath: self.focusFile.path) {
                    return
                }
                self.armFocusWatch(generation: expectedGeneration)
            }
        }
        src.setCancelHandler { close(descriptor) }
        focusSource = src
        src.resume()
        // Compensating post-activation read (see re-arm note above).
        readFocus()
    }
}
