import XCTest
@testable import nutrition_tracker

@MainActor final class ProgressChartScaleTests: XCTestCase {
    func testSmallWeightFluctuationsUseAReadableDomainAwayFromZero() {
        let domain = ProgressChartScale.weightDomain(values: [75.2, 75.5, 75.3, 75.4])
        XCTAssertGreaterThan(domain.lowerBound, 74)
        XCTAssertLessThan(domain.upperBound - domain.lowerBound, 2)
        XCTAssertLessThan(domain.lowerBound, 75.2)
        XCTAssertGreaterThan(domain.upperBound, 75.5)
    }

    func testOneReadingAndConstantWeightHaveANonzeroStableSpan() {
        let single = ProgressChartScale.weightDomain(values: [75.5])
        XCTAssertEqual(single, ProgressChartScale.weightDomain(values: [75.5, 75.5, 75.5]))
        XCTAssertGreaterThanOrEqual(single.upperBound - single.lowerBound, 1)
        XCTAssertTrue(single.contains(75.5))
    }

    func testEveryVisibleValueIncludingTheMovingMeanFitsWithPadding() {
        let values = [65.3, 75.5, 85.8, 69.2]
        let domain = ProgressChartScale.weightDomain(values: values)
        XCTAssertLessThan(domain.lowerBound, values.min()!)
        XCTAssertGreaterThan(domain.upperBound, values.max()!)
    }

    func testInvalidValuesDoNotDistortTheDomain() {
        XCTAssertEqual(ProgressChartScale.weightDomain(values: [.nan, .infinity, -2, 0, 75.5]),
                       ProgressChartScale.weightDomain(values: [75.5]))
        XCTAssertEqual(ProgressChartScale.weightDomain(values: []), 0...1)
        XCTAssertEqual(ProgressChartScale.weightDomain(values: [0.2]).lowerBound, 0)
    }
}
