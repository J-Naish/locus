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

  func testTextBackendUsesReadOnlyOnlyForRecognizedLargeText() {
    let limit = WorkspaceDocumentSurfaceSupport.editableTextByteLimit
    let backend = WorkspaceDocumentSurfaceSupport.textBackend

    // Recognized text over the limit → the read-only windowed backend.
    XCTAssertEqual(backend(limit + 1, true), .readOnlyWindowed)
    // Recognized text at/under the limit → editable.
    XCTAssertEqual(backend(limit, true), .editable)
    // An unrecognized (possibly binary) file stays editable even when large, so it
    // is refused there rather than scanned into mojibake by the windowed viewer.
    XCTAssertEqual(backend(limit + 1, false), .editable)
    // Unknown size → editable.
    XCTAssertEqual(backend(nil, true), .editable)
  }

  // MARK: Inactive-document reconciliation

  func testReconciliationKeepsBufferWhenDiskIsUnchanged() {
    let fingerprint = makeFingerprint(size: 5)
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.reconciliation(
        isCached: true,
        baselineFingerprint: fingerprint,
        currentFingerprint: fingerprint,
        hasPendingConflict: false,
        hasUnsavedEdits: true
      ),
      .keepBuffer
    )
    // Both sides unreadable (never resolved) compares equal too.
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.reconciliation(
        isCached: true,
        baselineFingerprint: nil,
        currentFingerprint: nil,
        hasPendingConflict: false,
        hasUnsavedEdits: true
      ),
      .keepBuffer
    )
  }

  func testReconciliationIgnoresDivergenceForAnUncachedDocument() {
    // Not cached → there is no retained buffer to reconcile, whatever disk says.
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.reconciliation(
        isCached: false,
        baselineFingerprint: makeFingerprint(size: 5),
        currentFingerprint: makeFingerprint(size: 9),
        hasPendingConflict: false,
        hasUnsavedEdits: false
      ),
      .keepBuffer
    )
  }

  func testReconciliationWarnsWhenDiskChangedUnderUnsavedEdits() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.reconciliation(
        isCached: true,
        baselineFingerprint: makeFingerprint(size: 5),
        currentFingerprint: makeFingerprint(size: 9),
        hasPendingConflict: false,
        hasUnsavedEdits: true
      ),
      .conflict
    )
  }

  func testReconciliationReloadsWhenDiskChangedUnderACleanBuffer() {
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.reconciliation(
        isCached: true,
        baselineFingerprint: makeFingerprint(size: 5),
        currentFingerprint: makeFingerprint(size: 9),
        hasPendingConflict: false,
        hasUnsavedEdits: false
      ),
      .reloadFromDisk
    )
  }

  func testReconciliationTreatsAFingerprintAppearingOrVanishingAsADivergence() {
    // The file became unreadable (deleted/moved) while inactive: unsaved edits
    // are worth a warning; a clean buffer reloads (and surfaces the open error).
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.reconciliation(
        isCached: true,
        baselineFingerprint: makeFingerprint(size: 5),
        currentFingerprint: nil,
        hasPendingConflict: false,
        hasUnsavedEdits: true
      ),
      .conflict
    )
    // No baseline was ever recorded but the file reads now.
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.reconciliation(
        isCached: true,
        baselineFingerprint: nil,
        currentFingerprint: makeFingerprint(size: 5),
        hasPendingConflict: false,
        hasUnsavedEdits: false
      ),
      .reloadFromDisk
    )
  }

  func testReconciliationPreservesAnUnresolvedPendingConflict() {
    let fingerprint = makeFingerprint(size: 5)
    XCTAssertEqual(
      WorkspaceDocumentSurfaceSupport.reconciliation(
        isCached: true,
        baselineFingerprint: fingerprint,
        currentFingerprint: fingerprint,
        hasPendingConflict: true,
        hasUnsavedEdits: true
      ),
      .conflict
    )
  }

  private func makeFingerprint(size: UInt64) -> DocumentFileFingerprint {
    DocumentFileFingerprint(size: size, modificationDate: Date(timeIntervalSince1970: 100))
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
