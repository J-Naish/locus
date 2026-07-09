import Foundation
import OSLog

enum TerminalBridgeError: LocalizedError, Equatable {
  case incompatibleABI(expected: UInt32, actual: UInt32)
  case invalidArgument(String)
  case corePanic(String)
  case unknown(status: UInt32, message: String)

  var errorDescription: String? {
    switch self {
    case .incompatibleABI(let expected, let actual):
      return "Terminal ABI mismatch. Expected \(expected), got \(actual)."
    case .invalidArgument(let message), .corePanic(let message):
      return message
    case .unknown(let status, let message):
      return "Terminal FFI status \(status): \(message)"
    }
  }
}

enum TerminalPasteResult: Equatable {
  case safe(Data)
  case unsafe
}

enum TerminalDirtyKind: Equatable {
  case none
  case partial
  case full
  case unknown(UInt32)
}

struct TerminalCellFlags: OptionSet, Equatable {
  let rawValue: UInt32

  static let bold = Self(rawValue: 1 << 0)
  static let italic = Self(rawValue: 1 << 1)
  static let faint = Self(rawValue: 1 << 2)
  static let blink = Self(rawValue: 1 << 3)
  static let inverse = Self(rawValue: 1 << 4)
  static let invisible = Self(rawValue: 1 << 5)
  static let strikethrough = Self(rawValue: 1 << 6)
  static let overline = Self(rawValue: 1 << 7)
  static let underline = Self(rawValue: 1 << 8)
}

struct TerminalModifiers: OptionSet, Equatable {
  let rawValue: UInt16

  static let shift = Self(rawValue: 1 << 0)
  static let control = Self(rawValue: 1 << 1)
  static let option = Self(rawValue: 1 << 2)
  static let command = Self(rawValue: 1 << 3)
  static let capsLock = Self(rawValue: 1 << 4)
  static let numLock = Self(rawValue: 1 << 5)
}

enum TerminalCellWidth: UInt8, Equatable {
  case narrow = 0
  case wide = 1
  case spacerHead = 2
  case spacerTail = 3
}

/// Wraps one `locus_term` handle. This class is not thread-safe: use one
/// instance from a single serial execution context. If a call throws
/// `.corePanic`, discard this instance and create a new one.
final class TerminalCore {
  private static let logger = Logger(subsystem: "Locus", category: "TerminalBridge")

  private let handle: OpaquePointer

  init(columns: UInt16, rows: UInt16, maxScrollback: Int = 0) throws {
    try Self.validateABI()

    guard maxScrollback >= 0 else {
      throw TerminalBridgeError.invalidArgument("maxScrollback must be non-negative.")
    }

    guard let handle = locus_term_new(columns, rows, numericCast(maxScrollback)) else {
      let message = terminalLastErrorMessage()
      if message.localizedCaseInsensitiveContains("panic") {
        throw TerminalBridgeError.corePanic(message)
      }
      throw TerminalBridgeError.invalidArgument(message)
    }

    self.handle = handle
  }

  deinit {
    locus_term_free(handle)
  }

  func feed(_ data: Data) throws {
    let status = data.withUnsafeBytes { buffer in
      locus_term_feed(
        handle,
        buffer.bindMemory(to: UInt8.self).baseAddress,
        buffer.count
      )
    }
    try Self.checkStatus(status)
  }

  func takeResponses() throws -> Data {
    var bytes = LocusTermBytes(ptr: nil, len: 0, cap: 0)
    let status = locus_term_take_responses(handle, &bytes)
    try Self.checkStatus(status)
    return Self.copyAndFree(bytes: &bytes)
  }

  func resize(columns: UInt16, rows: UInt16) throws {
    try Self.checkStatus(locus_term_resize(handle, columns, rows))
  }

  func encodeKey(_ event: LocusTermKeyEvent) throws -> Data {
    var mutableEvent = event
    var bytes = LocusTermBytes(ptr: nil, len: 0, cap: 0)
    let status = withUnsafePointer(to: &mutableEvent) { eventPointer in
      locus_term_key(handle, eventPointer, &bytes)
    }
    try Self.checkStatus(status)
    return Self.copyAndFree(bytes: &bytes)
  }

  func encodePaste(_ text: String) throws -> TerminalPasteResult {
    let data = Data(text.utf8)
    var bytes = LocusTermBytes(ptr: nil, len: 0, cap: 0)
    let status = data.withUnsafeBytes { buffer in
      locus_term_paste(
        handle,
        buffer.bindMemory(to: UInt8.self).baseAddress,
        buffer.count,
        &bytes
      )
    }

    if status == LOCUS_TERM_STATUS_UNSAFE_PASTE {
      locus_term_bytes_free(&bytes)
      return .unsafe
    }

    try Self.checkStatus(status)
    return .safe(Self.copyAndFree(bytes: &bytes))
  }

  func scroll(byRows delta: Int) throws {
    try Self.checkStatus(locus_term_scroll(handle, delta))
  }

  func render(into frame: TerminalFrame) throws {
    try Self.checkStatus(locus_term_render(handle, frame.rawPointer, false))
  }

  private static func validateABI() throws {
    let actual = locus_term_abi_version()
    guard actual == LOCUS_TERM_ABI_VERSION else {
      throw TerminalBridgeError.incompatibleABI(
        expected: LOCUS_TERM_ABI_VERSION,
        actual: actual
      )
    }
  }

  private static func checkStatus(_ status: LocusStatus) throws {
    switch status {
    case LOCUS_STATUS_OK:
      return
    case LOCUS_TERM_STATUS_INVALID_ARGUMENT:
      throw TerminalBridgeError.invalidArgument(terminalLastErrorMessage())
    case LOCUS_TERM_STATUS_PANIC:
      throw TerminalBridgeError.corePanic(terminalLastErrorMessage())
    default:
      Self.logger.error("Unknown terminal status from Rust core: \(status)")
      assertionFailure("Unknown terminal status: \(status)")
      throw TerminalBridgeError.unknown(status: status, message: terminalLastErrorMessage())
    }
  }

  private static func copyAndFree(bytes: inout LocusTermBytes) -> Data {
    defer {
      locus_term_bytes_free(&bytes)
    }

    guard bytes.len > 0, let pointer = bytes.ptr else {
      return Data()
    }
    return Data(bytes: pointer, count: bytes.len)
  }
}

/// Reusable terminal render target. The row, cell, and grapheme buffers are
/// owned by Rust and remain valid until the next render into this frame or
/// until the frame is freed.
final class TerminalFrame {
  fileprivate let rawPointer: UnsafeMutablePointer<LocusTermFrame>

  init() throws {
    guard let frame = locus_term_frame_new() else {
      throw TerminalBridgeError.corePanic(terminalLastErrorMessage())
    }

    rawPointer = frame
  }

  deinit {
    locus_term_frame_free(rawPointer)
  }

  var dirtyKind: TerminalDirtyKind {
    switch rawPointer.pointee.dirty_state {
    case LOCUS_TERM_DIRTY_NONE:
      return .none
    case LOCUS_TERM_DIRTY_PARTIAL:
      return .partial
    case LOCUS_TERM_DIRTY_FULL:
      return .full
    default:
      return .unknown(rawPointer.pointee.dirty_state)
    }
  }

  var cursor: LocusTermCursor {
    rawPointer.pointee.cursor
  }

  var columns: UInt16 {
    rawPointer.pointee.cols
  }

  var rows: UInt16 {
    rawPointer.pointee.rows
  }

  func withRows<R>(_ body: (UnsafeBufferPointer<LocusTermRow>) throws -> R) rethrows -> R {
    try body(
      UnsafeBufferPointer(
        start: rawPointer.pointee.rows_ptr,
        count: rawPointer.pointee.row_count
      )
    )
  }

  func withCells<R>(_ body: (UnsafeBufferPointer<LocusTermCell>) throws -> R) rethrows -> R {
    try body(
      UnsafeBufferPointer(
        start: rawPointer.pointee.cells_ptr,
        count: rawPointer.pointee.cell_count
      )
    )
  }

  func withGraphemes<R>(_ body: (UnsafeBufferPointer<UInt32>) throws -> R) rethrows -> R {
    try body(
      UnsafeBufferPointer(
        start: rawPointer.pointee.graphemes_ptr,
        count: rawPointer.pointee.grapheme_count
      )
    )
  }

  func plainText() -> String {
    let rows = UnsafeBufferPointer(
      start: rawPointer.pointee.rows_ptr,
      count: rawPointer.pointee.row_count
    )
    let cells = UnsafeBufferPointer(
      start: rawPointer.pointee.cells_ptr,
      count: rawPointer.pointee.cell_count
    )
    let graphemes = UnsafeBufferPointer(
      start: rawPointer.pointee.graphemes_ptr,
      count: rawPointer.pointee.grapheme_count
    )

    var lines: [String] = []
    lines.reserveCapacity(rows.count)
    for row in rows {
      let end = min(row.cell_start + row.cell_count, cells.count)
      var line = ""
      if row.cell_start < end {
        for cell in cells[row.cell_start..<end] {
          guard TerminalCellWidth(rawValue: cell.wide) != .spacerTail else {
            continue
          }

          if let scalar = UnicodeScalar(cell.codepoint), cell.codepoint != 0 {
            line.unicodeScalars.append(scalar)
          } else {
            line.append(" ")
          }

          let graphemeEnd = min(cell.grapheme_start + cell.grapheme_len, graphemes.count)
          if cell.grapheme_start < graphemeEnd {
            for codepoint in graphemes[cell.grapheme_start..<graphemeEnd] {
              if let scalar = UnicodeScalar(codepoint) {
                line.unicodeScalars.append(scalar)
              }
            }
          }
        }
      }
      lines.append(line.trimmingCharacters(in: .whitespaces))
    }

    while lines.last?.isEmpty == true {
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }
}

enum PtyError: LocalizedError, Equatable {
  case invalidArgument(String)
  case io(String)
  case wouldBlock(String)
  case childExec(String)
  case timeout(String)
  case corePanic(String)
  case spawnFailed(String)
  case unknown(status: UInt32, message: String)

  var errorDescription: String? {
    switch self {
    case .invalidArgument(let message),
      .io(let message),
      .wouldBlock(let message),
      .childExec(let message),
      .timeout(let message),
      .corePanic(let message),
      .spawnFailed(let message):
      return message
    case .unknown(let status, let message):
      return "PTY FFI status \(status): \(message)"
    }
  }
}

/// Wraps one `locus_pty` handle. This class is not thread-safe: use one
/// instance from a single serial execution context. If a call throws
/// `.corePanic`, discard this instance and create a new one.
final class PtySession {
  private static let logger = Logger(subsystem: "Locus", category: "PtyBridge")

  private let handle: OpaquePointer

  init(
    command: String,
    arguments: [String] = [],
    environment: [(String, String)] = [],
    currentDirectory: String? = nil,
    columns: UInt16,
    rows: UInt16
  ) throws {
    handle = try Self.spawn(
      command: command,
      arguments: arguments,
      environment: environment,
      currentDirectory: currentDirectory,
      columns: columns,
      rows: rows
    )
  }

  deinit {
    locus_pty_free(handle)
  }

  var masterFileDescriptor: Int32 {
    locus_pty_master_fd(handle)
  }

  /// Reads available bytes from the nonblocking PTY. A return value of `0`
  /// means either no bytes are currently available or EOF has been reached;
  /// callers should combine this with `tryWait()` to distinguish process exit.
  func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
    var outLength = 0
    let status = locus_pty_read(
      handle,
      buffer.bindMemory(to: UInt8.self).baseAddress,
      buffer.count,
      &outLength
    )
    if status == LOCUS_PTY_STATUS_WOULD_BLOCK {
      return 0
    }
    try Self.checkStatus(status)
    return outLength
  }

  func write(_ data: Data) throws -> Int {
    var outLength = 0
    let status = data.withUnsafeBytes { buffer in
      locus_pty_write(
        handle,
        buffer.bindMemory(to: UInt8.self).baseAddress,
        buffer.count,
        &outLength
      )
    }
    try Self.checkStatus(status)
    return outLength
  }

  func resize(columns: UInt16, rows: UInt16) throws {
    try Self.checkStatus(locus_pty_resize(handle, columns, rows))
  }

  func tryWait() throws -> LocusPtyExitStatus? {
    var status = LocusPtyExitStatus(exited: false, code: -1, signal: 0)
    try Self.checkStatus(locus_pty_try_wait(handle, &status))
    return status.exited ? status : nil
  }

  func shutdown() throws {
    try Self.checkStatus(locus_pty_shutdown(handle))
  }

  private static func spawn(
    command: String,
    arguments: [String],
    environment: [(String, String)],
    currentDirectory: String?,
    columns: UInt16,
    rows: UInt16
  ) throws -> OpaquePointer {
    try withPtyString(command.isEmpty ? nil : command) { commandString in
      try withPtyString(currentDirectory) { cwdString in
        try withPtyStrings(arguments) { argumentStrings in
          try withPtyStrings(environment.map(\.0)) { environmentKeys in
            try withPtyStrings(environment.map(\.1)) { environmentValues in
              let envVars = zip(environmentKeys, environmentValues).map { key, value in
                LocusPtyEnvVar(key: key, value: value)
              }

              return try argumentStrings.withUnsafeBufferPointer { argsBuffer in
                try envVars.withUnsafeBufferPointer { envBuffer in
                  var options = LocusPtyOptions(
                    cols: columns,
                    rows: rows,
                    command: commandString,
                    args: argsBuffer.baseAddress,
                    args_len: argsBuffer.count,
                    cwd: cwdString,
                    env: envBuffer.baseAddress,
                    env_len: envBuffer.count
                  )
                  guard let handle = locus_pty_spawn(&options) else {
                    throw PtyError.spawnFailed(terminalLastErrorMessage())
                  }
                  return handle
                }
              }
            }
          }
        }
      }
    }
  }

  private static func checkStatus(_ status: LocusStatus) throws {
    switch status {
    case LOCUS_STATUS_OK:
      return
    case LOCUS_PTY_STATUS_INVALID_ARGUMENT:
      throw PtyError.invalidArgument(terminalLastErrorMessage())
    case LOCUS_PTY_STATUS_IO:
      throw PtyError.io(terminalLastErrorMessage())
    case LOCUS_PTY_STATUS_WOULD_BLOCK:
      throw PtyError.wouldBlock(terminalLastErrorMessage())
    case LOCUS_PTY_STATUS_CHILD_EXEC:
      throw PtyError.childExec(terminalLastErrorMessage())
    case LOCUS_PTY_STATUS_TIMEOUT:
      throw PtyError.timeout(terminalLastErrorMessage())
    case LOCUS_PTY_STATUS_PANIC:
      throw PtyError.corePanic(terminalLastErrorMessage())
    default:
      Self.logger.error("Unknown PTY status from Rust core: \(status)")
      assertionFailure("Unknown PTY status: \(status)")
      throw PtyError.unknown(status: status, message: terminalLastErrorMessage())
    }
  }
}

private func withPtyString<R>(
  _ text: String?,
  _ body: (LocusPtyString) throws -> R
) rethrows -> R {
  guard let text else {
    return try body(LocusPtyString(ptr: nil, len: 0))
  }

  let bytes = Array(text.utf8)
  return try bytes.withUnsafeBufferPointer { buffer in
    try body(LocusPtyString(ptr: buffer.baseAddress, len: buffer.count))
  }
}

private func withPtyStrings<R>(
  _ texts: [String],
  _ body: ([LocusPtyString]) throws -> R
) rethrows -> R {
  let bytes = texts.map { Array($0.utf8) }
  var strings: [LocusPtyString] = []
  strings.reserveCapacity(bytes.count)

  func recurse(_ index: Int) throws -> R {
    guard index < bytes.count else {
      return try body(strings)
    }

    return try bytes[index].withUnsafeBufferPointer { buffer in
      strings.append(LocusPtyString(ptr: buffer.baseAddress, len: buffer.count))
      defer {
        strings.removeLast()
      }
      return try recurse(index + 1)
    }
  }

  return try recurse(0)
}

private func terminalLastErrorMessage() -> String {
  guard let message = locus_last_error_message() else {
    return "Rust core error details are unavailable."
  }

  let text = String(cString: message)
  return text.isEmpty ? "Rust core error details are unavailable." : text
}
