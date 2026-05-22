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

    func testFiltersShortcutsByDisplayName() {
        let shortcuts = [
            makeFavoriteFolder(displayName: "Client Materials", path: "/Users/nash/Documents/Acme"),
            makeFavoriteFolder(displayName: "Project Briefs", path: "/Users/nash/Documents/Briefs"),
            makeFavoriteFolder(displayName: "Invoices", path: "/Users/nash/Documents/Finance")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredShortcuts(shortcuts, query: "brief").map(\.displayName),
            ["Project Briefs"]
        )
        XCTAssertEqual(
            WorkspaceEntrySearch.filteredShortcuts(shortcuts, query: "CLIENT").map(\.displayName),
            ["Client Materials"]
        )
        XCTAssertEqual(
            WorkspaceEntrySearch.filteredShortcuts(shortcuts, query: "documents").map(\.displayName),
            []
        )
    }

    func testRequiresEveryWhitespaceSeparatedTermForShortcuts() {
        let shortcuts = [
            makeFavoriteFolder(displayName: "Project Briefs", path: "/tmp/briefs"),
            makeFavoriteFolder(displayName: "Project Notes", path: "/tmp/notes"),
            makeFavoriteFolder(displayName: "Brief Archive", path: "/tmp/archive")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredShortcuts(shortcuts, query: "project briefs").map(\.displayName),
            ["Project Briefs"]
        )
    }

    func testReportsWhetherQueryHasSearchTerms() {
        XCTAssertFalse(WorkspaceEntrySearch.hasSearchTerms(in: " \t\n "))
        XCTAssertTrue(WorkspaceEntrySearch.hasSearchTerms(in: "brief"))
    }

    func testFiltersShortcutNamesCaseInsensitively() {
        let shortcuts = [
            makeFavoriteFolder(displayName: "Budget Archive", path: "/tmp/budget"),
            makeFavoriteFolder(displayName: "Meeting Notes", path: "/tmp/notes")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredShortcuts(shortcuts, query: "BUDGET").map(\.displayName),
            ["Budget Archive"]
        )
    }

    func testReturnsOriginalShortcutOrderForBlankQuery() {
        let shortcuts = [
            makeFavoriteFolder(displayName: "First", path: "/tmp/first"),
            makeFavoriteFolder(displayName: "Second", path: "/tmp/second")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredShortcuts(shortcuts, query: " \t\n ").map(\.displayName),
            ["First", "Second"]
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

private func makeFavoriteFolder(displayName: String, path: String) -> FavoriteFolder {
    FavoriteFolder(
        id: path,
        url: URL(filePath: path, directoryHint: .isDirectory),
        displayName: displayName,
        path: path,
        addedAt: Date(timeIntervalSince1970: 0)
    )
}
