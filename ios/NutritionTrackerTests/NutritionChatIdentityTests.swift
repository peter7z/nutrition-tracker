import XCTest
@testable import nutrition_tracker

@MainActor final class NutritionChatIdentityTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_475_200)
    func testDeletingAnUndeliveredPhotoCancelsOutboxAndPreventsChangedRequestRetryAfterRelaunch() async throws {
        for initialState in [ChatDeliveryState.queued, .sending, .failed, .cancelled] {
            let repository = ChatIdentityPersistence(); let store = NutritionStore(persistence: repository)
            let owner = UUID().uuidString
            let photo = NutritionAttachment(id: UUID(), relativePath: "fixture.jpg", mimeType: "image/jpeg", byteCount: 100, createdAt: date, remoteOwnerID: owner)
            try store.saveAttachment(photo)
            let userID = try store.enqueueChat(text: "Analyze fixture photo", date: date, attachmentIDs: [photo.id], ownerID: owner)
            try store.updateChatDelivery(messageID: userID, state: initialState)
            try store.removeAttachment(id: photo.id)
            let reopened = NutritionStore(persistence: repository)
            let user = try XCTUnwrap(reopened.snapshot.messages.first { $0.id == userID })
            XCTAssertEqual(user.text, "Analyze fixture photo")
            XCTAssertTrue(user.attachmentIDs.isEmpty); XCTAssertEqual(user.attachmentRemoved, true)
            XCTAssertEqual(user.state, .cancelled); XCTAssertFalse(user.canRetrieveOrRetry)
            XCTAssertEqual(reopened.snapshot.outbox.first?.state, .cancelled)
            XCTAssertTrue(reopened.snapshot.attachments.isEmpty)
        }
    }
    func testDeletingDeliveredPhotoPreservesCachedReviewAndLegacyBackupCompatibility() async throws {
        let repository = ChatIdentityPersistence(); let store = NutritionStore(persistence: repository)
        let photo = NutritionAttachment(id: UUID(), relativePath: "fixture.jpg", mimeType: "image/jpeg", byteCount: 100, createdAt: date)
        try store.saveAttachment(photo)
        let userID = try store.enqueueChat(text: "Analyze fixture photo", date: date, attachmentIDs: [photo.id])
        try store.appendAssistantMessage(text: "Existing analysis", date: date, replyTo: userID)
        try store.updateChatDelivery(messageID: userID, state: .delivered)
        let answer = store.snapshot.messages.last
        try store.removeAttachment(id: photo.id)
        let user = try XCTUnwrap(store.snapshot.messages.first { $0.id == userID })
        XCTAssertEqual(user.state, .delivered); XCTAssertEqual(user.attachmentRemoved, true)
        XCTAssertTrue(user.canRetrieveOrRetry); XCTAssertEqual(store.snapshot.messages.last, answer)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(user)) as? [String: Any])
        legacyObject.removeValue(forKey: "attachmentRemoved")
        let legacy = try JSONDecoder().decode(PersistentChatMessage.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        XCTAssertNil(legacy.attachmentRemoved); XCTAssertTrue(legacy.canRetrieveOrRetry)
    }
    func testNativeAssistantUsesRequestIdentityAndHydratedResponseDoesNotDuplicate() async throws {
        let repository = ChatIdentityPersistence(); let store = NutritionStore(persistence: repository)
        let request = UUID(); let owner = UUID().uuidString
        let userID = try store.enqueueChat(text: "Fixture question", date: date, ownerID: owner, operationID: request)
        XCTAssertNotEqual(userID, request)
        try store.appendAssistantMessage(text: "Fixture answer", date: date, replyTo: userID, ownerID: owner)
        let answer = try XCTUnwrap(store.snapshot.messages.first { $0.role == .assistant })
        XCTAssertEqual(answer.operationID, request)
        let reopened = NutritionStore(persistence: repository)
        try reopened.appendAssistantMessage(text: "Retry answer", date: date, replyTo: userID, ownerID: owner)
        XCTAssertEqual(reopened.snapshot.messages.filter { $0.role == .assistant }, [answer])
        // A remote reply hydrated before native delivery has the same operation identity.
        repository.snapshot.messages.removeAll { $0.role == .assistant }
        var hydrated = answer; hydrated.id = UUID(); hydrated.text = "Hydrated fixture answer"
        repository.snapshot.messages.append(hydrated)
        let fromRemote = NutritionStore(persistence: repository)
        try fromRemote.appendAssistantMessage(text: "Duplicate callback", date: date, replyTo: userID, ownerID: owner)
        XCTAssertEqual(fromRemote.snapshot.messages.filter { $0.role == .assistant }, [hydrated])
    }
    func testLegacyAssistantMigratesInPlaceAndOwnerMismatchCannotAppendOrChangeIt() async throws {
        let repository = ChatIdentityPersistence(); let store = NutritionStore(persistence: repository)
        let request = UUID(); let owner = UUID().uuidString
        let userID = try store.enqueueChat(text: "Fixture question", date: date, ownerID: owner, operationID: request)
        let legacy = PersistentChatMessage(id: UUID(), role: .assistant, text: "Existing answer", createdAt: date,
            dayID: store.dayID(for: date), state: .delivered, operationID: userID, remoteOwnerID: owner)
        repository.snapshot.messages.append(legacy)
        let reopened = NutritionStore(persistence: repository); let before = reopened.snapshot
        XCTAssertThrowsError(try reopened.appendAssistantMessage(text: "Foreign", date: date, replyTo: userID, ownerID: UUID().uuidString)) {
            XCTAssertEqual($0 as? NutritionError, .conflict)
        }
        XCTAssertEqual(reopened.snapshot, before)
        try reopened.appendAssistantMessage(text: "Retry", date: date, replyTo: userID, ownerID: owner)
        let migrated = try XCTUnwrap(reopened.snapshot.messages.first { $0.role == .assistant })
        XCTAssertEqual(migrated.id, legacy.id); XCTAssertEqual(migrated.text, legacy.text); XCTAssertEqual(migrated.operationID, request)
        XCTAssertEqual(reopened.snapshot.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(repository.snapshot, reopened.snapshot)
    }
    func testLocalLegacyUserWithoutOperationIdentityKeepsLocalReplyIdempotent() async throws {
        let repository = ChatIdentityPersistence(); let id = UUID()
        repository.snapshot.messages = [PersistentChatMessage(id: id, role: .user, text: "Local fixture", createdAt: date,
            dayID: repository.snapshot.profile.dayID(for: date), state: .delivered)]
        let store = NutritionStore(persistence: repository)
        try store.appendAssistantMessage(text: "Local response", date: date, replyTo: id)
        try store.appendAssistantMessage(text: "Retry", date: date, replyTo: id)
        XCTAssertEqual(store.snapshot.messages.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(store.snapshot.messages.last?.operationID, id); XCTAssertNil(store.snapshot.messages.last?.remoteOwnerID)
    }
}

@MainActor private final class ChatIdentityPersistence: NutritionPersistence {
    var snapshot = NutritionSnapshot()
    func load() throws -> NutritionSnapshot { snapshot }
    func save(_ candidate: NutritionSnapshot) throws { snapshot = candidate }
}
