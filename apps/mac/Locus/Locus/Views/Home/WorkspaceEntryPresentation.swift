import SwiftUI

extension WorkspaceEntry {
  /// Synthesizes a `WorkspaceEntry` for the workspace root folder itself.
  /// The FFI lists only a folder's children, so the root row has no
  /// metadata-bearing entry to copy. Fields not directly observable from the
  /// URL are intentionally left nil, unknown, or false.
  static func workspaceRoot(at folderURL: URL) -> WorkspaceEntry {
    let standardizedURL = folderURL.standardizedFileURL
    let folderName = standardizedURL.lastPathComponent
    return WorkspaceEntry(
      // Keep the synthesized root id aligned with Git status path keys.
      id: standardizedURL.locusStandardizedPath,
      url: standardizedURL,
      name: folderName.isEmpty ? "Workspace" : folderName,
      kind: .directory,
      fileType: .unknown,
      sizeBytes: nil,
      modified: nil,
      isReadOnly: false
    )
  }

  var symbolName: String {
    switch kind {
    case .directory:
      return "folder"
    case .file:
      return fileType.symbolName
    case .symlink:
      return "arrowshape.turn.up.right"
    case .other:
      return "doc"
    }
  }

  var symbolColor: Color {
    switch kind {
    case .directory:
      return .blue
    case .file:
      return .secondary
    case .symlink:
      return .purple
    case .other:
      return .secondary
    }
  }
}

extension WorkspaceFileType {
  fileprivate var symbolName: String {
    switch self {
    case .markdown, .structuredText, .plainText:
      return "doc.text"
    case .pdf:
      return "doc.richtext"
    case .office:
      return "doc"
    case .image:
      return "photo"
    case .audio:
      return "waveform"
    case .video:
      return "film"
    case .code:
      return "chevron.left.forwardslash.chevron.right"
    case .unknown:
      return "doc"
    }
  }
}
