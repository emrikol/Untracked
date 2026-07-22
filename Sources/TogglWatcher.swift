import CoreServices
import Foundation

/// Event-driven watcher for Toggl's local store. Instead of polling on a timer,
/// it uses FSEvents to wake only when Toggl actually writes to its database
/// (i.e. when you start/stop/edit a timer). Between those writes the app does
/// zero work.
///
/// Toggl rewrites its WAL frequently (roughly once/second while a timer runs),
/// so on top of FSEvents' `latency` coalescing we throttle to at most one read
/// per `minInterval` (leading + trailing), so a chatty writer can't make us
/// re-read in a tight loop.
/// Thread confinement: every mutable field below is owned by `queue`, except
/// `deliveryGeneration`, which is main-thread only. That discipline is what makes
/// this safe, and it's why the type is `@unchecked Sendable` rather than an
/// `actor` — an actor would force the entire call chain async for no behavioural
/// gain. **If you add state here, say which thread owns it.**
internal final class TogglWatcher: @unchecked Sendable {
    private let store = TogglLocalStore()
    private let onChange: @Sendable (TrackingState) -> Void
    private let queue = DispatchQueue(label: "com.emrikol.Untracked.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    private let minInterval: TimeInterval = 3.0 // at most one read per this window
    /// FSEvents coalescing window. Toggl rewrites its WAL ~1x/sec, so letting the
    /// OS batch that burst costs us nothing and saves a pile of wake-ups.
    private static let fsEventsLatency: CFTimeInterval = 2.0
    /// Monotonic uptime of the last admitted read (see `Uptime` — civil `Date`
    /// math here let a clock rollback defer event reads for hours). Nil = never.
    private var lastRead: TimeInterval?
    private var trailingScheduled = false
    private var isRunning = false
    /// Monitoring may remain enabled when the optional FSEvents stream fails.
    private var refreshEnabled = false
    private var activeGeneration: UInt64 = 0
    /// Accessed only by callers and delivery closures on the main thread.
    private var deliveryGeneration: UInt64 = 0

    /// Directory holding DatabaseModel.sqlite (+ -wal/-shm).
    private let watchDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/B227VTMZ94.group.com.toggl.daneel.extensions/production")
        .path

    internal init(onChange: @escaping @Sendable (TrackingState) -> Void) {
        self.onChange = onChange
    }

    deinit {
        // The FSEvents context above holds an *unretained* pointer to self, so a
        // stream outliving this object would call back into freed memory. Nothing
        // guarantees stop() was called first — today AppDelegate happens to, but
        // that is incidental, and it would not survive this type being recreated
        // or instantiated anywhere else.
        //
        // Torn down directly rather than via stop(): stop() hops onto `queue`, and
        // if the final release happens inside a block already running there,
        // queue.sync would deadlock. At deinit no other reference to self exists,
        // so touching `stream` without the queue is safe by definition.
        guard let stream else {
            return
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    internal func start() {
        guard !queue.sync(execute: { refreshEnabled }) else {
            return
        }
        deliveryGeneration &+= 1
        let generation = deliveryGeneration
        queue.sync { startOnQueue(generation: generation) }
    }

    private func startOnQueue(generation: UInt64) {
        dispatchPrecondition(condition: .onQueue(queue))
        refreshEnabled = true
        activeGeneration = generation

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else {
                return
            }
            Unmanaged<TogglWatcher>.fromOpaque(info).takeUnretainedValue().throttledEmit()
        }
        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [watchDir] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.fsEventsLatency, // coalesces the WAL write burst
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
            ) else {
            // FSEvents is an *accelerator*, not the source of truth. Losing it
            // must not leave us blind until the 120 s fallback, so still take one
            // authoritative read. Note this read is deliberately NOT
            // hoisted above stream setup: on the success path we must register
            // first and read second, or a write landing in between is missed.
            refreshWithoutStream()
            return
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            refreshWithoutStream() // same reasoning as the create failure above
            return
        }
        isRunning = true
        refresh() // initial read, after event registration closes the startup gap
    }

    /// Read once from `queue` without requiring a live stream. Used by the
    /// stream-setup failure paths, which already hold the queue — `refresh()`
    /// would re-dispatch onto it, which is merely redundant here.
    private func refreshWithoutStream() {
        dispatchPrecondition(condition: .onQueue(queue))
        emit(generation: activeGeneration, allowWithoutStream: true)
    }

    /// Backstop re-read (used by the fallback timer in case an event is missed).
    internal func refresh() {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            emit(generation: activeGeneration, allowWithoutStream: true)
        }
    }

    /// Leading + trailing throttle, all on `queue`. First event reads immediately;
    /// further events inside the window schedule a single trailing read so we
    /// still capture the final state, but never more than once per `minInterval`.
    private func throttledEmit() {
        let now = Uptime.now()
        // Monotonic, so `elapsed` can never go negative and the trailing deadline
        // below stays bounded by `minInterval` even across a wall-clock change.
        let elapsed = lastRead.map { now - $0 } ?? .infinity
        if elapsed >= minInterval {
            lastRead = now
            emit(generation: activeGeneration)
        } else if !trailingScheduled {
            trailingScheduled = true
            let generation = activeGeneration
            queue.asyncAfter(deadline: .now() + (minInterval - elapsed)) { [weak self] in
                guard let self, isRunning, activeGeneration == generation else {
                    return
                }
                trailingScheduled = false
                lastRead = Uptime.now()
                emit(generation: generation)
            }
        }
    }

    private func emit(generation: UInt64, allowWithoutStream: Bool = false) {
        guard
            refreshEnabled, activeGeneration == generation,
            allowWithoutStream || isRunning else {
            return
        }
        let state = store.currentState()
        DispatchQueue.main.async { [weak self, onChange] in
            guard let self, deliveryGeneration == generation else {
                return
            }
            onChange(state)
        }
    }

    internal func stop() {
        deliveryGeneration &+= 1 // invalidate already-queued main-thread deliveries
        queue.sync {
            activeGeneration &+= 1
            refreshEnabled = false
            isRunning = false
            trailingScheduled = false
            guard let stream else {
                return
            }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}
