import Foundation
import Testing
@testable import BambooTime

/// Hits the real API with the app's code, using the refresh token the app
/// stored after Sign In (macOS asks for Keychain access). Runs only with:
/// [BAMBOO_EXPECT_WEEK="47h 50m"] BAMBOO_DOMAIN=acme BAMBOO_CLIENT_ID=… [BAMBOO_CLIENT_SECRET=…] swift test --filter live
@Test(.enabled(if: ProcessInfo.processInfo.environment["BAMBOO_CLIENT_ID"] != nil))
func liveWeekTotal() async throws {
    let env = ProcessInfo.processInfo.environment
    let config = OAuthConfig(clientId: env["BAMBOO_CLIENT_ID"]!, clientSecret: env["BAMBOO_CLIENT_SECRET"],
                             redirectURI: env["BAMBOO_REDIRECT_URI"] ?? "bambootime://oauth")
    let client = BambooClient(domain: env["BAMBOO_DOMAIN"]!, tokens: TokenStore(domain: env["BAMBOO_DOMAIN"]!, config: config))
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
