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

  func testOtherEntriesUseUnsupportedSurface() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.surfaceKind(
        for: makeEntry(name: "unknown", kind: .other, fileType: .image)
      ),
      .unsupported
    )
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
