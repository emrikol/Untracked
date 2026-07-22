// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Loads, persists, and hot-reloads `~/.untracked.json`. The watcher is a
/// kqueue `DispatchSource` (event-driven, no polling — zero cost when idle). It
/// re-arms on every event so atomic-save (write-temp-then-rename, which most
/// editors do) is handled by re-opening the new inode.
/// Thread confinement: `settings` is written on the main thread (via `start`,
/// `mutate`, and the reload hop) and read from it; `queue` only carries kqueue
/// events and the coalescing work item. `@unchecked Sendable` for the same
/// reason as `TogglWatcher` — deliberate confinement, not an escape hatch.
internal final class ConfigStore: @unchecked Sendable {
    internal let fileURL: URL

    internal private(set) var settings = Settings.defaults
    internal var onChange: (@Sendable (Settings) -> Void)?

    private let queue = DispatchQueue(label: "com.emrikol.Untracked.config", qos: .utility)
    /// Bounded re-selection when an atomic save unlinks the inode mid-arm.
    private static let maxWatchArmAttempts = 4
    /// Coalesce an editor's write burst into one reload.
    private static let reloadCoalesceDelay: TimeInterval = 0.25
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    internal init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".untracked.json")) {
        self.fileURL = fileURL
    }

    deinit {
        // Nothing ever calls a stop() on this type — it lives for the process —
        // so deinit is the only release path if that ever changes. The source
        // holds an open file descriptor; the work item holds a strong closure.
        pending?.cancel()
        source?.cancel()
    }

    internal func start() {
        ensureFileExists()
        beginWatching(notifyChanges: false)
        notify() // initial apply
    }

    /// Mutate, persist, and apply immediately (used by menu actions).
    @discardableResult
    internal func mutate(_ change: (inout Settings) -> Void) -> Bool {
        var updated = settings
        change(&updated)
        guard updated != settings else {
            return true
        }
        do {
            try write(updated)
        } catch {
            NSLog("Untracked: config write failed: \(error)")
            return false
        }
        settings = updated // commit live state only after durable atomic replacement
        notify()
        return true
    }

    private func notify() {
        let snapshot = settings
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }

    // MARK: File I/O

    private func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            try write(.defaults)
        } catch {
            NSLog("Untracked: couldn't create default config: \(error)")
        }
    }

    private func write(_ settings: Settings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: fileURL, options: .atomic)
    }

    @discardableResult
    private func reload() -> Bool {
        guard
            let data = try? Data(contentsOf: fileURL),
            let loaded = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            return false // malformed/transient reads retain last-known-good settings
        }
        guard loaded != settings else {
            return false
        }
        settings = loaded
        return true
    }

    // MARK: kqueue watch

    private func beginWatching(notifyChanges: Bool = true) {
        stopWatching()
        // Selecting a target and opening it are separate syscalls, and an
        // editor's atomic save (write-temp-then-rename) is precisely what
        // unlinks the selected inode in between. A single failed open must not
        // leave hot-reload permanently unarmed, so re-evaluate which
        // path exists and try again — a racing replace settles in an iteration
        // or two, and the home directory always opens. Bounded and still fully
        // event-driven; deliberately not a retry timer.
        var descriptor: Int32 = -1
        for _ in 0 ..< Self.maxWatchArmAttempts {
            guard let target = nearestExistingWatchTarget() else {
                break
            }
            descriptor = open(target.path, O_EVTONLY)
            if descriptor >= 0 {
                break
            }
        }
        guard descriptor >= 0 else {
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: queue
        )
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(descriptor) }
        source = src
        src.resume()
        // Close the snapshot-registration interval: an atomic rename between the
        // prior read and source activation is captured by this compensating read.
        let changed = reload()
        if notifyChanges, changed {
            notify()
        }
    }

    /// Observe the config inode when present, otherwise the nearest existing
    /// ancestor. An ancestor event re-enters `beginWatching`, walking closer to
    /// the file until a late-created path can be watched directly.
    private func nearestExistingWatchTarget() -> URL? {
        var target = fileURL
        while !FileManager.default.fileExists(atPath: target.path) {
            let parent = target.deletingLastPathComponent()
            guard parent.path != target.path else {
                return nil
            }
            target = parent
        }
        return target
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }

    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            DispatchQueue.main.async {
                self.ensureFileExists()
                self.beginWatching() // re-arm first, then compensating reload
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.reloadCoalesceDelay, execute: work) // coalesce write bursts
    }
}
