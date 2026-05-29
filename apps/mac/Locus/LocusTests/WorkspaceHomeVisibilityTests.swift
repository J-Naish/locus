import XCTest

@testable import Locus

final class WorkspaceHomeVisibilityTests: XCTestCase {
  func testHidesDotFilesAndFoldersInHomeDirectory() {
    let homeURL = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    let snapshot = WorkspaceSnapshot(
      entries: [
        makeEntry(name: ".agents", folderURL: homeURL, kind: .directory),
        makeEntry(name: ".env", folderURL: homeURL, kind: .file),
        makeEntry(name: "Documents", folderURL: homeURL, kind: .directory),
        makeEntry(name: "notes.md", folderURL: homeURL, kind: .file),
      ],
      partialErrors: []
    )

    let filtered = WorkspaceHomeVisibility.filteredSnapshot(
      snapshot,
      folderURL: homeURL,
      homeDirectoryURL: homeURL
    )

    XCTAssertEqual(filtered.entries.map(\.name), ["Documents", "notes.md"])
  }

  func testKeepsDotFilesOutsideHomeDirectory() {
    let homeURL = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    let projectURL = URL(filePath: "/Users/tester/Projects/locus", directoryHint: .isDirectory)
    let snapshot = WorkspaceSnapshot(
      entries: [
        makeEntry(name: ".agents", folderURL: projectURL, kind: .directory),
        makeEntry(name: ".env", folderURL: projectURL, kind: .file),
        makeEntry(name: "project-brief.md", folderURL: projectURL, kind: .file),
      ],
      partialErrors: []
    )

    let filtered = WorkspaceHomeVisibility.filteredSnapshot(
      snapshot,
      folderURL: projectURL,
      homeDirectoryURL: homeURL
    )

    XCTAssertEqual(filtered.entries.map(\.name), [".agents", ".env", "project-brief.md"])
  }

  func testHidesFinderHiddenEntriesInHomeDirectory() {
    let homeURL = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    let snapshot = WorkspaceSnapshot(
      entries: [
        makeEntry(name: "Library", folderURL: homeURL, kind: .directory),
        makeEntry(name: "Downloads", folderURL: homeURL, kind: .directory),
      ],
      partialErrors: []
    )

    let filtered = WorkspaceHomeVisibility.filteredSnapshot(
      snapshot,
      folderURL: homeURL,
      homeDirectoryURL: homeURL,
      isHiddenResource: { $0.lastPathComponent == "Library" }
    )

    XCTAssertEqual(filtered.entries.map(\.name), ["Downloads"])
  }

  func testSuppressesPartialErrorsInHomeDirectory() {
    let homeURL = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    let partialError = WorkspacePartialError(
      id: "read-entry-0",
      kind: .readEntry,
      message: "failed to read folder entry"
    )
    let snapshot = WorkspaceSnapshot(
      entries: [makeEntry(name: ".env", folderURL: homeURL, kind: .file)],
      partialErrors: [partialError]
    )

    let filtered = WorkspaceHomeVisibility.filteredSnapshot(
      snapshot,
      folderURL: homeURL,
      homeDirectoryURL: homeURL
    )

    XCTAssertEqual(filtered.entries, [])
    XCTAssertEqual(filtered.partialErrors, [])
  }

  func testPreservesPartialErrorsOutsideHomeDirectory() {
    let homeURL = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    let projectURL = URL(filePath: "/Users/tester/Projects/locus", directoryHint: .isDirectory)
    let partialError = WorkspacePartialError(
      id: "read-entry-0",
      kind: .readEntry,
      message: "failed to read folder entry"
    )
    let snapshot = WorkspaceSnapshot(
      entries: [makeEntry(name: ".env", folderURL: projectURL, kind: .file)],
      partialErrors: [partialError]
    )

    let filtered = WorkspaceHomeVisibility.filteredSnapshot(
      snapshot,
      folderURL: projectURL,
      homeDirectoryURL: homeURL
    )

    XCTAssertEqual(filtered.entries.map(\.name), [".env"])
    XCTAssertEqual(filtered.partialErrors, [partialError])
  }

  func testIdentifiesHiddenImmediateHomeShortcutURLs() {
    let homeURL = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    XCTAssertTrue(
      WorkspaceHomeVisibility.isHiddenHomeURL(
        homeURL.appending(path: ".zshrc", directoryHint: .notDirectory),
        homeDirectoryURL: homeURL
      )
    )
    XCTAssertTrue(
      WorkspaceHomeVisibility.isHiddenHomeURL(
        homeURL.appending(path: "Library", directoryHint: .isDirectory),
        homeDirectoryURL: homeURL,
        isHiddenResource: { $0.lastPathComponent == "Library" }
      )
    )
    XCTAssertFalse(
      WorkspaceHomeVisibility.isHiddenHomeURL(
        homeURL.appending(path: "Documents", directoryHint: .isDirectory),
        homeDirectoryURL: homeURL
      )
    )
  }

  func testDoesNotTreatNestedDotFolderContentsAsImmediateHomeShortcuts() {
    let homeURL = URL(filePath: "/Users/tester", directoryHint: .isDirectory)
    let configURL =
      homeURL
      .appending(path: ".ssh", directoryHint: .isDirectory)
      .appending(path: "config", directoryHint: .notDirectory)

    XCTAssertFalse(
      WorkspaceHomeVisibility.isHiddenHomeURL(
        configURL,
        homeDirectoryURL: homeURL
      )
    )
  }

  private func makeEntry(
    name: String,
    folderURL: URL,
    kind: WorkspaceEntryKind
  ) -> WorkspaceEntry {
    let url = folderURL.appending(
      path: name, directoryHint: kind.isDirectoryLike ? .isDirectory : .notDirectory)
    return WorkspaceEntry(
      id: url.path(percentEncoded: false),
      url: url,
      name: name,
      kind: kind,
      fileType: .unknown,
      sizeBytes: nil,
      modified: nil,
      isReadOnly: false
    )
  }
}
