import Foundation

enum WorkspaceEntryOpenAction: Equatable, Sendable {
  case browseFolder(URL)
  case openInPlace(URL)
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
      let surfaceKind = WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry)
      if surfaceKind.supportsInPlaceOpen {
        return .openInPlace(entry.url)
      }

      return nil
    case .other:
      return nil
    }
  }
}
