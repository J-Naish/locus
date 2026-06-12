import Foundation

enum WorkspaceTextDocumentSupport {
  static func canEdit(_ entry: WorkspaceEntry) -> Bool {
    guard entry.kind.isFileLike else {
      return false
    }

    switch entry.fileType {
    case .markdown, .structuredText, .plainText, .code, .unknown:
      return true
    case .pdf, .office, .image, .audio, .video:
      return false
    }
  }

  static func canOpenInTextSurface(_ entry: WorkspaceEntry) -> Bool {
    guard entry.kind.isFileLike else {
      return false
    }

    switch entry.fileType {
    case .markdown, .structuredText, .plainText, .code, .unknown:
      return true
    case .pdf, .office, .image, .audio, .video:
      return false
    }
  }

  /// Recognized text types eligible for the read-only large-file viewer. Unlike
  /// `canEdit`, this excludes `.unknown`: a large file of an unrecognized type may
  /// be binary, and the windowed viewer would scan it and show mojibake. A large
  /// unknown file therefore falls to the editable path (which refuses it) rather
  /// than to the lossy viewer.
  static func isRecognizedTextType(_ entry: WorkspaceEntry) -> Bool {
    guard entry.kind.isFileLike else {
      return false
    }

    switch entry.fileType {
    case .markdown, .structuredText, .plainText, .code:
      return true
    case .unknown, .pdf, .office, .image, .audio, .video:
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

  /// Whether the text viewer soft-wraps long lines to the viewport instead of
  /// scrolling horizontally. Wrapping is reserved for prose documents — where a
  /// line is a paragraph and its length is incidental — and turned off wherever
  /// a line is itself a unit of meaning: structured config, code, tabular/log
  /// data, dotfile lists, and environment files (whose values can be long but
  /// belong on one line). Prose is an explicit allowlist, so unrecognized files
  /// default to no-wrap, preserving their exact line structure.
  static func wrapsLines(for entry: WorkspaceEntry) -> Bool {
    if entry.fileType == .markdown {
      return true
    }
    // Only plain text can be prose; structured text, code, and binaries never wrap.
    guard entry.fileType == .plainText else {
      return false
    }
    let fileExtension = entry.url.pathExtension.lowercased()
    if proseTextExtensions.contains(fileExtension) {
      return true
    }
    // Extensionless prose documents (README, LICENSE, …). Dotfiles like
    // `.gitignore` and `.env` also have no extension, so match the document name
    // itself rather than treating every extensionless file as prose.
    guard fileExtension.isEmpty else {
      return false
    }
    return proseDocumentNames.contains(entry.url.lastPathComponent.lowercased())
  }

  private static let proseTextExtensions: Set<String> = ["txt", "text"]

  private static let proseDocumentNames: Set<String> = [
    "readme", "license", "notice", "changelog", "contributing", "authors",
  ]
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
