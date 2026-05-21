import XCTest
@testable import Locus

final class WorkspaceEntrySearchTests: XCTestCase {
    func testReturnsOriginalOrderForBlankQuery() {
        let entries = [
            makeWorkspaceEntry(name: "Drafts"),
            makeWorkspaceEntry(name: "project-brief.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: " \t\n ").map(\.name),
            ["Drafts", "project-brief.md"]
        )
    }

    func testMatchesFileNamesCaseInsensitively() {
        let entries = [
            makeWorkspaceEntry(name: "Budget.xlsx"),
            makeWorkspaceEntry(name: "meeting-notes.md"),
            makeWorkspaceEntry(name: "Project Brief.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "brief").map(\.name),
            ["Project Brief.md"]
        )
        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "BUDGET").map(\.name),
            ["Budget.xlsx"]
        )
    }

    func testRequiresEveryWhitespaceSeparatedTerm() {
        let entries = [
            makeWorkspaceEntry(name: "Project Brief.md"),
            makeWorkspaceEntry(name: "Project Notes.md"),
            makeWorkspaceEntry(name: "Brief Archive.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "project brief").map(\.name),
            ["Project Brief.md"]
        )
    }

    func testKeepsSelectionOnlyWhenStillVisible() {
        let visibleEntry = makeWorkspaceEntry(name: "notes.md")
        let hiddenEntry = makeWorkspaceEntry(name: "budget.xlsx")

        XCTAssertTrue(
            WorkspaceEntrySearch.shouldKeepSelection(
                visibleEntry.id,
                in: [visibleEntry]
            )
        )
        XCTAssertFalse(
            WorkspaceEntrySearch.shouldKeepSelection(
                hiddenEntry.id,
                in: [visibleEntry]
            )
        )
        XCTAssertTrue(WorkspaceEntrySearch.shouldKeepSelection(nil, in: [visibleEntry]))
    }
}

private func makeWorkspaceEntry(
    name: String,
    kind: WorkspaceEntryKind = .file,
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
