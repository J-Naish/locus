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
    case .file, .symlink:
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
    case .directory:
      return .folder
    case .other:
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
}
