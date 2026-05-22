import Foundation

protocol FileLocationShortcut: Identifiable {
    var url: URL { get }
    var displayName: String { get }
    var path: String { get }
}

enum WorkspaceEntrySearch {
    static func filteredEntries(_ entries: [WorkspaceEntry], query: String) -> [WorkspaceEntry] {
        filter(entries, query: query) { entry in
            [entry.name]
        }
    }

    static func filteredShortcuts<Shortcut: FileLocationShortcut>(
        _ shortcuts: [Shortcut],
        query: String
    ) -> [Shortcut] {
        filter(shortcuts, query: query) { shortcut in
            [shortcut.displayName]
        }
    }

    static func hasSearchTerms(in query: String) -> Bool {
        !searchTerms(from: query).isEmpty
    }

    private static func filter<Item>(
        _ items: [Item],
        query: String,
        matchableStrings: (Item) -> [String]
    ) -> [Item] {
        let terms = searchTerms(from: query)
        guard !terms.isEmpty else {
            return items
        }

        return items.filter { item in
            let strings = matchableStrings(item)
            return terms.allSatisfy { term in
                strings.contains { string in
                    string.localizedStandardContains(term)
                }
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
