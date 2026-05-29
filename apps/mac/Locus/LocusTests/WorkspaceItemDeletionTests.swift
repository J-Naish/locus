import XCTest

@testable import Locus

final class WorkspaceItemDeletionTests: XCTestCase {
  func testMovesFileToTrash() throws {
    let folderURL = try temporaryDirectory()
    let fileURL = folderURL.appending(path: "notes.md")
    try "notes".write(to: fileURL, atomically: true, encoding: .utf8)

    var movedURLs: [URL] = []
    let deletedItems = try WorkspaceItemDeletion.delete(
      [makeEntry(url: fileURL, kind: .file)],
      in: folderURL,
      moveToTrash: { url in
        movedURLs.append(url)
        try FileManager.default.removeItem(at: url)
        return url
      }
    )

    XCTAssertEqual(
      deletedItems.map(\.originalURL.locusStandardizedPath), [fileURL.locusStandardizedPath])
    XCTAssertEqual(
      deletedItems.map(\.trashedURL.locusStandardizedPath), [fileURL.locusStandardizedPath])
    XCTAssertEqual(movedURLs.map(\.locusStandardizedPath), [fileURL.locusStandardizedPath])
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  func testMovesFolderToTrash() throws {
    let folderURL = try temporaryDirectory()
    let targetURL = folderURL.appending(path: "Drafts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)

    let deletedItems = try WorkspaceItemDeletion.delete(
      [makeEntry(url: targetURL, kind: .directory)],
      in: folderURL,
      moveToTrash: { url in
        try FileManager.default.removeItem(at: url)
        return url
      }
    )

    XCTAssertEqual(
      deletedItems.map(\.originalURL.locusStandardizedPath), [targetURL.locusStandardizedPath])
    XCTAssertFalse(FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)))
  }

  func testRejectsWorkspaceRoot() throws {
    let folderURL = try temporaryDirectory()

    XCTAssertThrowsError(
      try WorkspaceItemDeletion.delete([makeEntry(url: folderURL, kind: .directory)], in: folderURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemDeletionError, .cannotDeleteWorkspaceRoot)
    }
  }

  func testRejectsItemsOutsideWorkspace() throws {
    let folderURL = try temporaryDirectory()
    let outsideURL = FileManager.default.temporaryDirectory.appending(
      path: "locus-item-deletion-outside-\(UUID().uuidString)"
    )
    try "outside".write(to: outsideURL, atomically: true, encoding: .utf8)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: outsideURL)
    }

    XCTAssertThrowsError(
      try WorkspaceItemDeletion.delete([makeEntry(url: outsideURL, kind: .file)], in: folderURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemDeletionError, .outsideWorkspace)
    }
  }

  func testDeduplicatesRepeatedEntries() throws {
    let folderURL = try temporaryDirectory()
    let fileURL = folderURL.appending(path: "notes.md")
    try "notes".write(to: fileURL, atomically: true, encoding: .utf8)

    var movedURLs: [URL] = []
    _ = try WorkspaceItemDeletion.delete(
      [
        makeEntry(url: fileURL, kind: .file),
        makeEntry(url: fileURL, kind: .file),
      ],
      in: folderURL,
      moveToTrash: { url in
        movedURLs.append(url)
        try FileManager.default.removeItem(at: url)
        return url
      }
    )

    XCTAssertEqual(movedURLs.map(\.locusStandardizedPath), [fileURL.locusStandardizedPath])
  }

  func testDeletingEmptySelectionDoesNothing() throws {
    let folderURL = try temporaryDirectory()

    let deletedItems = try WorkspaceItemDeletion.delete([], in: folderURL)

    XCTAssertTrue(deletedItems.isEmpty)
  }

  func testReportsDeleteFailureWithItemName() throws {
    let folderURL = try temporaryDirectory()
    let fileURL = folderURL.appending(path: "notes.md")
    try "notes".write(to: fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(
      try WorkspaceItemDeletion.delete(
        [makeEntry(url: fileURL, kind: .file)],
        in: folderURL,
        moveToTrash: { _ in throw CocoaError(.fileWriteNoPermission) }
      )
    ) {
      XCTAssertEqual($0 as? WorkspaceItemDeletionError, .deleteFailed("notes.md"))
    }
  }

  func testReportsPartialFailureAfterMovingEarlierItems() throws {
    let folderURL = try temporaryDirectory()
    let firstURL = folderURL.appending(path: "first.md")
    let secondURL = folderURL.appending(path: "second.md")
    let thirdURL = folderURL.appending(path: "third.md")
    try "first".write(to: firstURL, atomically: true, encoding: .utf8)
    try "second".write(to: secondURL, atomically: true, encoding: .utf8)
    try "third".write(to: thirdURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(
      try WorkspaceItemDeletion.delete(
        [
          makeEntry(url: firstURL, kind: .file),
          makeEntry(url: secondURL, kind: .file),
          makeEntry(url: thirdURL, kind: .file),
        ],
        in: folderURL,
        moveToTrash: { url in
          if url.locusStandardizedPath == secondURL.locusStandardizedPath {
            throw CocoaError(.fileWriteNoPermission)
          }
          try FileManager.default.removeItem(at: url)
          return url
        }
      )
    ) {
      guard let error = $0 as? WorkspaceItemDeletionError,
        case .partiallyDeleted(let succeededItems, let failedName, let remainingCount) = error
      else {
        return XCTFail("Expected partial deletion error, got \($0)")
      }

      XCTAssertEqual(
        succeededItems.map(\.originalURL.locusStandardizedPath), [firstURL.locusStandardizedPath])
      XCTAssertEqual(failedName, "second.md")
      XCTAssertEqual(remainingCount, 1)
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path(percentEncoded: false)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path(percentEncoded: false)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: thirdURL.path(percentEncoded: false)))
  }

  func testMovesSymbolicLinkWithoutRemovingTarget() throws {
    let folderURL = try temporaryDirectory()
    let targetURL = folderURL.appending(path: "target.md")
    let linkURL = folderURL.appending(path: "link.md")
    try "target".write(to: targetURL, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    let deletedItems = try WorkspaceItemDeletion.delete(
      [makeEntry(url: linkURL, kind: .file)],
      in: folderURL,
      moveToTrash: { url in
        try FileManager.default.removeItem(at: url)
        return url
      }
    )

    XCTAssertEqual(
      deletedItems.map(\.originalURL.locusStandardizedPath), [linkURL.locusStandardizedPath])
    XCTAssertFalse(FileManager.default.fileExists(atPath: linkURL.path(percentEncoded: false)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path(percentEncoded: false)))
  }

  func testRestoresDeletedItemsFromTrashLocation() throws {
    let folderURL = try temporaryDirectory()
    let originalURL = folderURL.appending(path: "notes.md")
    let trashURL = folderURL.appending(path: ".Trash-notes.md")
    try "notes".write(to: trashURL, atomically: true, encoding: .utf8)

    let restoredURLs = try WorkspaceItemRestoration.restore([
      WorkspaceDeletedItem(originalURL: originalURL, trashedURL: trashURL)
    ])

    XCTAssertEqual(restoredURLs.map(\.locusStandardizedPath), [originalURL.locusStandardizedPath])
    XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path(percentEncoded: false)))
    XCTAssertFalse(FileManager.default.fileExists(atPath: trashURL.path(percentEncoded: false)))
  }

  func testDeletesURLsForUndoRedoPaths() throws {
    let folderURL = try temporaryDirectory()
    let fileURL = folderURL.appending(path: "notes.md")
    try "notes".write(to: fileURL, atomically: true, encoding: .utf8)

    let deletedItems = try WorkspaceItemDeletion.deleteURLs(
      [fileURL],
      in: folderURL,
      moveToTrash: { url in
        try FileManager.default.removeItem(at: url)
        return url
      }
    )

    XCTAssertEqual(
      deletedItems,
      [WorkspaceDeletedItem(originalURL: fileURL, trashedURL: fileURL)]
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)))
  }

  func testReportsPartialFailureAfterRestoringEarlierItems() throws {
    let folderURL = try temporaryDirectory()
    let firstOriginalURL = folderURL.appending(path: "first.md")
    let secondOriginalURL = folderURL.appending(path: "second.md")
    let thirdOriginalURL = folderURL.appending(path: "third.md")
    let firstTrashURL = folderURL.appending(path: ".Trash-first.md")
    let secondTrashURL = folderURL.appending(path: ".Trash-second.md")
    let thirdTrashURL = folderURL.appending(path: ".Trash-third.md")

    XCTAssertThrowsError(
      try WorkspaceItemRestoration.restore(
        [
          WorkspaceDeletedItem(originalURL: firstOriginalURL, trashedURL: firstTrashURL),
          WorkspaceDeletedItem(originalURL: secondOriginalURL, trashedURL: secondTrashURL),
          WorkspaceDeletedItem(originalURL: thirdOriginalURL, trashedURL: thirdTrashURL),
        ],
        moveFromTrash: { trashURL, originalURL in
          if trashURL.locusStandardizedPath == secondTrashURL.locusStandardizedPath {
            throw CocoaError(.fileWriteNoPermission)
          }
          try "restored".write(to: originalURL, atomically: true, encoding: .utf8)
        }
      )
    ) {
      guard let error = $0 as? WorkspaceItemRestorationError,
        case .partiallyRestored(let succeededURLs, let failedName, let remainingCount) = error
      else {
        return XCTFail("Expected partial restoration error, got \($0)")
      }

      XCTAssertEqual(
        succeededURLs.map(\.locusStandardizedPath), [firstOriginalURL.locusStandardizedPath])
      XCTAssertEqual(failedName, "second.md")
      XCTAssertEqual(remainingCount, 1)
    }

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: firstOriginalURL.path(percentEncoded: false)))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: secondOriginalURL.path(percentEncoded: false)))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: thirdOriginalURL.path(percentEncoded: false)))
  }

  private func makeEntry(url: URL, kind: WorkspaceEntryKind) -> WorkspaceEntry {
    WorkspaceEntry(
      id: url.locusStandardizedPath,
      url: url,
      name: url.lastPathComponent,
      kind: kind,
      fileType: .plainText,
      sizeBytes: nil,
      modified: nil,
      isReadOnly: false
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "locus-item-deletion-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }
}
