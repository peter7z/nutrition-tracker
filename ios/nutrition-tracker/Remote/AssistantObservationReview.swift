import SwiftUI

struct ReviewedAssistantObservation {
    var recordedAt: Date
    var kilograms: Double?
    var activityKind: String
    var durationMinutes: Double?
    var activeEnergy: Double?
    var notes: String
    func validate(action: String) throws {
        guard recordedAt.timeIntervalSince1970.isFinite else { throw NutritionError.invalidData }
        if action == "add_weight" {
            guard let kilograms, kilograms.isFinite, kilograms > 0, kilograms < 1000 else { throw NutritionError.invalidData }
        } else if action == "add_activity" {
            guard !activityKind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  durationMinutes != nil || activeEnergy != nil,
                  durationMinutes.map({ $0.isFinite && $0 >= 0 }) != false,
                  activeEnergy.map({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) != false else { throw NutritionError.invalidData }
        } else { throw NutritionError.invalidData }
    }
    @MainActor func apply(action: String, to store: NutritionStore, operationID: UUID) throws {
        try validate(action: action)
        if action == "add_weight" { _ = try store.addWeight(kilograms: kilograms!, recordedAt: recordedAt, notes: notes, operationID: operationID) }
        else { _ = try store.addActivity(kind: activityKind, durationMinutes: durationMinutes, activeEnergy: activeEnergy, recordedAt: recordedAt, notes: notes, operationID: operationID) }
    }
}

struct AssistantObservationReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let action: String
    let onReview: (ReviewedAssistantObservation) -> Void
    @State private var value: ReviewedAssistantObservation
    init(proposal: AssistantProposal, fallbackDate: Date, reviewed: ReviewedAssistantObservation?, onReview: @escaping (ReviewedAssistantObservation) -> Void) {
        action = proposal.action; self.onReview = onReview
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = proposal.recorded_at.flatMap { formatter.date(from: $0) } ?? proposal.recorded_at.flatMap { ISO8601DateFormatter().date(from: $0) } ?? fallbackDate
        _value = State(initialValue: reviewed ?? ReviewedAssistantObservation(recordedAt: date, kilograms: proposal.weight_kg, activityKind: proposal.activity_kind ?? "", durationMinutes: proposal.duration_minutes, activeEnergy: proposal.active_kcal, notes: proposal.assumptions.joined(separator: "\n")))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Review the measurement and date before confirming. These values are not recorded yet.")
                    DatePicker("Recorded at", selection: $value.recordedAt)
                    if action == "add_weight" { OptionalNutrientField(title: "Weight (kg)", value: $value.kilograms) }
                    else {
                        TextField("Activity type", text: $value.activityKind)
                        OptionalNutrientField(title: "Duration (minutes)", value: $value.durationMinutes)
                        OptionalNutrientField(title: "Active energy (kcal)", value: $value.activeEnergy)
                        Text("Leave unknown values blank. Exercise stays separate from your food budget.").font(.footnote)
                    }
                    TextField("Notes and assumptions", text: $value.notes, axis: .vertical)
                }
            }
            .navigationTitle(action == "add_weight" ? "Review weight" : "Review activity").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Use reviewed values") { onReview(value); dismiss() }.disabled((try? value.validate(action: action)) == nil) }
            }
        }
    }
}
