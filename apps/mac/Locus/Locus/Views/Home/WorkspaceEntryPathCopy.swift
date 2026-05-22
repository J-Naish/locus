import Foundation

enum WorkspaceEntryPathCopy {
    static func pasteboardString(for entries: [WorkspaceEntry]) -> String? {
        guard !entries.isEmpty else {
            return nil
        }

        return entries
            .map { copyPath(for: $0.url) }
            .joined(separator: "\n")
    }

    static func menuTitle(for entries: [WorkspaceEntry]) -> String {
        entries.count == 1 ? "Copy Path" : "Copy Paths"
    }

    private static func copyPath(for url: URL) -> String {
        url.locusStandardizedPath
    }
}
