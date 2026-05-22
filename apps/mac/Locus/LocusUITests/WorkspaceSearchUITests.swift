import XCTest

final class WorkspaceSearchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCommandFFocusesWorkspaceSearchField() throws {
        let app = try launchAppWithBasicWorkspace()

        let searchField = app.textFields["workspace-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)

        app.typeKey("f", modifierFlags: [.command])

        XCTAssertTrue(searchField.waitForKeyboardFocus(timeout: 2))
    }

    @MainActor
    func testDoubleClickDirectoryRowNavigatesIntoFolder() throws {
        let app = try launchAppWithBasicWorkspace()

        let reportsRowText = app.staticTexts["Reports"]
        XCTAssertTrue(reportsRowText.waitForExistence(timeout: 5), app.debugDescription)

        reportsRowText.doubleClick()

        XCTAssertTrue(app.staticTexts["report-2026-01.md"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func launchAppWithBasicWorkspace() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchArguments = [
            "--ui-test-workspace",
            try fixtureWorkspacePath("basic")
        ]
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), app.debugDescription)

        guard app.windows.firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "Locus launched but its window is not visible to XCUITest. Grant Accessibility access to the UI test runner and rerun this test."
            )
        }

        return app
    }

    private func fixtureWorkspacePath(_ name: String, filePath: String = #filePath) throws -> String {
        var directory = URL(filePath: filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while !directory.path(percentEncoded: false).isEmpty, directory.path(percentEncoded: false) != "/" {
            let candidate = directory.appending(path: "fixtures/workspaces/\(name)", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path(percentEncoded: false), isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.path(percentEncoded: false)
            }

            directory.deleteLastPathComponent()
        }

        throw FixtureLookupError(name: name, startPath: filePath)
    }
}

private struct FixtureLookupError: Error, CustomStringConvertible {
    let name: String
    let startPath: String

    var description: String {
        "Fixture workspace '\(name)' was not found from \(startPath)."
    }
}

private extension XCUIElement {
    @MainActor
    func waitForKeyboardFocus(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
