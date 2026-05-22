import XCTest
@testable import Locus

final class WorkspaceEntryPathCopyTests: XCTestCase {
    func testSingleEntryCopiesPlainPath() {
        let entry = makeWorkspaceEntry(name: "Project Brief.md")

        XCTAssertEqual(
            WorkspaceEntryPathCopy.pasteboardString(for: [entry]),
            "/tmp/locus-test/Project Brief.md"
        )
    }

    func testDirectoryPathDropsTrailingSlash() {
        let entry = makeWorkspaceEntry(
            url: URL(filePath: "/tmp/locus-test/Reports/", directoryHint: .isDirectory),
            name: "Reports",
            kind: .directory
        )

        XCTAssertEqual(
            WorkspaceEntryPathCopy.pasteboardString(for: [entry]),
            "/tmp/locus-test/Reports"
        )
    }

    func testPathIsStandardizedBeforeCopying() {
        let entry = makeWorkspaceEntry(
            url: URL(filePath: "/tmp/locus-test/./Reports/../Notes.txt"),
            name: "Notes.txt",
            kind: .file
        )

        XCTAssertEqual(
            WorkspaceEntryPathCopy.pasteboardString(for: [entry]),
            "/tmp/locus-test/Notes.txt"
        )
    }

    func testMultipleEntriesCopyOnePathPerLineInInputOrder() {
        let first = makeWorkspaceEntry(name: "Reports")
        let second = makeWorkspaceEntry(name: "Notes.txt")

        XCTAssertEqual(
            WorkspaceEntryPathCopy.pasteboardString(for: [first, second]),
            """
            /tmp/locus-test/Reports
            /tmp/locus-test/Notes.txt
            """
        )
    }

    func testEmptySelectionCopiesNothing() {
        XCTAssertNil(WorkspaceEntryPathCopy.pasteboardString(for: []))
    }

    func testMenuTitleMatchesSelectionCount() {
        XCTAssertEqual(
            WorkspaceEntryPathCopy.menuTitle(for: [makeWorkspaceEntry(name: "Notes.txt")]),
            "Copy Path"
        )
        XCTAssertEqual(
            WorkspaceEntryPathCopy.menuTitle(
                for: [
                    makeWorkspaceEntry(name: "Notes.txt"),
                    makeWorkspaceEntry(name: "Reports")
                ]
            ),
            "Copy Paths"
        )
    }
}

private func makeWorkspaceEntry(name: String) -> WorkspaceEntry {
    let url = URL(filePath: "/tmp/locus-test/\(name)")
    return makeWorkspaceEntry(url: url, name: name, kind: .file)
}

private func makeWorkspaceEntry(
    url: URL,
    name: String,
    kind: WorkspaceEntryKind
) -> WorkspaceEntry {
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
