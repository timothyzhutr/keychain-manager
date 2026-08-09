import Foundation
import Security

/// One keychain entry (generic or internet password).
struct KItem: Identifiable, Hashable {
    let id = UUID()
    let persistentRef: Data
    let isInternet: Bool
    let service: String   // svce for generic, srvr for internet
    let account: String
    let label: String
    var kindLabel: String { isInternet ? "internet" : "generic" }
}

enum KError: Error, LocalizedError {
    case status(OSStatus)
    var errorDescription: String? {
        guard case let .status(s) = self else { return nil }
        switch s {
        case errSecUserCanceled: return "Authorization was canceled."
        case errSecItemNotFound: return "Item not found."
        case errSecAuthFailed:   return "Authorization failed."
        default:
            return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
        }
    }
}

/// Thin wrapper over the Security framework operating on the file-based login keychain.
enum Keychain {

    static func list() -> [KItem] {
        var items: [KItem] = []
        for isInternet in [false, true] {
            let query: [String: Any] = [
                kSecClass as String: isInternet ? kSecClassInternetPassword : kSecClassGenericPassword,
                kSecReturnAttributes as String: true,
                kSecReturnPersistentRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            guard status == errSecSuccess, let arr = result as? [[String: Any]] else { continue }
            for d in arr {
                guard let persistentRef = d[kSecValuePersistentRef as String] as? Data else {
                    continue
                }
                let account = d[kSecAttrAccount as String] as? String ?? ""
                let service = (isInternet
                    ? d[kSecAttrServer as String] as? String
                    : d[kSecAttrService as String] as? String) ?? ""
                let label = d[kSecAttrLabel as String] as? String
                    ?? (service.isEmpty ? account : service)
                items.append(KItem(persistentRef: persistentRef,
                                   isInternet: isInternet, service: service,
                                   account: account, label: label))
            }
        }
        return items.sorted {
            ($0.service.lowercased(), $0.account.lowercased())
                < ($1.service.lowercased(), $1.account.lowercased())
        }
    }

    /// Reads the secret. macOS shows its own authorization dialog for items this app
    /// doesn't yet own — that prompt is the OS, not us, and cannot be bypassed here.
    static func reveal(_ item: KItem) throws -> String {
        let query = revealQuery(for: item)

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KError.status(status)
        }
        return String(data: data, encoding: .utf8) ?? "(binary, \(data.count) bytes)"
    }

    static func revealQuery(for item: KItem) -> [String: Any] {
        [
            kSecValuePersistentRef as String: item.persistentRef,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    /// Adds a generic password; updates in place if service+account already exist.
    static func addGeneric(service: String, account: String,
                           password: String, note: String) throws {
        var attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8),
        ]
        if !note.isEmpty { attrs[kSecAttrDescription as String] = note }

        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let match: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            var update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
            if !note.isEmpty { update[kSecAttrDescription as String] = note }
            let us = SecItemUpdate(match as CFDictionary, update as CFDictionary)
            if us != errSecSuccess { throw KError.status(us) }
        } else if status != errSecSuccess {
            throw KError.status(status)
        }
    }

    static func delete(_ item: KItem) throws {
        let query = deleteQuery(for: item)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KError.status(status)
        }
    }

    static func deleteQuery(for item: KItem) -> [String: Any] {
        [
            kSecValuePersistentRef as String: item.persistentRef,
        ]
    }
}
