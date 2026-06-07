import Foundation

enum WorkspaceDocumentSurfaceKind: Equatable {
  case editableText
  case image
  case pdf
  case video
  case audio
  case quickLookPreview
  case folder
  case unsupported

  var supportsInPlaceOpen: Bool {
    switch self {
    case .editableText, .image, .pdf, .video, .audio, .quickLookPreview:
      return true
    case .folder, .unsupported:
      return false
    }
  }

  var isAutoSynced: Bool {
    // Auto-sync currently follows every in-place surface. Keep this as a
    // separate policy hook so a future surface can opt out without changing
    // the open-in-place resolver.
    supportsInPlaceOpen
  }
}

enum WorkspaceDocumentSurfaceSupport {
  static func surfaceKind(for entry: WorkspaceEntry) -> WorkspaceDocumentSurfaceKind {
    switch entry.kind {
    case .file, .symlinkToFile:
      if WorkspaceTextDocumentSupport.canEdit(entry) {
        return .editableText
      }
      if canRenderImageInPlace(entry) {
        return .image
      }
      if entry.fileType == .pdf {
        return .pdf
      }
      if entry.fileType == .video {
        return .video
      }
      if entry.fileType == .audio {
        return .audio
      }
      if entry.fileType == .office {
        return .quickLookPreview
      }
      return .unsupported
    case .directory, .symlinkToDirectory:
      return .folder
    case .symlink, .other:
      return .unsupported
    }
  }

  private static func canRenderImageInPlace(_ entry: WorkspaceEntry) -> Bool {
    guard entry.fileType == .image else {
      return false
    }

    return supportedRasterImageExtensions.contains(
      entry.url.pathExtension.lowercased()
    )
  }

  private static let supportedRasterImageExtensions: Set<String> = [
    "bmp",
    "gif",
    "heic",
    "heif",
    "jpeg",
    "jpg",
    "png",
    "tif",
    "tiff",
    "webp",
  ]

  /// A text file larger than this opens read-only in the windowed viewer instead
  /// of the in-memory editable buffer. Mirrors `TextBufferStore`'s editable cap.
  static var editableTextByteLimit: Int { TextBufferStore.defaultMaximumOpenByteCount }

  /// Whether a text file of `byteCount` bytes is too large to edit in memory and
  /// should open in the read-only windowed viewer.
  static func isLargeText(byteCount: Int) -> Bool {
    byteCount > editableTextByteLimit
  }

  /// Logical size of `url` in bytes, read inside a balanced security scope so it
  /// resolves the same way the document open does (which holds the scope before
  /// reading). Returns nil when the size is unavailable.
  static func fileByteCount(at url: URL) -> Int? {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
  }
}
