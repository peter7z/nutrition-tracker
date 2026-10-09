import XCTest
@testable import nutrition_tracker

@MainActor final class WeeklyGoalReviewTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "America/Montevideo")!

    private func date(_ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
    }

    func testHealthContextContainsOnlyConsentedDailyAggregatesAndOmitsUnknowns() throws {
        let context = WeeklyHealthReviewContext(
            startDay: "2026-09-25",
            endDay: "2026-10-08",
            weights: [WeeklyHealthWeightDay(day: "2026-10-08", kilograms: 70)],
            dailyNutrition: [WeeklyHealthNutritionDay(day: "2026-10-08", energy: 1800, protein: 90, carbohydrates: nil, fat: nil)],
            dailyActivity: [WeeklyHealthActivityDay(day: "2026-10-08", exerciseMinutes: nil, activeKcal: 250)]
        )

        guard case let .object(object) = context.jsonValue else { return XCTFail("Expected JSON object") }
        XCTAssertEqual(object["consent"], .bool(true))
        XCTAssertEqual(object["purpose"], .string("weekly_review"))
        XCTAssertNil(object["complete_days"])
        XCTAssertNil(object["source"])
        XCTAssertNil(object["device"])
        XCTAssertNil(object["record_ids"])
        guard case let .array(nutritionRows)? = object["daily_nutrition"],
              case let .object(nutritionRow) = nutritionRows[0] else { return XCTFail("Expected daily nutrition row") }
        XCTAssertEqual(nutritionRow["energy"], .number(1800))
        XCTAssertNil(nutritionRow["carbohydrates"])
        XCTAssertNil(nutritionRow["fat"])
        guard case let .array(activityRows)? = object["daily_activity"],
              case let .object(activityRow) = activityRows[0] else { return XCTFail("Expected daily activity row") }
        XCTAssertEqual(activityRow["active_kcal"], .number(250))
        XCTAssertNil(activityRow["exercise_minutes"])
    }

    func testAcceptedProposalIsStagedAndPreservesPreviousGoalVersion() throws {
        let store = NutritionStore(persistence: PreparedNutritionPersistence(NutritionSnapshot()))
        let oldGoals = NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 60)
        try store.saveGoals(oldGoals, effectiveDate: date(1))
        let reviewedVersionID = store.goalVersion(on: date(8))?.id
        let before = store.snapshot
        let operationID = UUID()
        let candidate = try WeeklyGoalProposalStager.stage(
            WeeklyGoalProposalValues(
                energy: 2100,
                protein: 110,
                carbohydrates: nil,
                fat: nil,
                effectiveDay: "2026-10-09",
                rationale: "A test proposal",
                assumptions: [],
                requiresConfirmation: true
            ),
            in: store,
            reviewedAt: date(8),
            capturedGoalVersionID: reviewedVersionID,
            operationID: operationID
        )
        XCTAssertEqual(store.snapshot, before, "Staging must not publish to the live store")
        XCTAssertEqual(candidate.goals.count, 2)
        XCTAssertEqual(candidate.goals.first?.goals, oldGoals)
        XCTAssertEqual(candidate.goals.last?.effectiveDay, "2026-10-09")
        XCTAssertEqual(candidate.goals.last?.goals, NutritionGoals(energy: 2100, protein: 110, carbohydrates: 200, fat: 60))
        XCTAssertEqual(candidate.goals.last?.id, operationID)
    }

    func testStaleVersionAndMissingTargetsRejectProposal() throws {
        let store = NutritionStore(persistence: PreparedNutritionPersistence(NutritionSnapshot()))
        try store.saveGoals(NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 60), effectiveDate: date(1))
        let staleID = store.goalVersion(on: date(8))?.id
        try store.saveGoals(NutritionGoals(energy: 2200, protein: 120, carbohydrates: 210, fat: 70), effectiveDate: date(7))
        XCTAssertThrowsError(try WeeklyGoalProposalStager.stage(
            WeeklyGoalProposalValues(energy: 2100, protein: 110, carbohydrates: nil, fat: nil, effectiveDay: "2026-10-09", rationale: "", assumptions: [], requiresConfirmation: true),
            in: store,
            reviewedAt: date(8),
            capturedGoalVersionID: staleID,
            operationID: UUID()
        )) { XCTAssertEqual($0 as? WeeklyGoalReviewError, .staleGoalVersion) }

        let emptyStore = NutritionStore(persistence: PreparedNutritionPersistence(NutritionSnapshot()))
        XCTAssertThrowsError(try WeeklyGoalProposalStager.stage(
            WeeklyGoalProposalValues(energy: 2100, protein: 110, carbohydrates: nil, fat: nil, effectiveDay: "2026-10-09", rationale: "", assumptions: [], requiresConfirmation: true),
            in: emptyStore,
            reviewedAt: date(8),
            capturedGoalVersionID: nil,
            operationID: UUID()
        )) { XCTAssertEqual($0 as? WeeklyGoalReviewError, .invalidProposal) }
    }

    func testProposalWithoutConfirmationCannotBeStaged() throws {
        let store = NutritionStore(persistence: PreparedNutritionPersistence(NutritionSnapshot()))
        try store.saveGoals(NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 60), effectiveDate: date(1))
        XCTAssertThrowsError(try WeeklyGoalProposalStager.stage(
            WeeklyGoalProposalValues(energy: 2100, protein: nil, carbohydrates: nil, fat: nil, effectiveDay: "2026-10-09", rationale: "", assumptions: [], requiresConfirmation: false),
            in: store,
            reviewedAt: date(8),
            capturedGoalVersionID: store.goalVersion(on: date(8))?.id,
            operationID: UUID()
        )) { XCTAssertEqual($0 as? WeeklyGoalReviewError, .confirmationRequired) }
    }

    func testBackdatedProposalCannotRewriteEarlierGoalHistory() throws {
        let store = NutritionStore(persistence: PreparedNutritionPersistence(NutritionSnapshot()))
        try store.saveGoals(NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 60), effectiveDate: date(1))
        XCTAssertThrowsError(try WeeklyGoalProposalStager.stage(
            WeeklyGoalProposalValues(energy: 2100, protein: 110, carbohydrates: nil, fat: nil, effectiveDay: "2026-10-07", rationale: "", assumptions: [], requiresConfirmation: true),
            in: store,
            reviewedAt: date(8),
            capturedGoalVersionID: store.goalVersion(on: date(8))?.id,
            operationID: UUID()
        )) { XCTAssertEqual($0 as? WeeklyGoalReviewError, .invalidProposal) }
    }

    func testClosedDayFrozenGoalDoesNotHideAddedGoalVersionDuringReview() throws {
        let store = NutritionStore(persistence: PreparedNutritionPersistence(NutritionSnapshot()))
        try store.saveGoals(NutritionGoals(energy: 2000, protein: 100, carbohydrates: 200, fat: 60), effectiveDate: date(1))
        try store.closeDay(date(8), completeness: .complete)
        let capturedVersions = store.snapshot.goals
        let frozenClosedDayGoalID = store.goalVersion(on: date(8))?.id
        try store.saveGoals(NutritionGoals(energy: 2200, protein: 120, carbohydrates: 210, fat: 70), effectiveDate: date(12))

        XCTAssertEqual(store.goalVersion(on: date(8))?.id, frozenClosedDayGoalID, "Closed-day summaries remain frozen to their original goal version")
        XCTAssertThrowsError(try WeeklyGoalProposalStager.stage(
            WeeklyGoalProposalValues(energy: 2100, protein: 110, carbohydrates: nil, fat: nil, effectiveDay: "2026-10-09", rationale: "", assumptions: [], requiresConfirmation: true),
            in: store,
            reviewedAt: date(8),
            capturedGoalVersionID: frozenClosedDayGoalID,
            operationID: UUID(),
            capturedGoalVersions: capturedVersions
        )) { XCTAssertEqual($0 as? WeeklyGoalReviewError, .staleGoalVersion) }
    }
}
