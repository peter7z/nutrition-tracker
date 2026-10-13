import XCTest

@MainActor final class TrackingUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    func testSignedOutCannotOpenDiaryProgressOrSettingsEvenWithSavedHistory() {
        launch(seed: true, signedOut: true)
        let signIn = app.buttons["account.apple.signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.isEnabled)
        XCTAssertTrue(app.staticTexts["Sign in to get started"].exists)
        assertLoginOnly()
        app.terminate()
        launch(reset: false, signedOut: true)
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        assertLoginOnly()
    }

    func testExpiredStoredSessionRequiresLogin() {
        launch(seed: true, expired: true)
        XCTAssertTrue(app.buttons["account.apple.signin"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your session expired. Sign in again."].exists)
        assertLoginOnly()
    }

    func testSettingsLogoutReturnsToLoginAndCancelKeepsDiary() {
        launch(seed: true)
        XCTAssertTrue(app.buttons["tracking.settings"].waitForExistence(timeout: 10))
        app.buttons["tracking.settings"].tap()
        let signOut = app.buttons["account.signout"]
        XCTAssertTrue(signOut.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["account.apple.signin"].exists)
        signOut.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(signOut.exists)
        signOut.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Sign out"].tap()
        let signIn = app.buttons["account.apple.signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.isEnabled)
        assertLoginOnly()
    }

    func testLoginConnectionFailureCanRetryWithoutOpeningApp() {
        launch(signedOut: true, offline: true)
        let retry = app.buttons["login.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["account.apple.signin"].isEnabled)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Could not connect. Try again."].waitForExistence(timeout: 5))
        assertLoginOnly()
    }

    func testSpanishLoginLightAndDarkLargestText() {
        launch(spanish: true, appearance: "light", signedOut: true)
        XCTAssertTrue(app.buttons["account.apple.signin"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Iniciá sesión para empezar"].exists)
        capture("login-light-es")
        app.terminate()
        launch(spanish: true, appearance: "dark", largest: true, signedOut: true)
        let signIn = app.buttons["account.apple.signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        reveal(signIn)
        XCTAssertTrue(signIn.isHittable)
        capture("login-dark-accessibility-es")
        assertLoginOnly()
    }

    private func assertLoginOnly() {
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertFalse(app.buttons["tracking.settings"].exists)
        XCTAssertFalse(app.buttons["settings.done"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["today.energy"].exists)
        XCTAssertFalse(app.staticTexts["Saved banana"].exists)
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

    func testProgressWeightZoomAndSelection() {
        launch(progress: true, spanish: true, appearance: "light")
        tapTab("Progreso")
        let range = app.segmentedControls["progress.weight.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        XCTAssertTrue(range.buttons["Mes"].isSelected)
        capture("progress-weight-month-es")
        range.buttons["Semana"].tap()
        XCTAssertTrue(range.buttons["Semana"].isSelected)
        let chart = app.descendants(matching: .any)["progress.weight.chart"].firstMatch
        XCTAssertTrue(chart.exists)
        capture("progress-weight-week-es")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Peso seleccionado"].waitForExistence(timeout: 3))
        capture("progress-weight-selected-es")
        range.buttons["90 días"].tap()
        XCTAssertTrue(app.staticTexts["Último peso"].exists)
        range.buttons["Año"].tap()
        XCTAssertTrue(range.buttons["Año"].isSelected)
        capture("progress-weight-year-es")
        range.buttons["Semana"].tap()
        let expectedReview = "11 / 14 · 4 + 7 por semana"
        let reviewWeights = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", expectedReview, expectedReview)).firstMatch
        reveal(reviewWeights)
        if !reviewWeights.exists {
            let debug = XCTAttachment(string: app.debugDescription); debug.lifetime = .keepAlways; add(debug)
            capture("progress-review-debug")
        }
        XCTAssertTrue(reviewWeights.exists, "Week zoom must keep all 14 days in the weekly review")
    }

    func testProgressWeightDarkLargestText() {
        launch(progress: true, spanish: true, appearance: "dark", largest: true)
        tapTab("Progreso")
        let range = app.segmentedControls["progress.weight.range"]
        XCTAssertTrue(range.waitForExistence(timeout: 5))
        capture("progress-weight-dark-accessibility-es")
        range.buttons["Semana"].tap()
        XCTAssertTrue(range.buttons["Semana"].isSelected)
        app.swipeUp()
        capture("progress-weight-week-dark-accessibility-es")
    }

    func testProgressWeightScrollsThroughHistoryAndReturnsToLatest() {
        launch(progress: true, spanish: true, appearance: "light")
        tapTab("Progreso")
        let chart = app.descendants(matching: .any)["progress.weight.chart"].firstMatch
        XCTAssertTrue(chart.waitForExistence(timeout: 5))
        let period = app.staticTexts["progress.weight.period"]
        let latestPeriod = period.label
        let value = app.staticTexts["progress.weight.value"]
        XCTAssertEqual(value.label, "75,5")
        chart.swipeRight()
        let latest = app.buttons["progress.weight.latest"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertNotEqual(period.label, latestPeriod)
        XCTAssertNotEqual(value.label, "75,5")
        capture("progress-weight-scrolled-month-es")
        let historicalEnd = period.label.components(separatedBy: " – ").last
        let range = app.segmentedControls["progress.weight.range"]
        range.buttons["Semana"].tap()
        XCTAssertTrue(range.buttons["Semana"].isSelected)
        XCTAssertTrue(latest.exists, "Changing zoom must keep the historical period")
        XCTAssertEqual(period.label.components(separatedBy: " – ").last, historicalEnd)
        chart.swipeRight()
        capture("progress-weight-scrolled-week-es")
        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Peso seleccionado"].waitForExistence(timeout: 3))
        latest.tap()
        XCTAssertTrue(app.staticTexts["Último peso"].waitForExistence(timeout: 3))
        XCTAssertEqual(value.label, "75,5")
        XCTAssertFalse(latest.exists)
        chart.swipeRight()
        for _ in 0..<6 {
            guard latest.exists else { break }
            chart.swipeLeft()
        }
        XCTAssertEqual(value.label, "75,5")
        XCTAssertFalse(latest.exists, "Scrolling forward must stop at the latest window")
        let chartY = chart.frame.minY
        app.swipeUp()
        XCTAssertTrue(!chart.exists || chart.frame.minY < chartY - 20,
                      "Vertical page scrolling must remain available")
    }

    func testDayPagingDirectionTitlesAndFixedHeader() {
        launch(seed: true)
        var profileCalendar = Calendar(identifier: .gregorian)
        profileCalendar.timeZone = TimeZone(identifier: "America/Montevideo")!
        let pager = app.scrollViews["today.dayPages"]
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 10))
        XCTAssertTrue(pager.waitForExistence(timeout: 5))
        let header = app.descendants(matching: .any)["today.dayHeader"]
        let initialFrame = header.frame

        pager.swipeRight()
        XCTAssertTrue(app.navigationBars["Yesterday"].waitForExistence(timeout: 5))
        XCTAssertEqual(header.frame.minX, initialFrame.minX, accuracy: 1)
        XCTAssertEqual(header.frame.maxY, initialFrame.maxY, accuracy: 1)
        capture("yesterday-native-paging")

        pager.swipeRight()
        let historicalDate = profileCalendar.date(byAdding: .day, value: -2, to: .now)!
        var titleFormat = Date.FormatStyle.dateTime.day().month(.abbreviated).locale(Locale(identifier: "en_US"))
        titleFormat.timeZone = profileCalendar.timeZone
        XCTAssertTrue(app.navigationBars[historicalDate.formatted(titleFormat)].waitForExistence(timeout: 5))

        pager.swipeLeft()
        XCTAssertTrue(app.navigationBars["Yesterday"].waitForExistence(timeout: 5))
        pager.swipeLeft()
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
        let components = profileCalendar.dateComponents([.year, .month, .day], from: .now)
        let day = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        let energy = app.scrollViews["today.day.\(day)"].descendants(matching: .any)["today.energy"]
        XCTAssertEqual(energy.value as? String, "133.5")
        pager.swipeLeft()
        XCTAssertTrue(app.navigationBars["Today"].exists)

        app.terminate()
        launch(seed: true, spanish: true)
        XCTAssertTrue(app.navigationBars["Hoy"].waitForExistence(timeout: 10))
        app.scrollViews["today.dayPages"].swipeRight()
        XCTAssertTrue(app.navigationBars["Ayer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Nutrición del día"].firstMatch.exists)
    }

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

    private func launch(reset: Bool = true, seed: Bool = false, progress: Bool = false, spanish: Bool = false, appearance: String? = nil, largest: Bool = false,
                        signedOut: Bool = false, expired: Bool = false, offline: Bool = false) {
        app.launchArguments = ["--ui-testing", "-AppleLanguages", spanish ? "(es)" : "(en)", "-AppleLocale", spanish ? "es_UY" : "en_US"]
        if reset { app.launchArguments.append("--reset-ui-testing") }
        if seed { app.launchArguments.append("--seed-ui-testing") }
        if progress { app.launchArguments.append("--seed-progress-ui-testing") }
        if signedOut { app.launchArguments.append("--signed-out-ui-testing") }
        if expired { app.launchArguments.append("--expired-session-ui-testing") }
        if offline { app.launchArguments.append("--login-offline-ui-testing") }
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
