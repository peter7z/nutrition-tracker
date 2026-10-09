import SwiftUI
import Foundation

@main struct NutritionTrackerApp: App {
    @State private var health: HealthSyncModel
    @State private var remote: RemoteSession
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
        _remote = State(initialValue: RemoteSession(restoreCredentials: !uiTesting || ProcessInfo.processInfo.arguments.contains("--ui-testing-restore-session"), forceOffline: uiTesting && ProcessInfo.processInfo.arguments.contains("--ui-testing-offline"), credentialService: uiTesting ? "com.peter7z.NutritionTracker.ui-testing-session" : "com.peter7z.NutritionTracker.remote-session"))
        _health = State(initialValue: uiTesting ? HealthSyncModel(persistence: HealthFileRepository(fileURL: testHealthURL)) : HealthSyncModel())
        #else
        uiTesting = false
        _remote = State(initialValue: RemoteSession())
        _health = State(initialValue: HealthSyncModel())
        #endif
    }
    var body: some Scene {
        WindowGroup {
            AccountTrackingRoot(ownerID: remote.ownerID, uiTesting: uiTesting)
                .id(remote.ownerID ?? "local")
                .environment(health).environment(remote)
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

/// Account identity creates both the store and the view tree together. Drafts,
/// photos and in-flight UI state cannot survive a switch into another account.
private struct AccountTrackingRoot: View {
    @Environment(HealthSyncModel.self) private var health
    @State private var nutrition: NutritionStore
    let ownerID: String?
    init(ownerID: String?, uiTesting: Bool) {
        self.ownerID = ownerID
        _nutrition = State(initialValue: uiTesting ? NutritionStore(persistence: NutritionFileRepository(fileURL: URL.temporaryDirectory.appendingPathComponent("nutrition-ui-testing.json"))) : NutritionStore.forOwner(ownerID))
    }
    var body: some View {
        ContentView().environment(nutrition)
            .task {
                if ownerID == nil, nutrition.snapshot.goals.isEmpty, let legacy = health.snapshot.goals {
                    try? nutrition.saveGoals(legacy, effectiveDate: .now)
                }
            }
    }
}
