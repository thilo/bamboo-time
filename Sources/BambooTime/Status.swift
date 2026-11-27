import Foundation

/// GET /time_tracking/timesheet_entries item: a clock entry (start/end, `end`
/// nil while clocked in) or a manual hour entry (`hours` only).
struct TimesheetEntry: Decodable, Sendable {
    let type: String
    /// Calendar day the entry belongs to, in the entry's timezone (YYYY-MM-DD).
    let date: String
    let start: Date?
    let end: Date?
    let timezone: String?
    let hours: Flex?

    var isClock: Bool { type == "clock" && start != nil }
    var isOpen: Bool { isClock && end == nil }
    var tz: String { timezone ?? TimeZone.current.identifier }

    /// Clock entries: end − start (exact; `hours` is rounded). Hour entries: `hours`.
    func duration(at now: Date) -> TimeInterval {
        guard let start, isClock else { return (hours?.value ?? 0) * 3600 }
        return max(0, (end ?? now).timeIntervalSince(start))
    }
}

struct Summary {
    var open: TimesheetEntry?
    /// Today's closed clock entries, newest first.
    var closed: [TimesheetEntry]
    var total: TimeInterval
    /// Clock and manual hour entries since the start of this week (user's first weekday), plus the open entry.
    var week: TimeInterval
    /// Clock and manual hour entries in the four full weeks before this one.
    var fourWeeks: TimeInterval
}

/// "Today" is evaluated per entry in the entry's own timezone, so a midnight
/// rollover there is handled even if the Mac is in another zone.
func summarize(_ entries: [TimesheetEntry], now: Date) -> Summary {
    let open = entries.first { $0.isOpen }
    let live = open?.duration(at: now) ?? 0
    let closed = entries
        .filter { $0.isClock && !$0.isOpen && $0.date == dayString(now, timeZone: $0.tz) }
        .sorted { $0.start! > $1.start! }
    func start(_ weeksBack: Int, _ e: TimesheetEntry) -> String {
        dayString(weekStart(now, weeksBack: weeksBack, timeZone: e.tz), timeZone: e.tz)
    }
    let week = entries
        .filter { !$0.isOpen && $0.date >= start(0, $0) && $0.date <= dayString(now, timeZone: $0.tz) }
        .reduce(live) { $0 + $1.duration(at: now) }
    let fourWeeks = entries
        .filter { !$0.isOpen && $0.date >= start(4, $0) && $0.date < start(0, $0) }
        .reduce(0) { $0 + $1.duration(at: now) }
    return Summary(open: open, closed: closed, total: closed.reduce(live) { $0 + $1.duration(at: now) },
                   week: week, fourWeeks: fourWeeks)
}

/// Gregorian (the API's `date` format) but with the user's first weekday.
private func calendar(_ id: String) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: id) ?? .current
    cal.firstWeekday = Calendar.current.firstWeekday
    return cal
}

/// YYYY-MM-DD; these strings compare correctly as plain strings.
func dayString(_ date: Date, timeZone id: String) -> String {
    let c = calendar(id).dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
}

/// Start of this week, or of the week `weeksBack` weeks earlier.
func weekStart(_ date: Date, weeksBack: Int = 0, timeZone id: String = TimeZone.current.identifier) -> Date {
    let cal = calendar(id)
    return cal.date(byAdding: .weekOfYear, value: -weeksBack, to: cal.dateInterval(of: .weekOfYear, for: date)!.start)!
}


/// "0h 42m", "4h 00m", "4h 12m": one shape, so the menu bar title keeps its width.
func formatDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded()))
    return String(format: "%dh %02dm", minutes / 60, minutes % 60)
}

/// Menu rows: "23m", "4h 17m", "4h  5m". A single-digit minute gets a figure space (digit width), so
/// right-aligned durations keep their h and m in one column.
func formatRowDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int((seconds / 60).rounded()))
    let m = (minutes % 60 < 10 ? "\u{2007}" : "") + "\(minutes % 60)m"
    return minutes < 60 ? m : "\(minutes / 60)h \(m)"
}

func formatTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

/// GET /time_off/requests item; `dates` maps YYYY-MM-DD → amount in `amount.unit`.
struct TimeOffRequest: Decodable, Sendable {
    struct Amount: Decodable, Sendable { let unit: String }
    let amount: Amount
    let dates: [String: Flex]?
}

/// GET /meta/time_off/types; `defaultHours` = company hours per weekday ("Monday": "8").
struct TimeOffTypes: Decodable, Sendable {
    struct Day: Decodable, Sendable { let name: String; let amount: Flex }
    let defaultHours: [Day]
    var hoursPerDay: [String: Double] { Dictionary(defaultHours.map { ($0.name, $0.amount.value) }) { a, _ in a } }
}

/// A number BambooHR may send as JSON number or string ("8").
struct Flex: Decodable, Sendable {
    let value: Double
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { value = d; return }
        value = Double(try c.decode(String.self)) ?? 0
    }
}

/// Approved time off on days `from...to` (YYYY-MM-DD). Day-based time off is
/// converted with the company's hours for that weekday, as BambooHR's own
/// weekly total does.
func timeOffTime(_ timeOff: [TimeOffRequest], from: String, to: String, hoursPerDay: [String: Double]) -> TimeInterval {
    timeOff.reduce(0.0) { sum, request in
        (request.dates ?? [:]).filter { $0.key >= from && $0.key <= to }.reduce(sum) { sum, day in
            let factor = request.amount.unit == "days" ? hoursPerDay[weekdayName(day.key) ?? ""] ?? 0 : 1
            return sum + day.value.value * factor * 3600
        }
    }
}

/// "2026-11-02" → "Monday" (English, matching `defaultHours[].name`).
func weekdayName(_ day: String) -> String? {
    guard let date = try? Date(day, strategy: .iso8601.year().month().day()) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .gmt
    cal.locale = Locale(identifier: "en_US_POSIX")
    return cal.weekdaySymbols[cal.component(.weekday, from: date) - 1]
}

let bambooDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601  // live format: 2026-11-06T07:43:00+00:00
    return d
}()
