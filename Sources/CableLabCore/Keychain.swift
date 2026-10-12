import Foundation
import Security

/// The Mac password for `sudo`, kept in the user's login Keychain when they ask for it.
///
/// The item's access list trusts the app that created it (by code signature), so other apps get a
/// Keychain prompt instead of the password. It is never written to disk by Cable Lab itself and
/// never sent over the control socket.
public enum PasswordStore {
    static let service = "com.tarikbc.cablelab.sudo"

    static var account: String { NSUserName() }

    static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static var hasPassword: Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public static func save(_ password: String) -> Bool {
        let data = Data(password.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Cable Lab (sudo for disk tests)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
