import SwiftUI

extension FoodUnit {
    var titleKey: String { switch self { case .gram: "Grams"; case .milliliter: "Milliliters"; case .serving: "Servings" } }
}
extension NutritionBasis {
    var titleKey: String { switch self { case .per100Grams: "Per 100 g"; case .per100Milliliters: "Per 100 ml"; case .perServing: "Per serving" } }
}
extension FoodPreparation {
    var titleKey: String { switch self { case .unspecified: "Not specified"; case .raw: "Raw"; case .cooked: "Cooked" } }
}
extension FoodSource {
    var titleKey: String { switch self { case .manual: "Manual"; case .label: "Confirmed label"; case .catalog: "Catalog"; case .estimate: "Estimate"; case .recipe: "Recipe" } }
}
extension IntakeSelection {
    var titleKey: String { switch self { case .manual: "Recorded meals"; case .historical: "Daily summary"; case .health: "Apple Health" } }
}

struct NutrientValuesRows: View {
    let values: NutrientValues
    var body: some View {
        row("Energy", values.energy, "kcal")
        row("Protein", values.protein, "g")
        row("Carbs", values.carbohydrates, "g")
        row("Fat", values.fat, "g")
        row("Saturated fat", values.saturatedFat, "g")
        row("Fiber", values.fiber, "g")
    }
    private func row(_ title: LocalizedStringKey, _ value: Double?, _ unit: String) -> some View {
        LabeledContent(title) {
            if let value { Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)") }
            else { Text("Unknown").foregroundStyle(.secondary) }
        }
    }
}
