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

    func testSingleFileOpensExternally() {
        let entry = makeWorkspaceEntry(name: "notes.md", kind: .file)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .openExternally(entry.url)
        )
    }

    func testSingleSymlinkDelegatesToExternalOpen() {
        let entry = makeWorkspaceEntry(name: "latest", kind: .symlink)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .openExternally(entry.url)
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
    kind: WorkspaceEntryKind
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
        fileType: .unknown,
        sizeBytes: nil,
        modified: nil,
        isReadOnly: false
    )
}
