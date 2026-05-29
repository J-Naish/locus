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

      let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
      if let fileSize, fileSize > TextDocumentStore.maximumLoadedTextByteCount {
        throw TextDocumentStoreError.fileTooLarge
      }

      let data = try Data(contentsOf: url)
      if let document = TextDocumentStore.decodeText(from: data) {
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

      try text.write(
        to: url,
        atomically: !TextDocumentStore.isSymbolicLink(at: url),
        encoding: encoding
      )
    }.value
  }

  private static func isSymbolicLink(at url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(
      atPath: url.path(percentEncoded: false)
    )) != nil
  }

  private static func decodeText(from data: Data) -> TextDocument? {
    guard !data.isEmpty else {
      return TextDocument(text: "", encoding: .utf8)
    }

    if hasUTF8ByteOrderMark(data) {
      let contentData = Data(data.dropFirst(3))
      guard let text = String(data: contentData, encoding: .utf8),
        isProbablyText(text)
      else {
        return nil
      }
      return TextDocument(text: text, encoding: .utf8)
    }

    if hasUTF16ByteOrderMark(data) {
      return decodeText(from: data, encodings: [.utf16, .utf16LittleEndian, .utf16BigEndian])
    }

    guard !data.contains(0) else {
      return nil
    }

    return decodeText(from: data, encodings: fallbackEncodings)
  }

  private static func decodeText(
    from data: Data,
    encodings: [String.Encoding]
  ) -> TextDocument? {
    for encoding in encodings {
      if let text = String(data: data, encoding: encoding),
        isProbablyText(text)
      {
        return TextDocument(text: text, encoding: encoding)
      }
    }
    return nil
  }

  private static func hasUTF8ByteOrderMark(_ data: Data) -> Bool {
    data.starts(with: [0xEF, 0xBB, 0xBF])
  }

  private static func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
    data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
  }

  private static func isProbablyText(_ text: String) -> Bool {
    !text.unicodeScalars.contains { scalar in
      let value = scalar.value
      return value == 0
        || (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
        || (value >= 0x7F && value <= 0x9F)
    }
  }

  private static let fallbackEncodings: [String.Encoding] = [
    .utf8,
    .shiftJIS,
    .isoLatin1,
  ]

  private static let maximumLoadedTextByteCount = 16 * 1024 * 1024
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
