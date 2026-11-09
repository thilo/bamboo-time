import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

/// OAuth app registered on developers.bamboohr.com, stamped into Info.plist by bundle.sh.
struct OAuthConfig: Sendable {
    let clientId: String
    let clientSecret: String?  // nil for a public client (PKCE only)
    let redirectURI: String
    static let callbackScheme = "bambootime"
    /// Scopes for exactly the endpoints BambooClient calls; offline_access yields the refresh token.
    static let scopes = "offline_access employee:name time_tracking time_tracking:timesheets.write time_off"

    /// nil without a bundle (`swift run`); bundle.sh requires a client id.
    static let current: OAuthConfig? = {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String? {
            (info[key] as? String).flatMap { $0.isEmpty || $0.hasPrefix("__") ? nil : $0 }
        }
        guard let id = value("BambooClientID") else { return nil }
        return OAuthConfig(clientId: id, clientSecret: value("BambooClientSecret"),
                           redirectURI: value("BambooRedirectURI") ?? "\(callbackScheme)://oauth")
    }()
}

struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Double?
    let refresh_token: String?
}

/// Hands out a valid access token, refreshing via the Keychain's refresh token.
actor TokenStore {
    let domain: String
    let config: OAuthConfig
    private var access: (token: String, expiry: Date)?
    private var refreshing: Task<String, Error>?  // concurrent requests share one refresh

    init(domain: String, config: OAuthConfig) {
        self.domain = domain
        self.config = config
    }

    func bearer() async throws -> String {
        if let access, access.expiry > Date().addingTimeInterval(60) { return access.token }
        if let refreshing { return try await refreshing.value }
        let task = Task { try await refresh() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func refresh() async throws -> String {
        guard let refresh = Keychain.read() else { throw BambooError.http(401, "signed out") }
        let t = try await tokenRequest(domain: domain, config: config,
                                       ["grant_type": "refresh_token", "refresh_token": refresh])
        if let new = t.refresh_token, new != refresh { _ = Keychain.write(new) }  // rotated
        access = (t.access_token, Date().addingTimeInterval(t.expires_in ?? 3600))
        return t.access_token
    }
}

func tokenRequest(domain: String, config: OAuthConfig, _ params: [String: String]) async throws -> TokenResponse {
    guard isValidDomain(domain), let url = URL(string: "https://\(domain).bamboohr.com/token.php?request=token")
    else { throw BambooError.invalidDomain }
    var form = params
    form["client_id"] = config.clientId
    form["client_secret"] = config.clientSecret
    form["redirect_uri"] = config.redirectURI
    var c = URLComponents()
    c.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    // URLComponents leaves "+" unescaped, which form decoding would read as a space.
    req.httpBody = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    let (data, response) = try await BambooClient.session.data(for: req)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { throw BambooError.http(code, BambooClient.detail(data)) }
    return try JSONDecoder().decode(TokenResponse.self, from: data)
}

/// Authorization code flow with PKCE in a browser sheet (shares the browser's
/// BambooHR/SSO session). Stores the refresh token in the Keychain.
@MainActor
func signIn(domain: String, config: OAuthConfig) async throws {
    let verifier = randomURLSafe(32)
    let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    let state = randomURLSafe(16)
    var c = URLComponents(string: "https://\(domain).bamboohr.com/authorize.php")!
    c.queryItems = [
        .init(name: "request", value: "authorize"),
        .init(name: "response_type", value: "code"),
        .init(name: "client_id", value: config.clientId),
        .init(name: "redirect_uri", value: config.redirectURI),
        .init(name: "scope", value: OAuthConfig.scopes),
        .init(name: "state", value: state),
        .init(name: "code_challenge", value: challenge),
        .init(name: "code_challenge_method", value: "S256"),
    ]
    guard isValidDomain(domain), let url = c.url else { throw BambooError.invalidDomain }

    let callback = try await BrowserSession().run(url)
    let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func param(_ name: String) -> String? { items.first { $0.name == name }?.value }
    if let error = param("error") { throw BambooError.http(401, param("error_description") ?? error) }
    guard param("state") == state, let code = param("code") else { throw BambooError.http(400, "invalid sign-in response") }

    let t = try await tokenRequest(domain: domain, config: config,
                                   ["grant_type": "authorization_code", "code": code, "code_verifier": verifier])
    guard let refresh = t.refresh_token else { throw BambooError.http(400, "no refresh token (offline_access scope missing?)") }
    guard Keychain.write(refresh) else { throw BambooError.http(0, "could not save to Keychain") }
}

@MainActor
private final class BrowserSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: OAuthConfig.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? CancellationError()) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false  // reuse the browser's login/SSO
            session.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSWindow() }
    }
}

private func randomURLSafe(_ bytes: Int) -> String {
    var data = Data(count: bytes)
    _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
    return base64URL(data)
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
