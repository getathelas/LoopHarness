import Foundation

/// Injectable socket boundary for deterministic disconnect, timeout and stale-callback tests.
protocol LiveConnection: AnyObject {
    var closeCode: Int { get }
    var httpStatus: Int? { get }
    func receive() async throws -> Data
    func send(_ text: String) async throws
    func ping(completion: @escaping (Error?) -> Void)
    func cancel()
}

final class LiveWebSocket: LiveConnection {
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    var closeCode: Int { task.closeCode.rawValue }
    var httpStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

    init(key: String) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: config)
        var request = URLRequest(url: LiveProtocol.endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        task.resume()
    }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: return Data()
        }
    }
    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func ping(completion: @escaping (Error?) -> Void) { task.sendPing(pongReceiveHandler: completion) }
    func cancel() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}

enum LiveRecovery {
    static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 12]
    static let heartbeatInterval: TimeInterval = 15
    static let heartbeatGrace: TimeInterval = 45

    static func retryable(error: Error, httpStatus: Int?, closeCode: Int) -> Bool {
        if let status = httpStatus, status >= 400 {
            return [408, 429].contains(status) || status >= 500
        }
        if [1002, 1003, 1007, 1008, 1009].contains(closeCode) { return false }
        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            return ![NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorUserAuthenticationRequired,
                     NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
                     NSURLErrorServerCertificateNotYetValid].contains(error.code)
        }
        return true
    }

    /// Never record server text, NSError userInfo, audio, transcripts or credentials.
    static func diagnostic(stage: String, error: Error?, httpStatus: Int?, closeCode: Int,
                           retry: Int, queued: Int) -> String {
        let ns = error as NSError?
        let domains = [NSURLErrorDomain, NSPOSIXErrorDomain, NSCocoaErrorDomain, "LiveAudio", "LiveConnection"]
        let domain = ns.map { domains.contains($0.domain) ? $0.domain : "Other" } ?? "none"
        return "Live \(stage): domain=\(domain) code=\(ns?.code ?? 0) http=\(httpStatus ?? 0) close=\(closeCode) retry=\(retry) queued=\(queued)"
    }
}
