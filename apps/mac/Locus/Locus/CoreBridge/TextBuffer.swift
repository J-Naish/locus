import Foundation
import os

/// A position in a `TextBuffer`, in every coordinate the editor needs.
struct TextPosition: Equatable, Sendable {
  let byte: Int
  let charIndex: Int
  let utf16: Int
  let line: Int
  let columnUTF16: Int
}

enum TextBufferError: LocalizedError, Equatable, Sendable {
  case invalidArgument(String)
  case io(String)
  case notUTF8
  case invalidOffset
  case invalidRange
  case invalidLine
  case unknown(UInt32)

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let message):
      return message
    case .io(let message):
      return message
    case .notUTF8:
      return "The file is not valid UTF-8 text."
    case .invalidOffset:
      return "The text position is out of range."
    case .invalidRange:
      return "The text range is invalid."
    case .invalidLine:
      return "The line is out of range."
    case .unknown(let status):
      return "The text buffer failed with status \(status)."
    }
  }
}

/// The read-only surface the virtualized editor view needs to render and
/// navigate a document, whether it is backed by an editable ``TextBuffer`` or a
/// read-only ``LargeFile``. Editing stays off this protocol: the view gates
/// mutation behind a concrete ``TextBuffer`` and `isEditable`, so a large
/// read-only file simply has no editable backing.
///
/// Coordinates match the core contract: a line range joins lines with `\n` and
/// strips each line's terminator; a position carries byte/char/UTF-16/line/column;
/// the UTF-16-range read does no terminator stripping. Reads clamp rather than
/// trapping — a viewport read must never fail — so the position methods throw
/// only on an unexpected core/IO error.
///
/// Class-bound: both backends are reference types wrapping a Rust handle, and the
/// view holds one without copying.
protocol TextDocumentReading: AnyObject {
  /// Number of logical lines (`newlines + 1`; an empty document is one line).
  var lineCount: Int { get }
  /// Total content length in bytes.
  var byteLength: Int { get }
  /// Total content length in UTF-16 code units.
  var utf16Length: Int { get }
  /// Monotonic content version, bumped on every edit. A read-only document holds a
  /// constant value, so a cache keyed on it stays valid for the document's life.
  var revision: UInt64 { get }

  /// Maps a UTF-16 offset to a full position.
  func position(forUTF16 utf16: Int) throws -> TextPosition
  /// Maps a 0-based line and UTF-16 column to a full position.
  func position(forLine line: Int, columnUTF16: Int) throws -> TextPosition

  /// Text of lines `[start, start + count)` (clamped), joined by `\n` with each
  /// line's terminator stripped.
  func text(forLineRange start: Int, count: Int) -> String
  /// Like `text(forLineRange:count:)`, but returns at most `maxBytesPerLine` bytes
  /// of any single line's content, so one enormous line never crosses the boundary
  /// in full.
  func text(forLineRange start: Int, count: Int, maxBytesPerLine: Int) -> String
  /// Raw text of the UTF-16 range `[start, end)`, with no terminator stripping —
  /// used to read a window within a long line or to copy a selection.
  func text(fromUTF16 start: Int, toUTF16 end: Int) -> String
}

/// Swift owner of a Rust-backed arbitrary-size text buffer.
///
/// Wraps the `locus_text_buffer_*` C ABI, copying borrowed snapshot text into
/// Swift `String`s before releasing it and freeing the handle on `deinit`.
///
/// Not `Sendable`. The underlying Rust buffer is `Send + Sync`, so concurrent
/// *immutable* reads are safe (the background save reads it while the main thread
/// keeps rendering). Mutations (`insert`/`replace`/`delete`/`undo`/`redo`/
/// `markSaved`) must not overlap any other access; the caller serializes them by
/// pausing edits for the save's duration and keeping all mutation on one actor.
final class TextBuffer {
  private let handle: OpaquePointer
  private static let logger = Logger(subsystem: "com.nash.locus", category: "TextBuffer")

  private init(handle: OpaquePointer) {
    self.handle = handle
  }

  deinit {
    locus_text_buffer_free(handle)
  }

  /// Opens a UTF-8 text file. A non-UTF-8 file throws `.notUTF8`; the caller is
  /// expected to decode legacy encodings and use `open(bytes:)`.
  static func open(at url: URL) throws -> TextBuffer {
    try ensureABICompatible()
    var handle: OpaquePointer?
    let status = url.path(percentEncoded: false).withCString { path in
      locus_text_buffer_open(path, &handle)
    }
    guard status == LOCUS_STATUS_OK, let handle else {
      throw Self.error(for: status)
    }
    return TextBuffer(handle: handle)
  }

  /// Opens a buffer from already-UTF-8 bytes (e.g. content the platform decoded
  /// from a legacy encoding). The bytes are copied.
  static func open(bytes: Data) throws -> TextBuffer {
    try ensureABICompatible()
    var handle: OpaquePointer?
    let status = bytes.withUnsafeBytes { raw -> UInt32 in
      locus_text_buffer_open_bytes(
        raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &handle)
    }
    guard status == LOCUS_STATUS_OK, let handle else {
      throw Self.error(for: status)
    }
    return TextBuffer(handle: handle)
  }

  var lineCount: Int { locus_text_buffer_line_count(handle) }
  var byteLength: Int { locus_text_buffer_byte_length(handle) }
  var utf16Length: Int { locus_text_buffer_utf16_length(handle) }
  var revision: UInt64 { locus_text_buffer_revision(handle) }
  var isDirty: Bool { locus_text_buffer_is_dirty(handle) }

  /// Marks the current content as saved (clears the dirty flag).
  func markSaved() {
    locus_text_buffer_mark_saved(handle)
  }

  /// Writes the full content to the file at `path` (created/truncated), streaming
  /// it through the core so a multi-gigabyte document is not assembled in memory.
  /// The caller owns any atomic-rename / symlink handling.
  func write(toPath path: String) throws {
    let status = path.withCString { locus_text_buffer_write_path(handle, $0) }
    guard status == LOCUS_STATUS_OK else {
      throw Self.error(for: status)
    }
  }

  /// Text of lines `[start, start + count)` (clamped), joined by `\n` with each
  /// line's terminator stripped. The borrowed snapshot is copied before free.
  func text(forLineRange start: Int, count: Int) -> String {
    // Negative indices would wrap to a huge size_t and silently read as empty.
    // A viewport read clamps, so treat invalid input as empty content.
    guard start >= 0, count >= 0 else {
      return ""
    }
    var snapshot: OpaquePointer?
    let status = locus_text_buffer_snapshot_line_range(handle, start, count, &snapshot)
    return Self.decodeSnapshot(status, snapshot, context: "text(forLineRange:)")
  }

  /// Like `text(forLineRange:count:)`, but never returns more than
  /// `maxBytesPerLine` bytes of any single line's content. A file that is one
  /// enormous line therefore never crosses the FFI boundary in full.
  func text(forLineRange start: Int, count: Int, maxBytesPerLine: Int) -> String {
    guard start >= 0, count >= 0, maxBytesPerLine >= 0 else {
      return ""
    }
    var snapshot: OpaquePointer?
    let status = locus_text_buffer_snapshot_line_range_capped(
      handle, start, count, maxBytesPerLine, &snapshot)
    return Self.decodeSnapshot(status, snapshot, context: "text(forLineRange:maxBytesPerLine:)")
  }

  /// Raw text of the UTF-16 range `[start, end)`, with no line-terminator
  /// stripping. Reads just the visible window of one enormous line (intra-line
  /// virtualization) without materializing the line before it. Returns empty for
  /// an out-of-range or surrogate-splitting range rather than throwing, since a
  /// viewport read clamps and must never error.
  func text(fromUTF16 start: Int, toUTF16 end: Int) -> String {
    guard start >= 0, end >= start else {
      return ""
    }
    var snapshot: OpaquePointer?
    let status = locus_text_buffer_snapshot_utf16_range(handle, start, end, &snapshot)
    return Self.decodeSnapshot(status, snapshot, context: "text(fromUTF16:toUTF16:)")
  }

  /// Copies a borrowed snapshot's text into a Swift `String` and frees it,
  /// decoding by the length-counted ABI contract (not a NUL terminator).
  fileprivate static func decodeSnapshot(
    _ status: UInt32, _ snapshot: OpaquePointer?, context: String
  ) -> String {
    guard status == LOCUS_STATUS_OK, let snapshot else {
      if status != LOCUS_STATUS_OK {
        // Snapshots are in-memory, so this is not expected; log so ABI drift or
        // an unexpected failure is visible rather than silently empty.
        logger.error("\(context) failed with status \(status)")
      }
      return ""
    }
    defer { locus_text_snapshot_free(snapshot) }
    guard let text = locus_text_snapshot_text(snapshot) else {
      return ""
    }
    let byteLength = locus_text_snapshot_byte_length(snapshot)
    return String(decoding: UnsafeRawBufferPointer(start: text, count: byteLength), as: UTF8.self)
  }

  func position(forUTF16 utf16: Int) throws -> TextPosition {
    guard utf16 >= 0 else {
      throw TextBufferError.invalidOffset
    }
    var raw = LocusTextPosition()
    let status = locus_text_buffer_position_for_utf16(handle, utf16, &raw)
    guard status == LOCUS_STATUS_OK else {
      throw Self.error(for: status)
    }
    return TextPosition(from: raw)
  }

  func position(forLine line: Int, columnUTF16: Int) throws -> TextPosition {
    guard line >= 0 else {
      throw TextBufferError.invalidLine
    }
    guard columnUTF16 >= 0 else {
      throw TextBufferError.invalidOffset
    }
    var raw = LocusTextPosition()
    let status = locus_text_buffer_position_for_line_column(handle, line, columnUTF16, &raw)
    guard status == LOCUS_STATUS_OK else {
      throw Self.error(for: status)
    }
    return TextPosition(from: raw)
  }

  /// Inserts `text` at a UTF-16 offset. Uses the byte API so text containing a
  /// NUL is handled correctly, and `withUTF8` to avoid an extra full copy.
  func insert(_ text: String, atUTF16 offset: Int) throws {
    guard offset >= 0 else {
      throw TextBufferError.invalidOffset
    }
    var text = text
    let status = text.withUTF8 { buffer in
      locus_text_buffer_insert_bytes(handle, offset, buffer.baseAddress, buffer.count)
    }
    guard status == LOCUS_STATUS_OK else {
      throw Self.error(for: status)
    }
  }

  /// Deletes the UTF-16 range `[start, end)`.
  func delete(fromUTF16 start: Int, toUTF16 end: Int) throws {
    guard start >= 0, end >= 0 else {
      throw TextBufferError.invalidRange
    }
    let status = locus_text_buffer_delete(handle, start, end)
    guard status == LOCUS_STATUS_OK else {
      throw Self.error(for: status)
    }
  }

  /// Replaces the UTF-16 range `[start, end)` with `text` in a single undo step.
  /// Uses the byte API so text containing a NUL is handled, and `withUTF8` to
  /// avoid an extra full copy.
  func replace(_ text: String, fromUTF16 start: Int, toUTF16 end: Int) throws {
    guard start >= 0, end >= 0 else {
      throw TextBufferError.invalidRange
    }
    var text = text
    let status = text.withUTF8 { buffer in
      locus_text_buffer_replace(handle, start, end, buffer.baseAddress, buffer.count)
    }
    guard status == LOCUS_STATUS_OK else {
      throw Self.error(for: status)
    }
  }

  /// Reverts the most recent edit. Returns whether anything was undone.
  @discardableResult
  func undo() throws -> Bool {
    var didUndo = false
    let status = locus_text_buffer_undo(handle, &didUndo)
    guard status == LOCUS_STATUS_OK else {
      throw Self.error(for: status)
    }
    return didUndo
  }

  /// Re-applies the most recently undone edit. Returns whether anything was redone.
  @discardableResult
  func redo() throws -> Bool {
    var didRedo = false
    let status = locus_text_buffer_redo(handle, &didRedo)
    guard status == LOCUS_STATUS_OK else {
      throw Self.error(for: status)
    }
    return didRedo
  }

  // MARK: - Internals

  fileprivate static func ensureABICompatible() throws {
    guard locus_core_is_abi_compatible(CoreBridge.expectedABIVersion) else {
      throw CoreBridgeError.incompatibleABI(
        expected: CoreBridge.expectedABIVersion,
        actual: locus_core_abi_version()
      )
    }
  }

  fileprivate static func error(for status: UInt32) -> TextBufferError {
    switch status {
    case LOCUS_TEXT_STATUS_INVALID_ARGUMENT:
      return .invalidArgument(lastErrorMessage())
    case LOCUS_TEXT_STATUS_IO:
      return .io(lastErrorMessage())
    case LOCUS_TEXT_STATUS_NOT_UTF8:
      return .notUTF8
    case LOCUS_TEXT_STATUS_INVALID_OFFSET:
      return .invalidOffset
    case LOCUS_TEXT_STATUS_INVALID_RANGE:
      return .invalidRange
    case LOCUS_TEXT_STATUS_INVALID_LINE:
      return .invalidLine
    default:
      logger.error("Unknown text buffer status from Rust core: \(status)")
      return .unknown(status)
    }
  }

  private static func lastErrorMessage() -> String {
    guard let message = locus_last_error_message() else {
      return "Rust core error details are unavailable."
    }
    let text = String(cString: message)
    return text.isEmpty ? "Rust core error details are unavailable." : text
  }
}

/// ``TextBuffer`` already exposes the full read surface (it is the editable
/// backend), so its conformance is declaration-only.
extension TextBuffer: TextDocumentReading {}

extension TextPosition {
  fileprivate init(from raw: LocusTextPosition) {
    self.init(
      byte: raw.byte,
      charIndex: raw.char_index,
      utf16: raw.utf16,
      line: raw.line,
      columnUTF16: raw.column_utf16
    )
  }
}

/// Swift owner of a Rust-backed, read-only, line-indexed large file.
///
/// Wraps the `locus_large_file_*` C ABI for files too large to load into an
/// editable ``TextBuffer``: the file is scanned once for a sparse line index,
/// then line ranges are read on demand by window, so the whole file is never
/// resident and an external truncation surfaces as a short read rather than a
/// crash. Frees the handle on `deinit`.
///
/// Read-only by design: it provides the full ``TextDocumentReading`` surface —
/// line and UTF-16 reads plus position mapping — but no editing or saving.
/// Reuses ``TextBuffer``'s snapshot decoding and status-to-error mapping, since
/// it returns the same C ABI snapshot type.
/// `@unchecked Sendable`: the handle is used only for read-only `&self` FFI calls
/// (the Rust line index is `Sync`); it is built off the main thread, then read on
/// the main actor, so handing it across that hop is safe.
final class LargeFile: @unchecked Sendable {
  private let handle: OpaquePointer
  /// Security-scoped access held for the file's lifetime: unlike the editable
  /// buffer (read fully at open), the windowed reads happen after open, so the
  /// scope must outlive `open`. Non-nil only when access was started; released on
  /// `deinit`.
  private let securityScopedURL: URL?

  private init(handle: OpaquePointer, securityScopedURL: URL?) {
    self.handle = handle
    self.securityScopedURL = securityScopedURL
  }

  deinit {
    locus_large_file_free(handle)
    securityScopedURL?.stopAccessingSecurityScopedResource()
  }

  /// Opens `path` as a read-only line-indexed large file, building its line index.
  static func open(at url: URL) throws -> LargeFile {
    try TextBuffer.ensureABICompatible()
    let didStartAccess = url.startAccessingSecurityScopedResource()
    var handle: OpaquePointer?
    let status = url.path(percentEncoded: false).withCString { path in
      locus_large_file_open(path, &handle)
    }
    guard status == LOCUS_STATUS_OK, let handle else {
      if didStartAccess {
        url.stopAccessingSecurityScopedResource()
      }
      throw TextBuffer.error(for: status)
    }
    return LargeFile(handle: handle, securityScopedURL: didStartAccess ? url : nil)
  }

  var lineCount: Int { locus_large_file_line_count(handle) }
  var byteLength: Int { Int(locus_large_file_byte_length(handle)) }
  var utf16Length: Int { locus_large_file_utf16_length(handle) }
  /// A read-only file's content never changes, so its version is a constant. A
  /// band cache keyed on `(revision, range)` therefore stays valid for the
  /// document's whole life — exactly right, since the bytes are immutable.
  var revision: UInt64 { 0 }

  /// Text of lines `[start, start + count)` (clamped), read as one window from the
  /// file. The borrowed snapshot is copied into a Swift `String` before free.
  func text(forLineRange start: Int, count: Int) -> String {
    // A viewport read clamps, so treat invalid input as empty rather than letting
    // a negative wrap to a huge size_t.
    guard start >= 0, count >= 0 else {
      return ""
    }
    var snapshot: OpaquePointer?
    let status = locus_large_file_snapshot_line_range(handle, start, count, &snapshot)
    return TextBuffer.decodeSnapshot(status, snapshot, context: "LargeFile.text(forLineRange:)")
  }

  /// Like `text(forLineRange:count:)`, but never returns more than `maxBytesPerLine`
  /// bytes of any single line's content, so one enormous line never crosses the FFI
  /// in full.
  func text(forLineRange start: Int, count: Int, maxBytesPerLine: Int) -> String {
    guard start >= 0, count >= 0, maxBytesPerLine >= 0 else {
      return ""
    }
    var snapshot: OpaquePointer?
    let status = locus_large_file_snapshot_line_range_capped(
      handle, start, count, maxBytesPerLine, &snapshot)
    return TextBuffer.decodeSnapshot(
      status, snapshot, context: "LargeFile.text(forLineRange:maxBytesPerLine:)")
  }

  /// Raw text of the UTF-16 range `[start, end)`, with no line-terminator stripping
  /// (used to read a window within a long line or to copy a selection). Returns
  /// empty for an inverted range rather than throwing, since a viewport read clamps
  /// and must never error.
  func text(fromUTF16 start: Int, toUTF16 end: Int) -> String {
    guard start >= 0, end >= start else {
      return ""
    }
    var snapshot: OpaquePointer?
    let status = locus_large_file_snapshot_utf16_range(handle, start, end, &snapshot)
    return TextBuffer.decodeSnapshot(
      status, snapshot, context: "LargeFile.text(fromUTF16:toUTF16:)")
  }

  /// Maps a UTF-16 offset to a full position. The core clamps an out-of-range
  /// offset and floors a mid-surrogate offset, so this throws only on an unexpected
  /// core/IO error.
  func position(forUTF16 utf16: Int) throws -> TextPosition {
    guard utf16 >= 0 else {
      throw TextBufferError.invalidOffset
    }
    var raw = LocusTextPosition()
    let status = locus_large_file_position_for_utf16(handle, utf16, &raw)
    guard status == LOCUS_STATUS_OK else {
      throw TextBuffer.error(for: status)
    }
    return TextPosition(from: raw)
  }

  /// Maps a 0-based line and UTF-16 column to a full position. The core clamps a
  /// column past the line end and a line past the last line, so this throws only on
  /// an unexpected core/IO error.
  func position(forLine line: Int, columnUTF16: Int) throws -> TextPosition {
    guard line >= 0 else {
      throw TextBufferError.invalidLine
    }
    guard columnUTF16 >= 0 else {
      throw TextBufferError.invalidOffset
    }
    var raw = LocusTextPosition()
    let status = locus_large_file_position_for_line_column(handle, line, columnUTF16, &raw)
    guard status == LOCUS_STATUS_OK else {
      throw TextBuffer.error(for: status)
    }
    return TextPosition(from: raw)
  }
}

/// A large file is a read-only document peer of ``TextBuffer``: it satisfies the
/// full read surface, with no editable backing.
extension LargeFile: TextDocumentReading {}
