import AppKit
import CoreGraphics
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
  func testDoubleClickDirectoryRowNavigatesIntoFolder() throws {
    let app = try launchAppWithBasicWorkspace()

    let reportsRowText = app.staticTexts["Reports"]
    XCTAssertTrue(reportsRowText.waitForExistence(timeout: 5), app.debugDescription)

    reportsRowText.doubleClick()

    XCTAssertTrue(
      app.staticTexts["report-2026-01.md"].waitForExistence(timeout: 5), app.debugDescription)
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
    XCTAssertTrue(app.staticTexts["Gamma Note.md"].waitForExistence(timeout: 5), app.debugDescription)

    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(app.staticTexts["Beta Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Gamma"].waitForExistence(timeout: 2), app.debugDescription)

    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 2), app.debugDescription)

    app.typeKey("]", modifierFlags: [.command])
    XCTAssertTrue(app.staticTexts["Beta Note.md"].waitForExistence(timeout: 5), app.debugDescription)
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

    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(app.staticTexts["Beta Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(app.staticTexts["Alpha Note.md"].waitForExistence(timeout: 5), app.debugDescription)
    app.typeKey("[", modifierFlags: [.command])
    XCTAssertTrue(app.staticTexts["Other"].waitForExistence(timeout: 5), app.debugDescription)

    app.staticTexts["Other"].doubleClick()
    XCTAssertTrue(app.staticTexts["Other Note.md"].waitForExistence(timeout: 5), app.debugDescription)

    app.typeKey("]", modifierFlags: [.command])
    XCTAssertTrue(app.staticTexts["Other Note.md"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertFalse(app.staticTexts["Alpha Note.md"].exists)
  }

  @MainActor
  func testCommandBracketDoesNotNavigateWhilePDFSearchIsFocused() throws {
    let workspaceURL = try makeNavigationHistoryWorkspace()
    let betaURL = workspaceURL
      .appending(path: "Alpha", directoryHint: .isDirectory)
      .appending(path: "Beta", directoryHint: .isDirectory)
    try writeFixturePDF(pageCount: 1, to: betaURL.appending(path: "Beta Search.pdf"))
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    XCTAssertTrue(app.staticTexts["Alpha"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Alpha"].doubleClick()
    XCTAssertTrue(app.staticTexts["Beta"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Beta"].doubleClick()
    XCTAssertTrue(app.staticTexts["Beta Search.pdf"].waitForExistence(timeout: 5), app.debugDescription)
    app.staticTexts["Beta Search.pdf"].doubleClick()

    let searchField = app.textFields["document-pdf-search-field"]
    XCTAssertTrue(searchField.waitForExistence(timeout: 5), app.debugDescription)
    searchField.click()
    searchField.typeText("Page")
    app.typeKey("[", modifierFlags: [.command])

    XCTAssertTrue(app.staticTexts["Beta Note.md"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertFalse(app.staticTexts["Alpha Note.md"].exists)
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
  func testWorkspaceChromeOmitsPrototypeSecondaryControls() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let app = try launchApp(workspacePath: workspacePath)

    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["basic"].waitForExistence(timeout: 2), app.debugDescription)
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
    // These actions intentionally stay out of the UI; keep assertions here
    // so future menu work does not reintroduce external handoff paths.
    XCTAssertFalse(app.menuItems["Reveal in Finder"].exists)
    XCTAssertFalse(app.menuItems["Open Externally"].exists)
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

    let projectBriefRow = app.outlines.firstMatch.cells
      .containing(NSPredicate(format: "value == %@", "Project Brief.md"))
      .firstMatch
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.click()

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
  func testDoubleClickTextFileOpensDocumentEditorInLocus() throws {
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
    projectBriefRowText.doubleClick()

    XCTAssertTrue(
      app.textViews["document-text-editor"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(
      previewInvocations(forKey: previewInvocationsKey, filePath: previewInvocationsFilePath), [])
  }

  @MainActor
  func testDoubleClickImageFileViewsImageInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
    let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
    let app = try launchApp(
      workspacePath: workspacePath,
      previewInvocationsKey: previewInvocationsKey,
      previewInvocationsFilePath: previewInvocationsFilePath
    )

    let sampleRowText = app.staticTexts["sample.png"]
    XCTAssertTrue(sampleRowText.waitForExistence(timeout: 5), app.debugDescription)
    sampleRowText.doubleClick()

    XCTAssertTrue(
      app.images["document-image-view"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["sample.png"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(
      previewInvocations(forKey: previewInvocationsKey, filePath: previewInvocationsFilePath), [])
  }

  @MainActor
  func testDoubleClickPDFFileViewsPDFInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
    let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
    let app = try launchApp(
      workspacePath: workspacePath,
      previewInvocationsKey: previewInvocationsKey,
      previewInvocationsFilePath: previewInvocationsFilePath
    )

    let sampleRowText = app.staticTexts["sample.pdf"]
    XCTAssertTrue(sampleRowText.waitForExistence(timeout: 5), app.debugDescription)
    sampleRowText.doubleClick()

    let pdfSurface = app.descendants(matching: .any)["document-pdf-surface"]
    XCTAssertTrue(pdfSurface.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["sample.pdf"].waitForExistence(timeout: 2), app.debugDescription)

    let pageSummary = app.staticTexts["document-pdf-page-summary"]
    XCTAssertTrue(pageSummary.waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(pageSummary.label, "Page 1 of 1")
    XCTAssertTrue(
      app.buttons["document-pdf-previous-page-button"].waitForExistence(timeout: 2),
      app.debugDescription)
    XCTAssertTrue(
      app.buttons["document-pdf-next-page-button"].waitForExistence(timeout: 2),
      app.debugDescription)
    XCTAssertTrue(
      app.buttons["document-pdf-zoom-out-button"].waitForExistence(timeout: 2), app.debugDescription
    )
    XCTAssertTrue(
      app.buttons["document-pdf-fit-button"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(
      app.buttons["document-pdf-zoom-in-button"].waitForExistence(timeout: 2), app.debugDescription)

    let searchField = app.textFields["document-pdf-search-field"]
    XCTAssertTrue(searchField.waitForExistence(timeout: 2), app.debugDescription)
    searchField.click()
    searchField.typeText("Locus")

    let searchSummary = app.staticTexts["document-pdf-search-summary"]
    XCTAssertTrue(waitForElement(searchSummary, toHaveLabel: "1 of 1"), app.debugDescription)
    XCTAssertTrue(
      app.buttons["document-pdf-previous-search-match-button"].waitForExistence(timeout: 2),
      app.debugDescription)
    XCTAssertTrue(
      app.buttons["document-pdf-next-search-match-button"].waitForExistence(timeout: 2),
      app.debugDescription)
    XCTAssertEqual(
      previewInvocations(forKey: previewInvocationsKey, filePath: previewInvocationsFilePath), [])
  }

  @MainActor
  func testPDFControlsNavigatePagesAndZoomInLocus() throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-pdf-controls-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    filesToRemove.insert(workspaceURL.path(percentEncoded: false))
    try writeFixturePDF(pageCount: 2, to: workspaceURL.appending(path: "multi-page.pdf"))

    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let pdfRowText = app.staticTexts["multi-page.pdf"]
    XCTAssertTrue(pdfRowText.waitForExistence(timeout: 5), app.debugDescription)
    pdfRowText.doubleClick()

    let pageSummary = app.staticTexts["document-pdf-page-summary"]
    XCTAssertTrue(pageSummary.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertEqual(pageSummary.label, "Page 1 of 2")

    app.buttons["document-pdf-next-page-button"].click()
    XCTAssertTrue(waitForElement(pageSummary, toHaveLabel: "Page 2 of 2"), app.debugDescription)

    let zoomSummary = app.staticTexts["document-pdf-zoom-summary"]
    XCTAssertTrue(zoomSummary.waitForExistence(timeout: 2), app.debugDescription)
    let initialZoomLabel = zoomSummary.label
    app.buttons["document-pdf-zoom-in-button"].click()
    XCTAssertTrue(
      waitForElementLabelToChange(zoomSummary, from: initialZoomLabel), app.debugDescription)
    XCTAssertTrue(zoomSummary.label.hasSuffix("%"), app.debugDescription)

    let searchField = app.textFields["document-pdf-search-field"]
    XCTAssertTrue(searchField.waitForExistence(timeout: 2), app.debugDescription)
    searchField.click()
    searchField.typeText("Page")

    let searchSummary = app.staticTexts["document-pdf-search-summary"]
    XCTAssertTrue(waitForElement(searchSummary, toHaveLabel: "1 of 2"), app.debugDescription)
    app.buttons["document-pdf-next-search-match-button"].click()
    XCTAssertTrue(waitForElement(searchSummary, toHaveLabel: "2 of 2"), app.debugDescription)
    app.buttons["document-pdf-next-search-match-button"].click()
    XCTAssertTrue(waitForElement(searchSummary, toHaveLabel: "1 of 2"), app.debugDescription)
  }

  @MainActor
  func testDoubleClickOfficeFilePreviewsInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
    let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
    let app = try launchApp(
      workspacePath: workspacePath,
      previewInvocationsKey: previewInvocationsKey,
      previewInvocationsFilePath: previewInvocationsFilePath
    )

    let officeRowText = app.staticTexts["valid.docx"]
    XCTAssertTrue(officeRowText.waitForExistence(timeout: 5), app.debugDescription)
    officeRowText.doubleClick()

    let quickLookSurface = app.descendants(matching: .any)["document-quicklook-surface"]
    XCTAssertTrue(quickLookSurface.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["valid.docx"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(
      previewInvocations(forKey: previewInvocationsKey, filePath: previewInvocationsFilePath), [])
  }

  @MainActor
  func testDoubleClickVideoFilePlaysVideoInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
    let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
    let app = try launchApp(
      workspacePath: workspacePath,
      previewInvocationsKey: previewInvocationsKey,
      previewInvocationsFilePath: previewInvocationsFilePath
    )

    let videoRowText = app.staticTexts["video-placeholder.mp4"]
    XCTAssertTrue(videoRowText.waitForExistence(timeout: 5), app.debugDescription)
    videoRowText.doubleClick()

    let videoSurface = app.descendants(matching: .any)["document-video-surface"]
    XCTAssertTrue(videoSurface.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["video-placeholder.mp4"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(
      previewInvocations(forKey: previewInvocationsKey, filePath: previewInvocationsFilePath), [])
  }

  @MainActor
  func testDoubleClickAudioFilePlaysAudioInLocus() throws {
    let workspacePath = try fixtureWorkspacePath("file-types")
    let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
    let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
    let app = try launchApp(
      workspacePath: workspacePath,
      previewInvocationsKey: previewInvocationsKey,
      previewInvocationsFilePath: previewInvocationsFilePath
    )

    let audioRowText = app.staticTexts["audio-placeholder.mp3"]
    XCTAssertTrue(audioRowText.waitForExistence(timeout: 5), app.debugDescription)
    audioRowText.doubleClick()

    let audioSurface = app.descendants(matching: .any)["document-audio-surface"]
    XCTAssertTrue(audioSurface.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["audio-placeholder.mp3"].waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertEqual(
      previewInvocations(forKey: previewInvocationsKey, filePath: previewInvocationsFilePath), [])
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
  func testUndecodableImageOffersQuickLookPreviewFallback() throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-invalid-image-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    filesToRemove.insert(workspaceURL.path(percentEncoded: false))

    let brokenImageURL = workspaceURL.appending(path: "broken.png")
    try Data("not an image".utf8).write(to: brokenImageURL)

    let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
    let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
    let app = try launchApp(
      workspacePath: workspaceURL.path(percentEncoded: false),
      previewInvocationsKey: previewInvocationsKey,
      previewInvocationsFilePath: previewInvocationsFilePath
    )

    let brokenImageRowText = app.staticTexts["broken.png"]
    XCTAssertTrue(brokenImageRowText.waitForExistence(timeout: 5), app.debugDescription)
    brokenImageRowText.doubleClick()

    XCTAssertTrue(
      app.descendants(matching: .any)["document-image-error-surface"].waitForExistence(timeout: 5),
      app.debugDescription)

    let previewButton = app.buttons["Preview"]
    XCTAssertTrue(previewButton.waitForExistence(timeout: 2), app.debugDescription)
    previewButton.click()

    XCTAssertTrue(
      waitForPreviewInvocation(
        brokenImageURL.path(percentEncoded: false),
        key: previewInvocationsKey,
        filePath: previewInvocationsFilePath
      ),
      app.debugDescription
    )
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

    let editor = app.textViews["document-text-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
    editor.click()

    let updatedText = "# Updated Brief\n\nLocus edits Markdown in app.\n"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(updatedText, forType: .string)
    app.typeKey("a", modifierFlags: [.command])
    app.typeKey("v", modifierFlags: [.command])

    XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 2), app.debugDescription)

    let saveButton = app.buttons["document-save-button"]
    XCTAssertTrue(saveButton.waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertTrue(saveButton.isEnabled, app.debugDescription)
    saveButton.click()

    XCTAssertTrue(waitForFileContents(updatedText, at: projectBriefURL), app.debugDescription)
  }

  @MainActor
  func testUnsavedMarkdownDraftSurvivesRowSelectionChanges() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let projectBriefURL = workspaceURL.appending(path: "Project Brief.md")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let projectBriefRow = app.outlines.firstMatch.cells
      .containing(NSPredicate(format: "value == %@", "Project Brief.md"))
      .firstMatch
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.click()

    let editor = app.textViews["document-text-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
    editor.click()

    let updatedText = "# Draft Survives\n\nThis edit is not saved yet.\n"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(updatedText, forType: .string)
    app.typeKey("a", modifierFlags: [.command])
    app.typeKey("v", modifierFlags: [.command])

    XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 2), app.debugDescription)

    let notesRow = app.outlines.firstMatch.cells
      .containing(NSPredicate(format: "value == %@", "Notes.txt"))
      .firstMatch
    XCTAssertTrue(notesRow.waitForExistence(timeout: 5), app.debugDescription)
    notesRow.click()

    XCTAssertFalse(waitForFileContents(updatedText, at: projectBriefURL, timeout: 0.5))

    projectBriefRow.click()
    XCTAssertTrue(app.staticTexts["Unsaved"].waitForExistence(timeout: 2), app.debugDescription)
    app.buttons["document-save-button"].click()

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

    let editor = app.textViews["document-text-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)

    let externalText = "# External Update\n\nChanged outside Locus.\n"
    try externalText.write(to: projectBriefURL, atomically: true, encoding: .utf8)

    XCTAssertTrue(
      waitForEditorContents(externalText, in: app, timeout: 5),
      app.debugDescription
    )

    let saveButton = app.buttons["document-save-button"]
    XCTAssertTrue(saveButton.waitForExistence(timeout: 2), app.debugDescription)
    XCTAssertFalse(saveButton.isEnabled, app.debugDescription)
  }

  @MainActor
  func testExternalTextChangeReplacesUnsavedEditorText() throws {
    let workspaceURL = try temporaryWorkspaceCopy(ofFixtureNamed: "basic")
    let projectBriefURL = workspaceURL.appending(path: "Project Brief.md")
    let app = try launchApp(workspacePath: workspaceURL.path(percentEncoded: false))

    let projectBriefRow = app.outlines.firstMatch.cells
      .containing(NSPredicate(format: "value == %@", "Project Brief.md"))
      .firstMatch
    XCTAssertTrue(projectBriefRow.waitForExistence(timeout: 5), app.debugDescription)
    projectBriefRow.click()

    let editor = app.textViews["document-text-editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5), app.debugDescription)
    editor.click()

    let userText = "# User Draft\n\nKeep this Locus edit.\n"
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(userText, forType: .string)
    app.typeKey("a", modifierFlags: [.command])
    app.typeKey("v", modifierFlags: [.command])

    let externalText = "# External Update\n\nChanged outside Locus.\n"
    try externalText.write(to: projectBriefURL, atomically: true, encoding: .utf8)

    XCTAssertTrue(
      waitForEditorContents(externalText, in: app, timeout: 5),
      app.debugDescription
    )
    XCTAssertFalse(app.staticTexts["Unsaved"].exists, app.debugDescription)
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
    let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
    let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
    let app = try launchApp(
      previewInvocationsKey: previewInvocationsKey,
      previewInvocationsFilePath: previewInvocationsFilePath,
      recentFiles: [recentFilePath]
    )

    let recentFile = app.buttons.matching(identifier: "recent-file-row").firstMatch
    XCTAssertTrue(recentFile.waitForExistence(timeout: 5), app.debugDescription)
    recentFile.click()

    XCTAssertTrue(app.staticTexts["basic"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Reports"].waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(
      app.staticTexts["Project Brief.md"].waitForExistence(timeout: 5), app.debugDescription)
    assertTableRow(named: "Project Brief.md", isSelectedIn: app)

    app.typeKey(.space, modifierFlags: [])

    XCTAssertTrue(
      waitForPreviewInvocation(
        recentFilePath,
        key: previewInvocationsKey,
        filePath: previewInvocationsFilePath
      ),
      app.debugDescription
    )
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
  func testRecentFileShortcutCanBePreviewedFromContextMenu() throws {
    let workspacePath = try fixtureWorkspacePath("basic")
    let recentFilePath = "\(workspacePath)/Project Brief.md"
    let previewInvocationsKey = "previewInvocations.uiTests.\(UUID().uuidString)"
    let previewInvocationsFilePath = temporaryPreviewInvocationsPath()
    let app = try launchApp(
      previewInvocationsKey: previewInvocationsKey,
      previewInvocationsFilePath: previewInvocationsFilePath,
      recentFiles: [recentFilePath]
    )

    let recentFile = app.buttons.matching(identifier: "recent-file-row").firstMatch
    XCTAssertTrue(recentFile.waitForExistence(timeout: 5), app.debugDescription)

    recentFile.rightClick()

    let previewMenuItem = app.menuItems["Preview"]
    XCTAssertTrue(previewMenuItem.waitForExistence(timeout: 2), app.debugDescription)
    // These actions intentionally stay out of the UI; keep assertions here
    // so future menu work does not reintroduce external handoff paths.
    XCTAssertFalse(app.menuItems["Reveal in Finder"].exists)
    XCTAssertFalse(app.menuItems["Open Externally"].exists)
    previewMenuItem.click()

    XCTAssertTrue(
      waitForPreviewInvocation(
        recentFilePath,
        key: previewInvocationsKey,
        filePath: previewInvocationsFilePath
      ),
      app.debugDescription
    )
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
  private func launchAppWithBasicWorkspace() throws -> XCUIApplication {
    try launchApp(workspacePath: fixtureWorkspacePath("basic"))
  }

  @MainActor
  private func launchApp(
    workspacePath: String? = nil,
    recentFilesKey: String = "recentFiles.uiTests.\(UUID().uuidString)",
    recentFoldersKey: String = "recentFolders.uiTests.\(UUID().uuidString)",
    previewInvocationsKey: String = "previewInvocations.uiTests.\(UUID().uuidString)",
    previewInvocationsFilePath: String? = nil,
    recentFiles: [String] = [],
    recentFolders: [String] = []
  ) throws -> XCUIApplication {
    let previewInvocationsFilePath = previewInvocationsFilePath ?? temporaryPreviewInvocationsPath()
    trackUserDefaultsKeys(
      recentFilesKey,
      recentFoldersKey,
      previewInvocationsKey
    )

    let app = XCUIApplication()
    app.launchEnvironment["LOCUS_UI_TESTING"] = "1"
    app.launchArguments = [
      "--ui-test-recent-files-key",
      recentFilesKey,
      "--ui-test-recent-folders-key",
      recentFoldersKey,
      "--ui-test-preview-invocations-key",
      previewInvocationsKey,
      "--ui-test-preview-invocations-file",
      previewInvocationsFilePath,
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
    for key in keys {
      userDefaultsKeysToRemove.insert(key)
    }
  }

  @MainActor
  private func assertTableRow(
    named name: String,
    isSelectedIn app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let nameCell = app.cells
      .containing(NSPredicate(format: "value == %@", name))
      .firstMatch
    XCTAssertTrue(
      nameCell.waitForExistence(timeout: 2), app.debugDescription, file: file, line: line)
    XCTAssertTrue(nameCell.isSelected, app.debugDescription, file: file, line: line)
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
    let editor = app.textViews["document-text-editor"]
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

  @MainActor
  private func waitForElement(
    _ element: XCUIElement,
    toHaveLabel expectedLabel: String,
    timeout: TimeInterval = 2
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.label == expectedLabel {
        return true
      }

      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    return false
  }

  @MainActor
  private func waitForElementLabelToChange(
    _ element: XCUIElement,
    from label: String,
    timeout: TimeInterval = 2
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if element.label != label {
        return true
      }

      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }

    return false
  }

  private func previewInvocations(forKey key: String, filePath: String) -> [String] {
    if let fileContents = try? String(contentsOfFile: filePath, encoding: .utf8),
      !fileContents.isEmpty
    {
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

  private func writeFixturePDF(pageCount: Int, to url: URL) throws {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw PDFFixtureWriteError()
    }

    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 420)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw PDFFixtureWriteError()
    }

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
      .paragraphStyle: paragraphStyle,
    ]

    for pageNumber in 1...pageCount {
      context.beginPDFPage(nil)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
      NSString(string: "Page \(pageNumber)")
        .draw(in: CGRect(x: 40, y: 190, width: 240, height: 60), withAttributes: attributes)
      NSGraphicsContext.restoreGraphicsState()
      context.endPDFPage()
    }

    context.closePDF()
    try data.write(to: url, options: .atomic)
  }
}

private struct FixtureLookupError: Error, CustomStringConvertible {
  let name: String
  let startPath: String

  var description: String {
    "Fixture workspace '\(name)' was not found from \(startPath)."
  }
}

private struct PDFFixtureWriteError: Error {}

extension XCUIElement {
  @MainActor
  fileprivate func waitForKeyboardFocus(timeout: TimeInterval) -> Bool {
    let predicate = NSPredicate(format: "hasKeyboardFocus == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
