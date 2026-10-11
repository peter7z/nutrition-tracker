import XCTest

@MainActor final class TrackingUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testSavedHistoryCanBeReadAfterRelaunchWithoutAnyTrackingWriteRoutes() {
        launch(seed: true)
        let energy = app.descendants(matching: .any)["today.energy"]
        XCTAssertTrue(energy.waitForExistence(timeout: 10))
        XCTAssertEqual(energy.value as? String, "133.5")
        assertNoWriteRoutes()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Saved banana"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Delete"].exists)
        tapTab("Progress")
        XCTAssertTrue(app.navigationBars["Progress"].waitForExistence(timeout: 5))
        let activity = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Saved walk")).firstMatch
        reveal(activity)
        if !activity.exists {
            let debug = XCTAttachment(string: app.debugDescription); debug.lifetime = .keepAlways; add(debug)
            capture("missing-saved-activity")
        }
        XCTAssertTrue(activity.exists)
        XCTAssertFalse(app.buttons["Add progress record"].exists)
        XCTAssertFalse(app.buttons["Actions for manual weight"].exists)
        XCTAssertFalse(app.buttons["Actions for manual activity"].exists)
        app.terminate(); launch(reset: false)
        XCTAssertTrue(energy.waitForExistence(timeout: 10))
        XCTAssertEqual(energy.value as? String, "133.5")
        assertNoWriteRoutes()
        app.buttons["tracking.settings"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Save"].exists)
        XCTAssertFalse(app.buttons["Restore backup"].exists)
        XCTAssertFalse(app.buttons["Import spreadsheet"].exists)
        XCTAssertFalse(app.buttons["Sign in or create account"].exists)
        XCTAssertEqual(app.textFields.count, 0)
    }

    func testEmptyAppKeepsHealthConfigurationAndReadOnlyProgress() {
        launch()
        XCTAssertTrue(app.buttons["Connect Apple Health"].waitForExistence(timeout: 10))
        assertNoWriteRoutes()
        app.buttons["Connect Apple Health"].tap()
        XCTAssertTrue(app.navigationBars["Connect Apple Health"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Data types"].exists)
        app.buttons["Cancel"].tap()
        tapTab("Progress")
        XCTAssertTrue(app.staticTexts["No weight data in this range"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add progress record"].exists)
    }

    func testSpanishLightScreens() { captureSpanish(appearance: "light", largest: false) }
    func testSpanishDarkLargestTextScreens() { captureSpanish(appearance: "dark", largest: true) }

    private func captureSpanish(appearance: String, largest: Bool) {
        launch(spanish: true, appearance: appearance, largest: largest)
        XCTAssertTrue(app.buttons["Conectá Apple Health"].waitForExistence(timeout: 10))
        capture("today-\(appearance)")
        assertNoWriteRoutes()
        app.buttons["tracking.settings"].tap()
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        capture("settings-\(appearance)")
        app.buttons["settings.done"].tap()
        tapTab("Progreso")
        XCTAssertTrue(app.navigationBars["Progreso"].waitForExistence(timeout: 5))
        capture("progress-\(appearance)")
        XCTAssertFalse(app.buttons["Add progress record"].exists)
    }

    private func launch(reset: Bool = true, seed: Bool = false, spanish: Bool = false, appearance: String? = nil, largest: Bool = false) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_UY" : "en_US"]
        if reset { app.launchArguments.append("--reset-ui-testing") }
        if seed { app.launchArguments.append("--seed-ui-testing") }
        if let appearance { app.launchArguments.append("--ui-testing-\(appearance)") }
        if largest { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
    }
    private func assertNoWriteRoutes() {
        for id in ["today.openChat", "today.closeDay", "today.reopenDay", "chat.draft", "food.name", "food.energy"] {
            XCTAssertFalse(app.descendants(matching: .any)[id].exists, "Removed route: \(id)")
        }
        XCTAssertFalse(app.tabBars.buttons["Chat"].exists)
        XCTAssertFalse(app.buttons["Set goals"].exists)
    }
    private func tapTab(_ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); XCTAssertTrue(button.isHittable); button.tap()
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "companion-" + name
        attachment.lifetime = .keepAlways; add(attachment)
    }
}
