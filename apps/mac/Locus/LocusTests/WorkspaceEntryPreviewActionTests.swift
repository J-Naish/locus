import XCTest

@testable import Locus

final class WorkspaceEntryPreviewActionTests: XCTestCase {
  func testSingleFileCanBePreviewed() {
    let entry = makeWorkspaceEntry(name: "brief.md", kind: .file)

    XCTAssertEqual(WorkspaceEntryPreviewActionResolver.previewURLs(for: [entry]), [entry.url])
  }

  func testSingleSymlinkCanBePreviewedBySystemResolution() {
    let entry = makeWorkspaceEntry(name: "brief-link", kind: .symlink)

    XCTAssertEqual(WorkspaceEntryPreviewActionResolver.previewURLs(for: [entry]), [entry.url])
  }

  func testDirectoryCannotBePreviewedFromFileList() {
    let entry = makeWorkspaceEntry(name: "Reports", kind: .directory)

    XCTAssertNil(WorkspaceEntryPreviewActionResolver.previewURLs(for: [entry]))
  }

  func testOtherEntryCannotBePreviewed() {
    let entry = makeWorkspaceEntry(name: "socket", kind: .other)

    XCTAssertNil(WorkspaceEntryPreviewActionResolver.previewURLs(for: [entry]))
  }

  func testMultipleSelectionCannotBePreviewedAsOneAction() {
    let first = makeWorkspaceEntry(name: "first.md", kind: .file)
    let second = makeWorkspaceEntry(name: "second.md", kind: .file)

    XCTAssertNil(WorkspaceEntryPreviewActionResolver.previewURLs(for: [first, second]))
  }

  private func makeWorkspaceEntry(name: String, kind: WorkspaceEntryKind) -> WorkspaceEntry {
    let directoryHint: URL.DirectoryHint = kind == .directory ? .isDirectory : .notDirectory
    let url = URL(filePath: "/tmp/\(name)", directoryHint: directoryHint)
    return WorkspaceEntry(
      id: url.path(percentEncoded: false),
      url: url,
      name: name,
      kind: kind,
      fileType: kind == .file ? .markdown : .unknown,
      sizeBytes: kind == .directory ? nil : 12,
      modified: Date(timeIntervalSince1970: 0),
      isReadOnly: false
    )
  }
}
