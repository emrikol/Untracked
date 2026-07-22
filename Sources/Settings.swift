import AppKit
import Foundation

// swiftlint:disable redundant_type_annotation - wire format, see below
/// User-tunable settings, persisted as `~/.untracked.json`. Every field has
/// a default and may be overridden individually — missing/unknown keys fall back
/// to defaults, so a partial file is fine.
///
/// The type annotations below are deliberate despite being redundant for most fields.
/// This struct *is* the on-disk JSON schema, so every property states its type
/// explicitly and consistently. Note that `borderThickness: Double = 10` and
/// `gracePeriodSeconds: Double = 45` are not redundant at all — dropping the
/// annotation would infer `Int` and silently change the field's type. Keeping
/// the whole struct annotated means no one has to notice which is which.
internal struct Settings: Codable, Equatable {
    internal var alertStyle: String = "menuBar" // "border" | "menuBar" | "both"
    internal var flashWhenTracking: Bool = true // green heartbeat while a timer IS running
    internal var flashWhenNotTracking: Bool = true // red heartbeat while NOT tracking (the nag)
    internal var trackingColorHex: String = "#34C759" // green
    internal var notTrackingColorHex: String = "#FF3B30" // red
    internal var beatPeriodSeconds: Double = 8.0 // seconds between heartbeats
    internal var borderThickness: Double = 10 // px, for the "border" style
    internal var gracePeriodSeconds: Double = 45 // wait this long after a timer stops before nagging
    internal var respectDoNotDisturb: Bool = true // suppress the nag while a Focus/DnD is active
    internal var workHoursEnabled: Bool = false // if true, only nag during workDays/workHours
    internal var workDays: String = "MTWRF" // M T W R(Thu) F S(Sat) U(Sun)
    internal var workHours: String = "09:00-17:00" // local time, "HH:MM-HH:MM"

    internal static let defaults = Self()
    // swiftlint:enable redundant_type_annotation

    /// These raw values *are* the JSON keys in `~/.untracked.json`, so they
    /// are spelled out rather than inferred from the case names. Renaming a
    /// property must not silently stop reading a key users already have on disk.
    internal enum CodingKeys: String, CodingKey {
        case alertStyle = "alertStyle"
        case flashWhenTracking = "flashWhenTracking"
        case flashWhenNotTracking = "flashWhenNotTracking"
        case trackingColorHex = "trackingColor"
        case notTrackingColorHex = "notTrackingColor"
        case beatPeriodSeconds = "beatPeriodSeconds"
        case borderThickness = "borderThickness"
        case gracePeriodSeconds = "gracePeriodSeconds"
        case respectDoNotDisturb = "respectDoNotDisturb"
        case workHoursEnabled = "workHoursEnabled"
        case workDays = "workDays"
        case workHours = "workHours"
    }

    /// Derived, validated views (fall back to a sane color if the hex is garbage).
    internal var style: AlertStyle {
        AlertStyle(rawValue: alertStyle) ?? .menuBar
    }

    internal var trackingColor: NSColor {
        NSColor(hex: trackingColorHex) ?? .systemGreen
    }

    internal var notTrackingColor: NSColor {
        NSColor(hex: notTrackingColorHex) ?? .systemRed
    }

    /// Indexed by `Calendar`'s weekday number (1 = Sunday … 7 = Saturday), so the
    /// string is ordered to match rather than carrying seven numeric literals.
    private static let weekdayLetters = Array("UMTWRFS")
    private static let daysPerWeek = 7
    private static let minutesPerHour = 60
    private static let validHours = 0 ... 23
    private static let validMinutes = 0 ... 59
    /// A range's grammar is exactly "HH:MM-HH:MM": two components, or four digits
    /// in the compact "HHMM" form.
    private static let rangeComponentCount = 2
    private static let compactTimeDigits = 4
    /// "HHMM" splits evenly into two-digit hour and minute halves.
    private static let compactTimeHalf = 2
    /// Scan a little over a week: enough to cross any weekly work-hours pattern.
    private static let transitionSearchDays = 8
    /// Sanity clamps for values that arrive from a hand-edited JSON file. Out of
    /// range falls back to the default rather than being trusted.
    private static let beatPeriodRange = 1.0 ... 3_600.0
    private static let thicknessRange = 1.0 ... 200.0
    private static let graceRange = 0.0 ... 86_400.0

    /// Valid single-letter work-day codes actually present in `workDays`.
    private var validWorkdayLetters: Set<Character> {
        let allowed = Set<Character>(["U", "M", "T", "W", "R", "F", "S"])
        let supplied = Set(workDays.uppercased())
        guard !supplied.isEmpty, supplied.isSubset(of: allowed) else {
            return []
        }
        return supplied
    }

    private func isWorkday(_ weekday: Int) -> Bool {
        guard weekday >= 1, weekday <= Self.daysPerWeek else {
            return false
        }
        let letter = Self.weekdayLetters[weekday - 1]
        return validWorkdayLetters.contains(letter)
    }

    /// Whether nagging is permitted at `now` given the work-hours setting.
    /// Disabled → always true. A misconfigured window (unparseable hours or no
    /// valid work days) also fails **open** → true, so a typo can never silently
    /// lock the app off. System local timezone.
    internal func nagAllowedNow(_ now: Date = Date()) -> Bool {
        guard workHoursEnabled else {
            return true
        }
        guard let (start, end) = Self.parseRange(workHours), !validWorkdayLetters.isEmpty else {
            return true
        }
        let cal = Calendar.current
        let comps = cal.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = comps.weekday else {
            return false
        }
        let mins = (comps.hour ?? 0) * Self.minutesPerHour + (comps.minute ?? 0)

        if start <= end { // same-day window
            return isWorkday(weekday) && mins >= start && mins < end
        }
        // Overnight window (e.g. 22:00–06:00) belongs to its START day: the
        // evening part [start, 24:00) counts if today is a work day; the morning
        // part [0, end) counts if *yesterday* was a work day.
        let yesterday = weekday == 1 ? Self.daysPerWeek : weekday - 1
        return (mins >= start && isWorkday(weekday)) || (mins < end && isWorkday(yesterday))
    }

    /// The next moment `nagAllowedNow` flips, so a single dated timer can be
    /// scheduled instead of polling. Nil when work-hours is off or misconfigured
    /// (nagAllowedNow is then constant → no boundary needed). Works for same-day
    /// *and* overnight windows: it scans the only times the predicate can change
    /// — each day's start, end, and midnight (the day-of-week boundary) — and
    /// returns the first where the value actually flips.
    internal func nextWorkHoursTransition(after date: Date) -> Date? {
        guard
            workHoursEnabled, let (startMins, endMins) = Self.parseRange(workHours),
            !validWorkdayLetters.isEmpty else {
            return nil
        }
        let cal = Calendar.current
        let current = nagAllowedNow(date)
        let candidateMinutes = Set([0, startMins, endMins])
        var soonest: Date?
        for offset in 0 ... Self.transitionSearchDays {
            guard let day = cal.date(byAdding: .day, value: offset, to: date) else {
                continue
            }
            for mins in candidateMinutes {
                var times = Set<Date>()
                if
                    let t = cal.date(
                        bySettingHour: mins / Self.minutesPerHour,
                        minute: mins % Self.minutesPerHour,
                        second: 0,
                        of: day
                    ) {
                    times.insert(t)
                }
                // `date(bySettingHour:)` chooses the first occurrence of an
                // ambiguous fall-back time. Include the repeated occurrence too.
                let anchor = cal.startOfDay(for: day).addingTimeInterval(-1)
                let components = DateComponents(hour: mins / Self.minutesPerHour, minute: mins % Self.minutesPerHour, second: 0)
                if
                    let repeated = cal.nextDate(
                        after: anchor,
                        matching: components,
                        matchingPolicy: .strict,
                        repeatedTimePolicy: .last,
                        direction: .forward
                    ),
                    cal.isDate(repeated, inSameDayAs: day) {
                    times.insert(repeated)
                }
                for t in times where t > date && nagAllowedNow(t) != current {
                    soonest = soonest.map { Swift.min($0, t) } ?? t
                }
            }
        }
        return soonest
    }

    private static func parseRange(_ s: String) -> (Int, Int)? {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == Self.rangeComponentCount, let a = parseHM(parts[0]), let b = parseHM(parts[1]) else {
            return nil
        }
        guard a != b else {
            return nil
        } // ambiguous empty/full-day range: fail open
        return (a, b)
    }

    private static func parseHM(_ raw: Substring) -> Int? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.contains(":") {
            let p = t.split(separator: ":", omittingEmptySubsequences: false)
            guard
                p.count == Self.rangeComponentCount, let h = Int(p[0]), let m = Int(p[1]),
                validHours.contains(h), validMinutes.contains(m) else {
                return nil
            }
            return h * Self.minutesPerHour + m
        }
        if
            t.count == Self.compactTimeDigits, let h = Int(t.prefix(Self.compactTimeHalf)),
            let m = Int(t.suffix(Self.compactTimeHalf)),
            validHours.contains(h), validMinutes.contains(m) {
            return h * Self.minutesPerHour + m
        }
        return nil
    }
}

extension Settings {
    /// Lenient decode: any absent key keeps its default value.
    internal init(from decoder: Decoder) throws {
        self.init() // start from defaults
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alertStyle = try c.decodeIfPresent(String.self, forKey: .alertStyle) ?? alertStyle
        flashWhenTracking = try c.decodeIfPresent(Bool.self, forKey: .flashWhenTracking) ?? flashWhenTracking
        flashWhenNotTracking = try c.decodeIfPresent(Bool.self, forKey: .flashWhenNotTracking) ?? flashWhenNotTracking
        trackingColorHex = try c.decodeIfPresent(String.self, forKey: .trackingColorHex) ?? trackingColorHex
        notTrackingColorHex = try c.decodeIfPresent(String.self, forKey: .notTrackingColorHex) ?? notTrackingColorHex
        let decodedBeat = try c.decodeIfPresent(Double.self, forKey: .beatPeriodSeconds) ?? beatPeriodSeconds
        beatPeriodSeconds = decodedBeat.isFinite && Self.beatPeriodRange.contains(decodedBeat)
            ? decodedBeat : Self.defaults.beatPeriodSeconds
        let decodedThickness = try c.decodeIfPresent(Double.self, forKey: .borderThickness) ?? borderThickness
        borderThickness = decodedThickness.isFinite && Self.thicknessRange.contains(decodedThickness)
            ? decodedThickness : Self.defaults.borderThickness
        let decodedGrace = try c.decodeIfPresent(Double.self, forKey: .gracePeriodSeconds) ?? gracePeriodSeconds
        gracePeriodSeconds = decodedGrace.isFinite && Self.graceRange.contains(decodedGrace)
            ? decodedGrace : Self.defaults.gracePeriodSeconds
        respectDoNotDisturb = try c.decodeIfPresent(Bool.self, forKey: .respectDoNotDisturb) ?? respectDoNotDisturb
        workHoursEnabled = try c.decodeIfPresent(Bool.self, forKey: .workHoursEnabled) ?? workHoursEnabled
        workDays = try c.decodeIfPresent(String.self, forKey: .workDays) ?? workDays
        workHours = try c.decodeIfPresent(String.self, forKey: .workHours) ?? workHours
    }
}

// swiftlint:disable no_magic_numbers - the literals below *are* the #RRGGBBAA
// format specification: byte offsets, a byte mask, and the 0-255 channel scale.
// Naming them (`bitsPerByte * 3`) would obscure the format rather than explain
// it, which is the opposite of what the rule exists for.
extension NSColor {
    /// Parse "#RRGGBB" or "#RRGGBBAA" (with or without leading #).
    internal convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
        }
        // UInt64(_:radix:) accepts a leading sign, so "+12345" would parse as
        // 0x12345 and its six-character length would silently select the RGB
        // branch. Require exactly six or eight hex digits and nothing else.
        guard
            s.count == 6 || s.count == 8, s.allSatisfy(\.isHexDigit),
            let value = UInt64(s, radix: 16)
        else {
            return nil
        }
        let r, g, b, a: CGFloat
        switch s.count {
        case 6:
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1

        case 8:
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255

        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

// swiftlint:enable no_magic_numbers
