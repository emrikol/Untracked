// SPDX-License-Identifier: GPL-2.0-or-later
import CoreServices
import Foundation
import os

private let log = Logger(subsystem: "com.emrikol.Untracked", category: "watcher")

/// What prompted a read, so a dead FSEvents stream can be told from a live one.
internal enum RefreshSource {
    /// FSEvents delivered — the stream is doing its job.
    case event
    /// The 120 s backstop timer fired.
    case fallback
    /// The authoritative read taken when monitoring starts.
    case initial
}

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

    /// Last state handed to `onChange`, owned by `queue`. Kept here rather than
    /// read back from AppDelegate so the check stays inside the type that knows
    /// which path produced the read.
    private var lastEmittedState: TrackingState?
    /// Consecutive state changes the fallback found before FSEvents did.
    private var changesMissedByStream = 0
    /// One miss is a lost race: FSEvents coalesces for `fsEventsLatency` and reads
    /// are throttled to `minInterval`, so the backstop can legitimately win
    /// occasionally. Two in a row is not a race — it's a stream that stopped
    /// delivering, which silently drops detection from ~1 s to ~120 s.
    private static let missedChangeThreshold = 2
    /// Rebuilds attempted in this monitoring generation, reset by `start()`.
    private var streamRestarts = 0
    /// If three fresh streams all go deaf, the problem is not the stream, and
    /// rebuilding a fourth just burns wake-ups on a machine that is already
    /// misbehaving. The 120 s fallback keeps working either way, so the failure
    /// mode of giving up is slow detection — not no detection. A pause or a
    /// work-hours boundary starts a new generation and resets this.
    private static let maxStreamRestarts = 3

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
        streamRestarts = 0

        guard createStreamOnQueue() else {
            // FSEvents is an *accelerator*, not the source of truth. Losing it
            // must not leave us blind until the 120 s fallback, so still take one
            // authoritative read. Note this read is deliberately NOT hoisted
            // above stream setup: on the success path we must register first and
            // read second, or a write landing in between is missed.
            //
            // Logged because the two modes are otherwise indistinguishable from
            // the outside: both deliver state, one just does it up to 120 s
            // late. That ambiguity is exactly what hid the degradation bug.
            log.notice("watcher armed: fallback only (FSEvents unavailable)")
            refreshWithoutStream()
            return
        }
        log.notice("watcher armed: FSEvents + 120s fallback")
        refresh(source: .initial) // after event registration, closing the startup gap
    }

    /// Build and start the FSEvents stream. Returns false if either step failed,
    /// leaving `stream` nil and `isRunning` false.
    ///
    /// Split out of `startOnQueue` because `restartStreamOnQueue` needs exactly
    /// this and nothing else — not the generation bump, not the initial read.
    private func createStreamOnQueue() -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))

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
            return false
        }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return false
        }
        isRunning = true
        return true
    }

    /// Tear the FSEvents stream down and build a fresh one, in place.
    ///
    /// Called only when `noteDelivery` has positive evidence the stream stopped
    /// delivering. This is deliberately different from the documented "a failed
    /// stream *setup* isn't retried" trade-off: there, nothing is known and a
    /// retry would be speculative; here the backstop has caught the stream
    /// missing real changes twice running, so a restart is the response to
    /// measured failure rather than a guess.
    ///
    /// Generations are untouched — this is the same monitoring session with a
    /// new stream, so deliveries already in flight stay valid.
    private func restartStreamOnQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard streamRestarts < Self.maxStreamRestarts else {
            return // give up rather than churn; the fallback still works
        }
        streamRestarts += 1
        let attempt = streamRestarts

        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        isRunning = false

        if createStreamOnQueue() {
            log.notice("FSEvents stream rebuilt (attempt \(attempt, privacy: .public))")
        } else {
            log.notice("FSEvents stream rebuild failed (attempt \(attempt, privacy: .public)); staying on the 120s fallback")
        }
    }

    /// Read once from `queue` without requiring a live stream. Used by the
    /// stream-setup failure paths, which already hold the queue — `refresh()`
    /// would re-dispatch onto it, which is merely redundant here.
    private func refreshWithoutStream() {
        dispatchPrecondition(condition: .onQueue(queue))
        emit(generation: activeGeneration, allowWithoutStream: true)
    }

    /// Backstop re-read (used by the fallback timer in case an event is missed).
    internal func refresh(source: RefreshSource = .fallback) {
        queue.async { [weak self] in
            guard let self else {
                return
            }
            emit(generation: activeGeneration, allowWithoutStream: true, source: source)
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

    private func emit(
        generation: UInt64,
        allowWithoutStream: Bool = false,
        source: RefreshSource = .event
    ) {
        guard
            refreshEnabled, activeGeneration == generation,
            allowWithoutStream || isRunning else {
            return
        }
        let state = store.currentState()
        noteDelivery(state: state, source: source)
        DispatchQueue.main.async { [weak self, onChange] in
            guard let self, deliveryGeneration == generation else {
                return
            }
            onChange(state)
        }
    }

    /// Notice when the backstop, not the stream, is finding the changes.
    ///
    /// A state change surfaced by the fallback is by definition one FSEvents
    /// failed to deliver. The stream can lose an occasional race, so this only
    /// complains once it happens `missedChangeThreshold` times consecutively —
    /// at which point the app is running blind on a 120 s timer while reporting
    /// itself perfectly healthy, which is exactly how this went unnoticed.
    ///
    /// Costs one comparison inside a read that already happened: no timer, no
    /// extra I/O, nothing while idle.
    private func noteDelivery(state: TrackingState, source: RefreshSource) {
        dispatchPrecondition(condition: .onQueue(queue))
        defer { lastEmittedState = state }
        guard let previous = lastEmittedState, state != previous else {
            return // first read of a generation, or nothing changed
        }
        switch source {
        case .event:
            changesMissedByStream = 0 // the stream is delivering

        case .fallback:
            changesMissedByStream += 1
            // Bound to a local: os.Logger interpolation is an autoclosure, so a
            // property read there needs an explicit `self.` — which SwiftFormat's
            // redundantSelf then strips, and the build fails. Don't reintroduce it.
            let missed = changesMissedByStream
            if missed >= Self.missedChangeThreshold {
                log.notice("""
                FSEvents appears dead: the 120s fallback has found \
                \(missed, privacy: .public) consecutive state changes \
                the stream should have delivered first
                """)
                // Reset before restarting, so the next two misses are counted
                // against the *new* stream. Without this the counter stays over
                // threshold and every subsequent fallback read would restart
                // again — a rebuild storm driven by stale evidence.
                changesMissedByStream = 0
                restartStreamOnQueue()
            }

        case .initial:
            break // a start-up read racing the stream proves nothing
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
