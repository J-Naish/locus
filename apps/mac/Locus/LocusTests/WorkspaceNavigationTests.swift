import XCTest

@testable import Locus

final class WorkspaceNavigationTests: XCTestCase {
  func testNavigationHistoryRecordsCurrentEntryWhenNavigatingToNewFolder() {
    let root = historyEntry("/workspace")
    let reports = historyEntry("/workspace/Reports")
    var history = WorkspaceNavigationHistory()

    history.recordNavigation(from: root, to: reports)

    XCTAssertEqual(history.previousEntry, root)
    XCTAssertTrue(history.canGoBack)
    XCTAssertFalse(history.canGoForward)
  }

  func testNavigationHistoryCanMoveBackMultipleTimes() {
    let root = historyEntry("/workspace")
    let reports = historyEntry("/workspace/Reports")
    let archive = historyEntry("/workspace/Reports/Archive")
    var history = WorkspaceNavigationHistory()

    history.recordNavigation(from: root, to: reports)
    history.recordNavigation(from: reports, to: archive)

    XCTAssertEqual(history.previousEntry, reports)
    history.commitBackNavigation(from: archive)

    XCTAssertEqual(history.previousEntry, root)
    XCTAssertEqual(history.nextEntry, archive)
    history.commitBackNavigation(from: reports)

    XCTAssertNil(history.previousEntry)
    XCTAssertEqual(history.nextEntry, reports)
  }

  func testNavigationHistoryCanMoveForwardAfterMovingBack() {
    let root = historyEntry("/workspace")
    let reports = historyEntry("/workspace/Reports")
    let archive = historyEntry("/workspace/Reports/Archive")
    var history = WorkspaceNavigationHistory()

    history.recordNavigation(from: root, to: reports)
    history.recordNavigation(from: reports, to: archive)
    history.commitBackNavigation(from: archive)

    XCTAssertEqual(history.nextEntry, archive)
    history.commitForwardNavigation(from: reports)

    XCTAssertEqual(history.previousEntry, reports)
    XCTAssertNil(history.nextEntry)
  }

  func testNavigationHistoryClearsForwardStackAfterNewNavigation() {
    let root = historyEntry("/workspace")
    let reports = historyEntry("/workspace/Reports")
    let archive = historyEntry("/workspace/Reports/Archive")
    let clientFiles = historyEntry("/workspace/Client Files")
    var history = WorkspaceNavigationHistory()

    history.recordNavigation(from: root, to: reports)
    history.recordNavigation(from: reports, to: archive)
    history.commitBackNavigation(from: archive)
    history.recordNavigation(from: reports, to: clientFiles)

    XCTAssertEqual(history.previousEntry, reports)
    XCTAssertNil(history.nextEntry)
  }

  func testNavigationHistoryDoesNotRecordSameFolderReloads() {
    let root = historyEntry("/workspace")
    let sameRoot = historyEntry("/workspace", selectedPath: "/workspace/Notes.txt")
    var history = WorkspaceNavigationHistory()

    history.recordNavigation(from: root, to: sameRoot)

    XCTAssertFalse(history.canGoBack)
    XCTAssertNil(history.previousEntry)
  }

  func testNavigationHistoryPreservesRootAndSelectedURL() {
    let entry = historyEntry(
      "/workspace/Reports",
      rootPath: "/workspace",
      selectedPath: "/workspace/Reports/report.md"
    )

    XCTAssertEqual(entry.rootURL, URL(filePath: "/workspace", directoryHint: .isDirectory))
    XCTAssertEqual(entry.selectedURL, URL(filePath: "/workspace/Reports/report.md"))
  }

  func testParentFolderURLReturnsParentForNestedFolder() {
    let folderURL = URL(filePath: "/Users/nash/dev", directoryHint: .isDirectory)

    XCTAssertEqual(
      WorkspaceNavigation.parentFolderURL(for: folderURL),
      URL(filePath: "/Users/nash", directoryHint: .isDirectory)
    )
  }

  func testParentFolderURLReturnsNilForRoot() {
    let folderURL = URL(filePath: "/", directoryHint: .isDirectory)

    XCTAssertNil(WorkspaceNavigation.parentFolderURL(for: folderURL))
  }

  func testParentFolderURLNormalizesTrailingSlash() {
    let folderURL = URL(filePath: "/Users/nash/dev/", directoryHint: .isDirectory)

    XCTAssertEqual(
      WorkspaceNavigation.parentFolderURL(for: folderURL),
      URL(filePath: "/Users/nash", directoryHint: .isDirectory)
    )
  }

  func testParentFolderURLReturnsRootForSinglePathComponent() {
    let folderURL = URL(filePath: "/Users", directoryHint: .isDirectory)

    XCTAssertEqual(
      WorkspaceNavigation.parentFolderURL(for: folderURL),
      URL(filePath: "/", directoryHint: .isDirectory)
    )
  }

  func testParentFolderURLDoesNotEscapeRootFolder() {
    let rootURL = URL(filePath: "/Users/nash", directoryHint: .isDirectory)
    let childURL = URL(filePath: "/Users/nash/dev", directoryHint: .isDirectory)

    XCTAssertEqual(
      WorkspaceNavigation.parentFolderURL(for: childURL, within: rootURL),
      rootURL
    )
    XCTAssertNil(WorkspaceNavigation.parentFolderURL(for: rootURL, within: rootURL))
  }

  func testParentFolderURLDoesNotTreatSiblingPrefixAsRoot() {
    let rootURL = URL(filePath: "/Users/nash/dev", directoryHint: .isDirectory)
    let siblingPrefixURL = URL(
      filePath: "/Users/nash/dev-other/project", directoryHint: .isDirectory)

    XCTAssertNil(WorkspaceNavigation.parentFolderURL(for: siblingPrefixURL, within: rootURL))
  }

  func testPathPrefixMatchesRootAndExactPaths() {
    XCTAssertTrue("/Users/nash".locusHasPathPrefix("/"))
    XCTAssertTrue("/Users/nash".locusHasPathPrefix("/Users/nash"))
  }

  func testPathPrefixMatchesNestedPathsWithOrWithoutTrailingSlash() {
    XCTAssertTrue("/Users/nash/dev/locus".locusHasPathPrefix("/Users/nash"))
    XCTAssertTrue("/Users/nash/dev/locus".locusHasPathPrefix("/Users/nash/"))
  }

  func testPathPrefixDoesNotMatchSiblingNames() {
    XCTAssertFalse("/Users/nashville/project".locusHasPathPrefix("/Users/nash"))
  }

  private func historyEntry(
    _ folderPath: String,
    rootPath: String? = nil,
    selectedPath: String? = nil
  ) -> WorkspaceHistoryEntry {
    WorkspaceHistoryEntry(
      folderURL: URL(filePath: folderPath, directoryHint: .isDirectory),
      rootURL: rootPath.map { URL(filePath: $0, directoryHint: .isDirectory) },
      selectedURL: selectedPath.map { URL(filePath: $0) }
    )
  }
}
