import XCTest
@testable import nutrition_tracker

@MainActor final class TrackingBridgeTests: XCTestCase {
    func testOverlappingMealsAndHealthRequireChoiceInsteadOfAdding() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var manual = NutritionSnapshot()
        manual.entries = [FoodEntry(id: UUID(), version: 1, dayID: manual.profile.dayID(for: date), draft: FoodEntryDraft(name: "Food", consumedAt: date, amount: 100, nutrition: NutrientValues(energy: 100)), createdAt: date, updatedAt: date)]
        var health = HealthSnapshot()
        health.configuration = HealthImportConfiguration(metrics: [.dietaryEnergy], startDate: nil, timeZoneIdentifier: manual.profile.timeZoneIdentifier)
        health.dailyValues = [HealthDayValue(metric: .dietaryEnergy, date: date, value: 150, sourceNames: ["Health"])]
        let conflict = TrackingBridge.nutrition(on: date, manual: manual, health: health)
        XCTAssertTrue(conflict.hasConflict); XCTAssertNil(conflict.values.energy)
        manual.intakeResolutions = [IntakeResolution(dayID: manual.profile.dayID(for: date), selection: .manual)]
        XCTAssertEqual(TrackingBridge.nutrition(on: date, manual: manual, health: health).values.energy, 100)
        manual.intakeResolutions[0].selection = .health
        XCTAssertEqual(TrackingBridge.nutrition(on: date, manual: manual, health: health).values.energy, 150)
    }
    func testPartialManualNutritionKeepsUnknownAndMarksIncomplete() {
        let date = Date()
        var manual = NutritionSnapshot()
        manual.entries = [FoodEntry(id: UUID(), version: 1, dayID: manual.profile.dayID(for: date), draft: FoodEntryDraft(name: "Food", consumedAt: date, amount: 100, nutrition: NutrientValues(energy: 0, protein: nil)), createdAt: date, updatedAt: date)]
        let result = TrackingBridge.nutrition(on: date, manual: manual, health: HealthSnapshot())
        XCTAssertEqual(result.values.energy, 0); XCTAssertNil(result.values.protein); XCTAssertTrue(result.hasMissingNutrients)
    }
    func testClosedHealthUsesOnlyItsFrozenSummaryAndAccount() throws {
        let date = Date(timeIntervalSince1970: 1_791_475_200)
        let owner = UUID().uuidString
        let store = NutritionStore(persistence: PreparedNutritionPersistence(NutritionSnapshot()))
        try store.resolveIntake(on: date, selection: .health)
        try store.closeDay(date)
        let closedID = try XCTUnwrap(store.day(on: date)?.summaries.last?.id)
        var health = HealthSnapshot()
        health.configuration = HealthImportConfiguration(metrics: [.dietaryEnergy], startDate: nil, timeZoneIdentifier: store.snapshot.profile.timeZoneIdentifier)
        health.dailyValues = [HealthDayValue(metric: .dietaryEnergy, date: date, value: 1500, sourceNames: ["Updated"])]
        health.closedNutritionDays = [HealthNutritionClosure(id: closedID, accountScope: owner.lowercased(), dayID: store.dayID(for: date), closedAt: date, values: [HealthDayValue(metric: .dietaryEnergy, date: date, value: 1000, sourceNames: [])], goals: nil)]
        XCTAssertEqual(TrackingBridge.nutrition(on: date, manual: store.snapshot, health: health, accountScope: owner).values.energy, 1000)
        XCTAssertNil(TrackingBridge.nutrition(on: date, manual: store.snapshot, health: health, accountScope: "local").values.energy)
        XCTAssertNil(TrackingBridge.nutrition(on: date, manual: store.snapshot, health: health, accountScope: UUID().uuidString).values.energy)
        try store.reopenDay(date)
        XCTAssertEqual(TrackingBridge.nutrition(on: date, manual: store.snapshot, health: health, accountScope: owner).values.energy, 1500)
    }
    func testClosedHistoricalTotalsSurviveLaterSourceReplacement() throws {
        let date = Date(timeIntervalSince1970: 1_791_475_200)
        var original = NutritionSnapshot()
        let day = original.profile.dayID(for: date)
        var totals = NutritionTotals(); totals.include(NutrientValues(energy: 1200, protein: 60))
        let summary = ClosedDaySummary(id: UUID(), version: 1, closedAt: date, completeness: .incomplete, totals: totals, entryVersions: [:], goalVersionID: nil, intakeSource: .historical)
        original.days = [NutritionDayLog(id: day, version: 1, isClosed: true, summaries: [summary])]
        original.historicalSummaries = []
        let result = TrackingBridge.nutrition(on: date, manual: original, health: HealthSnapshot())
        XCTAssertEqual(result.values.energy, 1200); XCTAssertEqual(result.values.protein, 60)
        XCTAssertNil(result.values.carbohydrates); XCTAssertEqual(result.selection, .historical)
    }
    func testPreparedCloseDoesNotPublishSourceChoiceOrDayBeforeSave() throws {
        let date = Date(timeIntervalSince1970: 1_791_475_200)
        let original = NutritionSnapshot()
        let store = NutritionStore(persistence: PreparedNutritionPersistence(original))
        var health = HealthSnapshot()
        health.configuration = HealthImportConfiguration(metrics: [.dietaryEnergy], startDate: nil, timeZoneIdentifier: original.profile.timeZoneIdentifier)
        health.dailyValues = [HealthDayValue(metric: .dietaryEnergy, date: date, value: 1000, sourceNames: [])]
        let candidate = try TrackingBridge.preparedClosure(on: date, store: store, health: health, accountScope: "local", completeness: .incomplete)
        XCTAssertEqual(store.snapshot, original)
        XCTAssertEqual(candidate.intakeResolutions.first?.selection, .health)
        XCTAssertTrue(candidate.days.first?.isClosed == true)
        XCTAssertEqual(candidate.days.first?.summaries.first?.totals, NutritionTotals(), "Raw Health nutrients must not enter manual sync")
        try store.publishPreparedSnapshot(candidate, expectedSnapshot: original)
        XCTAssertEqual(store.snapshot, candidate)
        XCTAssertThrowsError(try store.publishPreparedSnapshot(original, expectedSnapshot: original))
    }
}
