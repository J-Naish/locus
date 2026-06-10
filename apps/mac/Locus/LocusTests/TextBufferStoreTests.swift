import XCTest

@testable import Locus

final class TextBufferStoreTests: XCTestCase {
  private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("locus-store-\(UUID().uuidString).txt")
  }

  func testSavesEditedBufferContentToDisk() throws {
    let url = temporaryFileURL()
    try Data("hello".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let buffer = try TextBuffer.open(at: url)
    try buffer.replace("bye", fromUTF16: 0, toUTF16: 5)
    XCTAssertTrue(buffer.isDirty)

    try TextBufferStore().save(XCTUnwrap(buffer.takeSaveSnapshot()), to: url)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bye")
  }

  func testSavePreservesUneditedCRLFBytes() throws {
    let url = temporaryFileURL()
    try Data("a\r\nb".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let buffer = try TextBuffer.open(at: url)
    try buffer.insert("X", atUTF16: 0)  // edit only the start; CRLF must survive

    try TextBufferStore().save(XCTUnwrap(buffer.takeSaveSnapshot()), to: url)
    XCTAssertEqual(try Data(contentsOf: url), Data("Xa\r\nb".utf8))
  }

  func testSaveWritesThroughASymbolicLink() throws {
    // A symlinked path must update the link target, not replace the link.
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("locus-store-symlink-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let target = directory.appendingPathComponent("target.txt")
    let link = directory.appendingPathComponent("link.txt")
    try Data("original".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    let buffer = try TextBuffer.open(at: link)
    try buffer.replace("updated!", fromUTF16: 0, toUTF16: 8)
    try TextBufferStore().save(XCTUnwrap(buffer.takeSaveSnapshot()), to: link)

    // The link still points at the target, and the target now holds the edit.
    XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "updated!")
  }

  // MARK: Encoding round-trip

  func testOpensPlainUTF8ViaTheZeroCopyPath() throws {
    let url = temporaryFileURL()
    try Data("héllo\n".utf8).write(to: url)  // multibyte UTF-8, no BOM
    defer { try? FileManager.default.removeItem(at: url) }

    let opened = try TextBufferStore().open(at: url)
    XCTAssertEqual(opened.encoding, .utf8)
    XCTAssertEqual(opened.buffer.utf16Length, ("héllo\n" as NSString).length)
  }

  func testOpensAndStripsUTF8ByteOrderMark() throws {
    let url = temporaryFileURL()
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(Data("hello\n".utf8))
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let opened = try TextBufferStore().open(at: url)
    XCTAssertEqual(opened.encoding, .utf8)
    XCTAssertEqual(opened.buffer.utf16Length, 6)  // "hello\n" — BOM stripped
  }

  func testRoundTripsShiftJISPreservingEncoding() throws {
    let url = temporaryFileURL()
    try XCTUnwrap("あ\n".data(using: .shiftJIS)).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TextBufferStore()

    let opened = try store.open(at: url)
    XCTAssertEqual(opened.encoding, .shiftJIS)

    try opened.buffer.replace("請求書\n", fromUTF16: 0, toUTF16: opened.buffer.utf16Length)
    try store.save(XCTUnwrap(opened.buffer.takeSaveSnapshot()), to: url, encoding: opened.encoding)

    let data = try Data(contentsOf: url)
    XCTAssertNil(String(data: data, encoding: .utf8))  // not rewritten as UTF-8
    XCTAssertEqual(String(data: data, encoding: .shiftJIS), "請求書\n")
  }

  func testRoundTripsUTF16PreservingEncoding() throws {
    let url = temporaryFileURL()
    var data = Data([0xFF, 0xFE])  // UTF-16 LE BOM
    data.append(try XCTUnwrap("hi\n".data(using: .utf16LittleEndian)))
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TextBufferStore()

    let opened = try store.open(at: url)
    XCTAssertEqual(opened.encoding, .utf16LittleEndian)

    try opened.buffer.replace("やあ\n", fromUTF16: 0, toUTF16: opened.buffer.utf16Length)
    try store.save(XCTUnwrap(opened.buffer.takeSaveSnapshot()), to: url, encoding: opened.encoding)

    let saved = try Data(contentsOf: url)
    XCTAssertEqual(saved.prefix(2), Data([0xFF, 0xFE]))  // LE BOM preserved
    XCTAssertEqual(String(data: saved, encoding: .utf16), "やあ\n")
  }

  func testRoundTripsUTF16BigEndianPreservingByteOrder() throws {
    let url = temporaryFileURL()
    var data = Data([0xFE, 0xFF])  // UTF-16 BE BOM
    data.append(try XCTUnwrap("hi\n".data(using: .utf16BigEndian)))
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TextBufferStore()

    let opened = try store.open(at: url)
    XCTAssertEqual(opened.encoding, .utf16BigEndian)

    try opened.buffer.replace("ねこ\n", fromUTF16: 0, toUTF16: opened.buffer.utf16Length)
    try store.save(XCTUnwrap(opened.buffer.takeSaveSnapshot()), to: url, encoding: opened.encoding)

    let saved = try Data(contentsOf: url)
    XCTAssertEqual(saved.prefix(2), Data([0xFE, 0xFF]))  // big-endian byte order kept
    XCTAssertEqual(String(data: saved, encoding: .utf16), "ねこ\n")
  }

  func testSaveRefusesCharactersUnrepresentableInOriginalEncoding() throws {
    let url = temporaryFileURL()
    try XCTUnwrap("あ\n".data(using: .shiftJIS)).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let store = TextBufferStore()

    let opened = try store.open(at: url)
    try opened.buffer.replace("😀\n", fromUTF16: 0, toUTF16: opened.buffer.utf16Length)

    let snapshot = try XCTUnwrap(opened.buffer.takeSaveSnapshot())
    XCTAssertThrowsError(try store.save(snapshot, to: url, encoding: opened.encoding)) {
      error in
      guard case TextEncoding.CodingError.unrepresentable = error else {
        return XCTFail("expected unrepresentable, got \(error)")
      }
    }
    // The refused save left the original file untouched.
    XCTAssertEqual(String(data: try Data(contentsOf: url), encoding: .shiftJIS), "あ\n")
  }

  func testRejectsLegacyEncodedFileLargerThanDecodeCap() throws {
    let url = temporaryFileURL()
    try XCTUnwrap("あいうえお\n".data(using: .shiftJIS)).write(to: url)  // ~11 bytes
    defer { try? FileManager.default.removeItem(at: url) }
    // A larger budget applies to plain UTF-8; a legacy-encoded file over the
    // decode cap is refused rather than read fully into memory.
    let store = TextBufferStore(maximumDecodedByteCount: 4)

    XCTAssertThrowsError(try store.open(at: url)) { error in
      guard case TextBufferStoreError.tooLargeForEncoding = error else {
        return XCTFail("expected tooLargeForEncoding, got \(error)")
      }
    }
  }

  func testRefusesToOpenUTF8FileLargerThanOpenCap() throws {
    let url = temporaryFileURL()
    try Data("hello".utf8).write(to: url)  // 5 bytes, plain UTF-8 (no BOM)
    defer { try? FileManager.default.removeItem(at: url) }
    // A file over the open cap is refused rather than read into memory.
    let store = TextBufferStore(maximumOpenByteCount: 4)

    XCTAssertThrowsError(try store.open(at: url)) { error in
      guard case TextBufferStoreError.tooLargeToOpen = error else {
        return XCTFail("expected tooLargeToOpen, got \(error)")
      }
    }
  }
}
