import XCTest
@testable import Locus

final class WorkspaceTextDocumentSupportTests: XCTestCase {
    func testMarkdownAndStructuredTextCanBeEdited() {
        XCTAssertTrue(WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "draft.md", fileType: .markdown)))
        XCTAssertTrue(WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "settings.yaml", fileType: .structuredText)))
        XCTAssertTrue(WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "notes.txt", fileType: .plainText)))
        XCTAssertTrue(WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "script.swift", fileType: .code)))
    }

    func testBinaryAndUnknownFilesAreNotEditableTextDocuments() {
        XCTAssertFalse(WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "brief.pdf", fileType: .pdf)))
        XCTAssertFalse(WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "photo.png", fileType: .image)))
        XCTAssertFalse(WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "deck.pptx", fileType: .office)))
        XCTAssertFalse(WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "blob", fileType: .unknown)))
    }

    func testDirectoriesAreNotEditableTextDocuments() {
        XCTAssertFalse(
            WorkspaceTextDocumentSupport.canEdit(
                makeEntry(name: "Reports", kind: .directory, fileType: .unknown)
            )
        )
    }

    private func makeEntry(
        name: String,
        kind: WorkspaceEntryKind = .file,
        fileType: WorkspaceFileType
    ) -> WorkspaceEntry {
        let url = URL(
            filePath: "/tmp/locus-test/\(name)",
            directoryHint: kind == .directory ? .isDirectory : .notDirectory
        )
        return WorkspaceEntry(
            id: url.path(percentEncoded: false),
            url: url,
            name: name,
            kind: kind,
            fileType: fileType,
            sizeBytes: nil,
            modified: nil,
            isReadOnly: false
        )
    }
}
