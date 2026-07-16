import Darwin
import XCTest

@testable import Locus

final class TerminalBridgeTests: XCTestCase {
  func testLinkRoundTripThroughFeed() throws {
    let terminal = try TerminalCore(columns: 40, rows: 8)
    try terminal.feed(Data("https://example.com".utf8))

    let matches = try terminal.viewportLinks()

    XCTAssertEqual(
      matches,
      [TerminalLinkMatch(y: 0, xStart: 0, xEnd: 18, linkID: 0)]
    )
    XCTAssertEqual(try terminal.linkURI(UInt32(matches[0].linkID)), "https://example.com")
  }

  func testDecodeLinkMatchesHandlesStrideAndTruncation() {
    var data = Data()
    for value: UInt16 in [2, 3, 5, 7, 11, 13, 17, 19] {
      var nativeValue = value
      withUnsafeBytes(of: &nativeValue) { data.append(contentsOf: $0) }
    }

    XCTAssertEqual(
      TerminalCore.decodeLinkMatches(data),
      [
        TerminalLinkMatch(y: 2, xStart: 3, xEnd: 5, linkID: 7),
        TerminalLinkMatch(y: 11, xStart: 13, xEnd: 17, linkID: 19),
      ]
    )
    XCTAssertEqual(
      TerminalCore.decodeLinkMatches(Data(data.prefix(12))),
      [TerminalLinkMatch(y: 2, xStart: 3, xEnd: 5, linkID: 7)]
    )
  }

  func testSearchRoundTripThroughFeed() throws {
    let terminal = try TerminalCore(columns: 40, rows: 8)
    try terminal.feed(Data("Fizz\r\nBuzz\r\nFizz".utf8))

    try terminal.searchStart(Data("Fizz".utf8))

    XCTAssertEqual(
      try terminal.searchStatus(),
      TerminalSearchStatus(active: true, complete: true, total: 2, selectedIndex: nil)
    )
    let matches = try terminal.searchViewportMatches()
    XCTAssertEqual(matches.count, 2)
    XCTAssertTrue(matches.allSatisfy { !$0.isSelected })

    XCTAssertEqual(try terminal.searchSelect(.next).selectedIndex, 0)
    XCTAssertEqual(try terminal.searchViewportMatches().filter(\.isSelected).count, 1)

    try terminal.searchEnd()
    try terminal.searchEnd()
    XCTAssertEqual(
      try terminal.searchStatus(),
      TerminalSearchStatus(active: false, complete: false, total: 0, selectedIndex: nil)
    )
  }

  func testDecodeSearchMatchesHandlesStrideAndTruncation() {
    var data = Data()
    for value: UInt16 in [2, 3, 5, 0, 7, 11, 13, 1] {
      var nativeValue = value
      withUnsafeBytes(of: &nativeValue) { data.append(contentsOf: $0) }
    }
    XCTAssertEqual(
      TerminalCore.decodeSearchMatches(data),
      [
        TerminalSearchMatch(y: 2, xStart: 3, xEnd: 5, isSelected: false),
        TerminalSearchMatch(y: 7, xStart: 11, xEnd: 13, isSelected: true),
      ]
    )
    XCTAssertEqual(
      TerminalCore.decodeSearchMatches(Data(data.prefix(12))),
      [TerminalSearchMatch(y: 2, xStart: 3, xEnd: 5, isSelected: false)]
    )
  }

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

  func testKeyProtocolActiveTracksXtermKittyAndReset() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    XCTAssertEqual(terminal.keyProtocolActive, [])

    try terminal.feed(Data("\u{1B}[>4;2m".utf8))
    XCTAssertEqual(terminal.keyProtocolActive, [.modifyOtherKeys])

    try terminal.feed(Data("\u{1B}[=1;1u".utf8))
    XCTAssertEqual(terminal.keyProtocolActive, [.modifyOtherKeys, .kittyKeyboard])

    try terminal.feed(Data("\u{1B}c".utf8))
    XCTAssertEqual(terminal.keyProtocolActive, [])
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

  func testTakeClipboardWriteCopiesAndClearsPendingData() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)
    try terminal.feed(Data("\u{1B}]52;c;aGVsbG8=\u{07}".utf8))

    XCTAssertEqual(try terminal.takeClipboardWrite(), Data("hello".utf8))
    XCTAssertNil(try terminal.takeClipboardWrite())
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

  func testFrameExposesABIV4ScrollMetadata() throws {
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

  func testSelectionGestureAndStringRoundTripThroughBridge() throws {
    let terminal = try TerminalCore(columns: 12, rows: 4)
    let frame = try TerminalFrame()
    try terminal.feed(Data("abcdef".utf8))

    try terminal.selectionGesture(.press, column: 1, row: 0)
    try terminal.selectionGesture(.drag, column: 4, row: 0)
    try terminal.selectionGesture(.release, column: 4, row: 0)
    try terminal.render(into: frame, full: true)

    XCTAssertEqual(try terminal.selectionString(), "bcd")
    XCTAssertEqual(frame.selectionRange(forRow: 0), 1...3)

    try terminal.clearSelection()
    try terminal.render(into: frame, full: true)
    XCTAssertNil(frame.selectionRange(forRow: 0))
  }

  func testLatestTitleAndPwdReportRoundTrip() throws {
    let terminal = try TerminalCore(columns: 80, rows: 24)

    try terminal.feed(Data("\u{1B}]2;bridge-title\u{07}".utf8))
    try terminal.feed(Data("\u{1B}]7;file:///tmp/locus%20p3\u{07}".utf8))
    XCTAssertEqual(try terminal.latestTitle(), "bridge-title")
    XCTAssertEqual(
      try terminal.latestWorkingDirectoryReport(),
      "file:///tmp/locus%20p3"
    )

    try terminal.feed(Data("\u{1B}]2;\u{07}".utf8))
    try terminal.feed(Data("\u{1B}]7;\u{07}".utf8))
    XCTAssertEqual(try terminal.latestTitle(), "")
    XCTAssertEqual(try terminal.latestWorkingDirectoryReport(), "")
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
