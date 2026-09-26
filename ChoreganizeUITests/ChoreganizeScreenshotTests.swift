import XCTest

/// Captures App Store marketing screenshots across the app's primary surfaces.
///
/// Driven by the `deploy public` skill. The app is launched with the demo seed
/// (`CHOREGANIZE_LOCAL_ONLY=1` + `CHOREGANIZE_UITEST_INMEMORY=1` for a clean,
/// hermetic in-memory store, plus `CHOREGANIZE_SEED_JSON` pointing at the skill's
/// tracked `demo-data.json`) and the first-run onboarding tour suppressed. The test
/// walks Work → Calendar → Edit → Hub → scope menu, saving each frame as a kept
/// attachment.
///
/// Extract the PNGs from the result bundle with:
///   xcrun xcresulttool export attachments \
///     --path <result.xcresult> --output-path <dir>
/// (the manifest.json maps each file back to its `suggestedHumanReadableName`).
///
/// Run only this test, per device, e.g.:
///   xcodebuild test -scheme Choreganize -configuration Debug \
///     -destination "id=<sim-udid>" -derivedDataPath /tmp/choreg-deploy-dd \
///     -only-testing:ChoreganizeUITests/ChoreganizeScreenshotTests \
///     -resultBundlePath /tmp/cz_shots_<device>.xcresult
final class ChoreganizeScreenshotTests: XCTestCase {

    /// The deploy skill's tracked, date-relative demo dataset. Overridable via the
    /// `CHOREGANIZE_SEED_JSON` env var if the runner forwards one.
    private static let defaultSeedPath =
        "/Users/spencervankeuren/XcodeRepo/.claude/skills/deploy/demo-data.json"

    override func setUpWithError() throws {
        // Keep capturing the remaining surfaces even if one navigation step drifts —
        // a partial set of shots is far more useful than aborting on the first miss.
        continueAfterFailure = true
    }

    @MainActor
    private func launchSeeded() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CHOREGANIZE_LOCAL_ONLY"] = "1"
        app.launchEnvironment["CHOREGANIZE_UITEST_INMEMORY"] = "1"
        let seed = ProcessInfo.processInfo.environment["CHOREGANIZE_SEED_JSON"]
            ?? Self.defaultSeedPath
        app.launchEnvironment["CHOREGANIZE_SEED_JSON"] = seed
        // Argument domain overrides persisted defaults: skip onboarding, pin scope.
        app.launchArguments += ["-hasSeenOnboarding", "YES", "-activeScope", "solo"]
        app.launch()
        return app
    }

    /// A fixed pause to let SwiftUI view-switch / morph animations settle before a shot.
    /// Implemented as an intentionally-unfulfilled wait (returns `.timedOut`, ignored).
    @MainActor
    private func settle(_ seconds: TimeInterval = 1.0) {
        _ = XCTWaiter.wait(for: [expectation(description: "settle")], timeout: seconds)
    }

    /// Save the current screen as a kept attachment named for the surface.
    @MainActor
    private func snap(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let att = XCTAttachment(screenshot: shot)
        att.name = name
        att.lifetime = .keepAlways
        add(att)
    }

    /// Drive the floating morph switcher to the named mode (Work / Edit / Calendar):
    /// tap the collapsed pill to expand the bar, then tap the named segment.
    @MainActor
    private func selectMode(_ app: XCUIApplication, _ title: String) {
        let pill = app.buttons["modeSwitcherCollapsed"]
        XCTAssertTrue(pill.waitForExistence(timeout: 10), "mode switcher pill should exist")
        pill.tap()
        let segment = app.buttons[title]
        if segment.waitForExistence(timeout: 5) {
            segment.tap()
        } else {
            // Menu-style fallback (if the DEBUG switcher style is flipped).
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) segment should exist")
            item.tap()
        }
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        let app = launchSeeded()

        // Wait for the seed to land — each Work row carries a completion toggle.
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30),
                      "seeded Work rows should render")
        settle()

        // 1. Work — today's checklist.
        snap("1-work")

        // 2. Calendar — month grid with completion badges.
        selectMode(app, "Calendar")
        settle()
        snap("2-calendar")

        // 3. Edit — guided add-flow lenses + manage list.
        selectMode(app, "Edit")
        settle()
        snap("3-edit")

        // 4. Hub — settings + support sheet.
        let hub = app.buttons["Hub"]
        XCTAssertTrue(hub.waitForExistence(timeout: 5), "Hub toolbar button should exist")
        hub.tap()
        _ = app.navigationBars["Hub"].waitForExistence(timeout: 5)
        settle()
        snap("4-hub")
        let done = app.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }
        settle()

        // 5. Scope menu — Solo/Household switch open.
        var scope = app.buttons["Personal"]
        if !scope.waitForExistence(timeout: 5) {
            scope = app.buttons
                .matching(NSPredicate(format: "label CONTAINS[c] %@", "Personal"))
                .firstMatch
        }
        if scope.waitForExistence(timeout: 5) {
            scope.tap()
            settle()
            snap("5-scope")
        }
    }

    /// Focused capture of the #57 calendar redesign: the month grid (discrete
    /// fill/outline status bars + tinted "today"), a past-day detail (with the new
    /// "Log a completion" affordance), and the retroactive log sheet.
    @MainActor
    func testCaptureCalendarRedesign() throws {
        let app = launchSeeded()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30),
                      "seeded Work rows should render")
        settle()

        // 1. The redesigned month grid.
        selectMode(app, "Calendar")
        settle()
        snap("cal-1-grid")

        // 2. A recent past day's detail (June 16 — a Tuesday carrying completions).
        var day = app.buttons["calendar-day-16"]
        if !day.waitForExistence(timeout: 5) {
            day = app.descendants(matching: .any)["calendar-day-16"]
        }
        guard day.waitForExistence(timeout: 3) else { return }   // grid shot already saved
        day.tap()
        settle()
        snap("cal-2-pastday")

        // 3. The retroactive log-completion sheet.
        let logButton = app.buttons["logCompletionButton"]
        if logButton.waitForExistence(timeout: 5) {
            logButton.tap()
            settle()
            snap("cal-3-logsheet")
        }
    }

    /// Captures the fully-completed-past-day glow bar (#57). Uses a dedicated seed
    /// (`/tmp/cz_glow_seed.json`) with two 100% past days, since the standard demo set
    /// has none. A still can't show the pulse — pair with a screen recording for that.
    @MainActor
    func testCaptureCalendarGlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["CHOREGANIZE_LOCAL_ONLY"] = "1"
        app.launchEnvironment["CHOREGANIZE_UITEST_INMEMORY"] = "1"
        app.launchEnvironment["CHOREGANIZE_SEED_JSON"] = "/tmp/cz_glow_seed.json"
        app.launchArguments += ["-hasSeenOnboarding", "YES", "-activeScope", "solo"]
        app.launch()

        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30),
                      "seeded Work rows should render")
        settle()
        selectMode(app, "Calendar")
        settle(2.5)   // let the glow pulse reach a bright phase before the still
        snap("cal-glow-grid")
        settle(6)     // dwell so a concurrent screen recording captures several pulses
    }

    /// Captures the Backup & Restore screen (#63): Hub → Data → Backup & Restore.
    @MainActor
    func testCaptureBackupRestore() throws {
        let app = launchSeeded()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30),
                      "seeded rows should render")
        settle()

        let hub = app.buttons["Hub"]
        XCTAssertTrue(hub.waitForExistence(timeout: 5), "Hub toolbar button should exist")
        hub.tap()
        _ = app.navigationBars["Hub"].waitForExistence(timeout: 5)
        settle()

        let row = app.buttons["Backup & Restore"]
        if row.waitForExistence(timeout: 5) {
            row.tap()
        } else {
            app.staticTexts["Backup & Restore"].firstMatch.tap()
        }
        _ = app.navigationBars["Backup & Restore"].waitForExistence(timeout: 5)
        settle()
        snap("backup-restore")
    }

    /// v1.6.0 "Free Foundation" wave — focused captures of the new IN-APP surfaces:
    /// DayPage "Mark all done" (CG-08/#91), the Hub streak readout (CG-10/#93), and the
    /// editable add-flow Review step + its inline draft editor (CG-09/#92).
    /// NOTE: widgets (CG-02/04/05), the reminder "Mark done" action (CG-03), and the sync
    /// status banner (CG-06/07) are device/OS surfaces that don't render under the
    /// local-only simulator seed — verify those on device.
    @MainActor
    func testCaptureV160Features() throws {
        let app = launchSeeded()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30),
                      "seeded Work rows should render")
        settle()

        // 1. DayPage "Mark all done" (CG-08) — scroll the Work list to reveal the button.
        let markAll = app.buttons["markAllDoneButton"]
        for _ in 0..<5 where !markAll.isHittable { app.swipeUp(); settle(0.2) }
        if markAll.waitForExistence(timeout: 3) {
            settle(0.4)
            snap("v160-1-markalldone")
        }

        // 2. Hub streak readout (CG-10) — open Hub, scroll to the Streaks section.
        let hub = app.buttons["Hub"]
        if hub.waitForExistence(timeout: 5) {
            hub.tap()
            _ = app.navigationBars["Hub"].waitForExistence(timeout: 5)
            settle()
            let streak = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Current streak")).firstMatch
            for _ in 0..<6 where !streak.isHittable { app.swipeUp(); settle(0.2) }
            settle(0.4)
            snap("v160-2-streaks")
            // Dismiss the Hub sheet (scope to the Hub nav bar — a bare "Done" is ambiguous).
            let done = app.navigationBars["Hub"].buttons["Done"]
            if done.waitForExistence(timeout: 3) { done.tap() } else { app.swipeDown(velocity: .fast) }
            _ = app.navigationBars["Hub"].waitForNonExistence(timeout: 5)
            settle()
        }

        // 3. Editable Review step + inline editor (CG-09) — drive the day-lens add flow:
        //    lens → "Every day" → type a chore → "Day Complete" → "Add & Finish"
        //    (the unadded-chore confirmation) → "Review & Save" → Review.
        selectMode(app, "Edit")
        settle()
        var lens = app.buttons["addflow.lens.byDay"]
        if !lens.exists { lens = app.descendants(matching: .any)["addflow.lens.byDay"] }
        guard lens.waitForExistence(timeout: 5) else { return }
        lens.tap()
        settle()
        let everyDay = app.buttons["Every day"]
        guard everyDay.waitForExistence(timeout: 5) else { return }
        everyDay.tap(); settle()
        let nameField = app.textFields["addflow.choreNameField"]
        guard nameField.waitForExistence(timeout: 5) else { return }
        nameField.tap(); nameField.typeText("Wipe counters")
        // Finish the group; the "unadded chore" confirmation surfaces "Add & Finish".
        let dayComplete = app.buttons["Day Complete"]
        guard dayComplete.waitForExistence(timeout: 5) else { return }
        dayComplete.tap(); settle()
        let addFinish = app.buttons["Add & Finish"]
        if addFinish.waitForExistence(timeout: 5) { addFinish.tap(); settle() }
        // .another step ("Nice work") → Review.
        let review = app.buttons["Review & Save"]
        guard review.waitForExistence(timeout: 5) else { return }
        review.tap()
        _ = app.navigationBars["Review"].waitForExistence(timeout: 5)
        settle()
        snap("v160-3-review")
        // Tap the staged draft to open the inline editor sheet (navTitle "Edit Chore").
        let row = app.buttons
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Wipe counters")).firstMatch
        if row.waitForExistence(timeout: 3) {
            row.tap()
            _ = app.navigationBars["Edit Chore"].waitForExistence(timeout: 5)
            settle()
            snap("v160-4-review-editor")
        }
    }

    // MARK: - Room vision (#105, #107)

    /// Local room photos for the on-device-model captures (never committed); override
    /// with `CHOREGANIZE_ROOM_PHOTO`. The captures skip when the photo isn't there.
    private static let roomPhotoDir = "/Users/spencervankeuren/XcodeRepo/.claude-work/fm-eval/photos"

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        return button.exists ? button : app.descendants(matching: .any)[identifier]
    }

    /// Snap a Room (#105) end to end with the real on-device model — needs a simulator
    /// on a Mac with Apple Intelligence. The DEBUG `CHOREGANIZE_ROOM_PHOTO` hook stands
    /// in for the camera/picker. Captures the entry row, the capture screen, streaming
    /// analysis and the review, then saves and checks a suggestion landed in Chores.
    @MainActor
    func testCaptureSnapARoom() throws {
        let photo = ProcessInfo.processInfo.environment["CHOREGANIZE_ROOM_PHOTO"]
            ?? "\(Self.roomPhotoDir)/kitchen-c-2.jpg"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: photo), "no room photo at \(photo)")

        // 1. Entry row + capture screen (no photo hook on this launch).
        var app = launchSeeded()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30), "seeded Work rows should render")
        selectMode(app, "Edit")
        let entry = element(app, "addflow.snapRoom")
        try XCTSkipUnless(entry.waitForExistence(timeout: 10), "Snap a Room isn't offered (no Apple Intelligence?)")
        settle()
        snap("snap-0-edit")
        entry.tap()
        XCTAssertTrue(element(app, "roomvision.choosePhoto").waitForExistence(timeout: 5), "capture step should show")
        settle(0.5)
        snap("snap-1-capture")
        app.terminate()

        // 2. Same path with the photo hook: analysis starts on its own.
        app = XCUIApplication()
        app.launchEnvironment["CHOREGANIZE_LOCAL_ONLY"] = "1"
        app.launchEnvironment["CHOREGANIZE_UITEST_INMEMORY"] = "1"
        app.launchEnvironment["CHOREGANIZE_SEED_JSON"] = ProcessInfo.processInfo.environment["CHOREGANIZE_SEED_JSON"]
            ?? Self.defaultSeedPath
        app.launchEnvironment["CHOREGANIZE_ROOM_PHOTO"] = photo
        app.launchArguments += ["-hasSeenOnboarding", "YES", "-activeScope", "solo"]
        app.launch()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 30), "seeded Work rows should render")
        selectMode(app, "Edit")
        let entry2 = element(app, "addflow.snapRoom")
        XCTAssertTrue(entry2.waitForExistence(timeout: 10))
        entry2.tap()
        settle(1.2)
        snap("snap-2-analyzing")

        let add = element(app, "roomsnap.add")
        XCTAssertTrue(add.waitForExistence(timeout: 90), "suggestions should arrive")
        settle()
        snap("snap-3-review")

        // The first kept suggestion's name (row label = "Name, schedule").
        let first = element(app, "roomsnap.suggestion.0")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        let name = first.label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        XCTAssertFalse(name.isEmpty, "a suggestion should have a name")
        add.tap()

        // Back on Edit: the saved chore shows up in Chores.
        let chores = app.buttons["Chores"]
        XCTAssertTrue(chores.waitForExistence(timeout: 10), "should return to the Edit tab")
        chores.tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 10), "saved suggestion \"\(name)\" should be listed")
        settle(0.5)
        snap("snap-4-saved")
    }
}
