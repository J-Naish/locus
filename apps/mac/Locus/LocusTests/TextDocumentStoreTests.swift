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

  private func temporaryFile(named name: String, contents: String) throws -> URL {
    try temporaryFile(named: name, data: try XCTUnwrap(contents.data(using: .utf8)))
  }

  private func temporaryFile(named name: String, data: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "locus-text-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }

    let url = directory.appending(path: name)
    try data.write(to: url)
    return url
  }
}
