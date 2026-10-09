import XCTest
@testable import nutrition_tracker

final class AssistantFoodReviewTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_791_475_200)
    private func proposal(quantity: Double = 200, unit: String = "gram", nutrients: NutrientValues = NutrientValues(energy: 240, protein: 20, carbohydrates: 30, fat: 4)) -> AssistantProposal {
        AssistantProposal(operation_id: UUID().uuidString, action: "add", name: "Confirmed food", quantity: quantity,
            unit: unit, state: "cooked", day: "2026-10-08", nutrients: nutrients,
            assumptions: ["Quantity estimated from the description", "Only consumed food"], requires_clarification: false)
    }
    func testGramTotalsRemainTotalsAndChangingConsumedAmountScalesEverything() throws {
        let input = proposal(); var draft = try AssistantFoodReview.draft(for: input, fallbackDate: date)
        XCTAssertEqual(try draft.values(), input.nutrients)
        XCTAssertEqual(draft.basis, .perServing); XCTAssertEqual(draft.conversion?.gramsPerServing, 200)
        XCTAssertNil(draft.conversion?.gramsPerMilliliter); XCTAssertEqual(draft.source, .estimate)
        draft.amount = 50
        XCTAssertEqual(try draft.values().energy, 60); XCTAssertEqual(try draft.values().protein, 5)
        XCTAssertEqual(try draft.values().carbohydrates, 7.5); XCTAssertEqual(try draft.values().fat, 1)
        XCTAssertNil(try draft.values().saturatedFat)
        XCTAssertEqual(draft.consumedAt, date); XCTAssertEqual(draft.preparation, .cooked)
        XCTAssertEqual(draft.notes, input.assumptions.joined(separator: "\n"))
    }
    func testMilliliterLabelUsesOfferedQuantityWithoutAssumingDensity() throws {
        var draft = try AssistantFoodReview.draft(for: proposal(quantity: 250, unit: "milliliter"), fallbackDate: date, intent: "label")
        XCTAssertEqual(try draft.values().energy, 240); XCTAssertEqual(draft.source, .label)
        XCTAssertEqual(draft.conversion?.millilitersPerServing, 250)
        XCTAssertNil(draft.conversion?.gramsPerServing); XCTAssertNil(draft.conversion?.gramsPerMilliliter)
        draft.amount = 125; XCTAssertEqual(try draft.values().energy, 120)
    }
    func testServingTotalsNormalizePerServingAndUnknownsStayUnknown() throws {
        let input = proposal(quantity: 2.5, unit: "serving", nutrients: NutrientValues(energy: 500, protein: 0))
        var draft = try AssistantFoodReview.draft(for: input, fallbackDate: date)
        XCTAssertEqual(draft.nutrition.energy, 200); XCTAssertEqual(try draft.values().energy, 500)
        XCTAssertEqual(try draft.values().protein, 0); XCTAssertNil(try draft.values().fat)
        XCTAssertNil(draft.conversion); draft.amount = 0.5
        XCTAssertEqual(try draft.values().energy, 100); XCTAssertNil(try draft.values().carbohydrates)
    }
    func testClarificationAndNonFoodActionsCannotBeConfirmedThroughReviewHelper() throws {
        for action in ["query", "delete", "close_day", "add_weight", "add_activity", "unknown"] {
            var input = proposal(); input.action = action
            XCTAssertThrowsError(try AssistantFoodReview.draft(for: input, fallbackDate: date))
        }
        var ambiguous = proposal(); ambiguous.requires_clarification = true
        XCTAssertThrowsError(try AssistantFoodReview.draft(for: ambiguous, fallbackDate: date)) { XCTAssertEqual($0 as? NutritionError, .invalidData) }
        var correction = proposal(); correction.action = "update"
        XCTAssertNoThrow(try AssistantFoodReview.draft(for: correction, fallbackDate: date))
    }
    func testInvalidQuantitiesUnitsNamesNutrientsAndPreparationReject() throws {
        for amount in [0, -1, .nan, .infinity, 1_000_001] {
            XCTAssertThrowsError(try AssistantFoodReview.draft(for: proposal(quantity: amount), fallbackDate: date))
        }
        for unit in ["cup", "grams", "", "g"] {
            XCTAssertThrowsError(try AssistantFoodReview.draft(for: proposal(unit: unit), fallbackDate: date))
        }
        for nutrients in [NutrientValues(energy: -1), NutrientValues(protein: .nan), NutrientValues(fat: .infinity)] {
            XCTAssertThrowsError(try AssistantFoodReview.draft(for: proposal(nutrients: nutrients), fallbackDate: date))
        }
        var input = proposal(); input.name = "  \n "
        XCTAssertThrowsError(try AssistantFoodReview.draft(for: input, fallbackDate: date))
        input = proposal(); input.state = "fried"
        XCTAssertThrowsError(try AssistantFoodReview.draft(for: input, fallbackDate: date))
        input = proposal(); input.nutrients = nil
        XCTAssertThrowsError(try AssistantFoodReview.draft(for: input, fallbackDate: date))
        XCTAssertThrowsError(try AssistantFoodReview.draft(for: proposal(), fallbackDate: Date(timeIntervalSince1970: .infinity)))
    }
    func testCatalogReferencesAreNotCarriedIntoConsumedFoodAndMissingStateIsExplicitUnknown() throws {
        var input = proposal(); input.state = nil
        input.product_id = UUID().uuidString; input.product_version = 7
        input.recipe_id = UUID().uuidString; input.recipe_version = 9
        let draft = try AssistantFoodReview.draft(for: input, fallbackDate: date, intent: "photo")
        XCTAssertNil(draft.productID); XCTAssertNil(draft.productVersion); XCTAssertNil(draft.recipeID); XCTAssertNil(draft.recipeVersion)
        XCTAssertEqual(draft.preparation, .unspecified); XCTAssertEqual(draft.source, .estimate)
        XCTAssertEqual(try draft.values(), input.nutrients)
    }
}
