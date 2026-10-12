import SwiftUI

struct AppSettingsView: View {
    @Environment(AccountSession.self) private var account
    @Environment(NutritionStore.self) private var nutrition
    @Environment(HealthWeightUpload.self) private var weightUpload
    @Environment(HealthSyncModel.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var showHealth = false
    @State private var showDisconnect = false
    @State private var confirmWeightSharing = false
    @State private var confirmDeleteWeights = false

    var body: some View {
        NavigationStack {
            Form {
                AccountSection()
                Section("Share weight with your account") {
                    Text("Upload weight measurements and their dates from Apple Health to your Nutrition Tracker account. They will be available in the web diary and ChatGPT. Food, activity and other Health data are not uploaded.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Stopping uploads keeps previously shared weights. Delete the server copy to remove them from your account.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if account.session == nil { Text("Sign in to share weight.") }
                    else if weightUpload.isEnabled {
                        Button("Sync weight now") { Task { await weightUpload.sync(account: account, health: health); await nutrition.refresh(account: account) } }
                        Button("Stop sharing weight") { Task { await weightUpload.setConsent(enabled: false, account: account, health: health) } }
                    } else {
                        Button("Enable weight sharing") { confirmWeightSharing = true }
                            .disabled(!health.snapshot.isConnected || health.snapshot.configuration?.metrics.contains(.weight) != true)
                    }
                    if account.session != nil {
                        Button("Delete server weight copy", role: .destructive) { confirmDeleteWeights = true }
                    }
                    if let date = weightUpload.lastSyncDate { LabeledContent("Last weight upload") { Text(date, format: .dateTime.day().month().hour().minute()) } }
                    if let error = weightUpload.errorKey {
                        Text(LocalizedStringKey(error)).foregroundStyle(.red)
                        Button("Retry weight upload") { Task { await weightUpload.sync(account: account, health: health); await nutrition.refresh(account: account) } }
                    }
                    if weightUpload.isWorking { ProgressView() }
                }
                .disabled(weightUpload.isWorking)
                Section("Apple Health") {
                    Button("Connect or change selection") { showHealth = true }
                        .disabled(health.isWorking || health.storageNeedsRecovery)
                    if health.snapshot.isConnected {
                        Button("Sync now") { Task { await health.refreshIfConnected() } }
                            .disabled(health.isWorking || health.storageNeedsRecovery)
                    }
                    if health.snapshot.configuration != nil || health.snapshot.closedNutritionDays?.isEmpty == false || health.snapshot.pendingChatContexts?.isEmpty == false {
                        Button("Disconnect or delete local copy", role: .destructive) { showDisconnect = true }
                            .disabled(health.isWorking)
                    }
                    if let date = health.snapshot.lastSyncDate {
                        LabeledContent("Last sync") { Text(date, format: .dateTime.day().month().hour().minute()) }
                    }
                    Text("Read-only access. Your original Health data stays unchanged.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let key = health.errorKey {
                    Section {
                        OperationErrorView(key: key)
                        if health.storageNeedsRecovery { Button("Retry reading local data") { health.reload() } }
                    }
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("settings.done")
                }
            }
            .sheet(isPresented: $showHealth) { HealthConnectionView() }
            .confirmationDialog("Upload Apple Health weight?", isPresented: $confirmWeightSharing, titleVisibility: .visible) {
                Button("Authorize weight upload") { Task {
                    await weightUpload.setConsent(enabled: true, account: account, health: health)
                    await weightUpload.sync(account: account, health: health)
                    await nutrition.refresh(account: account)
                } }
            } message: { Text("Available weight history will be uploaded, followed by new measurements and deletions. You can stop sharing and delete the server copy at any time.") }
            .confirmationDialog("Delete uploaded weights?", isPresented: $confirmDeleteWeights, titleVisibility: .visible) {
                Button("Delete server copy", role: .destructive) { Task {
                    await weightUpload.setConsent(enabled: false, deleteData: true, account: account, health: health)
                    await nutrition.refresh(account: account)
                } }
            } message: { Text("Sharing will stop. Original measurements in Apple Health and manual weights are kept.") }
            .confirmationDialog("Disconnect Apple Health?", isPresented: $showDisconnect, titleVisibility: .visible) {
                if health.snapshot.isConnected { Button("Disconnect and keep local copy") { health.disconnect(removeLocalCopy: false) } }
                Button("Delete local Health copy", role: .destructive) { health.disconnect(removeLocalCopy: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Syncing stops. Original data in Apple Health is never deleted. Your daily goals are kept.")
            }
        }
    }
}
