import Foundation

/// Keeps recently opened text documents' live buffers alive across file switches,
/// so unsaved edits survive navigating away and back — until the document is
/// saved, reloaded, or evicted. Unsaved (dirty) buffers are always retained; clean
/// buffers are evicted least-recently-used once the cache exceeds `maxRetained`,
/// bounding how many memory-mapped files are held at once.
///
/// Each entry also remembers the file fingerprint the buffer was last in sync with
/// (at open or save), so switching back to an inactive document can detect an
/// external change that happened while it was not being monitored.
///
/// This is the model foundation the planned tab UI will build on; for now it just
/// removes the silent loss of edits when switching files in the sidebar. It is
/// `@MainActor`-isolated because it holds non-`Sendable` `TextBuffer`s.
@MainActor
final class OpenDocumentCache: ObservableObject {
  private struct Entry {
    let buffer: TextBuffer
    let encoding: String.Encoding
    var fingerprint: DocumentFileFingerprint?
    var lastUsedTick: Int
  }

  private var entries: [String: Entry] = [:]
  private var tick = 0

  /// How many documents to keep. Dirty documents are kept beyond this; only clean
  /// ones are evicted, so unsaved edits are never dropped to honor the limit.
  let maxRetained: Int

  init(maxRetained: Int = 8) {
    self.maxRetained = maxRetained
  }

  var count: Int { entries.count }

  func contains(forKey key: String) -> Bool { entries[key] != nil }

  /// Whether the cached buffer for `key` has unsaved edits. Read directly from the
  /// buffer so it does not lag a surface-level mirror of the dirty state.
  func isDirty(forKey key: String) -> Bool { entries[key]?.buffer.isDirty ?? false }

  /// The cached buffer for `key`, if present, marked most-recently-used.
  func cached(forKey key: String) -> (buffer: TextBuffer, encoding: String.Encoding)? {
    guard var entry = entries[key] else { return nil }
    tick += 1
    entry.lastUsedTick = tick
    entries[key] = entry
    return (entry.buffer, entry.encoding)
  }

  /// The disk fingerprint the cached buffer for `key` was last in sync with, used
  /// to detect an external change while the document was inactive.
  func fingerprint(forKey key: String) -> DocumentFileFingerprint? {
    entries[key]?.fingerprint
  }

  /// Updates the in-sync fingerprint for an existing entry (after a save or after
  /// an external change is reconciled).
  func setFingerprint(_ fingerprint: DocumentFileFingerprint?, forKey key: String) {
    guard var entry = entries[key] else { return }
    entry.fingerprint = fingerprint
    entries[key] = entry
  }

  /// Stores a freshly opened buffer with the disk fingerprint it matches, then
  /// evicts clean least-recently-used entries beyond the retention limit.
  func store(
    buffer: TextBuffer, encoding: String.Encoding, fingerprint: DocumentFileFingerprint?,
    forKey key: String
  ) {
    tick += 1
    entries[key] = Entry(
      buffer: buffer, encoding: encoding, fingerprint: fingerprint, lastUsedTick: tick)
    evictIfNeeded()
  }

  /// Drops `key` so the next open reads fresh content from disk. Used when an
  /// edit-discarding reload is requested (conflict reload or a clean external
  /// change).
  func drop(forKey key: String) {
    entries.removeValue(forKey: key)
  }

  private func evictIfNeeded() {
    while entries.count > maxRetained {
      // Evict the least-recently-used clean entry; never drop unsaved edits.
      guard
        let victim =
          entries
          .filter({ !$0.value.buffer.isDirty })
          .min(by: { $0.value.lastUsedTick < $1.value.lastUsedTick })?
          .key
      else {
        break  // everything retained is dirty — keep it (bounded by edits in flight)
      }
      entries.removeValue(forKey: victim)
    }
  }
}
