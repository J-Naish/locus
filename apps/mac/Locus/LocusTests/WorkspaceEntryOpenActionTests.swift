import XCTest
@testable import Locus

final class WorkspaceEntryOpenActionTests: XCTestCase {
    func testSingleDirectoryBrowsesInLocus() {
        let entry = makeWorkspaceEntry(name: "Drafts", kind: .directory)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .browseFolder(entry.url)
        )
    }

    func testSingleTextFileEditsInLocus() {
        let entry = makeWorkspaceEntry(name: "notes.md", kind: .file, fileType: .markdown)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .openInPlace(entry.url)
        )
    }

    func testSingleImageFileViewsInLocus() {
        let entry = makeWorkspaceEntry(name: "photo.png", kind: .file, fileType: .image)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .openInPlace(entry.url)
        )
    }

    func testSingleVectorImagePreviewsWithQuickLook() {
        let entry = makeWorkspaceEntry(name: "diagram.svg", kind: .file, fileType: .image)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .preview(entry.url)
        )
    }

    func testSinglePDFFileViewsInLocus() {
        let entry = makeWorkspaceEntry(name: "brief.pdf", kind: .file, fileType: .pdf)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .openInPlace(entry.url)
        )
    }

    func testSingleUnsupportedFilePreviewsInLocus() {
        let entry = makeWorkspaceEntry(name: "deck.pptx", kind: .file, fileType: .office)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .preview(entry.url)
        )
    }

    func testUnsupportedFileTypesPreviewInLocus() {
        let unsupportedFileTypes: [(String, WorkspaceFileType)] = [
            ("deck.pptx", .office),
            ("clip.mp4", .video),
            ("voice.mp3", .audio),
            ("blob", .unknown)
        ]

        for (name, fileType) in unsupportedFileTypes {
            let entry = makeWorkspaceEntry(name: name, kind: .file, fileType: fileType)

            XCTAssertEqual(
                WorkspaceEntryOpenActionResolver.action(for: [entry]),
                .preview(entry.url),
                "Expected \(name) to fall back to Preview"
            )
        }
    }

    func testSingleTextSymlinkEditsInLocus() {
        let entry = makeWorkspaceEntry(name: "latest", kind: .symlink, fileType: .plainText)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .openInPlace(entry.url)
        )
    }

    func testSingleImageSymlinkViewsInLocus() {
        let entry = makeWorkspaceEntry(name: "latest.png", kind: .symlink, fileType: .image)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .openInPlace(entry.url)
        )
    }

    func testSingleNonTextSymlinkPreviewsInLocus() {
        let entry = makeWorkspaceEntry(name: "latest", kind: .symlink, fileType: .unknown)

        XCTAssertEqual(
            WorkspaceEntryOpenActionResolver.action(for: [entry]),
            .preview(entry.url)
        )
    }

    func testOtherEntriesCannotBeOpened() {
        let entry = makeWorkspaceEntry(name: "socket", kind: .other)

        XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [entry]))
    }

    func testMultipleSelectionCannotBeOpenedAsOneAction() {
        let folder = makeWorkspaceEntry(name: "Drafts", kind: .directory)
        let file = makeWorkspaceEntry(name: "notes.md", kind: .file)

        XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [folder, file]))
        XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: []))
    }
}

private func makeWorkspaceEntry(
    name: String,
    kind: WorkspaceEntryKind,
    fileType: WorkspaceFileType = .unknown
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
