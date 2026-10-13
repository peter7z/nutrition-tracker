import Foundation

struct ResolvedDailyNutrition {
    var values: NutrientValues
    var candidates: [IntakeSelection]
    var selection: IntakeSelection?
    var hasConflict: Bool
    var hasMissingNutrients: Bool
}

enum TrackingBridge {
    static func accountWeights(manual: NutritionSnapshot, health: HealthSnapshot) -> [ManualWeightEntry] {
        let localIDs = Set(health.samples.filter { $0.metric == .weight }.map(\.id))
        return manual.weights.filter { $0.source != .appleHealth || !localIDs.contains($0.sourceSampleID ?? $0.id) }
    }
    static func nutrition(on date: Date, manual: NutritionSnapshot, health: HealthSnapshot, accountScope: String = "local") -> ResolvedDailyNutrition {
        let dayID = manual.profile.dayID(for: date)
        if let day = manual.days.first(where: { $0.id == dayID }), let summary = day.summaries.last, summary.intakeSource == .health {
            let source = summary.intakeSource ?? .manual
            let values: NutrientValues
            if source == .health {
                // Link by the ordinary day-summary ID; Health values never enter manual sync.
                let scope = accountScope.lowercased()
                let archive = health.closedNutritionDays?.first { $0.id == summary.id && $0.dayID == dayID && $0.accountScope.lowercased() == scope }
                func value(_ metric: HealthMetric) -> Double? { archive?.values.first { $0.metric == metric }?.value }
                values = NutrientValues(energy: value(.dietaryEnergy), protein: value(.protein), carbohydrates: value(.carbohydrates), fat: value(.fat), saturatedFat: value(.saturatedFat), fiber: value(.fiber), vitaminA: value(.vitaminA), thiamin: value(.thiamin), riboflavin: value(.riboflavin), niacin: value(.niacin), pantothenicAcid: value(.pantothenicAcid), vitaminB6: value(.vitaminB6), biotin: value(.biotin), vitaminB12: value(.vitaminB12), vitaminC: value(.vitaminC), vitaminD: value(.vitaminD), vitaminE: value(.vitaminE), vitaminK: value(.vitaminK), folate: value(.folate), calcium: value(.calcium), chloride: value(.chloride), iron: value(.iron), magnesium: value(.magnesium), phosphorus: value(.phosphorus), potassium: value(.potassium), sodium: value(.sodium), zinc: value(.zinc), chromium: value(.chromium), copper: value(.copper), iodine: value(.iodine), manganese: value(.manganese), molybdenum: value(.molybdenum), selenium: value(.selenium))
            } else {
                values = summary.totals.completeValues
            }
            return ResolvedDailyNutrition(values: values, candidates: [source], selection: source, hasConflict: false, hasMissingNutrients: [values.energy, values.protein, values.carbohydrates, values.fat].contains { $0 == nil })
        }
        let entries = manual.entries.filter { !$0.deleted && $0.dayID == dayID }
        var total = NutritionTotals()
        entries.forEach { total.include($0.values) }
        let historical = manual.historicalSummaries.filter { $0.dayID == dayID }
        let healthValues = NutrientValues(energy: health.value(for: .dietaryEnergy, on: date), protein: health.value(for: .protein, on: date), carbohydrates: health.value(for: .carbohydrates, on: date), fat: health.value(for: .fat, on: date), saturatedFat: health.value(for: .saturatedFat, on: date), fiber: health.value(for: .fiber, on: date), vitaminA: health.value(for: .vitaminA, on: date), thiamin: health.value(for: .thiamin, on: date), riboflavin: health.value(for: .riboflavin, on: date), niacin: health.value(for: .niacin, on: date), pantothenicAcid: health.value(for: .pantothenicAcid, on: date), vitaminB6: health.value(for: .vitaminB6, on: date), biotin: health.value(for: .biotin, on: date), vitaminB12: health.value(for: .vitaminB12, on: date), vitaminC: health.value(for: .vitaminC, on: date), vitaminD: health.value(for: .vitaminD, on: date), vitaminE: health.value(for: .vitaminE, on: date), vitaminK: health.value(for: .vitaminK, on: date), folate: health.value(for: .folate, on: date), calcium: health.value(for: .calcium, on: date), chloride: health.value(for: .chloride, on: date), iron: health.value(for: .iron, on: date), magnesium: health.value(for: .magnesium, on: date), phosphorus: health.value(for: .phosphorus, on: date), potassium: health.value(for: .potassium, on: date), sodium: health.value(for: .sodium, on: date), zinc: health.value(for: .zinc, on: date), chromium: health.value(for: .chromium, on: date), copper: health.value(for: .copper, on: date), iodine: health.value(for: .iodine, on: date), manganese: health.value(for: .manganese, on: date), molybdenum: health.value(for: .molybdenum, on: date), selenium: health.value(for: .selenium, on: date))
        var candidates: [IntakeSelection] = []
        if !entries.isEmpty { candidates.append(.manual) }
        if !historical.isEmpty { candidates.append(.historical) }
        if healthValues.allValues.contains(where: { $0 != nil }) { candidates.append(.health) }
        let saved = manual.intakeResolutions.first { $0.dayID == dayID }?.selection
        let choice = saved.flatMap { candidates.contains($0) ? $0 : nil } ?? (candidates.count == 1 ? candidates[0] : nil)
        let values: NutrientValues
        switch choice {
        case .manual: values = NutrientValues(energy: total.energy.value, protein: total.protein.value, carbohydrates: total.carbohydrates.value, fat: total.fat.value, saturatedFat: total.saturatedFat.value, fiber: total.fiber.value)
        case .historical: values = historical.count == 1 ? historical[0].nutrients : NutrientValues()
        case .health: values = healthValues
        case nil: values = NutrientValues()
        }
        return ResolvedDailyNutrition(values: values, candidates: candidates, selection: choice, hasConflict: candidates.count > 1 && choice == nil || choice == .historical && historical.count > 1,
            hasMissingNutrients: choice == .manual ? !total.isComplete : [values.energy, values.protein, values.carbohydrates, values.fat].contains(where: { $0 == nil }))
    }

}
