import AppKit
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

    func testSyntaxMatchesEditableFileTypes() {
        XCTAssertEqual(WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "draft.md", fileType: .markdown)), .markdown)
        XCTAssertEqual(WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "settings.yaml", fileType: .structuredText)), .structuredText)
        XCTAssertEqual(WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "notes.txt", fileType: .plainText)), .plainText)
        XCTAssertEqual(WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "script.swift", fileType: .code)), .code)
        XCTAssertNil(WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "image.png", fileType: .image)))
    }

    func testMarkdownSyntaxHighlightsHeadingsAndInlineCode() {
        let storage = NSTextStorage(string: "# Title\nUse `value` here")

        TextDocumentSyntaxHighlighter.apply(
            to: storage,
            text: storage.string,
            syntax: .markdown,
            font: TextDocumentSyntax.markdown.font
        )

        XCTAssertEqual(storage.foregroundColor(at: 1), NSColor.controlAccentColor)
        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "`value`"), NSColor.systemPurple)
    }

    func testStructuredTextSyntaxHighlightsKeysAndValues() {
        let storage = NSTextStorage(string: "enabled: true\ncount: 12\nname: \"Locus\"")

        TextDocumentSyntaxHighlighter.apply(
            to: storage,
            text: storage.string,
            syntax: .structuredText,
            font: TextDocumentSyntax.structuredText.font
        )

        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "enabled"), NSColor.controlAccentColor)
        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "true"), NSColor.systemOrange)
        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "12"), NSColor.systemPurple)
        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "\"Locus\""), NSColor.systemGreen)
    }

    func testCodeSyntaxHighlightsKeywordsStringsAndComments() {
        let storage = NSTextStorage(string: "let name = \"Locus\" // comment")

        TextDocumentSyntaxHighlighter.apply(
            to: storage,
            text: storage.string,
            syntax: .code,
            font: TextDocumentSyntax.code.font
        )

        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "let"), NSColor.controlAccentColor)
        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "\"Locus\""), NSColor.systemGreen)
        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "// comment"), NSColor.secondaryLabelColor)
    }

    func testCodeSyntaxDoesNotTreatURLSlashesAsComment() {
        let storage = NSTextStorage(string: "let url = \"https://example.com\"")

        TextDocumentSyntaxHighlighter.apply(
            to: storage,
            text: storage.string,
            syntax: .code,
            font: TextDocumentSyntax.code.font
        )

        XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "https://example.com"), NSColor.systemGreen)
    }

    func testEditedRangeHighlightsOnlyContainingParagraph() {
        let text = "plain\n# Heading\nplain"
        let editedRange = (text as NSString).range(of: "# Heading")

        let highlightedRange = TextDocumentSyntaxHighlighter.highlightedParagraphRange(for: editedRange, in: text)

        XCTAssertEqual((text as NSString).substring(with: highlightedRange), "# Heading\n")
    }

    func testVeryLargeTextSkipsSyntaxHighlighting() {
        let text = "# Heading\n" + String(repeating: "a", count: 200_001)
        let storage = NSTextStorage(string: text)

        TextDocumentSyntaxHighlighter.apply(
            to: storage,
            text: storage.string,
            syntax: .markdown,
            font: TextDocumentSyntax.markdown.font
        )

        XCTAssertEqual(storage.foregroundColor(at: 1), NSColor.labelColor)
    }

    func testBoundaryLengthTextIsStillHighlighted() {
        let text = "# Heading\n" + String(repeating: "a", count: 199_990)
        XCTAssertEqual((text as NSString).length, TextDocumentSyntaxHighlighter.maximumHighlightedUTF16Length)
        let storage = NSTextStorage(string: text)

        TextDocumentSyntaxHighlighter.apply(
            to: storage,
            text: storage.string,
            syntax: .markdown,
            font: TextDocumentSyntax.markdown.font
        )

        XCTAssertEqual(storage.foregroundColor(at: 1), NSColor.controlAccentColor)
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

private extension NSTextStorage {
    func foregroundColor(at location: Int) -> NSColor? {
        attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
    }

    func foregroundColor(in text: String, matching substring: String) -> NSColor? {
        let range = (text as NSString).range(of: substring)
        XCTAssertNotEqual(range.location, NSNotFound)
        return foregroundColor(at: range.location)
    }
}
