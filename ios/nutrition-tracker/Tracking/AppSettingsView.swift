import SwiftUI

struct AppSettingsView: View {
    @Environment(HealthSyncModel.self) private var health
    @Environment(\.dismiss) private var dismiss
    @State private var showHealth = false
    @State private var showDisconnect = false

    var body: some View {
        NavigationStack {
            Form {
                AccountSection()
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
