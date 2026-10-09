import XCTest
@testable import nutrition_tracker

@MainActor final class AssistantObservationReviewTests: XCTestCase {
    func testReviewedActivityPreservesUnknownDurationAndDoesNotAffectFoodTotals() throws {
        let store = NutritionStore(persistence: PreparedNutritionPersistence(NutritionSnapshot()))
        let date = Date(timeIntervalSince1970: 1_791_475_200); let operation = UUID()
        let observation = ReviewedAssistantObservation(recordedAt: date, kilograms: nil, activityKind: "Cycling", durationMinutes: nil, activeEnergy: 200, notes: "Measured active energy; duration unknown")
        try observation.apply(action: "add_activity", to: store, operationID: operation)
        try observation.apply(action: "add_activity", to: store, operationID: operation)
        XCTAssertEqual(store.snapshot.activities.count, 1); XCTAssertNil(store.snapshot.activities.first?.durationMinutes)
        XCTAssertEqual(store.snapshot.activities.first?.activeEnergy, 200)
        XCTAssertNil(store.totals(on: date).energy.value)
    }
    func testInvalidMeasurementsAndAmbiguousEmptyActivityCannotBeConfirmed() {
        let date = Date()
        for value in [Double.nan, .infinity, -1, 0, 1000] {
            let observation = ReviewedAssistantObservation(recordedAt: date, kilograms: value, activityKind: "", durationMinutes: nil, activeEnergy: nil, notes: "")
            XCTAssertThrowsError(try observation.validate(action: "add_weight"))
        }
        var observation = ReviewedAssistantObservation(recordedAt: date, kilograms: nil, activityKind: "Running", durationMinutes: nil, activeEnergy: nil, notes: "")
        XCTAssertThrowsError(try observation.validate(action: "add_activity"))
        observation.durationMinutes = 30
        XCTAssertNoThrow(try observation.validate(action: "add_activity"))
        observation.activeEnergy = -.infinity
        XCTAssertThrowsError(try observation.validate(action: "add_activity"))
    }
}
