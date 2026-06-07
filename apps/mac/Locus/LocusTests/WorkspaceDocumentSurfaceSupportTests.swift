import XCTest

@testable import Locus

final class WorkspaceDocumentSurfaceSupportTests: XCTestCase {
  func testTextFilesUseEditableTextSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "notes.md", fileType: .markdown)),
      .editableText
    )
  }

  func testUnknownFilesTryEditableTextSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: ".customignore", fileType: .unknown)),
      .editableText
    )
  }

  func testRasterImagesUseImageSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "photo.png", fileType: .image)),
      .image
    )
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "photo.jpg", fileType: .image)),
      .image
    )
  }

  func testVectorImagesUseUnsupportedSurfaceForQuickLookFallback() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "diagram.svg", fileType: .image)),
      .unsupported
    )
  }

  func testPDFsUsePDFSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "brief.pdf", fileType: .pdf)),
      .pdf
    )
  }

  func testVideoFilesUseVideoSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "clip.mp4", fileType: .video)),
      .video
    )
  }

  func testAudioFilesUseAudioSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "voice.mp3", fileType: .audio)),
      .audio
    )
  }

  func testOfficeFilesUseQuickLookPreviewSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "deck.pptx", fileType: .office)),
      .quickLookPreview
    )
  }

  func testDirectoriesUseFolderSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "Reports", kind: .directory, fileType: .unknown)
      ),
      .folder
    )
  }

  func testDirectorySymlinksUseFolderSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "Reports Link", kind: .symlinkToDirectory, fileType: .unknown)
      ),
      .folder
    )
  }

  func testFileSymlinksUseTargetFileTypeSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "latest", kind: .symlinkToFile, fileType: .markdown)
      ),
      .editableText
    )
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "linked-photo", kind: .symlinkToFile, fileType: .image)
      ),
      .unsupported
    )
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "linked-photo.png", kind: .symlinkToFile, fileType: .image)
      ),
      .image
    )
  }

  func testUnknownSymlinksUseUnsupportedSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "broken", kind: .symlink, fileType: .unknown)
      ),
      .unsupported
    )
  }

  func testOtherEntriesUseUnsupportedSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "unknown", kind: .other, fileType: .image)
      ),
      .unsupported
    )
  }

  func testLargeTextThresholdRoutesOversizedFilesToTheReadOnlyViewer() {
    XCTAssertFalse(WorkspaceDocumentSurfaceSupport.isLargeText(byteCount: 0))
    XCTAssertFalse(
      WorkspaceDocumentSurfaceSupport.isLargeText(
        byteCount: WorkspaceDocumentSurfaceSupport.editableTextByteLimit))
    XCTAssertTrue(
      WorkspaceDocumentSurfaceSupport.isLargeText(
        byteCount: WorkspaceDocumentSurfaceSupport.editableTextByteLimit + 1))
  }

  func testUnreadablyLongLinesGuardTripsOnMaxLineLength() {
    // A reasonable longest line renders fine.
    XCTAssertFalse(WorkspaceDocumentSurfaceSupport.hasUnreadablyLongLines(maxLineByteCount: 4096))
    // One pathologically long line trips the guard — the case an average-based
    // check missed (a giant line in an otherwise normal file).
    XCTAssertTrue(
      WorkspaceDocumentSurfaceSupport.hasUnreadablyLongLines(maxLineByteCount: 300_000_000))
  }

  private func makeEntry(
    name: String,
    kind: WorkspaceEntryKind = .file,
    fileType: WorkspaceFileType
  ) -> WorkspaceEntry {
    WorkspaceEntry(
      id: "/tmp/locus-test/\(name)",
      url: URL(filePath: "/tmp/locus-test/\(name)"),
      name: name,
      kind: kind,
      fileType: fileType,
      sizeBytes: 12,
      modified: nil,
      isReadOnly: false
    )
  }
}
