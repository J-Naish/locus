import Foundation

enum WorkspaceEntryOpenAction: Equatable, Sendable {
    case browseFolder(URL)
    case preview(URL)
}

enum WorkspaceEntryOpenActionResolver {
    static func action(for entries: [WorkspaceEntry]) -> WorkspaceEntryOpenAction? {
        guard entries.count == 1, let entry = entries.first else {
            return nil
        }

        switch entry.kind {
        case .directory:
            return .browseFolder(entry.url)
        case .file, .symlink:
            return .preview(entry.url)
        case .other:
            return nil
        }
    }
}
