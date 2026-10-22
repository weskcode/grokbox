import XCTest

/// Fresh demo-account setup through its first inspected and ticked sender,
/// on the built-in demo mailboxes only. Setup must never move mail, so none
/// of these tests presses Archive.
final class GrokboxiOSFirstActionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--reset", "--demo", "--stub-model", "--onboard"]
        app.launch()
    }

    private func wait(_ element: XCUIElement, _ seconds: TimeInterval = 90, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: seconds), "missing: \(element)", file: file, line: line)
    }

    private func runSetupToDone() {
        wait(app.buttons["Continue"])
        app.buttons["Continue"].tap()
        wait(app.buttons["Continue"])
        app.buttons["Continue"].tap()
        wait(app.buttons["Start"])
        app.buttons["Start"].tap()
        wait(app.buttons["tickCandidate"].firstMatch, 180)
    }

    func testCardsShowEvidenceAndNothingIsTickedByDefault() {
        runSetupToDone()
        XCTAssertTrue(app.staticTexts["Places to start"].exists)
        XCTAssertLessThanOrEqual(app.buttons.matching(identifier: "tickCandidate").count, 3)
        XCTAssertTrue(app.staticTexts["Nothing has changed in your mailbox."].exists)
        XCTAssertFalse(app.buttons["reviewInSweep"].exists)
        XCTAssertTrue(app.buttons["Show me the Brief"].exists)
    }

    func testInspectTickAndReviewInSweepOpensSweepWithOnlyThatSender() {
        runSetupToDone()
        app.buttons["inspectCandidate"].firstMatch.tap()
        wait(app.staticTexts["Applying it in Sweep saves a rule for this address in every account."])

        app.buttons["tickCandidate"].firstMatch.tap()
        let review = app.buttons["reviewInSweep"]
        wait(review, 10)
        XCTAssertTrue(review.label.contains("(1)"), review.label)
        review.tap()

        wait(app.navigationBars["Sweep"], 30)
        let archive = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Archive' AND label CONTAINS 'from 1 senders'")).firstMatch
        wait(archive, 30)
    }

    func testNotNowRemovesTheCardAndTickingIsUndoable() {
        runSetupToDone()
        let before = app.buttons.matching(identifier: "skipCandidate").count
        app.buttons["tickCandidate"].firstMatch.tap()
        wait(app.buttons["reviewInSweep"], 10)
        app.buttons["tickCandidate"].firstMatch.tap()
        XCTAssertFalse(app.buttons["reviewInSweep"].exists)
        app.buttons["skipCandidate"].firstMatch.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "skipCandidate").count, before - 1)
    }
}
