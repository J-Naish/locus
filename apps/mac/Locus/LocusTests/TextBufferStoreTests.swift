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

    try TextBufferStore().save(buffer, to: url)
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "bye")
  }

  func testSavePreservesUneditedCRLFBytes() throws {
    let url = temporaryFileURL()
    try Data("a\r\nb".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let buffer = try TextBuffer.open(at: url)
    try buffer.insert("X", atUTF16: 0)  // edit only the start; CRLF must survive

    try TextBufferStore().save(buffer, to: url)
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
    try TextBufferStore().save(buffer, to: link)

    // The link still points at the target, and the target now holds the edit.
    XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "updated!")
  }
}
