import AppKit
import XCTest

final class DocumentFindUITests: XCTestCase {
  private var filesToRemove: Set<String> = []
  private var userDefaultsKeysToRemove: Set<String> = []

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
    filesToRemove.removeAll()
    userDefaultsKeysToRemove.removeAll()
    try super.tearDownWithError()
  }

  @MainActor
  func testDocumentFindBarNavigatesAndReturnsTypingToDocument() throws {
    let workspace = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let app = try launchApp(workspacePath: workspace.path(percentEncoded: false))

    let projectBriefRow = workspaceSidebarLabel(named: "Project Brief.md", in: app)
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.click()

    let editor = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
    editor.click()

    app.typeKey("f", modifierFlags: [.command])
    let field = app.textFields["document-find-field"]
    XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
    app.typeText("local")

    let count = app.staticTexts["document-find-count"]
    XCTAssertTrue(count.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(count.label, "1/2")

    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
    XCTAssertTrue(waitForFindCount("2/2", in: app, timeout: 5), app.debugDescription)

    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
    XCTAssertTrue(field.waitForNonExistence(timeout: 5), app.debugDescription)

    app.typeText("LOCAL")
    XCTAssertTrue(
      waitForEditorContentsContaining("LOCAL", in: app, timeout: 5), app.debugDescription)
  }

  @MainActor
  private func launchApp(
    workspacePath: String,
    recentFilesKey: String = "recentFiles.documentFind.\(UUID().uuidString)",
    recentFoldersKey: String = "recentFolders.documentFind.\(UUID().uuidString)"
  ) throws -> XCUIApplication {
    trackUserDefaultsKeys(
      recentFilesKey,
      recentFoldersKey,
      "workspace.sidebar.recentFoldersExpanded",
      "workspace.textEditing.autoSaveEnabled"
    )
    let app = XCUIApplication()
    app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
    app.launchArguments = [
      "--ui-test-recent-files-key",
      recentFilesKey,
      "--ui-test-recent-folders-key",
      recentFoldersKey,
      "--ui-test-workspace",
      workspacePath,
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

  private func trackUserDefaultsKeys(_ keys: String...) {
    let appDefaults = UserDefaults(suiteName: "com.nash.locus")
    for key in keys {
      userDefaultsKeysToRemove.insert(key)
      UserDefaults.standard.removeObject(forKey: key)
      appDefaults?.removeObject(forKey: key)
    }
  }

  private func temporaryWorkspaceCopy(ofFixtureNamed name: String) throws -> URL {
    let source = URL(filePath: try fixtureWorkspacePath(name), directoryHint: .isDirectory)
    let destination = FileManager.default.temporaryDirectory
      .appending(path: "locus-document-find-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: destination)
    filesToRemove.insert(destination.path(percentEncoded: false))
    return destination
  }

  private func fixtureWorkspacePath(_ name: String, filePath: String = #filePath) throws -> String {
    var directory = URL(filePath: filePath).deletingLastPathComponent()
    let fileManager = FileManager.default
    while !directory.path(percentEncoded: false).isEmpty,
      directory.path(percentEncoded: false) != "/"
    {
      let candidate = directory.appending(
        path: "fixtures/workspaces/\(name)",
        directoryHint: .isDirectory)
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(
        atPath: candidate.path(percentEncoded: false),
        isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return candidate.path(percentEncoded: false)
      }
      directory.deleteLastPathComponent()
    }
    throw XCTSkip("Could not find fixture workspace \(name)")
  }

  @MainActor
  private func workspaceSidebarLabel(named name: String, in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(identifier: name).firstMatch
  }

  @MainActor
  private func waitForFindCount(
    _ expected: String,
    in app: XCUIApplication,
    timeout: TimeInterval
  ) -> Bool {
    let count = app.staticTexts["document-find-count"]
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if count.exists, count.label == expected {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return false
  }

  @MainActor
  private func waitForEditorContentsContaining(
    _ expected: String,
    in app: XCUIApplication,
    timeout: TimeInterval
  ) -> Bool {
    let editor = app.textViews["document-large-text-viewer"]
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      NSPasteboard.general.clearContents()
      editor.click()
      app.typeKey("a", modifierFlags: [.command])
      app.typeKey("c", modifierFlags: [.command])
      if NSPasteboard.general.string(forType: .string)?.contains(expected) == true {
        return true
      }
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return false
  }
}
