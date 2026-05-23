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
