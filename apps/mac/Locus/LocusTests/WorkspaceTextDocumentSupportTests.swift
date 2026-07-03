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

  func testMarkdownHeadingScaleIsDescendingAndDistinct() {
    let sizes = (1...6).map { MarkdownDocumentMetrics.headingFont(level: $0).pointSize }

    XCTAssertEqual(sizes, sizes.sorted(by: >))
    // H1–H3 carry the sectional hierarchy and must be clearly distinct.
    XCTAssertGreaterThanOrEqual(sizes[0] - sizes[1], 4)
    XCTAssertGreaterThanOrEqual(sizes[1] - sizes[2], 3)
    XCTAssertGreaterThan(sizes[0], MarkdownDocumentMetrics.bodyFontSize * 1.8)
  }

  func testMarkdownHeadingLineMetricsCarrySectionalAir() {
    let h1 = LineRenderingTextView.headingLineMetrics(level: 1, isDocumentTop: false)
    let font = MarkdownDocumentMetrics.headingFont(level: 1)

    XCTAssertEqual(
      h1.rowHeight, ceil(font.ascender - font.descender + font.leading), accuracy: 0.01)
    XCTAssertGreaterThan(h1.leadingInset, h1.trailingInset)

    let title = LineRenderingTextView.headingLineMetrics(level: 1, isDocumentTop: true)
    XCTAssertEqual(
      title.leadingInset, MarkdownDocumentMetrics.documentTopHeadingInset, accuracy: 0.01)
    XCTAssertLessThan(title.leadingInset, h1.leadingInset)
  }

  func testMarkdownHeadingLinesCarryTighteningTracking() {
    let lines = ["# Quarterly Review", "", "Body"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    XCTAssertEqual(states[0].headingLevel, 1)

    let rendered = TextDocumentSyntaxHighlighter.markdownMeasurementLine(
      lines[0],
      font: TextDocumentSyntax.markdown.font,
      state: states[0],
      typography: MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font))
    let kern = rendered.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat
    XCTAssertEqual(kern ?? 0, MarkdownDocumentMetrics.headingTracking(level: 1), accuracy: 0.01)
    XCTAssertLessThan(kern ?? 0, 0)
  }

  func testMarkdownH6UsesSecondaryHeadingTextColor() {
    let line = "###### Small Section"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    let rendered = TextDocumentSyntaxHighlighter.highlightedLine(
      line,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      applyRules: true,
      markdownLineState: state)

    XCTAssertEqual(rendered.foregroundColor(at: 0), NSColor.secondaryLabelColor)
  }

  func testMarkdownSourceFallbackH6UsesSecondaryHeadingTextColor() {
    let storage = NSTextStorage(string: "###### Small Section")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(
      storage.foregroundColor(in: storage.string, matching: "Small"),
      NSColor.secondaryLabelColor)
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

  func testMarkdownSourceFallbackStylesHeadingsAndInlineCode() {
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

  func testMarkdownSourceFallbackConcealsHeadingMarkerAndScalesTitle() throws {
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

  // MARK: Inline HTML

  /// Renders one prose line through the markdown highlighter (inline pass).
  private func htmlRendered(_ line: String) -> NSAttributedString {
    TextDocumentSyntaxHighlighter.highlightedLine(
      line, syntax: .markdown, font: TextDocumentSyntax.markdown.font)
  }

  /// The display string a line collapses to (display-map pass).
  private func htmlDisplayText(_ line: String) -> String {
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    return TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      line, font: TextDocumentSyntax.markdown.font, state: state)
  }

  func testMarkdownDecodesNamedHTMLEntities() {
    XCTAssertEqual(
      htmlRendered("a &amp; b &lt;tag&gt; &copy; &mdash; done").string,
      "a & b <tag> © — done")
    // Unknown entities stay literal, like a browser.
    XCTAssertEqual(htmlRendered("x &bogusentity; y").string, "x &bogusentity; y")
  }

  func testMarkdownDecodesNumericAndAstralEntitiesAndRejectsUnsafe() {
    XCTAssertEqual(htmlRendered("&#65;&#x42; &#x1F600;").string, "AB 😀")
    // Surrogate halves and out-of-range stay literal; NUL and bidi controls too.
    XCTAssertEqual(
      htmlRendered("&#xD800; &#xFFFFFF; &#0; &#x202E;").string,
      "&#xD800; &#xFFFFFF; &#0; &#x202E;")
  }

  func testMarkdownEntitiesInsideInlineCodeStayLiteral() {
    // Inline code protects its span, so the entity is not decoded inside it.
    XCTAssertEqual(htmlRendered("Use `a &amp; b` here").string, "Use a &amp; b here")
  }

  func testMarkdownInlineHTMLFormattingTags() {
    XCTAssertEqual(
      htmlRendered("a <b>bold</b> <i>it</i> <s>x</s> <u>u</u> end").string,
      "a bold it x u end")
    let bold = htmlRendered("a <b>bold</b>")
    XCTAssertEqual(
      bold.resolvedFont(in: bold.string, matching: "bold")?.fontDescriptor.symbolicTraits
        .contains(.bold), true)
    // Case-insensitive per HTML.
    XCTAssertEqual(htmlRendered("<STRONG>x</STRONG>").string, "x")
    // <code> renders as a mono chip.
    let code = htmlRendered("press <code>esc</code>")
    XCTAssertEqual(
      code.resolvedFont(in: code.string, matching: "esc")?.fontDescriptor.symbolicTraits
        .contains(.monoSpace), true)
    // <small> dims without shrinking the font.
    let small = htmlRendered("a <small>note</small>")
    XCTAssertEqual(small.foregroundColor(in: small.string, matching: "note"), .secondaryLabelColor)
  }

  func testMarkdownSafeHTMLLinkRendersTextWithLinkColor() {
    let safe = htmlRendered("go <a href=\"https://example.com\">here</a> now")
    XCTAssertEqual(safe.string, "go here now")
    XCTAssertEqual(safe.foregroundColor(in: safe.string, matching: "here"), .linkColor)
  }

  func testMarkdownUnsafeOrHreflessHTMLLinkStaysLiteral() {
    // javascript:, data:, and obfuscated schemes are not styled as links and
    // are left literal (the entity inside the rejected tag still decodes, but
    // the link is never honoured — and never coloured/clickable).
    XCTAssertEqual(
      htmlRendered("<a href=\"javascript:alert(1)\">x</a>").string,
      "<a href=\"javascript:alert(1)\">x</a>")
    XCTAssertEqual(
      htmlRendered("<a href=\"&#106;avascript:x\">x</a>").string,
      "<a href=\"javascript:x\">x</a>")
    XCTAssertNotEqual(
      htmlRendered("<a href=\"javascript:alert(1)\">x</a>").foregroundColor(at: 0), .linkColor)
    XCTAssertEqual(htmlRendered("<a name=\"t\">x</a>").string, "<a name=\"t\">x</a>")
  }

  func testMarkdownLineBreakTagBecomesSpace() {
    XCTAssertEqual(htmlRendered("a<br>b").string, "a b")
    XCTAssertEqual(htmlRendered("a<br/>b").string, "a b")
  }

  func testMarkdownEscapedHTMLStaysLiteralAndScriptNeverActive() {
    // &lt;b&gt;x&lt;/b&gt; must show the literal tags, not bold; <script> shows literally.
    XCTAssertEqual(htmlRendered("&lt;b&gt;x&lt;/b&gt;").string, "<b>x</b>")
    XCTAssertEqual(htmlRendered("<script>evil()</script>").string, "<script>evil()</script>")
  }

  func testMarkdownMalformedHTMLRendersLiterallyWithoutCrashing() {
    for line in ["<b>foo", "<b>x</i>", "<a href=", "&#;", "&", "<b></b>", "<u>"] {
      XCTAssertEqual(htmlDisplayText(line), htmlRendered(line).string, "parity for \(line)")
    }
  }

  func testMarkdownInlineHTMLDisplayAndAttributedStringsStayInParity() {
    let corpus = [
      "a &amp; b &copy;", "x &#x1F600; y", "<b>bold</b> and <i>it</i>",
      "<code>&amp;</code>", "nested <b>**md**</b>", "<a href=\"https://x.com\">go</a>",
      "<a href=\"javascript:x\">no</a>", "line<br>break", "<mark>hi</mark> <kbd>K</kbd>",
    ]
    for line in corpus {
      XCTAssertEqual(htmlDisplayText(line), htmlRendered(line).string, "parity for: \(line)")
    }
  }

  func testMarkdownInlineHTMLTagsWrappingEntitiesAndCodeStillStrip() {
    // A tag whose body contains a decoded entity / inline code / nested tag
    // must still strip to its inner content (not render the raw tag).
    XCTAssertEqual(htmlRendered("<b>&copy;</b>").string, "©")
    XCTAssertEqual(htmlRendered("<code>a &amp; b</code>").string, "a & b")
    XCTAssertEqual(htmlRendered("<i>caf&eacute;</i>").string, "café")
    XCTAssertEqual(htmlRendered("<b><i>x</i></b>").string, "x")
    let link = htmlRendered("<a href=\"https://x.com\">&copy; 2026</a>")
    XCTAssertEqual(link.string, "© 2026")
    XCTAssertEqual(link.foregroundColor(in: link.string, matching: "2026"), .linkColor)
  }

  func testMarkdownUnclosedHTMLLinkIsLinearTimeNotReDoS() {
    // A crafted unterminated <a ... line must not trigger quadratic
    // backtracking on the (off-main) measurement path. ~20k chars, no close.
    let line = "<a " + String(repeating: " ", count: 20_000) + "x"
    let start = Date()
    _ = htmlRendered(line)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 0.5, "unterminated <a line should render in linear time")
  }

  func testMarkdownNumericEntitiesRejectInvisibleFormatControls() {
    // U+061C (Arabic letter mark), zero-width space, BOM, soft hyphen, word
    // joiner — all invisible/format controls — stay literal, not decoded.
    XCTAssertEqual(
      htmlRendered("a&#x061C;b &#x200B; &#xFEFF; &#xAD; &#x2060;").string,
      "a&#x061C;b &#x200B; &#xFEFF; &#xAD; &#x2060;")
  }

  func testMarkdownEntityDisplayMapRoundTripsAndKeepsSurrogateIntegrity() {
    let source = "x &#x1F600; y"
    let map = TextDocumentSyntaxHighlighter.markdownDisplayMap(for: source, state: .plain)
    XCTAssertEqual(map.displayText, "x 😀 y")
    // Selecting the emoji maps back to the whole source entity, so copy returns
    // the original markup, not the decoded glyph.
    let emoji = map.bufferRange(forDisplayStart: 2, end: 4, includeWholeLineMarkers: false)
    XCTAssertEqual((source as NSString).substring(with: emoji), "&#x1F600;")
    // The caret cannot land between the two surrogate units: the interior
    // column collapses to the entity start.
    XCTAssertEqual(map.bufferColumn(forDisplayColumn: 3), map.bufferColumn(forDisplayColumn: 2))
  }

  func testHTMLImageOnlyLineIsClassifiedWithSourceAndAlt() {
    let lines = [
      "<img src=\"images/chart.png\" alt=\"Quarterly chart\">",
      "<img src='diagram.svg'/>",
      "<IMG SRC=\"https://example.com/a.png\" />",
      "Before <img src=\"inline.png\"> after",
      "<img alt=\"no source\">",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      states[0].imageSource,
      MarkdownImageSource(source: "images/chart.png", altText: "Quarterly chart"))
    XCTAssertEqual(states[1].imageSource, MarkdownImageSource(source: "diagram.svg", altText: ""))
    XCTAssertEqual(
      states[2].imageSource,
      MarkdownImageSource(source: "https://example.com/a.png", altText: ""))
    XCTAssertNil(states[3].imageSource, "an inline <img> in prose is not an image block")
    XCTAssertNil(states[4].imageSource, "an <img> without a src is not an image block")
  }

  func testHTMLImageSourceEntityDecodesAndRejectsUnsafeSchemes() {
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: [
      "<img src=\"https://x.com/a.png?u=1&amp;v=2\">",
      "<img src=\"javascript:alert(1)\">",
      "<img src=\"data:image/png;base64,AAAA\" alt=\"x\">",
      "<img src=\"&#106;avascript:alert(1)\">",
    ])

    XCTAssertEqual(states[0].imageSource?.source, "https://x.com/a.png?u=1&v=2")
    XCTAssertNil(states[1].imageSource, "javascript: src is rejected")
    XCTAssertNil(states[2].imageSource, "data: src is rejected")
    XCTAssertNil(states[3].imageSource, "entity-obfuscated javascript: src is rejected")
    // A rejected <img> renders as literal text, not a stripped/blank line.
    XCTAssertEqual(
      htmlDisplayText("<img src=\"javascript:alert(1)\">"),
      "<img src=\"javascript:alert(1)\">")
  }

  func testHTMLImageLineRendersAltTextAsCaption() {
    let line = "<img src=\"images/chart.png\" alt=\"Quarterly chart\">"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    let rendered = TextDocumentSyntaxHighlighter.highlightedLine(
      line, syntax: .markdown, font: TextDocumentSyntax.markdown.font, markdownLineState: state)

    XCTAssertEqual(rendered.string, "Quarterly chart")
    XCTAssertEqual(
      rendered.resolvedFont(at: 0)?.pointSize, MarkdownDocumentMetrics.imageCaptionFontSize)
    XCTAssertEqual(rendered.foregroundColor(at: 0), NSColor.secondaryLabelColor)
  }

  func testHTMLCaptionlessImageLineCollapsesToEmpty() {
    let line = "<img src=\"images/chart.png\">"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        line, font: TextDocumentSyntax.markdown.font, state: state),
      "")
  }

  func testHTMLInlineImageInProseCollapsesToAltText() {
    XCTAssertEqual(
      htmlRendered("See <img src=\"i.png\" alt=\"Figure 1\"> here.").string,
      "See Figure 1 here.")
  }

  func testHTMLImageDisplayMapCollapsesTagToCaptionUnit() {
    let source = "<img src=\"x.png\" alt=\"Cap\">"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [source])[0]
    let map = TextDocumentSyntaxHighlighter.markdownDisplayMap(for: source, state: state)

    XCTAssertEqual(map.displayText, "Cap")
    // Selecting the caption maps back to the whole <img> tag, so copy returns the
    // original markup, and the caret cannot land inside the collapsed tag.
    let whole = map.bufferRange(forDisplayStart: 0, end: 3, includeWholeLineMarkers: false)
    XCTAssertEqual((source as NSString).substring(with: whole), source)
    XCTAssertEqual(map.bufferColumn(forDisplayColumn: 1), map.bufferColumn(forDisplayColumn: 0))
  }

  func testHTMLImageInsideCodeFenceStaysLiteral() {
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: [
      "```", "<img src=\"a.png\">", "```",
    ])
    XCTAssertEqual(states[1].insideFence, true)
    XCTAssertNil(states[1].imageSource)
  }

  func testHTMLHorizontalRuleCollapsesToEmptyLikeThematicBreak() {
    for rule in ["<hr>", "<hr/>", "<hr />", "<HR>", "<hr class=\"sep\">", "  <hr>  "] {
      XCTAssertEqual(htmlDisplayText(rule), "", "<hr> should render empty: \(rule)")
    }
  }

  func testHTMLHorizontalRuleRequiresWholeLineAndStaysLiteralOtherwise() {
    // A mid-line <hr>, or something that is not actually an hr tag, stays literal.
    XCTAssertEqual(htmlDisplayText("text <hr> more"), "text <hr> more")
    XCTAssertEqual(htmlDisplayText("<hr2>"), "<hr2>")
    XCTAssertEqual(htmlDisplayText("<header>"), "<header>")
  }

  func testHTMLHorizontalRuleInsideCodeFenceStaysLiteral() {
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: ["```", "<hr>", "```"])
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "<hr>", font: TextDocumentSyntax.markdown.font, state: states[1]),
      "<hr>")
  }

  func testHTMLBlockImageAndRuleStayInDisplayParity() {
    let corpus = [
      "<img src=\"a.png\" alt=\"A\">", "<img src=\"https://x.com/a.png\">",
      "<img src=\"x.png\">", "See <img src=\"i.png\" alt=\"Fig\"> now",
      "<hr>", "<hr/>", "<hr class=\"x\">",
    ]
    for line in corpus {
      let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
      let display = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        line, font: TextDocumentSyntax.markdown.font, state: state)
      let attributed = TextDocumentSyntaxHighlighter.highlightedLine(
        line, syntax: .markdown, font: TextDocumentSyntax.markdown.font, markdownLineState: state
      ).string
      XCTAssertEqual(display, attributed, "parity for: \(line)")
    }
  }

  func testHTMLUnterminatedImageAndRuleAreLinearTime() {
    let imgLine = "<img " + String(repeating: " ", count: 20_000) + "x"
    let hrLine = "<hr " + String(repeating: " ", count: 20_000) + "x"
    let start = Date()
    _ = htmlRendered(imgLine)
    _ = htmlDisplayText(hrLine)
    let elapsed = Date().timeIntervalSince(start)
    XCTAssertLessThan(elapsed, 0.5, "unterminated <img/<hr lines should render in linear time")
  }

  func testHTMLHorizontalRuleMutesLikeThematicBreakOnApplyPath() {
    // The legacy NSTextStorage apply() path is a fifth rule site: a whole-line
    // <hr> must be muted exactly like ---/***/___, not styled as plain body.
    func appliedColor(_ text: String) -> NSColor? {
      let storage = NSTextStorage(string: text)
      TextDocumentSyntaxHighlighter.apply(
        to: storage, text: storage.string, syntax: .markdown,
        font: TextDocumentSyntax.markdown.font)
      return storage.foregroundColor(at: 0)
    }
    XCTAssertEqual(appliedColor("<hr>"), appliedColor("---"))
    XCTAssertNotEqual(appliedColor("<hr>"), appliedColor("plain text"))
  }

  func testHTMLImageWithGreaterThanInAttributeStaysFullyLiteral() {
    // A literal `>` inside a quoted attribute truncates the deliberately simple,
    // linear-time tag match, leaving unbalanced quotes. The balanced-quotes gate
    // then treats the tag as malformed and leaves the WHOLE line literal (rather
    // than partially collapsing it), preserving the linear-time guarantee.
    let line = "<img src=\"a.png\" alt=\"x > y\"> done"
    XCTAssertNil(
      TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0].imageSource,
      "a > inside an attribute must not yield a live image block")
    XCTAssertEqual(htmlDisplayText(line), line, "malformed tag stays fully literal")
    XCTAssertEqual(htmlRendered(line).string, htmlDisplayText(line), "parity for: \(line)")
  }

  func testHTMLImageIgnoresAttributeKeywordsInsideQuotedValues() {
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: [
      // A `src=` living inside the alt value is not a real source: no live image.
      "<img alt=\"caption src=https://evil.test/x.png\">",
      // The real src/alt win; the `alt=` inside the title value is ignored.
      "<img title=\"alt=Fake\" src=\"real.png\" alt=\"Real\">",
    ])
    XCTAssertNil(
      states[0].imageSource, "src= inside another attribute's value is not a real source")
    XCTAssertEqual(
      states[1].imageSource, MarkdownImageSource(source: "real.png", altText: "Real"))
  }

  func testHTMLImageInsideInlineCodeStaysLiteral() {
    // A code example containing an <img> tag must show the literal tag, not
    // collapse to its alt — inline code is protected before the <img> rule runs.
    let line = "Example: `<img src=\"x.png\" alt=\"Cap\">`"
    XCTAssertEqual(htmlRendered(line).string, "Example: <img src=\"x.png\" alt=\"Cap\">")
    XCTAssertEqual(htmlDisplayText(line), htmlRendered(line).string, "parity for: \(line)")
  }

  func testHTMLLinkIgnoresHrefKeywordInsideQuotedValue() {
    // The real (unsafe) href wins over a safe-looking href= inside another
    // attribute's value, so the link is not falsely treated as safe.
    let safeDecoy = htmlRendered("<a title=\"href=https://ok.test\" href=\"javascript:x\">go</a>")
    XCTAssertNotEqual(
      safeDecoy.foregroundColor(in: safeDecoy.string, matching: "go"), .linkColor,
      "an unsafe real href must not render as a link even with a safe decoy href=")
    // A genuinely safe href still renders as a link.
    let safe = htmlRendered("<a href=\"https://ok.test\">go</a>")
    XCTAssertEqual(safe.foregroundColor(in: safe.string, matching: "go"), .linkColor)
  }

  func testHTMLQuotedHorizontalRuleAndThematicBreakCollapseConsistently() {
    // A rule inside a blockquote collapses its text to empty (matching the view,
    // which draws the rule); it must not show literal <hr>/--- under the rule.
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: ["> <hr>", "> ---"])
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "> <hr>", font: TextDocumentSyntax.markdown.font, state: states[0]),
      "")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "> ---", font: TextDocumentSyntax.markdown.font, state: states[1]),
      "")
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

  func testMarkdownRenderedBrokenLinksUseBrokenLinkColor() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "Read [docs](https://example.com) or [missing](missing.md)",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLinkStatus: { destination in
        destination == "missing.md" ? .invalid : .valid
      }
    )

    XCTAssertEqual(line.string, "Read docs or missing")
    XCTAssertEqual(line.foregroundColor(in: line.string, matching: "docs"), .linkColor)
    XCTAssertEqual(
      line.foregroundColor(in: line.string, matching: "missing"),
      MarkdownDocumentMetrics.brokenLinkColor)
  }

  func testMarkdownRenderedAutolinkURLStaysLinkColorWhenValid() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "Autolink: <https://example.com/reports/q2>.",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLinkStatus: { destination in
        MarkdownLinkNavigation.visualState(for: destination, baseFileURL: nil)
      }
    )

    XCTAssertEqual(line.string, "Autolink: https://example.com/reports/q2.")
    XCTAssertEqual(
      line.foregroundColor(in: line.string, matching: "https://example.com/reports/q2"),
      .linkColor)
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

  func testMarkdownNestedEmphasisRendersOneLevelInsideBold() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "Use **bold with *italic* inside** now",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(line.string, "Use bold with italic inside now")
    XCTAssertEqual(
      line.resolvedFont(in: line.string, matching: "bold")?.fontDescriptor.symbolicTraits
        .contains(.bold),
      true)
    let italicTraits = line.resolvedFont(in: line.string, matching: "italic")?.fontDescriptor
      .symbolicTraits
    XCTAssertEqual(italicTraits?.contains(.bold), true)
    XCTAssertEqual(italicTraits?.contains(.italic), true)
  }

  func testMarkdownLinkLabelsCanContainEmphasis() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "Open [**important** doc](docs/brief.md)",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(line.string, "Open important doc")
    XCTAssertEqual(
      line.resolvedFont(in: line.string, matching: "important")?.fontDescriptor.symbolicTraits
        .contains(.bold),
      true)
    XCTAssertEqual(
      line.foregroundColor(in: line.string, matching: "important"),
      NSColor.linkColor)
  }

  func testMarkdownInlineCodeUsesChipAttributeInsteadOfBackgroundColor() {
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      "Use `value` here",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )
    let range = (line.string as NSString).range(of: "value")

    XCTAssertNotNil(
      line.attribute(.locusMarkdownInlineCodeChip, at: range.location, effectiveRange: nil))
    XCTAssertNil(line.attribute(.backgroundColor, at: range.location, effectiveRange: nil))
  }

  func testMarkdownInlineCodeScalesInsideHeading() throws {
    let source = "# Use `value`"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [source])[0]
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      source,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: state)

    XCTAssertEqual(line.string, "Use value")
    let expected = MarkdownDocumentMetrics.inlineCodeFont(
      forDisplayFont: MarkdownDocumentMetrics.headingFont(level: 1)
    ).pointSize
    XCTAssertEqual(
      try XCTUnwrap(line.resolvedFont(in: line.string, matching: "value")).pointSize,
      expected,
      accuracy: 0.01)
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
      "[product-brief]: docs/product/brief.md")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[2], font: TextDocumentSyntax.markdown.font, state: states[2]),
      "https://example.com/roadmap")
  }

  func testMarkdownReferenceLinksResolveTargetsAndUnresolvedStayLiteral() {
    let lines = [
      "Read [Product brief][product-brief] and [Missing][missing].",
      "[product-brief]: docs/product/brief.md",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      lines[0], font: TextDocumentSyntax.markdown.font, state: states[0])
    let targets = TextDocumentSyntaxHighlighter.markdownLinkTargets(for: lines[0], state: states[0])

    XCTAssertEqual(rendered, "Read Product brief and [Missing][missing].")
    XCTAssertEqual(
      targets,
      [
        MarkdownLinkTarget(
          displayRange: (rendered as NSString).range(of: "Product brief"),
          destination: "docs/product/brief.md")
      ])
  }

  func testMarkdownFootnoteDefinitionsRemainVisibleLiteralText() {
    let lines = [
      "A footnote marker [^1].",
      "[^1]: note text",
      "    continuation stays prose",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertFalse(states[1].isReferenceDefinition)
    XCTAssertFalse(states[2].isIndentedCodeBlock)
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[1], font: TextDocumentSyntax.markdown.font, state: states[1]),
      "[^1]: note text")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[2], font: TextDocumentSyntax.markdown.font, state: states[2]),
      "    continuation stays prose")
  }

  func testMarkdownRenderedLinkTargetsExposeDisplayedRangesAndDestinations() {
    let line =
      #"**Lead** See [Brief](docs/brief.md) and <https://example.com/roadmap> plus <a href="docs/skill.md">Skill</a>"#
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      line, font: TextDocumentSyntax.markdown.font, state: state)
    let targets = TextDocumentSyntaxHighlighter.markdownLinkTargets(for: line, state: state)

    XCTAssertEqual(rendered, "Lead See Brief and https://example.com/roadmap plus Skill")
    XCTAssertEqual(
      targets,
      [
        MarkdownLinkTarget(
          displayRange: (rendered as NSString).range(of: "Brief"),
          destination: "docs/brief.md"),
        MarkdownLinkTarget(
          displayRange: (rendered as NSString).range(of: "https://example.com/roadmap"),
          destination: "https://example.com/roadmap"),
        MarkdownLinkTarget(
          displayRange: (rendered as NSString).range(of: "Skill"),
          destination: "docs/skill.md"),
      ])
  }

  func testMarkdownBareURLAutolinkTargetsExcludeTrailingPunctuationAndInlineCode() {
    let line =
      #"Visit https://example.com/reports/q2. Code `https://example.com/code` and [Brief](docs/brief.md)."#
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      line, font: TextDocumentSyntax.markdown.font, state: state)
    let targets = TextDocumentSyntaxHighlighter.markdownLinkTargets(for: line, state: state)

    XCTAssertEqual(
      rendered,
      "Visit https://example.com/reports/q2. Code https://example.com/code and Brief.")
    XCTAssertEqual(
      targets,
      [
        MarkdownLinkTarget(
          displayRange: (rendered as NSString).range(of: "https://example.com/reports/q2"),
          destination: "https://example.com/reports/q2"),
        MarkdownLinkTarget(
          displayRange: (rendered as NSString).range(of: "Brief"),
          destination: "docs/brief.md"),
      ])
  }

  func testMarkdownLinkNavigationResolvesExternalAndFileDestinations() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "locus-link-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let docs = directory.appending(path: "docs", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let base = directory.appending(path: "guide.md", directoryHint: .notDirectory)
    let linked = docs.appending(path: "brief.md", directoryHint: .notDirectory)
    try Data("guide".utf8).write(to: base)
    try Data("brief".utf8).write(to: linked)

    XCTAssertEqual(
      MarkdownLinkNavigation.openRequest(for: "https://example.com/roadmap", baseFileURL: base),
      .external(URL(string: "https://example.com/roadmap")!))
    XCTAssertEqual(
      MarkdownLinkNavigation.openRequest(for: "mailto:hello@example.com", baseFileURL: base),
      .external(URL(string: "mailto:hello@example.com")!))
    XCTAssertEqual(
      MarkdownLinkNavigation.openRequest(for: "docs/brief.md#intro", baseFileURL: base),
      .file(linked.standardizedFileURL))
    XCTAssertEqual(
      MarkdownLinkNavigation.openRequest(for: "<docs/brief.md>", baseFileURL: base),
      .file(linked.standardizedFileURL))
    XCTAssertNil(MarkdownLinkNavigation.openRequest(for: "https://", baseFileURL: base))
    XCTAssertNil(MarkdownLinkNavigation.openRequest(for: "javascript:alert(1)", baseFileURL: base))
    XCTAssertNil(MarkdownLinkNavigation.openRequest(for: "docs/missing.md", baseFileURL: base))

    XCTAssertEqual(
      MarkdownLinkNavigation.visualState(for: "https://example.com/roadmap", baseFileURL: base),
      .valid)
    XCTAssertEqual(
      MarkdownLinkNavigation.visualState(for: "https://", baseFileURL: base),
      .invalid)
    XCTAssertEqual(
      MarkdownLinkNavigation.visualState(for: "docs/brief.md#intro", baseFileURL: base),
      .valid)
    XCTAssertEqual(
      MarkdownLinkNavigation.visualState(for: "docs/missing.md", baseFileURL: base),
      .invalid)
    XCTAssertEqual(
      MarkdownLinkNavigation.visualState(for: "javascript:alert(1)", baseFileURL: base),
      .invalid)
    XCTAssertEqual(
      MarkdownLinkNavigation.visualState(for: "mailto:hello@example.com", baseFileURL: base),
      .valid)
    XCTAssertEqual(
      MarkdownLinkNavigation.visualState(for: "tel:+15551234567", baseFileURL: base),
      .valid)
    XCTAssertEqual(
      MarkdownLinkNavigation.visualState(for: "#overview", baseFileURL: base),
      .valid)
    XCTAssertNil(MarkdownLinkNavigation.openRequest(for: "#overview", baseFileURL: base))
  }

  func testMarkdownImageOnlyLineIsClassifiedWithSourceAndAlt() {
    let lines = [
      "![Quarterly chart](images/chart.png)",
      "  ![](https://example.com/a.png)  ",
      "Before ![Inline](inline.png)",
      "![Trailing](trailing.png) after",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      states[0].imageSource,
      MarkdownImageSource(source: "images/chart.png", altText: "Quarterly chart"))
    XCTAssertEqual(
      states[1].imageSource,
      MarkdownImageSource(source: "https://example.com/a.png", altText: ""))
    XCTAssertNil(states[2].imageSource)
    XCTAssertNil(states[3].imageSource)
  }

  func testMarkdownVideoOnlyLineIsClassifiedWithSourceAndAlt() {
    let lines = [
      "![Demo clip](media/demo.mp4)",
      "![Movie](https://cdn.example.com/movie.mov?token=abc)",
      "![Stream][demo-stream]",
      "[demo-stream]: media/session.m3u8",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      states[0].imageSource,
      MarkdownImageSource(source: "media/demo.mp4", altText: "Demo clip", kind: .video))
    XCTAssertEqual(
      states[1].imageSource,
      MarkdownImageSource(
        source: "https://cdn.example.com/movie.mov?token=abc",
        altText: "Movie",
        kind: .video))
    XCTAssertEqual(
      states[2].imageSource,
      MarkdownImageSource(source: "media/session.m3u8", altText: "Stream", kind: .video))
  }

  func testHTMLVideoOnlyLineIsClassifiedWithSourceAndCaption() {
    let lines = [
      "<video src=\"media/demo.mp4\" title=\"Launch demo\" controls></video>",
      "<video controls src='https://cdn.example.com/demo.m4v' aria-label='Remote demo'>",
      "Before <video src=\"inline.mp4\"></video> after",
      "<video title=\"No source\"></video>",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      states[0].imageSource,
      MarkdownImageSource(source: "media/demo.mp4", altText: "Launch demo", kind: .video))
    XCTAssertEqual(
      states[1].imageSource,
      MarkdownImageSource(
        source: "https://cdn.example.com/demo.m4v",
        altText: "Remote demo",
        kind: .video))
    XCTAssertNil(states[2].imageSource, "an inline <video> in prose is not a media block")
    XCTAssertNil(states[3].imageSource, "a <video> without a src is not a media block")
  }

  func testMarkdownReferenceStyleImageOnlyLineIsClassifiedWithResolvedSource() {
    let lines = [
      "![Referenced image][fixture-svg]",
      "",
      "[fixture-svg]: ../media/valid/locus-fixture.svg",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      states[0].imageSource,
      MarkdownImageSource(
        source: "../media/valid/locus-fixture.svg",
        altText: "Referenced image"))
  }

  func testMarkdownReferenceImageDefinitionDestinationStopsAtUnquotedWhitespace() {
    let lines = [
      "![Plain][plain-space]",
      "![Angled][angled-space]",
      "[plain-space]: images/two words.png",
      "[angled-space]: <images/two words.png> \"title\"",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      states[0].imageSource,
      MarkdownImageSource(source: "images/two", altText: "Plain"))
    XCTAssertEqual(
      states[1].imageSource,
      MarkdownImageSource(source: "images/two words.png", altText: "Angled"))
  }

  func testMarkdownLinkedImageOnlyLineKeepsImageSourceAndLinkDestination() {
    let lines = [
      "[![Fixture image](../media/valid/locus-fixture.svg)](../../docs/requirements.md)",
      "[![Referenced image][fixture-svg]](../../docs/requirements.md)",
      "[fixture-svg]: ../media/valid/locus-fixture.svg",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      states[0].imageSource,
      MarkdownImageSource(
        source: "../media/valid/locus-fixture.svg",
        altText: "Fixture image",
        linkDestination: "../../docs/requirements.md"))
    XCTAssertEqual(
      states[1].imageSource,
      MarkdownImageSource(
        source: "../media/valid/locus-fixture.svg",
        altText: "Referenced image",
        linkDestination: "../../docs/requirements.md"))
  }

  func testMarkdownImageOnlyLinesRenderCaptionWithoutRawImageSyntax() {
    let lines = [
      "[![Fixture image](../media/valid/locus-fixture.svg)](../../docs/requirements.md)",
      "![Referenced image][fixture-svg]",
      "[fixture-svg]: ../media/valid/locus-fixture.svg",
      "[![Referenced link image][fixture-svg]](../../docs/requirements.md)",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[0], font: TextDocumentSyntax.markdown.font, state: states[0]),
      "Fixture image")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[1], font: TextDocumentSyntax.markdown.font, state: states[1]),
      "Referenced image")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[3], font: TextDocumentSyntax.markdown.font, state: states[3]),
      "Referenced link image")

    let map = TextDocumentSyntaxHighlighter.markdownDisplayMap(for: lines[0], state: states[0])
    XCTAssertEqual(map.displayText, "Fixture image")
    XCTAssertEqual(
      map.bufferRange(forDisplayStart: 0, end: map.displayLength, includeWholeLineMarkers: false),
      NSRange(location: 3, length: 13))
  }

  func testMarkdownVideoOnlyLinesRenderCaptionWithoutRawVideoSyntax() {
    let markdown = "![Demo clip](media/demo.mp4)"
    let html = "<video src=\"media/demo.mp4\" title=\"Launch demo\" controls></video>"
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: [markdown, html])

    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        markdown, font: TextDocumentSyntax.markdown.font, state: states[0]),
      "Demo clip")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        html, font: TextDocumentSyntax.markdown.font, state: states[1]),
      "Launch demo")
  }

  func testMarkdownImageCaptionUsesSameWhitespaceTrimAsClassification() {
    let line = "\u{00A0}![Fixture image](../media/valid/locus-fixture.svg)\u{00A0}"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]

    XCTAssertEqual(
      state.imageSource,
      MarkdownImageSource(
        source: "../media/valid/locus-fixture.svg",
        altText: "Fixture image"))
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        line, font: TextDocumentSyntax.markdown.font, state: state),
      "Fixture image")
  }

  func testMarkdownImageDestinationStripsTitleAndAngleBrackets() {
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: [
      "![A](photo.png \"The title\")",
      "![B](<my photo.png>)",
      "![C](diagram.svg 'caption')",
    ])

    XCTAssertEqual(states[0].imageSource?.source, "photo.png")
    XCTAssertEqual(states[1].imageSource?.source, "my photo.png")
    XCTAssertEqual(states[2].imageSource?.source, "diagram.svg")
  }

  func testMarkdownImageLinesInsideCodeAndHeadingsAreNotClassified() {
    let lines = [
      "```",
      "![Fenced](a.png)",
      "```",
      "![Setext](b.png)",
      "===",
      "    ![Indented](c.png)",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertNil(states[1].imageSource)
    XCTAssertEqual(states[3].setextHeadingLevel, 1)
    XCTAssertNil(states[3].imageSource)
    XCTAssertNil(states[5].imageSource)
  }

  func testMarkdownCodeFenceLabelRendersAsTrackedMutedCaption() {
    let lines = ["```swift", "let value = 1", "```"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(states[0].isFenceLabel, true)
    XCTAssertEqual(states[2].isFenceLabel, false)

    let label = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[0],
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[0])
    XCTAssertEqual(label.string, "swift")
    XCTAssertEqual(label.resolvedFont(at: 0)?.pointSize, MarkdownDocumentMetrics.codeFenceFontSize)
    XCTAssertEqual(
      label.resolvedFont(at: 0)?.fontDescriptor.symbolicTraits.contains(.monoSpace), false)
    XCTAssertEqual(label.foregroundColor(at: 0), .secondaryLabelColor)
    let kern = label.attribute(.kern, at: 0, effectiveRange: nil) as? CGFloat
    XCTAssertEqual(kern ?? 0, MarkdownDocumentMetrics.codeCaptionTracking, accuracy: 0.01)
  }

  func testMarkdownBareFenceHasNoLabel() {
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: ["```", "code", "```"])
    XCTAssertEqual(states[0].isFenceLabel, false)
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "```", font: TextDocumentSyntax.markdown.font, state: states[0]),
      "")
  }

  func testMarkdownFencedCodeTintsCommentsAndStringsNotKeywords() {
    let lines = ["```swift", "let name = \"Nishi\"  // greet", "```"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let body = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[1],
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[1])

    XCTAssertEqual(
      body.foregroundColor(in: body.string, matching: "// greet"), NSColor.tertiaryLabelColor)
    // Keywords are never coloured — code reads as typeset text, not an IDE theme.
    XCTAssertEqual(body.foregroundColor(in: body.string, matching: "let"), NSColor.labelColor)
    // The string takes a calm distinct ink, not a marker or label colour.
    let stringColor = body.foregroundColor(in: body.string, matching: "\"Nishi\"")
    XCTAssertNotEqual(stringColor, NSColor.labelColor)
    XCTAssertNotEqual(stringColor, NSColor.tertiaryLabelColor)
  }

  func testMarkdownClosingFenceWithTrailingTextStaysEmpty() {
    let lines = ["```swift", "let x = 1", "```end"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    // A closer is never a label, even when written with trailing text — it
    // collapses to empty so it matches its slim row (no glyphs in a 6pt row).
    XCTAssertEqual(states[2].isFenceLabel, false)
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        "```end", font: TextDocumentSyntax.markdown.font, state: states[2]),
      "")
  }

  func testMarkdownIndentedCodeKeepsCommentTintButFrontmatterUsesMetadataStyling() throws {
    let indented = TextDocumentSyntaxHighlighter.markdownLineStates(for: ["    # note", "    code"])
    let indentedLine = TextDocumentSyntaxHighlighter.highlightedLine(
      "    # note",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: indented[0])
    XCTAssertEqual(indented[0].isIndentedCodeBlock, true)
    XCTAssertEqual(
      indentedLine.foregroundColor(in: indentedLine.string, matching: "# note"),
      NSColor.tertiaryLabelColor)

    let frontmatter = TextDocumentSyntaxHighlighter.markdownLineStates(for: [
      "---", "title: Hi", "---",
    ])
    let frontmatterLine = TextDocumentSyntaxHighlighter.highlightedLine(
      "title: Hi",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: frontmatter[1])
    XCTAssertEqual(frontmatter[1].insideFrontMatter, true)
    XCTAssertEqual(frontmatterLine.string, "title\nHi")
    XCTAssertEqual(
      frontmatterLine.foregroundColor(in: frontmatterLine.string, matching: "title"),
      NSColor.tertiaryLabelColor)
    XCTAssertEqual(
      frontmatterLine.foregroundColor(in: frontmatterLine.string, matching: "Hi"),
      NSColor.labelColor)
    XCTAssertFalse(
      try XCTUnwrap(frontmatterLine.resolvedFont(in: frontmatterLine.string, matching: "title"))
        .fontDescriptor.symbolicTraits.contains(.monoSpace))
  }

  func testMarkdownFencedCodeTintIsLanguageAgnostic() {
    let lines = ["```python", "def greet():  # say hi", "```"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let body = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[1],
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[1])

    XCTAssertEqual(body.foregroundColor(in: body.string, matching: "# say hi"), .tertiaryLabelColor)
    XCTAssertEqual(body.foregroundColor(in: body.string, matching: "def"), .labelColor)
  }

  func testMarkdownImageLineRendersAltTextAsCaption() {
    let line = "![Quarterly chart](images/chart.png)"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    let rendered = TextDocumentSyntaxHighlighter.highlightedLine(
      line,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: state)

    XCTAssertEqual(rendered.string, "Quarterly chart")
    XCTAssertEqual(
      rendered.resolvedFont(at: 0)?.pointSize,
      MarkdownDocumentMetrics.imageCaptionFontSize)
    XCTAssertEqual(rendered.foregroundColor(at: 0), NSColor.secondaryLabelColor)
  }

  func testMarkdownQuotedImageLineKeepsQuoteDepth() {
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: ["> ![Quoted](q.png)"])

    XCTAssertEqual(states[0].imageSource?.source, "q.png")
    XCTAssertEqual(states[0].quoteDepth, 1)
  }

  func testMarkdownListItemAndOversizedImageLinesStayInline() {
    let longDestination = "images/" + String(repeating: "a", count: 2_100) + ".png"
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: [
      "- ![Bullet](a.png)",
      "1. ![Ordered](b.png)",
      "![Huge](\(longDestination))",
    ])

    XCTAssertNil(states[0].imageSource)
    XCTAssertNil(states[1].imageSource)
    XCTAssertNil(states[2].imageSource)
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

  func testMarkdownIndentedFenceInsideListPreservesListContext() {
    let lines = [
      "- Parent",
      "  ```swift",
      "  let value = 1",
      "  ```",
      "  - Child",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let renderedChild = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[4],
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[4]
    )

    XCTAssertEqual(states[1].listDepth, 1)
    XCTAssertEqual(states[2].listDepth, 1)
    XCTAssertEqual(states[3].listDepth, 1)
    XCTAssertEqual(states[4].listDepth, 2)
    XCTAssertEqual(renderedChild.string, "Child")
    XCTAssertEqual(
      renderedChild.resolvedFont(at: 0)?.fontDescriptor.symbolicTraits.contains(.monoSpace),
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

  func testQuotedMarkdownTableUsesQuoteBodyForCellsAndRawColumnsForCopy() {
    let lines = [
      "> | First | Second |",
      "> | --- | --- |",
      "> | a | b |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(states[0].isTableHeader, true)
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[0], font: TextDocumentSyntax.markdown.font, state: states[0]),
      "First\tSecond")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[2], font: TextDocumentSyntax.markdown.font, state: states[2]),
      "a\tb")

    let map = TextDocumentSyntaxHighlighter.markdownDisplayMap(for: lines[2], state: states[2])
    XCTAssertEqual(map.displayText, "a\tb")
    XCTAssertEqual(
      map.bufferRange(forDisplayStart: 0, end: 1, includeWholeLineMarkers: false),
      NSRange(location: 4, length: 1))
    XCTAssertEqual(
      map.bufferRange(
        forDisplayStart: 0, end: (map.displayText as NSString).length, includeWholeLineMarkers: true
      ),
      NSRange(location: 0, length: (lines[2] as NSString).length))
  }

  func testMarkdownTableEscapedPipesStayInsideCells() {
    let lines = [
      "| Pattern | Meaning |",
      "| --- | --- |",
      "| A \\| B | Escaped pipe in text |",
      "| `a \\| b` | Escaped pipe in inline code |",
      "| trailing | Ends with \\| |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertTrue(states[2].isTableRow)
    XCTAssertTrue(states[3].isTableRow)
    XCTAssertTrue(states[4].isTableRow)
    XCTAssertEqual(states[2].tableColumns.count, 2)
    XCTAssertEqual(states[4].tableColumns.count, 2)
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[2], font: TextDocumentSyntax.markdown.font, state: states[2]),
      "A | B\tEscaped pipe in text")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[3], font: TextDocumentSyntax.markdown.font, state: states[3]),
      "a | b\tEscaped pipe in inline code")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[4], font: TextDocumentSyntax.markdown.font, state: states[4]),
      "trailing\tEnds with |")
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
      MarkdownDocumentMetrics.tableCellFontSize)
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

    var cellState = MarkdownLineStyleState()
    cellState.isTableRow = true
    let styled = TextDocumentSyntaxHighlighter.markdownMeasurementLine(
      "`status: draft`",
      font: TextDocumentSyntax.markdown.font,
      state: cellState,
      typography: MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font))
    let expected = max(
      MarkdownDocumentMetrics.tableColumnMinimumWidth, ceil(styled.size().width))
    let exampleColumn = try XCTUnwrap(columns.last)
    XCTAssertEqual(exampleColumn.width, expected, accuracy: 1)
  }

  func testMarkdownWideTableColumnsAreNotScaledIntoProseWidth() {
    let lines = [
      "| Team | Owner | Region | Priority | Status | Budget | Actual | Delta | Risk | Next Step |",
      "| :--- | :--- | :--- | :---: | :---: | ---: | ---: | ---: | :---: | :--- |",
      "| Sales | Nishi | Japan | P0 | Draft | 120,000 | 118,400 | -1.3% | Medium | Confirm enterprise pipeline assumptions before Friday. |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let columns = states[0].tableColumns
    let tableWidth =
      columns.reduce(CGFloat(0)) { $0 + $1.width }
      + MarkdownDocumentMetrics.tableColumnGutter * CGFloat(max(0, columns.count - 1))
      + MarkdownDocumentMetrics.tableEdgeInset * 2

    XCTAssertGreaterThan(tableWidth, MarkdownDocumentMetrics.maxMeasureWidth)
    XCTAssertGreaterThanOrEqual(
      columns.map(\.width).max() ?? 0,
      MarkdownDocumentMetrics.tableColumnMaximumWidth)
  }

  func testMarkdownTableLongCellsWrapInsideTheirColumnWithoutTruncating() throws {
    let longCell =
      "Confirm enterprise pipeline assumptions before Friday and capture follow-up notes in the review memo."
    let lines = [
      "| Team | Status | Next Step |",
      "| :--- | :---: | :--- |",
      "| Sales | Draft | \(longCell) |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let columns = states[2].tableColumns
    XCTAssertEqual(columns.count, 3)

    let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      lines[2], font: TextDocumentSyntax.markdown.font, state: states[2])
    let visualRows = rendered.components(separatedBy: "\n")
    let firstRowCells = try XCTUnwrap(visualRows.first).components(separatedBy: "\t")
    let normalizedRendered = rendered.split(whereSeparator: \.isWhitespace).joined(separator: " ")

    XCTAssertGreaterThanOrEqual(firstRowCells.count, 3)
    XCTAssertEqual(firstRowCells[0], "Sales")
    XCTAssertEqual(firstRowCells[1], "Draft")
    XCTAssertTrue(normalizedRendered.contains("Confirm enterprise pipeline assumptions"))
    XCTAssertTrue(normalizedRendered.contains("review memo"))
    XCTAssertFalse(rendered.contains("…"))

    XCTAssertGreaterThan(visualRows.count, 1)
    XCTAssertTrue(visualRows.dropFirst().allSatisfy { $0.hasPrefix("\t\t") })

    let nextStepColumn = try XCTUnwrap(columns.last)
    XCTAssertEqual(
      nextStepColumn.width,
      MarkdownDocumentMetrics.tableColumnMaximumWidth,
      accuracy: 1)
  }

  func testMarkdownTableHeadersWrapOnlyAtWordBoundaries() {
    let lines = [
      "| Empty | Very Long Header Name For Width Stress And Word Boundary Wrapping | Centred | Right Number | Symbol |",
      "| :--- | :--- | :---: | ---: | :---: |",
      "| filled | This is a deliberately long cell with repeated business prose. | maybe | 123 | * |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      lines[0], font: TextDocumentSyntax.markdown.font, state: states[0])
    let visualRows = rendered.components(separatedBy: "\n")

    XCTAssertGreaterThan(visualRows.count, 1, rendered)
    XCTAssertTrue(rendered.contains("Very Long Header Name For "), rendered)
    XCTAssertTrue(rendered.contains("Width Stress And Word Boundary "), rendered)
    XCTAssertTrue(rendered.contains("Wrapping"), rendered)
    XCTAssertTrue(rendered.contains("Symbol"), rendered)
    XCTAssertFalse(rendered.contains("Symbo\nl"))
    XCTAssertFalse(rendered.contains("Centre\nd"))
  }

  func testMarkdownTableHeaderWrappingUsesHeaderTypography() {
    let lines = [
      "| Notes | Escaped Pipe | Date |",
      "| :--- | :--- | :---: |",
      "| Long note that makes the first column wider than the pipe column. | A \\| B | 2026-01-15 |",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      lines[0], font: TextDocumentSyntax.markdown.font, state: states[0])

    XCTAssertTrue(rendered.contains("Escaped Pipe"), rendered)
    XCTAssertFalse(rendered.contains("Escaped\nPipe"), rendered)
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
        state: MarkdownLineStyleState(isFenceDelimiter: true, isFenceLabel: true)),
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

  func testMarkdownFenceClosesOnlyWithMatchingMarkerKind() {
    let lines = ["~~~", "```", "still code", "~~~", "body"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertTrue(states[0].isFenceDelimiter)
    XCTAssertTrue(states[1].insideFence)
    XCTAssertFalse(states[1].isFenceDelimiter)
    XCTAssertTrue(states[2].insideFence)
    XCTAssertTrue(states[3].isFenceDelimiter)
    XCTAssertFalse(states[4].insideFence)
  }

  func testMarkdownFenceClosesOnlyWithLongEnoughMarker() {
    let lines = ["````", "```", "still code", "````"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertTrue(states[0].isFenceDelimiter)
    XCTAssertTrue(states[1].insideFence)
    XCTAssertFalse(states[1].isFenceDelimiter)
    XCTAssertTrue(states[2].insideFence)
    XCTAssertTrue(states[3].isFenceDelimiter)
  }

  func testMarkdownUnclosedBracketRunDoesNotStallRendering() {
    let line = String(repeating: "[", count: 5_000)
    let start = Date()

    let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      line,
      font: TextDocumentSyntax.markdown.font)

    XCTAssertEqual(rendered, line)
    XCTAssertLessThan(Date().timeIntervalSince(start), 1)
  }

  func testMarkdownSourceFallbackConcealsTaskMarkerButKeepsTextReadable() throws {
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

  func testMarkdownSourceFallbackConcealsOrderedMarkers() throws {
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

  func testMarkdownUnderscoreEmphasisStylesWithoutTouchingIntrawordNames() {
    let storage = NSTextStorage(
      string: "Use _em_ and __strong__ and ___both___, but keep snake_case and __init__.")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "em")?.fontDescriptor.symbolicTraits
        .contains(.italic),
      true)
    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "strong")?.fontDescriptor.symbolicTraits
        .contains(.bold),
      true)
    let both = storage.resolvedFont(in: storage.string, matching: "both")?.fontDescriptor
      .symbolicTraits
    XCTAssertEqual(both?.contains(.bold), true)
    XCTAssertEqual(both?.contains(.italic), true)
    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "case")?.fontDescriptor.symbolicTraits
        .contains(.italic),
      false)
    XCTAssertEqual(
      storage.resolvedFont(in: storage.string, matching: "init")?.fontDescriptor.symbolicTraits
        .contains(.bold),
      true)
  }

  func testMarkdownUnderscoreEmphasisSupportsJapaneseText() throws {
    let storage = NSTextStorage(string: "これは_強調_です")

    TextDocumentSyntaxHighlighter.apply(
      to: storage,
      text: storage.string,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font
    )

    let obliqueness = try XCTUnwrap(storage.obliqueness(in: storage.string, matching: "強調"))
    XCTAssertEqual(obliqueness, MarkdownDocumentMetrics.syntheticItalicObliqueness, accuracy: 0.001)
  }

  func testMarkdownClosedATXHeadingStripsTrailingMarkerRun() {
    let line = "## Title ##"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]

    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        line, font: TextDocumentSyntax.markdown.font, state: state),
      "Title")
  }

  func testMarkdownCheckedTaskTextUsesSecondaryColor() {
    let source = "- [x] Done"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [source])[0]
    let line = TextDocumentSyntaxHighlighter.highlightedLine(
      source,
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font,
      markdownLineState: state)

    XCTAssertEqual(line.string, "Done")
    XCTAssertEqual(
      line.foregroundColor(in: line.string, matching: "Done"),
      NSColor.secondaryLabelColor)
  }

  func testMarkdownDoubleBacktickSpanAllowsSingleBacktickInside() {
    let rendered = TextDocumentSyntaxHighlighter.highlightedLine(
      "Use ``a `b` c`` now",
      syntax: .markdown,
      font: TextDocumentSyntax.markdown.font)

    XCTAssertEqual(rendered.string, "Use a `b` c now")
    XCTAssertEqual(
      rendered.resolvedFont(in: rendered.string, matching: "a `b` c")?.fontDescriptor.symbolicTraits
        .contains(.monoSpace),
      true)
  }

  func testMarkdownEmailAutolinkDropsAnglesWithoutCreatingLinkTarget() {
    let line = "Contact <agent@example.com> today"
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
      line, font: TextDocumentSyntax.markdown.font, state: state)
    let targets = TextDocumentSyntaxHighlighter.markdownLinkTargets(for: rendered, state: state)

    XCTAssertEqual(rendered, "Contact agent@example.com today")
    XCTAssertTrue(targets.isEmpty)
  }

  func testMarkdownBackslashHardBreakHidesTrailingSlash() {
    let line = #"Line with hard break\"#
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]

    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        line, font: TextDocumentSyntax.markdown.font, state: state),
      "Line with hard break")
  }

  func testMarkdownShortTableDelimiterCellsAreAccepted() {
    let lines = ["| Left | Right | Center |", "| - | --: | :-: |", "| A | 1 | yes |"]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(states[0].tableColumns.map(\.alignment), [.left, .right, .center])
    XCTAssertTrue(states[1].isTableSeparator)
    XCTAssertTrue(states[2].isTableRow)
  }

  @MainActor
  func testMarkdownInvalidTaskMarkerStaysLiteralBulletText() throws {
    let view = LineRenderingTextView()
    view.syntax = .markdown
    view.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
    view.setBuffer(try TextBuffer.open(bytes: Data("- [-] maybe".utf8)))

    XCTAssertTrue(
      view.markdownTaskCheckboxTargetsForTesting(inLineRange: 0..<view.lineCount).isEmpty)
  }

  func testMarkdownSourceFallbackStrikethroughStylesContentAndConcealsMarkers() {
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

  func testMarkdownSourceFallbackSetextHeadingScalesPreviousLineAndConcealsUnderline() {
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

  func testMarkdownFrontMatterRendersAsMetadataRows() {
    let markdown = """
      ---
      name: pdf
      description: Comprehensive PDF toolkit
      allowed-tools: [Read, Write, Bash]
      ---
      # Body
      """
    let lines = markdown.components(separatedBy: "\n")
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let name = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[1], syntax: .markdown, font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[1])
    let tools = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[3], syntax: .markdown, font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[3])

    XCTAssertEqual(name.string, "name\npdf")
    XCTAssertEqual(
      tools.string,
      "allowed-tools\nRead\(MarkdownDocumentMetrics.frontMatterChipDisplaySeparator)Write"
        + "\(MarkdownDocumentMetrics.frontMatterChipDisplaySeparator)Bash")
    XCTAssertTrue(try XCTUnwrap(name.paragraphStyle(at: 0)?.tabStops).isEmpty)
    XCTAssertTrue(try XCTUnwrap(tools.paragraphStyle(at: 0)?.tabStops).isEmpty)
    XCTAssertFalse(
      try XCTUnwrap(name.resolvedFont(in: name.string, matching: "name"))
        .fontDescriptor.symbolicTraits.contains(.monoSpace))
    XCTAssertLessThan(
      try XCTUnwrap(name.resolvedFont(in: name.string, matching: "name")).pointSize,
      try XCTUnwrap(name.resolvedFont(in: name.string, matching: "pdf")).pointSize)
    XCTAssertEqual(
      name.foregroundColor(in: name.string, matching: "name"), NSColor.tertiaryLabelColor)
    XCTAssertEqual(name.foregroundColor(in: name.string, matching: "pdf"), NSColor.labelColor)

    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[0], font: TextDocumentSyntax.markdown.font, state: states[0]), "")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.highlightedLine(
        "# Body", syntax: .markdown, font: TextDocumentSyntax.markdown.font,
        markdownLineState: states[5]
      ).resolvedFont(at: 0)?.pointSize,
      MarkdownDocumentMetrics.headingFont(level: 1).pointSize)
  }

  func testMarkdownFrontMatterSequenceValuesRenderAsCollectedChips() {
    let lines = [
      "---",
      "reviewers:",
      "  - dario",
      "  - role: reviewer",
      "  - musk",
      "---",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let reviewers = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[1], syntax: .markdown, font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[1])
    let dario = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[2], syntax: .markdown, font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[2])

    XCTAssertEqual(
      reviewers.string,
      "reviewers\ndario\(MarkdownDocumentMetrics.frontMatterChipDisplaySeparator)"
        + "role: reviewer\(MarkdownDocumentMetrics.frontMatterChipDisplaySeparator)musk")
    XCTAssertEqual(dario.string, "")
    XCTAssertTrue(try XCTUnwrap(reviewers.paragraphStyle(at: 0)?.tabStops).isEmpty)
    XCTAssertEqual(
      try XCTUnwrap(reviewers.resolvedFont(in: reviewers.string, matching: "dario")).pointSize,
      MarkdownDocumentMetrics.frontMatterChipFont.pointSize,
      accuracy: 0.5)
    XCTAssertEqual(states[1].frontMatterField?.rendersValuesAsChips, true)
    XCTAssertEqual(
      states[1].frontMatterField?.values.map(\.text), ["dario", "role: reviewer", "musk"])
    XCTAssertEqual(states[2].isFrontMatterSequenceContinuation, true)
    XCTAssertEqual(states[2].frontMatterSequenceValue?.text, "dario")
    XCTAssertEqual(
      states[2].frontMatterSequenceValue?.sourceRange,
      NSRange(location: 4, length: 5))
    XCTAssertNil(states[3].frontMatterField)
    XCTAssertEqual(states[3].isFrontMatterSequenceContinuation, true)
    XCTAssertEqual(states[3].frontMatterSequenceValue?.text, "role: reviewer")
    XCTAssertEqual(
      TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[2], font: TextDocumentSyntax.markdown.font, state: states[2]), "")

    let map = TextDocumentSyntaxHighlighter.markdownDisplayMap(for: lines[2], state: states[2])
    XCTAssertEqual(
      map.bufferRange(forDisplayStart: 0, end: 0, includeWholeLineMarkers: false),
      NSRange(location: 4, length: 0))

    let separatorLength = (MarkdownDocumentMetrics.frontMatterChipDisplaySeparator as NSString)
      .length
    let valueStart =
      ("reviewers" as NSString).length + MarkdownDocumentMetrics.frontMatterKeyValueSeparatorLength
    XCTAssertEqual(
      LineRenderingTextView.frontMatterChipDisplayRanges(
        keyLength: ("reviewers" as NSString).length,
        values: states[1].frontMatterField?.values ?? []),
      [
        NSRange(location: valueStart, length: 5),
        NSRange(location: valueStart + 5 + separatorLength, length: 14),
        NSRange(location: valueStart + 5 + separatorLength + 14 + separatorLength, length: 4),
      ])
  }

  func testMarkdownFrontMatterSequenceValuesWithColonsStaySequenceRows() {
    let lines = [
      "---",
      "- role: reviewer",
      "- https://example.com",
      "- 10:30",
      "---",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertNil(states[1].frontMatterField)
    XCTAssertEqual(states[1].frontMatterSequenceValue?.text, "role: reviewer")
    XCTAssertNil(states[2].frontMatterField)
    XCTAssertEqual(states[2].frontMatterSequenceValue?.text, "https://example.com")
    XCTAssertNil(states[3].frontMatterField)
    XCTAssertEqual(states[3].frontMatterSequenceValue?.text, "10:30")

    let role = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[1], syntax: .markdown, font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[1])
    XCTAssertEqual(role.string, "role: reviewer")
  }

  func testMarkdownFrontMatterQuotedEmptyScalarDoesNotCollectFollowingSequence() {
    let lines = [
      "---",
      #"note: """#,
      "  - should stay visible",
      "---",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)

    XCTAssertEqual(states[1].frontMatterField?.key, "note")
    XCTAssertEqual(states[1].frontMatterField?.values.first?.text, "")
    XCTAssertEqual(states[1].frontMatterField?.rendersValuesAsChips, false)
    XCTAssertEqual(states[2].frontMatterSequenceValue?.text, "should stay visible")
    XCTAssertEqual(states[2].isFrontMatterSequenceContinuation, false)

    let item = TextDocumentSyntaxHighlighter.highlightedLine(
      lines[2], syntax: .markdown, font: TextDocumentSyntax.markdown.font,
      markdownLineState: states[2])
    XCTAssertEqual(item.string, "should stay visible")
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

  func testMarkdownSourceFallbackImageSyntaxIsNotTreatedAsALink() {
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

  fileprivate func obliqueness(in text: String, matching substring: String) -> CGFloat? {
    let range = (text as NSString).range(of: substring)
    XCTAssertNotEqual(range.location, NSNotFound)
    return attribute(.obliqueness, at: range.location, effectiveRange: nil) as? CGFloat
  }

  fileprivate func paragraphStyle(at location: Int) -> NSParagraphStyle? {
    attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
  }
}
