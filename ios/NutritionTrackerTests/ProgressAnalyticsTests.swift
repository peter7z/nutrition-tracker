import XCTest
@testable import nutrition_tracker

@MainActor final class ProgressAnalyticsTests: XCTestCase {
    private let timeZone = TimeZone(identifier: "America/Montevideo")!
    private var analytics: ProgressAnalytics { ProgressAnalytics(timeZone: timeZone) }

    private func date(_ day: Int, month: Int = 10, year: Int = 2026, hour: Int = 12, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testExplicitTimezoneDeterminesGregorianCalendarDay() {
        let beforeMontevideoMidnight = Date(timeIntervalSince1970: date(8, hour: 0).timeIntervalSince1970 - 90 * 60)
        let afterMontevideoMidnight = date(8, hour: 1)
        let result = analytics.resolveWeights([
            WeightObservation(id: "late-previous-day", date: beforeMontevideoMidnight, kg: 70, source: "Manual"),
            WeightObservation(id: "new-day", date: afterMontevideoMidnight, kg: 70.2, source: "Manual")
        ])

        XCTAssertEqual(result.coveredDayCount, 2)
        XCTAssertEqual(result.dailyWeights[0].date, analytics.calendar.startOfDay(for: beforeMontevideoMidnight))
        XCTAssertNotEqual(result.dailyWeights[0].date, result.dailyWeights[1].date)
        XCTAssertNil(ProgressAnalytics(timeZoneIdentifier: "not/a-time-zone"))
    }

    func testUnresolvedCrossSourceDuplicateIsExcludedAndVisible() {
        let result = analytics.resolveWeights([
            WeightObservation(id: "health", date: date(8), kg: 70.0, source: "Apple Health"),
            WeightObservation(id: "manual", date: date(8, minute: 10), kg: 70.1, source: "Manual")
        ])

        XCTAssertEqual(result.rawSampleCount, 2)
        XCTAssertEqual(result.conflictGroups.count, 1)
        XCTAssertEqual(result.unresolvedConflictCount, 1)
        XCTAssertEqual(result.excludedObservationCount, 2)
        XCTAssertTrue(result.dailyWeights.isEmpty)
    }

    func testExplicitChoiceKeepsOneHealthOrManualObservation() {
        let observations = [
            WeightObservation(id: "health", date: date(8), kg: 70.0, source: "Apple Health"),
            WeightObservation(id: "manual", date: date(8, minute: 10), kg: 70.1, source: "Manual")
        ]
        let unresolved = analytics.resolveWeights(observations)
        let groupID = unresolved.conflictGroups[0].id
        let resolved = analytics.resolveWeights(observations, choices: [groupID: .include(observationID: "manual")])

        XCTAssertEqual(resolved.unresolvedConflictCount, 0)
        XCTAssertEqual(resolved.excludedObservationCount, 1)
        XCTAssertEqual(resolved.coveredDayCount, 1)
        XCTAssertEqual(resolved.dailyWeights[0].observation.id, "manual")
        XCTAssertEqual(resolved.rawObservations.count, 2, "Reconciliation must preserve both source records")
    }

    func testSameSourceMeasurementsAreNotCollapsedAsCrossSourceConflict() {
        let result = analytics.resolveWeights([
            WeightObservation(id: "manual-early", date: date(8, hour: 8), kg: 70, source: "Manual"),
            WeightObservation(id: "manual-late", date: date(8, hour: 19), kg: 70.2, source: "Manual")
        ])

        XCTAssertTrue(result.conflictGroups.isEmpty)
        XCTAssertEqual(result.rawSampleCount, 2)
        XCTAssertEqual(result.coveredDayCount, 1)
        XCTAssertEqual(result.dailyWeights[0].observation.id, "manual-late")
    }

    func testMovingAverageUsesAvailableDaysAndDoesNotFillGaps() {
        let result = analytics.resolveWeights([
            WeightObservation(id: "d1", date: date(1), kg: 70, source: "Manual"),
            WeightObservation(id: "d3", date: date(3), kg: 72, source: "Manual"),
            WeightObservation(id: "d8", date: date(8), kg: 78, source: "Manual")
        ])
        let averages = analytics.movingAverages(for: result)

        XCTAssertEqual(averages.count, 3, "No synthetic points should be created for days 2, 4–7")
        XCTAssertEqual(averages[1].averageKg, 71, accuracy: 0.000_001)
        XCTAssertEqual(averages[1].contributingDayCount, 2)
        XCTAssertEqual(averages[1].rawSampleCount, 2)
        XCTAssertEqual(averages[2].averageKg, 75, accuracy: 0.000_001, "Day one is outside the window, while day three remains available")
        XCTAssertEqual(averages[2].contributingDayCount, 2)
    }

    func testWeeklyReviewRequiresTenCompleteDaysAndSixWeightsAcrossBothWeeks() {
        let intakes = (1...14).map { day in
            DailyIntakeObservation(
                date: date(day),
                caloriesKcal: day <= 10 ? 2_000 : nil,
                proteinGrams: day <= 10 ? 120 : nil,
                isComplete: day <= 10
            )
        }
        let weightObservations = [
            WeightObservation(id: "w1", date: date(1), kg: 70, source: "Manual"),
            WeightObservation(id: "w4", date: date(4), kg: 70.1, source: "Manual"),
            WeightObservation(id: "w7", date: date(7), kg: 70.2, source: "Manual"),
            WeightObservation(id: "w8", date: date(8), kg: 70.3, source: "Manual"),
            WeightObservation(id: "w11", date: date(11), kg: 70.4, source: "Manual"),
            WeightObservation(id: "w14", date: date(14), kg: 70.5, source: "Manual")
        ]
        let weights = analytics.resolveWeights(weightObservations)
        let summary = analytics.weeklyReview(endingAt: date(14), weights: weights, activities: [
            ActivityObservation(id: "walk", date: date(9), durationMinutes: 30, activeEnergyKcal: nil, source: "Apple Health")
        ], intakes: intakes)

        XCTAssertEqual(summary.completeNutritionDays, 10)
        XCTAssertEqual(summary.incompleteNutritionDays, 4)
        XCTAssertEqual(summary.caloriesKcal, 20_000)
        XCTAssertEqual(summary.caloriesCoverageDays, 10)
        XCTAssertEqual(summary.averageCaloriesKcalPerObservedDay, 2_000)
        XCTAssertEqual(summary.proteinCoverageDays, 10)
        XCTAssertEqual(summary.averageProteinGramsPerObservedDay, 120)
        XCTAssertEqual(summary.weightDayCount, 6)
        XCTAssertEqual(summary.firstWeekWeightDayCount, 3)
        XCTAssertEqual(summary.secondWeekWeightDayCount, 3)
        XCTAssertTrue(summary.isEligibleForGoalReview)
        XCTAssertEqual(summary.activity.activeEnergyKcal, nil, "Unknown active energy must remain unknown")

        let nineCompleteDays = intakes.map { intake in
            DailyIntakeObservation(date: intake.date, caloriesKcal: intake.caloriesKcal, proteinGrams: intake.proteinGrams, isComplete: intake.date != date(10) && intake.isComplete)
        }
        let insufficientNutrition = analytics.weeklyReview(endingAt: date(14), weights: weights, activities: [], intakes: nineCompleteDays)
        XCTAssertEqual(insufficientNutrition.completeNutritionDays, 9)
        XCTAssertFalse(insufficientNutrition.isEligibleForGoalReview)

        let insufficientWeights = analytics.resolveWeights(Array(weightObservations.dropLast()))
        let insufficientWeightCoverage = analytics.weeklyReview(endingAt: date(14), weights: insufficientWeights, activities: [], intakes: intakes)
        XCTAssertFalse(insufficientWeightCoverage.isEligibleForGoalReview)
    }

    func testEnergyOnlyActivityStillContributesActivityCoverageWithoutInventingMinutes() {
        let summary = analytics.weeklyReview(
            endingAt: date(14),
            weights: analytics.resolveWeights([]),
            activities: [ActivityObservation(id: "energy-only", date: date(9), activeEnergyKcal: 180, source: "Apple Health")],
            intakes: []
        )

        XCTAssertEqual(summary.activity.coveredDayCount, 1)
        XCTAssertEqual(summary.activity.activeEnergyKcal, 180)
        XCTAssertNil(summary.activity.durationMinutes, "Unknown exercise minutes must stay unknown")
        XCTAssertEqual(summary.activity.durationObservationCount, 0)
    }

    func testInvalidNutrientAmountsDoNotBecomeCoverageOrTotals() {
        let summary = analytics.weeklyReview(
            endingAt: date(14),
            weights: analytics.resolveWeights([]),
            activities: [],
            intakes: [
                DailyIntakeObservation(date: date(1), caloriesKcal: -1, proteinGrams: -10, isComplete: true),
                DailyIntakeObservation(date: date(2), caloriesKcal: 1_000_001, proteinGrams: .infinity, isComplete: true)
            ]
        )

        XCTAssertNil(summary.caloriesKcal)
        XCTAssertEqual(summary.caloriesCoverageDays, 0)
        XCTAssertNil(summary.proteinGrams)
        XCTAssertEqual(summary.proteinCoverageDays, 0)
        XCTAssertEqual(summary.completeNutritionDays, 2, "Explicit completeness remains separate from nutrient-field coverage")
    }
}
