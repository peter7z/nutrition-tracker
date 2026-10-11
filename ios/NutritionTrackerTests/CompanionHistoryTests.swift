import XCTest
@testable import nutrition_tracker

@MainActor final class CompanionHistoryTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_475_200)

    func testExistingHistoryRemainsReadableAndBytesUnchangedIncludingPendingChat() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tracking-v1.json")
        let original = CompanionTestFixture.history(on: date)
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: file)
        let store = NutritionStore(persistence: NutritionFileRepository(fileURL: file))
        XCTAssertFalse(store.storageNeedsRecovery)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(store.entries(on: date).count, 1)
        XCTAssertEqual(store.goals(on: date)?.energy, 2000)
        let display = TrackingBridge.nutrition(on: date, manual: store.snapshot, health: HealthSnapshot())
        XCTAssertEqual(display.values.energy, 133.5)
        store.reload()
        XCTAssertEqual(store.snapshot.messages, original.messages)
        XCTAssertEqual(store.snapshot.outbox, original.outbox)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testLegacyAdditiveSchemaLoadsWithoutRewritingOrDroppingHistory() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = CompanionTestFixture.history(on: date)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["weightConflictSelections", "activitySourceSelections", "intakeResolutions", "historicalSummaries", "importBatches"] { object.removeValue(forKey: key) }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let file = root.appendingPathComponent("tracking.json"); try bytes.write(to: file)
        let store = NutritionStore(persistence: NutritionFileRepository(fileURL: file))
        XCTAssertFalse(store.storageNeedsRecovery)
        XCTAssertEqual(store.snapshot.entries, original.entries)
        XCTAssertEqual(store.snapshot.weights, original.weights)
        XCTAssertEqual(store.snapshot.activities, original.activities)
        XCTAssertEqual(store.snapshot.messages, original.messages)
        XCTAssertEqual(store.snapshot.chatDraft, original.chatDraft)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testMalformedAndFutureHistoryArePreservedRatherThanReset() async throws {
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for bytes in [Data("invalid-json".utf8), Data("{\"schemaVersion\":2,\"profile\":{},\"entries\":[]}".utf8)] {
            try bytes.write(to: file)
            let store = NutritionStore(persistence: NutritionFileRepository(fileURL: file))
            XCTAssertTrue(store.storageNeedsRecovery)
            store.reload()
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testAccountFileAndClosureScopeStayIsolated() async throws {
        let owner = UUID(); let other = UUID()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = try JSONSerialization.data(withJSONObject: ["userID": owner.uuidString, "token": "disposable", "endpoint": "https://fixture.example"])
        let history = LegacyHistory.decodeOwner(from: data)
        XCTAssertEqual(history.ownerID, owner)
        XCTAssertEqual(history.accountScope, owner.uuidString.lowercased())
        XCTAssertNotEqual(LegacyHistory.fileURL(ownerID: owner, root: root), LegacyHistory.fileURL(ownerID: other, root: root))
        XCTAssertNotEqual(LegacyHistory.fileURL(ownerID: owner, root: root), LegacyHistory.fileURL(ownerID: nil, root: root))
        XCTAssertNil(LegacyHistory.decodeOwner(from: Data("{\"userID\":\"../invalid\"}".utf8)).ownerID)
        var manual = CompanionTestFixture.history(on: date)
        let summary = try XCTUnwrap(manual.days[0].summaries.last)
        manual.days[0].summaries[0].intakeSource = .health
        manual.days[0].summaries[0].totals = NutritionTotals()
        var health = HealthSnapshot()
        health.closedNutritionDays = [HealthNutritionClosure(id: summary.id, accountScope: history.accountScope,
            dayID: manual.days[0].id, closedAt: date, values: [HealthDayValue(metric: .dietaryEnergy, date: date, value: 800, sourceNames: ["Fixture"])], goals: nil)]
        XCTAssertEqual(TrackingBridge.nutrition(on: date, manual: manual, health: health, accountScope: history.accountScope).values.energy, 800)
        XCTAssertNil(TrackingBridge.nutrition(on: date, manual: manual, health: health, accountScope: other.uuidString).values.energy)
    }

    func testOverlappingSourcesStayUnresolvedWithoutAddingOrSavingAChoice() async {
        var manual = CompanionTestFixture.history(on: date); manual.days = []
        var health = HealthSnapshot()
        health.configuration = HealthImportConfiguration(metrics: [.dietaryEnergy], startDate: nil, timeZoneIdentifier: "America/Montevideo")
        health.dailyValues = [HealthDayValue(metric: .dietaryEnergy, date: date, value: 800, sourceNames: ["Fixture"])]
        let display = TrackingBridge.nutrition(on: date, manual: manual, health: health)
        XCTAssertTrue(display.hasConflict)
        XCTAssertNil(display.values.energy)
        XCTAssertTrue(manual.intakeResolutions.isEmpty)
    }

    func testPartialPortionPreservesLabelCaloriesAndUnknownNutrients() async throws {
        let draft = FoodEntryDraft(name: "Label fixture", mealName: "Lunch", consumedAt: date, amount: 50,
            nutrition: NutrientValues(energy: 123, protein: 10, carbohydrates: 15, fat: 3), source: .label)
        var totals = NutritionTotals(); totals.include(try draft.values())
        XCTAssertEqual(totals.energy.value, 61.5)
        XCTAssertEqual(totals.protein.value, 5)
        XCTAssertNil(totals.saturatedFat.value)
        XCTAssertEqual(totals.saturatedFat.missingCount, 1)
        let proteinEnergy = 5.0 * 4.0; let carbohydrateEnergy = 7.5 * 4.0; let fatEnergy = 1.5 * 9.0
        let fromMacros = proteinEnergy + carbohydrateEnergy + fatEnergy
        XCTAssertNotEqual(totals.energy.value, fromMacros)
        var zero = NutritionTotals(); zero.include(NutrientValues(energy: 0)); zero.include(NutrientValues())
        XCTAssertEqual(zero.energy.value, 0); XCTAssertFalse(zero.energy.isComplete)
    }
    func testUnitsRequireExplicitDensityAndServingConversion() async throws {
        var input = FoodEntryDraft(name: "Label fixture", mealName: "Lunch", consumedAt: date, amount: 50, nutrition: NutrientValues(energy: 123)); input.unit = .milliliter
        XCTAssertThrowsError(try input.values()) { XCTAssertEqual($0 as? NutritionError, .conversionRequired) }
        input.conversion = PortionConversion(gramsPerMilliliter: 0.8)
        XCTAssertEqual(try input.values().energy!, 49.2, accuracy: 0.001)
        input.unit = .serving; input.amount = 0.5; input.conversion = PortionConversion(gramsPerServing: 30)
        XCTAssertEqual(try input.values().energy!, 18.45, accuracy: 0.001)
        input.basis = .perServing; input.unit = .gram; input.amount = 15
        XCTAssertEqual(try input.values().energy, 61.5)
    }
}
