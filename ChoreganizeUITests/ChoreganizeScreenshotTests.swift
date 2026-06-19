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
}
