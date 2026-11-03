import XCTest

/// CG-26 / #127 — the Quick Add ghost end to end: an empty day's ghost at rest,
/// and the scroll-revealed ghost that opens New Chore prefilled with its room.
/// Hermetic, in-memory launches (`CHOREGANIZE_LOCAL_ONLY` + `_UITEST_INMEMORY`).
/// Run on `CZ-Portrait`, never on the sharing rig sims.
final class QuickAddUITests: XCTestCase {

    /// The deploy skill's demo dataset (date-relative; regenerate with its
    /// `gen-demo-data.py`). The scroll test skips when it's missing.
    private static let seedPath =
        "/Users/spencervankeuren/XcodeRepo/.claude/skills/deploy/demo-data.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(seeded: Bool, grouping: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CHOREGANIZE_LOCAL_ONLY"] = "1"
        app.launchEnvironment["CHOREGANIZE_UITEST_INMEMORY"] = "1"
        if seeded { app.launchEnvironment["CHOREGANIZE_SEED_JSON"] = Self.seedPath }
        app.launchArguments += ["-hasSeenOnboarding", "YES", "-activeScope", "solo",
                                "-workGrouping", grouping]
        app.launch()
        return app
    }

    private var ghostQuery: NSPredicate {
        NSPredicate(format: "identifier BEGINSWITH %@", "quickAdd.")
    }

    /// An empty day shows its ghost at rest; tapping it opens a focused New Chore
    /// sheet, Return saves, and the chore lands on today's page.
    @MainActor
    func testEmptyDayGhostAddsChoreWithReturn() throws {
        let app = launch(seeded: false, grouping: "none")
        let today = Date().formatted(.dateTime.weekday(.wide))

        // Every empty upcoming page shows one; take the one on screen.
        XCTAssertTrue(app.buttons["quickAdd.day"].firstMatch.waitForExistence(timeout: 15),
                      "an empty day should show the ghost at rest")
        let ghost = try XCTUnwrap(app.buttons.matching(identifier: "quickAdd.day")
            .allElementsBoundByIndex.first { $0.isHittable })
        XCTAssertTrue(ghost.label.contains("Add a chore for \(today)"), "got \(ghost.label)")
        ghost.tap()

        XCTAssertTrue(app.navigationBars["New Chore"].waitForExistence(timeout: 5))
        // The name field is focused: typing goes straight in, Return saves.
        let name = "Water the plants"
        let field = app.textFields["Name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.typeText(name + "\n")

        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5),
                      "the saved chore should appear on today's page")
        XCTAssertFalse(app.navigationBars["New Chore"].exists, "Return should save and close")
    }

    /// Scrolling reveals one ghost (the section nearest the middle); it opens New
    /// Chore with that room and today's weekday.
    @MainActor
    func testScrollGhostPrefillsRoomAndDay() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.seedPath), "demo seed missing")
        let app = launch(seeded: true, grouping: "room")
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30), "seeded rows should render")
        let today = Date().formatted(.dateTime.weekday(.wide))

        // At rest, no ghost is exposed.
        XCTAssertEqual(app.buttons.matching(ghostQuery).count, 0, "no ghost before scrolling")

        // Drag the visible page's list (the pager keeps neighbouring pages mounted
        // offscreen, so an element query could pick one of those).
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        from.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)))
        let ghosts = app.buttons.matching(ghostQuery)
        XCTAssertTrue(ghosts.firstMatch.waitForExistence(timeout: 3), "scrolling should reveal a ghost")
        XCTAssertEqual(ghosts.count, 1, "only the section nearest the middle shows a ghost")

        let ghost = ghosts.firstMatch
        let room = String(ghost.identifier.dropFirst("quickAdd.".count))
        XCTAssertEqual(ghost.label, "Add chore to \(room)")
        ghost.tap()

        XCTAssertTrue(app.navigationBars["New Chore"].waitForExistence(timeout: 5))
        let form = app.collectionViews.firstMatch
        if room != "No Room" {
            XCTAssertTrue(form.buttons.matching(NSPredicate(format: "label CONTAINS %@", room)).firstMatch.exists
                          || form.staticTexts[room].exists, "Area should be prefilled with \(room)")
        }
        XCTAssertTrue(form.buttons.matching(NSPredicate(format: "label CONTAINS %@", today)).firstMatch.exists
                      || form.staticTexts[today].exists, "Day should be prefilled with \(today)")

        let name = "Dust the shelves"
        let field = app.textFields["Name"]
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        expectation(for: focused, evaluatedWith: field)
        waitForExpectations(timeout: 5)
        app.typeText(name + "\n")

        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5),
                      "the saved chore should appear on today's page")
    }
}
