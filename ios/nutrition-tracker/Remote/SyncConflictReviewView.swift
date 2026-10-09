import SwiftUI

struct SyncConflictReviewView: View {
    @Environment(NutritionStore.self) private var store
    @Environment(RemoteSession.self) private var remote
    @Environment(\.dismiss) private var dismiss
    let sync: TrackingSync
    @State private var review: TrackingConflictReview?
    @State private var choices: [String: TrackingConflictChoice] = [:]
    @State private var working = false
    @State private var errorKey: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose which version to keep for each conflicting record. Other pending changes are preserved.")
                    if working { ProgressView("Loading records…") }
                    if let errorKey { OperationErrorView(key: errorKey) }
                    Button("Reload conflict review") { Task { await load() } }.disabled(working)
                }
                if let review {
                    if review.conflicts.isEmpty { Text("No conflicting records remain. Sync records again.") }
                    ForEach(review.conflicts, id: \.id) { conflict in
                        Section {
                            Text("This device").font(.headline)
                            SyncRecordPreview(record: conflict.local)
                            Divider()
                            Text("Private server").font(.headline)
                            SyncRecordPreview(record: conflict.server)
                            Picker("Keep this version", selection: Binding(get: { choices[conflict.id] }, set: { choices[conflict.id] = $0 })) {
                                Text("Choose a version").tag(Optional<TrackingConflictChoice>.none)
                                Text("This device").tag(Optional.some(TrackingConflictChoice.local))
                                Text("Private server").tag(Optional.some(TrackingConflictChoice.server))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Review sync conflicts").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) { Button("Confirm choices") { Task { await resolve() } }
                    .disabled(working || review == nil || review?.conflicts.isEmpty == true || choices.count != review?.conflicts.count) }
            }
            .task { await load() }
        }
    }
    private func load() async {
        guard !working else { return }; working = true; defer { working = false }
        do { review = try await sync.conflictReview(store: store, remote: remote); choices = [:]; errorKey = nil }
        catch { review = nil; errorKey = error.userFacingRemoteKey }
    }
    private func resolve() async {
        guard let review, !working else { return }; working = true; defer { working = false }
        do { try await sync.resolve(review, choices: choices, store: store, remote: remote); dismiss() }
        catch { self.review = nil; choices = [:]; errorKey = error.userFacingRemoteKey }
    }
}

private struct SyncRecordPreview: View {
    let record: RemoteRecord?
    var body: some View {
        if let record {
            switch record.kind {
            case "entry":
                if let entry = try? record.payload.decode(FoodEntry.self) {
                    Text(verbatim: entry.draft.name)
                    Text(entry.draft.consumedAt, format: .dateTime.day().month().year().hour().minute())
                    if entry.deleted { Text("Deleted") }
                    else { Text("\(entry.draft.amount.formatted()) \(String(localized: String.LocalizationValue(entry.draft.unit.titleKey)))"); NutrientValuesRows(values: entry.values) }
                }
            case "weight":
                if let value = try? record.payload.decode(ManualWeightEntry.self) { Text("\(value.kilograms.formatted()) kg"); Text(value.recordedAt, format: .dateTime.day().month().year().hour().minute()) }
            case "activity":
                if let value = try? record.payload.decode(ManualActivityEntry.self) { Text(verbatim: value.kind); Text(value.recordedAt, format: .dateTime.day().month().year().hour().minute()); if let duration = value.durationMinutes { Text("\(duration.formatted()) min") }; if let energy = value.activeEnergy { Text("\(energy.formatted()) kcal") } }
            case "goal":
                if let value = try? record.payload.decode(NutritionGoalVersion.self) { Text(value.effectiveDate, format: .dateTime.day().month().year()); if let goals = value.goals { NutrientValuesRows(values: NutrientValues(energy: goals.energy, protein: goals.protein, carbohydrates: goals.carbohydrates, fat: goals.fat)) } else { Text("No goals") } }
            case "product":
                if let value = try? record.payload.decode(FoodProduct.self) { Text(verbatim: value.name); Text(verbatim: value.brand); Text(LocalizedStringKey(value.basis.titleKey)); NutrientValuesRows(values: value.nutrition) }
            case "recipe":
                if let value = try? record.payload.decode(FoodRecipe.self) { Text(verbatim: value.name); Text("Ingredients: \(value.ingredients.count)") }
            case "day":
                if let value = try? record.payload.decode(NutritionDayLog.self) { Text(verbatim: value.id); Text(value.isClosed ? "Day closed" : "Day open · saved automatically"); if let summary = value.summaries.last { Text(summary.completeness == .complete ? "Complete" : "Incomplete") } }
            case "historical":
                if let value = try? record.payload.decode(HistoricalNutritionSummary.self) { Text(verbatim: value.dayID); NutrientValuesRows(values: value.nutrients); Text(verbatim: value.notes) }
            case "profile":
                if let value = try? record.payload.decode(NutritionProfile.self) { Text(verbatim: value.timeZoneIdentifier); Text(verbatim: value.preferences) }
            case "resolution":
                if let value = try? record.payload.decode(IntakeResolution.self) { Text(verbatim: value.dayID); Text(LocalizedStringKey(value.selection.titleKey)) }
            default: Text("Imported data changed. Export a backup before choosing a version.")
            }
        } else { Text("Deleted") }
    }
}
