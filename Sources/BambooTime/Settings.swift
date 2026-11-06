import Foundation
import Security
import AppKit

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

enum Keychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "me.thilo.bamboo-time",
         kSecAttrAccount as String: "api-key"]
    }

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns false if the Keychain refused.
    static func write(_ key: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

/// Shows the settings dialog; returns true if new settings were saved.
@MainActor
func runSettingsDialog() -> Bool {
    let domain = NSTextField(string: Prefs.domain)
    domain.placeholderString = "mycompany (from mycompany.bamboohr.com)"
    let key = NSSecureTextField(string: Keychain.read() ?? "")
    key.placeholderString = "API key (BambooHR → profile menu → API Keys)"
    let stack = NSStackView(views: [domain, key])
    stack.orientation = .vertical
    stack.frame = NSRect(x: 0, y: 0, width: 320, height: 52)
    for f in [domain, key] { f.widthAnchor.constraint(equalToConstant: 320).isActive = true }

    let alert = NSAlert()
    alert.messageText = "BambooTime Settings"
    alert.accessoryView = stack
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = domain
    var problem: String?
    repeat {
        if let problem { alert.informativeText = "⚠ \(problem)" }
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let d = normalizeDomain(domain.stringValue)
        let k = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isValidDomain(d) { problem = "Invalid company domain"; continue }
        if k.isEmpty { problem = "API key is required"; continue }
        guard Keychain.write(k) else { problem = "Could not save API key to Keychain"; continue }
        Prefs.domain = d
        Prefs.employeeId = 0  // key may belong to someone else; re-resolve
        return true
    } while true
}
