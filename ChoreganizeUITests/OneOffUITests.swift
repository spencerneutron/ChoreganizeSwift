import XCTest

/// CG-27 / #128 — one-offs end to end: adding one from the Quick Add sheet's
/// One-off switch, completing it (grace period, then gone), cancelling within the
/// grace period, and the 3-at-a-time limit with its buried setting. Hermetic,
/// in-memory launches; run on `CZ-Portrait`, never on the sharing rig sims.
final class OneOffUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(oneOffs: [String] = [], unlimited: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CHOREGANIZE_LOCAL_ONLY"] = "1"
        app.launchEnvironment["CHOREGANIZE_UITEST_INMEMORY"] = "1"
        if !oneOffs.isEmpty {
            app.launchEnvironment["CHOREGANIZE_SEED_ONE_OFFS"] = oneOffs.joined(separator: "|")
        }
        app.launchArguments += ["-hasSeenOnboarding", "YES", "-activeScope", "solo",
                                "-workGrouping", "none", "-oneOffPlacement", "inList",
                                "-oneOffsUnlimitedPersonal", unlimited ? "YES" : "NO"]
        app.launch()
        return app
    }

    /// The on-screen match (neighbouring day pages are mounted offscreen too).
    @MainActor
    private func onScreen(_ query: XCUIElementQuery, _ identifier: String,
                          timeout: TimeInterval = 10) -> XCUIElement? {
        guard query[identifier].firstMatch.waitForExistence(timeout: timeout) else { return nil }
        return query.matching(identifier: identifier).allElementsBoundByIndex.first { $0.isHittable }
    }

    @MainActor
    func testAddOneOffFromQuickAddSheetThenCompleteIt() throws {
        let app = launch()
        let ghost = try XCTUnwrap(onScreen(app.buttons, "quickAdd.day", timeout: 15), "empty day ghost")
        ghost.tap()

        let kind = app.segmentedControls["newItem.kind"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5), "the Work view's sheet offers Chore | One-off")
        kind.buttons["One-off"].tap()
        XCTAssertTrue(app.navigationBars["New One-off"].waitForExistence(timeout: 3))

        let field = app.textFields["oneOff.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        app.typeText("Return the library books\n")

        let check = try XCTUnwrap(onScreen(app.buttons, "oneOff.check.Return the library books"),
                                  "the one-off should lead today's list")
        check.tap()
        // Grace period (1.5 s), then the poof, then it's gone.
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.buttons["oneOff.check.Return the library books"])
        waitForExpectations(timeout: 6)
    }

    @MainActor
    func testTappingAgainWithinGraceKeepsIt() throws {
        let app = launch(oneOffs: ["Call the plumber"])
        let check = try XCTUnwrap(onScreen(app.buttons, "oneOff.check.Call the plumber"))
        check.tap()
        check.tap()   // undo inside the grace period
        _ = XCTWaiter.wait(for: [expectation(description: "past the grace period")], timeout: 3)
        XCTAssertNotNil(onScreen(app.buttons, "oneOff.check.Call the plumber", timeout: 2),
                        "a second tap within the grace period cancels completing")
    }

    @MainActor
    func testLimitRefusesAFourthUntilLifted() throws {
        let three = ["Return the library books", "Call the plumber", "Order the cake"]
        var app = launch(oneOffs: three)
        XCTAssertNotNil(onScreen(app.buttons, "oneOff.check.Order the cake"))
        XCTAssertNil(onScreen(app.buttons, "oneOff.add", timeout: 1), "no ＋ at the limit")

        // The Quick Add sheet's One-off mode explains the limit and won't save.
        let ghost = try XCTUnwrap(onScreen(app.buttons, "quickAdd.day", timeout: 5))
        ghost.tap()
        app.segmentedControls["newItem.kind"].buttons["One-off"].tap()
        XCTAssertTrue(app.staticTexts["One-offs are for a few things at a time. Finish one to add another."]
            .waitForExistence(timeout: 3))
        app.textFields["oneOff.title"].tap()
        app.typeText("Donate old clothes")
        XCTAssertFalse(app.buttons["Save"].isEnabled, "Save is off at the limit")
        app.buttons["Cancel"].tap()

        // With "Limit one-offs to 3" off, the ＋ is back and a fourth saves.
        app.terminate()
        app = launch(oneOffs: three, unlimited: true)
        let add = try XCTUnwrap(onScreen(app.buttons, "oneOff.add"), "＋ with the limit lifted")
        add.tap()
        XCTAssertTrue(app.navigationBars["New One-off"].waitForExistence(timeout: 3))
        let field = app.textFields["oneOff.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        app.typeText("Donate old clothes\n")
        // Past 3 the section collapses: 3 rows plus "Show all (4)".
        XCTAssertTrue(app.buttons["Show all (4)"].firstMatch.waitForExistence(timeout: 5), "collapses past 3")
    }
}
