import Foundation
import PDFKit

struct LocusPDFDocument: @unchecked Sendable {
    let document: PDFDocument
}

protocol PDFDocumentStoring: Sendable {
    func loadPDF(at url: URL) async throws -> LocusPDFDocument
}

struct PDFDocumentStore: PDFDocumentStoring {
    /// The current app is unsandboxed, so most calls return `false` here.
    /// Keeping access balanced in this boundary makes later bookmark-backed
    /// document loading explicit instead of scattering scope calls in views.
    func loadPDF(at url: URL) async throws -> LocusPDFDocument {
        let task = Task.detached(priority: .userInitiated) {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            try Task.checkCancellation()

            guard let document = PDFDocument(url: url) else {
                throw PDFDocumentStoreError.cannotOpen
            }

            try Task.checkCancellation()

            return LocusPDFDocument(document: document)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

enum PDFDocumentStoreError: LocalizedError {
    case cannotOpen

    var errorDescription: String? {
        "This PDF file could not be opened."
    }
}
