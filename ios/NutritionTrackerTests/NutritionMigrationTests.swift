import XCTest
@testable import nutrition_tracker

@MainActor final class NutritionMigrationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_475_200)
    private func fixture() throws -> NutritionSnapshot {
        let memory = MigrationPersistence(); let store = NutritionStore(persistence: memory, now: { self.date })
        try store.addEntry(FoodEntryDraft(name: "Older label fixture", mealName: "Lunch", consumedAt: date, amount: 100,
            nutrition: NutrientValues(energy: 120, protein: 10), source: .label))
        try store.addWeight(kilograms: 75.5, recordedAt: date, notes: "Fixture")
        try store.setChatDraft("Unsent fixture")
        try store.enqueueChat(text: "Saved fixture question", date: date)
        return store.snapshot
    }
    func testActualRepositoryLoadsAdditiveLegacySchemaWithoutLosingEntriesChatOrWeights() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("Migration-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try fixture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["weightConflictSelections", "activitySourceSelections", "intakeResolutions", "historicalSummaries", "importBatches"] { object.removeValue(forKey: key) }
        let bytes = try JSONSerialization.data(withJSONObject: object); let file = directory.appendingPathComponent("tracking-v1.json")
        try bytes.write(to: file)
        let repository = NutritionFileRepository(fileURL: file); let loaded = try repository.load()
        XCTAssertEqual(loaded.entries, original.entries); XCTAssertEqual(loaded.messages, original.messages)
        XCTAssertEqual(loaded.weights, original.weights); XCTAssertEqual(loaded.outbox, original.outbox)
        XCTAssertEqual(loaded.profile, original.profile); XCTAssertEqual(loaded.chatDraft, original.chatDraft)
        XCTAssertTrue(loaded.weightConflictSelections.isEmpty); XCTAssertTrue(loaded.activitySourceSelections.isEmpty)
        let store = NutritionStore(persistence: repository)
        XCTAssertFalse(store.storageNeedsRecovery); XCTAssertEqual(store.snapshot, loaded)
        XCTAssertEqual(try Data(contentsOf: file), bytes, "Loading migration must preserve the source file until a successful mutation")
        try store.setChatDraft("After migration")
        let reopened = NutritionStore(persistence: repository)
        XCTAssertFalse(reopened.storageNeedsRecovery); XCTAssertEqual(reopened.snapshot.entries, original.entries)
        XCTAssertEqual(reopened.snapshot.weights, original.weights); XCTAssertEqual(reopened.snapshot.chatDraft, "After migration")
    }
    func testMalformedPresentFieldsAndFutureSchemaRemainUnreadableAndAreNeverReset() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("Migration-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("tracking-v1.json")
        let original = try fixture()
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for badValue in [NSNull(), "incorrect type", ["group": 9]] as [Any] {
            var object = base; object["weightConflictSelections"] = badValue
            let bytes = try JSONSerialization.data(withJSONObject: object); try bytes.write(to: file)
            XCTAssertThrowsError(try NutritionFileRepository(fileURL: file).load())
            let store = NutritionStore(persistence: NutritionFileRepository(fileURL: file))
            XCTAssertTrue(store.storageNeedsRecovery); XCTAssertEqual(try Data(contentsOf: file), bytes)
            XCTAssertThrowsError(try store.setChatDraft("Must not overwrite"))
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
        var future = base; future["schemaVersion"] = 2; future.removeValue(forKey: "activitySourceSelections")
        let futureBytes = try JSONSerialization.data(withJSONObject: future); try futureBytes.write(to: file)
        XCTAssertThrowsError(try NutritionFileRepository(fileURL: file).load()) { XCTAssertEqual($0 as? NutritionError, .unsupportedSchema) }
        XCTAssertTrue(NutritionStore(persistence: NutritionFileRepository(fileURL: file)).storageNeedsRecovery)
        XCTAssertEqual(try Data(contentsOf: file), futureBytes)
        var missingCore = base; missingCore.removeValue(forKey: "entries")
        XCTAssertThrowsError(try NutritionBackup.decode(JSONSerialization.data(withJSONObject: missingCore), datesISO8601: false))
    }
}

@MainActor private final class MigrationPersistence: NutritionPersistence {
    var snapshot = NutritionSnapshot()
    func load() throws -> NutritionSnapshot { snapshot }
    func save(_ value: NutritionSnapshot) throws { snapshot = value }
}
