import Foundation

enum TextBufferStoreError: LocalizedError {
  /// A non-UTF-8 (or BOM-prefixed) file is too large to decode, since that path
  /// must read the whole file into memory. Large files are supported only as
  /// UTF-8 (memory-mapped). Editing in a legacy encoding stays a small-file path.
  case tooLargeForEncoding
  /// The bytes do not look like text in any supported encoding.
  case notRecognizedAsText

  var errorDescription: String? {
    switch self {
    case .tooLargeForEncoding:
      return
        "This file is too large to open in its (non-UTF-8) encoding. Large files are supported only as UTF-8."
    case .notRecognizedAsText:
      return "The file does not appear to be a text document."
    }
  }
}

/// Opens and saves a `TextBuffer`, preserving the file's original text encoding.
///
/// Opening keeps the zero-copy path for the common case: a UTF-8 file (without a
/// BOM) is memory-mapped, so a multi-gigabyte file is never read onto the heap.
/// A byte-order mark, or bytes that are not valid UTF-8, route to a Foundation
/// decode (Shift JIS / UTF-16 / Latin-1), which materializes the file — those
/// legacy-encoded files are small in practice.
///
/// Saving streams UTF-8 straight to disk (still zero-copy for huge files); a
/// non-UTF-8 file is re-encoded to its original encoding (refusing, rather than
/// losing, characters that cannot be represented). It writes atomically for a
/// regular file and in place through a symlink (so the link target is updated).
struct TextBufferStore {
  /// Largest file the decode (non-UTF-8 / BOM) path will read into memory. UTF-8
  /// files bypass this via memory-mapping, so only legacy-encoded files are
  /// bounded. Injectable so tests can exercise the boundary cheaply.
  static let defaultMaximumDecodedByteCount = 64 * 1024 * 1024
  let maximumDecodedByteCount: Int

  init(maximumDecodedByteCount: Int = TextBufferStore.defaultMaximumDecodedByteCount) {
    self.maximumDecodedByteCount = maximumDecodedByteCount
  }

  func open(at url: URL) throws -> (buffer: TextBuffer, encoding: String.Encoding) {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    // A BOM would otherwise be mapped as content, so decode it explicitly.
    if Self.hasByteOrderMark(at: url) {
      return try decodeFully(at: url)
    }
    // No BOM: try the zero-copy UTF-8 memory-map; fall back to a decode only when
    // the bytes are not valid UTF-8 (legacy encodings).
    do {
      return (try TextBuffer.open(at: url), .utf8)
    } catch TextBufferError.notUTF8 {
      return try decodeFully(at: url)
    }
  }

  func save(_ buffer: TextBuffer, to url: URL, encoding: String.Encoding = .utf8) throws {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    if encoding == .utf8 {
      // Stream the buffer straight to disk — no full-document materialization.
      try writeAtomically(to: url) { destination in
        try buffer.write(toPath: destination.path(percentEncoded: false))
      }
      return
    }

    // Legacy encoding: materialize the (small) content and re-encode it.
    let text = try utf8Text(of: buffer, siblingOf: url)
    let data = try TextEncoding.encode(text, as: encoding)
    try writeAtomically(to: url) { destination in
      try data.write(to: destination)
    }
  }

  /// Reads `data` from disk and decodes it to UTF-8-backed buffer bytes. Bounded
  /// by `maximumDecodedByteCount`, since this path reads the whole file into
  /// memory (unlike the memory-mapped UTF-8 path).
  private func decodeFully(at url: URL) throws -> (buffer: TextBuffer, encoding: String.Encoding) {
    let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    if let fileSize, fileSize > maximumDecodedByteCount {
      throw TextBufferStoreError.tooLargeForEncoding
    }
    let data = try Data(contentsOf: url)
    guard let document = TextEncoding.decode(data) else {
      throw TextBufferStoreError.notRecognizedAsText
    }
    return (try TextBuffer.open(bytes: Data(document.text.utf8)), document.encoding)
  }

  /// The buffer's exact content as a UTF-8 string, via a sibling temp file so the
  /// streaming write path is reused (no content-snapshot FFI needed).
  private func utf8Text(of buffer: TextBuffer, siblingOf url: URL) throws -> String {
    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".locus-reencode-\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try buffer.write(toPath: temporaryURL.path(percentEncoded: false))
    return String(decoding: try Data(contentsOf: temporaryURL), as: UTF8.self)
  }

  /// Writes via `write` using the atomic-vs-symlink policy: through a symlink in
  /// place, otherwise to a sibling temp file then replaced.
  private func writeAtomically(to url: URL, _ write: (URL) throws -> Void) throws {
    if Self.isSymbolicLink(at: url) {
      try write(url)
      return
    }
    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".locus-save-\(UUID().uuidString).tmp")
    do {
      try write(temporaryURL)
      if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporaryURL)
      } else {
        try FileManager.default.moveItem(at: temporaryURL, to: url)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  private static func hasByteOrderMark(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else {
      return false
    }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 3)) ?? Data()
    return head.starts(with: [0xEF, 0xBB, 0xBF])  // UTF-8 BOM
      || head.starts(with: [0xFF, 0xFE])  // UTF-16 LE BOM
      || head.starts(with: [0xFE, 0xFF])  // UTF-16 BE BOM
  }

  private static func isSymbolicLink(at url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(
      atPath: url.path(percentEncoded: false)
    )) != nil
  }
}
