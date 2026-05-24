import Foundation

enum WorkspaceTextDocumentSupport {
  static func canEdit(_ entry: WorkspaceEntry) -> Bool {
    guard entry.kind == .file || entry.kind == .symlink else {
      return false
    }

    switch entry.fileType {
    case .markdown, .structuredText, .plainText, .code:
      return true
    case .pdf, .office, .image, .audio, .video, .unknown:
      return false
    }
  }

  static func syntax(for entry: WorkspaceEntry) -> TextDocumentSyntax? {
    switch entry.fileType {
    case .markdown:
      return .markdown
    case .structuredText:
      return .structuredText
    case .code:
      return .code
    case .plainText:
      return .plainText
    case .pdf, .office, .image, .audio, .video, .unknown:
      return nil
    }
  }
}

enum WorkspaceFileTypeLabel {
  static func displayLabel(for entry: WorkspaceEntry) -> String {
    switch entry.fileType {
    case .markdown:
      return "Markdown"
    case .structuredText:
      return "Structured text"
    case .plainText:
      return "Plain text"
    case .code:
      return "Source text"
    case .pdf:
      return "PDF"
    case .office:
      return "Office document"
    case .image:
      return "Image"
    case .audio:
      return "Audio"
    case .video:
      return "Video"
    case .unknown:
      return "File"
    }
  }
}
