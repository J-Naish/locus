import Foundation

enum WorkspaceDocumentSurfaceKind: Equatable {
    case editableText
    case image
    case pdf
    case folder
    case unsupported

    var supportsInPlaceOpen: Bool {
        switch self {
        case .editableText, .image, .pdf:
            return true
        case .folder, .unsupported:
            return false
        }
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
        "webp"
    ]
}
