import Foundation

struct ResolvedDailyNutrition {
    var values: NutrientValues
    var candidates: [IntakeSelection]
    var selection: IntakeSelection?
    var hasConflict: Bool
    var hasMissingNutrients: Bool
}

@MainActor final class PreparedNutritionPersistence: NutritionPersistence {
    var value: NutritionSnapshot
    init(_ value: NutritionSnapshot) { self.value = value }
    func load() throws -> NutritionSnapshot { value }
    func save(_ snapshot: NutritionSnapshot) throws { try NutritionBackup.validate(snapshot); value = snapshot }
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
                values = NutrientValues(energy: closed.totals.energy.value, protein: closed.totals.protein.value, carbohydrates: closed.totals.carbohydrates.value, fat: closed.totals.fat.value, saturatedFat: closed.totals.saturatedFat.value)
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
        case .manual: values = NutrientValues(energy: total.energy.value, protein: total.protein.value, carbohydrates: total.carbohydrates.value, fat: total.fat.value, saturatedFat: total.saturatedFat.value)
        case .historical: values = historical.count == 1 ? historical[0].nutrients : NutrientValues()
        case .health: values = healthValues
        case nil: values = NutrientValues()
        }
        return ResolvedDailyNutrition(values: values, candidates: candidates, selection: choice, hasConflict: candidates.count > 1 && choice == nil || choice == .historical && historical.count > 1,
            hasMissingNutrients: choice == .manual ? !total.isComplete : [values.energy, values.protein, values.carbohydrates, values.fat].contains(where: { $0 == nil }))
    }

    @MainActor static func preparedClosure(on date: Date, store: NutritionStore, health: HealthSnapshot, accountScope: String, completeness: DayCompleteness, operationID: UUID = UUID()) throws -> NutritionSnapshot {
        let staged = NutritionStore(persistence: PreparedNutritionPersistence(store.snapshot))
        guard staged.day(on: date)?.isClosed != true else { return store.snapshot }
        let resolved = nutrition(on: date, manual: store.snapshot, health: health, accountScope: accountScope)
        guard !resolved.hasConflict else { throw NutritionError.conflict }
        if let selection = resolved.selection { try staged.resolveIntake(on: date, selection: selection) }
        try staged.closeDay(date, completeness: completeness, operationID: operationID)
        return staged.snapshot
    }

    @MainActor static func closeDay(on date: Date, store: NutritionStore, health: HealthSyncModel, accountScope: String, completeness: DayCompleteness) throws {
        let before = store.snapshot
        let candidate = try preparedClosure(on: date, store: store, health: health.snapshot, accountScope: accountScope, completeness: completeness)
        guard candidate != before else { return }
        let summary = candidate.days.first { $0.id == store.dayID(for: date) }?.summaries.last
        var archiveID: UUID?
        if let summary, summary.intakeSource == .health {
            archiveID = try health.recordNutritionClosure(on: date, dayID: store.dayID(for: date), accountScope: accountScope, goals: store.goals(on: date), closureID: summary.id)
        }
        do { try store.publishPreparedSnapshot(candidate, expectedSnapshot: before) }
        catch { if let archiveID { try? health.removeClosure(id: archiveID) }; throw error }
    }
}
