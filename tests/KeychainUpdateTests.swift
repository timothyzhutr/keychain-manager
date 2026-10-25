import Foundation
import Security

@main
struct KeychainUpdateTests {
    static func main() throws {
        for isInternet in [false, true] {
            let reference = Data([0x01, 0x02, isInternet ? 0x03 : 0x04])
            let item = KItem(persistentRef: reference, isInternet: isInternet,
                             service: "example.invalid", account: "alice", label: "Example")
            let password = "  rotated-token-🔑\n"
            var calls = 0
            try Keychain.updatePassword(item, password: password, update: { query, changes in
                calls += 1
                let query = query as NSDictionary
                let changes = changes as NSDictionary
                expect(query.count == 1 && query[kSecValuePersistentRef] as? Data == reference,
                       "update must target only the selected persistent reference")
                expect(changes.count == 1 && changes[kSecValueData] as? Data == Data(password.utf8),
                       "update must preserve the exact secret and leave all metadata unchanged")
                return errSecSuccess
            })
            expect(calls == 1, "update must issue a single in-place change")

            for failure in [errSecUserCanceled, errSecAuthFailed, errSecItemNotFound] {
                do {
                    try Keychain.updatePassword(item, password: "replacement", update: { _, _ in failure })
                    fail("a failed update must reach the caller")
                } catch KError.status(let status) {
                    expect(status == failure, "update must preserve the original error status")
                }
            }
        }
        print("KeychainUpdateTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
