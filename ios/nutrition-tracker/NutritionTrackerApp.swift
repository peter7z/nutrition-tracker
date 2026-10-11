import SwiftUI
import Foundation

@main struct NutritionTrackerApp: App {
    @State private var account: AccountSession
    @State private var health: HealthSyncModel
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
        history = uiTesting ? LegacyHistory(ownerID: nil) : .stored()
        _health = State(initialValue: uiTesting ? HealthSyncModel(persistence: HealthFileRepository(fileURL: testHealthURL)) : HealthSyncModel())
        #else
        uiTesting = false
        history = .stored()
        _health = State(initialValue: HealthSyncModel())
        #endif
        _account = State(initialValue: AccountSession(enabled: !uiTesting))
    }
    var body: some Scene {
        WindowGroup {
            AccountTrackingRoot(history: history, uiTesting: uiTesting)
                .environment(account).environment(health).environment(\.legacyHistory, history)
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

/// Read-only server diary with account-scoped caching; legacy files stay intact.
private struct AccountTrackingRoot: View {
    @Environment(AccountSession.self) private var account
    @State private var nutrition: NutritionStore
    private let history: LegacyHistory
    private let uiTesting: Bool
    init(history: LegacyHistory, uiTesting: Bool) {
        self.history = history; self.uiTesting = uiTesting
        let url = uiTesting ? URL.temporaryDirectory.appendingPathComponent("nutrition-ui-testing.json") : history.fileURL
        _nutrition = State(initialValue: NutritionStore(persistence: NutritionFileRepository(fileURL: url)))
    }
    var body: some View {
        Group {
            if !uiTesting && nutrition.ownerID != account.session?.user_id {
                ProgressView("Syncing diary…")
            } else {
                ContentView()
            }
        }
            .environment(nutrition)
            .environment(\.legacyHistory, account.session.map { LegacyHistory(ownerID: UUID(uuidString: $0.user_id)) } ?? history)
            .task(id: account.session?.user_id) {
                guard !uiTesting else { return }
                nutrition.selectAccount(account.session?.user_id)
                await nutrition.refresh(account: account)
            }
    }
}
