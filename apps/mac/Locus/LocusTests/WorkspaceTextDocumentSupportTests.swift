import AppKit
import XCTest

@testable import Locus

final class WorkspaceTextDocumentSupportTests: XCTestCase {
  func testMarkdownAndStructuredTextCanBeEdited() {
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "draft.md", fileType: .markdown)))
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canEdit(
        makeEntry(name: "settings.yaml", fileType: .structuredText)))
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "notes.txt", fileType: .plainText)))
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "script.swift", fileType: .code)))
  }

  func testBinaryFilesAreNotEditableTextDocuments() {
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "brief.pdf", fileType: .pdf)))
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "photo.png", fileType: .image)))
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "deck.pptx", fileType: .office)))
  }

  func testUnknownFilesAreEditableTextCandidates() {
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canEdit(makeEntry(name: ".customignore", fileType: .unknown)))
    XCTAssertEqual(
      WorkspaceTextDocumentSupport.syntax(
        for: makeEntry(name: ".customignore", fileType: .unknown)),
      nil
    )
  }

  func testDirectoriesAreNotEditableTextDocuments() {
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.canEdit(
        makeEntry(name: "Reports", kind: .directory, fileType: .unknown)
      )
    )
  }

  func testSyntaxMatchesEditableFileTypes() {
    XCTAssertEqual(
      WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "draft.md", fileType: .markdown)),
      .markdown)
    XCTAssertEqual(
      WorkspaceTextDocumentSupport.syntax(
        for: makeEntry(name: "settings.yaml", fileType: .structuredText)), .structuredText)
    XCTAssertEqual(
      WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "notes.txt", fileType: .plainText)),
      .plainText)
    XCTAssertEqual(
      WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "script.swift", fileType: .code)),
      .code)
    XCTAssertNil(
      WorkspaceTextDocumentSupport.syntax(for: makeEntry(name: "image.png", fileType: .image)))
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
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "`value`"), NSColor.systemPurple)
  }

  func testStructuredTextSyntaxHighlightsKeysAndValues() {
    let storage = NSTextStorage(string: "enabled: true\ncount: 12\nname: \"Locus\"")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .structuredText,
      font: TextDocumentSyntax.structuredText.font
    )

    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "enabled"), NSColor.controlAccentColor)
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "true"), NSColor.systemOrange)
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "12"), NSColor.systemPurple)
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "\"Locus\""), NSColor.systemGreen)
  }

  func testCodeSyntaxHighlightsKeywordsStringsAndComments() {
    let storage = NSTextStorage(string: "let name = \"Locus\" // comment")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .code,
      font: TextDocumentSyntax.code.font
    )

    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "let"), NSColor.controlAccentColor)
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "\"Locus\""), NSColor.systemGreen)
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "// comment"),
      NSColor.secondaryLabelColor)
  }

  func testCodeSyntaxDoesNotTreatURLSlashesAsComment() {
    let storage = NSTextStorage(string: "let url = \"https://example.com\"")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .code,
      font: TextDocumentSyntax.code.font
    )

    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "https://example.com"),
      NSColor.systemGreen)
  }

  func testEditedRangeHighlightsOnlyContainingParagraph() {
    let text = "plain\n# Heading\nplain"
    let editedRange = (text as NSString).range(of: "# Heading")

    let highlightedRange = TextDocumentSyntaxHighlighter.highlightedParagraphRange(
      for: editedRange, in: text)

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
    XCTAssertEqual(
      (text as NSString).length, TextDocumentSyntaxHighlighter.maximumHighlightedUTF16Length)
    let storage = NSTextStorage(string: text)

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(storage.foregroundColor(at: 1), NSColor.controlAccentColor)
  }

  func testLineNumberLayoutTracksLogicalLinesIncludingTrailingBlankLine() {
    let starts = TextLineNumberLayout.lineStartLocations(in: "one\ntwo\n")

    XCTAssertEqual(starts, [0, 4, 8])
    XCTAssertEqual(TextLineNumberLayout.lineNumber(forCharacterLocation: 0, in: starts), 1)
    XCTAssertEqual(TextLineNumberLayout.lineNumber(forCharacterLocation: 4, in: starts), 2)
    XCTAssertEqual(TextLineNumberLayout.lineNumber(forCharacterLocation: 8, in: starts), 3)
    XCTAssertTrue(TextLineNumberLayout.isLineStart(4, in: starts))
    XCTAssertFalse(TextLineNumberLayout.isLineStart(5, in: starts))
  }

  func testLineNumberLayoutTracksCRLFAndConsecutiveBlankLines() {
    XCTAssertEqual(TextLineNumberLayout.lineStartLocations(in: "one\r\ntwo\r\n"), [0, 5, 10])
    XCTAssertEqual(TextLineNumberLayout.lineStartLocations(in: "\n\n\n"), [0, 1, 2, 3])
  }

  func testLineNumberLayoutDoesNotAddBlankLineWithoutTrailingNewline() {
    XCTAssertEqual(TextLineNumberLayout.lineStartLocations(in: "one\ntwo"), [0, 4])
  }

  func testLineNumberLayoutHandlesEmptySingleLineDocument() {
    let starts = TextLineNumberLayout.lineStartLocations(in: "")

    XCTAssertEqual(starts, [0])
    XCTAssertEqual(TextLineNumberLayout.lineNumber(forCharacterLocation: 0, in: starts), 1)
    XCTAssertEqual(TextLineNumberLayout.lineNumber(forCharacterLocation: -1, in: starts), 1)
    XCTAssertEqual(TextLineNumberLayout.lineNumber(forCharacterLocation: 999, in: starts), 1)
  }

  func testLineNumberGutterWidensForLargeDocuments() {
    let font = TextDocumentSyntax.code.font
    let shortWidth = TextLineNumberLayout.gutterWidth(lineCount: 9, font: font)
    let largeWidth = TextLineNumberLayout.gutterWidth(lineCount: 10_000, font: font)

    XCTAssertGreaterThan(largeWidth, shortWidth)
  }

  func testLineNumberVisibilityMatchesDocumentOrientedEditingScope() {
    XCTAssertTrue(
      TextLineNumberLayout.shouldShowLineNumbers(syntax: .plainText, textUTF16Length: 12))
    XCTAssertTrue(
      TextLineNumberLayout.shouldShowLineNumbers(syntax: .structuredText, textUTF16Length: 12))
    XCTAssertTrue(TextLineNumberLayout.shouldShowLineNumbers(syntax: .code, textUTF16Length: 12))
    XCTAssertTrue(
      TextLineNumberLayout.shouldShowLineNumbers(syntax: .markdown, textUTF16Length: 12))
  }

  func testLineNumbersAreHiddenForVeryLargeDocuments() {
    XCTAssertTrue(
      TextLineNumberLayout.shouldShowLineNumbers(
        syntax: .code,
        textUTF16Length: TextLineNumberLayout.maximumLineNumberedUTF16Length
      )
    )
    XCTAssertFalse(
      TextLineNumberLayout.shouldShowLineNumbers(
        syntax: .code,
        textUTF16Length: TextLineNumberLayout.maximumLineNumberedUTF16Length + 1
      )
    )
  }

  func testLineNumberReloadIsNeededOnlyWhenEditedTextTouchesLineSeparators() {
    XCTAssertFalse(
      TextLineNumberLayout.editCanChangeLineStarts(
        currentText: "one\ntwo",
        affectedRange: NSRange(location: 1, length: 1),
        replacementText: "x"
      )
    )
    XCTAssertTrue(
      TextLineNumberLayout.editCanChangeLineStarts(
        currentText: "one\ntwo",
        affectedRange: NSRange(location: 3, length: 1),
        replacementText: ""
      )
    )
    XCTAssertTrue(
      TextLineNumberLayout.editCanChangeLineStarts(
        currentText: "one two",
        affectedRange: NSRange(location: 3, length: 1),
        replacementText: "\n"
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

extension NSTextStorage {
  fileprivate func foregroundColor(at location: Int) -> NSColor? {
    attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
  }

  fileprivate func foregroundColor(in text: String, matching substring: String) -> NSColor? {
    let range = (text as NSString).range(of: substring)
    XCTAssertNotEqual(range.location, NSNotFound)
    return foregroundColor(at: range.location)
  }
}
