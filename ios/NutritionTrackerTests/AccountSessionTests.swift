import XCTest
@testable import nutrition_tracker

private final class TestSessionPersistence: SessionPersistence {
    var value: ServerSession?
    var failClear = false
    var failLoad = false
    func load() throws -> ServerSession? { if failLoad { throw AccountError.storage }; return value }
    func save(_ session: ServerSession) throws { value = session }
    func clear() throws { if failClear { throw AccountError.storage }; value = nil }
}

@MainActor private final class UploadHealthClient: HealthDataClient {
    var isAvailable = true
    var queriedAnchors: [Data?] = []
    let sample = HealthSampleRecord(id: UUID(), metric: .weight, startDate: .now, endDate: .now,
        value: 80, sourceName: "Fixture", sourceBundleIdentifier: "fixture", deviceName: nil, workoutActivityCode: nil)
    func requestReadAccess(to metrics: Set<HealthMetric>) async throws {}
    func changes(for metric: HealthMetric, start: Date?, anchor: Data?) async throws -> HealthDelta {
        XCTAssertEqual(metric, .weight); XCTAssertNil(start)
        queriedAnchors.append(anchor)
        return HealthDelta(samples: anchor == nil ? [sample] : [], deletedIDs: [], anchor: Data([1]), hasMore: false)
    }
    func dailyStatistics(for metric: HealthMetric, start: Date, end: Date, calendar: Calendar) async throws -> [HealthDayValue] { [] }
}
@MainActor private final class UploadHealthPersistence: HealthPersistence {
    func load() throws -> HealthSnapshot {
        var value = HealthSnapshot()
        value.configuration = HealthImportConfiguration(metrics: [.weight], startDate: .now, timeZoneIdentifier: "America/Montevideo")
        value.isConnected = true
        return value
    }
    func save(_ snapshot: HealthSnapshot) throws {}
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
    func testSessionUnavailableWhileLockedCanBeRestoredWithoutSigningInAgain() {
        let persistence = TestSessionPersistence()
        persistence.value = ServerSession(token: "test-token", user_id: "owner", expires_at: "2099-01-01T00:00:00Z")
        persistence.failLoad = true
        let account = AccountSession(persistence: persistence)
        XCTAssertNil(account.session)
        XCTAssertNotNil(persistence.value)
        persistence.failLoad = false
        account.restoreSessionIfNeeded()
        XCTAssertEqual(account.session?.user_id, "owner")
        XCTAssertNil(account.errorKey)
    }

    func testUnlockDoesNotRestoreAnExpiredSession() {
        let persistence = TestSessionPersistence()
        persistence.value = ServerSession(token: "test-token", user_id: "owner", expires_at: "2000-01-01T00:00:00Z")
        persistence.failLoad = true
        let account = AccountSession(persistence: persistence)
        persistence.failLoad = false
        account.restoreSessionIfNeeded()
        XCTAssertNil(account.session)
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
    func testExpiredStoredSessionIsRemovedBeforeAppCanOpen() {
        let persistence = TestSessionPersistence()
        persistence.value = ServerSession(token: "expired", user_id: "owner", expires_at: "2000-01-01T00:00:00Z")
        let account = AccountSession(persistence: persistence)
        XCTAssertNil(account.session)
        XCTAssertNil(persistence.value)
        XCTAssertEqual(account.errorKey, "Your session expired. Sign in again.")
    }
    func testExpiredStoredSessionDoesNotOpenAppWhenKeychainRemovalFails() {
        let persistence = TestSessionPersistence()
        persistence.value = ServerSession(token: "expired", user_id: "owner", expires_at: "2000-01-01T00:00:00Z")
        persistence.failClear = true
        let account = AccountSession(persistence: persistence)
        XCTAssertNil(account.session)
        XCTAssertNotNil(persistence.value)
        XCTAssertNotNil(account.errorKey)
    }
    func testBackendFractionalTimestampExpiresStoredSession() {
        let persistence = TestSessionPersistence()
        persistence.value = ServerSession(token: "expired", user_id: "owner", expires_at: "2000-01-01T00:00:00.123456+00:00")
        let account = AccountSession(persistence: persistence)
        XCTAssertNil(account.session)
        XCTAssertNil(persistence.value)
    }
    func testInvalidStoredExpirationRequiresLogin() {
        let persistence = TestSessionPersistence()
        persistence.value = ServerSession(token: "invalid", user_id: "owner", expires_at: "invalid-date")
        XCTAssertNil(AccountSession(persistence: persistence).session)
        XCTAssertNil(persistence.value)
    }
    func testRejectedSessionBlocksAppEvenWhenKeychainRemovalFails() async {
        let (account, persistence) = setup()
        persistence.failClear = true
        AccountURLProtocol.handler = { _ in (401, "{}") }
        await account.refreshProfile()
        XCTAssertNil(account.session)
        XCTAssertNotNil(persistence.value)
        XCTAssertEqual(account.errorKey, "Could not securely remove your session.")
    }
    func testWeightRequestRejectionAlsoRequiresLogin() async {
        let (account, persistence) = setup()
        AccountURLProtocol.handler = { _ in (401, "{}") }
        do {
            let _: AccountProfile = try await account.weightRequest("v1/health/weights")
            XCTFail("Expected session rejection")
        } catch { }
        XCTAssertNil(account.session)
        XCTAssertNil(persistence.value)
    }
    func testRevokedSessionCannotUnlockAppWhenLogoutKeychainRemovalFails() async {
        let (account, persistence) = setup()
        persistence.failClear = true
        AccountURLProtocol.handler = { _ in (200, #"{"ok":true}"#) }
        await account.signOut()
        XCTAssertNil(account.session)
        XCTAssertNotNil(persistence.value)
        XCTAssertEqual(account.errorKey, "Could not securely remove your session.")
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
    func testWeightUploadRequiresConsentAndPersistsExactRetryBeforeAdvancingAnchor() async throws {
        let owner = UUID(); let (account, _) = setup(owner: owner.uuidString)
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let uploader = HealthWeightUpload(root: root)
        let client = UploadHealthClient()
        let health = HealthSyncModel(client: client, persistence: UploadHealthPersistence())
        await uploader.sync(account: account, health: health)
        XCTAssertTrue(client.queriedAnchors.isEmpty)
        AccountURLProtocol.handler = { _ in (200, #"{"enabled":true,"version":1}"#) }
        await uploader.setConsent(enabled: true, account: account, health: health)
        XCTAssertTrue(uploader.isEnabled)
        AccountURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("consent") == true { return (200, #"{"enabled":true,"version":1}"#) }
            throw URLError(.notConnectedToInternet)
        }
        await uploader.sync(account: account, health: health)
        XCTAssertNotNil(uploader.errorKey)
        let file = root.appendingPathComponent(owner.uuidString + ".json")
        let failed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(failed["anchor"])
        let pending = try XCTUnwrap(failed["pending"] as? [String: Any])
        let original = try XCTUnwrap((pending["body"] as? [String: Any])?["request_id"] as? String)
        AccountURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("consent") == true { return (200, #"{"enabled":true,"version":1}"#) }
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            let body = (saved["pending"] as! [String: Any])["body"] as! [String: Any]
            XCTAssertEqual(body["request_id"] as? String, original)
            return (200, "{\"saved\":true,\"request_id\":\"" + original + "\"}")
        }
        await uploader.sync(account: account, health: health)
        XCTAssertNil(uploader.errorKey)
        XCTAssertEqual(client.queriedAnchors.count, 2)
        XCTAssertEqual(client.queriedAnchors.last!, Data([1]))
        let restored = HealthWeightUpload(root: root); restored.selectAccount(owner.uuidString)
        XCTAssertTrue(restored.isEnabled)
        restored.selectAccount(UUID().uuidString)
        XCTAssertFalse(restored.isEnabled)
    }
    func testOfflineRevocationStopsLocallyAndIsRetriedAfterRestart() async throws {
        let owner = UUID(); let (account, _) = setup(owner: owner.uuidString)
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let health = HealthSyncModel(client: UploadHealthClient(), persistence: UploadHealthPersistence())
        let uploader = HealthWeightUpload(root: root)
        AccountURLProtocol.handler = { _ in (200, #"{"enabled":true,"version":1}"#) }
        await uploader.setConsent(enabled: true, account: account, health: health)
        AccountURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await uploader.setConsent(enabled: false, deleteData: true, account: account, health: health)
        XCTAssertFalse(uploader.isEnabled)
        let restored = HealthWeightUpload(root: root); restored.selectAccount(owner.uuidString)
        AccountURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/health/weight/consent")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, #"{"enabled":false,"version":2}"#)
        }
        await restored.sync(account: account, health: health)
        XCTAssertFalse(restored.isEnabled); XCTAssertNil(restored.errorKey)
    }
}
