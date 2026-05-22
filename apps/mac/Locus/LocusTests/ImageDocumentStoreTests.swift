import XCTest
@testable import Locus

final class ImageDocumentStoreTests: XCTestCase {
    func testLoadsDecodedImage() async throws {
        let url = try temporaryFile(named: "sample.png", data: Self.onePixelPNGData)
        let store = ImageDocumentStore()

        let document = try await store.loadImage(at: url)

        XCTAssertEqual(document.image.size.width, 1)
        XCTAssertEqual(document.image.size.height, 1)
    }

    func testThrowsWhenImageCannotBeDecoded() async throws {
        let url = try temporaryFile(named: "broken.png", data: Data("not an image".utf8))
        let store = ImageDocumentStore()

        do {
            _ = try await store.loadImage(at: url)
            XCTFail("Expected invalid image data to fail decoding")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This image file could not be decoded.")
        }
    }

    private func temporaryFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "locus-image-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    private static let onePixelPNGData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )!
}
