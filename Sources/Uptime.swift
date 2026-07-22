import Foundation

/// Monotonic elapsed time, for measuring **durations**.
///
/// Never use `Date`/`timeIntervalSince` to measure how long something has been
/// true. `Date` is the civil clock: NTP, a manual change, or an administrative
/// correction can move it *backwards*, which turns a small positive duration
/// into a large negative one. Both places that got this wrong computed a delay
/// as `interval - elapsed`, so a one-hour rollback pushed a 3-second throttle
/// out to 3603 s and a 45-second grace period out to 3645 s — the app went
/// quiet for an hour. This app explicitly observes `NSSystemClockDidChange`,
/// so clock corrections are a normal, expected input, not a theoretical one.
///
/// `uptimeNanoseconds` is immune to civil-clock changes. It does not advance
/// while the machine is asleep, which is the behaviour we want here: after a
/// long sleep we'd rather re-evaluate promptly than believe hours "elapsed".
/// Wake notifications and the 120 s fallback cover that path anyway.
///
/// Keep the wall-clock `Date` alongside this when the value is *displayed*
/// (e.g. "not tracking for 12m") — that genuinely is a civil-time question.
internal enum Uptime {
    private static let nanosecondsPerSecond: TimeInterval = 1_000_000_000

    /// Seconds since boot, excluding sleep. Only meaningful when subtracted
    /// from another `Uptime.now()`.
    internal static func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / nanosecondsPerSecond
    }
}
