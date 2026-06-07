import XCTest

@testable import Locus

final class WorkspaceItemMoveTests: XCTestCase {
  func testPlannedMovesProducesDestinationInsideTargetFolder() throws {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let source = URL(filePath: "/tmp/locus/notes.md")
    let target = URL(filePath: "/tmp/locus/Drafts")

    let planned = try WorkspaceItemMove.plannedMoves(
      for: [source], into: target, workspaceURL: workspaceURL)

    XCTAssertEqual(planned.count, 1)
    XCTAssertEqual(planned[0].sourceURL.locusStandardizedPath, source.locusStandardizedPath)
    XCTAssertEqual(
      planned[0].destinationURL.locusStandardizedPath, "/tmp/locus/Drafts/notes.md")
  }

  func testPlannedMovesRejectsWorkspaceRoot() {
    let workspaceURL = URL(filePath: "/tmp/locus")

    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedMoves(
        for: [workspaceURL], into: URL(filePath: "/tmp/locus/Drafts"), workspaceURL: workspaceURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .cannotMoveWorkspaceRoot)
    }
  }

  func testPlannedMovesRejectsSourceOutsideWorkspace() {
    let workspaceURL = URL(filePath: "/tmp/locus")

    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedMoves(
        for: [URL(filePath: "/tmp/other/file.md")],
        into: URL(filePath: "/tmp/locus/Drafts"),
        workspaceURL: workspaceURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .outsideWorkspace)
    }
  }

  func testPlannedMovesRejectsTargetOutsideWorkspace() {
    let workspaceURL = URL(filePath: "/tmp/locus")

    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedMoves(
        for: [URL(filePath: "/tmp/locus/file.md")],
        into: URL(filePath: "/tmp/other"),
        workspaceURL: workspaceURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .outsideWorkspace)
    }
  }

  func testPlannedMovesRejectsMovingFolderIntoItself() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let folder = URL(filePath: "/tmp/locus/Reports")

    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedMoves(for: [folder], into: folder, workspaceURL: workspaceURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .moveIntoSelf)
    }
  }

  func testPlannedMovesRejectsMovingFolderIntoItsDescendant() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let folder = URL(filePath: "/tmp/locus/Reports")
    let descendant = URL(filePath: "/tmp/locus/Reports/2026")

    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedMoves(
        for: [folder], into: descendant, workspaceURL: workspaceURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .moveIntoSelf)
    }
  }

  func testPlannedMovesSkipsItemsAlreadyInTargetFolder() throws {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let source = URL(filePath: "/tmp/locus/Drafts/notes.md")
    let target = URL(filePath: "/tmp/locus/Drafts")

    let planned = try WorkspaceItemMove.plannedMoves(
      for: [source], into: target, workspaceURL: workspaceURL)

    XCTAssertTrue(planned.isEmpty)
  }

  func testPlannedMovesDeduplicatesRepeatedSources() throws {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let source = URL(filePath: "/tmp/locus/notes.md")
    let target = URL(filePath: "/tmp/locus/Drafts")

    let planned = try WorkspaceItemMove.plannedMoves(
      for: [source, source], into: target, workspaceURL: workspaceURL)

    XCTAssertEqual(planned.count, 1)
  }

  func testDisambiguatedURLReturnsSameURLWhenNoCollision() {
    let url = URL(filePath: "/tmp/locus/notes.md")

    let resolved = WorkspaceItemMove.disambiguatedURL(for: url) { _ in false }

    XCTAssertEqual(resolved.locusStandardizedPath, url.locusStandardizedPath)
  }

  func testDisambiguatedURLAppendsCounterBeforeExtension() {
    let url = URL(filePath: "/tmp/locus/notes.md")
    let taken: Set<String> = ["/tmp/locus/notes.md"]

    let resolved = WorkspaceItemMove.disambiguatedURL(for: url) {
      taken.contains($0.locusStandardizedPath)
    }

    XCTAssertEqual(resolved.locusStandardizedPath, "/tmp/locus/notes 2.md")
  }

  func testDisambiguatedURLSkipsTakenCounters() {
    let url = URL(filePath: "/tmp/locus/notes.md")
    let taken: Set<String> = [
      "/tmp/locus/notes.md",
      "/tmp/locus/notes 2.md",
    ]

    let resolved = WorkspaceItemMove.disambiguatedURL(for: url) {
      taken.contains($0.locusStandardizedPath)
    }

    XCTAssertEqual(resolved.locusStandardizedPath, "/tmp/locus/notes 3.md")
  }

  func testDisambiguatedURLHandlesNamesWithoutExtension() {
    let url = URL(filePath: "/tmp/locus/Drafts")
    let taken: Set<String> = ["/tmp/locus/Drafts"]

    let resolved = WorkspaceItemMove.disambiguatedURL(for: url) {
      taken.contains($0.locusStandardizedPath)
    }

    XCTAssertEqual(resolved.locusStandardizedPath, "/tmp/locus/Drafts 2")
  }

  func testMovesFileIntoTargetFolderOnDisk() throws {
    let workspaceURL = try temporaryDirectory()
    let sourceURL = workspaceURL.appending(path: "notes.md")
    let targetURL = workspaceURL.appending(path: "Drafts", directoryHint: .isDirectory)
    try "notes".write(to: sourceURL, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)

    let planned = try WorkspaceItemMove.plannedMoves(
      for: [sourceURL], into: targetURL, workspaceURL: workspaceURL)
    let execution = WorkspaceItemMove.move(planned)

    let expectedURL = targetURL.appending(path: "notes.md")
    XCTAssertNil(execution.failure)
    XCTAssertEqual(
      execution.moved.map(\.originalURL.locusStandardizedPath), [sourceURL.locusStandardizedPath])
    XCTAssertEqual(
      execution.moved.map(\.newURL.locusStandardizedPath), [expectedURL.locusStandardizedPath])
    XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path(percentEncoded: false)))
  }

  func testMoveCanBeReversedForUndo() throws {
    let workspaceURL = try temporaryDirectory()
    let sourceURL = workspaceURL.appending(path: "notes.md")
    let targetURL = workspaceURL.appending(path: "Drafts", directoryHint: .isDirectory)
    try "notes".write(to: sourceURL, atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)

    let planned = try WorkspaceItemMove.plannedMoves(
      for: [sourceURL], into: targetURL, workspaceURL: workspaceURL)
    let execution = WorkspaceItemMove.move(planned)

    let reverse = execution.moved.map {
      WorkspacePlannedMove(sourceURL: $0.newURL, destinationURL: $0.originalURL)
    }
    _ = WorkspaceItemMove.move(reverse)

    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: targetURL.appending(path: "notes.md").path(percentEncoded: false)))
  }

  func testMoveSurfacesCollisionAsNameCollision() {
    let planned = [
      WorkspacePlannedMove(
        sourceURL: URL(filePath: "/tmp/locus/notes.md"),
        destinationURL: URL(filePath: "/tmp/locus/Drafts/notes.md"))
    ]

    let execution = WorkspaceItemMove.move(
      planned,
      moveItem: { _, _ in throw CocoaError(.fileWriteFileExists) }
    )

    XCTAssertTrue(execution.moved.isEmpty)
    XCTAssertEqual(execution.failure, .nameCollision("notes.md"))
  }

  func testMoveReportsPartialSuccessWithFailingItem() {
    let firstSource = URL(filePath: "/tmp/locus/first.md")
    let planned = [
      WorkspacePlannedMove(
        sourceURL: firstSource, destinationURL: URL(filePath: "/tmp/locus/Drafts/first.md")),
      WorkspacePlannedMove(
        sourceURL: URL(filePath: "/tmp/locus/second.md"),
        destinationURL: URL(filePath: "/tmp/locus/Drafts/second.md")),
    ]

    let execution = WorkspaceItemMove.move(
      planned,
      moveItem: { source, _ in
        if source.lastPathComponent == "second.md" {
          throw CocoaError(.fileWriteNoPermission)
        }
      }
    )

    XCTAssertEqual(
      execution.moved.map(\.originalURL.locusStandardizedPath), [firstSource.locusStandardizedPath])
    XCTAssertEqual(execution.failure, .moveFailed("second.md"))
  }

  func testReplaceTrashesExistingDestinationAndRecordsIt() {
    var trashed: [URL] = []
    let planned = [
      WorkspacePlannedMove(
        sourceURL: URL(filePath: "/tmp/locus/notes.md"),
        destinationURL: URL(filePath: "/tmp/locus/Drafts/notes.md"),
        replacesExisting: true)
    ]

    let execution = WorkspaceItemMove.move(
      planned,
      moveItem: { _, _ in },
      trashItem: { url in
        trashed.append(url)
        return URL(filePath: "/tmp/.Trash/notes.md")
      },
      restoreItem: { _, _ in XCTFail("restore should not run on success") }
    )

    XCTAssertNil(execution.failure)
    XCTAssertEqual(trashed.map(\.locusStandardizedPath), ["/tmp/locus/Drafts/notes.md"])
    XCTAssertEqual(
      execution.replacedTrashed.map(\.originalURL.locusStandardizedPath),
      ["/tmp/locus/Drafts/notes.md"])
    XCTAssertEqual(execution.moved.count, 1)
  }

  func testReplaceRestoresTrashedDestinationWhenMoveFails() {
    var restored: [(URL, URL)] = []
    let planned = [
      WorkspacePlannedMove(
        sourceURL: URL(filePath: "/tmp/locus/notes.md"),
        destinationURL: URL(filePath: "/tmp/locus/Drafts/notes.md"),
        replacesExisting: true)
    ]

    let execution = WorkspaceItemMove.move(
      planned,
      moveItem: { _, _ in throw CocoaError(.fileWriteNoPermission) },
      trashItem: { _ in URL(filePath: "/tmp/.Trash/notes.md") },
      restoreItem: { trashURL, originalURL in restored.append((trashURL, originalURL)) }
    )

    XCTAssertTrue(execution.moved.isEmpty)
    XCTAssertTrue(execution.replacedTrashed.isEmpty)
    XCTAssertEqual(execution.failure, .moveFailed("notes.md"))
    XCTAssertEqual(restored.count, 1)
    XCTAssertEqual(restored.first?.0.locusStandardizedPath, "/tmp/.Trash/notes.md")
    XCTAssertEqual(restored.first?.1.locusStandardizedPath, "/tmp/locus/Drafts/notes.md")
  }

  func testPlannedImportsPlacesExternalSourcesIntoTarget() throws {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let external = URL(filePath: "/tmp/downloads/photo.png")
    let target = URL(filePath: "/tmp/locus/Assets")

    let planned = try WorkspaceItemMove.plannedImports(
      for: [external], into: target, workspaceURL: workspaceURL)

    XCTAssertEqual(planned.count, 1)
    XCTAssertEqual(
      planned[0].destinationURL.locusStandardizedPath, "/tmp/locus/Assets/photo.png")
  }

  func testPlannedImportsRejectsTargetOutsideWorkspace() {
    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedImports(
        for: [URL(filePath: "/tmp/downloads/photo.png")],
        into: URL(filePath: "/tmp/other"),
        workspaceURL: URL(filePath: "/tmp/locus"))
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .outsideWorkspace)
    }
  }

  func testCopiesExternalFileIntoTargetFolderOnDisk() throws {
    let workspaceURL = try temporaryDirectory()
    let externalDirectory = try temporaryDirectory()
    let sourceURL = externalDirectory.appending(path: "photo.txt")
    try "photo".write(to: sourceURL, atomically: true, encoding: .utf8)

    let planned = try WorkspaceItemMove.plannedImports(
      for: [sourceURL], into: workspaceURL, workspaceURL: workspaceURL)
    let execution = WorkspaceItemMove.copy(planned)

    let expectedURL = workspaceURL.appending(path: "photo.txt")
    XCTAssertNil(execution.failure)
    XCTAssertEqual(
      execution.moved.map(\.newURL.locusStandardizedPath), [expectedURL.locusStandardizedPath])
    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path(percentEncoded: false)))
    XCTAssertTrue(FileManager.default.fileExists(atPath: expectedURL.path(percentEncoded: false)))
  }

  // MARK: - partitionByWorkspace

  func testPartitionByWorkspaceSplitsInternalAndExternalURLs() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let inside = URL(filePath: "/tmp/locus/notes.md")
    let insideNested = URL(filePath: "/tmp/locus/Drafts/outline.md")
    let outside = URL(filePath: "/tmp/other/file.md")

    let (internalURLs, externalURLs) = WorkspaceItemMove.partitionByWorkspace(
      [inside, outside, insideNested], workspaceURL: workspaceURL)

    XCTAssertEqual(
      internalURLs.map(\.locusStandardizedPath),
      [inside.locusStandardizedPath, insideNested.locusStandardizedPath])
    XCTAssertEqual(externalURLs.map(\.locusStandardizedPath), [outside.locusStandardizedPath])
  }

  func testPartitionByWorkspaceTreatsSymlinkedDirectoryEscapeAsExternal() throws {
    let root = try temporaryDirectory()
    let workspaceURL = root.appending(path: "workspace", directoryHint: .isDirectory)
    let outsideURL = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
    let secretURL = outsideURL.appending(path: "secret.txt")
    try "secret".write(to: secretURL, atomically: true, encoding: .utf8)

    // A symlinked directory inside the workspace that points outside it.
    let linkURL = workspaceURL.appending(path: "escape", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

    // A path that only lexically sits under the workspace but resolves outside.
    let throughLink = linkURL.appending(path: "secret.txt")

    let (internalURLs, externalURLs) = WorkspaceItemMove.partitionByWorkspace(
      [throughLink], workspaceURL: workspaceURL)

    XCTAssertTrue(internalURLs.isEmpty)
    XCTAssertEqual(externalURLs, [throughLink])
  }

  func testPartitionByWorkspaceTreatsSymlinkFileInsideWorkspaceAsInternal() throws {
    let root = try temporaryDirectory()
    let workspaceURL = root.appending(path: "workspace", directoryHint: .isDirectory)
    let outsideURL = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
    let targetURL = outsideURL.appending(path: "target.txt")
    try "target".write(to: targetURL, atomically: true, encoding: .utf8)

    // A symlink file living inside the workspace pointing outside it. Dragging it
    // should move the link itself, so it stays an internal operation.
    let linkURL = workspaceURL.appending(path: "alias.txt")
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)

    let (internalURLs, externalURLs) = WorkspaceItemMove.partitionByWorkspace(
      [linkURL], workspaceURL: workspaceURL)

    XCTAssertEqual(internalURLs, [linkURL])
    XCTAssertTrue(externalURLs.isEmpty)
  }

  func testPlannedMovesRejectsTargetReachedThroughSymlinkedDirectoryEscape() throws {
    let root = try temporaryDirectory()
    let workspaceURL = root.appending(path: "workspace", directoryHint: .isDirectory)
    let outsideURL = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
    let sourceURL = workspaceURL.appending(path: "notes.md")
    try "notes".write(to: sourceURL, atomically: true, encoding: .utf8)

    // A symlinked directory inside the workspace that points outside it. Using
    // it as the move destination would write the file outside the workspace, so
    // it must be rejected rather than treated as a lexically internal target.
    let linkURL = workspaceURL.appending(path: "escape", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedMoves(
        for: [sourceURL], into: linkURL, workspaceURL: workspaceURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .outsideWorkspace)
    }
  }

  func testPlannedMovesRejectsSourceReachedThroughSymlinkedDirectoryEscape() throws {
    let root = try temporaryDirectory()
    let workspaceURL = root.appending(path: "workspace", directoryHint: .isDirectory)
    let outsideURL = root.appending(path: "outside", directoryHint: .isDirectory)
    let targetURL = workspaceURL.appending(path: "Drafts", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: false)
    let secretURL = outsideURL.appending(path: "secret.txt")
    try "secret".write(to: secretURL, atomically: true, encoding: .utf8)

    // The source is reached through a symlinked directory that escapes the
    // workspace, so moving it would act on a file that lives outside.
    let linkURL = workspaceURL.appending(path: "escape", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)
    let throughLink = linkURL.appending(path: "secret.txt")

    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedMoves(
        for: [throughLink], into: targetURL, workspaceURL: workspaceURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .outsideWorkspace)
    }
  }

  func testPlannedImportsRejectsTargetReachedThroughSymlinkedDirectoryEscape() throws {
    let root = try temporaryDirectory()
    let workspaceURL = root.appending(path: "workspace", directoryHint: .isDirectory)
    let outsideURL = root.appending(path: "outside", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: false)
    let externalURL = root.appending(path: "photo.png")
    try Data().write(to: externalURL)

    let linkURL = workspaceURL.appending(path: "escape", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideURL)

    XCTAssertThrowsError(
      try WorkspaceItemMove.plannedImports(
        for: [externalURL], into: linkURL, workspaceURL: workspaceURL)
    ) {
      XCTAssertEqual($0 as? WorkspaceItemMoveError, .outsideWorkspace)
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "locus-item-move-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }
}
