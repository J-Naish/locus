import Foundation

enum WorkspaceEntryOpenAction: Equatable, Sendable {
    case browseFolder(URL)
    case openExternally(URL)
}

enum WorkspaceEntryOpenActionResolver {
    static func action(for entries: [WorkspaceEntry]) -> WorkspaceEntryOpenAction? {
        guard entries.count == 1, let entry = entries.first else {
            return nil
        }

        switch entry.kind {
        case .directory:
            return .browseFolder(entry.url)
        case .file:
            return .openExternally(entry.url)
        case .symlink:
            // Let macOS resolve symlink targets for now so aliases to files and
            // folders behave consistently with the system handoff path.
            return .openExternally(entry.url)
        case .other:
            return nil
        }
    }
}
