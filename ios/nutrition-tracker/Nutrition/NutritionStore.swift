import Foundation
import Observation

@MainActor @Observable final class NutritionStore {
    private(set) var snapshot = NutritionSnapshot()
    private(set) var errorKey: String?
    private(set) var storageNeedsRecovery = false
    @ObservationIgnored private let persistence: any NutritionPersistence

    init(persistence: (any NutritionPersistence)? = nil) {
        self.persistence = persistence ?? NutritionFileRepository()
        reload()
    }
    func reload() {
        do { snapshot = try persistence.load(); try NutritionBackup.validate(snapshot); storageNeedsRecovery = false; errorKey = nil }
        catch { storageNeedsRecovery = true; errorKey = "Could not read your nutrition history. The saved file was preserved." }
    }
    func dayID(for date: Date) -> String { snapshot.profile.dayID(for: date) }
    func entries(on date: Date) -> [FoodEntry] { entries(dayID: dayID(for: date)) }
    func entries(dayID: String) -> [FoodEntry] { snapshot.entries.filter { !$0.deleted && $0.dayID == dayID }.sorted { $0.draft.consumedAt < $1.draft.consumedAt } }
    func totals(on date: Date) -> NutritionTotals { totals(dayID: dayID(for: date)) }
    func totals(dayID: String) -> NutritionTotals { Self.totals(snapshot, dayID: dayID) }
    func day(on date: Date) -> NutritionDayLog? { snapshot.days.first { $0.id == dayID(for: date) } }
    func goals(on date: Date) -> NutritionGoals? { goalVersion(on: date)?.goals }
    func goalVersion(on date: Date) -> NutritionGoalVersion? {
        let day = dayID(for: date)
        if let closed = snapshot.days.first(where: { $0.id == day && $0.isClosed }) {
            guard let id = closed.summaries.last?.goalVersionID else { return nil }
            return snapshot.goals.first { $0.id == id }
        }
        return snapshot.goals.filter { $0.effectiveDay <= day }.sorted { $0.effectiveDay == $1.effectiveDay ? $0.createdAt < $1.createdAt : $0.effectiveDay < $1.effectiveDay }.last
    }
    private static func totals(_ snapshot: NutritionSnapshot, dayID: String) -> NutritionTotals {
        var result = NutritionTotals()
        for entry in snapshot.entries where !entry.deleted && entry.dayID == dayID { result.include(entry.values) }
        return result
    }
}
