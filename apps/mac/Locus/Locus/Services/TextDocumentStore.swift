import Foundation

struct TextDocument: Equatable, Sendable {
    let text: String
    let encoding: String.Encoding
}

protocol TextDocumentStoring: Sendable {
    func loadText(at url: URL) async throws -> TextDocument
    func saveText(_ text: String, to url: URL, encoding: String.Encoding) async throws
}

struct TextDocumentStore: TextDocumentStoring {
    /// The current app is unsandboxed, so most calls return `false` here.
    /// Keeping access balanced in this boundary makes later bookmark-backed
    /// document loading explicit instead of scattering scope calls in views.
    func loadText(at url: URL) async throws -> TextDocument {
        try await Task.detached(priority: .userInitiated) {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            do {
                var encoding = String.Encoding.utf8
                let text = try String(contentsOf: url, usedEncoding: &encoding)
                return TextDocument(text: text, encoding: encoding)
            } catch {
                let data = try Data(contentsOf: url)
                if let document = TextDocumentStore.decodeFallbackText(from: data) {
                    return document
                }
                throw error
            }
        }.value
    }

    func saveText(_ text: String, to url: URL, encoding: String.Encoding) async throws {
        try await Task.detached(priority: .userInitiated) {
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            try text.write(to: url, atomically: true, encoding: encoding)
        }.value
    }

    private static func decodeFallbackText(from data: Data) -> TextDocument? {
        for encoding in fallbackEncodings {
            if let text = String(data: data, encoding: encoding) {
                return TextDocument(text: text, encoding: encoding)
            }
        }
        return nil
    }

    private static let fallbackEncodings: [String.Encoding] = [
        .utf8,
        .shiftJIS,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
        .isoLatin1
    ]
}
