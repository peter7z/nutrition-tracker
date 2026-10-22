import SwiftUI
import Foundation

@main struct NutritionTrackerApp: App {
    @UIApplicationDelegateAdaptor(HealthBackgroundAppDelegate.self) private var appDelegate
    @State private var account: AccountSession
    @State private var health: HealthSyncModel
    @State private var weights = HealthBackgroundRuntime.shared.weights
    @State private var nutritionHealth = HealthNutritionUpload()
    @State private var bodyMeasurementHealth = HealthBackgroundRuntime.shared.measurements
    private let history: LegacyHistory
    private let uiTesting: Bool
    init() {
        #if DEBUG
        uiTesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let testURL = URL.temporaryDirectory.appendingPathComponent("nutrition-ui-testing.json")
        let testHealthURL = URL.temporaryDirectory.appendingPathComponent("health-ui-testing.json")
        if uiTesting && ProcessInfo.processInfo.arguments.contains("--reset-ui-testing") {
            try? FileManager.default.removeItem(at: testURL)
            try? FileManager.default.removeItem(at: testHealthURL)
        }
        if uiTesting && ProcessInfo.processInfo.arguments.contains("--seed-ui-testing") {
            try? JSONEncoder().encode(CompanionTestFixture.history(on: .now)).write(to: testURL, options: .atomic)
        }
        if uiTesting && ProcessInfo.processInfo.arguments.contains("--seed-progress-ui-testing") {
            try? JSONEncoder().encode(CompanionTestFixture.progress(on: .now)).write(to: testURL, options: .atomic)
        }
        history = uiTesting ? LegacyHistory(ownerID: nil) : .stored()
        _health = State(initialValue: uiTesting ? HealthSyncModel(persistence: HealthFileRepository(fileURL: testHealthURL)) : HealthBackgroundRuntime.shared.health)
        #else
        uiTesting = false
        history = .stored()
        _health = State(initialValue: HealthBackgroundRuntime.shared.health)
        #endif
        #if DEBUG
        _account = State(initialValue: uiTesting ? AccountUITestFixture.makeSession() : HealthBackgroundRuntime.shared.account)
        #else
        _account = State(initialValue: HealthBackgroundRuntime.shared.account)
        #endif
    }
    var body: some Scene {
        WindowGroup {
            AccountTrackingRoot(history: history, uiTesting: uiTesting)
                .environment(account).environment(health).environment(weights).environment(nutritionHealth)
                .environment(bodyMeasurementHealth).environment(\.legacyHistory, history)
                .preferredColorScheme(testAppearance)
        }
    }
    private var testAppearance: ColorScheme? {
        #if DEBUG
        guard uiTesting else { return nil }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-dark") { return .dark }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing-light") { return .light }
        #endif
        return nil
    }
}

/// Server diary with account-scoped caching; Health nutrition export is opt-in.
private struct AccountTrackingRoot: View {
    @Environment(AccountSession.self) private var account
    @Environment(HealthSyncModel.self) private var health
    @Environment(HealthWeightUpload.self) private var weights
    @Environment(HealthNutritionUpload.self) private var nutritionHealth
    @Environment(HealthBodyMeasurementUpload.self) private var bodyMeasurementHealth
    @State private var nutrition: NutritionStore
    private let history: LegacyHistory
    private let uiTesting: Bool
    init(history: LegacyHistory, uiTesting: Bool) {
        self.history = history; self.uiTesting = uiTesting
        let url = uiTesting ? URL.temporaryDirectory.appendingPathComponent("nutrition-ui-testing.json") : history.fileURL
        _nutrition = State(initialValue: NutritionStore(persistence: NutritionFileRepository(fileURL: url)))
    }
    private var backgroundConfiguration: String {
        "\(account.session?.user_id ?? ""):\(weights.isEnabled):\(bodyMeasurementHealth.isEnabled):\(health.snapshot.isConnected):\(health.snapshot.configuration?.metrics.contains(.weight) == true)"
    }
    var body: some View {
        Group {
            if account.session == nil {
                LoginView()
            } else if !uiTesting && nutrition.ownerID != account.session?.user_id {
                ProgressView("Syncing diary…")
            } else {
                ContentView(refreshOnActivation: !uiTesting)
                    .id(account.session?.user_id)
            }
        }
            .environment(nutrition)
            .environment(\.legacyHistory, account.session.map { LegacyHistory(ownerID: UUID(uuidString: $0.user_id)) } ?? history)
            .onChange(of: backgroundConfiguration) { _, _ in
                guard !uiTesting else { return }
                HealthBackgroundRuntime.shared.configure()
            }
            .onChange(of: nutrition.snapshot.entries) { _, entries in
                guard !uiTesting, account.session != nil else { return }
                Task { await nutritionHealth.syncIfEnabled(entries: entries, owner: account.session?.user_id) }
            }
            .task(id: account.session?.user_id) {
                guard !uiTesting else { return }
                nutrition.selectAccount(account.session?.user_id)
                weights.selectAccount(account.session?.user_id)
                nutritionHealth.selectAccount(account.session?.user_id)
                bodyMeasurementHealth.selectAccount(account.session?.user_id)
                HealthBackgroundRuntime.shared.configure()
                guard account.session != nil else { return }
                await weights.sync(account: account, health: health)
                await nutrition.refresh(account: account)
                await nutritionHealth.syncIfEnabled(entries: nutrition.snapshot.entries, owner: account.session?.user_id)
                await bodyMeasurementHealth.sync(account: account)
            }
    }
}
