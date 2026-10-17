import Foundation
import Security

@main
struct KeychainFailureTests {
    static func main() throws {
        let empty = try Keychain.list(copyMatching: { _, _ in errSecItemNotFound })
        expect(empty.isEmpty, "an empty keychain should be a successful empty list")

        do {
            _ = try Keychain.list(copyMatching: { _, _ in errSecAuthFailed })
            fail("authorization errors must not be reported as an empty keychain")
        } catch KError.status(let status) {
            expect(status == errSecAuthFailed, "the original error should reach the UI")
        }

        var calls = 0
        do {
            _ = try Keychain.list(copyMatching: { _, result in
                calls += 1
                if calls == 1 { result?.pointee = [] as CFArray; return errSecSuccess }
                return errSecInteractionNotAllowed
            })
            fail("a later class failure must not silently return a partial list")
        } catch KError.status(let status) {
            expect(status == errSecInteractionNotAllowed, "partial list failure should propagate")
        }

        do {
            _ = try Keychain.list(copyMatching: { _, result in
                result?.pointee = "unexpected" as CFString
                return errSecSuccess
            })
            fail("malformed successful responses must not look like an empty keychain")
        } catch { /* Any explicit error is preferable to silently dropping all items. */ }
        print("KeychainFailureTests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
