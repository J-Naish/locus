import XCTest

@testable import Locus

final class MediaDocumentStoreTests: XCTestCase {
  func testLoadsPlayableVideoDocument() async throws {
    let store = MediaDocumentStore()
    let url = try fixtureURL(path: "workspaces/file-types/video-placeholder.mp4")

    let document = try await store.loadMedia(at: url)

    XCTAssertNotNil(document.player.currentItem)
  }

  func testLoadsPlayableAudioDocument() async throws {
    let store = MediaDocumentStore()
    let url = try fixtureURL(path: "workspaces/file-types/audio-placeholder.mp3")

    let document = try await store.loadMedia(at: url)

    XCTAssertNotNil(document.player.currentItem)
  }

  func testRejectsInvalidMediaDocument() async throws {
    let workspaceURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-invalid-media-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: workspaceURL)
    }

    let brokenMediaURL = workspaceURL.appending(path: "broken.mp4")
    try Data("not media".utf8).write(to: brokenMediaURL)

    do {
      _ = try await MediaDocumentStore().loadMedia(at: brokenMediaURL)
      XCTFail("Expected invalid media to fail loading")
    } catch let error as MediaDocumentStoreError {
      XCTAssertEqual(error, .cannotOpen)
    }
  }

  private func fixtureURL(path: String) throws -> URL {
    var directory = URL(filePath: #filePath).deletingLastPathComponent()
    let fileManager = FileManager.default

    while !directory.path(percentEncoded: false).isEmpty,
      directory.path(percentEncoded: false) != "/"
    {
      let url = directory.appending(path: "fixtures/\(path)")
      if fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
        return url
      }

      directory.deleteLastPathComponent()
    }

    throw CocoaError(.fileNoSuchFile)
  }
}
