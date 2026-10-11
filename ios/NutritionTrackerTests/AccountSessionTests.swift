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
    private func setup(signedIn: Bool = true, owner: String = "owner") -> (AccountSession, TestSessionPersistence) {
        let persistence = TestSessionPersistence()
        if signedIn { persistence.value = ServerSession(token: "test-token", user_id: owner, expires_at: "2099-01-01T00:00:00Z") }
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
    func testDiaryDownloadUsesSessionBearerAndStateEndpoint() async throws {
        let (account, _) = setup()
        AccountURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/state")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, #"{"revision":0,"records":[],"messages":[]}"#)
        }
        let data = try await account.fetchDiary()
        XCTAssertTrue(try BackendDiary.decode(data).entries.isEmpty)
    }
    func testDiaryExpiryRemovesSessionButOfflineFailureKeepsIt() async {
        let (account, persistence) = setup()
        AccountURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await account.fetchDiary(); XCTFail("Expected offline error") } catch { }
        XCTAssertNotNil(account.session)
        AccountURLProtocol.handler = { _ in (401, "{}") }
        do { _ = try await account.fetchDiary(); XCTFail("Expected expired session") } catch { }
        XCTAssertNil(account.session); XCTAssertNil(persistence.value)
    }
    func testRefreshReplacesCorrectedDeletedEntriesAndRetainsCacheOffline() async throws {
        let owner = UUID()
        let (account, _) = setup(owner: owner.uuidString)
        let store = NutritionStore(persistence: NutritionFileRepository(fileURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let cache = BackendDiary.cacheURL(owner: owner)
        defer { try? FileManager.default.removeItem(at: cache) }
        var draft = CompanionTestFixture.history(on: .now).entries[0].draft
        let entryID = UUID()
        func state(_ version: Int, includeEntry: Bool) throws -> String {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let object = try JSONSerialization.jsonObject(with: encoder.encode(draft))
            let records: [[String: Any]] = includeEntry ? [["kind": "entry", "id": entryID.uuidString,
                "version": version, "payload": ["draft": object]]] : []
            return String(decoding: try JSONSerialization.data(withJSONObject: ["revision": version, "records": records]), as: UTF8.self)
        }
        let first = try state(1, includeEntry: true)
        AccountURLProtocol.handler = { _ in (200, first) }
        await store.refresh(account: account)
        XCTAssertEqual(store.snapshot.entries.count, 1)
        draft.nutrition.energy = 200
        let correction = try state(2, includeEntry: true)
        AccountURLProtocol.handler = { _ in (200, correction) }
        await store.refresh(account: account)
        XCTAssertEqual(store.snapshot.entries.count, 1)
        XCTAssertEqual(store.snapshot.entries[0].version, 2)
        XCTAssertEqual(store.snapshot.entries[0].draft.nutrition.energy, 200)
        let bytes = try Data(contentsOf: cache)
        AccountURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await store.refresh(account: account)
        XCTAssertEqual(store.snapshot.entries.count, 1)
        XCTAssertEqual(try Data(contentsOf: cache), bytes)
        XCTAssertNotNil(store.errorKey)
        AccountURLProtocol.handler = { _ in (200, "{\"records\":[]}") }
        await store.refresh(account: account)
        XCTAssertEqual(store.snapshot.entries.count, 1)
        XCTAssertEqual(try Data(contentsOf: cache), bytes)
        let deleted = try state(3, includeEntry: false)
        AccountURLProtocol.handler = { _ in (200, deleted) }
        await store.refresh(account: account)
        XCTAssertTrue(store.snapshot.entries.isEmpty)
        XCTAssertNil(store.errorKey)
    }
    func testPendingResponseCannotRestorePreviousAccountDiary() async throws {
        let first = UUID(); let second = UUID()
        let (account, _) = setup(owner: first.uuidString)
        let store = NutritionStore(persistence: NutritionFileRepository(fileURL: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        let started = expectation(description: "Diary request started")
        let release = DispatchSemaphore(value: 0)
        AccountURLProtocol.handler = { _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return (200, #"{"revision":1,"records":[],"messages":[]}"#)
        }
        let refresh = Task { await store.refresh(account: account) }
        await fulfillment(of: [started], timeout: 2)
        store.selectAccount(second.uuidString)
        release.signal()
        await refresh.value
        XCTAssertEqual(store.ownerID, second.uuidString)
        XCTAssertTrue(store.snapshot.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: BackendDiary.cacheURL(owner: first).path))
    }
}
