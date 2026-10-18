import SwiftUI

struct AppSettingsView: View {
    @Environment(AccountSession.self) private var account
    @Environment(NutritionStore.self) private var nutrition
    @Environment(HealthWeightUpload.self) private var weightUpload
    @Environment(HealthNutritionUpload.self) private var nutritionUpload
    @Environment(HealthBodyMeasurementUpload.self) private var bodyMeasurementUpload
    @Environment(HealthSyncModel.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var showHealth = false
    @State private var showDisconnect = false
    @State private var confirmWeightSharing = false
    @State private var confirmDeleteWeights = false
    @State private var confirmNutritionSync = false
    @State private var confirmBodyMeasurementSync = false

    var body: some View {
        NavigationStack {
            Form {
                AccountSection()
                Section("Share weight with your account") {
                    Text("Upload weight measurements and their dates from Apple Health to your Bocado account. They will be available in the web diary and ChatGPT. Food, activity and other Health data are not uploaded.")
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
                    Text("Apple Health reads stay on this device. Nutrition sync writes food records to Apple Health when you enable it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Nutrition in Apple Health") {
                    Text("Save calories, macros, fiber, vitamins and minerals from your food diary to Apple Health. Sync follows your signed-in account and updates diary changes; existing Health records stay if you stop syncing.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if account.session == nil {
                        Text("Sign in to sync nutrition.")
                    } else if nutritionUpload.isEnabled {
                        Button("Sync nutrition now") {
                            Task { await nutritionUpload.sync(entries: nutrition.snapshot.entries) }
                        }
                        Button("Stop nutrition sync", role: .destructive) { nutritionUpload.disable() }
                    } else {
                        Button("Enable nutrition sync") { confirmNutritionSync = true }
                            .disabled(!nutritionUpload.isAvailable || nutritionUpload.isWorking)
                    }
                    if let date = nutritionUpload.lastSyncDate {
                        LabeledContent("Last nutrition sync") { Text(date, format: .dateTime.day().month().hour().minute()) }
                    }
                    if let error = nutritionUpload.errorKey { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
                    if nutritionUpload.isWorking { ProgressView() }
                }
                .disabled(nutritionUpload.isWorking)
                Section("Body measurements in Apple Health") {
                    Text("Apple Health supports waist circumference, so Bocado syncs the waist measurement at the navel. Neck, minimum waist, biceps, thigh and hip stay in Bocado and MCP.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if account.session == nil {
                        Text("Sign in to sync body measurements.")
                    } else if bodyMeasurementUpload.isEnabled {
                        Button("Sync waist now") { Task { await bodyMeasurementUpload.sync(account: account) } }
                        Button("Stop waist sync", role: .destructive) { bodyMeasurementUpload.disable() }
                    } else {
                        Button("Enable waist sync") { confirmBodyMeasurementSync = true }
                            .disabled(!bodyMeasurementUpload.isAvailable || bodyMeasurementUpload.isWorking)
                    }
                    if let date = bodyMeasurementUpload.lastSyncDate {
                        LabeledContent("Last waist sync") { Text(date, format: .dateTime.day().month().hour().minute()) }
                    }
                    if let error = bodyMeasurementUpload.errorKey { Text(LocalizedStringKey(error)).foregroundStyle(.red) }
                    if bodyMeasurementUpload.isWorking { ProgressView() }
                }
                .disabled(bodyMeasurementUpload.isWorking)
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
            .confirmationDialog("Enable nutrition sync?", isPresented: $confirmNutritionSync, titleVisibility: .visible) {
                Button("Enable nutrition sync") { Task { await nutritionUpload.enable(account: account, entries: nutrition.snapshot.entries) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your food diary's calories, macros, fiber, vitamins and minerals will be saved to Apple Health. New and edited diary entries will sync when your diary refreshes. You can stop sync here; records already saved in Health will remain.")
            }
            .confirmationDialog("Enable waist sync?", isPresented: $confirmBodyMeasurementSync, titleVisibility: .visible) {
                Button("Enable waist sync") { Task { await bodyMeasurementUpload.enable(account: account) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Bocado will save waist measurements taken at the navel to Apple Health. Other measurements and the minimum waist measurement remain in Bocado. Stopping sync will keep records already saved in Health.")
            }
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
