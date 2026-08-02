import Foundation
import Security

@main
struct KeychainQueryTests {
    static func main() {
        let persistentRef = Data([0x01, 0x02, 0x03, 0x04])
        let item = KItem(persistentRef: persistentRef,
                         isInternet: true,
                         service: "example.com",
                         account: "alice",
                         label: "Example")

        assertRevealTargetsPersistentReference(Keychain.revealQuery(for: item),
                                               reference: persistentRef)
        assertDeleteTargetsPersistentReference(Keychain.deleteQuery(for: item),
                                               reference: persistentRef)
        print("KeychainQueryTests passed")
    }

    private static func assertRevealTargetsPersistentReference(
        _ query: [String: Any], reference: Data
    ) {
        guard query[kSecValuePersistentRef as String] as? Data == reference else {
            fail("reveal query does not target the persistent reference")
        }
        assertHasNoAmbiguousAttributes(query, operation: "reveal")
    }

    private static func assertDeleteTargetsPersistentReference(
        _ query: [String: Any], reference: Data
    ) {
        guard query[kSecValuePersistentRef as String] as? Data == reference else {
            fail("delete query does not target the persistent reference")
        }
        assertHasNoAmbiguousAttributes(query, operation: "delete")
    }

    private static func assertHasNoAmbiguousAttributes(
        _ query: [String: Any], operation: String
    ) {
        for ambiguousKey in [kSecAttrServer, kSecAttrService, kSecAttrAccount] {
            if query[ambiguousKey as String] != nil {
                fail("\(operation) query still targets an ambiguous attribute")
            }
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
