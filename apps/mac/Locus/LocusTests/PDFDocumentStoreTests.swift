import XCTest
@testable import Locus

final class PDFDocumentStoreTests: XCTestCase {
    func testLoadsPDFDocument() async throws {
        let url = try temporaryFile(named: "sample.pdf", data: Self.validPDFData)
        let store = PDFDocumentStore()

        let document = try await store.loadPDF(at: url)

        XCTAssertEqual(document.document.pageCount, 1)
    }

    func testThrowsWhenPDFCannotBeOpened() async throws {
        let url = try temporaryFile(named: "broken.pdf", data: Data("not a pdf".utf8))
        let store = PDFDocumentStore()

        do {
            _ = try await store.loadPDF(at: url)
            XCTFail("Expected invalid PDF data to fail opening")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This PDF file could not be opened.")
        }
    }

    private func temporaryFile(named name: String, data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "locus-pdf-store-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    private static let validPDFData = Data("""
    %PDF-1.4
    1 0 obj
    << /Type /Catalog /Pages 2 0 R >>
    endobj
    2 0 obj
    << /Type /Pages /Kids [3 0 R] /Count 1 >>
    endobj
    3 0 obj
    << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>
    endobj
    xref
    0 4
    0000000000 65535 f 
    0000000009 00000 n 
    0000000058 00000 n 
    0000000115 00000 n 
    trailer
    << /Root 1 0 R /Size 4 >>
    startxref
    186
    %%EOF
    """.utf8)
}
