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
  static let defaultMaximumLoadedTextByteCount = 64 * 1024 * 1024

  /// The largest file (in bytes) Locus loads as an editable text document.
  /// Files above this fail with `fileTooLarge`. Injectable so tests can exercise
  /// the boundary without writing large fixtures.
  let maximumLoadedTextByteCount: Int

  init(maximumLoadedTextByteCount: Int = TextDocumentStore.defaultMaximumLoadedTextByteCount) {
    self.maximumLoadedTextByteCount = maximumLoadedTextByteCount
  }

  /// The current app is unsandboxed, so most calls return `false` here.
  /// Keeping access balanced in this boundary makes later bookmark-backed
  /// document loading explicit instead of scattering scope calls in views.
  func loadText(at url: URL) async throws -> TextDocument {
    let maximumByteCount = maximumLoadedTextByteCount
    return try await Task.detached(priority: .userInitiated) {
      let didStartAccess = url.startAccessingSecurityScopedResource()
      defer {
        if didStartAccess {
          url.stopAccessingSecurityScopedResource()
        }
      }

      let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
      if let fileSize, fileSize > maximumByteCount {
        throw TextDocumentStoreError.fileTooLarge
      }

      let data = try Data(contentsOf: url)
      if let document = TextEncoding.decode(data) {
        return document
      }
      throw TextDocumentStoreError.notRecognizedAsText
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

      let data = try TextEncoding.encode(text, as: encoding)
      // Atomic for a regular file; in place through a symlink so the link target
      // (not the link) is updated. Matches the buffer-backed save policy.
      let options: Data.WritingOptions =
        TextDocumentStore.isSymbolicLink(at: url) ? [] : [.atomic]
      try data.write(to: url, options: options)
    }.value
  }

  private static func isSymbolicLink(at url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(
      atPath: url.path(percentEncoded: false)
    )) != nil
  }
}

enum TextDocumentStoreError: LocalizedError {
  case fileTooLarge
  case notRecognizedAsText

  var errorDescription: String? {
    switch self {
    case .fileTooLarge:
      return "The file is too large to open as a text document."
    case .notRecognizedAsText:
      return "The file does not appear to be a text document."
    }
  }
}
