import Foundation

/// Writes a `TextBuffer`'s content to disk. The buffer streams its bytes through
/// the Rust core, so even a multi-gigabyte document is never assembled in memory
/// to save it. Mirrors the atomic-vs-symlink write policy used by the editable
/// text path (`TextDocumentStore.saveText`): a regular file is replaced
/// atomically via a sibling temp file, while a symlink is written through in
/// place (so the link target, not the link, is updated).
struct TextBufferStore {
  func save(_ buffer: TextBuffer, to url: URL) throws {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }

    if Self.isSymbolicLink(at: url) {
      try buffer.write(toPath: url.path(percentEncoded: false))
      return
    }

    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".locus-save-\(UUID().uuidString).tmp")
    do {
      try buffer.write(toPath: temporaryURL.path(percentEncoded: false))
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

  private static func isSymbolicLink(at url: URL) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(
      atPath: url.path(percentEncoded: false)
    )) != nil
  }
}
