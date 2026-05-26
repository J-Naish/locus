import XCTest

@testable import Locus

final class TextDocumentStoreTests: XCTestCase {
  func testLoadsUTF8TextDocument() async throws {
    let url = try temporaryFile(named: "notes.md", contents: "# Notes\n\nこんにちは\n")
    let store = TextDocumentStore()

    let text = try await store.loadText(at: url)

    XCTAssertEqual(text.text, "# Notes\n\nこんにちは\n")
    XCTAssertEqual(text.encoding, .utf8)
  }

  func testSavesUTF8TextDocument() async throws {
    let url = try temporaryFile(named: "settings.yaml", contents: "title: Old\n")
    let store = TextDocumentStore()

    try await store.saveText("title: New\nowner: finance\n", to: url, encoding: .utf8)

    XCTAssertEqual(
      try String(contentsOf: url, encoding: .utf8),
      "title: New\nowner: finance\n"
    )
  }

  func testLoadEditSaveReloadRoundTrip() async throws {
    let url = try temporaryFile(named: "draft.md", contents: "# Draft\n\nOriginal\n")
    let store = TextDocumentStore()

    let loaded = try await store.loadText(at: url)
    try await store.saveText(
      loaded.text.replacingOccurrences(of: "Original", with: "Updated"),
      to: url,
      encoding: loaded.encoding
    )
    let reloaded = try await store.loadText(at: url)

    XCTAssertEqual(reloaded.text, "# Draft\n\nUpdated\n")
    XCTAssertEqual(reloaded.encoding, loaded.encoding)
  }

  func testPreservesNonUTF8EncodingWhenSaving() async throws {
    let originalText = "title: 日本語\n"
    let url = try temporaryFile(
      named: "shift-jis.yaml",
      data: try XCTUnwrap(originalText.data(using: .shiftJIS))
    )
    let store = TextDocumentStore()

    let loaded = try await store.loadText(at: url)
    try await store.saveText(
      loaded.text.replacingOccurrences(of: "日本語", with: "請求書"),
      to: url,
      encoding: loaded.encoding
    )

    let savedData = try Data(contentsOf: url)
    XCTAssertNil(String(data: savedData, encoding: .utf8))
    XCTAssertEqual(String(data: savedData, encoding: .shiftJIS), "title: 請求書\n")
  }

  func testLoadsExtensionlessUTF8TextDocument() async throws {
    let url = try temporaryFile(named: ".customignore", contents: "target/\n*.tmp\n")
    let store = TextDocumentStore()

    let loaded = try await store.loadText(at: url)

    XCTAssertEqual(loaded.text, "target/\n*.tmp\n")
    XCTAssertEqual(loaded.encoding, .utf8)
  }

  func testStripsUTF8ByteOrderMarkOnLoad() async throws {
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(try XCTUnwrap("hello\n".data(using: .utf8)))
    let url = try temporaryFile(named: "notes", data: data)
    let store = TextDocumentStore()

    let loaded = try await store.loadText(at: url)

    XCTAssertEqual(loaded.text, "hello\n")
    XCTAssertEqual(loaded.encoding, .utf8)
  }

  func testLoadsUTF16LittleEndianTextDocumentWithByteOrderMark() async throws {
    let text = "hello\nこんにちは\n"
    var data = Data([0xFF, 0xFE])
    data.append(try XCTUnwrap(text.data(using: .utf16LittleEndian)))
    let url = try temporaryFile(named: "notes", data: data)
    let store = TextDocumentStore()

    let loaded = try await store.loadText(at: url)

    XCTAssertEqual(loaded.text, text)
  }

  func testLoadsUTF16BigEndianTextDocumentWithByteOrderMark() async throws {
    let text = "hello\nこんにちは\n"
    var data = Data([0xFE, 0xFF])
    data.append(try XCTUnwrap(text.data(using: .utf16BigEndian)))
    let url = try temporaryFile(named: "notes", data: data)
    let store = TextDocumentStore()

    let loaded = try await store.loadText(at: url)

    XCTAssertEqual(loaded.text, text)
  }

  func testRejectsBinaryDataEvenWhenFallbackEncodingCouldDecodeBytes() async throws {
    let url = try temporaryFile(named: "blob", data: Data([0x00, 0x01, 0x02, 0xFF]))
    let store = TextDocumentStore()

    do {
      _ = try await store.loadText(at: url)
      XCTFail("Expected binary data to fail text loading")
    } catch {
      XCTAssertFalse(error.localizedDescription.isEmpty)
    }
  }

  func testRejectsOversizedTextDocumentBeforeLoadingContents() async throws {
    let url = try temporaryFile(named: "large-unknown", byteCount: 16 * 1024 * 1024 + 1)
    let store = TextDocumentStore()

    do {
      _ = try await store.loadText(at: url)
      XCTFail("Expected oversized text loading to fail")
    } catch TextDocumentStoreError.fileTooLarge {
      // Expected.
    } catch {
      XCTFail("Expected fileTooLarge, got \(error)")
    }
  }

  private func temporaryFile(named name: String, contents: String) throws -> URL {
    try temporaryFile(named: name, data: try XCTUnwrap(contents.data(using: .utf8)))
  }

  private func temporaryFile(named name: String, byteCount: UInt64) throws -> URL {
    let url = try temporaryURL(named: name)
    _ = FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: byteCount)
    try handle.close()
    return url
  }

  private func temporaryFile(named name: String, data: Data) throws -> URL {
    let url = try temporaryURL(named: name)
    try data.write(to: url)
    return url
  }

  private func temporaryURL(named name: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "locus-text-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return directory.appending(path: name)
  }
}
