import XCTest

/// Drives the phone app the way a thumb would: tabs, a swipe to Done, a
/// swipe to Later, an Undo, a search. Runs against the built-in demo
/// mailboxes, so it needs no account and touches no real mail.
final class GrokboxiOSUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--reset", "--demo", "--stub-model", "--run-all", "--section", "brief"]
        app.launch()
    }

    private func wait(_ element: XCUIElement, _ seconds: TimeInterval = 90, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: seconds), "missing: \(element)", file: file, line: line)
    }

    private func keepScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testBriefShowsRankedRowsAfterDemoRun() {
        // --run-all indexes and reads three mailboxes with the on-device model; give it time.
        wait(app.staticTexts["Now · start here, three things, then stop"].firstMatch)
        let firstRow = app.cells.element(boundBy: 2)   // header cells come first
        wait(firstRow, 120)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'in thread' OR label CONTAINS[c] 'Overdue' OR label CONTAINS[c] 'Reply' OR label CONTAINS[c] 'Review'")).firstMatch.waitForExistence(timeout: 30))
    }

    func testTabsAllOpen() {
        wait(app.tabBars.buttons["Senders"])
        for tab in ["Senders", "Sweep", "Activity", "Settings", "Brief"] {
            app.tabBars.buttons[tab].tap()
            wait(app.navigationBars[tab], 20)
        }
    }

    func testSwipeDoneArchivesAndUndoRestores() {
        wait(app.staticTexts["Now · start here, three things, then stop"].firstMatch)
        let sendersReady = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Overdue' OR label CONTAINS[c] 'Reply' OR label CONTAINS[c] 'Review' OR label CONTAINS[c] 'due'")).firstMatch
        wait(sendersReady, 120)

        let row = app.descendants(matching: .any).matching(identifier: "briefRow").firstMatch
        wait(row, 30)
        let sender = row.label
        row.swipeLeft()
        wait(app.buttons["Done"], 10)
        app.buttons["Done"].tap()

        app.tabBars.buttons["Activity"].tap()
        wait(app.navigationBars["Activity"], 20)
        let archived = app.descendants(matching: .any).matching(identifier: "activityRow").firstMatch
        wait(archived, 20)
        archived.swipeLeft()
        wait(app.buttons["Undo"], 10)
        app.buttons["Undo"].tap()
        wait(app.descendants(matching: .any).matching(identifier: "activityRowUndone").firstMatch, 30)
        XCTAssertFalse(sender.isEmpty)
    }

    func testSendersSearchFilters() {
        app.tabBars.buttons["Senders"].tap()
        wait(app.navigationBars["Senders"], 20)
        wait(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'senders'")).firstMatch, 60)
        let search = app.searchFields.firstMatch
        wait(search, 10)
        search.tap()
        search.typeText("Swift")
        wait(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Swift'")).firstMatch, 10)
        XCTAssertFalse(app.staticTexts["Instagram"].exists)
    }

    /// Changing the approach in Settings must change what Sweep says it will
    /// do, and what it proposes — the policy is not decoration.
    func testCleanupPolicyChangesTheSweep() {
        app.tabBars.buttons["Sweep"].tap()
        wait(app.navigationBars["Sweep"], 20)
        let gentleButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archive'")).firstMatch
        wait(gentleButton, 90)
        let gentleLabel = gentleButton.label
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Never unsubscribes'")).firstMatch.exists,
                      "the default policy states that it never unsubscribes")

        app.tabBars.buttons["Settings"].tap()
        wait(app.staticTexts["How Grokbox cleans"], 20)
        app.buttons["Thorough"].tap()

        app.tabBars.buttons["Sweep"].tap()
        wait(app.navigationBars["Sweep"], 20)
        let thoroughSummary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Unsubscribes automatically'")).firstMatch
        wait(thoroughSummary, 20)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'promotions go to the Trash'")).firstMatch.exists,
                      "Thorough trashes promotions, and says so")
        let thoroughButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archive'")).firstMatch
        wait(thoroughButton, 30)
        XCTAssertNotEqual(gentleLabel, thoroughButton.label, "a more aggressive policy proposes more mail")

        // Put it back, so the setting does not leak into other tests.
        app.tabBars.buttons["Settings"].tap()
        wait(app.buttons["Gentle"], 20)
        app.buttons["Gentle"].tap()
    }

    func testUnsubscribeThatCannotBeSentSaysSo() {
        app.tabBars.buttons["Senders"].tap()
        wait(app.navigationBars["Senders"], 20)
        let search = app.searchFields.firstMatch
        wait(search, 60)
        search.tap()
        search.typeText("Morning Digest")
        let row = app.cells.containing(NSPredicate(format: "label CONTAINS 'The Morning Digest'")).firstMatch
        wait(row, 30)
        row.press(forDuration: 1.2)
        wait(app.buttons["Unsubscribe"], 10)
        app.buttons["Unsubscribe"].tap()
        let alert = app.alerts["Unsubscribe"]
        wait(alert, 30)
        keepScreenshot("unsubscribe-not-sent")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Nothing was sent.'")).firstMatch.exists,
                      "a request that never left is reported as not sent")
        XCTAssertFalse(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS 'acknowledged'")).firstMatch.exists)
        alert.buttons["OK"].tap()
    }

    func testFailedAutomaticUnsubscribeIsNotShownAsDone() {
        app.tabBars.buttons["Settings"].tap()
        wait(app.staticTexts["How Grokbox cleans"], 20)
        app.buttons["Thorough"].tap()
        defer {
            app.tabBars.buttons["Settings"].tap()
            if app.buttons["Gentle"].waitForExistence(timeout: 20) { app.buttons["Gentle"].tap() }
        }

        app.tabBars.buttons["Sweep"].tap()
        wait(app.navigationBars["Sweep"], 20)
        wait(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Unsubscribes automatically'")).firstMatch, 30)
        let apply = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archive'")).firstMatch
        wait(apply, 90)
        apply.tap()
        wait(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Swept'")).firstMatch, 120)

        app.tabBars.buttons["Activity"].tap()
        wait(app.navigationBars["Activity"], 20)
        let notConfirmed = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'not confirmed'")).firstMatch
        wait(notConfirmed, 30)
        keepScreenshot("activity-not-confirmed")
        XCTAssertTrue(notConfirmed.label.contains("Nothing was sent."), notConfirmed.label)
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Unsubscribed from'")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Archived' OR label BEGINSWITH 'Moved'")).firstMatch.exists,
                      "the archive result is still shown")
    }

    func testSweepListsPlanAndSettingsHasNoOllama() {
        app.tabBars.buttons["Sweep"].tap()
        wait(app.navigationBars["Sweep"], 20)
        wait(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archive'")).firstMatch, 90)
        XCTAssertGreaterThan(app.switches.count, 0, "per-sender toggles")
        app.tabBars.buttons["Settings"].tap()
        wait(app.staticTexts["Apple on-device model"], 20)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Ollama'")).firstMatch.exists, "Ollama is Mac-only")
    }
}
