import XCTest
@testable import nutrition_tracker

private final class TestSessionPersistence: SessionPersistence {
    var value: ServerSession?
    var failClear = false
    func load() throws -> ServerSession? { value }
    func save(_ session: ServerSession) throws { value = session }
    func clear() throws { if failClear { throw AccountError.storage }; value = nil }
}

private final class AccountURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor final class AccountSessionTests: XCTestCase {
    private func setup(signedIn: Bool = true) -> (AccountSession, TestSessionPersistence) {
        let persistence = TestSessionPersistence()
        if signedIn { persistence.value = ServerSession(token: "test-token", user_id: "owner", expires_at: "2099-01-01T00:00:00Z") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AccountURLProtocol.self]
        return (AccountSession(persistence: persistence, network: URLSession(configuration: config)), persistence)
    }
    func testProfileUsesStoredBearerAndRejectsDifferentOwner() async {
        let (account, _) = setup()
        AccountURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, #"{"user_id":"foreign","email":"foreign@example.com"}"#)
        }
        await account.refreshProfile()
        XCTAssertNil(account.email)
        XCTAssertEqual(account.session?.user_id, "owner")
        XCTAssertNotNil(account.errorKey)
    }
    func testExpiredSessionClearsKeychainAndIdentity() async {
        let (account, persistence) = setup()
        AccountURLProtocol.handler = { _ in (401, "{}") }
        await account.refreshProfile()
        XCTAssertNil(account.session); XCTAssertNil(persistence.value)
        XCTAssertEqual(account.errorKey, "Your session expired. Sign in again.")
    }
    func testLogoutOfflineKeepsSessionForRetryAndSuccessClearsIt() async {
        let (account, persistence) = setup()
        AccountURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await account.signOut()
        XCTAssertNotNil(account.session); XCTAssertNotNil(persistence.value)
        AccountURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/logout")
            return (200, #"{"ok":true}"#)
        }
        await account.signOut()
        XCTAssertNil(account.session); XCTAssertNil(persistence.value)
    }
    func testChallengePreparationHasNoBearerAndIsNotStoredAsSession() async {
        let (account, persistence) = setup(signedIn: false)
        AccountURLProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, #"{"challenge_id":"one-time","nonce":"hashed-nonce"}"#)
        }
        await account.prepareApple()
        XCTAssertEqual(account.challenge?.nonce, "hashed-nonce")
        XCTAssertNil(account.session); XCTAssertNil(persistence.value)
    }
}
