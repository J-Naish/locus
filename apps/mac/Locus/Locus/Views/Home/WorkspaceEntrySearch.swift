import Foundation

enum WorkspaceEntrySearch {
    static func filteredEntries(_ entries: [WorkspaceEntry], query: String) -> [WorkspaceEntry] {
        let terms = searchTerms(from: query)
        guard !terms.isEmpty else {
            return entries
        }

        return entries.filter { entry in
            terms.allSatisfy { term in
                entry.name.localizedStandardContains(term)
            }
        }
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
