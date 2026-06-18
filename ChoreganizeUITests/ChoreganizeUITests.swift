import XCTest

/// End-to-end UI coverage for the Edit-tab guided add-flow (P2). The app is launched
/// with `CHOREGANIZE_LOCAL_ONLY=1` so the Core Data stack skips CloudKit — otherwise an
/// iCloud-less simulator traps on launch (the reason the old template stubs crashed) —
/// and with the first-run onboarding tour suppressed so it doesn't block navigation.
final class ChoreganizeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches the app configured for headless UI testing.
    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CHOREGANIZE_LOCAL_ONLY"] = "1"
        app.launchEnvironment["CHOREGANIZE_UITEST_INMEMORY"] = "1"   // clean, hermetic store
        // Argument domain overrides persisted defaults: skip onboarding, pin scope.
        app.launchArguments += ["-hasSeenOnboarding", "YES", "-activeScope", "solo"]
        app.launch()
        return app
    }

    /// Switches the bottom mode switcher to the named tab. The Menu-backed switcher
    /// (#65) is a glass pill that opens a system Menu, so tap the pill, then tap the
    /// named menu item.
    @MainActor
    private func selectMode(_ app: XCUIApplication, _ title: String) {
        let collapsed = app.buttons["modeSwitcherCollapsed"]
        XCTAssertTrue(collapsed.waitForExistence(timeout: 10), "mode switcher pill should exist")
        collapsed.tap()
        // Menu items expose their label/identifier; accept either query.
        let asButton = app.buttons[title]
        if asButton.waitForExistence(timeout: 5) {
            asButton.tap()
        } else {
            let asMenuItem = app.menuItems[title]
            XCTAssertTrue(asMenuItem.waitForExistence(timeout: 5), "\(title) menu item should exist")
            asMenuItem.tap()
        }
    }

    /// Drives the day-by-day wizard end to end and confirms the chore persists into the
    /// manual Chores list — exercising lens → group → add → review → commit in the app.
    @MainActor
    func testAddFlowDayByDayPersistsChore() throws {
        let app = launchApp()
        selectMode(app, "Edit")

        // Enter the day-by-day wizard (NavigationLink carries an accessibility id).
        let lens = app.descendants(matching: .any)["addflow.lens.byDay"]
        XCTAssertTrue(lens.waitForExistence(timeout: 5), "Day-by-day lens entry should exist")
        lens.tap()

        // Pick a weekday group.
        let monday = app.buttons["Monday"]
        XCTAssertTrue(monday.waitForExistence(timeout: 5), "Weekday picker should offer Monday")
        monday.tap()

        // Add a uniquely-named chore to the group.
        let choreName = "UITest Vacuum Hallway"
        let nameField = app.textFields["addflow.choreNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "Chore name field should exist")
        nameField.tap()
        nameField.typeText(choreName)

        // Dismiss the keyboard (tap the nav-bar centre/title) so the in-form button is hittable.
        app.navigationBars.firstMatch.tap()
        app.buttons["Add chore"].tap()

        // Finish the group → review → save. ("Done" relabeled per-lens — #54; day lens here.)
        app.buttons["Day Complete"].tap()
        let reviewSave = app.buttons["Review & Save"]
        XCTAssertTrue(reviewSave.waitForExistence(timeout: 5))
        reviewSave.tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        // Back on the Edit home: open the manual Chores list and confirm it persisted.
        let choresLink = app.buttons["Chores"]
        XCTAssertTrue(choresLink.waitForExistence(timeout: 5), "Manage → Chores link should exist")
        choresLink.tap()

        XCTAssertTrue(app.staticTexts[choreName].waitForExistence(timeout: 5),
                      "Chore added via the wizard should appear in the Chores list")

        // #51: tapping the row's empty trailing area (not the name text, which is
        // leading-aligned) must still open the editor — the whole row is the tap target.
        // The whole row is a single full-width Button. Tap it ~0.85 across — well right of
        // the leading name text — to prove the off-text area opens the editor (#51).
        let rowButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", choreName)).firstMatch
        XCTAssertTrue(rowButton.waitForExistence(timeout: 5), "Chore row button should exist")
        rowButton.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Edit Chore"].waitForExistence(timeout: 5),
                      "Tapping the row off the name text should open the editor (#51)")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchEnvironment["CHOREGANIZE_LOCAL_ONLY"] = "1"
            app.launchArguments += ["-hasSeenOnboarding", "YES"]
            app.launch()
        }
    }
}
