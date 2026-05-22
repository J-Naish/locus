import AppKit
import XCTest

final class WorkspaceSearchUITests: XCTestCase {
    private var userDefaultsKeysToRemove: Set<String> = []
    private var filesToRemove: Set<String> = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        NSPasteboard.general.clearContents()
    }

    override func tearDownWithError() throws {
        NSPasteboard.general.clearContents()
        let appDefaults = UserDefaults(suiteName: "com.nash.locus")
        for key in userDefaultsKeysToRemove {
            UserDefaults.standard.removeObject(forKey: key)
            appDefaults?.removeObject(forKey: key)
        }
        for path in filesToRemove {
            try? FileManager.default.removeItem(atPath: path)
        }
        userDefaultsKeysToRemove.removeAll()
        filesToRemove.removeAll()
        try super.tearDownWithError()
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
    func testWorkspaceRefreshesWhenFolderContentsChange() throws {
        let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
        let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

        XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)

        try "Detected by Locus\n".write(
            to: workspaceURL.appending(path: "Added Later.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Also detected\n".write(
            to: workspaceURL.appending(path: "Added Second.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(app.staticTexts["Added Later.md"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Added Second.md"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testWorkspaceShowsErrorWhenCurrentFolderIsDeleted() throws {
        let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
        let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

        XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)

        try FileManager.default.removeItem(at: workspaceURL)
        filesToRemove.remove(workspaceURL.path(percentEncoded: false))

        XCTAssertTrue(app.staticTexts["Folder Could Not Be Opened"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testContextMenuCopiesSelectedEntryPath() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let app = try launchApp(workspacePath: workspacePath)
        let pasteboard = NSPasteboard.general

        let reportsRowText = app.staticTexts["Reports"]
        XCTAssertTrue(reportsRowText.waitForExistence(timeout: 5), app.debugDescription)

        reportsRowText.rightClick()

        let copyPathMenuItem = app.menuItems["Copy Path"]
        XCTAssertTrue(copyPathMenuItem.waitForExistence(timeout: 2), app.debugDescription)
        copyPathMenuItem.click()

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "\(workspacePath)/Reports"
        )
    }

    @MainActor
    func testContextMenuPreviewsFile() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
        let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
        let app = try launchApp(
            workspacePath: workspacePath,
            previewInvocationsKey: previewInvocationsKey,
            previewInvocationsFilePath: previewInvocationsFilePath
        )

        let projectBriefRowText = app.staticTexts["Project Brief.md"]
        XCTAssertTrue(projectBriefRowText.waitForExistence(timeout: 5), app.debugDescription)

        projectBriefRowText.rightClick()

        let previewMenuItem = app.menuItems["Preview"]
        XCTAssertTrue(previewMenuItem.waitForExistence(timeout: 2), app.debugDescription)
        previewMenuItem.click()

        XCTAssertTrue(
            waitForPreviewInvocation(
                "\(workspacePath)/Project Brief.md",
                key: previewInvocationsKey,
                filePath: previewInvocationsFilePath
            ),
            app.debugDescription
        )
    }

    @MainActor
    func testSpacePreviewsSelectedFile() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
        let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
        let app = try launchApp(
            workspacePath: workspacePath,
            previewInvocationsKey: previewInvocationsKey,
            previewInvocationsFilePath: previewInvocationsFilePath
        )

        let projectBriefRowText = app.staticTexts["Project Brief.md"]
        XCTAssertTrue(projectBriefRowText.waitForExistence(timeout: 5), app.debugDescription)
        projectBriefRowText.click()

        app.typeKey(.space, modifierFlags: [])

        XCTAssertTrue(
            waitForPreviewInvocation(
                "\(workspacePath)/Project Brief.md",
                key: previewInvocationsKey,
                filePath: previewInvocationsFilePath
            ),
            app.debugDescription
        )
    }

    @MainActor
    func testSpaceTypesIntoFocusedSearchFieldInsteadOfPreviewing() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
        let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
        let app = try launchApp(
            workspacePath: workspacePath,
            previewInvocationsKey: previewInvocationsKey,
            previewInvocationsFilePath: previewInvocationsFilePath
        )

        let projectBriefRowText = app.staticTexts["Project Brief.md"]
        XCTAssertTrue(projectBriefRowText.waitForExistence(timeout: 5), app.debugDescription)
        projectBriefRowText.click()

        let searchField = app.textFields["workspace-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.click()
        app.typeText("Project ")

        XCTAssertEqual(searchField.value as? String, "Project ")
        XCTAssertEqual(previewInvocations(forKey: previewInvocationsKey, filePath: previewInvocationsFilePath), [])
    }

    @MainActor
    func testRecentFolderOpensFromHome() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let app = try launchAppWithRecentFolder(workspacePath: workspacePath)

        XCTAssertTrue(app.staticTexts["Recent Folders"].waitForExistence(timeout: 5), app.debugDescription)

        let recentFolder = app.buttons["Open basic"]
        XCTAssertTrue(recentFolder.waitForExistence(timeout: 5), app.debugDescription)
        recentFolder.click()

        XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testRecentFileAppearsFromHome() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let recentFilePath = "\(workspacePath)/Project Brief.md"
        let app = try launchAppWithRecentFile(filePath: recentFilePath)

        XCTAssertTrue(app.staticTexts["Recent Files"].waitForExistence(timeout: 5), app.debugDescription)

        let recentFile = app.buttons.matching(identifier: "recent-file-row").firstMatch
        XCTAssertTrue(recentFile.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Open Project Brief.md"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testRecentFileCanBeRemovedFromHome() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let recentFilePath = "\(workspacePath)/Project Brief.md"
        let app = try launchAppWithRecentFile(filePath: recentFilePath)

        let recentFile = app.buttons.matching(identifier: "recent-file-row").firstMatch
        XCTAssertTrue(recentFile.waitForExistence(timeout: 5), app.debugDescription)

        recentFile.rightClick()

        let removeMenuItem = app.menuItems["Remove"]
        XCTAssertTrue(removeMenuItem.waitForExistence(timeout: 2), app.debugDescription)
        removeMenuItem.click()

        XCTAssertFalse(recentFile.waitForExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    func testHomeSearchFiltersSavedShortcuts() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let recentFilePath = "\(workspacePath)/Project Brief.md"
        let app = try launchApp(favoriteFolders: [workspacePath], recentFiles: [recentFilePath])

        XCTAssertTrue(app.staticTexts["Favorite Folders"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Recent Files"].waitForExistence(timeout: 5), app.debugDescription)

        let searchField = app.textFields["home-shortcut-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.click()
        app.typeText("brief")

        XCTAssertTrue(app.staticTexts["Recent Files"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertTrue(app.buttons["Open Project Brief.md"].waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Favorite Folders"].waitForExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    func testHomeSearchShowsEmptyStateWhenNoSavedShortcutsMatch() throws {
        let workspacePath = try fixtureWorkspacePath("basic")
        let app = try launchApp(favoriteFolders: [workspacePath])

        let searchField = app.textFields["home-shortcut-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
        searchField.click()
        app.typeText("definitely-no-match")

        let emptyState = app.descendants(matching: .any)["home-shortcut-search-empty-state"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 2), app.debugDescription)
    }

    @MainActor
    func testCurrentFolderCanBePinnedAndReopenedFromHome() throws {
        let favoriteFoldersKey = "favoriteFolders.uiTests.\(UUID().uuidString)"
        let workspacePath = try fixtureWorkspacePath("basic")
        var app = try launchApp(workspacePath: workspacePath, favoriteFoldersKey: favoriteFoldersKey)

        let favoriteButton = app.buttons["favorite-current-folder-button"]
        XCTAssertTrue(favoriteButton.waitForExistence(timeout: 5), app.debugDescription)
        favoriteButton.click()
        app.terminate()

        app = try launchApp(favoriteFoldersKey: favoriteFoldersKey)

        XCTAssertTrue(app.staticTexts["Favorite Folders"].waitForExistence(timeout: 5), app.debugDescription)

        let favoriteFolder = app.buttons.matching(identifier: "favorite-folder-row").firstMatch
        XCTAssertTrue(favoriteFolder.waitForExistence(timeout: 5), app.debugDescription)
        favoriteFolder.click()

        XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func launchAppWithBasicWorkspace() throws -> XCUIApplication {
        try launchApp(workspacePath: fixtureWorkspacePath("basic"))
    }

    @MainActor
    private func launchApp(
        workspacePath: String? = nil,
        favoriteFoldersKey: String = "favoriteFolders.uiTests.\(UUID().uuidString)",
        recentFilesKey: String = "recentFiles.uiTests.\(UUID().uuidString)",
        recentFoldersKey: String = "recentFolders.uiTests.\(UUID().uuidString)",
        previewInvocationsKey: String = "previewInvocations.uiTests.\(UUID().uuidString)",
        previewInvocationsFilePath: String? = nil,
        favoriteFolders: [String] = [],
        recentFiles: [String] = [],
        recentFolders: [String] = []
    ) throws -> XCUIApplication {
        let previewInvocationsFilePath = previewInvocationsFilePath ?? temporaryPreviewInvocationsPath()
        trackUserDefaultsKeys(favoriteFoldersKey, recentFilesKey, recentFoldersKey, previewInvocationsKey)

        let app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchArguments = [
            "--ui-test-favorite-folders-key",
            favoriteFoldersKey,
            "--ui-test-recent-files-key",
            recentFilesKey,
            "--ui-test-recent-folders-key",
            recentFoldersKey,
            "--ui-test-preview-invocations-key",
            previewInvocationsKey,
            "--ui-test-preview-invocations-file",
            previewInvocationsFilePath
        ]
        favoriteFolders.forEach {
            app.launchArguments += ["--ui-test-favorite-folder", $0]
        }
        recentFiles.forEach {
            app.launchArguments += ["--ui-test-recent-file", $0]
        }
        recentFolders.forEach {
            app.launchArguments += ["--ui-test-recent-folder", $0]
        }
        if let workspacePath {
            app.launchArguments += [
                "--ui-test-workspace",
                workspacePath
            ]
        }
        try launchAndWaitForWindow(app)
        return app
    }

    @MainActor
    private func launchAppWithRecentFolder(workspacePath: String) throws -> XCUIApplication {
        let favoriteFoldersKey = "favoriteFolders.uiTests.\(UUID().uuidString)"
        let recentFilesKey = "recentFiles.uiTests.\(UUID().uuidString)"
        let recentFoldersKey = "recentFolders.uiTests.\(UUID().uuidString)"
        let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
        let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
        trackUserDefaultsKeys(favoriteFoldersKey, recentFilesKey, recentFoldersKey, previewInvocationsKey)

        let app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchArguments = [
            "--ui-test-favorite-folders-key",
            favoriteFoldersKey,
            "--ui-test-recent-files-key",
            recentFilesKey,
            "--ui-test-recent-folders-key",
            recentFoldersKey,
            "--ui-test-recent-folder",
            workspacePath,
            "--ui-test-preview-invocations-key",
            previewInvocationsKey,
            "--ui-test-preview-invocations-file",
            previewInvocationsFilePath
        ]
        try launchAndWaitForWindow(app)
        return app
    }

    @MainActor
    private func launchAppWithRecentFile(filePath: String) throws -> XCUIApplication {
        let favoriteFoldersKey = "favoriteFolders.uiTests.\(UUID().uuidString)"
        let recentFilesKey = "recentFiles.uiTests.\(UUID().uuidString)"
        let recentFoldersKey = "recentFolders.uiTests.\(UUID().uuidString)"
        let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
        let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
        trackUserDefaultsKeys(favoriteFoldersKey, recentFilesKey, recentFoldersKey, previewInvocationsKey)

        let app = XCUIApplication()
        app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
        app.launchArguments = [
            "--ui-test-favorite-folders-key",
            favoriteFoldersKey,
            "--ui-test-recent-files-key",
            recentFilesKey,
            "--ui-test-recent-file",
            filePath,
            "--ui-test-recent-folders-key",
            recentFoldersKey,
            "--ui-test-preview-invocations-key",
            previewInvocationsKey,
            "--ui-test-preview-invocations-file",
            previewInvocationsFilePath
        ]
        try launchAndWaitForWindow(app)
        return app
    }

    @MainActor
    private func launchAndWaitForWindow(_ app: XCUIApplication) throws {
        app.launch()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), app.debugDescription)

        guard app.windows.firstMatch.waitForExistence(timeout: 5) else {
            throw XCTSkip(
                "Locus launched but its window is not visible to XCUITest. Grant Accessibility access to the UI test runner and rerun this test."
            )
        }
    }

    private func trackUserDefaultsKeys(_ keys: String...) {
        keys.forEach { userDefaultsKeysToRemove.insert($0) }
    }

    private func waitForPreviewInvocation(
        _ path: String,
        key: String,
        filePath: String,
        timeout: TimeInterval = 2
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if previewInvocations(forKey: key, filePath: filePath).contains(path) {
                return true
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        return false
    }

    private func previewInvocations(forKey key: String, filePath: String) -> [String] {
        if let fileContents = try? String(contentsOfFile: filePath, encoding: .utf8),
           !fileContents.isEmpty {
            return fileContents.components(separatedBy: "\n")
        }

        let appDefaults = UserDefaults(suiteName: "com.nash.locus")
        return appDefaults?.stringArray(forKey: key)
            ?? UserDefaults.standard.stringArray(forKey: key)
            ?? []
    }

    private func temporaryPreviewInvocationsPath() -> String {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "locus-preview-invocations-\(UUID().uuidString).txt")
            .path(percentEncoded: false)
        filesToRemove.insert(path)
        return path
    }

    private func temporaryWorkspaceCopy(ofFixtureNamed name: String) throws -> URL {
        let source = URL(filePath: try fixtureWorkspacePath(name), directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "locus-ui-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: destination)
        filesToRemove.insert(destination.path(percentEncoded: false))
        return destination
    }

    private func fixtureWorkspacePath(_ name: String, filePath: String = #filePath) throws -> String {
        var directory = URL(filePath: filePath).deletingLastPathComponent()
        let fileManager = FileManager.default

        while !directory.path(percentEncoded: false).isEmpty, directory.path(percentEncoded: false) != "/" {
            let candidate = directory.appending(path: "fixtures/workspaces/\(name)", directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path(percentEncoded: false), isDirectory: &isDirectory),
               isDirectory.boolValue {
                return directory
                    .appending(path: "fixtures/workspaces")
                    .appending(path: name)
                    .path(percentEncoded: false)
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
