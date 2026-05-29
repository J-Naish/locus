import XCTest

@testable import Locus

final class WorkspaceEntryOpenActionTests: XCTestCase {
  func testSingleDirectoryBrowsesInLocus() {
    let entry = makeWorkspaceEntry(name: "Drafts", kind: .directory)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .browseFolder(entry.url)
    )
  }

  func testSingleTextFileEditsInLocus() {
    let entry = makeWorkspaceEntry(name: "notes.md", kind: .file, fileType: .markdown)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleImageFileViewsInLocus() {
    let entry = makeWorkspaceEntry(name: "photo.png", kind: .file, fileType: .image)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleVectorImageHasNoOpenAction() {
    let entry = makeWorkspaceEntry(name: "diagram.svg", kind: .file, fileType: .image)

    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [entry]))
  }

  func testSinglePDFFileViewsInLocus() {
    let entry = makeWorkspaceEntry(name: "brief.pdf", kind: .file, fileType: .pdf)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleVideoFilePlaysInLocus() {
    let entry = makeWorkspaceEntry(name: "clip.mp4", kind: .file, fileType: .video)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleAudioFilePlaysInLocus() {
    let entry = makeWorkspaceEntry(name: "voice.mp3", kind: .file, fileType: .audio)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleOfficeFilePreviewsInPlace() {
    let entry = makeWorkspaceEntry(name: "deck.pptx", kind: .file, fileType: .office)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleUnknownFileTriesInPlaceTextOpen() {
    let entry = makeWorkspaceEntry(name: "blob", kind: .file, fileType: .unknown)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleTextSymlinkEditsInLocus() {
    let entry = makeWorkspaceEntry(name: "latest", kind: .symlinkToFile, fileType: .plainText)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleImageSymlinkViewsInLocus() {
    let entry = makeWorkspaceEntry(name: "latest.png", kind: .symlinkToFile, fileType: .image)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleUnknownSymlinkTriesInPlaceTextOpen() {
    let entry = makeWorkspaceEntry(name: "latest", kind: .symlinkToFile, fileType: .unknown)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleDirectorySymlinkBrowsesInLocus() {
    let entry = makeWorkspaceEntry(name: "hooks", kind: .symlinkToDirectory)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .browseFolder(entry.url)
    )
  }

  func testUnknownSymlinkCannotBeOpened() {
    let entry = makeWorkspaceEntry(name: "broken", kind: .symlink, fileType: .unknown)

    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [entry]))
  }

  func testOtherEntriesCannotBeOpened() {
    let entry = makeWorkspaceEntry(name: "socket", kind: .other)

    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [entry]))
  }

  func testMultipleSelectionCannotBeOpenedAsOneAction() {
    let folder = makeWorkspaceEntry(name: "Drafts", kind: .directory)
    let file = makeWorkspaceEntry(name: "notes.md", kind: .file)

    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [folder, file]))
    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: []))
  }
}

private func makeWorkspaceEntry(
  name: String,
  kind: WorkspaceEntryKind,
  fileType: WorkspaceFileType = .unknown
) -> WorkspaceEntry {
  let url = URL(
    filePath: "/tmp/locus-test/\(name)",
    directoryHint: kind.isDirectoryLike ? .isDirectory : .notDirectory
  )
  return WorkspaceEntry(
    id: url.path(percentEncoded: false),
    url: url,
    name: name,
    kind: kind,
    fileType: fileType,
    sizeBytes: nil,
    modified: nil,
    isReadOnly: false
  )
}
