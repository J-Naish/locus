import Foundation

enum TextBufferStoreError: LocalizedError {
  /// A non-UTF-8 (or BOM-prefixed) file is too large to decode, since that path
  /// must read the whole file into memory. A larger budget applies to plain
  /// UTF-8; editing in a legacy encoding stays a small-file path.
  case tooLargeForEncoding
  /// The file is larger than the buffer will read into memory, so it is refused
  /// rather than opened. Realistic documents sit far below this bound.
  case tooLargeToOpen
  /// The bytes do not look like text in any supported encoding.
  case notRecognizedAsText

  var errorDescription: String? {
    switch self {
    case .tooLargeForEncoding:
      return
        "This file is too large to open in its (non-UTF-8) encoding. A larger limit applies to plain UTF-8 files."
    case .tooLargeToOpen:
      return "This file is too large to open."
    case .notRecognizedAsText:
      return "The file does not appear to be a text document."
    }
  }
}

/// Opens and saves a `TextBuffer`, preserving the file's original text encoding.
///
/// Opening reads the file into the buffer, which owns its bytes — there is no
/// memory map, so an external truncation can never fault the process. A plain
/// UTF-8 file takes the direct path; a byte-order mark, or bytes that are not
/// valid UTF-8, route to a Foundation decode (Shift JIS / UTF-16 / Latin-1).
/// Both paths are bounded by a maximum size so a pathologically large file is
/// refused rather than read into memory; realistic documents sit far below it.
///
/// Saving streams UTF-8 straight to disk without materializing a full copy; a
/// non-UTF-8 file is re-encoded to its original encoding (refusing, rather than
/// losing, characters that cannot be represented). It writes through an atomic
/// replacement for both regular files and symlink targets, so a crash during
/// save does not leave a truncated document behind.
struct TextBufferStore {
  /// Largest plain-UTF-8 file `open` loads into the editable in-memory buffer
  /// (worst-case editable RAM ≈ this size). A larger file is refused here; the
  /// document surface routes it to the read-only windowed viewer instead.
  /// Injectable so tests can exercise the boundary cheaply.
  static let defaultMaximumOpenByteCount = 256 * 1024 * 1024  // 256 MiB
  /// Largest file the decode (non-UTF-8 / BOM) path will read into memory. Lower
  /// than the UTF-8 bound because decoding allocates more; legacy-encoded files
  /// are small in practice. Injectable so tests can exercise the boundary cheaply.
  static let defaultMaximumDecodedByteCount = 64 * 1024 * 1024
  let maximumOpenByteCount: Int
  let maximumDecodedByteCount: Int

  init(
    maximumOpenByteCount: Int = TextBufferStore.defaultMaximumOpenByteCount,
    maximumDecodedByteCount: Int = TextBufferStore.defaultMaximumDecodedByteCount
  ) {
    self.maximumOpenByteCount = maximumOpenByteCount
    self.maximumDecodedByteCount = maximumDecodedByteCount
  }

  func open(at url: URL) throws -> (buffer: TextBuffer, encoding: String.Encoding) {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    // A BOM is decoded explicitly rather than landing in the buffer as content.
    if Self.hasByteOrderMark(at: url) {
      return try decodeFully(at: url)
    }
    // No BOM: read the file as UTF-8 into the buffer, which owns its bytes (no
    // memory map, so an external truncation can't fault the process). Bound the
    // size first so a pathologically large file is refused, not read into memory.
    let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    if let fileSize, fileSize > maximumOpenByteCount {
      throw TextBufferStoreError.tooLargeToOpen
    }
    do {
      return (try TextBuffer.open(at: url), .utf8)
    } catch TextBufferError.notUTF8 {
      return try decodeFully(at: url)
    }
  }

  func save(_ snapshot: TextBufferSnapshot, to url: URL, encoding: String.Encoding = .utf8) throws {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    if encoding == .utf8 {
      // Stream the snapshot straight to disk — no full-document materialization.
      try writeAtomically(to: url) { destination in
        try snapshot.write(toPath: destination.path(percentEncoded: false))
      }
      return
    }

    // Legacy encoding: materialize the (small) content and re-encode it.
    let text = try utf8Text(of: snapshot)
    let data = try TextEncoding.encode(text, as: encoding)
    try writeAtomically(to: url) { destination in
      try data.write(to: destination)
    }
  }

  /// Reads `data` from disk and decodes it to UTF-8-backed buffer bytes. Bounded
  /// by `maximumDecodedByteCount`, lower than the UTF-8 read bound because
  /// decoding allocates more than a direct read.
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

  /// The snapshot's exact content as a UTF-8 string, via a process temp file so
  /// the streaming write path is reused without touching the user's folder.
  private func utf8Text(of snapshot: TextBufferSnapshot) throws -> String {
    let temporaryURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-reencode-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try snapshot.write(toPath: temporaryURL.path(percentEncoded: false))
    return String(decoding: try Data(contentsOf: temporaryURL), as: UTF8.self)
  }

  /// Writes via `write` to a temporary replacement item, then atomically swaps it
  /// into place. If `url` is a symlink, the symlink itself is preserved and its
  /// target is replaced atomically instead of being truncated in place.
  private func writeAtomically(to url: URL, _ write: (URL) throws -> Void) throws {
    let destinationURL = try Self.atomicWriteDestination(for: url)
    let fileManager = FileManager.default
    let destinationPath = destinationURL.path(percentEncoded: false)
    let appropriateURL =
      fileManager.fileExists(atPath: destinationPath)
      ? destinationURL : destinationURL.deletingLastPathComponent()
    let replacementDirectory = try fileManager.url(
      for: .itemReplacementDirectory,
      in: .userDomainMask,
      appropriateFor: appropriateURL,
      create: true
    )
    defer { try? fileManager.removeItem(at: replacementDirectory) }
    let temporaryURL =
      replacementDirectory
      .appending(path: "locus-save-\(UUID().uuidString).tmp", directoryHint: .notDirectory)

    do {
      try write(temporaryURL)
      if fileManager.fileExists(atPath: destinationPath) {
        _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw error
    }
  }

  private static func atomicWriteDestination(for url: URL) throws -> URL {
    let path = url.path(percentEncoded: false)
    guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
      return url
    }

    if destination.hasPrefix("/") {
      return URL(filePath: destination)
    }
    return URL(
      fileURLWithPath: destination,
      relativeTo: url.deletingLastPathComponent()
    )
    .standardizedFileURL
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

}
