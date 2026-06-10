import XCTest

@testable import Locus

final class TextBufferTests: XCTestCase {
  func testOpensBytesAndReadsLines() throws {
    let buffer = try TextBuffer.open(bytes: Data("ab\ncde".utf8))
    XCTAssertEqual(buffer.lineCount, 2)
    XCTAssertEqual(buffer.utf16Length, 6)
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 2), "ab\ncde")
    XCTAssertFalse(buffer.isDirty)
  }

  func testCappedLineRangeTruncatesLongLinesButKeepsNeighbors() throws {
    let long = String(repeating: "x", count: 5_000)
    let buffer = try TextBuffer.open(bytes: Data("a\n\(long)\nb".utf8))
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 3, maxBytesPerLine: 5), "a\nxxxxx\nb")
    // A generous cap leaves short lines unchanged.
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1, maxBytesPerLine: 1_000), "a")
  }

  func testCappedLineRangeRejectsNegativeInputs() throws {
    let buffer = try TextBuffer.open(bytes: Data("abc".utf8))
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1, maxBytesPerLine: -1), "")
    XCTAssertEqual(buffer.text(forLineRange: -1, count: 1, maxBytesPerLine: 10), "")
  }

  func testRejectsInvalidUTF8() {
    XCTAssertThrowsError(try TextBuffer.open(bytes: Data([0xFF, 0xFE, 0x00]))) {
      XCTAssertEqual($0 as? TextBufferError, .notUTF8)
    }
  }

  func testInsertDeleteUndoRedo() throws {
    let buffer = try TextBuffer.open(bytes: Data("ac".utf8))
    try buffer.insert("b", atUTF16: 1)
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1), "abc")
    XCTAssertTrue(buffer.isDirty)

    XCTAssertNotNil(try buffer.undo())
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1), "ac")
    XCTAssertNotNil(try buffer.redo())
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1), "abc")

    try buffer.delete(fromUTF16: 0, toUTF16: 1)
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1), "bc")
  }

  func testUndoAndRedoReportTheRewrittenSpan() throws {
    // "😀" is 2 UTF-16 units, so the offsets prove the span is UTF-16-based.
    // Replace "bc" (2 units at offset 3) with "XX\nYY" (5 units).
    let buffer = try TextBuffer.open(bytes: Data("😀abc".utf8))
    try buffer.replace("XX\nYY", fromUTF16: 3, toUTF16: 5)

    let undone = try XCTUnwrap(buffer.undo())
    XCTAssertEqual(undone, TextChange(startUTF16: 3, oldLengthUTF16: 5, newLengthUTF16: 2))

    let redone = try XCTUnwrap(buffer.redo())
    XCTAssertEqual(redone, TextChange(startUTF16: 3, oldLengthUTF16: 2, newLengthUTF16: 5))

    XCTAssertNil(try buffer.redo())  // nothing left to redo reports nil, not zeros
  }

  func testReadSnapshotIsIsolatedAndDoesNotSealTypingRun() throws {
    let buffer = try TextBuffer.open(bytes: Data("hi\nthere".utf8))
    try buffer.insert("a", atUTF16: 2)

    let snapshot = try XCTUnwrap(buffer.takeReadSnapshot())
    try buffer.insert("b", atUTF16: 3)  // keeps coalescing into the same run

    // The snapshot reads the content from the moment it was taken.
    XCTAssertEqual(snapshot.lineCount, 2)
    XCTAssertEqual(snapshot.utf16Length, 9)
    XCTAssertEqual(snapshot.text(forLineRange: 0, count: 2, maxBytesPerLine: 1024), "hia\nthere")
    let position = try snapshot.position(forLine: 1, columnUTF16: 99)
    XCTAssertEqual(position.line, 1)
    XCTAssertEqual(position.columnUTF16, 5)  // clamped to "there"
    XCTAssertThrowsError(try snapshot.position(forLine: 9, columnUTF16: 0))

    // One undo reverts the whole typed run: taking a read snapshot mid-run did
    // not split it (unlike a save snapshot, which seals deliberately).
    XCTAssertNotNil(try buffer.undo())
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 2), "hi\nthere")
  }

  func testReadSnapshotServesReadsOffTheMainActor() async throws {
    // The wrap measurement reads snapshots on a detached task; pin that the
    // reads answer correctly off-main while the live buffer is edited on-main.
    let buffer = try TextBuffer.open(bytes: Data("alpha\nbeta\ngamma".utf8))
    let snapshot = try XCTUnwrap(buffer.takeReadSnapshot())
    try buffer.replace("rewritten", fromUTF16: 0, toUTF16: buffer.utf16Length)

    let lines = await Task.detached(priority: .userInitiated) {
      (0..<snapshot.lineCount).map { line in
        snapshot.text(forLineRange: line, count: 1, maxBytesPerLine: 64)
      }
    }.value

    XCTAssertEqual(lines, ["alpha", "beta", "gamma"])
  }

  func testMarkSavedClearsDirty() throws {
    let buffer = try TextBuffer.open(bytes: Data("a".utf8))
    try buffer.insert("b", atUTF16: 1)
    XCTAssertTrue(buffer.isDirty)
    buffer.markSaved()
    XCTAssertFalse(buffer.isDirty)
  }

  func testMarkSavedAndClearHistoryReleasesUndoRecords() throws {
    let buffer = try TextBuffer.open(bytes: Data(String(repeating: "a", count: 1024).utf8))
    try buffer.replace("b", fromUTF16: 0, toUTF16: buffer.utf16Length)
    XCTAssertTrue(buffer.isDirty)
    XCTAssertGreaterThan(buffer.historyByteLength, 0)

    buffer.markSavedAndClearHistory()

    XCTAssertFalse(buffer.isDirty)
    XCTAssertEqual(buffer.historyByteLength, 0)
    XCTAssertNil(try buffer.undo())
  }

  func testHistoryByteLimitPrunesOldUndoRecords() throws {
    let buffer = try TextBuffer.open(bytes: Data("abcdef".utf8))
    try buffer.setHistoryByteLimit(4)
    try buffer.replace("A", fromUTF16: 0, toUTF16: 1)
    try buffer.replace("C", fromUTF16: 2, toUTF16: 3)
    try buffer.replace("E", fromUTF16: 4, toUTF16: 5)

    XCTAssertLessThanOrEqual(buffer.historyByteLength, 4)
    XCTAssertNotNil(try buffer.undo())
    XCTAssertNotNil(try buffer.undo())
    XCTAssertNil(try buffer.undo())
  }

  func testInsertHandlesMultibyteAndNUL() throws {
    let buffer = try TextBuffer.open(bytes: Data("aあ".utf8))
    // Insert after "aあ" (UTF-16 offset 2) text that contains a NUL.
    try buffer.insert("X\u{0}", atUTF16: 2)
    // The snapshot is length-counted, so the embedded NUL is preserved.
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1), "aあX\u{0}")
  }

  func testPositionConversionsRoundTrip() throws {
    let buffer = try TextBuffer.open(bytes: Data("ab\ncde".utf8))
    let position = try buffer.position(forUTF16: 4)
    XCTAssertEqual(position.line, 1)
    XCTAssertEqual(position.columnUTF16, 1)
    XCTAssertEqual(position.byte, 4)

    let roundTrip = try buffer.position(forLine: position.line, columnUTF16: position.columnUTF16)
    XCTAssertEqual(roundTrip.utf16, 4)
  }

  func testInvalidOffsetThrows() throws {
    let buffer = try TextBuffer.open(bytes: Data("ab".utf8))
    XCTAssertThrowsError(try buffer.position(forUTF16: 99)) {
      XCTAssertEqual($0 as? TextBufferError, .invalidOffset)
    }
  }

  func testOpensEmptyData() throws {
    let buffer = try TextBuffer.open(bytes: Data())
    XCTAssertEqual(buffer.lineCount, 1)
    XCTAssertEqual(buffer.utf16Length, 0)
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1), "")
  }

  func testInsertingEmptyStringIsHarmless() throws {
    let buffer = try TextBuffer.open(bytes: Data("ab".utf8))
    try buffer.insert("", atUTF16: 1)
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 1), "ab")
    XCTAssertFalse(buffer.isDirty)
  }

  func testInvalidLineThrows() throws {
    let buffer = try TextBuffer.open(bytes: Data("a\nb".utf8))
    XCTAssertThrowsError(try buffer.position(forLine: 9, columnUTF16: 0)) {
      XCTAssertEqual($0 as? TextBufferError, .invalidLine)
    }
  }

  func testInvalidRangeThrows() throws {
    let buffer = try TextBuffer.open(bytes: Data("abc".utf8))
    XCTAssertThrowsError(try buffer.delete(fromUTF16: 2, toUTF16: 1)) {
      XCTAssertEqual($0 as? TextBufferError, .invalidRange)
    }
  }

  func testRevisionAdvancesOnEdit() throws {
    let buffer = try TextBuffer.open(bytes: Data("a".utf8))
    let before = buffer.revision
    try buffer.insert("b", atUTF16: 1)
    XCTAssertGreaterThan(buffer.revision, before)
  }

  func testManyBuffersFreeCleanly() throws {
    // Exercises deinit/free repeatedly (catches double-free/leak regressions
    // under sanitizers).
    for _ in 0..<100 {
      let buffer = try TextBuffer.open(bytes: Data("hello\nworld".utf8))
      XCTAssertEqual(buffer.lineCount, 2)
    }
  }

  func testRejectsNegativeInputs() throws {
    let buffer = try TextBuffer.open(bytes: Data("abc".utf8))
    // Reads clamp invalid input to empty rather than wrapping to a huge size_t.
    XCTAssertEqual(buffer.text(forLineRange: -1, count: 1), "")
    XCTAssertEqual(buffer.text(forLineRange: 0, count: -5), "")
    // Throwing APIs reject negatives in Swift before they reach the FFI.
    XCTAssertThrowsError(try buffer.position(forUTF16: -1)) {
      XCTAssertEqual($0 as? TextBufferError, .invalidOffset)
    }
    XCTAssertThrowsError(try buffer.position(forLine: -1, columnUTF16: 0)) {
      XCTAssertEqual($0 as? TextBufferError, .invalidLine)
    }
    XCTAssertThrowsError(try buffer.insert("x", atUTF16: -1)) {
      XCTAssertEqual($0 as? TextBufferError, .invalidOffset)
    }
    XCTAssertThrowsError(try buffer.delete(fromUTF16: -1, toUTF16: 2)) {
      XCTAssertEqual($0 as? TextBufferError, .invalidRange)
    }
  }

  func testOpensFileFromDisk() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "locus-text-buffer-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "doc.txt")
    try "hello\nworld".write(to: url, atomically: true, encoding: .utf8)

    let buffer = try TextBuffer.open(at: url)
    XCTAssertEqual(buffer.lineCount, 2)
    XCTAssertEqual(buffer.text(forLineRange: 0, count: 2), "hello\nworld")
  }
}
