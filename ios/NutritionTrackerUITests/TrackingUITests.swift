import XCTest

@MainActor final class TrackingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        addUIInterruptionMonitor(withDescription: "Decline saving disposable fixture password") { alert in
            guard alert.staticTexts["Save Password?"].exists, alert.buttons["Not Now"].exists else { return false }
            alert.buttons["Not Now"].tap()
            return true
        }
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["today.openChat"].waitForExistence(timeout: 10))
    }

    func testChatAutomaticallyCalculatesRecordsCorrectsClosesAndRelaunchesWithoutMacroEntry() throws {
        tap(app.buttons["today.openChat"])
        tap(app.buttons["Sign in to use the assistant"])
        fill("account.endpoint", with: "http://127.0.0.1:8766")
        fill("account.email", with: UUID().uuidString.lowercased() + "@ui-fixture.example")
        let create = app.switches["account.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); reveal(create)
        create.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(create.value as? String, "1")
        let password = app.secureTextFields["account.password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5)); reveal(password); password.tap()
        password.typeText("UI fixture password 12345")
        tap(app.buttons["account.submit"])
        XCTAssertTrue(app.buttons["today.openChat"].waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["account.submit"])
        waitForExpectations(timeout: 10)
        // Preserve native Password AutoFill in the product, but do not store
        // disposable fixture credentials when iOS offers to save them.
        let declinePassword = app.buttons["Not Now"]
        if declinePassword.waitForExistence(timeout: 3) { declinePassword.tap() }
        tap(tab("Today"))
        tap(app.buttons["today.openChat"])
        fill("chat.draft", with: "Comí 150 g de banana")
        tap(app.buttons["chat.send"])
        let confirm = app.buttons["Confirm consumed food"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["food.energy"].exists)
        XCTAssertFalse(app.textFields["food.protein"].exists)
        tap(confirm)
        XCTAssertTrue(app.staticTexts["Previously confirmed"].waitForExistence(timeout: 10))
        tap(tab("Today"))
        assertCalories(133.5)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Banana").count, 1)
        tap(app.buttons["today.openChat"])
        fill("chat.draft", with: "Eran 100 g de banana")
        tap(app.buttons["chat.send"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 15)); tap(confirm)
        XCTAssertTrue(app.staticTexts["Previously confirmed"].waitForExistence(timeout: 10))
        tap(tab("Today"))
        assertCalories(89)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Banana").count, 1)
        tap(app.buttons["today.closeDay"])
        tap(app.buttons["Close as incomplete"])
        XCTAssertTrue(app.buttons["today.reopenDay"].waitForExistence(timeout: 5))
        assertCalories(89)
        app.launchArguments.append("--ui-testing-restore-session")
        relaunchPreservingData()
        XCTAssertTrue(app.buttons["today.reopenDay"].waitForExistence(timeout: 10))
        assertCalories(89)
        tap(app.buttons["today.reopenDay"])
        XCTAssertTrue(app.buttons["today.closeDay"].waitForExistence(timeout: 5))
        assertCalories(89)
    }

    func testTypingAnUnsentMealDoesNotInventConsumption() throws {
        tap(app.buttons["today.openChat"])
        fill("chat.draft", with: "Comí una banana")
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        tap(app.buttons["chat.dismissKeyboard"])
        tap(tab("Today"))
        XCTAssertTrue(app.staticTexts["No meals recorded"].waitForExistence(timeout: 5))
        relaunchPreservingData()
        XCTAssertTrue(app.staticTexts["No meals recorded"].exists)
        tap(tab("Chat"))
        XCTAssertEqual(app.descendants(matching: .any)["chat.draft"].value as? String, "Comí una banana")
    }

    func testOfflineChatKeepsDraftWithoutClaimingASavedMealOrAssistantResponse() throws {
        app.terminate()
        app.launchArguments.append("--ui-testing-offline")
        app.launch()
        tap(tab("Chat"))
        XCTAssertTrue(app.descendants(matching: .any)["chat.offlineIndicator"].waitForExistence(timeout: 10))
        fill("chat.draft", with: "What if I eat a banana?")
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.isEnabled, "Offline IA must not manufacture a response")
        relaunchPreservingData()
        tap(tab("Chat"))
        let draft = app.descendants(matching: .any)["chat.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 5))
        XCTAssertEqual(draft.value as? String, "What if I eat a banana?")
        XCTAssertFalse(app.staticTexts["Saved meal"].exists)
        tap(tab("Today"))
        XCTAssertTrue(app.staticTexts["No meals recorded"].waitForExistence(timeout: 5))
    }

    func testSpanishScreensNavigationInLightAppearance() throws {
        try captureSpanishScreens(appearance: "Light", largestText: false)
    }

    func testSpanishScreensNavigationInDarkAppearanceWithLargestDynamicType() throws {
        try captureSpanishScreens(appearance: "Dark", largestText: true)
    }

    private func captureSpanishScreens(appearance: String, largestText: Bool) throws {
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-ui-testing", "-AppleLanguages", "(es)", "-AppleLocale", "es_UY", "-AppleInterfaceStyle", appearance]
        app.launchArguments.append(appearance == "Dark" ? "--ui-testing-dark" : "--ui-testing-light")
        if largestText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["today.openChat"].waitForExistence(timeout: 10))
        XCTAssertTrue(tab("Hoy").exists, "Spanish localization must be active")
        capture("today", appearance: appearance, largestText: largestText)
        tap(app.buttons["tracking.settings"])
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        capture("settings", appearance: appearance, largestText: largestText)
        tap(app.buttons["settings.done"])
        tap(tab("Chat"))
        XCTAssertTrue(app.descendants(matching: .any)["chat.draft"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        capture("chat", appearance: appearance, largestText: largestText)
        tap(tab("Progreso"))
        XCTAssertTrue(app.navigationBars["Progreso"].waitForExistence(timeout: 5))
        capture("progress", appearance: appearance, largestText: largestText)
        tap(tab("Hoy"))
        tap(app.buttons["today.openChat"])
        XCTAssertTrue(app.descendants(matching: .any)["chat.draft"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["food.energy"].exists)
        XCTAssertFalse(app.buttons["Save as confirmed product"].exists)
        if app.windows.firstMatch.frame.width > 700 {
            defer { XCUIDevice.shared.orientation = .portrait }
            XCUIDevice.shared.orientation = .landscapeLeft
            expectation(for: NSPredicate { element, _ in
                guard let window = element as? XCUIElement else { return false }
                return window.frame.width > window.frame.height
            }, evaluatedWith: app.windows.firstMatch)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(app.descendants(matching: .any)["chat.draft"].waitForExistence(timeout: 5))
            capture("chat-landscape", appearance: appearance, largestText: largestText)
            tap(tab("Hoy"))
            XCTAssertTrue(app.buttons["today.openChat"].exists)
            capture("today-landscape", appearance: appearance, largestText: largestText)
            tap(tab("Progreso"))
            XCTAssertTrue(app.navigationBars["Progreso"].waitForExistence(timeout: 5))
            capture("progress-landscape", appearance: appearance, largestText: largestText)
        }
    }

    private func tab(_ title: String) -> XCUIElement {
        let phoneTab = app.tabBars.buttons[title]
        if phoneTab.exists { return phoneTab }
        // iPad presents the native tabs above the content as ordinary buttons.
        return app.buttons.matching(identifier: title).firstMatch
    }

    private func capture(_ screen: String, appearance: String, largestText: Bool) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(screen)-es-\(appearance.lowercased())\(largestText ? "-accessibility" : "")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func relaunchPreservingData() {
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-ui-testing" }
        app.launch()
        XCTAssertTrue(app.buttons["today.openChat"].waitForExistence(timeout: 10))
    }
    private func fill(_ identifier: String, with text: String) {
        let field = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing accessibility identifier: \(identifier)")
        reveal(field)
        // Numeric fields align text to the trailing edge. A center tap can place
        // the caret before the value, where backspace cannot clear it.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let value = field.value as? String ?? ""
        if value != field.placeholderValue && !value.isEmpty {
            field.doubleTap()
            let selectAll = app.menuItems["Select All"]
            if selectAll.exists { selectAll.tap() }
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        let cleared = field.value as? String ?? ""
        if !cleared.isEmpty && cleared != field.placeholderValue {
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
            print("Replacement diagnostic: \(field.debugDescription)")
        }
        XCTAssertTrue(cleared.isEmpty || cleared == field.placeholderValue, "The editor must be empty before replacement; actual: \(cleared)")
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text)
    }
    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        reveal(element); element.tap()
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        // Editing a row near the bottom can leave a toolbar or the Today ring above the viewport.
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeDown()
        }
        XCTAssertTrue(element.isHittable)
    }
    private func assertCalories(_ expected: Double) {
        let calorie = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR label == %@", "today.energy", "Calories consumed")).firstMatch
        XCTAssertTrue(calorie.waitForExistence(timeout: 5))
        let predicate = NSPredicate { _, _ in
            let value = calorie.value as? String ?? calorie.label
            return Double(value.replacingOccurrences(of: ",", with: "")) == expected
        }
        expectation(for: predicate, evaluatedWith: calorie)
        waitForExpectations(timeout: 5)
    }
}
