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

    /// A rule choice shows what it would do first, and writes nothing until Save.
    func testRuleChoiceIsPreviewedAndSavedOnlyOnRequest() {
        app.tabBars.buttons["Senders"].tap()
        wait(app.navigationBars["Senders"], 20)
        let row = app.cells.element(boundBy: 1)   // the index bar is the first cell
        wait(row, 60)

        row.swipeLeft()
        wait(app.buttons["Always sweep"], 10)
        app.buttons["Always sweep"].tap()
        wait(app.navigationBars["Always sweep"], 20)
        wait(app.staticTexts["Scope"], 20)
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "rule-preview-sheet"
        sheet.lifetime = .keepAlways
        add(sheet)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Always sweep"].waitForNonExistence(timeout: 10), "cancel closes the sheet")

        row.press(forDuration: 1.2)
        wait(app.buttons["Follow my policy"], 10)
        XCTAssertFalse(app.buttons["Clear rule"].exists, "cancelling the preview saves nothing")
        app.buttons["Follow my policy"].tap()
        wait(app.navigationBars["Follow my policy"], 20)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Follow my policy"].waitForNonExistence(timeout: 10))

        row.swipeLeft()
        wait(app.buttons["Always sweep"], 10)
        app.buttons["Always sweep"].tap()
        wait(app.buttons["saveRule"], 20)
        app.buttons["saveRule"].tap()
        wait(row, 10)
        XCTAssertTrue(app.buttons["saveRule"].waitForNonExistence(timeout: 10), "saving closes the sheet")

        row.press(forDuration: 1.2)
        wait(app.buttons["Clear rule"], 10)
    }

    private func scrollTo(_ predicate: String, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.staticTexts.matching(NSPredicate(format: predicate)).firstMatch
        for _ in 0..<10 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.exists, "missing: \(predicate)", file: file, line: line)
    }

    /// After a sweep, the sender's detail shows the last sweep's outcome and says it is not a history.
    func testSenderDetailShowsTheLastSweepOutcome() {
        app.tabBars.buttons["Sweep"].tap()
        wait(app.navigationBars["Sweep"], 20)
        let apply = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archive'")).firstMatch
        // Larger text pushes the button below the fold of a lazy list.
        for _ in 0..<8 where !apply.waitForExistence(timeout: 20) { app.swipeUp() }
        wait(apply, 10)
        apply.tap()
        let running = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Applying' OR label CONTAINS[c] 'Connecting'")).firstMatch
        _ = running.waitForExistence(timeout: 5)
        XCTAssertTrue(running.waitForNonExistence(timeout: 120), "the sweep finishes")

        app.tabBars.buttons["Senders"].tap()
        wait(app.navigationBars["Senders"], 20)
        // Rules and the sweep report are not per account, so a sender indexed in several demo
        // accounts shows no tally. Walk the list until a sender with a single account.
        var shown = false
        for index in 1...15 where !shown {
            let row = app.cells.element(boundBy: index)
            guard row.waitForExistence(timeout: 10) else { break }
            row.tap()
            scrollTo("label == 'Last sweep since Grokbox opened'")
            scrollTo("label BEGINSWITH 'Only the last sweep'")
            let shared = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This sender is in more than one account'")).firstMatch
            if shared.exists {
                app.navigationBars.buttons.element(boundBy: 0).tap()
                continue
            }
            shown = true
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "sender-detail-last-sweep"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(shown, "some sender is in a single account")
    }

    /// A sender opens to the evidence behind its recommendation, and the list says what the index covers.
    func testSenderDetailShowsEvidenceAndIndexCoverage() {
        app.tabBars.buttons["Senders"].tap()
        wait(app.navigationBars["Senders"], 20)
        let row = app.cells.element(boundBy: 1)   // the index bar is the first cell
        wait(row, 60)
        wait(app.staticTexts["indexCoverageLine"], 30)
        XCTAssertTrue(app.staticTexts["indexCoverageLine"].label.hasPrefix("Index covers"))
        let list = XCTAttachment(screenshot: app.screenshot())
        list.name = "senders-coverage"
        list.lifetime = .keepAlways
        add(list)

        row.tap()
        wait(app.staticTexts.matching(NSPredicate(format: "label ==[c] 'In the index'")).firstMatch, 30)
        let top = XCTAttachment(screenshot: app.screenshot())
        top.name = "sender-detail-top"
        top.lifetime = .keepAlways
        add(top)
        scrollTo("label ==[c] 'If you sweep now'")
        scrollTo("label BEGINSWITH 'Moves' OR label BEGINSWITH 'Nothing' OR label BEGINSWITH 'Your rule' OR label BEGINSWITH 'No sweep'")
        scrollTo("label ==[c] 'Rule scope'")
        scrollTo("label CONTAINS 'applies to this address in every account'")
        let detail = XCTAttachment(screenshot: app.screenshot())
        detail.name = "sender-detail-bottom"
        detail.lifetime = .keepAlways
        add(detail)
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
