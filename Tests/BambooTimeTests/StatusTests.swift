import Foundation
import Testing
@testable import BambooTime

private func iso(_ s: String) -> Date { try! Date.ISO8601FormatStyle().parse(s) }

private func entry(_ date: String, _ start: String, _ end: String?, tz: String = "Europe/Berlin") -> TimesheetEntry {
    TimesheetEntry(type: "clock", date: date, start: iso(start), end: end.map(iso), timezone: tz, hours: nil)
}

private func decode<T: Decodable>(_ json: String) throws -> T { try bambooDecoder.decode(T.self, from: Data(json.utf8)) }

@Test func emptyDay() {
    let s = summarize([], now: iso("2026-11-06T12:00:00Z"))
    #expect(s.open == nil && s.closed.isEmpty && s.total == 0)
}

@Test func closedAndOpenEntriesToday() {
    let now = iso("2026-11-06T13:00:00Z")
    let s = summarize([
        entry("2026-11-06", "2026-11-06T12:00:00Z", nil),
        entry("2026-11-06", "2026-11-06T08:00:00Z", "2026-11-06T10:00:00Z"),
        entry("2026-11-05", "2026-11-05T08:00:00Z", "2026-11-05T16:00:00Z"),  // yesterday: excluded
    ], now: now)
    #expect(s.open != nil)
    #expect(s.closed.count == 1)
    #expect(s.total == 3 * 3600)
}

@Test func openEntryFromYesterdayStillClockedIn() {
    let s = summarize([entry("2026-11-05", "2026-11-05T22:00:00Z", nil)], now: iso("2026-11-06T01:00:00Z"))
    #expect(s.open != nil)
    #expect(s.total == 3 * 3600)
}

@Test func todayIsEvaluatedInEntryTimezone() {
    // 05:00Z on Nov 7 is still Nov 6 in Los Angeles, but already Nov 7 in Berlin.
    let now = iso("2026-11-07T05:00:00Z")
    let la = entry("2026-11-06", "2026-11-06T20:00:00Z", "2026-11-06T21:00:00Z", tz: "America/Los_Angeles")
    let berlin = entry("2026-11-06", "2026-11-06T20:00:00Z", "2026-11-06T21:00:00Z", tz: "Europe/Berlin")
    #expect(summarize([la], now: now).closed.count == 1)
    #expect(summarize([berlin], now: now).closed.isEmpty)
}

@Test func weekTotalSpansThisWeekOnly() throws {
    // Fri 2026-11-06. Wed Nov 4 is in this week whether weeks start Sunday or Monday; Fri Oct 30 is not.
    let now = iso("2026-11-06T13:00:00Z")
    let manual: [TimesheetEntry] = try decode(#"[{"type": "hour", "date": "2026-11-03", "start": null, "end": null, "timezone": null, "hours": 1.5}, {"type": "hour", "date": "2026-10-30", "hours": 4}]"#)
    let s = summarize([
        entry("2026-11-06", "2026-11-06T12:00:00Z", nil),                        // live: 1h
        entry("2026-11-06", "2026-11-06T08:00:00Z", "2026-11-06T10:00:00Z"),     // 2h
        entry("2026-11-04", "2026-11-04T08:00:00Z", "2026-11-04T16:00:00Z"),     // 8h
        entry("2026-10-30", "2026-10-30T08:00:00Z", "2026-10-30T16:00:00Z"),     // last week
    ] + manual, now: now)                                                         // + 1.5h manual this week
    #expect(s.total == 3 * 3600)
    #expect(s.closed.count == 1)
    #expect(s.week == 12.5 * 3600)
}

@Test func timeOffCountsHoursAndDays() throws {
    let off: [TimeOffRequest] = try decode("""
    [{"amount": {"unit": "hours", "amount": "6"}, "dates": {"2026-10-30": "2", "2026-11-02": "4"}},
     {"amount": {"unit": "days", "amount": 1}, "dates": {"2026-11-04": 1}}]
    """)
    let types: TimeOffTypes = try decode(#"{"timeOffTypes": [], "defaultHours": [{"name": "Wednesday", "amount": "7.5"}, {"name": "Saturday", "amount": "0"}]}"#)
    // 4h timed off on Nov 2 (Oct 30 outside the range) + 1 day on Wed Nov 4 × 7.5h
    #expect(timeOffTime(off, from: "2026-11-02", to: "2026-11-06", hoursPerDay: types.hoursPerDay) == 11.5 * 3600)
    #expect(weekdayName("2026-11-02") == "Monday")
}

@Test func formatsDurations() {
    #expect(formatDuration(42 * 60) == "42m")
    #expect(formatDuration(4 * 3600) == "4h")
    #expect(formatDuration(4 * 3600 + 12 * 60) == "4h 12m")
    #expect(formatDuration(-5) == "0m")
}

@Test func decodesApiPayload() throws {
    // Shapes as returned live by /time_tracking/timesheet_entries (2026-11-06).
    let closed: TimesheetEntry = try decode("""
    {"id": 22015, "employeeId": 7, "type": "clock", "date": "2026-11-06", "start": "2026-11-06T07:43:00+00:00",
     "end": "2026-11-06T15:33:00+00:00", "timezone": "Europe/Vienna", "hours": 7.8333, "note": null,
     "projectInfo": null, "approvedAt": null, "approved": false}
    """)
    #expect(closed.start == iso("2026-11-06T07:43:00Z"))
    #expect(closed.duration(at: .now) == (7 * 60 + 50) * 60)
    let open: TimesheetEntry = try decode(#"{"type": "clock", "date": "2026-11-06", "start": "2026-11-06T22:00:00+00:00", "end": null, "timezone": "Europe/Berlin", "hours": null}"#)
    #expect(open.isOpen)
    let utc: TimesheetEntry = try decode(#"{"type": "clock", "date": "2026-11-06", "start": "2026-11-06T09:02:00Z", "end": null}"#)
    #expect(utc.start == iso("2026-11-06T09:02:00Z"))
}

@Test func normalizesDomain() {
    #expect(normalizeDomain(" Acme ") == "acme")
    #expect(normalizeDomain("acme.bamboohr.com") == "acme")
    #expect(normalizeDomain("https://acme.bamboohr.com/home") == "acme")
    #expect(isValidDomain("my-co1"))
    #expect(!isValidDomain("evil.com/x"))
    #expect(!isValidDomain(""))
}
