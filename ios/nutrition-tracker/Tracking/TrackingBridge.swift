import Foundation

struct ResolvedDailyNutrition {
    var values: NutrientValues
    var candidates: [IntakeSelection]
    var selection: IntakeSelection?
    var hasConflict: Bool
    var hasMissingNutrients: Bool
}

enum TrackingBridge {
    static func nutrition(on date: Date, manual: NutritionSnapshot, health: HealthSnapshot, accountScope: String = "local") -> ResolvedDailyNutrition {
        let dayID = manual.profile.dayID(for: date)
        if let day = manual.days.first(where: { $0.id == dayID && $0.isClosed }), let closed = day.summaries.last {
            let source = closed.intakeSource ?? .manual
            let values: NutrientValues
            if source == .health {
                // Link by the ordinary day-summary ID; Health values never enter manual sync.
                let scope = accountScope.lowercased()
                let archive = health.closedNutritionDays?.first { $0.id == closed.id && $0.dayID == dayID && $0.accountScope.lowercased() == scope }
                func value(_ metric: HealthMetric) -> Double? { archive?.values.first { $0.metric == metric }?.value }
                values = NutrientValues(energy: value(.dietaryEnergy), protein: value(.protein), carbohydrates: value(.carbohydrates), fat: value(.fat), saturatedFat: value(.saturatedFat))
            } else {
                values = closed.totals.completeValues
            }
            return ResolvedDailyNutrition(values: values, candidates: [source], selection: source, hasConflict: false, hasMissingNutrients: [values.energy, values.protein, values.carbohydrates, values.fat].contains { $0 == nil })
        }
        let entries = manual.entries.filter { !$0.deleted && $0.dayID == dayID }
        var total = NutritionTotals()
        entries.forEach { total.include($0.values) }
        let historical = manual.historicalSummaries.filter { $0.dayID == dayID }
        let healthValues = NutrientValues(energy: health.value(for: .dietaryEnergy, on: date), protein: health.value(for: .protein, on: date), carbohydrates: health.value(for: .carbohydrates, on: date), fat: health.value(for: .fat, on: date), saturatedFat: health.value(for: .saturatedFat, on: date))
        var candidates: [IntakeSelection] = []
        if !entries.isEmpty { candidates.append(.manual) }
        if !historical.isEmpty { candidates.append(.historical) }
        if [healthValues.energy, healthValues.protein, healthValues.carbohydrates, healthValues.fat, healthValues.saturatedFat].contains(where: { $0 != nil }) { candidates.append(.health) }
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
