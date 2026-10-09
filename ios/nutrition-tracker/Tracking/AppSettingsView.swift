import SwiftUI
import UniformTypeIdentifiers

extension NutritionStore {
    static func forOwner(_ owner: String?) -> NutritionStore {
        guard let owner, let id = UUID(uuidString: owner) else { return NutritionStore() }
        let root = URL.applicationSupportDirectory.appendingPathComponent("NutritionTracker/Accounts", isDirectory: true)
        return NutritionStore(persistence: NutritionFileRepository(fileURL: root.appendingPathComponent("\(id.uuidString).json")))
    }
}

struct AppSettingsView: View {
    @Environment(NutritionStore.self) private var store
    @Environment(HealthSyncModel.self) private var health
    @Environment(RemoteSession.self) private var remote
    @Environment(\.dismiss) private var dismiss
    @State private var useGoals = false
    @State private var goals = NutritionGoals(energy: 2100, protein: 140, carbohydrates: 250, fat: 60)
    @State private var effectiveDate = Date.now
    @State private var preferences = ""
    @State private var showHealth = false
    @State private var showAccount = false
    @State private var showDisconnect = false
    @State private var showDelete = false
    @State private var showRestore = false
    @State private var pendingRestore: TrackingBackup?
    @State private var shareURL: URL?
    @State private var includeHealth = false
    @State private var errorKey: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("Daily goals") {
                    Toggle("Use daily goals", isOn: $useGoals)
                    DatePicker("Effective from", selection: $effectiveDate, displayedComponents: .date)
                    if useGoals {
                        goalField("Energy (kcal)", $goals.energy); goalField("Protein (g)", $goals.protein)
                        goalField("Carbs (g)", $goals.carbohydrates); goalField("Fat (g)", $goals.fat)
                    }
                    Text("Goal changes create a version. Earlier days keep their previous goals.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Preferences") {
                    TextField("Food preferences and restrictions", text: $preferences, axis: .vertical)
                    Text(verbatim: store.snapshot.profile.timeZoneIdentifier).font(.caption)
                }
                Section("Apple Health") {
                    Button("Connect or change selection") { showHealth = true }.disabled(health.isWorking)
                    if health.snapshot.isConnected { Button("Sync now") { Task { await health.refreshIfConnected() } } }
                    if health.snapshot.configuration != nil { Button("Disconnect or delete local copy", role: .destructive) { showDisconnect = true } }
                }
                Section("History and backup") {
                    NavigationLink("Import spreadsheet") { SpreadsheetImportView() }
                    Toggle("Include Apple Health in this export", isOn: $includeHealth)
                    Text("The export can contain personal data. Choose where to share or save it.").font(.footnote).foregroundStyle(.secondary)
                    Button("Export JSON backup") { exportBackup() }
                    Button("Export records CSV") { exportCSV() }
                    if let shareURL { ShareLink(item: shareURL) { Label("Share exported file", systemImage: "square.and.arrow.up") } }
                    Button("Restore backup") { showRestore = true }
                    ForEach(store.snapshot.importBatches) { batch in
                        VStack(alignment: .leading) {
                            Text(verbatim: batch.fileName).font(.caption)
                            Button("Undo this import", role: .destructive) { perform { try store.undoImportBatch(id: batch.id) } }
                        }
                    }
                }
                Section("Private account") {
                    if remote.isAuthenticated {
                        Text(verbatim: remote.email)
                        Text("This account has its own history. Signing out returns to your local history.").font(.footnote).foregroundStyle(.secondary)
                        Button("Sign out") { Task { await remote.logout() } }
                        Button("Delete account and its data", role: .destructive) { showDelete = true }
                    } else { Button("Sign in or create account") { showAccount = true } }
                    Text("Health import and manual tracking work without an account. Chat and photo analysis use the private server.").font(.footnote).foregroundStyle(.secondary)
                }
                Section { Button("Delete local tracking data", role: .destructive) { showDelete = true } }
                if let errorKey { Section { OperationErrorView(key: errorKey) } }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("settings.done") }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { perform {
                    try store.saveGoals(useGoals ? goals : nil, effectiveDate: effectiveDate)
                    var profile = store.snapshot.profile; profile.preferences = preferences; try store.updateProfile(profile)
                    dismiss()
                } }.disabled(useGoals && !goals.isValid || store.storageNeedsRecovery) }
            }
            .onAppear {
                preferences = store.snapshot.profile.preferences
                if let saved = store.goals(on: effectiveDate) { useGoals = true; goals = saved }
                else if store.snapshot.goals.isEmpty, let legacy = health.snapshot.goals { useGoals = true; goals = legacy }
            }
            .onChange(of: effectiveDate) { _, date in if let saved = store.goals(on: date) { useGoals = true; goals = saved } else { useGoals = false } }
            .sheet(isPresented: $showHealth) { HealthConnectionView() }
            .sheet(isPresented: $showAccount) { AccountAccessView() }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= TrackingBackupCodec.maximumBytes else { throw NutritionError.invalidData }
                    let data = try Data(contentsOf: url)
                    let backup = try TrackingBackupCodec.decode(data, ownerID: remote.ownerID,
                        validateHealth: { try health.validateRestoredSnapshot($0) },
                        validateImage: { _ = try AttachmentFiles.sanitizedJPEG($0) })
                    pendingRestore = backup
                } catch { errorKey = (error as? TrackingBackupError)?.userFacingKey ?? "Could not read this backup. Your saved data is unchanged." }
            }
            .confirmationDialog("Replace local history with this backup?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible) {
                Button("Restore", role: .destructive) { restoreBackup() }
                Button("Cancel", role: .cancel) { pendingRestore = nil }
            } message: {
                VStack {
                    Text(LocalizedStringKey(pendingRestore?.sourceAccountID == nil ? "Backup source: local history" : "Backup source: your signed-in account"))
                    Text(LocalizedStringKey(remote.isAuthenticated ? "Restore destination: your signed-in account" : "Restore destination: local history"))
                    Text("Only this account's local tracking is replaced. Backups from another account require signing in to that account. Local-only chat stays local. A Health copy is restored only if included. Apple Health originals stay unchanged.")
                }
            }
            .confirmationDialog("Disconnect Apple Health?", isPresented: $showDisconnect, titleVisibility: .visible) {
                Button("Disconnect and keep local copy") { health.disconnect(removeLocalCopy: false) }
                Button("Delete local Health copy", role: .destructive) { health.disconnect(removeLocalCopy: true) }
            } message: { Text("Syncing stops. Original Apple Health records stay unchanged.") }
            .confirmationDialog("Delete your data?", isPresented: $showDelete, titleVisibility: .visible) {
                Button("Delete local tracking and Health copy", role: .destructive) { perform { try AttachmentFiles(ownerID: remote.ownerID).deleteAll(); try store.deleteAllLocalTracking(); health.disconnect(removeLocalCopy: true) } }
                if remote.isAuthenticated { Button("Delete remote account too", role: .destructive) { Task {
                    let oldStore = store; let files = AttachmentFiles(ownerID: remote.ownerID)
                    do { try await remote.deleteAccount(); try files.deleteAll(); try oldStore.deleteAllLocalTracking(); health.disconnect(removeLocalCopy: true) }
                    catch { errorKey = error.userFacingRemoteKey }
                } } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Export a backup first if you want to keep a copy. Apple Health originals are never deleted.") }
        }
    }
    private func goalField(_ title: LocalizedStringKey, _ value: Binding<Double>) -> some View { RequiredNumberField(title: title, value: value) }
    private func perform(_ action: () throws -> Void) { do { try action(); errorKey = nil } catch { errorKey = (error as? TrackingBackupError)?.userFacingKey ?? (error as? NutritionError)?.userFacingKey ?? "Could not save the record. Your saved data is unchanged." } }
    private func exportBackup() {
        perform {
            let files = AttachmentFiles(ownerID: remote.ownerID)
            var images: [String: Data] = [:]
            var rawBytes = 0
            for item in store.snapshot.attachments {
                let image = try files.read(item); rawBytes += image.count
                guard rawBytes <= TrackingBackupCodec.maximumBytes * 3 / 4 else { throw NutritionError.invalidData }
                images[item.id.uuidString] = image
            }
            let backup = TrackingBackup(exportedAt: .now, nutrition: store.snapshot, health: includeHealth ? try TrackingExportScope.health(health.snapshot, ownerID: remote.ownerID) : nil, attachmentFiles: images, ownerID: remote.ownerID)
            let url = URL.temporaryDirectory.appendingPathComponent("nutrition-backup-\(UUID().uuidString).json")
            let data = try TrackingBackupCodec.encode(backup)
            try data.write(to: url, options: [.atomic, .completeFileProtection]); shareURL = url
        }
    }
    private func exportCSV() {
        perform {
            let data = try TrackingCSVExport.encode(nutrition: store.snapshot, health: includeHealth ? health.snapshot : nil, ownerID: remote.ownerID)
            let url = URL.temporaryDirectory.appendingPathComponent("nutrition-records-\(UUID().uuidString).csv")
            try data.write(to: url, options: [.atomic, .completeFileProtection]); shareURL = url
        }
    }
    private func restoreBackup() {
        guard let backup = pendingRestore else { return }
        perform {
            let checkpoint = try store.captureCheckpoint()
            let original = checkpoint.snapshot
            let recovering = checkpoint.storageNeedsRecovery
            try TrackingBackupRestorer.restore(backup, original: original, recoveringUnreadableStore: recovering,
                photos: AttachmentFiles(ownerID: remote.ownerID).backupIO,
                replaceNutrition: { candidate, expected in
                    if recovering {
                        try store.restorePreparedSnapshot(candidate, expectedSnapshot: expected)
                    } else { try store.publishPreparedSnapshot(candidate, expectedSnapshot: expected) }
                }, rollbackNutrition: { try store.restoreCheckpoint(checkpoint, expectedSnapshot: $0) },
                restoreHealth: { try health.restoreSnapshot($0) })
            pendingRestore = nil
        }
    }
}

struct AccountAccessView: View {
    @Environment(RemoteSession.self) private var remote
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var email = ""
    @State private var password = ""
    @State private var create = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Private server") { TextField("HTTPS server address", text: $endpoint).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("account.endpoint") }
                Section("Account") {
                    TextField("Email", text: $email).keyboardType(.emailAddress).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("account.email")
                    SecureField("Password", text: $password).textContentType(create ? .newPassword : .password).accessibilityIdentifier("account.password")
                    Toggle("Create a new account", isOn: $create).accessibilityIdentifier("account.create")
                    if create { Text("Use at least 12 characters.").font(.footnote) }
                    Button(create ? "Create account" : "Sign in") { Task {
                        await remote.authenticate(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), email: email, password: password, createAccount: create)
                        if remote.isAuthenticated { password = ""; dismiss() }
                    } }.disabled(remote.isWorking || email.isEmpty || password.isEmpty || endpoint.isEmpty).accessibilityIdentifier("account.submit")
                    if remote.isWorking { ProgressView() }
                    if let key = remote.errorKey { OperationErrorView(key: key) }
                }
            }.navigationTitle("Private account").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
