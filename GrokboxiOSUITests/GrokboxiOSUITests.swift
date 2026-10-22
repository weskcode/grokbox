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

    /// A typed request is read into a draft, shown in the same review sheet,
    /// and saved only from there. It never approves a sender.
    func testDescribedChangeIsDraftedPreviewedAndSavedOnlyOnRequest() {
        app.tabBars.buttons["Senders"].tap()
        wait(app.navigationBars["Senders"], 20)
        wait(app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'senders'")).firstMatch, 90)
        // One sender for the whole test: rows re-sort as indexing settles.
        let summary = app.cells.element(boundBy: 1)   // the index bar is the first cell
            .descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS ' messages, '")).firstMatch
        wait(summary, 60)
        let name = String(summary.label.prefix { $0 != "," })
        let row = app.cells.containing(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
        wait(row, 10)

        func describe(_ request: String) {
            row.press(forDuration: 1.2)
            wait(app.buttons["Describe a change…"], 10)
            app.buttons["Describe a change…"].tap()
            let field = app.textFields["describeChangeField"]
            wait(field, 20)
            field.tap()
            field.typeText(request)
            app.navigationBars["Change the rule"].buttons["Draft"].tap()
        }

        describe("Trash them")
        wait(app.staticTexts["describeChangeRefusal"], 10)
        XCTAssertTrue(app.staticTexts["describeChangeRefusal"].label.contains("isn't swept yet"), "typing cannot approve a sender")
        XCTAssertFalse(app.buttons["describeChangePreview"].exists, "a refusal offers nothing to save")
        app.buttons["Cancel"].tap()

        describe("Keep them")
        wait(app.buttons["describeChangePreview"], 10)
        app.buttons["describeChangePreview"].tap()
        wait(app.staticTexts["Scope"], 20)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["saveRule"].waitForNonExistence(timeout: 10))
        row.press(forDuration: 1.2)
        wait(app.buttons["Describe a change…"], 10)
        XCTAssertFalse(app.buttons["Clear rule"].exists, "cancelling the review saves nothing")
        app.buttons["Describe a change…"].tap()
        app.buttons["Cancel"].tap()

        row.swipeLeft()
        wait(app.buttons["Always sweep"], 10)
        app.buttons["Always sweep"].tap()
        wait(app.buttons["saveRule"], 20)
        app.buttons["saveRule"].tap()
        XCTAssertTrue(app.buttons["saveRule"].waitForNonExistence(timeout: 10))

        describe("Send them to the trash")
        wait(app.staticTexts["describeChangeDraft"], 10)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'permanently'")).firstMatch.exists,
                      "a draft that moves mail to Trash says it can end in loss")
        let draft = XCTAttachment(screenshot: app.screenshot())
        draft.name = "describe-change-draft"
        draft.lifetime = .keepAlways
        add(draft)
        app.buttons["describeChangePreview"].tap()
        wait(app.buttons["saveRule"], 20)
        wait(app.staticTexts["Scope"], 20)
        let review = XCTAttachment(screenshot: app.screenshot())
        review.name = "describe-change-review"
        review.lifetime = .keepAlways
        add(review)
        app.buttons["saveRule"].tap()
        XCTAssertTrue(app.buttons["saveRule"].waitForNonExistence(timeout: 10), "saving closes the review sheet")

        describe("Send them to the trash")
        wait(app.staticTexts["describeChangeRefusal"], 10)
        XCTAssertTrue(app.staticTexts["describeChangeRefusal"].label.contains("already"), "the saved rule now trashes this sender")
        app.buttons["Cancel"].tap()
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
