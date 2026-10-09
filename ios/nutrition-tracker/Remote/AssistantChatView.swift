import SwiftUI
import PhotosUI

private final class ProposalPersistence: NutritionPersistence {
    var value: NutritionSnapshot
    init(_ value: NutritionSnapshot) { self.value = value }
    func load() throws -> NutritionSnapshot { value }
    func save(_ snapshot: NutritionSnapshot) throws { try NutritionBackup.validate(snapshot); value = snapshot }
}

struct AssistantChatView: View {
    @Environment(NutritionStore.self) private var store
    @Environment(HealthSyncModel.self) private var health
    @Environment(RemoteSession.self) private var remote
    @State private var sync = TrackingSync()
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @Binding var selectedDate: Date
    @State private var response: AssistantResponse?
    @State private var editingProposal: AssistantProposal?
    @State private var reviewedDrafts: [String: FoodEntryDraft] = [:]
    @State private var confirmedIDs = Set<String>()
    @State private var errorKey: String?
    @State private var showAccount = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachment: NutritionAttachment?
    @State private var previewImage: UIImage?
    @State private var photoIsLabel = false
    @State private var shareHealthForRequest = false
    @State private var runningTask: Task<Void, Never>?
    @State private var isSending = false
    @State private var closeProposal: AssistantProposal?
    @State private var deletingPhoto: NutritionAttachment?
    @State private var showConflicts = false
    @State private var editingObservation: AssistantProposal?
    @State private var reviewedObservations: [String: ReviewedAssistantObservation] = [:]
    @State private var responseDay: String?
    @State private var pendingConfirmation: PendingAssistantConfirmation?
    private struct PendingAssistantConfirmation {
        var proposalID: String
        var operationID: UUID
        var snapshot: NutritionSnapshot
    }
    private var dayID: String { store.dayID(for: selectedDate) }
    var body: some View {
        NavigationStack { photoDeletionScreen }
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            offlineIndicator
            chatHistory
            composer
        }
    }

    @ViewBuilder private var offlineIndicator: some View {
        if !remote.isOnline {
            Label("Offline · draft saved locally", systemImage: "wifi.slash")
                .font(.caption).padding(8).accessibilityIdentifier("chat.offlineIndicator")
        }
    }

    private var chatHistory: some View {
        ScrollViewReader { proxy in
            ScrollView { historyRows }
                .background(Color(uiColor: .systemGroupedBackground))
                .onChange(of: response?.request_id) { _, requestID in
                    if requestID != nil { withAnimation { proxy.scrollTo("chat.bottom", anchor: .bottom) } }
                }
        }
    }

    private var visibleMessages: [PersistentChatMessage] {
        store.snapshot.messages.filter { $0.remoteOwnerID == remote.ownerID }
    }

    private var historyRows: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            signInPrompt
            SelectedDayPicker(selection: $selectedDate)
            ForEach(visibleMessages) { message in messageRow(message) }
            if let response { responseSection(response) }
            historyStatus
            Color.clear.frame(height: 1).id("chat.bottom")
        }.padding(20)
    }

    @ViewBuilder private var signInPrompt: some View {
        if !remote.isAuthenticated {
            Button { showAccount = true } label: {
                Text("Sign in to use the assistant")
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func messageRow(_ message: PersistentChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.role == .user ? "You" : "Assistant")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(verbatim: message.text).textSelection(.enabled)
            if message.role == .user { userMessageControls(message) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(message.role == .user ? Color("NutritionGreen").opacity(0.10) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private func userMessageControls(_ message: PersistentChatMessage) -> some View {
        ForEach(store.snapshot.attachments.filter { message.attachmentIDs.contains($0.id) }) { item in
            Button("Delete attached photo", role: .destructive) { deletingPhoto = item }
                .font(.caption).disabled(isSending)
        }
        Text(LocalizedStringKey(message.state.titleKey)).font(.caption).foregroundStyle(.secondary)
        if message.attachmentRemoved == true && message.state != .delivered {
            Text("Photo deleted. Send a new message to request another analysis.").font(.caption).foregroundStyle(.secondary)
        }
        if message.canRetrieveOrRetry {
            Button(message.state == .delivered || message.requiresSavedResponse == true ? "Review response" : "Retry explicitly") {
                start(messageID: message.id)
            }.font(.caption).disabled(isSending || !remote.isAuthenticated)
        }
    }

    @ViewBuilder private func responseSection(_ response: AssistantResponse) -> some View {
        dailyTotals
        ForEach(response.proposals.filter { $0.action != "query" }) { proposal in proposalCard(proposal) }
    }

    private var dailyTotals: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actual daily totals").font(.headline)
            if let date = dateForDay(responseDay ?? dayID) {
                Text(date, format: .dateTime.day().month().year()).font(.caption)
                NutrientValuesRows(values: TrackingBridge.nutrition(on: date, manual: store.snapshot, health: health.snapshot, accountScope: remote.ownerID ?? "local").values)
            }
            Text("Projections and estimates are separate from these recorded totals.").font(.caption).foregroundStyle(.secondary)
        }.padding(16)
    }

    @ViewBuilder private var historyStatus: some View {
        if let errorKey { OperationErrorView(key: errorKey) }
        if pendingConfirmation != nil {
            Text("Confirmation pending. Sync records to verify the original change before editing another proposal.")
                .font(.footnote).foregroundStyle(.orange)
        }
        if let error = sync.errorKey {
            OperationErrorView(key: error)
            if error == RemoteError.conflict.userFacingRemoteKey {
                Button("Review sync conflicts") { showConflicts = true }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let previewImage { photoPreview(previewImage) }
            healthSharingControls
            draftField
            composerActions
        }.padding(16).background(.bar)
    }

    private func photoPreview(_ image: UIImage) -> some View {
        HStack(alignment: .top) {
            Image(uiImage: image).resizable().scaledToFit().frame(width: 90, height: 90).accessibilityLabel("Selected photo")
            VStack(alignment: .leading) {
                Toggle("Nutrition label", isOn: $photoIsLabel)
                Text("Analysis sends this photo to the private server and AI. Review estimates before recording anything.").font(.caption)
                Button("Remove photo", role: .destructive) { removePhoto() }
            }
        }
    }

    @ViewBuilder private var healthSharingControls: some View {
        if health.snapshot.configuration != nil {
            Toggle("Share Health totals for this request", isOn: $shareHealthForRequest).font(.caption)
            if shareHealthForRequest {
                Text("Only weight, activity and nutrition totals for the selected day are shared. No raw observations or device details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var draftField: some View {
        TextField("Ask or describe what you ate", text: $draft, axis: .vertical)
            .lineLimit(1...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("chat.draft")
            .focused($draftFocused)
            .onChange(of: draft) { _, text in
                do { try store.setChatDraft(text) }
                catch { errorKey = "Could not save your draft. Please try again." }
            }
    }

    private var composerActions: some View {
        HStack {
            PhotosPicker(selection: $selectedPhoto, matching: .images) { Image(systemName: "photo") }.accessibilityLabel("Choose photo")
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Image(systemName: "camera") }.accessibilityLabel("Take photo")
            }
            Spacer()
            requestControls
        }
    }

    private var sendDisabled: Bool {
        pendingConfirmation != nil || !remote.isAuthenticated || !remote.isOnline || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil
    }

    @ViewBuilder private var requestControls: some View {
        if isSending {
            ProgressView()
            Button("Cancel request") { runningTask?.cancel() }
        } else {
            Button(previewImage == nil ? "Send" : "Analyze photo") { enqueueAndStart() }
                .buttonStyle(.borderedProminent).accessibilityIdentifier("chat.send").disabled(sendDisabled)
        }
    }

    @ToolbarContentBuilder private var chatToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Sync records", action: syncRecords).disabled(isSending || !remote.isAuthenticated)
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { draftFocused = false }.accessibilityIdentifier("chat.dismissKeyboard")
        }
    }

    private var chatScreen: some View {
        chatContent
            .navigationTitle("Chat")
            .toolbar { chatToolbar }
            .onAppear(perform: restoreChatDraft)
            .onDisappear { runningTask?.cancel() }
            .onChange(of: remote.ownerID) { _, _ in resetAccountUI() }
            .onChange(of: selectedPhoto) { _, item in loadSelectedPhoto(item) }
    }

    private var accountAndPhotoSheets: some View {
        chatScreen
            .sheet(isPresented: $showAccount) { AccountAccessView() }
            .sheet(isPresented: $showCamera) { CameraCapture(onImage: selectPhoto).ignoresSafeArea() }
            .sheet(isPresented: $showConflicts, onDismiss: { if sync.errorKey == nil { pendingConfirmation = nil } }) {
                SyncConflictReviewView(sync: sync)
            }
    }

    private var proposalSheets: some View {
        accountAndPhotoSheets
            .sheet(item: $editingProposal) { proposal in foodReview(proposal) }
            .sheet(item: $editingObservation) { proposal in observationReview(proposal) }
    }

    @ViewBuilder private func foodReview(_ proposal: AssistantProposal) -> some View {
        if let draft = reviewDraft(for: proposal) {
            AssistantFoodAmountReviewView(draft: draft) { reviewedDrafts[proposal.id] = $0 }
        }
    }

    private func reviewDraft(for proposal: AssistantProposal) -> FoodEntryDraft? {
        reviewedDrafts[proposal.id] ?? (try? AssistantFoodReview.draft(for: proposal, fallbackDate: dateForDay(proposal.day) ?? selectedDate, intent: response?.intent))
    }

    private func observationReview(_ proposal: AssistantProposal) -> some View {
        AssistantObservationReviewView(proposal: proposal, fallbackDate: dateForDay(proposal.day) ?? selectedDate, reviewed: reviewedObservations[proposal.id]) {
            reviewedObservations[proposal.id] = $0
        }
    }

    private var dayClosureScreen: some View {
        proposalSheets
            .confirmationDialog("Close this day?", isPresented: Binding(get: { closeProposal != nil }, set: { if !$0 { closeProposal = nil } }), titleVisibility: .visible) {
                Button("Close as complete") { confirmClosure(as: .complete) }
                Button("Close as incomplete") { confirmClosure(as: .incomplete) }
            }
    }

    private var photoDeletionScreen: some View {
        dayClosureScreen
            .confirmationDialog("Delete this photo from this device and the private server?", isPresented: Binding(get: { deletingPhoto != nil }, set: { if !$0 { deletingPhoto = nil } }), titleVisibility: .visible) {
                Button("Delete photo", role: .destructive) {
                    if let item = deletingPhoto { deletePhoto(item) }
                    deletingPhoto = nil
                }
            } message: { Text("Recorded foods and the analysis text are kept. The image is deleted.") }
    }

    private func syncRecords() {
        runningTask = Task {
            isSending = true; defer { isSending = false }
            do { try await sync.sync(store: store, remote: remote); pendingConfirmation = nil; errorKey = nil }
            catch { errorKey = error.userFacingRemoteKey }
        }
    }

    private func restoreChatDraft() {
        draft = store.snapshot.chatDraft
        attachment = store.snapshot.attachments.last { item in !store.snapshot.messages.contains { $0.attachmentIDs.contains(item.id) } }
        if let attachment, let data = try? AttachmentFiles(ownerID: remote.ownerID).read(attachment) { previewImage = UIImage(data: data) }
    }

    private func resetAccountUI() {
        runningTask?.cancel(); response = nil; reviewedDrafts = [:]; reviewedObservations = [:]; editingObservation = nil
        confirmedIDs = []; previewImage = nil; attachment = nil; draft = store.snapshot.chatDraft
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem?) {
        Task { if let data = try? await item?.loadTransferable(type: Data.self) { selectPhoto(data) } }
    }

    private func confirmClosure(as completeness: DayCompleteness) {
        if let proposal = closeProposal { confirm(proposal, completeness: completeness); closeProposal = nil }
    }

    private func proposalCard(_ proposal: AssistantProposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            proposalHeader(proposal)
            proposalStatus(proposal)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder private func proposalHeader(_ proposal: AssistantProposal) -> some View {
        Text("Proposed change · not recorded yet").font(.headline)
        if let name = proposal.name { Text(verbatim: name) }
        Text(verbatim: proposal.day).font(.caption)
        ForEach(proposal.assumptions, id: \.self) { Text(verbatim: $0).font(.caption).foregroundStyle(.secondary) }
        if proposal.requires_clarification {
            Text("Review the quantity, units and assumptions before confirming.").foregroundStyle(.orange).font(.caption)
        }
    }

    @ViewBuilder private func proposalStatus(_ proposal: AssistantProposal) -> some View {
        if store.snapshot.operations.contains(where: { $0.id.uuidString.lowercased() == proposal.id.lowercased() }) {
            if let event = store.snapshot.changes.first(where: { $0.operationID.uuidString.lowercased() == proposal.id.lowercased() }) {
                if event.undoneBy != nil { Label("Change undone", systemImage: "arrow.uturn.backward") }
                else {
                    Label("Previously confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Undo this change") { undo(event) }.disabled(isSending)
                }
            } else { Label("Previously confirmed", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        } else if confirmedIDs.contains(proposal.id) {
            Label("Confirmed and saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else { proposalControls(proposal) }
    }

    @ViewBuilder private func proposalControls(_ proposal: AssistantProposal) -> some View {
        if ["add", "update"].contains(proposal.action) { foodProposalControls(proposal) }
        else if ["add_weight", "add_activity"].contains(proposal.action) {
            Button("Review and edit") { editingObservation = proposal }.disabled(pendingConfirmation != nil)
            if reviewedObservations[proposal.id] != nil { Button("Confirm measurement") { confirm(proposal) }.disabled(isSending) }
        } else if proposal.action == "delete" { deletionProposalControls(proposal) }
        else if proposal.action == "close_day" { Button("Review day closure") { closeProposal = proposal }.disabled(isSending) }
        if pendingConfirmation?.proposalID == proposal.id {
            Button("Retry original confirmation") { confirm(proposal) }.disabled(isSending)
        }
    }

    @ViewBuilder private func foodProposalControls(_ proposal: AssistantProposal) -> some View {
        if let draft = reviewDraft(for: proposal), let values = try? draft.values() {
            Text("\(draft.amount.formatted()) \(String(localized: String.LocalizationValue(draft.unit.titleKey)))")
            NutrientValuesRows(values: values)
            Text("Nutrition is calculated by the assistant. Estimates are shown for review.").font(.caption).foregroundStyle(.secondary)
            if response?.intent != "label" {
                Button("Adjust quantity") { editingProposal = proposal }.disabled(pendingConfirmation != nil)
                Button("Confirm consumed food") { confirm(proposal) }.disabled(isSending || pendingConfirmation != nil)
            } else { Text("Tell the assistant how much you ate to record consumption.").font(.footnote) }
        } else { Text("Clarify the food and amount in chat before recording it.").font(.footnote).foregroundStyle(.orange) }
    }

    @ViewBuilder private func deletionProposalControls(_ proposal: AssistantProposal) -> some View {
        if let id = proposal.entry_id.flatMap(UUID.init(uuidString:)), let entry = store.snapshot.entries.first(where: { $0.id == id }) {
            Text(verbatim: entry.draft.name)
            Text(entry.draft.consumedAt, format: .dateTime.day().month().year().hour().minute())
            Text("\(entry.draft.amount.formatted()) \(String(localized: String.LocalizationValue(entry.draft.unit.titleKey)))")
        }
        if proposal.requires_clarification { Text("Clarify which record to delete before requesting deletion again.").font(.footnote) }
        Button("Confirm deletion", role: .destructive) { confirm(proposal) }.disabled(isSending || proposal.requires_clarification)
    }
    private func dateForDay(_ day: String) -> Date? { let formatter = DateFormatter(); formatter.calendar = store.snapshot.profile.calendar; formatter.timeZone = formatter.calendar.timeZone; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; return formatter.date(from: day) }
    private func enqueueAndStart() {
        guard pendingConfirmation == nil else { return }
        guard remote.isAuthenticated else { showAccount = true; return }
        let requestID = UUID()
        let scope = remote.ownerID ?? "local"
        do {
            let text = draft.isEmpty ? (photoIsLabel ? String(localized: "Read this nutrition label and estimate its nutrients. Do not record consumption.") : String(localized: "Estimate the components of this meal photo for review. Do not record consumption.")) : draft
            if shareHealthForRequest, let context = healthContext(day: dayID) {
                try health.savePendingChatContext(JSONEncoder().encode(context), requestID: requestID, accountScope: scope)
            }
            let messageID = try store.enqueueChat(text: text, date: selectedDate, attachmentIDs: attachment.map { [$0.id] } ?? [], ownerID: remote.ownerID, operationID: requestID)
            shareHealthForRequest = false
            draftFocused = false
            draft = ""; attachment = nil; previewImage = nil; start(messageID: messageID)
        } catch {
            try? health.savePendingChatContext(nil, requestID: requestID, accountScope: scope)
            errorKey = "Could not save your message. Please try again."
        }
    }
    private func start(messageID: UUID) {
        guard !isSending, remote.isAuthenticated, let message = store.snapshot.messages.first(where: { $0.id == messageID }), message.remoteOwnerID == remote.ownerID, message.canRetrieveOrRetry else { return }
        let requestID = message.operationID ?? message.id
        let scope = remote.ownerID ?? "local"
        let context = health.contextData(requestID: requestID, accountScope: scope).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        runningTask = Task {
            isSending = true; defer { isSending = false }
            do {
                var created = false
                let answer = try await AssistantRequestRecovery.response(requestID: requestID, wasDelivered: message.state == .delivered || message.attachmentRemoved == true || message.requiresSavedResponse == true, remote: remote) {
                    created = true
                    try store.updateChatDelivery(messageID: messageID, state: .sending)
                    try await sync.sync(store: store, remote: remote)
                    var remoteAttachmentID: String?
                    if let localID = message.attachmentIDs.first, let item = store.snapshot.attachments.first(where: { $0.id == localID }) {
                        if let cached = item.remoteAttachmentID { remoteAttachmentID = cached }
                        else { let uploaded = try await remote.uploadJPEG(AttachmentFiles(ownerID: remote.ownerID).read(item)); try Task.checkCancellation(); try store.updateAttachmentRemoteID(id: item.id, remoteID: uploaded.id); remoteAttachmentID = uploaded.id }
                    }
                    return try await remote.chat(requestID: requestID, day: message.dayID, text: message.text, attachmentID: remoteAttachmentID, healthContext: context)
                }
                if !created { try await sync.sync(store: store, remote: remote); pendingConfirmation = nil }
                try Task.checkCancellation()
                guard remote.ownerID == message.remoteOwnerID else { throw CancellationError() }
                try store.appendAssistantMessage(text: answer.message, date: dateForDay(message.dayID) ?? selectedDate, replyTo: messageID, ownerID: remote.ownerID)
                try store.updateChatDelivery(messageID: messageID, state: .delivered)
                try? health.savePendingChatContext(nil, requestID: requestID, accountScope: scope)
                response = answer; responseDay = message.dayID; confirmedIDs = []; reviewedDrafts = [:]; reviewedObservations = [:]; errorKey = nil
            } catch {
                if message.state != .delivered { try? store.updateChatDelivery(messageID: messageID, state: Task.isCancelled ? .cancelled : .failed) }
                if !Task.isCancelled { errorKey = error.userFacingRemoteKey }
            }
        }
    }
    private func confirm(_ proposal: AssistantProposal, completeness: DayCompleteness = .incomplete) {
        guard let operationID = UUID(uuidString: proposal.id), !confirmedIDs.contains(proposal.id), !store.snapshot.operations.contains(where: { $0.id == operationID }) else { return }
        guard pendingConfirmation == nil || pendingConfirmation?.proposalID == proposal.id else { return }
        runningTask = Task {
            isSending = true; defer { isSending = false }
            do {
                if let pending = pendingConfirmation {
                    try await sync.applyConfirmed(pending.snapshot, store: store, remote: remote, operationID: pending.operationID)
                    pendingConfirmation = nil; confirmedIDs.insert(proposal.id); errorKey = nil; return
                }
                let staged = NutritionStore(persistence: ProposalPersistence(store.snapshot))
                    switch proposal.action {
                    case "add": let draft = try reviewedDrafts[proposal.id] ?? AssistantFoodReview.draft(for: proposal, fallbackDate: dateForDay(proposal.day) ?? selectedDate, intent: response?.intent); _ = try staged.addEntry(draft, operationID: operationID)
                    case "update": guard let id = proposal.entry_id.flatMap(UUID.init(uuidString:)), let version = proposal.expected_version else { throw NutritionError.invalidData }; let draft = try reviewedDrafts[proposal.id] ?? AssistantFoodReview.draft(for: proposal, fallbackDate: dateForDay(proposal.day) ?? selectedDate, intent: response?.intent); try staged.updateEntry(id: id, expectedVersion: version, draft: draft, operationID: operationID)
                    case "delete": guard !proposal.requires_clarification, let id = proposal.entry_id.flatMap(UUID.init(uuidString:)), let version = proposal.expected_version else { throw NutritionError.invalidData }; try staged.deleteEntry(id: id, expectedVersion: version, operationID: operationID)
                    case "add_weight", "add_activity": guard let value = reviewedObservations[proposal.id] else { throw NutritionError.invalidData }; try value.apply(action: proposal.action, to: staged, operationID: operationID)
                    case "close_day":
                        guard let date = dateForDay(proposal.day) else { throw NutritionError.invalidData }
                        let before = staged.snapshot
                        let candidate = try TrackingBridge.preparedClosure(on: date, store: staged, health: health.snapshot, accountScope: remote.ownerID ?? "local", completeness: completeness, operationID: operationID)
                        if let summary = candidate.days.first(where: { $0.id == staged.dayID(for: date) })?.summaries.last, summary.intakeSource == .health {
                            // Retained through lost acknowledgments; unpublished summaries are ignored by the UI.
                            _ = try health.recordNutritionClosure(on: date, dayID: staged.dayID(for: date), accountScope: remote.ownerID ?? "local", goals: staged.goals(on: date), closureID: summary.id)
                        }
                        try staged.publishPreparedSnapshot(candidate, expectedSnapshot: before)
                    default: throw NutritionError.invalidData
                    }
                pendingConfirmation = PendingAssistantConfirmation(proposalID: proposal.id, operationID: operationID, snapshot: staged.snapshot)
                try await sync.applyConfirmed(staged.snapshot, store: store, remote: remote, operationID: operationID)
                pendingConfirmation = nil
                confirmedIDs.insert(proposal.id); errorKey = nil
            } catch { errorKey = (error as? NutritionError)?.userFacingKey ?? error.userFacingRemoteKey }
        }
    }
    private func undo(_ event: NutritionChangeEvent) {
        runningTask = Task {
            isSending = true; defer { isSending = false }
            do {
                let operationID = UUID()
                let staged = NutritionStore(persistence: PreparedNutritionPersistence(store.snapshot))
                try staged.undo(eventID: event.id, operationID: operationID)
                try await sync.applyConfirmed(staged.snapshot, store: store, remote: remote, operationID: operationID)
                confirmedIDs.remove(event.operationID.uuidString); errorKey = nil
            } catch { errorKey = (error as? NutritionError)?.userFacingKey ?? error.userFacingRemoteKey }
        }
    }
    private func healthContext(day: String) -> JSONValue? {
        guard let date = dateForDay(day) else { return nil }
        var metrics: [String: JSONValue] = [:]
        for (key, metric) in [("active_kcal",HealthMetric.activeEnergy),("steps",.steps),("exercise_minutes",.exerciseMinutes)] {
            if let value = health.snapshot.value(for: metric, on: date) { metrics[key] = .number(value) }
        }
        let resolved = TrackingBridge.nutrition(on: date, manual: store.snapshot, health: health.snapshot, accountScope: remote.ownerID ?? "local")
        let frozen = store.day(on: date)?.isClosed == true && resolved.selection == .health
        let values = frozen ? resolved.values : NutrientValues(energy: health.snapshot.value(for: .dietaryEnergy, on: date), protein: health.snapshot.value(for: .protein, on: date), carbohydrates: health.snapshot.value(for: .carbohydrates, on: date), fat: health.snapshot.value(for: .fat, on: date))
        for (key, value) in [("dietary_kcal",values.energy),("protein_g",values.protein),("carbohydrates_g",values.carbohydrates),("fat_g",values.fat)] {
            if let value { metrics[key] = .number(value) }
        }
        let end = store.snapshot.profile.calendar.date(byAdding: .day, value: 1, to: date) ?? date
        if let weight = health.snapshot.latestWeight(before: end), store.snapshot.profile.calendar.isDate(weight.endDate, inSameDayAs: date) { metrics["weight_kg"] = .number(weight.value) }
        return .object(["consent":.bool(true),"purpose":.string("chat"),"day":.string(day),"metrics":.object(metrics)])
    }
    private func selectPhoto(_ data: Data) {
        do {
            let clean = try AttachmentFiles.sanitizedJPEG(data)
            let item = try AttachmentFiles(ownerID: remote.ownerID).save(clean, id: UUID(), ownerID: remote.ownerID)
            do { try store.saveAttachment(item) } catch { try? AttachmentFiles(ownerID: remote.ownerID).delete(item); throw error }
            if let previous = attachment { try AttachmentRemoval.remove(id: previous.id, photos: AttachmentFiles(ownerID: remote.ownerID).removalIO) { try store.removeAttachment(id: previous.id) } }
            attachment = item; previewImage = UIImage(data: clean); selectedPhoto = nil; errorKey = nil
        } catch { errorKey = "Could not prepare this photo. Choose a supported image under 20 MB." }
    }
    private func removePhoto() {
        guard let attachment else { return }
        do { try AttachmentRemoval.remove(id: attachment.id, photos: AttachmentFiles(ownerID: remote.ownerID).removalIO) { try store.removeAttachment(id: attachment.id) }; self.attachment = nil; previewImage = nil }
        catch { errorKey = "Could not delete the photo. Please try again." }
    }
    private func deletePhoto(_ item: NutritionAttachment) {
        let scope = remote.ownerID
        runningTask = Task {
            isSending = true; defer { isSending = false }
            do {
                if let id = item.remoteAttachmentID {
                    guard remote.isAuthenticated, scope == item.remoteOwnerID else { throw RemoteError.authentication }
                    do { try await remote.deleteAttachment(id: id) } catch RemoteError.notFound { /* Already deleted. */ }
                }
                try Task.checkCancellation()
                guard remote.ownerID == scope else { throw CancellationError() }
                try AttachmentRemoval.remove(id: item.id, photos: AttachmentFiles(ownerID: scope).removalIO) { try store.removeAttachment(id: item.id) }
                errorKey = nil
            } catch AttachmentRemovalError.rollbackFailed { errorKey = "Photo deletion failed and its local copy could not be recovered. Keep your backup." }
            catch { errorKey = "Could not delete the photo. Please try again." }
        }
    }
}

extension ChatDeliveryState {
    var titleKey: String { switch self { case .queued: "Pending · not sent"; case .sending: "Sending…"; case .delivered: "Delivered"; case .failed: "Failed · retry explicitly"; case .cancelled: "Cancelled" } }
}
