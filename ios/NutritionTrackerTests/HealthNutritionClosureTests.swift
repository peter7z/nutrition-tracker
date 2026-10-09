import XCTest
@testable import nutrition_tracker

@MainActor final class HealthNutritionClosureTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_475_200)
    private let goals = NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 60)
    private func fixture() -> HealthSnapshot {
        var snapshot = HealthSnapshot()
        snapshot.configuration = HealthImportConfiguration(metrics: [.dietaryEnergy, .protein, .steps], startDate: nil, timeZoneIdentifier: "America/Montevideo")
        let start = snapshot.configuration!.calendar.startOfDay(for: date)
        snapshot.dailyValues = [HealthDayValue(metric: .dietaryEnergy, date: start, value: 1000, sourceNames: ["Fixture"]), HealthDayValue(metric: .protein, date: start, value: 50, sourceNames: ["Fixture"])]
        snapshot.isConnected = true
        return snapshot
    }
    private func context(consent: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["consent": consent, "purpose": "chat", "day": "2026-10-08", "metrics": ["weight_kg": 73.0, "steps": 4000.0]])
    }
    func testHealthClosureFreezesValuesAndGoalsAcrossRefreshReconfigureAndDisconnect() async throws {
        let repository = ClosureHealthPersistence(); repository.snapshot = fixture()
        let client = ClosureHealthClient(); let model = HealthSyncModel(client: client, persistence: repository, now: { self.date })
        let id = try model.recordNutritionClosure(on: date, dayID: "2026-10-08", accountScope: "local", goals: goals)
        client.statistics = [HealthDayValue(metric: .dietaryEnergy, date: date, value: 1500, sourceNames: ["Changed fixture"])]
        await model.refreshIfConnected()
        let closure = model.snapshot.closedNutritionDays!.first!
        XCTAssertEqual(closure.id, id); XCTAssertEqual(closure.values.first { $0.metric == .dietaryEnergy }?.value, 1000)
        XCTAssertEqual(closure.goals, goals)
        await model.prepareImport(configuration: HealthImportConfiguration(metrics: [.steps], startDate: nil, timeZoneIdentifier: "America/Montevideo"))
        XCTAssertEqual(model.stagedImport?.snapshot.closedNutritionDays, [closure])
        model.confirmImport()
        XCTAssertEqual(model.snapshot.closedNutritionDays, [closure]); XCTAssertNil(model.snapshot.value(for: .dietaryEnergy, on: date))
        model.disconnect(removeLocalCopy: false)
        XCTAssertEqual(model.snapshot.closedNutritionDays, [closure])
        let reopened = HealthSyncModel(client: client, persistence: repository)
        XCTAssertEqual(reopened.snapshot.closedNutritionDays, [closure])
        model.disconnect(removeLocalCopy: true)
        XCTAssertNil(model.snapshot.closedNutritionDays)
    }
    func testHealthClosureSaveFailureDoesNotPublishAndRollbackRemovesOnlyItsClosure() async throws {
        let repository = ClosureHealthPersistence(); repository.snapshot = fixture()
        let model = HealthSyncModel(client: ClosureHealthClient(), persistence: repository, now: { self.date })
        let before = model.snapshot; repository.failSave = true
        XCTAssertThrowsError(try model.recordNutritionClosure(on: date, dayID: "2026-10-08", accountScope: "local", goals: goals))
        XCTAssertEqual(model.snapshot, before); XCTAssertEqual(repository.snapshot, before)
        repository.failSave = false
        let first = try model.recordNutritionClosure(on: date, dayID: "2026-10-08", accountScope: "local", goals: goals)
        try model.removeClosure(id: first)
        XCTAssertEqual(model.snapshot, before, "Rollback of the first Health close must recover the exact previously published snapshot")
        let retained = try model.recordNutritionClosure(on: date, dayID: "2026-10-08", accountScope: "local", goals: goals)
        let second = try model.recordNutritionClosure(on: date, dayID: "2026-10-09", accountScope: UUID().uuidString, goals: nil)
        try model.removeClosure(id: second)
        XCTAssertEqual(model.snapshot.closedNutritionDays?.map(\.id), [retained])
        repository.failSave = true
        XCTAssertThrowsError(try model.removeClosure(id: retained))
        XCTAssertEqual(model.snapshot.closedNutritionDays?.map(\.id), [retained])
    }
    func testClosureRestoreValidationRejectsRawActivityAndInvalidScopesButAllowsOldSnapshots() async throws {
        let model = HealthSyncModel(client: ClosureHealthClient(), persistence: ClosureHealthPersistence())
        var invalid = fixture()
        invalid.closedNutritionDays = [HealthNutritionClosure(id: UUID(), accountScope: "another-person", dayID: "2026-10-08", closedAt: date, values: [], goals: nil)]
        XCTAssertThrowsError(try model.validateRestoredSnapshot(invalid))
        invalid.closedNutritionDays![0].accountScope = "local"
        invalid.closedNutritionDays![0].values = [HealthDayValue(metric: .steps, date: date, value: 4000, sourceNames: [])]
        XCTAssertThrowsError(try model.validateRestoredSnapshot(invalid))
        invalid.closedNutritionDays![0].values = [HealthDayValue(metric: .dietaryEnergy, date: date, value: -.infinity, sourceNames: [])]
        XCTAssertThrowsError(try model.validateRestoredSnapshot(invalid))
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(HealthSnapshot())) as! [String: Any]
        object.removeValue(forKey: "closedNutritionDays"); object.removeValue(forKey: "pendingChatContexts")
        let legacy = try JSONDecoder().decode(HealthSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.closedNutritionDays); XCTAssertNil(legacy.pendingChatContexts)
        try model.validateRestoredSnapshot(legacy)
    }
    func testPendingConsentedContextIsScopedFrozenAndPreservedUntilDeliveryOrExplicitDeletion() async throws {
        let repository = ClosureHealthPersistence(); let client = ClosureHealthClient()
        let model = HealthSyncModel(client: client, persistence: repository)
        let request = UUID(); let owner = UUID().uuidString
        let original = try context()
        try model.savePendingChatContext(original, requestID: request, accountScope: owner)
        XCTAssertEqual(model.contextData(requestID: request, accountScope: owner.lowercased()), original)
        XCTAssertNil(model.contextData(requestID: request, accountScope: "local"))
        let reloaded = HealthSyncModel(client: client, persistence: repository)
        XCTAssertEqual(reloaded.contextData(requestID: request, accountScope: owner), original)
        await reloaded.prepareImport(configuration: HealthImportConfiguration(metrics: [.steps], startDate: nil, timeZoneIdentifier: "America/Montevideo"))
        reloaded.confirmImport()
        XCTAssertEqual(reloaded.contextData(requestID: request, accountScope: owner), original)
        reloaded.disconnect(removeLocalCopy: false)
        XCTAssertEqual(reloaded.contextData(requestID: request, accountScope: owner), original)
        try reloaded.savePendingChatContext(nil, requestID: request, accountScope: owner)
        XCTAssertNil(reloaded.contextData(requestID: request, accountScope: owner))
        try reloaded.savePendingChatContext(original, requestID: request, accountScope: owner)
        reloaded.disconnect(removeLocalCopy: true)
        XCTAssertNil(reloaded.snapshot.pendingChatContexts)
    }
    func testPendingContextRejectsUnconsentedOrUnlistedDataAndSaveFailurePreservesOldState() async throws {
        let repository = ClosureHealthPersistence(); let model = HealthSyncModel(client: ClosureHealthClient(), persistence: repository)
        let request = UUID()
        XCTAssertThrowsError(try model.savePendingChatContext(context(consent: false), requestID: request, accountScope: "local"))
        let raw = try JSONSerialization.data(withJSONObject: ["consent": true, "purpose": "chat", "day": "2026-10-08", "metrics": ["deviceName": "Personal watch"]])
        XCTAssertThrowsError(try model.savePendingChatContext(raw, requestID: request, accountScope: "local"))
        let numericConsent = try JSONSerialization.data(withJSONObject: ["consent": 1, "purpose": "chat", "day": "2026-10-08", "metrics": [:]])
        XCTAssertThrowsError(try model.savePendingChatContext(numericConsent, requestID: request, accountScope: "local"))
        repository.failSave = true
        XCTAssertThrowsError(try model.savePendingChatContext(context(), requestID: request, accountScope: "local"))
        XCTAssertNil(model.snapshot.pendingChatContexts); XCTAssertNil(repository.snapshot.pendingChatContexts)
    }
}

@MainActor private final class ClosureHealthPersistence: HealthPersistence {
    var snapshot = HealthSnapshot()
    var failSave = false
    func load() throws -> HealthSnapshot { snapshot }
    func save(_ value: HealthSnapshot) throws { if failSave { throw HealthOperationError.invalidData }; snapshot = value }
}
@MainActor private final class ClosureHealthClient: HealthDataClient {
    var isAvailable = true
    var statistics: [HealthDayValue] = []
    func requestReadAccess(to metrics: Set<HealthMetric>) async throws {}
    func changes(for metric: HealthMetric, start: Date?, anchor: Data?) async throws -> HealthDelta { HealthDelta(samples: [], deletedIDs: [], anchor: Data([1]), hasMore: false) }
    func dailyStatistics(for metric: HealthMetric, start: Date, end: Date, calendar: Calendar) async throws -> [HealthDayValue] { statistics.filter { $0.metric == metric } }
}
