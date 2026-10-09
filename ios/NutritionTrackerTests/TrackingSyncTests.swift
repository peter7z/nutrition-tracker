import XCTest
@testable import nutrition_tracker

@MainActor final class TrackingSyncTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-10-08T15:00:00Z")!
    private func draft(_ amount: Double = 150) -> FoodEntryDraft { FoodEntryDraft(name: "Banana", consumedAt: date, amount: amount, nutrition: NutrientValues(energy: 89, protein: 1.1, carbohydrates: 22.8, fat: 0.3)) }
    func testSyncPublishesOwnedDomainAndRetainsDraftWithoutHealthPayload() async throws {
        let memory = TrackingMemory(); let store = NutritionStore(persistence: memory)
        try store.addEntry(draft()); try store.setChatDraft("Unsent local draft")
        let remote = TrackingFakeRemote(); let sync = TrackingSync(persistence: TrackingJournal())
        try await sync.sync(store: store, remote: remote)
        XCTAssertEqual(remote.requests.count, 1); XCTAssertEqual(store.snapshot.entries.filter { !$0.deleted }.count, 1)
        XCTAssertEqual(store.snapshot.chatDraft, "Unsent local draft")
        XCTAssertEqual(Set(remote.requests[0].operations.map(\.kind)), ["profile", "entry", "day"])
        XCTAssertFalse(String(data: try JSONEncoder().encode(remote.requests[0]), encoding: .utf8)!.contains("HealthSample"))
        try await sync.sync(store: store, remote: remote); XCTAssertEqual(remote.requests.count, 1)
    }
    func testLostAcknowledgementReusesRequestAndOperationIDsWithoutDuplicate() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); try store.addEntry(draft())
        let remote = TrackingFakeRemote(); remote.failAfterCommit = true
        let sync = TrackingSync(persistence: TrackingJournal())
        do { try await sync.sync(store: store, remote: remote); XCTFail("expected lost response") } catch {}
        XCTAssertEqual(remote.records.filter { $0.kind == "entry" }.count, 1)
        try await sync.sync(store: store, remote: remote)
        XCTAssertEqual(remote.requests.count, 2)
        XCTAssertEqual(remote.requests[0].request_id, remote.requests[1].request_id)
        XCTAssertEqual(remote.requests[0].operations.map(\.operation_id), remote.requests[1].operations.map(\.operation_id))
        XCTAssertEqual(remote.records.filter { $0.kind == "entry" }.count, 1)
    }
    func testAssistantMutationIsUnpublishedUntilAcknowledgedAndSaveFailureRetriesJournal() async throws {
        let memory = TrackingMemory(); let store = NutritionStore(persistence: memory)
        let stagedMemory = TrackingMemory(); stagedMemory.value = store.snapshot
        let staged = NutritionStore(persistence: stagedMemory); try staged.addEntry(draft())
        let remote = TrackingFakeRemote(); remote.failBeforeCommit = true
        let journal = TrackingJournal(); let sync = TrackingSync(persistence: journal)
        do { try await sync.applyConfirmed(staged.snapshot, store: store, remote: remote, operationID: UUID()); XCTFail() } catch {}
        XCTAssertTrue(store.snapshot.entries.isEmpty)
        remote.failBeforeCommit = false; memory.failSave = true
        do { try await sync.sync(store: store, remote: remote); XCTFail() } catch {}
        XCTAssertTrue(store.snapshot.entries.isEmpty)
        memory.failSave = false; try await sync.sync(store: store, remote: remote)
        XCTAssertEqual(store.snapshot.entries.filter { !$0.deleted }.count, 1)
        XCTAssertEqual(store.snapshot.changes.count, staged.snapshot.changes.count)
    }
    func testRemoteOnlyMergeAndTwoOwnerLateResponseCannotPublish() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); let remote = TrackingFakeRemote()
        let other = NutritionStore(persistence: TrackingMemory()); try other.addEntry(draft())
        let entry = other.snapshot.entries[0]
        remote.records = [RemoteRecord(id: entry.id.uuidString, kind: "entry", version: 1, payload: try JSONValue.encode(entry))]
        let sync = TrackingSync(persistence: TrackingJournal())
        try await sync.sync(store: store, remote: remote)
        XCTAssertEqual(store.snapshot.entries[0].id, entry.id)
        let blank = NutritionStore(persistence: TrackingMemory()); remote.switchOwnerDuringState = true
        do { try await sync.sync(store: blank, remote: remote); XCTFail() } catch {}
        XCTAssertTrue(blank.snapshot.entries.isEmpty)
    }
    func testConcurrentLocalAndRemoteCorrectionConflictsWithoutOverwrite() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); let id = try store.addEntry(draft())
        let remote = TrackingFakeRemote(); let sync = TrackingSync(persistence: TrackingJournal())
        try await sync.sync(store: store, remote: remote)
        try store.updateEntry(id: id, expectedVersion: 1, draft: draft(100))
        let index = remote.records.firstIndex { $0.kind == "entry" }!
        var entry = try remote.records[index].payload.decode(FoodEntry.self); entry.draft.amount = 120; entry.version = 2
        remote.records[index].payload = try JSONValue.encode(entry); remote.records[index].version += 1; remote.revision += 1
        do { try await sync.sync(store: store, remote: remote); XCTFail() } catch {}
        XCTAssertEqual(store.snapshot.entries[0].draft.amount, 100)
        XCTAssertEqual(remote.records[index].payload, try JSONValue.encode(entry))
    }
    func testPerRecordConflictChoicesPreserveUnrelatedEditsAndRejectStaleReview() async throws {
        for choice in [TrackingConflictChoice.local, .server] {
            let store = NutritionStore(persistence: TrackingMemory()); let id = try store.addEntry(draft())
            let remote = TrackingFakeRemote(); let engine = TrackingSync(persistence: TrackingJournal())
            try await engine.sync(store: store, remote: remote)
            try store.updateEntry(id: id, expectedVersion: 1, draft: draft(100))
            let extraID = try store.addEntry(draft(50))
            let index = remote.records.firstIndex { $0.kind == "entry" }!
            var remoteEntry = try remote.records[index].payload.decode(FoodEntry.self)
            remoteEntry.draft.amount = 120; remoteEntry.version = 2
            remote.records[index].payload = try JSONValue.encode(remoteEntry); remote.records[index].version += 1; remote.revision += 1
            let review = try await engine.conflictReview(store: store, remote: remote)
            XCTAssertEqual(review.conflicts.count, 1)
            try await engine.resolve(review, choices: [review.conflicts[0].id: choice], store: store, remote: remote)
            XCTAssertEqual(store.snapshot.entries.first { $0.id == id }?.draft.amount, choice == .local ? 100 : 120)
            XCTAssertEqual(store.snapshot.entries.first { $0.id == extraID }?.draft.amount, 50)
            let entry = try remote.records.first { $0.id.lowercased() == id.uuidString.lowercased() }!.payload.decode(FoodEntry.self)
            XCTAssertEqual(entry.version, choice == .local ? 3 : 2)
            do { try await engine.resolve(review, choices: [review.conflicts[0].id: choice], store: store, remote: remote); XCTFail("stale review accepted") } catch {}
            remote.ownerID = UUID().uuidString
            do { try await engine.resolve(review, choices: [review.conflicts[0].id: choice], store: store, remote: remote); XCTFail("foreign review accepted") } catch {}
        }
    }
    func testOfflineReopenCorrectionRecloseSendsIntermediateOpenInOrder() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); let id = try store.addEntry(draft()); try store.closeDay(date)
        let remote = TrackingFakeRemote(); let sync = TrackingSync(persistence: TrackingJournal())
        try await sync.sync(store: store, remote: remote)
        try store.reopenDay(date); try store.updateEntry(id: id, expectedVersion: 1, draft: draft(100)); try store.closeDay(date)
        try await sync.sync(store: store, remote: remote)
        let ops = remote.requests.last!.operations
        XCTAssertEqual(ops.first?.kind, "day"); XCTAssertEqual(try ops.first?.payload?.decode(NutritionDayLog.self).isClosed, false)
        XCTAssertEqual(ops.last?.kind, "day"); XCTAssertEqual(try ops.last?.payload?.decode(NutritionDayLog.self).isClosed, true)
        XCTAssertEqual(ops.first?.expected_version, 1); XCTAssertEqual(ops.last?.expected_version, 2)
    }
    func testCheckpointFailureAfterPublishingRecoversAcknowledgedJournal() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); try store.addEntry(draft())
        let journal = TrackingJournal(); journal.failSaveNumber = 3
        let sync = TrackingSync(persistence: journal); let remote = TrackingFakeRemote()
        do { try await sync.sync(store: store, remote: remote); XCTFail() } catch {}
        XCTAssertEqual(remote.requests.count, 1)
        journal.failSaveNumber = nil; try await sync.sync(store: store, remote: remote)
        XCTAssertEqual(remote.requests.count, 1)
        XCTAssertEqual(store.snapshot.entries.filter { !$0.deleted }.count, 1)
    }
    func testLargeImportBatchesPersistRetryIDsAndPublishOnlyAfterAllAcks() async throws {
        let memory = TrackingMemory()
        for _ in 0..<205 { memory.value.entries.append(FoodEntry(id: UUID(), version: 1, dayID: "2026-10-08", draft: draft(), createdAt: date, updatedAt: date)) }
        let store = NutritionStore(persistence: memory); let remote = TrackingFakeRemote(); remote.failOnRequest = 2
        let journal = TrackingJournal(); let sync = TrackingSync(persistence: journal)
        do { try await sync.sync(store: store, remote: remote); XCTFail() } catch {}
        XCTAssertEqual(remote.requests.count, 2); XCTAssertEqual(remote.requests[0].operations.count, 200)
        let pendingID = remote.requests[1].request_id
        remote.failOnRequest = nil; try await sync.sync(store: store, remote: remote)
        XCTAssertEqual(remote.requests.last?.request_id, pendingID)
        XCTAssertEqual(remote.records.filter { $0.kind == "entry" }.count, 205)
        XCTAssertEqual(store.snapshot.entries.filter { !$0.deleted }.count, 205)
    }
    func testExplicitConflictResolutionUsesServerAndSeparateOwnersUseSeparateJournals() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); let id = try store.addEntry(draft())
        let journal = TrackingJournal(); let remote = TrackingFakeRemote(); let sync = TrackingSync(persistence: journal)
        try await sync.sync(store: store, remote: remote)
        try store.updateEntry(id: id, expectedVersion: 1, draft: draft(100))
        try await sync.replaceLocalWithRemote(store: store, remote: remote)
        XCTAssertEqual(store.snapshot.entries[0].draft.amount, 150)
        let other = TrackingFakeRemote(); let otherStore = NutritionStore(persistence: TrackingMemory())
        try await sync.sync(store: otherStore, remote: other)
        XCTAssertTrue(otherStore.snapshot.entries.isEmpty); XCTAssertEqual(journal.values.count, 2)
    }
    func testRemoteChatRehydratesOncePreservingLocalIDsDraftAndOutbox() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); let remote = TrackingFakeRemote()
        let requestID = UUID(); let localID = try store.enqueueChat(text: "Synthetic question", date: date, ownerID: remote.ownerID, operationID: requestID)
        try store.setChatDraft("New unsent draft")
        let user = RemoteMessage(id: UUID().uuidString, request_id: requestID.uuidString, role: "user", content: "Synthetic question", day: "2026-10-08", created_at: "2026-10-08T15:00:00.123456+00:00", proposals: [])
        let assistant = RemoteMessage(id: UUID().uuidString, request_id: requestID.uuidString, role: "assistant", content: "Synthetic answer", day: "2026-10-08", created_at: "2026-10-08T15:00:01+00:00", proposals: [])
        remote.messages = [user,assistant]
        let sync = TrackingSync(persistence: TrackingJournal()); try await sync.sync(store: store, remote: remote)
        XCTAssertEqual(store.snapshot.messages.count, 2); XCTAssertEqual(store.snapshot.messages.first(where: { $0.role == .user })?.id, localID)
        XCTAssertEqual(store.snapshot.outbox.first?.state, .delivered); XCTAssertEqual(store.snapshot.chatDraft, "New unsent draft")
        try await sync.sync(store: store, remote: remote); XCTAssertEqual(store.snapshot.messages.count, 2)
        let fresh = NutritionStore(persistence: TrackingMemory())
        try await sync.replaceLocalWithRemote(store: fresh, remote: remote); XCTAssertEqual(fresh.snapshot.messages.count, 2)
    }
    func testNativeDeliveredChatThenServerHydrationHasOneAssistantByRequestID() async throws {
        let remote = TrackingFakeRemote(); let owner = remote.ownerID!; let requestID = UUID()
        let store = NutritionStore(persistence: TrackingMemory())
        let userID = try store.enqueueChat(text: "Query", date: date, ownerID: owner, operationID: requestID)
        try store.appendAssistantMessage(text: "Original answer", date: date, replyTo: userID, ownerID: owner)
        try store.updateChatDelivery(messageID: userID, state: .delivered)
        let localAssistantID = store.snapshot.messages.first { $0.role == .assistant }!.id
        remote.messages = [
            RemoteMessage(id: UUID().uuidString, request_id: requestID.uuidString, role: "user", content: "Query", day: store.dayID(for: date), created_at: "2026-10-08T15:00:00Z", proposals: []),
            RemoteMessage(id: UUID().uuidString, request_id: requestID.uuidString, role: "assistant", content: "Original answer", day: store.dayID(for: date), created_at: "2026-10-08T15:00:01Z", proposals: [])
        ]
        let engine = TrackingSync(persistence: TrackingJournal())
        try await engine.sync(store: store, remote: remote)
        try await engine.sync(store: store, remote: remote)
        let assistants = store.snapshot.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 1)
        XCTAssertEqual(assistants.first?.id, localAssistantID)
        XCTAssertEqual(assistants.first?.operationID, requestID)
        XCTAssertEqual(store.snapshot.messages.filter { $0.role == .user }.count, 1)
    }
    func testUnansweredRemoteUserHasFailedOutboxWithoutInventedAssistant() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); let remote = TrackingFakeRemote()
        remote.messages = [RemoteMessage(id: UUID().uuidString, request_id: UUID().uuidString, role: "user", content: "Synthetic failed question", day: "2026-10-08", created_at: "2026-10-08T15:00:00Z", proposals: [])]
        try await TrackingSync(persistence: TrackingJournal()).sync(store: store, remote: remote)
        XCTAssertEqual(store.snapshot.messages.count, 1); XCTAssertEqual(store.snapshot.messages[0].state, .failed)
        XCTAssertEqual(store.snapshot.messages[0].requiresSavedResponse, true, "A second device lacks the original photo/consent request body")
        XCTAssertEqual(store.snapshot.outbox.count, 1); XCTAssertTrue(store.snapshot.messages.filter { $0.role == .assistant }.isEmpty)
    }
    func testMetadataTypedDuringStateFetchSurvivesNoOperationRefresh() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); let remote = TrackingFakeRemote(); let sync = TrackingSync(persistence: TrackingJournal())
        try await sync.sync(store: store, remote: remote)
        remote.onState = {
            try? store.setChatDraft("Typed while loading remote state")
            _ = try? store.enqueueChat(text: "New queued message during sync", date: self.date, ownerID: remote.ownerID)
            try? store.setChatDraft("Still editing")
        }
        try await sync.sync(store: store, remote: remote)
        XCTAssertEqual(store.snapshot.chatDraft, "Still editing")
        XCTAssertEqual(store.snapshot.messages.last?.text, "New queued message during sync")
        XCTAssertEqual(store.snapshot.outbox.count, 1)
    }
    func testDeleteTombstoneRemovesRemoteEntryButRetainsLocalUndoHistory() async throws {
        let store = NutritionStore(persistence: TrackingMemory()); let id = try store.addEntry(draft())
        let remote = TrackingFakeRemote(); let sync = TrackingSync(persistence: TrackingJournal())
        try await sync.sync(store: store, remote: remote); try store.deleteEntry(id: id, expectedVersion: 1)
        try await sync.sync(store: store, remote: remote)
        XCTAssertTrue(remote.records.filter { $0.kind == "entry" }.isEmpty)
        XCTAssertEqual(store.snapshot.entries.first?.deleted, true)
        XCTAssertEqual(store.snapshot.changes.count, 2)
    }
}

@MainActor private final class TrackingMemory: NutritionPersistence {
    var value = NutritionSnapshot(); var failSave = false
    func load() throws -> NutritionSnapshot { value }
    func save(_ snapshot: NutritionSnapshot) throws { if failSave { throw NutritionError.storageUnavailable }; value = snapshot }
}
@MainActor private final class TrackingJournal: TrackingCheckpointPersistence {
    var values: [String: Data] = [:]; var saves = 0; var failSaveNumber: Int?
    func load(scope: String) throws -> Data? { values[scope] }
    func save(_ data: Data, scope: String) throws { saves += 1; if saves == failSaveNumber { throw NutritionError.storageUnavailable }; values[scope] = data }
}
@MainActor private final class TrackingFakeRemote: TrackingRemoteTransport {
    var ownerID: String? = UUID().uuidString; var endpoint = "https://example.test"
    var revision = 0; var records: [RemoteRecord] = []; var messages: [RemoteMessage]?; var requests: [RemoteSyncRequest] = []
    var replies: [String: RemoteState] = [:]
    var failAfterCommit = false; var failBeforeCommit = false; var switchOwnerDuringState = false; var failOnRequest: Int?; var onState: (() -> Void)?
    func state() async throws -> RemoteState {
        onState?()
        if switchOwnerDuringState { ownerID = UUID().uuidString }
        return RemoteState(revision: revision, records: records, messages: messages)
    }
    func sync(_ body: RemoteSyncRequest) async throws -> RemoteState {
        requests.append(body)
        if let old = replies[body.request_id] { return old }
        if failBeforeCommit || requests.count == failOnRequest { throw RemoteError.offline }
        guard body.base_revision == revision else { throw RemoteError.conflict }
        var candidate = records
        for op in body.operations {
            let index = candidate.firstIndex { $0.id.lowercased() == op.id.lowercased() }
            guard (index.map { candidate[$0].version } ?? 0) == op.expected_version else { throw RemoteError.conflict }
            if op.action == "delete" { if let index { candidate.remove(at: index) } }
            else {
                let record = RemoteRecord(id: op.id, kind: op.kind, version: op.expected_version + 1, payload: op.payload!)
                if let index { candidate[index] = record } else { candidate.append(record) }
            }
        }
        records = candidate; revision += 1
        let result = RemoteState(revision: revision, records: records); replies[body.request_id] = result
        if failAfterCommit { failAfterCommit = false; throw RemoteError.offline }
        return result
    }
}
