import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let secrets: SecretSession
    private let clipboard: SecretClipboard
    private var workspaceObservers: [NSObjectProtocol] = []
    private var windowObserver: NSObjectProtocol?

    override init() {
        secrets = SecretSession()
        clipboard = .shared
        super.init()
    }

    init(secrets: SecretSession, clipboard: SecretClipboard) {
        self.secrets = secrets
        self.clipboard = clipboard
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.secrets.clear() }
            })
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.secrets.clear() }
        }
    }

    func applicationDidResignActive(_ notification: Notification) { secrets.setActive(false) }

    func applicationDidBecomeActive(_ notification: Notification) { secrets.setActive(true) }

    func applicationWillTerminate(_ notification: Notification) {
        secrets.clear()
        clipboard.clearOwned()
    }

    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }
}
