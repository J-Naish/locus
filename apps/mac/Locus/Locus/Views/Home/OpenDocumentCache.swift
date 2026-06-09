import Foundation

/// Keeps recently opened text documents' live buffers alive across file switches,
/// so unsaved edits survive navigating away and back — until the document is
/// saved, reloaded, or evicted. Unsaved (dirty) buffers are always retained; clean
/// buffers are evicted least-recently-used once the cache exceeds either the
/// document count limit (`maxRetained`) or the total retained-bytes budget
/// (`maxRetainedByteCount`), bounding both how many files and how much memory are
/// held at once. The single most-recently-used document is always kept, so the
/// active document is never dropped to satisfy the byte budget.
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

  /// Total retained buffer bytes to stay under. A count limit alone lets a few
  /// large files pin a lot of memory (the editable buffer cap is 256 MiB each, so
  /// eight of them could hold ~2 GiB), so clean least-recently-used buffers are
  /// also evicted once their combined byte length exceeds this budget. Dirty
  /// buffers and the single most-recently-used document are kept regardless.
  let maxRetainedByteCount: Int

  /// Default total retained-bytes budget (see `maxRetainedByteCount`). Generously
  /// holds many ordinary documents while capping the few-large-files worst case.
  /// `nonisolated` so it can be used as an `init` default argument.
  nonisolated static let defaultMaxRetainedByteCount = 128 * 1024 * 1024  // 128 MiB

  init(
    maxRetained: Int = 8, maxRetainedByteCount: Int = OpenDocumentCache.defaultMaxRetainedByteCount
  ) {
    self.maxRetained = maxRetained
    self.maxRetainedByteCount = maxRetainedByteCount
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

  private var totalRetainedByteCount: Int {
    entries.values.reduce(0) { $0 + $1.buffer.byteLength }
  }

  private func evictIfNeeded() {
    while entries.count > maxRetained || totalRetainedByteCount > maxRetainedByteCount {
      // Never evict the most-recently-used entry: it is the active document, and
      // dropping it to honor the byte budget would defeat the cache. Among the
      // rest, evict the least-recently-used clean entry; never drop unsaved edits.
      let mostRecentlyUsedKey =
        entries.max(by: { $0.value.lastUsedTick < $1.value.lastUsedTick })?.key
      guard
        let victim =
          entries
          .filter({ $0.key != mostRecentlyUsedKey && !$0.value.buffer.isDirty })
          .min(by: { $0.value.lastUsedTick < $1.value.lastUsedTick })?
          .key
      else {
        break  // only the active document and dirty buffers remain — keep them
      }
      entries.removeValue(forKey: victim)
    }
  }
}
