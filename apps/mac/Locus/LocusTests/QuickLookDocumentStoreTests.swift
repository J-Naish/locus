import XCTest
@testable import Locus

final class QuickLookDocumentStoreTests: XCTestCase {
    func testLoadsExistingQuickLookDocument() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "locus-quicklook-\(UUID().uuidString).docx")
        try Data("placeholder".utf8).write(to: url)
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let document = try await QuickLookDocumentStore().loadQuickLookDocument(at: url)

        XCTAssertEqual(document.url, url)
    }

    func testMissingQuickLookDocumentFails() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "missing-\(UUID().uuidString).docx")

        do {
            _ = try await QuickLookDocumentStore().loadQuickLookDocument(at: url)
            XCTFail("Expected missing file to fail")
        } catch let error as QuickLookDocumentStoreError {
            XCTAssertEqual(error, .cannotOpen)
        }
    }
}
