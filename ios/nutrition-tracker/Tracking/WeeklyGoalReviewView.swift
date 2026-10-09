import SwiftUI

struct WeeklyGoalReviewView: View {
    @Environment(NutritionStore.self) private var nutrition
    @Environment(RemoteSession.self) private var remote
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var sync = TrackingSync()
    @State private var shareHealth = false
    @State private var isRequesting = false
    @State private var isApplying = false
    @State private var response: AssistantResponse?
    @State private var errorText: String?
    @State private var statusText: String?
    @State private var reviewSnapshot: ReviewSnapshot
    @State private var requestID = UUID()
    @State private var requestHealthContext: JSONValue?
    @State private var hasStartedRemoteRequest = false
    @State private var requestOwnerID: String?
    @State private var pendingCandidate: NutritionSnapshot?
    @State private var pendingOperationID: UUID?

    let summary: WeeklyReviewSummary

    private struct ReviewSnapshot {
        var reviewedAt: Date
        var goalVersionID: UUID?
        var goalVersions: [NutritionGoalVersion]?
        let healthContext: WeeklyHealthReviewContext
    }

    init(summary: WeeklyReviewSummary, reviewedAt: Date, capturedGoalVersionID: UUID?, healthReviewContext: WeeklyHealthReviewContext) {
        self.summary = summary
        _reviewSnapshot = State(initialValue: ReviewSnapshot(
            reviewedAt: reviewedAt,
            goalVersionID: capturedGoalVersionID,
            goalVersions: nil,
            healthContext: healthReviewContext
        ))
    }

    private var proposal: AssistantGoalProposal? { response?.goal_proposal }
    private var coverageAllowsProposal: Bool { response?.review_coverage?.goal_adjustment_allowed == true }

    var body: some View {
        NavigationStack {
            Form {
                Section("Recorded coverage") {
                    Text(summary.startDate, format: .dateTime.day().month())
                        + Text(" – ")
                        + Text(summary.endDate, format: .dateTime.day().month().year())
                    LabeledContent("Complete nutrition days", value: "\(summary.completeNutritionDays) / 14")
                    LabeledContent("Incomplete nutrition days", value: "\(summary.incompleteNutritionDays) / 14")
                    LabeledContent("Average calories") { observedValue(summary.averageCaloriesKcalPerObservedDay, unit: "kcal/day", days: summary.caloriesCoverageDays) }
                    LabeledContent("Average protein") { observedValue(summary.averageProteinGramsPerObservedDay, unit: "g/day", days: summary.proteinCoverageDays) }
                    LabeledContent("Weight days", value: "\(summary.weightDayCount) / 14")
                    LabeledContent("Weight days by week", value: "\(summary.firstWeekWeightDayCount) + \(summary.secondWeekWeightDayCount)")
                    LabeledContent("Mean observed weight") {
                        if let weight = summary.meanWeightKg { Text("\(weight.formatted(.number.precision(.fractionLength(1)).locale(locale))) kg") }
                        else { Text("Unknown").foregroundStyle(.secondary) }
                    }
                    LabeledContent("Activity days", value: "\(summary.activity.coveredDayCount) / 14")
                    LabeledContent("Unresolved weight matches", value: "\(summary.unresolvedWeightConflictCount)")
                    Text("Only recorded observations are summarized. Missing values stay unknown; activity is kept separate from food intake.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("A goal review requires at least 10 complete nutrition days and 6 weight days, including 3 weight days in each week.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Calories and protein averages use only days with those recorded values. No missing day is filled with zero. Activity does not count toward nutrition completeness.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Optional Apple Health sharing") {
                    Toggle("Share Apple Health daily summaries", isOn: $shareHealth)
                        .disabled(hasStartedRemoteRequest)
                    Text("When enabled, this review sends only selected daily totals for weight, nutrition, and activity from these 14 days. It does not send Health record IDs, source names, devices, or individual readings.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if reviewSnapshot.healthContext.weights.isEmpty && reviewSnapshot.healthContext.dailyNutrition.isEmpty && reviewSnapshot.healthContext.dailyActivity.isEmpty {
                        Text("No Apple Health daily summaries are selected in this period.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        Task { await requestReview() }
                    } label: {
                        if isRequesting { ProgressView() }
                        else { Label("Request weekly review", systemImage: "sparkles") }
                    }
                    .disabled(isRequesting || isApplying || pendingCandidate != nil || !summary.isEligibleForGoalReview || !remote.isAuthenticated || !remote.isOnline)
                    if !remote.isAuthenticated {
                        Text("Sign in to request a goal review.").font(.footnote).foregroundStyle(.secondary)
                    } else if !remote.isOnline {
                        Text("Connect to the internet to request a goal review.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("The assistant may explain the recorded pattern. It cannot change your goals automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
                if let statusText { Section { Text(statusText).foregroundStyle(.secondary) } }

                if let response {
                    Section("Assistant explanation") {
                        Text(response.message)
                            .textSelection(.enabled)
                    }

                    if let coverage = response.review_coverage {
                        Section("Server coverage check") {
                            LabeledContent("Complete nutrition days", value: "\(coverage.complete_days) / \(coverage.window_days)")
                            LabeledContent("Weight days", value: "\(coverage.weight_observed_days) / \(coverage.window_days)")
                            LabeledContent("Complete days by week", value: coverage.complete_days_by_week.map(String.init).joined(separator: " + "))
                            LabeledContent("Weight days by week", value: coverage.weight_days_by_week.map(String.init).joined(separator: " + "))
                            ForEach(Array(coverage.limitations.enumerated()), id: \.offset) { _, limitation in
                                Label(limitation, systemImage: "info.circle").font(.footnote)
                            }
                        }
                    }

                    if let proposal {
                        Section("Proposed goals") {
                            Text(proposal.rationale)
                            goalRow("Calories", value: proposal.energy, unit: "kcal/day")
                            goalRow("Protein", value: proposal.protein, unit: "g/day")
                            goalRow("Carbohydrates", value: proposal.carbohydrates, unit: "g/day")
                            goalRow("Fat", value: proposal.fat, unit: "g/day")
                            LabeledContent("Effective day", value: proposal.effective_day)
                            ForEach(Array(proposal.assumptions.enumerated()), id: \.offset) { _, assumption in
                                Label(assumption, systemImage: "text.quote").font(.footnote)
                            }
                            Text("These are proposals for you to review. Accepting saves a new version; previous goal versions are preserved.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text("A blank target keeps its current value. If no current value exists for a blank target, the proposal cannot be accepted.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button {
                                Task { await accept(proposal) }
                            } label: {
                                if isApplying { ProgressView() }
                                else if pendingCandidate != nil { Label("Retry saving proposed goals", systemImage: "arrow.clockwise") }
                                else { Label("Accept proposed goals", systemImage: "checkmark.circle") }
                            }
                            .disabled(isApplying || isRequesting || !coverageAllowsProposal || !proposal.requires_confirmation)
                            Button("Reject proposal", role: .destructive) {
                                self.response = nil
                                resetReviewRequest()
                                statusText = String(localized: "Proposal rejected. Your goals were not changed.")
                            }
                            .disabled(isApplying || pendingCandidate != nil)
                        }
                    } else {
                        Section("Goal review") {
                            Text("No goal change was proposed for this review. Your goals were not changed.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Weekly goal review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.disabled(isRequesting || isApplying) }
            }
            .onChange(of: remote.ownerID) { _, _ in
                response = nil
                shareHealth = false
                requestID = UUID()
                requestHealthContext = nil
                hasStartedRemoteRequest = false
                requestOwnerID = nil
                pendingCandidate = nil
                pendingOperationID = nil
                dismiss()
            }
        }
    }

    @ViewBuilder private func goalRow(_ title: LocalizedStringKey, value: Double?, unit: String) -> some View {
        LabeledContent(title) {
            if let value, value.isFinite, value > 0 {
                Text("\(value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) \(unit)")
            } else { Text("Not provided").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private func observedValue(_ value: Double?, unit: String, days: Int) -> some View {
        if let value {
            Text("\(value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))) \(unit) · \(days) days")
        } else { Text("Unknown · 0 days").foregroundStyle(.secondary) }
    }

    @MainActor private func requestReview() async {
        guard !isRequesting, summary.isEligibleForGoalReview else { return }
        if response != nil {
            requestID = UUID()
            requestHealthContext = nil
            hasStartedRemoteRequest = false
            requestOwnerID = nil
        }
        guard let ownerID = remote.ownerID else { return }
        isRequesting = true
        defer { isRequesting = false }
        errorText = nil
        statusText = nil
        response = nil
        do {
            if !hasStartedRemoteRequest {
                requestOwnerID = ownerID
                requestHealthContext = shareHealth ? reviewSnapshot.healthContext.jsonValue : nil
                hasStartedRemoteRequest = true
            }
            // Sync first so the server computes coverage from current closed days and observations.
            try await sync.sync(store: nutrition, remote: remote)
            guard remote.ownerID == ownerID else { throw RemoteError.authentication }
            reviewSnapshot.goalVersionID = nutrition.goalVersion(on: reviewSnapshot.reviewedAt)?.id
            reviewSnapshot.goalVersions = nutrition.snapshot.goals
            response = try await remote.weeklyReview(
                requestID: requestID,
                day: nutrition.dayID(for: reviewSnapshot.reviewedAt),
                text: String(localized: "Review my recorded progress for the last 14 days. Summarize the observations and explain the coverage before suggesting any goal changes."),
                healthReviewContext: requestHealthContext
            )
            guard remote.ownerID == ownerID else {
                response = nil
                throw RemoteError.authentication
            }
        } catch {
            errorText = String(localized: String.LocalizationValue(error.userFacingRemoteKey))
        }
    }

    @MainActor private func accept(_ proposal: AssistantGoalProposal) async {
        guard !isApplying, coverageAllowsProposal, proposal.requires_confirmation,
              let ownerID = requestOwnerID, remote.ownerID == ownerID else { return }
        isApplying = true
        defer { isApplying = false }
        errorText = nil
        do {
            let values = WeeklyGoalProposalValues(
                energy: proposal.energy,
                protein: proposal.protein,
                carbohydrates: proposal.carbohydrates,
                fat: proposal.fat,
                effectiveDay: proposal.effective_day,
                rationale: proposal.rationale,
                assumptions: proposal.assumptions,
                requiresConfirmation: proposal.requires_confirmation
            )
            if pendingCandidate == nil {
                pendingOperationID = requestID
                pendingCandidate = try WeeklyGoalProposalStager.stage(
                    values,
                    in: nutrition,
                    reviewedAt: reviewSnapshot.reviewedAt,
                    capturedGoalVersionID: reviewSnapshot.goalVersionID,
                    operationID: requestID,
                    capturedGoalVersions: reviewSnapshot.goalVersions
                )
            }
            guard let pendingCandidate, let pendingOperationID, remote.ownerID == ownerID else {
                throw RemoteError.authentication
            }
            try await sync.applyConfirmed(pendingCandidate, store: nutrition, remote: remote, operationID: pendingOperationID)
            guard remote.ownerID == ownerID else { throw RemoteError.authentication }
            self.pendingCandidate = nil
            self.pendingOperationID = nil
            statusText = String(localized: "Your new goal version was confirmed by the server.")
            response = nil
            resetReviewRequest()
        } catch WeeklyGoalReviewError.staleGoalVersion {
            errorText = String(localized: "Your active goals changed during this review. Request a new review before accepting.")
        } catch WeeklyGoalReviewError.invalidProposal {
            errorText = String(localized: "The proposed goals are incomplete or invalid. Your saved goals were not changed.")
        } catch {
            errorText = String(localized: String.LocalizationValue(error.userFacingRemoteKey))
        }
    }

    private func resetReviewRequest() {
        requestID = UUID()
        requestHealthContext = nil
        hasStartedRemoteRequest = false
        requestOwnerID = nil
    }
}
