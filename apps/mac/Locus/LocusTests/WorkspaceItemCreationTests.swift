import XCTest

@testable import Locus

final class WorkspaceItemCreationTests: XCTestCase {
  func testCreatesEmptyFileInWorkspaceFolder() throws {
    let folderURL = try temporaryDirectory()

    let createdURL = try WorkspaceItemCreation.create(.file, named: "notes.md", in: folderURL)

    XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path(percentEncoded: false)))
    XCTAssertEqual(try Data(contentsOf: createdURL), Data())
  }

  func testCreatesFolderInWorkspaceFolder() throws {
    let folderURL = try temporaryDirectory()

    let createdURL = try WorkspaceItemCreation.create(.folder, named: "Drafts", in: folderURL)

    var isDirectory = ObjCBool(false)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: createdURL.path(percentEncoded: false),
        isDirectory: &isDirectory
      )
    )
    XCTAssertTrue(isDirectory.boolValue)
  }

  func testCreatesUnicodeFileName() throws {
    let folderURL = try temporaryDirectory()

    let createdURL = try WorkspaceItemCreation.create(.file, named: "請求書-メモ.md", in: folderURL)

    XCTAssertEqual(createdURL.lastPathComponent, "請求書-メモ.md")
    XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path(percentEncoded: false)))
  }

  func testTrimsWhitespaceFromCreatedName() throws {
    let folderURL = try temporaryDirectory()

    let createdURL = try WorkspaceItemCreation.create(.file, named: "  .gitignore  ", in: folderURL)

    XCTAssertEqual(createdURL.lastPathComponent, ".gitignore")
    XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path(percentEncoded: false)))
  }

  func testRejectsEmptyName() throws {
    let folderURL = try temporaryDirectory()

    XCTAssertThrowsError(try WorkspaceItemCreation.create(.file, named: " \n ", in: folderURL)) {
      XCTAssertEqual($0 as? WorkspaceItemCreationError, .emptyName)
    }
  }

  func testRejectsNestedPathName() throws {
    let folderURL = try temporaryDirectory()

    XCTAssertThrowsError(
      try WorkspaceItemCreation.create(.file, named: "Notes/today.md", in: folderURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemCreationError, .nestedPath)
    }
  }

  func testRejectsDotPathName() throws {
    let folderURL = try temporaryDirectory()

    XCTAssertThrowsError(try WorkspaceItemCreation.create(.folder, named: "..", in: folderURL)) {
      XCTAssertEqual($0 as? WorkspaceItemCreationError, .nestedPath)
    }
  }

  func testRejectsInvalidCharacters() throws {
    let folderURL = try temporaryDirectory()

    XCTAssertThrowsError(try WorkspaceItemCreation.create(.file, named: "bad:name", in: folderURL))
    {
      XCTAssertEqual($0 as? WorkspaceItemCreationError, .invalidCharacters)
    }
    XCTAssertThrowsError(
      try WorkspaceItemCreation.create(.file, named: "bad\u{0001}name", in: folderURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemCreationError, .invalidCharacters)
    }
  }

  func testRejectsTooLongName() throws {
    let folderURL = try temporaryDirectory()
    let longName = String(repeating: "a", count: 256)

    XCTAssertThrowsError(try WorkspaceItemCreation.create(.file, named: longName, in: folderURL)) {
      XCTAssertEqual($0 as? WorkspaceItemCreationError, .nameTooLong)
    }
  }

  func testRejectsExistingItem() throws {
    let folderURL = try temporaryDirectory()
    let existingURL = folderURL.appending(path: "Drafts")
    try "keep me".write(to: existingURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try WorkspaceItemCreation.create(.file, named: "Drafts", in: folderURL)) {
      XCTAssertEqual($0 as? WorkspaceItemCreationError, .alreadyExists("Drafts"))
    }
    XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "keep me")
  }

  func testRejectsExistingFolder() throws {
    let folderURL = try temporaryDirectory()
    _ = try WorkspaceItemCreation.create(.folder, named: "Drafts", in: folderURL)

    XCTAssertThrowsError(try WorkspaceItemCreation.create(.folder, named: "Drafts", in: folderURL))
    {
      XCTAssertEqual($0 as? WorkspaceItemCreationError, .alreadyExists("Drafts"))
    }
  }

  func testFileCreationPlaceholderIsInsertedAtFirstFilePosition() {
    let entries = [
      makeEntry(name: "Alpha", kind: .directory),
      makeEntry(name: "Linked Folder", kind: .symlinkToDirectory),
      makeEntry(name: "Notes.md", kind: .file),
      makeEntry(name: "Archive", kind: .other),
    ]

    XCTAssertEqual(
      WorkspaceItemCreationPlacement.insertionIndex(for: .file, in: entries),
      2
    )
  }

  func testFileCreationPlaceholderIsAppendedWhenFolderHasNoFiles() {
    let entries = [
      makeEntry(name: "Alpha", kind: .directory),
      makeEntry(name: "Linked Folder", kind: .symlinkToDirectory),
    ]

    XCTAssertEqual(
      WorkspaceItemCreationPlacement.insertionIndex(for: .file, in: entries),
      2
    )
  }

  func testFolderCreationPlaceholderStaysAtStartOfFolderGroup() {
    let entries = [
      makeEntry(name: "Alpha", kind: .directory),
      makeEntry(name: "Notes.md", kind: .file),
    ]

    XCTAssertEqual(
      WorkspaceItemCreationPlacement.insertionIndex(for: .folder, in: entries),
      0
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "locus-item-creation-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private func makeEntry(name: String, kind: WorkspaceEntryKind) -> WorkspaceEntry {
    let url = URL(filePath: "/tmp/locus-item-creation-tests/\(name)")
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
