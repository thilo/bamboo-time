import Foundation
import Testing
@testable import BambooTime

/// Hits the real API with the app's code. Runs only with credentials:
/// [BAMBOO_EXPECT_WEEK="47h 50m"] BAMBOO_DOMAIN=acme BAMBOO_KEY=$(security find-generic-password -s me.thilo.bamboo-time -a api-key -w) swift test --filter live
@Test(.enabled(if: ProcessInfo.processInfo.environment["BAMBOO_KEY"] != nil))
func liveWeekTotal() async throws {
    let env = ProcessInfo.processInfo.environment
    let client = BambooClient(domain: env["BAMBOO_DOMAIN"]!, apiKey: env["BAMBOO_KEY"]!)
    let id = try await client.selfEmployeeId()
    let now = Date(), tz = TimeZone.current.identifier
    let (week, today) = (dayString(weekStart(now), timeZone: tz), dayString(now, timeZone: tz))

    let sheet = try await client.timesheetEntries(employeeId: id, from: week, to: today)
    let off = try await client.approvedTimeOff(employeeId: id, from: week, to: today)
    let s = summarize(sheet, now: now)
    let timeOff = timeOffTime(off, from: week, to: today, hoursPerDay: try await client.hoursPerDay())

    print("employee \(id), week \(week)…\(today)")
    for e in sheet {
        print("  \(e.type) \(e.date) \(e.start.map(formatTime) ?? "")–\(e.end.map(formatTime) ?? (e.isOpen ? "live" : "")) \(formatDuration(e.duration(at: now)))")
    }
    for o in off { print("  timeoff \(o.amount.unit) \(o.dates?.mapValues(\.value) ?? [:])") }
    print("clocked in: \(s.open != nil), today \(formatDuration(s.total))")
    print("entries \(formatDuration(s.week)) + time off \(formatDuration(timeOff)) = \(formatDuration(s.week + timeOff))")
    if let expected = env["BAMBOO_EXPECT_WEEK"] { #expect(formatDuration(s.week + timeOff) == expected) }  // e.g. "47h 50m"
}
