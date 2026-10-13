import XCTest
@testable import nutrition_tracker

@MainActor final class ProgressChartWindowTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: "America/Montevideo")!
        return result
    }

    private func day(_ offset: Int, calendar: Calendar? = nil) -> Date {
        let calendar = calendar ?? self.calendar
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12))!
        return calendar.date(byAdding: .day, value: offset, to: today)!
    }

    func testLatestWeekIncludesTodayAndKeepsOlderHistoryScrollable() {
        let window = ProgressChartWindow(days: 7, position: nil, earliest: day(-400), today: day(0), calendar: calendar)
        XCTAssertEqual(window.start, day(-6))
        XCTAssertEqual(window.end, day(1))
        XCTAssertEqual(window.historyStart, day(-400))
        XCTAssertTrue(window.contains(day(0)))
        XCTAssertFalse(window.contains(day(1)))
        XCTAssertTrue(window.isLatest)
    }

    func testScrollingToAnOlderWindowClampsBothEndsOfHistory() {
        let old = ProgressChartWindow(days: 30, position: day(-100), earliest: day(-400), today: day(0), calendar: calendar)
        XCTAssertEqual(old.start, day(-100))
        XCTAssertEqual(old.lastDay, day(-71))
        XCTAssertFalse(old.isLatest)
        let beforeHistory = ProgressChartWindow(days: 30, position: day(-900), earliest: day(-400), today: day(0), calendar: calendar)
        XCTAssertEqual(beforeHistory.start, day(-400))
        let future = ProgressChartWindow(days: 30, position: day(20), earliest: day(-400), today: day(0), calendar: calendar)
        XCTAssertEqual(future.start, day(-29))
    }

    func testSparseAndEmptyHistoryStillHaveACompleteViewport() {
        for earliest in [nil, day(0)] {
            let window = ProgressChartWindow(days: 30, position: nil, earliest: earliest, today: day(0), calendar: calendar)
            XCTAssertEqual(window.historyStart, day(-29))
            XCTAssertEqual(window.duration, 30 * 86_400)
        }
    }

    func testScrollPrecisionAtMidnightDoesNotDropTheNewestDay() {
        let window = ProgressChartWindow(days: 7, position: day(-6).addingTimeInterval(-0.01),
                                         earliest: day(-400), today: day(0), calendar: calendar)
        XCTAssertTrue(window.isLatest)
        XCTAssertTrue(window.contains(day(0)))
        let earlier = ProgressChartWindow(days: 7, position: day(-6).addingTimeInterval(-60),
                                          earliest: day(-400), today: day(0), calendar: calendar)
        XCTAssertFalse(earlier.isLatest)
    }

    func testViewportUsesCalendarDaysAcrossDaylightSavingTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let window = ProgressChartWindow(days: 7, position: nil, earliest: nil, today: today, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: window.start, to: window.end).day, 7)
        XCTAssertEqual(window.duration, 7 * 86_400 - 3_600)
        XCTAssertTrue(window.contains(today))
    }

    func testHistoricalViewportDoesNotTruncateMeanOrRecentReview() {
        let observations = (0..<60).map {
            WeightObservation(id: "w\($0)", date: day(-$0), kg: 75 + Double($0) / 10, source: "manual")
        }
        let timeline = ProgressWeightTimeline(analytics: ProgressAnalytics(timeZone: calendar.timeZone), observations: observations, choices: [:])
        let window = ProgressChartWindow(days: 7, position: day(-40), earliest: observations.last?.date, today: day(0), calendar: calendar)
        let firstMean = timeline.averages.first { $0.date == window.start }!
        XCTAssertEqual(firstMean.contributingDayCount, 7)
        XCTAssertEqual(firstMean.averageKg, 79.3, accuracy: 0.000_001)
        let review = ProgressAnalytics(timeZone: calendar.timeZone).weeklyReview(endingAt: day(0), weights: timeline.resolution, activities: [], intakes: [])
        XCTAssertEqual(review.weightDayCount, 14)
    }
}
