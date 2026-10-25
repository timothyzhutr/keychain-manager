import Foundation
import Security

enum IntegrationTestError: Error {
    case failed(String, OSStatus)
    case invalidResult(String)
}

@main
struct PersistentRefIntegrationTests {
    static func main() throws {
        let testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("keychain-manager-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: testRoot,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let keychainURL = testRoot.appendingPathComponent("Test.keychain-db")
        let password = Data("temporary-test-password".utf8)
        var keychain: SecKeychain?
        let createStatus = keychainURL.path.withCString { path in
            password.withUnsafeBytes { bytes in
                SecKeychainCreate(path, UInt32(password.count), bytes.baseAddress,
                                  false, nil, &keychain)
            }
        }
        guard createStatus == errSecSuccess, let keychain else {
            throw IntegrationTestError.failed("create temporary keychain", createStatus)
        }
        defer { SecKeychainDelete(keychain) }

        try Keychain.addGeneric(service: "overwrite-test.invalid", account: "alice",
                                password: "original", note: "original note", in: keychain)
        let genericBefore = try Keychain.list(in: keychain).first { !$0.isInternet }!
        let confirmedItem: KItem
        do {
            try Keychain.addGeneric(service: "overwrite-test.invalid", account: "alice",
                                    password: "replacement", note: "replacement note", in: keychain)
            throw IntegrationTestError.invalidResult("duplicate add overwrote an existing password")
        } catch KError.duplicateItem(let item) {
            confirmedItem = item
        }
        guard try Keychain.reveal(genericBefore) == "original" else {
            throw IntegrationTestError.invalidResult("duplicate add changed the saved password")
        }
        guard confirmedItem.persistentRef == genericBefore.persistentRef else {
            throw IntegrationTestError.invalidResult("confirmation did not target the existing item")
        }
        try Keychain.replaceGeneric(confirmedItem, password: "replacement", note: "replacement note")
        guard try Keychain.reveal(genericBefore) == "replacement" else {
            throw IntegrationTestError.invalidResult("confirmed replacement did not update the item")
        }
        let genericAttributes = try attributes(for: confirmedItem)
        let newToken = "  rotated-token-🔑\n"
        try Keychain.updatePassword(confirmedItem, password: newToken)
        guard try Keychain.reveal(genericBefore) == newToken else {
            throw IntegrationTestError.invalidResult("generic update did not preserve the exact new value")
        }
        try assertMetadataUnchanged(for: confirmedItem, before: genericAttributes)
        guard try Keychain.list(in: keychain).first?.persistentRef == genericBefore.persistentRef else {
            throw IntegrationTestError.invalidResult("generic update recreated the item")
        }
        // Confirmation cannot recreate a deleted item or update a different matching item.
        try Keychain.delete(confirmedItem)
        do {
            try Keychain.replaceGeneric(confirmedItem, password: "unexpected", note: "")
            throw IntegrationTestError.invalidResult("replacement unexpectedly recreated a deleted item")
        } catch KError.status(let status) where status == errSecItemNotFound { }

        // Updating a missing item must fail without recreating it. File-based keychain
        // references can be reused if another item is later added with identical attributes.
        do {
            try Keychain.updatePassword(confirmedItem, password: "unexpected")
            throw IntegrationTestError.invalidResult("update unexpectedly recreated a deleted item")
        } catch KError.status(let status) where status == errSecItemNotFound { }
        guard try Keychain.list(in: keychain).isEmpty else {
            throw IntegrationTestError.invalidResult("failed update created a new item")
        }

        try addInternetPassword(port: 80, secret: "first", to: keychain)
        try addInternetPassword(port: 443, secret: "second", to: keychain)

        let before = try items(in: keychain)
        guard before.count == 2 else {
            throw IntegrationTestError.invalidResult("expected two test items")
        }

        let revealed = try Keychain.reveal(before[0])
        guard ["first", "second"].contains(revealed) else {
            throw IntegrationTestError.invalidResult("revealed unexpected test data")
        }

        let internetAttributes = try attributes(for: before[0])
        let otherSecret = try Keychain.reveal(before[1])
        try Keychain.updatePassword(before[0], password: "rotated-internet-password")
        guard try Keychain.reveal(before[0]) == "rotated-internet-password",
              try Keychain.reveal(before[1]) == otherSecret else {
            throw IntegrationTestError.invalidResult("internet update did not change exactly one item")
        }
        try assertMetadataUnchanged(for: before[0], before: internetAttributes)
        let updated = try items(in: keychain)
        guard Set(updated.map(\.persistentRef)) == Set(before.map(\.persistentRef)) else {
            throw IntegrationTestError.invalidResult("internet update recreated an item")
        }

        try Keychain.delete(before[0])
        let after = try items(in: keychain)
        guard after.count == 1 else {
            throw IntegrationTestError.invalidResult(
                "deletion affected \(before.count - after.count) items instead of one")
        }

        print("PersistentRefIntegrationTests passed")
    }

    private static func attributes(for item: KItem) throws -> [String: Any] {
        let query: [String: Any] = [
            kSecValuePersistentRef as String: item.persistentRef,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, var attributes = result as? [String: Any] else {
            throw IntegrationTestError.failed("read item metadata", status)
        }
        attributes.removeValue(forKey: kSecAttrModificationDate as String)
        return attributes
    }

    private static func assertMetadataUnchanged(for item: KItem, before: [String: Any]) throws {
        guard NSDictionary(dictionary: before).isEqual(to: try attributes(for: item)) else {
            throw IntegrationTestError.invalidResult("updating the password changed item metadata")
        }
    }

    private static func addInternetPassword(
        port: Int, secret: String, to keychain: SecKeychain
    ) throws {
        let add: [String: Any] = [
            kSecUseKeychain as String: keychain,
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "persistent-ref-test.invalid",
            kSecAttrAccount as String: "alice",
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrPort as String: port,
            kSecValueData as String: Data(secret.utf8),
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw IntegrationTestError.failed("add internet password", status)
        }
    }

    private static func items(in keychain: SecKeychain) throws -> [KItem] {
        let query: [String: Any] = [
            kSecMatchSearchList as String: [keychain],
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "persistent-ref-test.invalid",
            kSecAttrAccount as String: "alice",
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let dictionaries = result as? [[String: Any]] else {
            throw IntegrationTestError.failed("list internet passwords", status)
        }

        return try dictionaries.map { dictionary in
            guard let persistentRef = dictionary[kSecValuePersistentRef as String] as? Data else {
                throw IntegrationTestError.invalidResult("missing persistent reference")
            }
            return KItem(persistentRef: persistentRef,
                         isInternet: true,
                         service: "persistent-ref-test.invalid",
                         account: "alice",
                         label: "test")
        }
    }
}
