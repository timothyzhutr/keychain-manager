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
    case duplicateItem(KItem)
    case invalidResult
    var errorDescription: String? {
        switch self {
        case .duplicateItem: return "A password already exists for this service and account."
        case .invalidResult: return "The keychain returned an unexpected result."
        case .status(let s):
            switch s {
            case errSecUserCanceled: return "Authorization was canceled."
            case errSecItemNotFound: return "Item not found."
            case errSecAuthFailed:   return "Authorization failed."
            default:
                return (SecCopyErrorMessageString(s, nil) as String?) ?? "Keychain error \(s)"
            }
        }
    }
}

/// Security framework wrapper for file-based keychains in the user's search list.
enum Keychain {

    static func list(in keychain: SecKeychain? = nil,
                     copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching) throws -> [KItem] {
        var items: [KItem] = []
        for isInternet in [false, true] {
            var query: [String: Any] = [
                kSecClass as String: isInternet ? kSecClassInternetPassword : kSecClassGenericPassword,
                kSecReturnAttributes as String: true,
                kSecReturnPersistentRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            if let keychain { query[kSecMatchSearchList as String] = [keychain] }
            var result: CFTypeRef?
            let status = copyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw KError.status(status) }
            guard let arr = result as? [[String: Any]] else { throw KError.invalidResult }
            for d in arr {
                items.append(try item(from: d, isInternet: isInternet))
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
        guard status == errSecSuccess else { throw KError.status(status) }
        guard let data = result as? Data else { throw KError.invalidResult }
        return String(data: data, encoding: .utf8) ?? "(binary, \(data.count) bytes)"
    }

    static func revealQuery(for item: KItem) -> [String: Any] {
        [
            kSecValuePersistentRef as String: item.persistentRef,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    /// Creates a generic password. Duplicates return the exact item for confirmation;
    /// creating a password never changes an existing secret.
    static func addGeneric(service: String, account: String,
                           password: String, note: String, in keychain: SecKeychain? = nil) throws {
        let target: SecKeychain
        if let keychain {
            target = keychain
        } else {
            var defaultKeychain: SecKeychain?
            let status = SecKeychainCopyDefault(&defaultKeychain)
            guard status == errSecSuccess else { throw KError.status(status) }
            guard let defaultKeychain else { throw KError.invalidResult }
            target = defaultKeychain
        }
        var attrs: [String: Any] = [
            kSecUseKeychain as String: target,
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
                kSecMatchSearchList as String: [target],
                kSecReturnAttributes as String: true,
                kSecReturnPersistentRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let lookupStatus = SecItemCopyMatching(match as CFDictionary, &result)
            guard lookupStatus == errSecSuccess else { throw KError.status(lookupStatus) }
            guard let attributes = result as? [String: Any] else { throw KError.invalidResult }
            throw KError.duplicateItem(try item(from: attributes, isInternet: false))
        } else if status != errSecSuccess {
            throw KError.status(status)
        }
    }

    static func replaceGeneric(_ item: KItem, password: String, note: String) throws {
        guard !item.isInternet else { throw KError.invalidResult }
        let match = [kSecValuePersistentRef as String: item.persistentRef]
        let update: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrDescription as String: note,
        ]
        let status = SecItemUpdate(match as CFDictionary, update as CFDictionary)
        guard status == errSecSuccess else { throw KError.status(status) }
    }

    /// Changes only the secret of this exact item, preserving its identity and metadata.
    /// A missing item is an error; updating never deletes or creates a password.
    static func updatePassword(_ item: KItem, password: String,
                               update: (CFDictionary, CFDictionary) -> OSStatus = SecItemUpdate) throws {
        let match = [kSecValuePersistentRef as String: item.persistentRef]
        let changes = [kSecValueData as String: Data(password.utf8)]
        let status = update(match as CFDictionary, changes as CFDictionary)
        guard status == errSecSuccess else { throw KError.status(status) }
    }

    private static func item(from attributes: [String: Any], isInternet: Bool) throws -> KItem {
        guard let reference = attributes[kSecValuePersistentRef as String] as? Data else {
            throw KError.invalidResult
        }
        let account = attributes[kSecAttrAccount as String] as? String ?? ""
        let serviceKey = isInternet ? kSecAttrServer : kSecAttrService
        let service = attributes[serviceKey as String] as? String ?? ""
        let label = attributes[kSecAttrLabel as String] as? String
            ?? (service.isEmpty ? account : service)
        return KItem(persistentRef: reference, isInternet: isInternet,
                     service: service, account: account, label: label)
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
