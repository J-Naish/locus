import Darwin
import XCTest

@testable import Locus

final class TerminalBridgeTests: XCTestCase {
  func testInitAndDeinitRoundTrip() throws {
    do {
      _ = try TerminalCore(columns: 80, rows: 24)
      _ = try TerminalFrame()
    }
  }

  func testInitRejectsOversizedDimensions() throws {
    XCTAssertThrowsError(try TerminalCore(columns: 5000, rows: 24)) { error in
      guard case TerminalBridgeError.invalidArgument(let message) = error else {
        XCTFail("Expected invalidArgument, got \(error)")
        return
      }
      XCTAssertTrue(message.contains("4096"), "Unexpected message: \(message)")
    }
  }

  func testABIVersionMatchesHeader() {
    XCTAssertEqual(TerminalCore.abiVersion, TerminalCore.expectedABIVersion)
  }

  func testFeedAndRenderPlainText() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    let frame = try TerminalFrame()

    try terminal.feed(Data("hello".utf8))
    try terminal.render(into: frame)

    XCTAssertTrue(frame.plainText().contains("hello"))
    XCTAssertEqual(frame.dirtyKind, .full)
  }

  func testSecondRenderReportsPartialThenNone() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    let frame = try TerminalFrame()

    try terminal.render(into: frame)
    try terminal.feed(Data("x".utf8))
    try terminal.render(into: frame)
    XCTAssertEqual(frame.dirtyKind, .partial)

    try terminal.render(into: frame)
    XCTAssertEqual(frame.dirtyKind, .none)
  }

  func testDeviceAttributesQueryProducesResponse() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)

    try terminal.feed(Data([0x1B, 0x5B, 0x63]))
    let response = try terminal.takeResponses()

    XCTAssertFalse(response.isEmpty)
    XCTAssertEqual(response.first, 0x1B)
  }

  func testResizeChangesFrameDimensions() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    let frame = try TerminalFrame()

    try terminal.resize(columns: 40, rows: 10)
    try terminal.render(into: frame)

    XCTAssertEqual(frame.columns, 40)
    XCTAssertEqual(frame.rows, 10)
  }

  func testEncodeKeyEnterIsCarriageReturn() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    let event = keyEvent(action: LOCUS_TERM_ACTION_PRESS, key: LOCUS_TERM_KEY_ENTER)

    XCTAssertEqual(try terminal.encodeKey(event), Data([0x0D]))
  }

  func testEncodeKeyCtrlCIsEtx() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    let bytes = Array("c".utf8)
    let encoded = try bytes.withUnsafeBufferPointer { buffer in
      let event = keyEvent(
        action: LOCUS_TERM_ACTION_PRESS,
        key: LOCUS_TERM_KEY_UNIDENTIFIED,
        mods: TerminalModifiers.control.rawValue,
        utf8: buffer.baseAddress,
        utf8Length: buffer.count,
        unshiftedCodepoint: UInt32(UnicodeScalar("c").value)
      )
      return try terminal.encodeKey(event)
    }

    XCTAssertEqual(encoded, Data([0x03]))
  }

  func testPasteSafeText() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)

    XCTAssertEqual(try terminal.encodePaste("hello"), .safe(Data("hello".utf8)))
  }

  func testPasteUnsafeTextIsFlagged() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)

    XCTAssertEqual(try terminal.encodePaste("a\nb"), .unsafe)
  }

  func testEncodePasteMultilineRequiresConfirmationWhenUnbracketed() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)

    XCTAssertEqual(try terminal.encodePaste("a\nb"), .unsafe)
    XCTAssertEqual(
      try terminal.encodePaste("a\nb", allowUnsafe: true),
      .safe(Data("a\rb".utf8))
    )
  }

  func testEncodePasteMultilineIsSafeInBracketedMode() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    try terminal.feed(Data("\u{1B}[?2004h".utf8))

    let result = try terminal.encodePaste("a\nb")
    guard case .safe(let data) = result else {
      return XCTFail("Expected bracketed multiline paste to be safe")
    }
    let prefix = Data("\u{1B}[200~".utf8)
    let suffix = Data("\u{1B}[201~".utf8)
    XCTAssertTrue(data.starts(with: prefix))
    XCTAssertEqual(data.suffix(suffix.count), suffix)
  }

  func testScrollbackRetainsHistoryAcrossScroll() throws {
    let terminal = try TerminalCore(
      columns: 20,
      rows: 5,
      maxScrollback: TerminalSession.defaultMaxScrollbackBytes
    )
    let frame = try TerminalFrame()
    for line in 1...40 {
      try terminal.feed(Data("L\(line)\r\n".utf8))
    }

    try terminal.render(into: frame, full: true)
    XCTAssertFalse(frame.plainText().contains("L1"))
    try terminal.scroll(byRows: -36)
    try terminal.render(into: frame, full: true)
    XCTAssertTrue(
      frame.plainText().contains("L1"),
      "Scrolled frame was: \(frame.plainText())"
    )
  }

  func testFrameCursorTracksPrinting() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    let frame = try TerminalFrame()

    try terminal.feed(Data("ab".utf8))
    try terminal.render(into: frame)

    XCTAssertEqual(frame.cursor.x, 2)
    XCTAssertEqual(frame.cursor.y, 0)
  }

  func testFrameExposesABIV3ScrollMetadata() throws {
    let terminal = try TerminalCore(
      columns: 20,
      rows: 5,
      maxScrollback: TerminalSession.defaultMaxScrollbackBytes
    )
    let frame = try TerminalFrame()
    for line in 1...20 {
      try terminal.feed(Data("L\(line)\r\n".utf8))
    }

    try terminal.render(into: frame, full: true)
    XCTAssertEqual(frame.scrollDelta, 0)
    XCTAssertEqual(frame.viewportOffsetRows, 0)
    XCTAssertGreaterThanOrEqual(frame.totalRows, 20)
    XCTAssertTrue(frame.atBottom)

    try terminal.scroll(byRows: -4)
    try terminal.render(into: frame, full: true)
    XCTAssertEqual(frame.viewportOffsetRows, 4)
    XCTAssertFalse(frame.atBottom)
  }

  func testGraphemeExtrasSurviveToPlainText() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    let frame = try TerminalFrame()

    try terminal.feed(Data("👨‍💻".utf8))
    try terminal.render(into: frame)

    XCTAssertTrue(frame.plainText().contains("👨‍💻"))
  }

  func testPtyEchoRoundTrip() throws {
    let session = try PtySession(
      command: "/bin/echo",
      arguments: ["hello"],
      columns: 80,
      rows: 24
    )

    let output = try read(from: session, untilContaining: "hello")
    let text = String(data: output, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("hello"), "Output was: \(text)")

    let status = try waitForExit(session)
    XCTAssertEqual(status.code, 0)
  }

  func testPtyCatWriteReadRoundTrip() throws {
    let session = try PtySession(command: "/bin/cat", columns: 80, rows: 24)

    _ = try session.write(Data("abc\n".utf8))
    let output = try read(from: session, untilContaining: "abc")
    let text = String(data: output, encoding: .utf8) ?? ""
    XCTAssertTrue(text.contains("abc"), "Output was: \(text)")

    try session.shutdown()
  }

  func testPtyMasterFdIsUsable() throws {
    let session = try PtySession(command: "/bin/cat", columns: 80, rows: 24)

    let fd = session.masterFileDescriptor
    XCTAssertGreaterThanOrEqual(fd, 0)
    let flags = fcntl(fd, F_GETFD)
    XCTAssertNotEqual(flags, -1)
    XCTAssertNotEqual(flags & FD_CLOEXEC, 0)

    try session.shutdown()
  }
}

private func keyEvent(
  action: UInt32,
  key: UInt32,
  mods: UInt16 = 0,
  utf8: UnsafePointer<UInt8>? = nil,
  utf8Length: Int = 0,
  unshiftedCodepoint: UInt32 = 0
) -> LocusTermKeyEvent {
  LocusTermKeyEvent(
    action: action,
    key: key,
    mods: mods,
    consumed_mods: 0,
    composing: false,
    utf8: utf8,
    utf8_len: utf8Length,
    unshifted_codepoint: unshiftedCodepoint
  )
}

private func read(
  from session: PtySession,
  untilContaining expectedText: String,
  timeout: TimeInterval = 2.0
) throws -> Data {
  let deadline = Date().addingTimeInterval(timeout)
  var output = Data()
  var buffer = [UInt8](repeating: 0, count: 4096)

  while Date() < deadline {
    let count = try buffer.withUnsafeMutableBytes { rawBuffer in
      try session.read(into: rawBuffer)
    }
    if count > 0 {
      output.append(contentsOf: buffer.prefix(count))
      let text = String(data: output, encoding: .utf8) ?? ""
      if text.contains(expectedText) {
        return output
      }
    } else {
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  return output
}

private func waitForExit(
  _ session: PtySession,
  timeout: TimeInterval = 2.0
) throws -> LocusPtyExitStatus {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if let status = try session.tryWait() {
      return status
    }
    Thread.sleep(forTimeInterval: 0.01)
  }
  XCTFail("Timed out waiting for PTY process to exit")
  return LocusPtyExitStatus(exited: false, code: -1, signal: 0)
}
