import Foundation

enum WorkspaceEntryPreviewActionResolver {
    static func previewURLs(for entries: [WorkspaceEntry]) -> [URL]? {
        guard entries.count == 1, let entry = entries.first else {
            return nil
        }

        switch entry.kind {
        case .file, .symlink:
            return [entry.url]
        case .directory, .other:
            return nil
        }
    }
}
