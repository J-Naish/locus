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
  func testInitialWorkspaceShowsEmptyDocumentSurface() throws {
    let app = try launchAppWithBasicWorkspace()

    XCTAssertTrue(
      app.staticTexts["Project Brief.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["Select a File"].waitForExistence(timeout: 5), app.debugDescription)
  }

  @MainActor
  func testDoubleClickDirectoryRowNavigatesIntoFolder() throws {
    let app = try launchAppWithBasicWorkspace()

    let reportsRowText = app.staticTexts["Reports"]
    XCTAssertTrue(reportsRowText.waitForExistence(timeout: 5), app.debugDescription)

    reportsRowText.doubleClick()

    XCTAssertTrue(
      app.staticTexts["report-2026-01.md"].waitForExistence(timeout: 5), app.debugDescription)
  }

  @MainActor
  func testDirectorySymlinkDisclosureExpandsTargetChildren() throws {
    let workspaceURL = try makeSymlinkWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    // A symlink row is announced as an alias, so its accessibility label is
    // "<name>, alias" — match that rather than the bare name.
    XCTAssertTrue(
      workspaceSidebarLabel(named: "linked-folder, alias", in: app).waitForExistence(timeout: 5),
      app.debugDescription)

    let linkedFolderDisclosure = disclosureButton(
      for: workspaceURL.appending(path: "linked-folder"),
      in: app
    )
    XCTAssertTrue(linkedFolderDisclosure.waitForExistence(timeout: 5), app.debugDescription)
    linkedFolderDisclosure.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()

    XCTAssertTrue(
      workspaceSidebarLabel(named: "Child.md", in: app).waitForExistence(timeout: 5),
      app.debugDescription)
  }

  @MainActor
  func testFileSymlinkCanBeEditedThroughLinkPath() throws {
    let workspaceURL = try makeSymlinkWorkspace()
    let targetURL = workspaceURL.appending(path: "Target.md")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    // A symlink row is announced as an alias ("<name>, alias"); match the full label.
    let linkedFileRow = workspaceSidebarCellContainingLabel(named: "Linked.md, alias", in: app)
    XCTAssertTrue(linkedFileRow.waitForExistence(timeout: 5), app.debugDescription)
    linkedFileRow.click()

    let editor = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
    editor.click()

    let updatedText = "# Updated Via Symlink\n\nSaved through the link path.\n"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(updatedText, forType: .string)
    app.typeKey("a", modifierFlags: [.command])
    app.typeKey("v", modifierFlags: [.command])
    XCTAssertTrue(waitForEditorContents(updatedText, in: app, timeout: 5), app.debugDescription)

    app.menuBars.menuBarItems["File"].click()
    let saveMenuItem = app.menuBars.menuItems["Save"]
    XCTAssertTrue(saveMenuItem.waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(saveMenuItem.isEnabled, app.debugDescription)
    saveMenuItem.click()

    XCTAssertTrue(waitForFileContents(updatedText, at: targetURL), app.debugDescription)
  }

  @MainActor
  func testClickDirectoryRowSelectsWithoutExpanding() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 5), app.debugDescription)

    app.staticTexts["Alpha"].click()

    assertTableRow(named: "Alpha", isSelectedIn: app)
    XCTAssertFalse(
      app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 1), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 2), app.debugDescription)
  }

  @MainActor
  func testDirectoryDisclosureClickDoesNotChangeRowSelection() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 5), app.debugDescription)

    app.staticTexts["Other"].click()
    assertTableRow(named: "Other", isSelectedIn: app)

    disclosureButton(for: workspaceURL.appending(path: "Alpha"), in: app).click()

    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 5), app.debugDescription)
    assertTableRow(named: "Other", isSelectedIn: app)
  }

  @MainActor
  func testClickDirectoryDisclosureExpandsAndCollapsesFolderWithoutNavigating() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 5), app.debugDescription)

    let alphaDisclosure = disclosureButton(for: workspaceURL.appending(path: "Alpha"), in: app)
    XCTAssertTrue(alphaDisclosure.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(alphaDisclosure.label, "Expand Alpha")
    alphaDisclosure.click()

    XCTAssertTrue(
      app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(alphaDisclosure.label, "Collapse Alpha")

    alphaDisclosure.click()

    XCTAssertFalse(
      app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 1), app.debugDescription)
    XCTAssertFalse(app.staticTexts["Beta"].exists, app.debugDescription)
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(alphaDisclosure.label, "Expand Alpha")
  }

  @MainActor
  func testNestedDirectoryDisclosuresExpandAndCollapseIndependently() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), app.debugDescription)

    let alphaDisclosure = disclosureButton(for: workspaceURL.appending(path: "Alpha"), in: app)
    XCTAssertTrue(alphaDisclosure.waitForExistence(timeout: 5), app.debugDescription)
    alphaDisclosure.click()
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 5), app.debugDescription)

    let betaURL = workspaceURL.appending(path: "Alpha").appending(path: "Beta")
    let betaDisclosure = disclosureButton(for: betaURL, in: app)
    XCTAssertTrue(betaDisclosure.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(betaDisclosure.label, "Expand Beta")
    betaDisclosure.click()

    XCTAssertTrue(
      app.staticTexts["Beta Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Gamma"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(betaDisclosure.label, "Collapse Beta")

    betaDisclosure.click()

    XCTAssertFalse(
      app.staticTexts["Beta Note.md"].waitForExistence(timeout: 1), app.debugDescription)
    XCTAssertFalse(app.staticTexts["Gamma"].exists, app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(betaDisclosure.label, "Expand Beta")
  }

  @MainActor
  func testDoubleClickExpandedDirectoryRowStillNavigatesIntoFolder() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), app.debugDescription)
    disclosureButton(for: workspaceURL.appending(path: "Alpha"), in: app).click()
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 5), app.debugDescription)

    app.staticTexts["Beta"].doubleClick()

    XCTAssertTrue(
      app.staticTexts["Beta Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Gamma"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertFalse(app.staticTexts["Alpha Note.md"].exists, app.debugDescription)
    XCTAssertFalse(app.staticTexts["Other"].exists, app.debugDescription)
  }

  @MainActor
  func testCommandBracketNavigatesWorkspaceFolderHistoryBackwardAndForward() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Alpha"].doubleClick()
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Beta"].doubleClick()
    XCTAssertTrue(app.staticTexts["Gamma"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Gamma"].doubleClick()
    XCTAssertTrue(
      app.staticTexts["Gamma Note.md"].waitForExistence(timeout: 5), app.debugDescription)

    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(
      app.staticTexts["Beta Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Gamma"].waitForExistence(timeout: 2), app.debugDescription)

    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(
      app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 2), app.debugDescription)

    app.typeKey("]", modifierFlags: [.command])
    XCTAssertTrue(
      app.staticTexts["Beta Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Gamma"].waitForExistence(timeout: 2), app.debugDescription)
  }

  @MainActor
  func testCommandForwardHistoryIsClearedAfterNewFolderNavigation() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Alpha"].doubleClick()
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Beta"].doubleClick()
    XCTAssertTrue(app.staticTexts["Gamma"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Gamma"].doubleClick()
    XCTAssertTrue(
      app.staticTexts["Gamma Note.md"].waitForExistence(timeout: 5), app.debugDescription)

    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(
      app.staticTexts["Beta Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(
      app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 5), app.debugDescription)

    app.staticTexts["Other"].doubleClick()
    XCTAssertTrue(
      app.staticTexts["Other Note.md"].waitForExistence(timeout: 5), app.debugDescription)

    app.typeKey("]", modifierFlags: [.command])
    XCTAssertTrue(
      app.staticTexts["Other Note.md"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertFalse(app.staticTexts["Alpha Note.md"].exists)
  }

  @MainActor
  func testCommandBracketDoesNotNavigateWhileTextEditorIsFocused() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Alpha"].doubleClick()
    XCTAssertTrue(
      app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Alpha Note.md"].click()

    let editor = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
    editor.click()
    editor.typeText("Draft ")

    app.typeKey("[", modifierFlags: [.command])

    XCTAssertTrue(
      app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertFalse(app.staticTexts["Other"].exists)
  }

  @MainActor
  func testWorkspaceFileListDoesNotShowMetadataColumns() throws {
    let app = try launchAppWithBasicWorkspace()

    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(app.staticTexts["Name"].exists)
    XCTAssertFalse(app.buttons["Name"].exists)
    XCTAssertFalse(app.staticTexts["Type"].exists)
    XCTAssertFalse(app.buttons["Type"].exists)
    XCTAssertFalse(app.staticTexts["Size"].exists)
    XCTAssertFalse(app.buttons["Size"].exists)
    XCTAssertFalse(app.staticTexts["Modified"].exists)
    XCTAssertFalse(app.buttons["Modified"].exists)
  }

  @MainActor
  func testCommandBTogglesWorkspaceSidebar() throws {
    let app = try launchAppWithBasicWorkspace()

    XCTAssertTrue(
      workspaceSidebarLabel(named: "Reports", in: app).waitForExistence(timeout: 5),
      app.debugDescription)

    app.typeKey("b", modifierFlags: [.command])

    XCTAssertFalse(
      workspaceSidebarLabel(named: "Reports", in: app).waitForExistence(timeout: 2),
      app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["Select a File"].waitForExistence(timeout: 2), app.debugDescription)

    app.typeKey("b", modifierFlags: [.command])

    XCTAssertTrue(
      workspaceSidebarLabel(named: "Reports", in: app).waitForExistence(timeout: 5),
      app.debugDescription)
  }

  @MainActor
  func testWorkspaceRootRowIsExpandedByDefaultAndTogglesViaDisclosure() throws {
    let workspaceURL = URL(filePath: try fixtureWorkspacePath("basic"), directoryHint: .isDirectory)
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let rootDisclosure = disclosureButton(for: workspaceURL, in: app)
    XCTAssertTrue(rootDisclosure.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(rootDisclosure.label, "Collapse basic")
    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)

    rootDisclosure.click()

    XCTAssertEqual(rootDisclosure.label, "Expand basic")
    XCTAssertFalse(app.staticTexts["Reports"].waitForExistence(timeout: 1), app.debugDescription)

    rootDisclosure.click()

    XCTAssertEqual(rootDisclosure.label, "Collapse basic")
    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)
  }

  @MainActor
  func testDoubleClickWorkspaceRootRowDoesNotNavigate() throws {
    let workspaceURL = URL(filePath: try fixtureWorkspacePath("basic"), directoryHint: .isDirectory)
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let rootDisclosure = disclosureButton(for: workspaceURL, in: app)
    XCTAssertTrue(rootDisclosure.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)

    rootDisclosure.click()
    XCTAssertFalse(app.staticTexts["Reports"].waitForExistence(timeout: 1), app.debugDescription)

    app.staticTexts["basic"].doubleClick()

    XCTAssertFalse(app.staticTexts["Reports"].waitForExistence(timeout: 1), app.debugDescription)
    XCTAssertEqual(rootDisclosure.label, "Expand basic")
  }

  @MainActor
  func testRecentFoldersAppearCollapsedAtBottomOfSidebarAndOpenWorkspace() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let recentFolderPath = try fixtureWorkspacePath("sorting")
    let app = try launchApp(workspacePath: workspacePath, recentFolders: [recentFolderPath])

    if !app.staticTexts["Reports"].waitForExistence(timeout: 2) {
      let showSidebarButton = app.buttons["Show Sidebar"]
      XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 2), app.debugDescription)
      showSidebarButton.click()
    }
    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)

    let recentFoldersDisclosure = app.buttons
      .matching(identifier: "workspace-sidebar-recent-folders-disclosure")
      .firstMatch
    XCTAssertTrue(recentFoldersDisclosure.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(recentFoldersDisclosure.label, "Expand Recent Folders")
    XCTAssertFalse(app.buttons["Open sorting"].exists, app.debugDescription)

    recentFoldersDisclosure.click()

    let recentFolder = app.buttons
      .matching(identifier: "workspace-sidebar-recent-folder-row")
      .firstMatch
    XCTAssertTrue(recentFolder.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(recentFoldersDisclosure.label, "Collapse Recent Folders")

    recentFolder.click()

    XCTAssertTrue(app.staticTexts["Folder 2"].waitForExistence(timeout: 5), app.debugDescription)
  }

  @MainActor
  func testWorkspaceChromeOmitsPrototypeSecondaryControls() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let app = try launchApp(workspacePath: workspacePath)

    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(app.staticTexts[workspacePath].exists)
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "items")).count, 0)
    XCTAssertFalse(app.buttons["favorite-current-folder-button"].exists)
    XCTAssertFalse(app.buttons["Parent Folder"].exists)
    XCTAssertFalse(app.textFields["workspace-search-field"].exists)
    XCTAssertFalse(app.buttons["Refresh"].exists)
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

    XCTAssertTrue(
      app.staticTexts["Added Later.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["Added Second.md"].waitForExistence(timeout: 5), app.debugDescription)
  }

  @MainActor
  func testWorkspaceShowsErrorWhenCurrentFolderIsDeleted() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)

    try FileManager.default.removeItem(at: workspaceURL)
    filesToRemove.remove(workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(
      app.staticTexts["Folder Could Not Be Opened"].waitForExistence(timeout: 5),
      app.debugDescription)
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
  func testContextMenuIncludesCreationAndCopyPath() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let app = try launchApp(workspacePath: workspacePath)

    let projectBriefRowText = app.staticTexts["Project Brief.md"]
    XCTAssertTrue(projectBriefRowText.waitForExistence(timeout: 5), app.debugDescription)

    projectBriefRowText.rightClick()

    XCTAssertTrue(app.menuItems["New File"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(app.menuItems["New Folder"].exists, app.debugDescription)
    XCTAssertTrue(app.menuItems["Copy Path"].exists, app.debugDescription)
    XCTAssertFalse(app.menuItems["Open"].exists, app.debugDescription)
    XCTAssertFalse(app.menuItems["Preview"].exists, app.debugDescription)
    XCTAssertFalse(app.menuItems["Show in Locus"].exists, app.debugDescription)
  }

  @MainActor
  func testContextMenuCreatesNewFileInWorkspace() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let projectBriefRowText = app.staticTexts["Project Brief.md"]
    XCTAssertTrue(projectBriefRowText.waitForExistence(timeout: 5), app.debugDescription)

    projectBriefRowText.rightClick()
    let newFileMenuItem = app.menuItems["New File"]
    XCTAssertTrue(newFileMenuItem.waitForExistence(timeout: 2), app.debugDescription)
    newFileMenuItem.click()

    let nameField = app.textFields["workspace-sidebar-creation-name-field"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 2), app.debugDescription)
    nameField.click()
    app.typeText("Created From Menu.md")
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

    let createdURL = workspaceURL.appending(path: "Created From Menu.md")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: createdURL.path(percentEncoded: false))
    )
    XCTAssertTrue(
      app.staticTexts["Created From Menu.md"].waitForExistence(timeout: 5),
      app.debugDescription
    )
    assertTableRow(named: "Created From Menu.md", isSelectedIn: app)
  }

  @MainActor
  func testContextMenuCreationCanBeCancelledWithEscape() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let projectBriefRowText = app.staticTexts["Project Brief.md"]
    XCTAssertTrue(projectBriefRowText.waitForExistence(timeout: 5), app.debugDescription)

    projectBriefRowText.rightClick()
    let newFileMenuItem = app.menuItems["New File"]
    XCTAssertTrue(newFileMenuItem.waitForExistence(timeout: 2), app.debugDescription)
    newFileMenuItem.click()

    let nameField = app.textFields["workspace-sidebar-creation-name-field"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 2), app.debugDescription)
    app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])

    XCTAssertFalse(
      app.textFields["workspace-sidebar-creation-name-field"].waitForExistence(timeout: 1),
      app.debugDescription
    )
  }

  @MainActor
  func testContextMenuCreationReportsEmptyNameInline() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let projectBriefRowText = app.staticTexts["Project Brief.md"]
    XCTAssertTrue(projectBriefRowText.waitForExistence(timeout: 5), app.debugDescription)

    projectBriefRowText.rightClick()
    let newFileMenuItem = app.menuItems["New File"]
    XCTAssertTrue(newFileMenuItem.waitForExistence(timeout: 2), app.debugDescription)
    newFileMenuItem.click()

    let nameField = app.textFields["workspace-sidebar-creation-name-field"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 2), app.debugDescription)
    nameField.click()
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

    let errorText = app.staticTexts["workspace-sidebar-creation-error"]
    XCTAssertTrue(errorText.waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Enter a name."].exists, app.debugDescription)
  }

  @MainActor
  func testContextMenuCreationReportsExistingNameInline() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let projectBriefRowText = app.staticTexts["Project Brief.md"]
    XCTAssertTrue(projectBriefRowText.waitForExistence(timeout: 5), app.debugDescription)

    projectBriefRowText.rightClick()
    let newFileMenuItem = app.menuItems["New File"]
    XCTAssertTrue(newFileMenuItem.waitForExistence(timeout: 2), app.debugDescription)
    newFileMenuItem.click()

    let nameField = app.textFields["workspace-sidebar-creation-name-field"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 2), app.debugDescription)
    nameField.click()
    app.typeText("Project Brief.md")
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

    let errorText = app.staticTexts["workspace-sidebar-creation-error"]
    XCTAssertTrue(errorText.waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["'Project Brief.md' already exists."].exists, app.debugDescription)
  }

  @MainActor
  func testContextMenuCreatesNewFileInSelectedFolder() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let reportsRowText = app.staticTexts["Reports"]
    XCTAssertTrue(reportsRowText.waitForExistence(timeout: 5), app.debugDescription)

    reportsRowText.rightClick()
    let newFileMenuItem = app.menuItems["New File"]
    XCTAssertTrue(newFileMenuItem.waitForExistence(timeout: 2), app.debugDescription)
    newFileMenuItem.click()

    let nameField = app.textFields["workspace-sidebar-creation-name-field"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 2), app.debugDescription)
    nameField.click()
    app.typeText("Nested Created.md")
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

    let createdURL = workspaceURL.appending(path: "Reports/Nested Created.md")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: createdURL.path(percentEncoded: false))
    )
    XCTAssertTrue(
      app.staticTexts["Nested Created.md"].waitForExistence(timeout: 5),
      app.debugDescription
    )
  }

  @MainActor
  func testDoubleClickTextFileOpensDocumentEditorInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let app = try launchApp(workspacePath: workspacePath)

    let projectBriefRow = workspaceSidebarLabel(named: "Project Brief.md", in: app)
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.doubleClick()

    XCTAssertTrue(
      app.textViews["document-large-text-viewer"].waitForExistence(timeout: 5), app.debugDescription
    )
  }

  @MainActor
  func testClickingEmptySidebarAreaClearsSelectionWithoutClosingDocument() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let app = try launchApp(workspacePath: workspacePath)

    let projectBriefRow = workspaceSidebarLabel(named: "Project Brief.md", in: app)
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.click()

    XCTAssertTrue(
      app.textViews["document-large-text-viewer"].waitForExistence(timeout: 5), app.debugDescription
    )
    assertTableRow(named: "Project Brief.md", isSelectedIn: app)

    let sidebarList = workspaceSidebarList(in: app)
    XCTAssertTrue(sidebarList.waitForExistence(timeout: 2), app.debugDescription)
    emptyAreaCoordinate(in: sidebarList, app: app).click()

    assertTableRow(named: "Project Brief.md", isNotSelectedIn: app)
    XCTAssertFalse(
      app.textFields["workspace-sidebar-creation-name-field"].exists,
      app.debugDescription
    )
    XCTAssertTrue(app.textViews["document-large-text-viewer"].exists, app.debugDescription)
  }

  @MainActor
  func testDoubleClickingEmptySidebarAreaStartsNewFileCreation() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(
      workspaceSidebarLabel(named: "Project Brief.md", in: app).waitForExistence(timeout: 5),
      app.debugDescription)

    let sidebarList = workspaceSidebarList(in: app)
    XCTAssertTrue(sidebarList.waitForExistence(timeout: 2), app.debugDescription)
    emptyAreaCoordinate(in: sidebarList, app: app).doubleClick()

    let nameField = app.textFields["workspace-sidebar-creation-name-field"]
    XCTAssertTrue(nameField.waitForExistence(timeout: 2), app.debugDescription)
    nameField.click()
    app.typeText("Created From Double Click.md")
    app.typeKey(XCUIKeyboardKey.return, modifierFlags: [])

    let createdURL = workspaceURL.appending(path: "Created From Double Click.md")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: createdURL.path(percentEncoded: false))
    )
    XCTAssertTrue(
      workspaceSidebarLabel(named: "Created From Double Click.md", in: app)
        .waitForExistence(timeout: 5),
      app.debugDescription
    )
  }

  @MainActor
  func testClickingFolderKeepsPreviouslyOpenedDocumentVisible() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let app = try launchApp(workspacePath: workspacePath)

    let projectBriefRow = workspaceSidebarLabel(named: "Project Brief.md", in: app)
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.click()

    XCTAssertTrue(
      app.textViews["document-large-text-viewer"].waitForExistence(timeout: 5), app.debugDescription
    )

    let reportsRow = workspaceSidebarLabel(named: "Reports", in: app)
    XCTAssertTrue(reportsRow.waitForExistence(timeout: 5), app.debugDescription)
    reportsRow.click()

    assertTableRow(named: "Reports", isSelectedIn: app)
    XCTAssertTrue(app.textViews["document-large-text-viewer"].exists, app.debugDescription)
    XCTAssertFalse(app.staticTexts["Select a File"].exists, app.debugDescription)
  }

  @MainActor
  func testDoubleClickImageFileViewsImageInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let app = try launchApp(workspacePath: workspacePath)

    let sampleRowText = app.staticTexts["sample.png"]
    XCTAssertTrue(sampleRowText.waitForExistence(timeout: 5), app.debugDescription)
    sampleRowText.doubleClick()

    XCTAssertTrue(
      app.images["document-image-view"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["sample.png"].waitForExistence(timeout: 2), app.debugDescription)
  }

  @MainActor
  func testDoubleClickPDFFileViewsPDFInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let app = try launchApp(workspacePath: workspacePath)

    let sampleRowText = app.staticTexts["sample.pdf"]
    XCTAssertTrue(sampleRowText.waitForExistence(timeout: 5), app.debugDescription)
    sampleRowText.doubleClick()

    let pdfSurface = app.descendants(matching: .any)["document-pdf-surface"]
    XCTAssertTrue(pdfSurface.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["sample.pdf"].waitForExistence(timeout: 2), app.debugDescription)

    XCTAssertFalse(app.staticTexts["document-pdf-page-summary"].exists)
    XCTAssertFalse(app.staticTexts["document-pdf-zoom-summary"].exists)
    XCTAssertFalse(app.textFields["document-pdf-search-field"].exists)
    XCTAssertFalse(app.buttons["document-pdf-previous-page-button"].exists)
    XCTAssertFalse(app.buttons["document-pdf-next-page-button"].exists)
    XCTAssertFalse(app.buttons["document-pdf-zoom-out-button"].exists)
    XCTAssertFalse(app.buttons["document-pdf-fit-button"].exists)
    XCTAssertFalse(app.buttons["document-pdf-zoom-in-button"].exists)
    XCTAssertFalse(app.buttons["document-pdf-previous-search-match-button"].exists)
    XCTAssertFalse(app.buttons["document-pdf-next-search-match-button"].exists)
  }

  @MainActor
  func testDoubleClickOfficeFilePreviewsInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let app = try launchApp(workspacePath: workspacePath)

    let officeRowText = app.staticTexts["valid.docx"]
    XCTAssertTrue(officeRowText.waitForExistence(timeout: 5), app.debugDescription)
    officeRowText.doubleClick()

    let quickLookSurface = app.descendants(matching: .any)["document-quicklook-surface"]
    XCTAssertTrue(quickLookSurface.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["valid.docx"].waitForExistence(timeout: 2), app.debugDescription)
  }

  @MainActor
  func testDoubleClickVideoFilePlaysVideoInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let app = try launchApp(workspacePath: workspacePath)

    let videoRowText = app.staticTexts["video-placeholder.mp4"]
    XCTAssertTrue(videoRowText.waitForExistence(timeout: 5), app.debugDescription)
    videoRowText.doubleClick()

    let videoSurface = app.descendants(matching: .any)["document-video-surface"]
    XCTAssertTrue(videoSurface.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["video-placeholder.mp4"].waitForExistence(timeout: 2), app.debugDescription)
  }

  @MainActor
  func testDoubleClickAudioFilePlaysAudioInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let app = try launchApp(workspacePath: workspacePath)

    let audioRowText = app.staticTexts["audio-placeholder.mp3"]
    XCTAssertTrue(audioRowText.waitForExistence(timeout: 5), app.debugDescription)
    audioRowText.doubleClick()

    let audioSurface = app.descendants(matching: .any)["document-audio-surface"]
    XCTAssertTrue(audioSurface.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["audio-placeholder.mp3"].waitForExistence(timeout: 2), app.debugDescription)
  }

  @MainActor
  func testBrokenVideoShowsMediaErrorSurface() throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-invalid-video-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    filesToRemove.insert(workspaceURL.path(percentEncoded: false))

    try Data("not video".utf8).write(to: workspaceURL.appending(path: "broken.mp4"))

    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let brokenVideoRowText = app.staticTexts["broken.mp4"]
    XCTAssertTrue(brokenVideoRowText.waitForExistence(timeout: 5), app.debugDescription)
    brokenVideoRowText.doubleClick()

    XCTAssertTrue(
      app.descendants(matching: .any)["document-media-error-surface"].waitForExistence(timeout: 5),
      app.debugDescription
    )
  }

  @MainActor
  func testBrokenPDFShowsPDFErrorSurface() throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-invalid-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    filesToRemove.insert(workspaceURL.path(percentEncoded: false))

    try Data("not a pdf".utf8).write(to: workspaceURL.appending(path: "broken.pdf"))

    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let brokenPDFRowText = app.staticTexts["broken.pdf"]
    XCTAssertTrue(brokenPDFRowText.waitForExistence(timeout: 5), app.debugDescription)
    brokenPDFRowText.doubleClick()

    XCTAssertTrue(
      app.descendants(matching: .any)["document-pdf-error-surface"].waitForExistence(timeout: 5),
      app.debugDescription)
    XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 2), app.debugDescription)
  }

  @MainActor
  func testUndecodableImageShowsErrorSurface() throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-invalid-image-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    filesToRemove.insert(workspaceURL.path(percentEncoded: false))

    let brokenImageURL = workspaceURL.appending(path: "broken.png")
    try Data("not an image".utf8).write(to: brokenImageURL)

    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let brokenImageRowText = app.staticTexts["broken.png"]
    XCTAssertTrue(brokenImageRowText.waitForExistence(timeout: 5), app.debugDescription)
    brokenImageRowText.doubleClick()

    XCTAssertTrue(
      app.descendants(matching: .any)["document-image-error-surface"].waitForExistence(timeout: 5),
      app.debugDescription)
    XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertFalse(app.buttons["Preview"].exists, app.debugDescription)
  }

  @MainActor
  func testMarkdownFileCanBeEditedAndSavedInLocus() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let projectBriefURL = workspaceURL.appending(path: "Project Brief.md")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let projectBriefRow = app.outlines.firstMatch.cells
      .containing(NSPredicate(format: "value == %@", "Project Brief.md"))
      .firstMatch
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.click()

    let editor = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
    editor.click()

    let updatedText = "# Updated Brief\n\nLocus edits Markdown in app.\n"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(updatedText, forType: .string)
    app.typeKey("a", modifierFlags: [.command])
    app.typeKey("v", modifierFlags: [.command])

    XCTAssertFalse(app.buttons["document-save-button"].exists, app.debugDescription)
    XCTAssertFalse(app.buttons["Save"].exists, app.debugDescription)
    XCTAssertTrue(waitForEditorContents(updatedText, in: app, timeout: 5), app.debugDescription)

    app.menuBars.menuBarItems["File"].click()
    let saveMenuItem = app.menuBars.menuItems["Save"]
    XCTAssertTrue(saveMenuItem.waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(saveMenuItem.isEnabled, app.debugDescription)
    saveMenuItem.click()

    XCTAssertTrue(waitForFileContents(updatedText, at: projectBriefURL), app.debugDescription)
  }

  @MainActor
  func testOpenTextDocumentSyncsExternalChangeAutomatically() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let projectBriefURL = workspaceURL.appending(path: "Project Brief.md")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let projectBriefRow = app.outlines.firstMatch.cells
      .containing(NSPredicate(format: "value == %@", "Project Brief.md"))
      .firstMatch
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.click()

    let editor = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)

    let externalText = "# External Update\n\nChanged outside Locus.\n"
    try externalText.write(to: projectBriefURL, atomically: true, encoding: .utf8)

    XCTAssertTrue(
      waitForEditorContents(externalText, in: app, timeout: 5),
      app.debugDescription
    )

    XCTAssertFalse(app.buttons["document-save-button"].exists, app.debugDescription)
    XCTAssertFalse(app.buttons["Save"].exists, app.debugDescription)
  }

  @MainActor
  func testRecentFolderOpensFromHome() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let app = try launchAppWithRecentFolder(workspacePath: workspacePath)

    XCTAssertTrue(
      app.staticTexts["Recent Folders"].waitForExistence(timeout: 5), app.debugDescription)

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

    XCTAssertTrue(
      app.staticTexts["Recent Files"].waitForExistence(timeout: 5), app.debugDescription)

    let recentFile = app.buttons.matching(identifier: "recent-file-row").firstMatch
    XCTAssertTrue(recentFile.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.buttons["Open Project Brief.md"].waitForExistence(timeout: 5), app.debugDescription)
  }

  @MainActor
  func testRecentFileShowsContainingFolderAndSelectsFile() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let recentFilePath = "\(workspacePath)/Project Brief.md"
    let app = try launchApp(recentFiles: [recentFilePath])

    let recentFile = app.buttons.matching(identifier: "recent-file-row").firstMatch
    XCTAssertTrue(recentFile.waitForExistence(timeout: 5), app.debugDescription)
    recentFile.click()

    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["Project Brief.md"].waitForExistence(timeout: 5), app.debugDescription)
    assertTableRow(named: "Project Brief.md", isSelectedIn: app)
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
  func testRecentFileShortcutContextMenuOmitsPreviewAndShowInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let recentFilePath = "\(workspacePath)/Project Brief.md"
    let app = try launchApp(recentFiles: [recentFilePath])

    let recentFile = app.buttons.matching(identifier: "recent-file-row").firstMatch
    XCTAssertTrue(recentFile.waitForExistence(timeout: 5), app.debugDescription)

    recentFile.rightClick()

    XCTAssertTrue(app.menuItems["Open"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(app.menuItems["Copy Path"].exists, app.debugDescription)
    XCTAssertTrue(app.menuItems["Remove"].exists, app.debugDescription)
    XCTAssertFalse(app.menuItems["Preview"].exists, app.debugDescription)
    XCTAssertFalse(app.menuItems["Show in Locus"].exists, app.debugDescription)
  }

  @MainActor
  func testRecentFileIsPrunedWhenContainingFolderCannotBeLoaded() throws {
    let recentFilesKey = "recentFiles.uiTests.\(UUID().uuidString)"
    let folderURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-deleted-recent-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    filesToRemove.insert(folderURL.path(percentEncoded: false))

    let recentFileURL = folderURL.appending(path: "orphaned.md")
    let recentFilePath = recentFileURL.path(percentEncoded: false)
    try "Orphaned\n".write(to: recentFileURL, atomically: true, encoding: .utf8)

    var app = try launchApp(recentFilesKey: recentFilesKey, recentFiles: [recentFilePath])
    let recentFile = app.buttons.matching(identifier: "recent-file-row").firstMatch
    XCTAssertTrue(recentFile.waitForExistence(timeout: 5), app.debugDescription)

    try FileManager.default.removeItem(at: folderURL)
    filesToRemove.remove(folderURL.path(percentEncoded: false))
    recentFile.click()

    XCTAssertTrue(
      app.staticTexts["Folder Could Not Be Opened"].waitForExistence(timeout: 5),
      app.debugDescription)

    app.terminate()
    app = try launchApp(recentFilesKey: recentFilesKey)
    XCTAssertFalse(
      app.buttons.matching(identifier: "recent-file-row").firstMatch.waitForExistence(timeout: 2))
  }

  @MainActor
  func testLargeFileViewerExposesSelectAllAndCopy() throws {
    // The text viewer resolves as a text view and supports select-all + copy.
    let app = try launchApp(workspacePath: fixtureWorkspacePath("basic"))

    let row = workspaceSidebarLabel(named: "Notes.txt", in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.click()

    let viewer = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    viewer.click()

    NSPasteboard.general.clearContents()
    var copied: String?
    let deadline = Date().addingTimeInterval(2)
    repeat {
      app.typeKey("a", modifierFlags: [.command])
      app.typeKey("c", modifierFlags: [.command])
      copied = NSPasteboard.general.string(forType: .string)
      if copied?.contains("Meeting notes") == true { break }
      Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline

    XCTAssertEqual(copied?.contains("Meeting notes"), true, "copied=\(copied ?? "nil")")
    XCTAssertEqual(copied?.contains("Avoid startup indexing."), true, "copied=\(copied ?? "nil")")
  }

  @MainActor
  func testReadOnlyLargeViewerSupportsSelectionAndStaysReadOnly() throws {
    // Force the large-text threshold low so a small fixture routes through the
    // windowed read-only viewer (a real >256 MiB file is impractical as a
    // fixture). The file then opens read-only via `LargeFile`, not the editable
    // buffer — the path that used to be a plain line list.
    let app = try launchApp(
      workspacePath: fixtureWorkspacePath("basic"),
      extraArguments: ["--ui-test-large-text-byte-limit", "16"]
    )

    let row = workspaceSidebarLabel(named: "Notes.txt", in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.click()

    // It resolves as the read-only viewer, not the editable one.
    let viewer = app.textViews["document-readonly-large-text-viewer"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(app.textViews["document-large-text-viewer"].exists, app.debugDescription)
    viewer.click()

    // Select-all + copy reads the windowed content.
    func copyAll() -> String? {
      NSPasteboard.general.clearContents()
      var copied: String?
      let deadline = Date().addingTimeInterval(2)
      repeat {
        app.typeKey("a", modifierFlags: [.command])
        app.typeKey("c", modifierFlags: [.command])
        copied = NSPasteboard.general.string(forType: .string)
        if copied?.contains("Meeting notes") == true { break }
        Thread.sleep(forTimeInterval: 0.05)
      } while Date() < deadline
      return copied
    }
    XCTAssertEqual(copyAll()?.contains("Avoid startup indexing."), true, app.debugDescription)

    // Editing is inert: a paste over the selection changes nothing.
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("OVERWRITE", forType: .string)
    app.typeKey("a", modifierFlags: [.command])
    app.typeKey("v", modifierFlags: [.command])
    // The original content survives — the paste was ignored.
    XCTAssertEqual(copyAll()?.contains("Meeting notes"), true, app.debugDescription)

    // The real Save affordance is the File > Save menu command (not a button), so
    // assert it directly: it must stay disabled for a read-only document, which is
    // the `WorkspaceDocumentSurface.isSaveDisabled` contract.
    let fileMenu = app.menuBars.menuBarItems["File"]
    XCTAssertTrue(fileMenu.waitForExistence(timeout: 5), app.debugDescription)
    fileMenu.click()
    let saveItem = app.menuBars.menuItems["Save"]
    XCTAssertTrue(saveItem.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertFalse(saveItem.isEnabled, app.debugDescription)
    app.typeKey(.escape, modifierFlags: [])  // close the menu
  }

  @MainActor
  func testLargeFileViewerAcceptsBasicTyping() throws {
    // The large-file viewer is editable: select the whole document, type a known
    // marker to replace it, then read it back through select-all + copy (the AX
    // value intentionally never materializes the whole document). Edits stay in
    // memory — there is no save here — so the fixture on disk is untouched.
    let app = try launchApp(workspacePath: fixtureWorkspacePath("basic"))

    let row = workspaceSidebarLabel(named: "Notes.txt", in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.click()

    let viewer = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    viewer.click()

    app.typeKey("a", modifierFlags: [.command])  // select all
    app.typeText("LocusEdit")  // replaces the selection

    NSPasteboard.general.clearContents()
    var copied: String?
    let deadline = Date().addingTimeInterval(2)
    repeat {
      app.typeKey("a", modifierFlags: [.command])
      app.typeKey("c", modifierFlags: [.command])
      copied = NSPasteboard.general.string(forType: .string)
      if copied == "LocusEdit" { break }
      Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline

    XCTAssertEqual(copied, "LocusEdit", "copied=\(copied ?? "nil")")
  }

  @MainActor
  func testLargeFileViewerUndoesTypingWithCommandZ() throws {
    // Verifies Cmd+Z reaches the viewer (rather than the Edit menu's undo
    // manager): type a marker, confirm it appears, undo, confirm it is gone.
    let app = try launchApp(workspacePath: fixtureWorkspacePath("basic"))

    let row = workspaceSidebarLabel(named: "Notes.txt", in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.click()

    let viewer = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    viewer.click()

    // Insert a marker character that the original document does not contain.
    app.typeText("Q")

    func copyAll() -> String? {
      NSPasteboard.general.clearContents()
      app.typeKey("a", modifierFlags: [.command])
      app.typeKey("c", modifierFlags: [.command])
      return NSPasteboard.general.string(forType: .string)
    }

    var copied: String?
    var deadline = Date().addingTimeInterval(2)
    repeat {
      copied = copyAll()
      if copied?.contains("Q") == true { break }
      Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    XCTAssertEqual(copied?.contains("Q"), true, "after typing: \(copied ?? "nil")")

    app.typeKey("z", modifierFlags: [.command])  // undo the insert

    deadline = Date().addingTimeInterval(2)
    repeat {
      copied = copyAll()
      if copied?.contains("Q") == false { break }
      Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    XCTAssertEqual(copied?.contains("Q"), false, "after undo: \(copied ?? "nil")")
    XCTAssertEqual(copied?.contains("Meeting notes"), true, "after undo: \(copied ?? "nil")")
  }

  @MainActor
  func testLargeFileViewerSavesEditsWithCommandS() throws {
    // Use a throwaway workspace so the edited file can be written safely (the
    // repo fixtures are never modified), then verify Cmd+S reaches disk.
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("locus-save-uitest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let fileURL = workspace.appendingPathComponent("Notes.txt")
    try Data("Meeting notes".utf8).write(to: fileURL)

    let app = try launchApp(workspacePath: workspace.path)

    let row = workspaceSidebarLabel(named: "Notes.txt", in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.click()

    let viewer = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    viewer.click()

    app.typeKey("a", modifierFlags: [.command])  // select all
    app.typeText("Saved!")  // replace the document
    app.typeKey("s", modifierFlags: [.command])  // save to disk

    var contents = ""
    let deadline = Date().addingTimeInterval(3)
    repeat {
      contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
      if contents == "Saved!" { break }
      Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline

    XCTAssertEqual(contents, "Saved!", "on-disk contents=\(contents)")
  }

  @MainActor
  func testLargeFileViewerConflictsOnExternalChangeWhileDirty() throws {
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("locus-conflict-uitest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let fileURL = workspace.appendingPathComponent("Notes.txt")
    try Data("ORIGINAL".utf8).write(to: fileURL)

    let app = try launchApp(workspacePath: workspace.path)

    let row = workspaceSidebarLabel(named: "Notes.txt", in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.click()

    let viewer = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    viewer.click()

    // Make unsaved edits, then change the file externally.
    app.typeKey("a", modifierFlags: [.command])
    app.typeText("DIRTYEDIT")
    try Data("EXTERNAL".utf8).write(to: fileURL)

    func copyAll() -> String? {
      NSPasteboard.general.clearContents()
      app.typeKey("a", modifierFlags: [.command])
      app.typeKey("c", modifierFlags: [.command])
      return NSPasteboard.general.string(forType: .string)
    }

    // A conflict banner appears (rather than silently reloading).
    let reload = app.buttons["Reload from Disk"]
    XCTAssertTrue(reload.waitForExistence(timeout: 3), app.debugDescription)

    // The unsaved edits are preserved (the buffer was not reloaded).
    viewer.click()
    XCTAssertEqual(copyAll(), "DIRTYEDIT")

    // Reload discards the edits and shows the on-disk content.
    reload.click()
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: reload)
    waitForExpectations(timeout: 3)

    viewer.click()
    var reloaded: String?
    let deadline = Date().addingTimeInterval(2)
    repeat {
      reloaded = copyAll()
      if reloaded == "EXTERNAL" { break }
      Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    XCTAssertEqual(reloaded, "EXTERNAL")
  }

  @MainActor
  func testInactiveCleanDocumentReloadsExternalChangeOnReturn() throws {
    // A clean document kept open while another is shown must reflect an external
    // change made while it was inactive when the user switches back to it.
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("locus-retention-clean-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let aURL = workspace.appendingPathComponent("Notes.txt")
    let bURL = workspace.appendingPathComponent("Other.txt")
    try Data("ORIGINAL".utf8).write(to: aURL)
    try Data("OTHER".utf8).write(to: bURL)

    let app = try launchApp(workspacePath: workspace.path)
    let viewer = app.textViews["document-large-text-viewer"]

    func open(_ name: String) {
      let row = workspaceSidebarLabel(named: name, in: app)
      XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
      row.click()
      XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    }
    func copyAll() -> String? {
      NSPasteboard.general.clearContents()
      viewer.click()
      app.typeKey("a", modifierFlags: [.command])
      app.typeKey("c", modifierFlags: [.command])
      return NSPasteboard.general.string(forType: .string)
    }

    open("Notes.txt")
    XCTAssertEqual(copyAll(), "ORIGINAL")
    open("Other.txt")  // leave A open but inactive
    try Data("EXTERNAL".utf8).write(to: aURL)  // A changes while inactive
    open("Notes.txt")  // return to A

    var shown: String?
    let deadline = Date().addingTimeInterval(3)
    repeat {
      shown = copyAll()
      if shown == "EXTERNAL" { break }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    XCTAssertEqual(shown, "EXTERNAL", app.debugDescription)
  }

  @MainActor
  func testInactiveDirtyDocumentConflictsWithExternalChangeOnReturn() throws {
    // A document with unsaved edits kept open while another is shown must keep its
    // edits and surface a conflict (not silently reload) when an external change
    // happened while it was inactive and the user switches back.
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("locus-retention-dirty-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let aURL = workspace.appendingPathComponent("Notes.txt")
    let bURL = workspace.appendingPathComponent("Other.txt")
    try Data("ORIGINAL".utf8).write(to: aURL)
    try Data("OTHER".utf8).write(to: bURL)

    let app = try launchApp(workspacePath: workspace.path)
    let viewer = app.textViews["document-large-text-viewer"]

    func open(_ name: String) {
      let row = workspaceSidebarLabel(named: name, in: app)
      XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
      row.click()
      XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    }
    func copyAll() -> String? {
      NSPasteboard.general.clearContents()
      viewer.click()
      app.typeKey("a", modifierFlags: [.command])
      app.typeKey("c", modifierFlags: [.command])
      return NSPasteboard.general.string(forType: .string)
    }

    open("Notes.txt")
    viewer.click()
    app.typeKey("a", modifierFlags: [.command])
    app.typeText("DIRTYEDIT")  // unsaved edits in A
    open("Other.txt")  // leave A open and dirty but inactive
    try Data("EXTERNAL".utf8).write(to: aURL)  // A changes while inactive
    open("Notes.txt")  // return to A

    let reload = app.buttons["Reload from Disk"]
    XCTAssertTrue(reload.waitForExistence(timeout: 5), app.debugDescription)  // conflict banner
    XCTAssertEqual(copyAll(), "DIRTYEDIT", app.debugDescription)  // edits preserved
  }

  @MainActor
  func testLargeFileViewerKeepsConflictWhenUndoneToClean() throws {
    // Regression: undoing edits back to a clean buffer must not hide a pending
    // external-change conflict (the file on disk is still divergent).
    let workspace = FileManager.default.temporaryDirectory
      .appendingPathComponent("locus-conflict-undo-uitest-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workspace) }
    let fileURL = workspace.appendingPathComponent("Notes.txt")
    try Data("ORIGINAL".utf8).write(to: fileURL)

    let app = try launchApp(workspacePath: workspace.path)

    let row = workspaceSidebarLabel(named: "Notes.txt", in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.click()

    let viewer = app.textViews["document-large-text-viewer"]
    XCTAssertTrue(viewer.waitForExistence(timeout: 5), app.debugDescription)
    viewer.click()

    app.typeKey("a", modifierFlags: [.command])
    app.typeText("DIRTYEDIT")  // single replace edit
    try Data("EXTERNAL".utf8).write(to: fileURL)

    let reload = app.buttons["Reload from Disk"]
    XCTAssertTrue(reload.waitForExistence(timeout: 3), app.debugDescription)

    // Undo back to the opened content: the buffer is clean again, but the disk
    // change is still unreconciled, so the conflict banner must remain.
    app.typeKey("z", modifierFlags: [.command])
    Thread.sleep(forTimeInterval: 0.3)
    XCTAssertTrue(reload.exists, "conflict banner should persist after undo")
  }

  @MainActor
  private func launchAppWithBasicWorkspace() throws -> XCUIApplication {
    try launchApp(workspacePath: fixtureWorkspacePath("basic"))
  }

  @MainActor
  private func launchApp(
    workspacePath: String? = nil,
    recentFilesKey: String = "recentFiles.uiTests.\(UUID().uuidString)",
    recentFoldersKey: String = "recentFolders.uiTests.\(UUID().uuidString)",
    recentFiles: [String] = [],
    recentFolders: [String] = [],
    extraArguments: [String] = []
  ) throws -> XCUIApplication {
    trackUserDefaultsKeys(
      recentFilesKey,
      recentFoldersKey,
      "workspace.sidebar.recentFoldersExpanded"
    )

    let app = XCUIApplication()
    app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
    app.launchArguments = [
      "--ui-test-recent-files-key",
      recentFilesKey,
      "--ui-test-recent-folders-key",
      recentFoldersKey,
    ]
    for recentFile in recentFiles {
      app.launchArguments += ["--ui-test-recent-file", recentFile]
    }
    for recentFolder in recentFolders {
      app.launchArguments += ["--ui-test-recent-folder", recentFolder]
    }
    if let workspacePath {
      app.launchArguments += [
        "--ui-test-workspace",
        workspacePath,
      ]
    }
    app.launchArguments += extraArguments
    try launchAndWaitForWindow(app)
    return app
  }

  @MainActor
  private func launchAppWithRecentFolder(workspacePath: String) throws -> XCUIApplication {
    try launchApp(recentFolders: [workspacePath])
  }

  @MainActor
  private func launchAppWithRecentFile(filePath: String) throws -> XCUIApplication {
    try launchApp(recentFiles: [filePath])
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
    let appDefaults = UserDefaults(suiteName: "com.nash.locus")
    for key in keys {
      userDefaultsKeysToRemove.insert(key)
      UserDefaults.standard.removeObject(forKey: key)
      appDefaults?.removeObject(forKey: key)
    }
  }

  @MainActor
  private func disclosureButton(for directoryURL: URL, in app: XCUIApplication) -> XCUIElement {
    // The sidebar hashes each row's `entry.id`. For the workspace root that id is
    // the standardized path with no trailing slash (matching the app's
    // `locusStandardizedPath`), so normalize here the same way — a directory URL
    // built with `directoryHint: .isDirectory` otherwise carries a trailing slash
    // and hashes differently. Child rows already have a slash-free path, so this
    // leaves them unchanged.
    let identifier =
      "workspace-sidebar-disclosure-\(stableHash(for: standardizedPath(for: directoryURL)))"
    return app.buttons.matching(identifier: identifier).firstMatch
  }

  private func standardizedPath(for url: URL) -> String {
    var path = url.standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  @MainActor
  private func emptyAreaCoordinate(
    in sidebarList: XCUIElement,
    app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUICoordinate {
    let sidebarFrame = sidebarList.frame
    let visibleRowFrames = sidebarList.cells.allElementsBoundByIndex
      .filter { $0.exists && $0.frame.intersects(sidebarFrame) }
      .map(\.frame)

    let lastRowMaxY = visibleRowFrames.map(\.maxY).max() ?? sidebarFrame.minY
    XCTAssertLessThan(
      lastRowMaxY + 8,
      sidebarFrame.maxY,
      "The fixture no longer leaves clickable empty sidebar space.",
      file: file,
      line: line
    )

    let point = CGPoint(
      x: sidebarFrame.midX,
      y: min((lastRowMaxY + sidebarFrame.maxY) / 2, sidebarFrame.maxY - 4)
    )
    return sidebarList.coordinate(
      withNormalizedOffset: CGVector(
        dx: (point.x - sidebarFrame.minX) / sidebarFrame.width,
        dy: (point.y - sidebarFrame.minY) / sidebarFrame.height
      )
    )
  }

  @MainActor
  private func workspaceSidebarList(in app: XCUIApplication) -> XCUIElement {
    let outline = app.outlines["workspace-sidebar-list"].firstMatch
    if outline.exists {
      return outline
    }

    let table = app.tables["workspace-sidebar-list"].firstMatch
    if table.exists {
      return table
    }

    return app.scrollViews["workspace-sidebar-list"].firstMatch
  }

  @MainActor
  private func workspaceSidebarLabel(named name: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[name]
  }

  private func stableHash(for value: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x100_0000_01b3
    }
    return String(hash, radix: 16)
  }

  @MainActor
  private func assertTableRow(
    named name: String,
    isSelectedIn app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let nameCell = workspaceSidebarCellContainingLabel(named: name, in: app)
    XCTAssertTrue(nameCell.isSelected, app.debugDescription, file: file, line: line)
  }

  @MainActor
  private func assertTableRow(
    named name: String,
    isNotSelectedIn app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let nameCell = workspaceSidebarCellContainingLabel(named: name, in: app)
    XCTAssertFalse(nameCell.isSelected, app.debugDescription, file: file, line: line)
  }

  @MainActor
  private func workspaceSidebarCellContainingLabel(
    named name: String,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let label = workspaceSidebarLabel(named: name, in: app)
    XCTAssertTrue(label.waitForExistence(timeout: 2), app.debugDescription, file: file, line: line)

    let labelCenter = CGPoint(x: label.frame.midX, y: label.frame.midY)
    let matchingCell = workspaceSidebarList(in: app).cells.allElementsBoundByIndex.first { cell in
      cell.exists && cell.frame.contains(labelCenter)
    }

    guard let matchingCell else {
      XCTFail(
        "Could not find sidebar cell containing '\(name)'.",
        file: file,
        line: line
      )
      return app.cells.firstMatch
    }

    return matchingCell
  }

  private func waitForFileContents(
    _ expectedContents: String,
    at url: URL,
    timeout: TimeInterval = 2
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if (try? String(contentsOf: url, encoding: .utf8)) == expectedContents {
        return true
      }

      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    return false
  }

  @MainActor
  private func waitForEditorContents(
    _ expectedContents: String,
    in app: XCUIApplication,
    timeout: TimeInterval = 2
  ) -> Bool {
    let editor = app.textViews["document-large-text-viewer"]
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      NSPasteboard.general.clearContents()
      editor.click()
      app.typeKey("a", modifierFlags: [.command])
      app.typeKey("c", modifierFlags: [.command])
      if NSPasteboard.general.string(forType: .string) == expectedContents {
        return true
      }

      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    return false
  }

  private func temporaryWorkspaceCopy(ofFixtureNamed name: String) throws -> URL {
    let source = URL(filePath: try fixtureWorkspacePath(name), directoryHint: .isDirectory)
    let destination = FileManager.default.temporaryDirectory
      .appending(path: "locus-ui-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: source, to: destination)
    filesToRemove.insert(destination.path(percentEncoded: false))
    return destination
  }

  private func makeNavigationHistoryWorkspace() throws -> URL {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-navigation-history-\(UUID().uuidString)", directoryHint: .isDirectory)
    let alphaURL = workspaceURL.appending(path: "Alpha", directoryHint: .isDirectory)
    let betaURL = alphaURL.appending(path: "Beta", directoryHint: .isDirectory)
    let gammaURL = betaURL.appending(path: "Gamma", directoryHint: .isDirectory)
    let otherURL = workspaceURL.appending(path: "Other", directoryHint: .isDirectory)

    try FileManager.default.createDirectory(at: gammaURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
    try "Alpha\n".write(
      to: alphaURL.appending(path: "Alpha Note.md"),
      atomically: true,
      encoding: .utf8
    )
    try "Beta\n".write(
      to: betaURL.appending(path: "Beta Note.md"),
      atomically: true,
      encoding: .utf8
    )
    try "Gamma\n".write(
      to: gammaURL.appending(path: "Gamma Note.md"),
      atomically: true,
      encoding: .utf8
    )
    try "Other\n".write(
      to: otherURL.appending(path: "Other Note.md"),
      atomically: true,
      encoding: .utf8
    )

    filesToRemove.insert(workspaceURL.path(percentEncoded: false))
    return workspaceURL
  }

  private func makeSymlinkWorkspace() throws -> URL {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-symlink-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)
    let targetFolderURL = workspaceURL.appending(path: "Target Folder", directoryHint: .isDirectory)
    let targetFileURL = workspaceURL.appending(path: "Target.md", directoryHint: .notDirectory)

    try FileManager.default.createDirectory(at: targetFolderURL, withIntermediateDirectories: true)
    try "# Child\n".write(
      to: targetFolderURL.appending(path: "Child.md"),
      atomically: true,
      encoding: .utf8
    )
    try "# Target\n".write(to: targetFileURL, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: workspaceURL.appending(path: "linked-folder", directoryHint: .isDirectory),
      withDestinationURL: targetFolderURL
    )
    try FileManager.default.createSymbolicLink(
      at: workspaceURL.appending(path: "Linked.md", directoryHint: .notDirectory),
      withDestinationURL: targetFileURL
    )

    filesToRemove.insert(workspaceURL.path(percentEncoded: false))
    return workspaceURL
  }

  private func fixtureWorkspacePath(_ name: String, filePath: String = #filePath) throws -> String {
    var directory = URL(filePath: filePath).deletingLastPathComponent()
    let fileManager = FileManager.default

    while !directory.path(percentEncoded: false).isEmpty,
      directory.path(percentEncoded: false) != "/"
    {
      let candidate = directory.appending(
        path: "fixtures/workspaces/\(name)", directoryHint: .isDirectory)
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(
        atPath: candidate.path(percentEncoded: false), isDirectory: &isDirectory),
        isDirectory.boolValue
      {
        return
          directory
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

extension XCUIElement {
  @MainActor
  fileprivate func waitForKeyboardFocus(timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "hasKeyboardFocus == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
