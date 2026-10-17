import AppKit
import Foundation

@main
struct SecretLifecycleTests {
    @MainActor
    static func main() async throws {
        let session = SecretSession(revealLifetime: 0.04)
        let id = UUID()
        let token = session.beginReveal(for: id)
        expect(session.finishReveal(for: id, token: token, result: .success("test-secret")),
               "current reveal should complete")
        expect(session.revealed[id] == "test-secret", "secret should be visible")
        session.hide(id)
        expect(session.revealed.isEmpty, "Hide must release the secret")

        let stale = session.beginReveal(for: id)
        session.clear()
        expect(!session.finishReveal(for: id, token: stale, result: .success("late-secret")),
               "reload/background cleanup must reject an in-flight reveal")
        expect(session.revealed.isEmpty && !session.isBusy(id), "cleanup must reset all state")

        let older = session.beginReveal(for: id)
        let current = session.beginReveal(for: id)
        expect(!session.finishReveal(for: id, token: older, result: .success("old")),
               "an older completion must not replace a newer request")
        expect(session.isBusy(id), "stale completion must not clear the newer busy state")
        expect(session.finishReveal(for: id, token: current, result: .success("new")),
               "newer completion should be accepted")
        try await waitUntil("revealed secret did not expire") { session.revealed.isEmpty }

        let failed = session.beginReveal(for: id)
        expect(session.finishReveal(for: id, token: failed,
                                   result: .failure(NSError(domain: "test", code: 1))),
               "current error should be accepted")
        expect(!session.isBusy(id) && session.revealed.isEmpty, "failure must clear busy state")

        let inactive = session.beginReveal(for: id)
        session.setActive(false)
        expect(!session.finishReveal(for: id, token: inactive, result: .success("background-secret")),
               "a reveal completing while inactive must be discarded")
        session.setActive(true)
        expect(session.revealed.isEmpty, "reactivating must not restore discarded secrets")

        let expiring = session.beginReveal(for: id)
        _ = session.finishReveal(for: id, token: expiring, result: .success("old-expiring-secret"))
        await Task.yield()  // Let the expiry task enter its sleep.
        blockMainActor(0.1)  // Its elapsed continuation queues behind this work.
        let fresh = session.beginReveal(for: id)
        _ = session.finishReveal(for: id, token: fresh, result: .success("fresh-secret"))
        await Task.yield()
        expect(session.revealed[id] == "fresh-secret", "an elapsed old timer must not hide a new reveal")
        session.clear()

        // System authorization dialogs can temporarily deactivate the app.
        let authorized = session.beginReveal(for: id)
        session.setActive(false)
        session.setActive(true)
        expect(session.finishReveal(for: id, token: authorized, result: .success("authorized-secret")),
               "a pending authorization may finish after the app is active again")
        session.setActive(false)
        expect(session.revealed.isEmpty, "deactivation must hide already revealed values")
        session.setActive(true)

        // Use a private pasteboard, never the user's clipboard.
        let pasteboard = NSPasteboard(name: .init("keychain-manager-tests-\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        let clipboard = SecretClipboard(pasteboard: pasteboard, lifetime: 0.04)
        clipboard.copy("old-copy")
        await Task.yield()
        blockMainActor(0.1)
        clipboard.copy("fresh-copy")
        await Task.yield()
        expect(pasteboard.string(forType: .string) == "fresh-copy",
               "an elapsed old clipboard timer must not clear a newer copy")
        clipboard.clearOwned()
        clipboard.copy("dummy-password")
        expect(pasteboard.string(forType: .string) == "dummy-password", "copy must preserve text")
        expect(pasteboard.types?.contains(.init("org.nspasteboard.ConcealedType")) == true,
               "copied secrets must be marked concealed")
        try await waitUntil("clipboard did not expire") { pasteboard.string(forType: .string) == nil }

        clipboard.copy("dummy-password")
        pasteboard.clearContents()
        pasteboard.setString("unrelated-content", forType: .string)
        clipboard.clearOwned()
        expect(pasteboard.string(forType: .string) == "unrelated-content",
               "cleanup must preserve a clipboard changed by another copy")

        clipboard.copy("dummy-password")
        clipboard.clearOwned()
        expect(pasteboard.string(forType: .string) == nil, "quit cleanup must clear owned secrets")

        let delegate = AppDelegate(secrets: session, clipboard: clipboard)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        let closeToken = session.beginReveal(for: id)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: nil)
        expect(!session.isBusy(id), "closing a window must invalidate pending reveals synchronously")
        expect(!session.finishReveal(for: id, token: closeToken, result: .success("closed-window")),
               "a closed window must not receive late plaintext")

        let sleepToken = session.beginReveal(for: id)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        expect(!session.isBusy(id), "sleep must invalidate pending reveals synchronously")
        expect(!session.finishReveal(for: id, token: sleepToken, result: .success("sleeping-secret")),
               "a sleeping session must not receive late plaintext")

        clipboard.copy("dummy-password")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        expect(pasteboard.string(forType: .string) == nil, "the app delegate must clear owned clipboard on quit")
        print("SecretLifecycleTests passed")
    }

    @MainActor
    private static func blockMainActor(_ duration: TimeInterval) { Thread.sleep(forTimeInterval: duration) }

    @MainActor
    private static func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        expect(condition(), message)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }
}
