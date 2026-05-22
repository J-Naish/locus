import Foundation

enum WorkspaceEntrySearch {
    static func filteredEntries(_ entries: [WorkspaceEntry], query: String) -> [WorkspaceEntry] {
        WorkspaceSearchRanker.rankedFilter(entries, query: query, matchableString: \.name)
    }

    static func filteredShortcuts<Shortcut: FileLocationShortcut>(
        _ shortcuts: [Shortcut],
        query: String
    ) -> [Shortcut] {
        WorkspaceSearchRanker.rankedFilter(shortcuts, query: query, matchableString: \.displayName)
    }

    static func hasSearchTerms(in query: String) -> Bool {
        !searchTerms(from: query).isEmpty
    }

    static func shouldKeepSelection(_ selectedEntryID: WorkspaceEntry.ID?, in entries: [WorkspaceEntry]) -> Bool {
        guard let selectedEntryID else {
            return true
        }

        return entries.contains { $0.id == selectedEntryID }
    }

    private static func searchTerms(from query: String) -> [String] {
        query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }
}
