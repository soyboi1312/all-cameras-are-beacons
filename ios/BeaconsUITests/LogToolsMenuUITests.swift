import XCTest

/// The Log's tools menu while the feed streams (LogToolsMenu in DetectionsView.swift).
final class LogToolsMenuUITests: XCTestCase {

    /// User report 2026-10-12: with a board streaming, Log tools > Category folded shut on every
    /// refresh, because SwiftUI rebuilt its toolbar Menu on each update. FAILS on that SwiftUI
    /// Menu (the submenu folds when the sample feed starts) and passes on LogToolsMenuButton.
    /// The DEBUG `-demoStream` feed starts 10 s after launch and publishes every 0.5 s, so the
    /// 16 s wait spans many publishes.
    func testCategorySubmenuStaysOpenWhileTheFeedStreams() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-demoStream", "-tab", "2"]
        app.launch()

        let tools = app.buttons["Log tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 15))
        tools.tap()
        let category = app.buttons["Category"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        let all = app.buttons["All Categories"]
        XCTAssertTrue(all.waitForExistence(timeout: 5), "the Category submenu opened")

        sleep(16)
        XCTAssertTrue(all.exists, "the Category submenu is still open after the feed started")
        // VoiceOver reads each category by its spoken name (detectionCategories `spoken`), which
        // the SwiftUI Menu never passed through.
        XCTAssertTrue(app.buttons["automatic license plate readers"].exists)
    }
}
