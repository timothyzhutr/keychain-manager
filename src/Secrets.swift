import AppKit
import Combine
import Foundation

@MainActor
final class SecretSession: ObservableObject {
    @Published private(set) var revealed: [UUID: String] = [:]
    @Published private var requests: [UUID: UUID] = [:]
    private var expirations: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private let revealLifetime: TimeInterval
    private var active = true

    init(revealLifetime: TimeInterval = 60) { self.revealLifetime = revealLifetime }

    func beginReveal(for id: UUID) -> UUID {
        hide(id)
        let token = UUID()
        requests[id] = token
        return token
    }
    func finishReveal(for id: UUID, token: UUID, result: Result<String, Error>) -> Bool {
        guard requests[id] == token else { return false }
        requests[id] = nil
        guard active else { return false }
        if case .success(let secret) = result {
            revealed[id] = secret
            let delay = UInt64(revealLifetime * 1_000_000_000)
            let expiration = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard !Task.isCancelled, let self, self.expirations[id]?.token == token else { return }
                self.hide(id)
            }
            expirations[id] = (token, expiration)
        }
        return true
    }
    func isBusy(_ id: UUID) -> Bool { requests[id] != nil }
    /// Keep pending authorization tokens through a transient system dialog, but
    /// never retain/display a result that arrives while the app is inactive.
    func setActive(_ active: Bool) {
        self.active = active
        if !active { hideRevealed() }
    }
    func hide(_ id: UUID) {
        expirations.removeValue(forKey: id)?.task.cancel()
        requests[id] = nil
        revealed[id] = nil
    }

    /// Invalidates pending work as well as releasing references to revealed text.
    func clear() {
        hideRevealed()
        requests.removeAll()
    }

    private func hideRevealed() {
        expirations.values.forEach { $0.task.cancel() }
        expirations.removeAll()
        revealed.removeAll()
    }

    deinit { expirations.values.forEach { $0.task.cancel() } }
}

@MainActor
final class SecretClipboard {
    static let shared = SecretClipboard()
    private let pasteboard: NSPasteboard
    private let lifetime: TimeInterval
    private var ownedChangeCount: Int?
    private var expiration: Task<Void, Never>?

    init(pasteboard: NSPasteboard = .general, lifetime: TimeInterval = 60) {
        self.pasteboard = pasteboard
        self.lifetime = lifetime
    }

    func copy(_ secret: String) {
        expiration?.cancel()
        pasteboard.clearContents()
        pasteboard.setString(secret, forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        let stamp = pasteboard.changeCount
        ownedChangeCount = stamp
        let delay = UInt64(lifetime * 1_000_000_000)
        expiration = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled, let self, self.ownedChangeCount == stamp else { return }
            self.clearOwned()
        }
    }

    func clearOwned() {
        expiration?.cancel()
        expiration = nil
        if let ownedChangeCount, pasteboard.changeCount == ownedChangeCount {
            pasteboard.clearContents()
        }
        ownedChangeCount = nil
    }

    deinit { expiration?.cancel() }
}
