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

        try Keychain.delete(before[0])
        let after = try items(in: keychain)
        guard after.count == 1 else {
            throw IntegrationTestError.invalidResult(
                "deletion affected \(before.count - after.count) items instead of one")
        }

        print("PersistentRefIntegrationTests passed")
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
