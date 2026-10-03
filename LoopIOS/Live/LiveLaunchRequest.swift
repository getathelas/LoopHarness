import Foundation

/// A short-lived, one-shot handoff survives an intent arriving before the UI.
/// It is intentionally not persisted: reopening later must not start the mic.
@MainActor
final class LiveLaunchRequest {
    static let shared = LiveLaunchRequest()
    private var requestedAt: Date?

    func request(now: Date = Date()) { requestedAt = now }
    func isPending(now: Date = Date()) -> Bool {
        guard let requestedAt else { return false }
        return now.timeIntervalSince(requestedAt) < 60
    }
    func consume(now: Date = Date()) -> Bool {
        let pending = isPending(now: now)
        requestedAt = nil
        return pending
    }
}
