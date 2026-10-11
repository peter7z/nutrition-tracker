import SwiftUI
import Foundation

@main struct NutritionTrackerApp: App {
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
    }
    var body: some Scene {
        WindowGroup {
            AccountTrackingRoot(history: history, uiTesting: uiTesting)
                .environment(health).environment(\.legacyHistory, history)
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

/// The existing account file remains selected without enabling tracking writes.
private struct AccountTrackingRoot: View {
    @State private var nutrition: NutritionStore
    init(history: LegacyHistory, uiTesting: Bool) {
        let url = uiTesting ? URL.temporaryDirectory.appendingPathComponent("nutrition-ui-testing.json") : history.fileURL
        _nutrition = State(initialValue: NutritionStore(persistence: NutritionFileRepository(fileURL: url)))
    }
    var body: some View { ContentView().environment(nutrition) }
}
