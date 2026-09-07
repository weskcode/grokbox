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
