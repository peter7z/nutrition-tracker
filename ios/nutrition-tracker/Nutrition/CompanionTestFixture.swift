#if DEBUG
import Foundation

enum CompanionTestFixture {
    static func progress(on date: Date) -> NutritionSnapshot {
        var snapshot = history(on: date)
        let calendar = snapshot.profile.calendar
        let today = calendar.startOfDay(for: date)
        snapshot.weights = (0..<45).compactMap { offset in
            // Include a gap to exercise segmented means without invented days.
            guard !(10...12).contains(offset),
                  let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let variation = sin(Double(offset) * 1.4) * 0.15
            return ManualWeightEntry(id: UUID(), recordedAt: day, kilograms: 75.5 + Double(offset) * 0.035 + variation)
        }
        return snapshot
    }

    static func history(on date: Date) -> NutritionSnapshot {
        var snapshot = NutritionSnapshot()
        let day = snapshot.profile.dayID(for: date)
        let draft = FoodEntryDraft(name: "Saved banana", mealName: "Breakfast", consumedAt: date, amount: 150,
            nutrition: NutrientValues(energy: 89, protein: 1.1, carbohydrates: 22.8, fat: 0.3), source: .estimate)
        snapshot.entries = [FoodEntry(id: UUID(), version: 2, dayID: day, draft: draft, createdAt: date, updatedAt: date)]
        snapshot.weights = [ManualWeightEntry(id: UUID(), recordedAt: date, kilograms: 75.5)]
        snapshot.activities = [ManualActivityEntry(id: UUID(), recordedAt: date, kind: "Saved walk", durationMinutes: 30, activeEnergy: 120)]
        let goalID = UUID()
        snapshot.goals = [NutritionGoalVersion(id: goalID, effectiveDay: day, effectiveDate: date,
            goals: NutritionGoals(energy: 2000, protein: 100, carbohydrates: 250, fat: 60), createdAt: date)]
        var totals = NutritionTotals(); totals.include(snapshot.entries[0].values)
        snapshot.days = [NutritionDayLog(id: day, isClosed: true, summaries: [ClosedDaySummary(
            id: UUID(), version: 1, closedAt: date, completeness: .incomplete, totals: totals,
            entryVersions: [snapshot.entries[0].id.uuidString: 2], goalVersionID: goalID, intakeSource: .manual)])]
        let messageID = UUID()
        snapshot.chatDraft = "Previously unsent draft"
        snapshot.messages = [PersistentChatMessage(id: messageID, role: .user, text: "Pending old message", createdAt: date, dayID: day, state: .queued)]
        snapshot.outbox = [ChatOutboxItem(id: UUID(), messageID: messageID)]
        return snapshot
    }
}
#endif
