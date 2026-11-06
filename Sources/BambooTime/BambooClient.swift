import Foundation

enum BambooError: LocalizedError {
    case invalidDomain
    case http(Int, String?)

    var isAuth: Bool {
        if case .http(let code, _) = self { return code == 401 || code == 403 }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidDomain: return "Invalid company domain"
        case .http(let code, let detail):
            let base = switch code {
            case 401: "Unauthorized: check your API key"
            case 403: "Forbidden: API key disabled or lacks permission"
            case 404: "Not found (not clocked in?)"
            case 409: "Conflict: already clocked in/out"
            case 422: "Validation error (time tracking configuration?)"
            case 429: "Rate limited: try again shortly"
            default: "HTTP \(code)"
            }
            return detail.map { "\(base): \($0)" } ?? base
        }
    }
}

struct BambooClient: Sendable {
    let domain: String
    let apiKey: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    /// GET /employees/0 resolves to the API key's owner.
    func selfEmployeeId() async throws -> Int {
        struct Me: Decodable { let id: Flex }  // id may be a number or a string
        return Int(try await (get("/employees/0") as Me).id.value)
    }

    /// Clock (including the open one) and manual hour entries. Days are
    /// YYYY-MM-DD in the company timezone; `from` must be within the last 365 days.
    func timesheetEntries(employeeId: Int, from: String, to: String) async throws -> [TimesheetEntry] {
        try await get("/time_tracking/timesheet_entries", ["start": from, "end": to, "employeeIds": "\(employeeId)"])
    }

    /// Approved requests overlapping `from...to` (YYYY-MM-DD).
    func approvedTimeOff(employeeId: Int, from: String, to: String) async throws -> [TimeOffRequest] {
        try await get("/time_off/requests", ["start": from, "end": to, "employeeId": "\(employeeId)",
                                             "status": "approved", "excludeNote": "1"])
    }

    /// Company hours per weekday name, used to convert day-based time off.
    func hoursPerDay() async throws -> [String: Double] {
        try await (get("/meta/time_off/types") as TimeOffTypes).hoursPerDay
    }

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        let items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try bambooDecoder.decode(T.self, from: try await request("GET", path, query: items))
    }

    func clockIn(employeeId: Int) async throws {
        _ = try await request("POST", "/time-tracking/clock-ins",
                              body: ["employeeId": employeeId, "timezone": TimeZone.current.identifier])
    }

    func clockOut(employeeId: Int) async throws {
        _ = try await request("POST", "/time-tracking/clock-outs", body: ["employeeId": employeeId])
    }

    private func request(_ method: String, _ path: String,
                         query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        guard isValidDomain(domain) else { throw BambooError.invalidDomain }
        var c = URLComponents()
        c.scheme = "https"
        c.host = "\(domain).bamboohr.com"
        c.path = "/api/v1" + path
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw BambooError.invalidDomain }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Basic " + Data("\(apiKey):x".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await Self.session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw BambooError.http(code, Self.detail(data)) }
        return data
    }

    /// BambooHR error bodies are JSON problem details.
    private static func detail(_ data: Data) -> String? {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["detail"] ?? obj?["title"] ?? obj?["message"]) as? String
    }
}

func isValidDomain(_ d: String) -> Bool {
    !d.isEmpty && d.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
}

/// Accepts "acme", "acme.bamboohr.com" or "https://acme.bamboohr.com/home".
func normalizeDomain(_ input: String) -> String {
    var d = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    for scheme in ["https://", "http://"] where d.hasPrefix(scheme) { d.removeFirst(scheme.count) }
    d = String(d.prefix { $0 != "/" })
    if d.hasSuffix(".bamboohr.com") { d.removeLast(".bamboohr.com".count) }
    return d
}
