import AppKit
import ImageIO
import XCTest

@testable import Locus

@MainActor
final class MarkdownImageStoreTests: XCTestCase {

  // MARK: - Source resolution

  func testResolvesRelativePathsAgainstTheDocumentFolder() throws {
    let document = URL(filePath: "/tmp/workspace/notes/doc.md")

    let sibling = MarkdownImageStore.resolvedLocation(
      source: "images/chart.png", baseURL: document)
    XCTAssertEqual(sibling?.url.path(), "/tmp/workspace/notes/images/chart.png")
    XCTAssertEqual(sibling?.isRemote, false)

    let parent = MarkdownImageStore.resolvedLocation(
      source: "../shared/logo.png", baseURL: document)
    XCTAssertEqual(parent?.url.path(), "/tmp/workspace/shared/logo.png")

    let absolute = MarkdownImageStore.resolvedLocation(
      source: "/tmp/elsewhere/pic.png", baseURL: document)
    XCTAssertEqual(absolute?.url.path(), "/tmp/elsewhere/pic.png")

    let encoded = MarkdownImageStore.resolvedLocation(
      source: "images/my%20photo.png", baseURL: document)
    XCTAssertEqual(
      encoded?.url.path(percentEncoded: false), "/tmp/workspace/notes/images/my photo.png")

    XCTAssertNil(
      MarkdownImageStore.resolvedLocation(source: "images/chart.png", baseURL: nil),
      "Relative sources need a document folder to resolve against")
  }

  func testResolutionExpandsOnlyTheUsersOwnHome() {
    let home = MarkdownImageStore.resolvedLocation(source: "~/Pictures/a.png", baseURL: nil)
    XCTAssertEqual(
      home?.url.path(percentEncoded: false),
      FileManager.default.homeDirectoryForCurrentUser.path + "/Pictures/a.png")

    let document = URL(filePath: "/tmp/ws/doc.md")
    let otherUser = MarkdownImageStore.resolvedLocation(source: "~root/a.png", baseURL: document)
    XCTAssertEqual(otherUser?.url.path(percentEncoded: false), "/tmp/ws/~root/a.png")
  }

  func testNaturalPixelSizeBudgetRejectsDecompressionBombs() {
    XCTAssertTrue(
      MarkdownImageStore.naturalPixelSizeIsAcceptable(CGSize(width: 8000, height: 6000)))
    XCTAssertFalse(
      MarkdownImageStore.naturalPixelSizeIsAcceptable(CGSize(width: 100_000, height: 100_000)))
    XCTAssertFalse(
      MarkdownImageStore.naturalPixelSizeIsAcceptable(CGSize(width: 0, height: 10)))
  }

  func testResolvesHttpsAsRemoteAndRejectsOtherSchemes() {
    let https = MarkdownImageStore.resolvedLocation(
      source: "https://example.com/a.png", baseURL: nil)
    XCTAssertEqual(https?.url.absoluteString, "https://example.com/a.png")
    XCTAssertEqual(https?.isRemote, true)

    XCTAssertNil(
      MarkdownImageStore.resolvedLocation(source: "http://example.com/a.png", baseURL: nil),
      "Plain http is blocked by App Transport Security and should fail quietly")
    XCTAssertNil(
      MarkdownImageStore.resolvedLocation(source: "ftp://example.com/a.png", baseURL: nil))
  }

  // MARK: - Probing

  func testProbeReadsPixelSizeOfLocalImages() async throws {
    let folder = try makeTemporaryFolder()
    let imageURL = folder.appendingPathComponent("chart.png")
    try writePNG(width: 6, height: 4, to: imageURL)
    let store = MarkdownImageStore(baseURL: folder.appendingPathComponent("doc.md"))

    XCTAssertEqual(store.state(for: "chart.png"), .loading)
    await store.settleForTesting()

    XCTAssertEqual(store.state(for: "chart.png"), .sized(CGSize(width: 6, height: 4)))
  }

  func testMissingAndUndecodableFilesFail() async throws {
    let folder = try makeTemporaryFolder()
    try Data("not an image".utf8).write(to: folder.appendingPathComponent("bad.png"))
    let store = MarkdownImageStore(baseURL: folder.appendingPathComponent("doc.md"))

    _ = store.state(for: "missing.png")
    _ = store.state(for: "bad.png")
    await store.settleForTesting()

    XCTAssertEqual(store.state(for: "missing.png"), .failed)
    XCTAssertEqual(store.state(for: "bad.png"), .failed)
  }

  func testSvgProbeFallsBackToNSImage() async throws {
    let folder = try makeTemporaryFolder()
    let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"></svg>"#
    try Data(svg.utf8).write(to: folder.appendingPathComponent("diagram.svg"))
    let store = MarkdownImageStore(baseURL: folder.appendingPathComponent("doc.md"))

    _ = store.state(for: "diagram.svg")
    await store.settleForTesting()

    XCTAssertEqual(store.state(for: "diagram.svg"), .sized(CGSize(width: 100, height: 50)))
    _ = store.decodedImage(for: "diagram.svg", maxPixelSize: 200)
    await store.settleForTesting()
    XCTAssertNotNil(store.decodedImage(for: "diagram.svg", maxPixelSize: 200))
  }

  // MARK: - Decoding

  func testDecodedImageDownsamplesToRequestedSize() async throws {
    let folder = try makeTemporaryFolder()
    try writePNG(width: 64, height: 32, to: folder.appendingPathComponent("wide.png"))
    let store = MarkdownImageStore(baseURL: folder.appendingPathComponent("doc.md"))

    _ = store.state(for: "wide.png")
    await store.settleForTesting()
    XCTAssertNil(
      store.decodedImage(for: "wide.png", maxPixelSize: 16),
      "Pixels decode asynchronously after the first request")
    await store.settleForTesting()

    let image = try XCTUnwrap(store.decodedImage(for: "wide.png", maxPixelSize: 16))
    XCTAssertEqual(image.width, 16)
    XCTAssertEqual(image.height, 8)
  }

  func testDecodedImageDoesNotUpscaleAndReusesTheCache() async throws {
    let folder = try makeTemporaryFolder()
    try writePNG(width: 6, height: 4, to: folder.appendingPathComponent("small.png"))
    let store = MarkdownImageStore(baseURL: folder.appendingPathComponent("doc.md"))

    _ = store.state(for: "small.png")
    await store.settleForTesting()
    _ = store.decodedImage(for: "small.png", maxPixelSize: 64)
    await store.settleForTesting()

    let first = try XCTUnwrap(store.decodedImage(for: "small.png", maxPixelSize: 64))
    XCTAssertEqual(first.width, 6)
    XCTAssertEqual(first.height, 4)
    let second = try XCTUnwrap(store.decodedImage(for: "small.png", maxPixelSize: 64))
    XCTAssertTrue(first === second, "Repeated requests must hit the decoded cache")
  }

  func testResetForgetsStatesAndCaches() async throws {
    let folder = try makeTemporaryFolder()
    try writePNG(width: 6, height: 4, to: folder.appendingPathComponent("a.png"))
    let store = MarkdownImageStore(baseURL: folder.appendingPathComponent("doc.md"))
    _ = store.state(for: "a.png")
    await store.settleForTesting()

    store.reset()

    XCTAssertEqual(store.state(for: "a.png"), .loading)
  }

  // MARK: - Helpers

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("MarkdownImageStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return folder
  }

  private func writePNG(width: Int, height: Int, to url: URL) throws {
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}
