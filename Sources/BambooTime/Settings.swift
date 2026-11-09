import Foundation
import Security
import AppKit
import AuthenticationServices

enum Prefs {
    static var domain: String {
        get { UserDefaults.standard.string(forKey: "companyDomain") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "companyDomain") }
    }

    /// 0 = not resolved yet (auto-detected via GET /employees/0).
    static var employeeId: Int {
        get { UserDefaults.standard.integer(forKey: "employeeId") }
        set { UserDefaults.standard.set(newValue, forKey: "employeeId") }
    }
}

/// Holds the OAuth refresh token (the access token stays in memory).
enum Keychain {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "me.thilo.bamboo-time",
        kSecAttrAccount as String: "refresh-token"] }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns false if the Keychain refused.
    static func write(_ value: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

/// Shows the settings dialog, then signs in and calls `done`; on failure the
/// dialog comes back with the problem. Call only from AppKit callbacks, never
/// inside a Task: a modal run loop there blocks the main queue, so every other
/// MainActor task (rendering, refresh) and the menu bar item stall.
@MainActor
func showSettings(problem: String? = nil, done: @escaping @MainActor () -> Void) {
    let domain = NSTextField(string: Prefs.domain)
    domain.placeholderString = "mycompany (from mycompany.bamboohr.com)"
    domain.frame = NSRect(x: 0, y: 0, width: 320, height: 24)

    let alert = NSAlert()
    alert.messageText = "BambooTime Settings"
    alert.accessoryView = domain
    alert.addButton(withTitle: "Sign In")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = domain
    // Back from the browser sheet the app is inactive and macOS may refuse
    // NSApp.activate(); a panel would then stay hidden.
    alert.window.hidesOnDeactivate = false
    alert.window.level = .floating
    guard let config = OAuthConfig.current else { return }  // `swift run`: no bundle, no sign-in
    var problem = problem
    var d = ""
    repeat {
        alert.informativeText = problem.map { "⚠ \($0)" }
            ?? "Enter your company domain, then sign in with your BambooHR account."
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        d = normalizeDomain(domain.stringValue)
        problem = isValidDomain(d) ? nil : "Invalid company domain"
    } while problem != nil

    Task {
        do { try await signIn(domain: d, config: config) } catch {
            let message = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                ? "Sign-in cancelled" : "Sign-in failed: \(error.localizedDescription)"
            // Leave the Task before the dialog's modal loop (see above).
            RunLoop.main.perform { MainActor.assumeIsolated { showSettings(problem: message, done: done) } }
            return
        }
        Prefs.domain = d
        Prefs.employeeId = 0  // may be someone else now; re-resolve
        done()
    }
}
