import AppKit
import XCTest

@testable import Locus

final class WorkspaceTextDocumentSupportTests: XCTestCase {
  func testMarkdownCanOpenInTextSurfaceAndCanBeEditedInLocus() {
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canEdit(makeEntry(name: "draft.md", fileType: .markdown)))
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canOpenInTextSurface(
        makeEntry(name: "draft.md", fileType: .markdown)))
  }

  func testStructuredTextPlainTextAndCodeCanBeEdited() {
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

  func testFileSymlinksUseTargetFileTypeForEditability() {
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canEdit(
        makeEntry(name: "linked-notes", kind: .symlinkToFile, fileType: .markdown)
      )
    )
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.canOpenInTextSurface(
        makeEntry(name: "linked-notes", kind: .symlinkToFile, fileType: .markdown)
      )
    )
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.canEdit(
        makeEntry(name: "linked-photo", kind: .symlinkToFile, fileType: .image)
      )
    )
  }

  func testUnknownSymlinksAreNotEditableTextDocuments() {
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.canEdit(
        makeEntry(name: "broken", kind: .symlink, fileType: .unknown)
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

  func testMarkdownUsesDocumentBodyTypographyAndHidesLineNumbers() {
    XCTAssertEqual(TextDocumentSyntax.markdown.font.pointSize, 15)
    XCTAssertFalse(TextDocumentSyntax.markdown.supportsLineNumbers)

    XCTAssertTrue(TextDocumentSyntax.plainText.supportsLineNumbers)
    XCTAssertTrue(TextDocumentSyntax.structuredText.supportsLineNumbers)
    XCTAssertTrue(TextDocumentSyntax.code.supportsLineNumbers)
  }

  func testMarkdownHeadingTypographyFitsUniformLineHeightUntilVariableRowsExist() {
    let headingFont = MarkdownDocumentMetrics.headingFont(level: 1)
    let headingHeight = ceil(headingFont.ascender - headingFont.descender + headingFont.leading)

    XCTAssertLessThanOrEqual(headingHeight, TextDocumentSyntax.markdown.lineHeight)
  }

  func testProseDocumentsSoftWrap() {
    // Markdown and plain prose read as documents, so lines wrap to the viewport.
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.wrapsLines(for: makeEntry(name: "draft.md", fileType: .markdown))
    )
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "notes.txt", fileType: .plainText)))
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "outline.text", fileType: .plainText)))
    // Extensionless prose documents (matched by name, case-insensitively).
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "README", fileType: .plainText)))
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "LICENSE", fileType: .plainText)))
    XCTAssertTrue(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "changelog", fileType: .plainText)))
  }

  func testStructuredCodeAndDataFilesDoNotWrap() {
    // A line is itself a unit of meaning here, so it is preserved (no wrap).
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "settings.yaml", fileType: .structuredText)))
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "script.swift", fileType: .code)))
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "records.csv", fileType: .plainText)))
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "table.tsv", fileType: .plainText)))
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: "app.log", fileType: .plainText)))
  }

  func testDotfileConfigDoesNotWrap() {
    // Ignore lists and environment files are line-oriented config: a long .env
    // value should stay on its own line rather than wrap.
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: ".gitignore", fileType: .plainText)))
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: ".env", fileType: .plainText)))
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: ".env.local", fileType: .plainText)))
  }

  func testUnknownFilesDoNotWrap() {
    // Unrecognized files default to no-wrap, preserving their exact lines.
    XCTAssertFalse(
      WorkspaceTextDocumentSupport.wrapsLines(
        for: makeEntry(name: ".customignore", fileType: .unknown)))
  }

  func testMarkdownSyntaxHighlightsHeadingsAndInlineCode() {
    let storage = NSTextStorage(string: "# Title\nUse `value` here")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertLessThanOrEqual(storage.foregroundColor(at: 0)?.alphaComponent ?? 1, 0.01)
    XCTAssertEqual(
      storage.resolvedFont(at: 0)?.pointSize, TextDocumentSyntax.markdown.font.pointSize)
    XCTAssertEqual(
      storage.resolvedFont(at: 2)?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "value")?.fontDescriptor.symbolicTraits
        .contains(.monoSpace), true)
  }

  func testMarkdownDocumentStylingConcealsHeadingMarkerAndScalesTitle() throws {
    let storage = NSTextStorage(string: "# Quarterly review")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertLessThanOrEqual(try XCTUnwrap(storage.foregroundColor(at: 0)).alphaComponent, 0.01)
    XCTAssertEqual(
      storage.resolvedFont(at: 0)?.pointSize, TextDocumentSyntax.markdown.font.pointSize)
    XCTAssertEqual(
      storage.resolvedFont(at: 2)?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
    XCTAssertEqual(
      storage.resolvedFont(at: 2)?.fontDescriptor.symbolicTraits.contains(.bold), true)
  }

  func testMarkdownRenderedLineRemovesHeadingMarkerAndScalesTitle() throws {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "# Quarterly review",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(line.string, "Quarterly review")
    XCTAssertEqual(
      line.resolvedFont(at: 0)?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
  }

  func testMarkdownRenderedLineRemovesListTaskAndOrderedMarkers() {
    let typography = MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font)

    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "- [ ] Update the summary",
        font: TextDocumentSyntax.markdown.font,
        typography: typography),
      "Update the summary")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "1) Review the numbers",
        font: TextDocumentSyntax.markdown.font,
        typography: typography),
      "Review the numbers")
  }

  func testMarkdownRenderedInlineRemovesFormattingMarkers() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "Use **bold** and `code` in [docs](https://example.com/a*b*c)",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(line.string, "Use bold and code in docs")
    XCTAssertEqual(
      line.resolvedFont(in: line.string, matching: "bold")?.fontDescriptor.symbolicTraits
        .contains(.bold),
      true)
    XCTAssertEqual(
      line.resolvedFont(in: line.string, matching: "code")?.fontDescriptor.symbolicTraits
        .contains(.monoSpace),
      true)
  }

  func testMarkdownRenderedBoldCanContainInlineCodeWithoutRawFallback() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "Use **bold with `code` inside** now",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(line.string, "Use bold with code inside now")
    XCTAssertEqual(
      line.resolvedFont(in: line.string, matching: "bold")?.fontDescriptor.symbolicTraits
        .contains(.bold),
      true)
    XCTAssertEqual(
      line.resolvedFont(in: line.string, matching: "code")?.fontDescriptor.symbolicTraits
        .contains(.monoSpace),
      true)
  }

  func testMarkdownRenderedEscapesRemoveBackslashWithoutStyling() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      #"Use \*literal* marker"#,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(line.string, "Use *literal* marker")
    XCTAssertEqual(
      line.resolvedFont(in: line.string, matching: "literal")?.fontDescriptor.symbolicTraits
        .contains(.italic),
      false)
  }

  func testMarkdownRenderedReferenceLinksAndAutolinksRemoveSyntax() {
    let lines = [
      "[Product brief][product-brief]",
      "[product-brief]: docs/product/brief.md",
      "<https://example.com/roadmap>",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[0], font: TextDocumentSyntax.markdown.font, state: states[0]),
      "Product brief")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[1], font: TextDocumentSyntax.markdown.font, state: states[1]),
      "")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[2], font: TextDocumentSyntax.markdown.font, state: states[2]),
      "https://example.com/roadmap")
  }

  func testMarkdownRenderedQuoteHeadingReclassifiesInnerBlock() {
    let line = "> ### Heading"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    let rendered = TextDocumentSyntaxHighlighter.highlightedLine(
      line,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: state
    )

    XCTAssertEqual(rendered.string, "Heading")
    XCTAssertEqual(
      rendered.resolvedFont(at: 0)?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 3).pointSize)
  }

  func testMarkdownIndentedCodeDoesNotBecomeAListItemOutsideListContext() {
    let line = "    - nishi"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    let rendered = TextDocumentSyntaxHighlighter.highlightedLine(
      line,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: state
    )

    XCTAssertEqual(rendered.string, "- nishi")
    XCTAssertEqual(
      rendered.resolvedFont(at: 0)?.fontDescriptor.symbolicTraits.contains(.monoSpace),
      true)
  }

  func testMarkdownIndentedListMarkerInsideListStaysAListItem() {
    let lines = [
      "- Parent",
      "    - Child",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let rendered = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[1],
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[1]
    )

    XCTAssertEqual(rendered.string, "Child")
    XCTAssertEqual(states[1].listDepth, 2)
    XCTAssertEqual(
      rendered.resolvedFont(at: 0)?.fontDescriptor.symbolicTraits.contains(.monoSpace),
      false)
  }

  func testMarkdownTablesRenderRowsWithoutPipeSyntax() {
    let lines = [
      "| Metric | Delta | Status |",
      "| :--- | ---: | :---: |",
      "| Revenue | 1200 | ready |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[0], font: TextDocumentSyntax.markdown.font, state: states[0]),
      "Metric\tDelta\tStatus")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[1], font: TextDocumentSyntax.markdown.font, state: states[1]),
      "")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[2], font: TextDocumentSyntax.markdown.font, state: states[2]),
      "Revenue\t1200\tready")
    XCTAssertEqual(states[0].isTableHeader, true)
    XCTAssertEqual(states[0].tableColumns.map(\.alignment), [.left, .right, .center])
    XCTAssertEqual(states[2].tableColumns, states[0].tableColumns)
    let header = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[0],
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[0])
    XCTAssertEqual(
      header.resolvedFont(in: header.string, matching: "Metric")?.pointSize,
      MarkdownDocumentMetrics.tableHeaderFontSize)
    let paragraphStyle = try? XCTUnwrap(
      header.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    XCTAssertEqual(paragraphStyle?.tabStops.count, 2)
    XCTAssertEqual(paragraphStyle?.tabStops.first?.alignment, .right)
    XCTAssertEqual(paragraphStyle?.tabStops.last?.alignment, .center)
  }

  func testMarkdownTableHeaderRendersAsMutedColumnLabel() {
    let lines = ["| Team | Owner |", "| --- | --- |", "| Sales | Nishi |"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    let header = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[0],
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[0])
    let body = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[2],
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[2])

    XCTAssertEqual(
      header.resolvedFont(in: header.string, matching: "Team")?.pointSize,
      MarkdownDocumentMetrics.tableHeaderFontSize)
    XCTAssertEqual(
      header.foregroundColor(in: header.string, matching: "Team"),
      NSColor.secondaryLabelColor)
    XCTAssertEqual(
      body.resolvedFont(in: body.string, matching: "Sales")?.pointSize,
      TextDocumentSyntax.markdown.font.pointSize)
  }

  func testMarkdownTableColumnWidthsMeasureStyledCells() throws {
    let lines = [
      "| Field | Example |",
      "| --- | --- |",
      "| Code | `status: draft` |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let columns = states[2].tableColumns
    XCTAssertEqual(columns.count, 2)

    let styled = TextDocumentSyntaxHighlighter.markdownMeasurementLine(
      "`status: draft`",
      font: TextDocumentSyntax.markdown.font,
      state: .plain,
      typography: MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font))
    let expected = max(
      MarkdownDocumentMetrics.tableColumnMinimumWidth, ceil(styled.size().width))
    let exampleColumn = try XCTUnwrap(columns.last)
    XCTAssertEqual(exampleColumn.width, expected, accuracy: 1)
  }

  func testMarkdownTableTabStopsUseGutterModel() throws {
    let lines = [
      "| Metric | Delta | Status |",
      "| :--- | ---: | :---: |",
      "| Revenue | 1200 | ready |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let columns = states[0].tableColumns
    XCTAssertEqual(columns.count, 3)

    let rendered = TextDocumentSyntaxHighlighter.markdownMeasurementLine(
      lines[2],
      font: TextDocumentSyntax.markdown.font,
      state: states[2],
      typography: MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font))
    let style = try XCTUnwrap(
      rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
    let stops = style.tabStops
    XCTAssertEqual(stops.count, 2)

    let gutter = MarkdownDocumentMetrics.tableColumnGutter
    let deltaOrigin = columns[0].width + gutter
    XCTAssertEqual(stops[0].alignment, .right)
    XCTAssertEqual(stops[0].location, deltaOrigin + columns[1].width, accuracy: 0.5)
    let statusOrigin = deltaOrigin + columns[1].width + gutter
    XCTAssertEqual(stops[1].alignment, .center)
    XCTAssertEqual(stops[1].location, statusOrigin + columns[2].width / 2, accuracy: 0.5)
  }

  func testMarkdownRenderedFenceLineShowsOnlyInfoString() {
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "```yaml",
        font: TextDocumentSyntax.markdown.font,
        state: MarkdownLineStyleState(isFenceDelimiter: true)),
      "yaml")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "```",
        font: TextDocumentSyntax.markdown.font,
        state: MarkdownLineStyleState(insideFence: true, isFenceDelimiter: true)),
      "")
  }

  func testMarkdownUnclosedFenceStaysLiteralUntilClosed() {
    let lines = ["```yaml", "status: draft"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertFalse(states[0].isFenceDelimiter)
    XCTAssertFalse(states[1].insideFence)
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[0],
        font: TextDocumentSyntax.markdown.font,
        state: states[0]),
      "```yaml")
  }

  func testMarkdownDocumentStylingConcealsTaskMarkerButKeepsTextReadable() throws {
    let storage = NSTextStorage(string: "- [ ] Update the summary")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertLessThanOrEqual(try XCTUnwrap(storage.foregroundColor(at: 0)).alphaComponent, 0.01)
    XCTAssertLessThanOrEqual(try XCTUnwrap(storage.foregroundColor(at: 4)).alphaComponent, 0.01)
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "Update"),
      NSColor.labelColor)
  }

  func testMarkdownDocumentStylingConcealsOrderedMarkers() throws {
    let storage = NSTextStorage(string: "1. Review the numbers")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertLessThanOrEqual(try XCTUnwrap(storage.foregroundColor(at: 0)).alphaComponent, 0.01)
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "Review"),
      NSColor.labelColor)
  }

  func testMarkdownLineStylingKeepsFenceContentMonospaced() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "# not a heading",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      applyRules: true,
      markdownLineState: MarkdownLineStyleState(insideFence: true)
    )

    XCTAssertEqual(
      line.resolvedFont(at: 0)?.fontDescriptor.symbolicTraits.contains(
        NSFontDescriptor.SymbolicTraits.monoSpace),
      true)
    XCTAssertNotEqual(
      line.resolvedFont(at: 0)?.pointSize, MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
  }

  func testMarkdownBoldItalicSpanStylesContentWithoutRawFallback() {
    let storage = NSTextStorage(string: "Use ***important*** now")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    let font = storage.resolvedFont(in: storage.string, matching: "important")
    XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.bold), true)
    XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.italic), true)
    XCTAssertLessThanOrEqual(
      storage.foregroundColor(in: storage.string, matching: "***")?.alphaComponent ?? 1, 0.01)
  }

  func testMarkdownStrikethroughStylesContentAndConcealsMarkers() {
    let storage = NSTextStorage(string: "Mark ~~done~~ after review")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    let range = (storage.string as NSString).range(of: "done")
    XCTAssertEqual(
      storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue)
    XCTAssertLessThanOrEqual(
      storage.foregroundColor(in: storage.string, matching: "~~")?.alphaComponent ?? 1, 0.01)
  }

  func testMarkdownSetextHeadingScalesPreviousLineAndConcealsUnderline() {
    let storage = NSTextStorage(string: "Quarterly Review\n---")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "Quarterly")?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 2).pointSize)
    XCTAssertLessThanOrEqual(
      storage.foregroundColor(in: storage.string, matching: "---")?.alphaComponent ?? 1, 0.01)
  }

  func testMarkdownSetextUnderlineDoesNotReclassifyAtxHeading() {
    let storage = NSTextStorage(string: "# Quarterly Review\n---")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "Quarterly")?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
  }

  func testMarkdownFrontMatterUsesMutedMonospacedText() {
    let markdown = """
      ---
      title: Draft
      ---
      # Body
      """
    let storage = NSTextStorage(string: markdown)

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(
      storage.resolvedFont(in: markdown, matching: "title")?.fontDescriptor.symbolicTraits
        .contains(.monoSpace), true)
    XCTAssertEqual(
      storage.resolvedFont(in: markdown, matching: "Body")?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
  }

  func testMarkdownEscapedEmphasisMarkersStayLiteral() {
    let storage = NSTextStorage(string: #"Use \*literal* marker"#)

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "literal")?.fontDescriptor.symbolicTraits
        .contains(.italic), false)
  }

  func testMarkdownImageSyntaxIsNotTreatedAsALink() {
    let storage = NSTextStorage(string: "![alt](https://example.com/image.png)")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(storage.foregroundColor(in: storage.string, matching: "alt"), NSColor.labelColor)
    XCTAssertEqual(storage.foregroundColor(at: 0), NSColor.labelColor)
  }

  func testMarkdownInlineCodeProtectsEmphasisMarkersInsideCode() {
    let storage = NSTextStorage(string: "Use `*literal*` marker")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    let font = storage.resolvedFont(in: storage.string, matching: "literal")
    XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.monoSpace), true)
    XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.italic), false)
  }

  func testMarkdownLinkUrlProtectsEmphasisCharactersInsideUrl() {
    let storage = NSTextStorage(string: "Read [doc](https://example.com/a*b*c) today")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "b")?.fontDescriptor.symbolicTraits
        .contains(.italic),
      false)
  }

  func testMarkdownBoldInsideHeadingKeepsHeadingScale() {
    let storage = NSTextStorage(string: "# **Important**")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    let font = storage.resolvedFont(in: storage.string, matching: "Important")
    XCTAssertEqual(font?.pointSize, MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
    XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.bold), true)
  }

  func testMarkdownParagraphHighlightPreservesFenceStateFromEarlierLines() {
    let markdown = """
      ```yaml
      status: draft
      ```
      """
    let storage = NSTextStorage(string: markdown)
    let range = (markdown as NSString).range(of: "status: draft")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: markdown,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      range: range
    )

    XCTAssertEqual(
      storage.resolvedFont(in: markdown, matching: "status")?.fontDescriptor.symbolicTraits
        .contains(.monoSpace), true)
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

  func testApplyRulesFalseKeepsBaseStylingButSkipsRuleColors() {
    // The long-line path opts out of rule highlighting: base styling (default
    // label color) is applied, but keyword/string colors are not.
    let storage = NSTextStorage(string: "let name = \"Locus\"")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .code,
      font: TextDocumentSyntax.code.font,
      range: NSRange(location: 0, length: (storage.string as NSString).length),
      applyRules: false
    )

    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "let"), NSColor.labelColor)
    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "\"Locus\""), NSColor.labelColor)
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

    XCTAssertEqual(
      storage.resolvedFont(at: 2)?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
  }

  private func makeEntry(
    name: String,
    kind: WorkspaceEntryKind = .file,
    fileType: WorkspaceFileType
  ) -> WorkspaceEntry {
    let url = URL(
      filePath: "/tmp/locus-test/\(name)",
      directoryHint: kind.isDirectoryLike ? .isDirectory : .notDirectory
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

extension NSAttributedString {
  fileprivate func foregroundColor(at location: Int) -> NSColor? {
    attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor
  }

  fileprivate func foregroundColor(in text: String, matching substring: String) -> NSColor? {
    let range = (text as NSString).range(of: substring)
    XCTAssertNotEqual(range.location, NSNotFound)
    return foregroundColor(at: range.location)
  }

  fileprivate func resolvedFont(at location: Int) -> NSFont? {
    attribute(.font, at: location, effectiveRange: nil) as? NSFont
  }

  fileprivate func resolvedFont(in text: String, matching substring: String) -> NSFont? {
    let range = (text as NSString).range(of: substring)
    XCTAssertNotEqual(range.location, NSNotFound)
    return resolvedFont(at: range.location)
  }
}
