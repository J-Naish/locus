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
            .openTextDocumentInPlace(entry.url)
        )
    }

    func testSingleNonTextFilePreviewsInLocus() {
        let entry = makeWorkspaceEntry(name: "brief.pdf", kind: .file, fileType: .pdf)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .preview(entry.url)
        )
    }

    func testSingleTextSymlinkEditsInLocus() {
        let entry = makeWorkspaceEntry(name: "latest", kind: .symlink, fileType: .plainText)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .openTextDocumentInPlace(entry.url)
        )
    }

    func testSingleNonTextSymlinkPreviewsInLocus() {
        let entry = makeWorkspaceEntry(name: "latest", kind: .symlink, fileType: .unknown)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .preview(entry.url)
        )
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
        directoryHint: kind == .directory ? .isDirectory : .notDirectory
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
