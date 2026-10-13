#if DEBUG
import Foundation

/// Isolated account and transport for Simulator UI tests; never reads the real Keychain.
enum AccountUITestFixture {
    static func makeSession() -> AccountSession {
        let arguments = ProcessInfo.processInfo.arguments
        let persistence = MemorySessionPersistence()
        if !arguments.contains("--signed-out-ui-testing") {
            persistence.value = ServerSession(token: "ui-test-token", user_id: "11111111-1111-1111-1111-111111111111",
                expires_at: arguments.contains("--expired-session-ui-testing") ? "2000-01-01T00:00:00Z" : "2099-01-01T00:00:00Z")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountFixtureURLProtocol.self]
        return AccountSession(persistence: persistence, network: URLSession(configuration: configuration))
    }
}

private final class MemorySessionPersistence: SessionPersistence {
    var value: ServerSession?
    func load() throws -> ServerSession? { value }
    func save(_ session: ServerSession) throws { value = session }
    func clear() throws { value = nil }
}

private final class AccountFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path
        if path == "/v1/auth/apple/challenge" && ProcessInfo.processInfo.arguments.contains("--login-offline-ui-testing") {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let body: String
        switch path {
        case "/v1/auth/apple/challenge": body = #"{"challenge_id":"ui-test","nonce":"ui-test-nonce"}"#
        case "/v1/auth/me": body = #"{"user_id":"11111111-1111-1111-1111-111111111111","email":"test@example.com"}"#
        case "/v1/auth/logout": body = #"{"ok":true}"#
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
#endif
