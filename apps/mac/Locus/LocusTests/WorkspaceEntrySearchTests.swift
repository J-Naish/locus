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

    func testMatchesFileNamesWithOneCharacterTypo() {
        let entries = [
            makeWorkspaceEntry(name: "Breif.md"),
            makeWorkspaceEntry(name: "Budget.xlsx"),
            makeWorkspaceEntry(name: "meeting-notes.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "brief").map(\.name),
            ["Breif.md"]
        )
        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "budegt").map(\.name),
            ["Budget.xlsx"]
        )
    }

    func testRanksStrongerFileNameMatchesBeforeWeakerMatches() {
        let entries = [
            makeWorkspaceEntry(name: "Project Brief.md"),
            makeWorkspaceEntry(name: "Breif.md"),
            makeWorkspaceEntry(name: "brief-notes.md"),
            makeWorkspaceEntry(name: "brief.md"),
            makeWorkspaceEntry(name: "brief")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "brief").map(\.name),
            [
                "brief",
                "brief.md",
                "brief-notes.md",
                "Project Brief.md",
                "Breif.md"
            ]
        )
    }

    func testKeepsOriginalOrderWhenSearchRankIsTied() {
        let entries = [
            makeWorkspaceEntry(name: "Project Brief.md"),
            makeWorkspaceEntry(name: "Client Brief.md"),
            makeWorkspaceEntry(name: "Sales Brief.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "brief").map(\.name),
            [
                "Project Brief.md",
                "Client Brief.md",
                "Sales Brief.md"
            ]
        )
    }

    func testDoesNotFuzzyMatchVeryShortTerms() {
        let entries = [
            makeWorkspaceEntry(name: "AI.md"),
            makeWorkspaceEntry(name: "UI.md"),
            makeWorkspaceEntry(name: "ACB.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "ai").map(\.name),
            ["AI.md"]
        )
        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "abc").map(\.name),
            []
        )
    }

    func testFuzzyMatchStartsAtFourCharacters() {
        let entries = [
            makeWorkspaceEntry(name: "ABDC.md"),
            makeWorkspaceEntry(name: "AXD.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "abcd").map(\.name),
            ["ABDC.md"]
        )
        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "adx").map(\.name),
            []
        )
    }

    func testRejectsNonAdjacentOrMultiCharacterTypos() {
        let entries = [
            makeWorkspaceEntry(name: "bxyef.md"),
            makeWorkspaceEntry(name: "bxxief.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "brief").map(\.name),
            []
        )
        XCTAssertFalse(FuzzyMatching.isSingleTypoMatch(Array("brief"), Array("brief")))
        XCTAssertFalse(FuzzyMatching.isSingleTypoMatch(Array("brief"), Array("bxyef")))
        XCTAssertFalse(FuzzyMatching.isSingleTypoMatch(Array("brief"), Array("bxxief")))
    }

    func testRanksDotfilesWithoutEmptyStemMatch() {
        XCTAssertEqual(WorkspaceSearchRanker.matchKind(for: ".gitignore", in: ".gitignore"), .exactName)
        XCTAssertEqual(WorkspaceSearchRanker.matchKind(for: "gitignore", in: ".gitignore"), .contains)
    }

    func testRanksNormalizedNamesCaseDiacriticAndWidthInsensitively() {
        XCTAssertEqual(WorkspaceSearchRanker.matchKind(for: "budget", in: "Ｂｕｄｇｅｔ.md"), .stem)
        XCTAssertEqual(WorkspaceSearchRanker.matchKind(for: "Cafe", in: "Café.md"), .stem)
        XCTAssertEqual(WorkspaceSearchRanker.matchKind(for: "REPORT", in: "report.md"), .stem)
    }

    func testJapaneseNamesUseContainsMatchingWithoutFuzzyTokenMatching() {
        let entries = [
            makeWorkspaceEntry(name: "プロジェクト概要.md"),
            makeWorkspaceEntry(name: "プロジェクト概用.md")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "概要").map(\.name),
            ["プロジェクト概要.md"]
        )
        XCTAssertEqual(
            WorkspaceEntrySearch.filteredEntries(entries, query: "概用").map(\.name),
            ["プロジェクト概用.md"]
        )
    }

    func testRanksTenThousandEntriesWithinInteractiveBudget() {
        let entries = (0..<10_000).map { index in
            switch index {
            case 7:
                return makeWorkspaceEntry(name: "Project Brief.md")
            case 5_000:
                return makeWorkspaceEntry(name: "Breif.md")
            default:
                return makeWorkspaceEntry(name: "Document-\(index).md")
            }
        }
        var result: [WorkspaceEntry] = []

        let elapsed = ContinuousClock().measure {
            result = WorkspaceEntrySearch.filteredEntries(entries, query: "brief")
        }

        XCTAssertEqual(result.map(\.name), ["Project Brief.md", "Breif.md"])
        XCTAssertLessThan(elapsed.milliseconds, 500)
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

    func testMatchesShortcutNamesWithOneCharacterTypo() {
        let shortcuts = [
            makeFavoriteFolder(displayName: "Project Breifs", path: "/tmp/briefs"),
            makeFavoriteFolder(displayName: "Meeting Notes", path: "/tmp/notes")
        ]

        XCTAssertEqual(
            WorkspaceEntrySearch.filteredShortcuts(shortcuts, query: "briefs").map(\.displayName),
            ["Project Breifs"]
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

private extension Duration {
    var milliseconds: Double {
        let components = components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
