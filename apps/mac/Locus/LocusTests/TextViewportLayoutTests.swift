import AppKit
import XCTest

@testable import Locus

final class TextViewportLayoutTests: XCTestCase {
  private let layout = TextViewportLayout(lineHeight: 10)

  // MARK: Shared viewer factories

  @MainActor
  private func makeViewer(_ contents: String) throws -> LineRenderingTextView {
    let buffer = try TextBuffer.open(bytes: Data(contents.utf8))
    let view = LineRenderingTextView()
    view.setBuffer(buffer)
    return view
  }

  @MainActor
  private func makeEditableViewer(_ contents: String) throws -> LineRenderingTextView {
    let view = try makeViewer(contents)
    view.isEditable = true
    return view
  }

  /// The whole buffer content, for round-trip assertions (terminators normalized
  /// to LF, matching the line-based buffer read).
  @MainActor
  private func content(of view: LineRenderingTextView) -> String {
    guard let buffer = view.editableBuffer else { return "" }
    return buffer.text(forLineRange: 0, count: buffer.lineCount)
  }

  func testContentHeightScalesWithLineCount() {
    XCTAssertEqual(layout.contentHeight(lineCount: 5), 50)
    XCTAssertEqual(layout.contentHeight(lineCount: 1), 10)
  }

  func testContentHeightTreatsEmptyBufferAsOneLine() {
    // An empty buffer reports one (empty) line, so height is never zero.
    XCTAssertEqual(layout.contentHeight(lineCount: 0), 10)
  }

  func testFrameHeightAddsScrollPastEndTailForTallDocuments() {
    let frameHeight = layout.frameHeight(visualRows: 100, viewportHeight: 400)

    XCTAssertEqual(frameHeight, 1390)
    XCTAssertEqual(frameHeight - 400, 1000 - 10)
  }

  func testFrameHeightKeepsSingleRowDocumentsAtViewportHeight() {
    XCTAssertEqual(layout.frameHeight(visualRows: 0, viewportHeight: 400), 400)
    XCTAssertEqual(layout.frameHeight(visualRows: 1, viewportHeight: 400), 400)
  }

  func testFrameHeightAddsScrollPastEndTailForFittingMultiRowDocuments() {
    XCTAssertEqual(layout.frameHeight(visualRows: 2, viewportHeight: 400), 410)
    XCTAssertEqual(layout.frameHeight(visualRows: 40, viewportHeight: 400), 790)
  }

  func testFrameHeightActivatesOverscrollOnceContentExceedsViewport() {
    XCTAssertEqual(layout.frameHeight(visualRows: 41, viewportHeight: 400), 800)
  }

  func testFrameHeightClampsOverscrollForTinyViewports() {
    XCTAssertEqual(layout.frameHeight(visualRows: 100, viewportHeight: 6), 1000)
    XCTAssertEqual(layout.frameHeight(visualRows: 100, viewportHeight: 0), 1000)
  }

  func testFrameHeightTreatsEmptyBufferAsOneRow() {
    XCTAssertEqual(layout.frameHeight(visualRows: 0, viewportHeight: 400), 400)
  }

  func testMarkdownViewportTopInsetAddsTwelvePoints() {
    XCTAssertEqual(
      LargeTextViewportMetrics.topContentInset(for: .plainText),
      LargeTextViewportMetrics.topContentInset)
    XCTAssertEqual(
      LargeTextViewportMetrics.topContentInset(for: .markdown),
      LargeTextViewportMetrics.topContentInset + 12)
    XCTAssertEqual(
      LargeTextViewportMetrics.topContentInset(for: .markdown, markdownViewMode: .source),
      LargeTextViewportMetrics.topContentInset)
  }

  func testMarkdownSourceModeUsesPlainTextPresentation() {
    XCTAssertEqual(
      TextViewportPresentation.displaySyntax(for: .markdown, markdownViewMode: .source),
      .plainText)
    XCTAssertTrue(
      TextViewportPresentation.usesClassicLineNumberGutter(
        for: .markdown, markdownViewMode: .source, backendIsReadOnly: false))
    XCTAssertFalse(
      TextViewportPresentation.usesClassicLineNumberGutter(
        for: .markdown, markdownViewMode: .rendered, backendIsReadOnly: false))
  }

  func testYOffsetIsLineTimesHeight() {
    XCTAssertEqual(layout.yOffset(forLine: 0), 0)
    XCTAssertEqual(layout.yOffset(forLine: 7), 70)
  }

  func testVisibleRangeCoversIntersectingLines() {
    // Rect [25, 55) touches lines 2..6 (line i spans [i*10, i*10+10)).
    let range = layout.visibleLineRange(
      in: CGRect(x: 0, y: 25, width: 100, height: 30), lineCount: 100)
    XCTAssertEqual(range, 2..<6)
  }

  func testVisibleRangeClampsToLineCount() {
    let range = layout.visibleLineRange(
      in: CGRect(x: 0, y: 80, width: 100, height: 1000), lineCount: 10)
    XCTAssertEqual(range, 8..<10)
  }

  func testVisibleRangeStartsAtZeroForNegativeOrigin() {
    let range = layout.visibleLineRange(
      in: CGRect(x: 0, y: -50, width: 100, height: 70), lineCount: 100)
    XCTAssertEqual(range, 0..<2)
  }

  func testVisibleRangeIsEmptyPastTheEnd() {
    let range = layout.visibleLineRange(
      in: CGRect(x: 0, y: 500, width: 100, height: 30), lineCount: 10)
    XCTAssertTrue(range.isEmpty)
  }

  func testVisibleRangeIsEmptyForEmptyBufferAndZeroHeight() {
    XCTAssertTrue(
      layout.visibleLineRange(in: CGRect(x: 0, y: 0, width: 100, height: 50), lineCount: 0)
        .isEmpty)
    XCTAssertTrue(
      layout.visibleLineRange(in: CGRect(x: 0, y: 0, width: 100, height: 0), lineCount: 10)
        .isEmpty)
  }

  func testVisibleRangeForExactLineBoundaries() {
    // A rect aligned exactly to line boundaries includes only those lines.
    let range = layout.visibleLineRange(
      in: CGRect(x: 0, y: 30, width: 100, height: 20), lineCount: 100)
    XCTAssertEqual(range, 3..<5)
  }

  // MARK: Multi-click selection

  @MainActor
  func testSelectWordSelectsTheWordAtThePosition() throws {
    let view = try makeViewer("hello world")
    view.selectWord(at: .init(line: 0, columnUTF16: 8))  // inside "world"
    XCTAssertEqual(view.selectedText(), "world")
  }

  @MainActor
  func testSelectWordKeepsNonASCIIWordIntact() throws {
    // Locale-aware word boundaries keep an accented word whole rather than
    // splitting at the diacritic.
    let view = try makeViewer("café latte")
    view.selectWord(at: .init(line: 0, columnUTF16: 1))  // inside "café"
    XCTAssertEqual(view.selectedText(), "café")
  }

  @MainActor
  func testSelectWordOnEmptyLineCollapsesToCaret() throws {
    let view = try makeViewer("\nsecond")  // first line is empty
    view.selectWord(at: .init(line: 0, columnUTF16: 0))
    XCTAssertEqual(view.selection?.isEmpty, true)
  }

  @MainActor
  func testSelectWordPastLineEndCollapsesToCaret() throws {
    // A double-click in the empty area to the right of the text (column at or past
    // the line length) places a caret instead of selecting the last word.
    let view = try makeViewer("hello world")  // length 11
    view.selectWord(at: .init(line: 0, columnUTF16: 11))
    XCTAssertEqual(view.selection?.isEmpty, true)
  }

  @MainActor
  func testSelectWordOnWhitespaceSelectsOnlyWhitespace() throws {
    // Clicking on the gap between words selects whitespace, never a neighbouring
    // word. (Exact run length is locale/tokenizer-defined; assert it is blank.)
    let view = try makeViewer("ab cd")
    view.selectWord(at: .init(line: 0, columnUTF16: 2))  // the space
    let selected = try XCTUnwrap(view.selectedText())
    XCTAssertFalse(selected.isEmpty)
    XCTAssertTrue(selected.trimmingCharacters(in: .whitespaces).isEmpty)
  }

  @MainActor
  func testSelectLineSelectsTheWholeLineContent() throws {
    let view = try makeViewer("ab\ncde\nf")
    view.selectLine(at: 1)
    XCTAssertEqual(view.selectedText(), "cde")  // content only, no trailing newline
  }

  @MainActor
  func testSelectLineClampsOutOfRangeLine() throws {
    let view = try makeViewer("only")
    view.selectLine(at: 99)
    XCTAssertEqual(view.selectedText(), "only")
  }

  // MARK: Drag-extend by word / line

  @MainActor
  func testWordDragExtendsBySpanningWholeWords() throws {
    let view = try makeViewer("one two three")
    view.beginWordSelection(at: .init(line: 0, columnUTF16: 5))  // "two"
    XCTAssertEqual(view.selectedText(), "two")
    view.extendSelection(to: .init(line: 0, columnUTF16: 9))  // inside "three"
    XCTAssertEqual(view.selectedText(), "two three")  // whole words, not "two thr"
  }

  @MainActor
  func testWordDragLeftSpansWholeWords() throws {
    let view = try makeViewer("one two three")
    view.beginWordSelection(at: .init(line: 0, columnUTF16: 5))  // "two"
    view.extendSelection(to: .init(line: 0, columnUTF16: 1))  // inside "one"
    XCTAssertEqual(view.selectedText(), "one two")
  }

  @MainActor
  func testWordDragWithinAnchorWordKeepsWholeWord() throws {
    let view = try makeViewer("one two three")
    view.beginWordSelection(at: .init(line: 0, columnUTF16: 5))  // "two"
    view.extendSelection(to: .init(line: 0, columnUTF16: 6))  // still inside "two"
    XCTAssertEqual(view.selectedText(), "two")  // never shrinks below the anchored word
  }

  @MainActor
  func testLineDragExtendsBySpanningWholeLines() throws {
    let view = try makeViewer("ab\ncde\nf")
    view.beginLineSelection(at: 1)  // "cde"
    view.extendSelection(to: .init(line: 2, columnUTF16: 0))  // onto last line
    XCTAssertEqual(view.selectedText(), "cde\nf")  // whole lines
  }

  @MainActor
  func testCharacterDragExtendsByCharacter() throws {
    let view = try makeViewer("hello")
    view.beginCaretSelection(at: .init(line: 0, columnUTF16: 0))
    view.extendSelection(to: .init(line: 0, columnUTF16: 3))
    XCTAssertEqual(view.selectedText(), "hel")  // single-click drag stays per-character
  }

  @MainActor
  func testLineDragUpwardSpansWholeLines() throws {
    let view = try makeViewer("ab\ncde\nf")
    view.beginLineSelection(at: 1)  // "cde"
    view.extendSelection(to: .init(line: 0, columnUTF16: 0))  // drag up onto the first line
    XCTAssertEqual(view.selectedText(), "ab\ncde")  // whole lines, reversed direction
  }

  @MainActor
  func testWordDragAcrossLinesSpansWholeWords() throws {
    let view = try makeViewer("one two\nthree four")
    view.beginWordSelection(at: .init(line: 0, columnUTF16: 5))  // "two"
    view.extendSelection(to: .init(line: 1, columnUTF16: 2))  // inside "three" on the next line
    XCTAssertEqual(view.selectedText(), "two\nthree")  // whole words across the line boundary
  }

  // MARK: Caret blink

  func testCaretBlinksOnlyWhenFocusedInActiveKeyWindowWithCollapsedSelection() {
    // Blinks with a caret only while this view owns the keyboard focus in the
    // active key window. A first responder in an inactive app must not keep a
    // visible "focus is here" caret behind another app.
    XCTAssertTrue(
      LineRenderingTextView.caretShouldBlink(
        isFirstResponder: true, isActiveKeyWindow: true, isComposing: false,
        selectionIsEmpty: true))
    XCTAssertFalse(
      LineRenderingTextView.caretShouldBlink(
        isFirstResponder: false, isActiveKeyWindow: true, isComposing: false,
        selectionIsEmpty: true))
    XCTAssertFalse(
      LineRenderingTextView.caretShouldBlink(
        isFirstResponder: true, isActiveKeyWindow: false, isComposing: false,
        selectionIsEmpty: true))
    XCTAssertFalse(
      LineRenderingTextView.caretShouldBlink(
        isFirstResponder: true, isActiveKeyWindow: true, isComposing: true,
        selectionIsEmpty: true))
    XCTAssertFalse(
      LineRenderingTextView.caretShouldBlink(
        isFirstResponder: true, isActiveKeyWindow: true, isComposing: false,
        selectionIsEmpty: false))
  }

  @MainActor
  func testActivityReschedulesBlinkTimerSoTheCaretStaysSolid() throws {
    // While blinking, user activity must restart the timer (not just flip the
    // flag), so a toggle that was about to fire cannot hide the caret right after
    // the action.
    let view = try makeViewer("hi")
    view.startCaretBlinking()
    let before = try XCTUnwrap(view.caretBlinkTimer)
    view.showCaretSolid()
    XCTAssertTrue(view.caretBlinkOn)
    XCTAssertFalse(before === view.caretBlinkTimer)  // a fresh full interval
    view.stopCaretBlinking()
  }

  @MainActor
  func testShowCaretSolidWithoutTimerKeepsPhaseSolidAndUnscheduled() throws {
    // When not blinking (unfocused: no timer), forcing solid must not start a timer.
    let view = try makeViewer("hi")
    view.showCaretSolid()
    XCTAssertTrue(view.caretBlinkOn)
    XCTAssertNil(view.caretBlinkTimer)
  }

  // MARK: Accessibility (range-based reading)

  @MainActor
  func testAccessibilityStringReturnsTextForRange() throws {
    let view = try makeViewer("ab\ncde\nf")
    XCTAssertEqual(view.accessibilityString(for: NSRange(location: 3, length: 3)), "cde")
    XCTAssertEqual(view.accessibilityString(for: NSRange(location: 0, length: 8)), "ab\ncde\nf")
  }

  @MainActor
  func testAccessibilityStringRefusesOverBudgetRange() throws {
    let view = try makeViewer("ab\ncde\nf")
    view.maximumAccessibilityStringLength = 2
    XCTAssertNil(view.accessibilityString(for: NSRange(location: 0, length: 3)))
  }

  @MainActor
  func testAccessibilityStringRefusesRangePastEnd() throws {
    let view = try makeViewer("ab\ncde\nf")  // length 8
    XCTAssertNil(view.accessibilityString(for: NSRange(location: 6, length: 5)))
  }

  @MainActor
  func testAccessibilityStringRefusesOverflowingRange() throws {
    // A hostile range whose location + length would overflow must be rejected, not
    // trap.
    let view = try makeViewer("ab\ncde\nf")
    XCTAssertNil(view.accessibilityString(for: NSRange(location: Int.max - 1, length: 10)))
  }

  @MainActor
  func testAccessibilityStringReadsBeyondTheDisplayClip() throws {
    // A line longer than the display clip must still read in full-document
    // coordinates: the offsets exposed by numberOfCharacters/rangeForLine and the
    // text returned by accessibilityString must agree past the clip.
    let longLine = String(repeating: "a", count: 25_000)
    let view = try makeViewer(longLine)
    XCTAssertEqual(view.accessibilityNumberOfCharacters(), 25_000)
    let whole = view.accessibilityString(for: NSRange(location: 0, length: 25_000))
    XCTAssertEqual(whole?.count, 25_000)
    // A slice past the 20000-char display clip returns the real characters.
    XCTAssertEqual(view.accessibilityString(for: NSRange(location: 22_000, length: 3)), "aaa")
  }

  @MainActor
  func testAccessibilityLineForCharacterOffset() throws {
    let view = try makeViewer("ab\ncde\nf")
    XCTAssertEqual(view.accessibilityLine(for: 0), 0)  // in "ab"
    XCTAssertEqual(view.accessibilityLine(for: 3), 1)  // start of "cde"
    XCTAssertEqual(view.accessibilityLine(for: 7), 2)  // "f"
  }

  @MainActor
  func testAccessibilityRangeForLineIncludesNewline() throws {
    let view = try makeViewer("ab\ncde\nf")
    XCTAssertEqual(view.accessibilityRange(forLine: 0), NSRange(location: 0, length: 3))  // "ab\n"
    XCTAssertEqual(view.accessibilityRange(forLine: 1), NSRange(location: 3, length: 4))  // "cde\n"
    XCTAssertEqual(view.accessibilityRange(forLine: 2), NSRange(location: 7, length: 1))  // "f"
  }

  @MainActor
  func testAccessibilitySelectedTextRangeMatchesSelection() throws {
    let view = try makeViewer("ab\ncde\nf")
    view.selectLine(at: 1)  // "cde" → UTF-16 [3, 6)
    XCTAssertEqual(view.accessibilitySelectedTextRange(), NSRange(location: 3, length: 3))
  }

  @MainActor
  func testAccessibilityInsertionPointLineNumberFollowsCaret() throws {
    let view = try makeViewer("ab\ncde\nf")
    view.beginCaretSelection(at: .init(line: 2, columnUTF16: 0))
    XCTAssertEqual(view.accessibilityInsertionPointLineNumber(), 2)
  }

  // MARK: Scroll rendering stability

  @MainActor
  func testViewerOptsOutOfResponsiveScrolling() {
    // The synthesized-height view draws viewport-relative chrome (pinned gutter,
    // caret, selection). Responsive scrolling's overdraw cache renders those at a
    // stale offset — tearing rows and blanking bands while scrolling — so the view
    // must opt out and redraw the visible band on each scroll instead.
    XCTAssertFalse(LineRenderingTextView.isCompatibleWithResponsiveScrolling)
  }

  @MainActor
  func testViewerIsOpaque() {
    // The view fills every dirty rect with the background before drawing, so it is
    // opaque; declaring so avoids compositing flashes in the layer-backed host.
    XCTAssertTrue(LineRenderingTextView().isOpaque)
  }

  @MainActor
  func testViewerKeepsLineNumberGutterForPlainText() throws {
    // The custom engine draws line numbers for every text file regardless of size
    // (unlike the legacy editor, which hides them above a length cap). Plain text
    // must still get a non-zero gutter so numbers are drawn.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.syntax = .plainText
    let buffer = try TextBuffer.open(bytes: Data("alpha\nbeta\ngamma\n".utf8))
    view.setBuffer(buffer)
    XCTAssertTrue(view.showsLineNumbers)
    XCTAssertGreaterThan(view.gutterWidth, 0)
  }

  // MARK: Open-failure messages

  @MainActor
  func testFailureMessageCallsOutLargeNonUTF8() {
    // A large non-UTF-8 file is rejected by the UTF-8-only buffer; the message
    // must explain the narrowing rather than surface a raw error.
    let message = VirtualizedTextDocumentView.failureMessage(
      for: TextBufferStoreError.tooLargeForEncoding)
    XCTAssertTrue(message.contains("UTF-8"))
    XCTAssertTrue(message.lowercased().contains("large"))
  }

  @MainActor
  func testFailureMessageFallsBackToLocalizedDescription() {
    let error = TextBufferError.invalidOffset
    XCTAssertEqual(
      VirtualizedTextDocumentView.failureMessage(for: error),
      error.localizedDescription
    )
  }

  // MARK: Syntax highlighter

  @MainActor
  func testHighlighterStylesAPlainMutableAttributedString() {
    // The band viewer highlights a throwaway NSMutableAttributedString rather
    // than an NSTextStorage; verify that generalized entry point colors a token.
    let source = "let x = 1"
    let attributed = NSMutableAttributedString(string: source)
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    TextDocumentSyntaxHighlighter.apply(
      to: attributed,
      text: source,
      syntax: .code,
      font: font,
      range: NSRange(location: 0, length: (source as NSString).length)
    )
    // "let" is a keyword, so the first character is no longer the base color.
    let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    XCTAssertNotNil(color)
    XCTAssertNotEqual(color, NSColor.labelColor)
  }

  // MARK: Gutter metrics

  @MainActor
  func testGutterWidthHasAMinimumForSmallFiles() {
    let font = GutterMetrics.lineNumberFont
    XCTAssertEqual(GutterMetrics.width(lineCount: 1, font: font), GutterMetrics.minimumWidth)
    XCTAssertEqual(GutterMetrics.width(lineCount: 9, font: font), GutterMetrics.minimumWidth)
  }

  @MainActor
  func testGutterWidthGrowsWithDigitCount() {
    let font = GutterMetrics.lineNumberFont
    XCTAssertGreaterThan(
      GutterMetrics.width(lineCount: 1_000_000, font: font),
      GutterMetrics.width(lineCount: 1, font: font)
    )
  }

  @MainActor
  func testGutterWidthIsZeroWhenLineNumbersHidden() {
    // A hidden gutter must take no horizontal space so the text starts flush.
    let textView = LineRenderingTextView()
    textView.showsLineNumbers = false

    XCTAssertEqual(textView.gutterWidth, 0)
  }

  @MainActor
  func testGutterWidthMatchesGutterMetricsWhenShown() {
    // With line numbers shown the gutter reserves the metric width. An empty
    // buffer reports one line, so the width is the minimum.
    let textView = LineRenderingTextView()
    textView.showsLineNumbers = true

    XCTAssertEqual(
      textView.gutterWidth,
      GutterMetrics.width(lineCount: textView.lineCount, font: GutterMetrics.lineNumberFont)
    )
  }

  // MARK: TextSelection model

  func testSelectionStartAndEndAreOrderedRegardlessOfDragDirection() {
    // Dragging upward (head before anchor) still reports start < end.
    let anchor = TextSelection.Endpoint(line: 5, columnUTF16: 2)
    let head = TextSelection.Endpoint(line: 1, columnUTF16: 8)
    let selection = TextSelection(anchor: anchor, head: head)
    XCTAssertEqual(selection.start, head)
    XCTAssertEqual(selection.end, anchor)
    XCTAssertFalse(selection.isEmpty)
  }

  func testCaretSelectionIsEmpty() {
    let caret = TextSelection(caretAt: .init(line: 3, columnUTF16: 4))
    XCTAssertTrue(caret.isEmpty)
    XCTAssertNil(caret.columnSpan(onLine: 3, lineLengthUTF16: 10))
  }

  func testColumnSpanReturnsNilOutsideSelection() {
    let selection = TextSelection(
      anchor: .init(line: 2, columnUTF16: 1), head: .init(line: 4, columnUTF16: 3))
    XCTAssertNil(selection.columnSpan(onLine: 1, lineLengthUTF16: 10))
    XCTAssertNil(selection.columnSpan(onLine: 5, lineLengthUTF16: 10))
  }

  func testColumnSpanOnSingleSelectedLine() {
    let selection = TextSelection(
      anchor: .init(line: 2, columnUTF16: 3), head: .init(line: 2, columnUTF16: 7))
    let span = selection.columnSpan(onLine: 2, lineLengthUTF16: 20)
    XCTAssertEqual(span?.start, 3)
    XCTAssertEqual(span?.end, 7)
  }

  func testColumnSpanAcrossMultipleLinesClampsToLineEnds() {
    // First line: from start column to its end. Middle line: whole line. Last
    // line: from 0 to the end column.
    let selection = TextSelection(
      anchor: .init(line: 1, columnUTF16: 4), head: .init(line: 3, columnUTF16: 2))
    XCTAssertEqual(
      selection.columnSpan(onLine: 1, lineLengthUTF16: 10).map { [$0.start, $0.end] }, [4, 10])
    XCTAssertEqual(
      selection.columnSpan(onLine: 2, lineLengthUTF16: 15).map { [$0.start, $0.end] }, [0, 15])
    XCTAssertEqual(
      selection.columnSpan(onLine: 3, lineLengthUTF16: 8).map { [$0.start, $0.end] }, [0, 2])
  }

  // MARK: selectedText (copy)

  /// Builds a viewer over a temporary file through the read-only large-file
  /// backend, exercising the `setReadOnlyDocument` path the surface uses for files
  /// too big to edit in memory.
  @MainActor
  private func makeReadOnlyViewer(_ contents: String) throws -> LineRenderingTextView {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "locus-readonly-viewer-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "large.txt")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    let view = LineRenderingTextView()
    view.setReadOnlyDocument(try LargeFile.open(at: url))
    return view
  }

  @MainActor
  func testReadOnlyDocumentRendersThroughTheReaderWithoutAnEditableBuffer() throws {
    let view = try makeReadOnlyViewer("alpha\nbeta\ngamma")
    // Reads flow through the read-only backend; there is no editable buffer.
    XCTAssertNil(view.editableBuffer)
    XCTAssertEqual(view.lineCount, 3)
    // The read paths still drive selection over the large-file backend.
    view.selectAll(nil)
    XCTAssertEqual(view.selection?.start, .init(line: 0, columnUTF16: 0))
    XCTAssertEqual(view.selection?.end.line, 2)
  }

  @MainActor
  func testSelectedTextRoundTripsMultiLineSelection() throws {
    let view = try makeViewer("alpha\nbravo\ncharlie")
    view.selectAll(nil)
    XCTAssertEqual(view.selectedText(), "alpha\nbravo\ncharlie")
  }

  @MainActor
  func testSelectedTextNormalizesCRLFToLF() throws {
    // The line-based viewer does not retain terminators, so a copy of a CRLF
    // document is normalized to LF. This is intentional for now.
    let view = try makeViewer("a\r\nb\r\nc")
    view.selectAll(nil)
    XCTAssertEqual(view.selectedText(), "a\nb\nc")
  }

  @MainActor
  func testSelectedTextClipsLongLineToDisplayLimit() throws {
    // Selection and copy share the displayed (clipped) text, so a copy of an
    // over-long line is bounded to what is shown/selectable.
    let view = try makeViewer(String(repeating: "x", count: 25_000))
    view.selectAll(nil)
    XCTAssertEqual(view.selectedText()?.count, 20_000)
  }

  @MainActor
  func testSelectedTextRefusesSelectionOverByteBudget() throws {
    // A selection larger than the copy budget is refused rather than
    // materializing a giant string on the main thread.
    let view = try makeViewer("abcdefghij")
    view.maximumCopiedByteCount = 4
    view.selectAll(nil)
    XCTAssertNil(view.selectedText())
  }

  @MainActor
  func testSelectedTextIsNilWithoutSelection() throws {
    let view = try makeViewer("alpha\nbravo")
    XCTAssertNil(view.selectedText())
  }

  // MARK: Keyboard navigation

  @MainActor
  func testMoveRightAdvancesAndWrapsToNextLine() throws {
    let view = try makeViewer("ab\ncd")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))
    view.moveHorizontally(forward: true, extend: false)  // (0,2) = end of "ab"
    view.moveHorizontally(forward: true, extend: false)  // wraps to (1,0)
    XCTAssertEqual(view.selection?.head, .init(line: 1, columnUTF16: 0))
  }

  @MainActor
  func testMoveLeftAtDocumentStartStaysPut() throws {
    let view = try makeViewer("ab")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 0))
  }

  @MainActor
  func testMoveDownKeepsGoalColumnAcrossShortLine() throws {
    let view = try makeViewer("abcd\nef\nghij")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)
    view.moveHorizontally(forward: true, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // (0,3)
    view.moveVertically(down: true, extend: false)  // "ef" is shorter, clamps to its end
    XCTAssertEqual(view.selection?.head, .init(line: 1, columnUTF16: 2))
    view.moveVertically(down: true, extend: false)  // goal column restores on the longer line
    XCTAssertEqual(view.selection?.head, .init(line: 2, columnUTF16: 3))
  }

  @MainActor
  func testShiftMoveExtendsSelectionFromAnchor() throws {
    let view = try makeViewer("hello")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: true)
    view.moveHorizontally(forward: true, extend: true)
    XCTAssertEqual(view.selection?.anchor, .init(line: 0, columnUTF16: 0))
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
    XCTAssertEqual(view.selectedText(), "he")
  }

  @MainActor
  func testMoveToEndOfLineAndDocument() throws {
    let view = try makeViewer("hello\nworld!")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveToLineEdge(end: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 5))
    view.moveToDocumentEdge(end: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 1, columnUTF16: 6))
  }

  @MainActor
  func testMoveWordRightStopsAtWordEnd() throws {
    let view = try makeViewer("foo bar")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveByWord(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 3))  // end of "foo"
    view.moveByWord(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 7))  // end of "bar"
  }

  @MainActor
  func testPlainMoveCollapsesExistingSelectionToEdge() throws {
    let view = try makeViewer("hello")
    view.selectAll(nil)  // (0,0)..(0,5)
    view.moveHorizontally(forward: false, extend: false)  // collapses to start
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 0))
    XCTAssertTrue(view.selection?.isEmpty == true)
  }

  @MainActor
  func testMoveRightOverEmojiSkipsWholeGrapheme() throws {
    // 😀 is a surrogate pair (two UTF-16 units); the caret must step over it whole
    // and never land between the surrogates.
    let view = try makeViewer("a😀b")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))
    view.moveHorizontally(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 3))  // skipped the pair
    view.moveHorizontally(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))  // back over the pair
  }

  @MainActor
  func testWordMoveLandsOnComposedBoundaryAroundEmoji() throws {
    // The emoji is its own word unit (locale-aware), so word moves step a → 😀 → b.
    // Every landing column (1, 3, 4) is a grapheme boundary: the caret never lands
    // at index 2, inside the emoji's surrogate pair.
    let view = try makeViewer("a😀b")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveByWord(forward: true, extend: false)  // end of "a"
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))
    view.moveByWord(forward: true, extend: false)  // end of the emoji word
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 3))
    view.moveByWord(forward: true, extend: false)  // end of "b"
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 4))
  }

  @MainActor
  func testWordMoveStopsAtLocaleWordBoundaryAcrossScripts() throws {
    // The tokenizer splits scripts: a forward word move from the start of "猫cat"
    // stops after the ideograph rather than treating the whole run as one word
    // (which the previous alphanumeric heuristic did).
    let view = try makeViewer("猫cat dog")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveByWord(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))  // after 猫
  }

  @MainActor
  func testWordMoveBackwardStopsAtWordStarts() throws {
    let view = try makeViewer("one two three")
    view.moveToDocumentEdge(end: true, extend: false)  // (0,13)
    view.moveByWord(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 8))  // start of "three"
    view.moveByWord(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 4))  // start of "two"
    view.moveByWord(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 0))  // start of "one"
  }

  @MainActor
  func testWordMoveBackwardStopsAtScriptBoundary() throws {
    let view = try makeViewer("猫cat dog")  // length 8
    view.moveToDocumentEdge(end: true, extend: false)  // (0,8)
    view.moveByWord(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 5))  // start of "dog"
    view.moveByWord(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))  // start of "cat", after 猫
  }

  @MainActor
  func testWordMoveBackwardStaysOnGraphemeBoundaryAroundEmoji() throws {
    // Backward stops at 3 then 1 — both grapheme boundaries; the caret never lands
    // at index 2, inside the emoji's surrogate pair.
    let view = try makeViewer("a😀b")
    view.moveToDocumentEdge(end: true, extend: false)  // (0,4)
    view.moveByWord(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 3))  // start of "b"
    view.moveByWord(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))  // start of the emoji word
  }

  @MainActor
  func testWordMoveCollapsesReversedSelectionToDirectionalEdge() throws {
    // A right-to-left selection has its head before its anchor; a non-extending
    // word move must start from the directional edge (the end, here), not the head.
    let view = try makeViewer("one two three")
    view.moveToDocumentEdge(end: true, extend: false)  // caret at (0,13)
    for _ in 0..<9 { view.moveHorizontally(forward: false, extend: true) }
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 4))  // reversed selection
    view.moveByWord(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 13))  // collapsed to end edge
    XCTAssertTrue(view.selection?.isEmpty == true)
  }

  // MARK: Accessibility (role and value)

  @MainActor
  func testLargeViewerIsTextAreaAccessibilityElement() throws {
    let view = try makeViewer("hello\nworld")
    XCTAssertEqual(view.accessibilityRole(), .textArea)
    XCTAssertTrue(view.isAccessibilityElement())
  }

  @MainActor
  func testLargeViewerDoesNotExposeWholeDocumentAsValue() throws {
    // Range-based AX: the value must not materialize the (possibly huge) document.
    let view = try makeViewer("hello\nworld")
    XCTAssertNil(view.accessibilityValue() as Any?)
    XCTAssertEqual(view.accessibilityNumberOfCharacters(), 11)
  }

  @MainActor
  func testLargeViewerAccessibilitySelectedTextReflectsSelection() throws {
    let view = try makeViewer("hello\nworld")
    XCTAssertNil(view.accessibilitySelectedText())
    view.selectAll(nil)
    XCTAssertEqual(view.accessibilitySelectedText(), "hello\nworld")
  }

  @MainActor
  func testLargeViewerAccessibilitySelectedTextIsBoundedBelowCopyLimit() throws {
    // Assistive tech may poll repeatedly, so an over-budget selection reports no
    // text (whereas explicit copy, with its larger budget, would still work).
    let view = try makeViewer("abcdefghij")
    view.maximumAccessibilitySelectedTextByteCount = 4
    view.selectAll(nil)
    XCTAssertNil(view.accessibilitySelectedText())
    XCTAssertEqual(view.selectedText(), "abcdefghij")  // copy budget is far larger
  }

  // MARK: Editing

  @MainActor
  func testDeleteWordBackwardRemovesPreviousWord() throws {
    let view = try makeEditableViewer("one two three")
    view.moveToDocumentEdge(end: true, extend: false)  // caret after "three"
    view.deleteWordBackward()
    XCTAssertEqual(content(of: view), "one two ")
  }

  @MainActor
  func testDeleteWordForwardRemovesNextWord() throws {
    let view = try makeEditableViewer("one two three")
    view.moveToDocumentEdge(end: false, extend: false)  // caret before "one"
    view.deleteWordForward()
    XCTAssertEqual(content(of: view), " two three")
  }

  @MainActor
  func testEditingIsIgnoredWhenNotEditable() throws {
    let view = try makeViewer("abc")  // read-only by default
    view.moveToDocumentEdge(end: false, extend: false)
    view.insertText("X")
    view.deleteForward()
    XCTAssertEqual(content(of: view), "abc")
  }

  @MainActor
  func testInsertTextAtCaretAdvancesCaret() throws {
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,1)
    view.insertText("X")
    XCTAssertEqual(content(of: view), "aXbc")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
    XCTAssertTrue(view.selection?.isEmpty == true)
  }

  @MainActor
  func testTypingReplacesSelection() throws {
    let view = try makeEditableViewer("hello")
    view.selectAll(nil)  // (0,0)..(0,5)
    view.insertText("Z")
    XCTAssertEqual(content(of: view), "Z")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))
  }

  @MainActor
  func testInsertNewlineSplitsLineAndPlacesCaretAtNextLineStart() throws {
    let view = try makeEditableViewer("abcd")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,2)
    view.insertText("\n")
    XCTAssertEqual(content(of: view), "ab\ncd")
    XCTAssertEqual(view.editableBuffer?.lineCount, 2)
    XCTAssertEqual(view.selection?.head, .init(line: 1, columnUTF16: 0))
  }

  @MainActor
  func testDeleteBackwardRemovesPreviousCharacter() throws {
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: true, extend: false)  // caret (0,3)
    view.deleteBackward()
    XCTAssertEqual(content(of: view), "ab")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
  }

  @MainActor
  func testDeleteBackwardAtLineStartMergesLines() throws {
    let view = try makeEditableViewer("ab\ncd")
    view.moveToDocumentEdge(end: true, extend: false)  // caret (1,2)
    view.moveToLineEdge(end: false, extend: false)  // caret (1,0)
    view.deleteBackward()
    XCTAssertEqual(content(of: view), "abcd")
    XCTAssertEqual(view.editableBuffer?.lineCount, 1)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
  }

  @MainActor
  func testMarkdownDecoratedLinesShiftTextStartInsideColumn() throws {
    let view = try makeViewer("plain\n- Item\n> Quote")
    view.setFrameSize(NSSize(width: 420, height: 300))
    view.syntax = .markdown
    view.updateLayout()

    let baseX = view.markdownTextColumnXForTesting(line: 0)

    XCTAssertEqual(view.markdownTextColumnXForTesting(line: 1), baseX + 24, accuracy: 0.5)
    XCTAssertEqual(view.markdownTextColumnXForTesting(line: 2), baseX + 17, accuracy: 0.5)
    XCTAssertLessThan(
      view.markdownWrapContentWidthForTesting(line: 1),
      view.markdownWrapContentWidthForTesting())
  }

  @MainActor
  func testMarkdownCodeCardStaysFlushWithTextColumnAndIndentsCode() throws {
    let view = try makeViewer("```swift\nlet value = 1\n```")
    view.setFrameSize(NSSize(width: 520, height: 300))
    view.syntax = .markdown
    view.updateLayout()

    let baseX = view.markdownTextColumnXForTesting()
    let frame = try XCTUnwrap(
      view.markdownCodeBlockFrameForTesting(fromLine: 0, toLine: 2, visibleRows: 0..<3))

    XCTAssertEqual(frame.minX, baseX, accuracy: 0.5)
    XCTAssertEqual(frame.width, view.markdownWrapContentWidthForTesting(), accuracy: 0.5)
    XCTAssertEqual(
      view.markdownTextColumnXForTesting(line: 1),
      baseX + MarkdownDocumentMetrics.codeCardInset,
      accuracy: 0.5)
    XCTAssertEqual(
      view.markdownWrapContentWidthForTesting(line: 1),
      view.markdownWrapContentWidthForTesting()
        - MarkdownDocumentMetrics.codeCardInset,
      accuracy: 0.5)
  }

  @MainActor
  func testMarkdownIndentedCodeUsesCodeCardFamily() throws {
    let view = try makeViewer("    - nishi")
    view.setFrameSize(NSSize(width: 520, height: 300))
    view.syntax = .markdown
    view.updateLayout()

    let baseX = view.markdownTextColumnXForTesting()
    let frame = try XCTUnwrap(
      view.markdownCodeBlockFrameForTesting(fromLine: 0, toLine: 0, visibleRows: 0..<1))

    XCTAssertEqual(frame.minX, baseX, accuracy: 0.5)
    XCTAssertEqual(
      view.markdownTextColumnXForTesting(line: 0),
      baseX + MarkdownDocumentMetrics.codeCardInset,
      accuracy: 0.5)
  }

  @MainActor
  func testMarkdownCodeCardSlimsCloserAndBreathesAtBlockEdges() throws {
    // A leading paragraph keeps the fence off the document top, so the block
    // air above the opener is exercised (the doc-top line suppresses it).
    let view = try makeViewer("Intro\n```swift\nlet value = 1\n```\nAfter")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let body = view.layout.lineHeight
    let air = MarkdownDocumentMetrics.codeBlockAir
    let slim = MarkdownDocumentMetrics.slimMarkerRowHeight
    let header = LineRenderingTextView.codeLabelRowHeight

    // The opener is a header band (label + copy control) plus the block air.
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 2))
        - (try XCTUnwrap(view.endpointYForTesting(line: 1))),
      air + header,
      accuracy: 0.5)
    // Interior body row stays the uniform height — code is already open.
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 3))
        - (try XCTUnwrap(view.endpointYForTesting(line: 2))),
      body,
      accuracy: 0.5)
    // Closer is a slim row carrying the block air below it.
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 4))
        - (try XCTUnwrap(view.endpointYForTesting(line: 3))),
      slim + air,
      accuracy: 0.5)
  }

  @MainActor
  func testMarkdownBareFenceOpenerIsSlimWithNoReservedLabelSpace() throws {
    let view = try makeViewer("Intro\n```\ncode line\n```\nAfter")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    // Without a language label there is no reserved header band — the opener
    // collapses to a slim row (plus the block air), so a language-less block
    // has no empty space at its top. The copy control floats over the corner.
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 2))
        - (try XCTUnwrap(view.endpointYForTesting(line: 1))),
      MarkdownDocumentMetrics.slimMarkerRowHeight + MarkdownDocumentMetrics.codeBlockAir,
      accuracy: 0.5)
    // ...but it still gets a copy control.
    XCTAssertEqual(view.markdownCodeCopyTargets(inLineRange: 0..<5).map(\.startLine), [1])
  }

  @MainActor
  func testMarkdownCodeCardFrameExcludesBlockAir() throws {
    let view = try makeViewer("Intro\n```swift\nlet value = 1\n```")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let frame = try XCTUnwrap(
      view.markdownCodeBlockFrameForTesting(fromLine: 1, toLine: 3, visibleRows: 0..<4))
    // The card begins below the leading air (the air sits outside the fill).
    XCTAssertEqual(
      frame.minY,
      try XCTUnwrap(view.endpointYForTesting(line: 1)) + MarkdownDocumentMetrics.codeBlockAir,
      accuracy: 0.5)
    // ...and ends at the closer's slim row, before the trailing air.
    XCTAssertEqual(
      frame.maxY,
      try XCTUnwrap(view.endpointYForTesting(line: 3))
        + MarkdownDocumentMetrics.slimMarkerRowHeight,
      accuracy: 0.5)
    XCTAssertEqual(frame.minX, view.markdownTextColumnXForTesting(), accuracy: 0.5)
  }

  @MainActor
  func testMarkdownFrontMatterUsesMetadataCardMetrics() throws {
    let view = try makeViewer("---\nname: pdf\nallowed-tools: [Read, Write, Bash]\n---\n# Body")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let frame = try XCTUnwrap(
      view.markdownFrontMatterFrameForTesting(fromLine: 0, toLine: 3, visibleRows: 0..<5))

    XCTAssertEqual(frame.minY, try XCTUnwrap(view.endpointYForTesting(line: 0)), accuracy: 0.5)
    XCTAssertEqual(frame.minX, view.markdownTextColumnXForTesting(), accuracy: 0.5)
    let line0Y = try XCTUnwrap(view.endpointYForTesting(line: 0))
    let line1Y = try XCTUnwrap(view.endpointYForTesting(line: 1))
    let line2Y = try XCTUnwrap(view.endpointYForTesting(line: 2))
    XCTAssertEqual(
      line1Y - line0Y,
      MarkdownDocumentMetrics.frontMatterVerticalPadding,
      accuracy: 0.5)
    XCTAssertEqual(
      line2Y - line1Y,
      MarkdownDocumentMetrics.frontMatterRowHeight,
      accuracy: 0.5)
  }

  @MainActor
  func testMarkdownFrontMatterSequenceRowsCollapseIntoCollectedChipRow() throws {
    let view = try makeViewer(
      "---\ntitle: Markdown Syntax Coverage\nreviewers:\n  - dario\n  - altman\n  - musk\ntags:\n  - markdown\n  - rendering\n---\n# Body"
    )
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let reviewersY = try XCTUnwrap(view.endpointYForTesting(line: 2))
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 3)),
      reviewersY + MarkdownDocumentMetrics.frontMatterRowHeight,
      accuracy: 0.5)
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 4)),
      reviewersY + MarkdownDocumentMetrics.frontMatterRowHeight,
      accuracy: 0.5)
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 5)),
      reviewersY + MarkdownDocumentMetrics.frontMatterRowHeight,
      accuracy: 0.5)
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 6)),
      reviewersY + MarkdownDocumentMetrics.frontMatterRowHeight,
      accuracy: 0.5)
  }

  @MainActor
  func testEditingCollectedFrontMatterChipDoesNotInsertIntoKeyLine() throws {
    let contents = "---\nreviewers:\n  - dario\n---"
    let view = try makeEditableViewer(contents)
    view.syntax = .markdown
    view.updateLayout()

    let firstChipColumn =
      ("reviewers" as NSString).length + MarkdownDocumentMetrics.frontMatterKeyValueSeparatorLength
    view.setSelectionForTesting(
      anchor: .init(line: 1, columnUTF16: firstChipColumn),
      head: .init(line: 1, columnUTF16: firstChipColumn))
    view.insertText("X")

    XCTAssertEqual(content(of: view), contents)
  }

  @MainActor
  func testMarkdownDocumentTopCodeCardSitsAtPageTop() throws {
    let view = try makeViewer("```swift\nlet value = 1\n```")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let frame = try XCTUnwrap(
      view.markdownCodeBlockFrameForTesting(fromLine: 0, toLine: 2, visibleRows: 0..<3))
    // No extra air above a document-top code block — it sits at the page top,
    // matching the heading document-top convention.
    XCTAssertEqual(frame.minY, try XCTUnwrap(view.endpointYForTesting(line: 0)), accuracy: 0.5)
  }

  @MainActor
  func testMarkdownFencedBlockHasCopyControlPinnedTopRight() throws {
    let view = try makeViewer("```swift\nlet x = 1\nprint(x)\n```")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let targets = view.markdownCodeCopyTargets(inLineRange: 0..<4)
    XCTAssertEqual(targets.count, 1)
    let target = try XCTUnwrap(targets.first)
    XCTAssertEqual(target.startLine, 0)
    // Copies the body (the lines between the fences), verbatim, not the markers.
    XCTAssertEqual(target.contentRange, 1..<3)
    XCTAssertEqual(
      view.markdownCopyableCodeText(contentRange: target.contentRange), "let x = 1\nprint(x)")
    // Pinned to the card's top-right corner.
    let cardRight =
      view.markdownTextColumnXForTesting() + view.markdownOuterContentWidthForTesting(line: 0)
    XCTAssertEqual(
      target.buttonRect.maxX, cardRight - MarkdownDocumentMetrics.codeCopyButtonInset, accuracy: 0.5
    )
    XCTAssertEqual(target.buttonRect.width, MarkdownDocumentMetrics.codeCopyButtonWidth)
    // Dropped a small inset below the card top (which is y = 0 at the document top).
    XCTAssertEqual(
      target.buttonRect.minY, MarkdownDocumentMetrics.codeCopyButtonTopInset, accuracy: 0.5)
  }

  @MainActor
  func testAdjacentFencedBlocksEachGetCopyControlAndHeaderBand() throws {
    // Two fenced blocks back-to-back with no separating blank line.
    let view = try makeViewer("```swift\nlet a = 1\n```\n```python\nb = 2\n```")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let targets = view.markdownCodeCopyTargets(inLineRange: 0..<6)
    XCTAssertEqual(targets.map(\.startLine), [0, 3])
    XCTAssertEqual(targets.last?.contentRange, 4..<5)
    XCTAssertEqual(view.markdownCopyableCodeText(contentRange: 4..<5), "b = 2")
    // The second opener (line 3) is a header band, not a slim closer row.
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 4))
        - (try XCTUnwrap(view.endpointYForTesting(line: 3))),
      LineRenderingTextView.codeLabelRowHeight,
      accuracy: 0.5)
  }

  @MainActor
  func testFenceImmediatelyAfterFrontmatterGetsCopyControl() throws {
    let view = try makeViewer("---\ntitle: Hi\n---\n```swift\nlet a = 1\n```")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let targets = view.markdownCodeCopyTargets(inLineRange: 0..<6)
    XCTAssertEqual(targets.map(\.startLine), [3])
    XCTAssertEqual(targets.first?.contentRange, 4..<5)
  }

  @MainActor
  func testCaretClickInClosingFenceBandSnapsToLastCodeLineEnd() throws {
    let view = try makeEditableViewer("```swift\nlet x = 1\n```\nafter")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    // A click just below the last visible code line (the closer's upper half)
    // snaps to the end of the last code line, not onto the concealed row. The
    // closer has no leading air, so its slim row starts at its y offset.
    let closerY = try XCTUnwrap(view.endpointYForTesting(line: 2))
    let point = NSPoint(x: 200, y: closerY + 1)
    XCTAssertEqual(view.caretEndpoint(at: point), .init(line: 1, columnUTF16: 9))
    // The raw resolver still lands on the delimiter so a drag can span it.
    XCTAssertEqual(view.endpoint(at: point).line, 2)
    XCTAssertTrue(view.isConcealedDelimiterLine(2))
  }

  @MainActor
  func testCaretClickInBareOpenerBandSnapsToFirstCodeLineStart() throws {
    let view = try makeEditableViewer("intro\n```\nlet x = 1\n```")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    // The bare opener (line 1) is concealed; a click just above the first code
    // line (the lower half of the opener's slim row, which sits just below its
    // leading air) snaps to the start of the first code line.
    XCTAssertTrue(view.isConcealedDelimiterLine(1))
    let firstCodeY = try XCTUnwrap(view.endpointYForTesting(line: 2))
    XCTAssertEqual(
      view.caretEndpoint(at: NSPoint(x: 200, y: firstCodeY - 1)), .init(line: 2, columnUTF16: 0))
  }

  @MainActor
  func testHorizontalArrowsSkipConcealedFenceRows() throws {
    let view = try makeEditableViewer("```swift\nlet x = 1\n```\nafter")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    // Right from the end of the last code line skips the concealed closer and
    // lands at the start of the next editable line — never on the phantom row.
    view.beginCaretSelection(at: .init(line: 1, columnUTF16: 9))
    view.moveHorizontally(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 3, columnUTF16: 0))
    // Left from there steps back over the closer to the code line's end.
    view.moveHorizontally(forward: false, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 1, columnUTF16: 9))
  }

  @MainActor
  func testRightArrowStaysPutAtClosingFenceEndOfDocument() throws {
    let view = try makeEditableViewer("```swift\nlet x = 1\n```")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    // The closing fence is the last line; Right at the code-line end must not
    // park on it (no editable line follows) — the caret stays at the code end.
    view.beginCaretSelection(at: .init(line: 1, columnUTF16: 9))
    view.moveHorizontally(forward: true, extend: false)
    XCTAssertEqual(view.selection?.head, .init(line: 1, columnUTF16: 9))
  }

  @MainActor
  func testCaretClickOnLabeledOpenerStaysEditable() throws {
    let view = try makeEditableViewer("```swift\nlet x = 1\n```")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    // The labeled opener renders its language word and remains editable text.
    XCTAssertFalse(view.isConcealedDelimiterLine(0))
    let labelY = try XCTUnwrap(view.endpointYForTesting(line: 0))
    XCTAssertEqual(view.caretEndpoint(at: NSPoint(x: 80, y: labelY + 2)).line, 0)
  }

  @MainActor
  func testCaretClickOnGenuineBlankLineIsNotSkipped() throws {
    let view = try makeEditableViewer("a\n\nb")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    XCTAssertFalse(view.isConcealedDelimiterLine(1))
    let blankY = try XCTUnwrap(view.endpointYForTesting(line: 1))
    XCTAssertEqual(
      view.caretEndpoint(at: NSPoint(x: 200, y: blankY + 2)), .init(line: 1, columnUTF16: 0))
  }

  @MainActor
  func testArrowDownAndUpSkipConcealedFenceRows() throws {
    let view = try makeEditableViewer("```swift\nlet x = 1\n```\nafter")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    // Down from the last code line skips the concealed closer and lands on the
    // next editable line.
    view.beginCaretSelection(at: .init(line: 1, columnUTF16: 0))
    view.moveVertically(down: true, extend: false)
    XCTAssertEqual(view.selection?.head.line, 3)
    // Up from there skips back over the closer to the code line.
    view.moveVertically(down: false, extend: false)
    XCTAssertEqual(view.selection?.head.line, 1)
  }

  @MainActor
  func testMarkdownFrontmatterDelimitersBecomeMetadataCardPaddingRows() throws {
    let view = try makeViewer("---\ntitle: Hi\nstatus: x\n---\nBody")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let verticalPadding = MarkdownDocumentMetrics.frontMatterVerticalPadding
    let rowHeight = MarkdownDocumentMetrics.frontMatterRowHeight
    let air = MarkdownDocumentMetrics.codeBlockAir

    // Opening `---` becomes the top padding of the metadata card, not a visible
    // marker row.
    XCTAssertEqual(try XCTUnwrap(view.endpointYForTesting(line: 1)), verticalPadding, accuracy: 0.5)
    // Metadata rows use the card's own relaxed row height.
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 2))
        - (try XCTUnwrap(view.endpointYForTesting(line: 1))),
      rowHeight,
      accuracy: 0.5)
    // Closing `---` becomes the bottom padding and carries the block air below it.
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 4))
        - (try XCTUnwrap(view.endpointYForTesting(line: 3))),
      verticalPadding + air,
      accuracy: 0.5)
  }

  @MainActor
  func testMarkdownIndentedCodeHasNoCopyControl() throws {
    let view = try makeViewer("    indented code")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    XCTAssertTrue(view.markdownCodeCopyTargets(inLineRange: 0..<1).isEmpty)
  }

  @MainActor
  func testMarkdownTableChromeStaysInsideTextColumn() throws {
    let view = try makeViewer(
      """
      | Metric | Delta |
      | :--- | ---: |
      | Revenue | 1200 |
      """)
    view.setFrameSize(NSSize(width: 560, height: 300))
    view.syntax = .markdown
    view.updateLayout()

    let baseX = view.markdownTextColumnXForTesting()
    let frame = try XCTUnwrap(
      view.markdownTableFrameForTesting(fromLine: 0, toLine: 2, visibleRows: 0..<3))

    XCTAssertEqual(frame.minX, baseX, accuracy: 0.5)
    XCTAssertGreaterThan(frame.width, 120)
    XCTAssertLessThanOrEqual(frame.maxX, baseX + view.markdownWrapContentWidthForTesting() + 0.5)
    XCTAssertEqual(
      view.markdownTextColumnXForTesting(line: 0),
      baseX + MarkdownDocumentMetrics.tableEdgeInset,
      accuracy: 0.5)
  }

  @MainActor
  func testMarkdownTableDrawsExactlyThreeRules() throws {
    let view = try makeViewer(
      """
      | Metric | Delta |
      | :--- | ---: |
      | Revenue | 1200 |
      | Costs | 800 |
      """)
    view.setFrameSize(NSSize(width: 560, height: 300))
    view.syntax = .markdown
    view.updateLayout()

    let rules = try XCTUnwrap(
      view.markdownTableRuleYsForTesting(fromLine: 0, toLine: 3, visibleRows: 0..<4))
    let rowHeight = view.layout.lineHeight

    let separatorHeight = MarkdownDocumentMetrics.slimMarkerRowHeight
    XCTAssertEqual(rules.count, 3)
    XCTAssertEqual(rules[0], 0, accuracy: 0.5)
    XCTAssertEqual(rules[1], rowHeight + separatorHeight / 2, accuracy: 0.5)
    XCTAssertEqual(rules[2], rowHeight * 3 + separatorHeight, accuracy: 0.5)
  }

  @MainActor
  func testMarkdownTableRulesBreatheIntoAdjacentBlankLines() throws {
    let view = try makeViewer(
      """

      | Metric | Delta |
      | :--- | ---: |
      | Revenue | 1200 |

      """)
    view.setFrameSize(NSSize(width: 560, height: 300))
    view.syntax = .markdown
    view.updateLayout()

    let rules = try XCTUnwrap(
      view.markdownTableRuleYsForTesting(fromLine: 1, toLine: 3, visibleRows: 0..<5))
    let rowHeight = view.layout.lineHeight
    let breath = MarkdownDocumentMetrics.tableRuleBreath

    let separatorHeight = MarkdownDocumentMetrics.slimMarkerRowHeight
    XCTAssertEqual(rules.count, 3)
    XCTAssertEqual(rules[0], rowHeight - breath, accuracy: 0.5)
    XCTAssertEqual(rules[1], rowHeight * 2 + separatorHeight / 2, accuracy: 0.5)
    XCTAssertEqual(rules[2], rowHeight * 3 + separatorHeight + breath, accuracy: 0.5)
  }

  @MainActor
  func testMarkdownTableSeparatorRowIsSlim() throws {
    let view = try makeViewer(
      """
      | Metric | Delta |
      | :--- | ---: |
      | Revenue | 1200 |
      """)
    view.setFrameSize(NSSize(width: 560, height: 300))
    view.syntax = .markdown
    view.updateLayout()

    let rowHeight = view.layout.lineHeight
    let separatorHeight = MarkdownDocumentMetrics.slimMarkerRowHeight
    // The body row starts one full header row plus one slim separator row down.
    let body = try XCTUnwrap(view.endpointYForTesting(line: 2))
    XCTAssertEqual(body, rowHeight + separatorHeight, accuracy: 0.5)
    // Hit-testing inside the body row's vertical span resolves to line 2.
    XCTAssertEqual(
      view.endpoint(at: NSPoint(x: 200, y: rowHeight + separatorHeight + rowHeight / 2)).line,
      2)
  }

  func testWrapIndexUniformDocumentsKeepRowTimesHeightGeometry() {
    let index = WrapIndex(
      visualRowsPerLine: [1, 2, 1],
      rowMetricsPerLine: [LineRowMetrics](repeating: LineRowMetrics(rowHeight: 24), count: 3),
      uniformRowHeight: 24)

    XCTAssertFalse(index.hasCustomRowHeights)
    for row in 0..<4 {
      XCTAssertEqual(
        index.yOffset(ofVisualRow: row, uniformRowHeight: 24), CGFloat(row) * 24, accuracy: 0.01)
    }
    XCTAssertEqual(index.totalHeight(uniformRowHeight: 24), 96, accuracy: 0.01)
  }

  func testWrapIndexCustomRowHeightsProduceCumulativeYGeometry() {
    // header (24), slim separator (6), wrapped body line (2 rows × 24), body (24).
    let index = WrapIndex(
      visualRowsPerLine: [1, 1, 2, 1],
      rowMetricsPerLine: [
        LineRowMetrics(rowHeight: 24),
        LineRowMetrics(rowHeight: 6),
        LineRowMetrics(rowHeight: 24),
        LineRowMetrics(rowHeight: 24),
      ],
      uniformRowHeight: 24)

    XCTAssertTrue(index.hasCustomRowHeights)
    XCTAssertEqual(index.yOffset(ofLine: 1, uniformRowHeight: 24), 24, accuracy: 0.01)
    XCTAssertEqual(index.yOffset(ofLine: 2, uniformRowHeight: 24), 30, accuracy: 0.01)
    XCTAssertEqual(index.yOffset(ofLine: 3, uniformRowHeight: 24), 78, accuracy: 0.01)
    XCTAssertEqual(index.yOffset(ofVisualRow: 3, uniformRowHeight: 24), 54, accuracy: 0.01)
    XCTAssertEqual(index.totalHeight(uniformRowHeight: 24), 102, accuracy: 0.01)
    XCTAssertEqual(index.rowHeight(ofLine: 1, uniformRowHeight: 24), 6, accuracy: 0.01)

    XCTAssertEqual(index.location(forY: 25, uniformRowHeight: 24).line, 1)
    XCTAssertEqual(index.location(forY: 31, uniformRowHeight: 24).line, 2)
    let secondRow = index.location(forY: 55, uniformRowHeight: 24)
    XCTAssertEqual(secondRow.line, 2)
    XCTAssertEqual(secondRow.rowInLine, 1)
    XCTAssertEqual(index.location(forY: 90, uniformRowHeight: 24).line, 3)
  }

  func testWrapIndexLeadingAndTrailingInsetsShapeLineBlocks() {
    // heading: 34pt glyph row with 22pt above / 6pt below, wrapping to 2 rows.
    let index = WrapIndex(
      visualRowsPerLine: [2, 1],
      rowMetricsPerLine: [
        LineRowMetrics(rowHeight: 34, leadingInset: 22, trailingInset: 6),
        LineRowMetrics(rowHeight: 24),
      ],
      uniformRowHeight: 24)

    // Line block: 22 + 2×34 + 6 = 96; body starts after it.
    XCTAssertEqual(index.yOffset(ofLine: 1, uniformRowHeight: 24), 96, accuracy: 0.01)
    XCTAssertEqual(index.totalHeight(uniformRowHeight: 24), 120, accuracy: 0.01)
    // Visual rows sit below the leading inset.
    XCTAssertEqual(index.yOffset(ofVisualRow: 0, uniformRowHeight: 24), 22, accuracy: 0.01)
    XCTAssertEqual(index.yOffset(ofVisualRow: 1, uniformRowHeight: 24), 56, accuracy: 0.01)
    // Clicks in the padding strips resolve to the heading, never a dead zone.
    XCTAssertEqual(index.location(forY: 10, uniformRowHeight: 24).line, 0)
    XCTAssertEqual(index.location(forY: 10, uniformRowHeight: 24).rowInLine, 0)
    let trailing = index.location(forY: 93, uniformRowHeight: 24)
    XCTAssertEqual(trailing.line, 0)
    XCTAssertEqual(trailing.rowInLine, 1)
  }

  @MainActor
  func testMarkdownHeadingRowsGainSectionalAirAndSetextUnderlineIsSlim() throws {
    let view = try makeViewer(
      """
      # Title

      ## Section

      Setext
      ===
      Body
      """)
    view.setFrameSize(NSSize(width: 560, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let body = view.layout.lineHeight
    let h1 = LineRenderingTextView.headingLineMetrics(level: 1, isDocumentTop: true)
    let h2 = LineRenderingTextView.headingLineMetrics(level: 2, isDocumentTop: false)
    let setextH1 = LineRenderingTextView.headingLineMetrics(level: 1, isDocumentTop: false)
    let slim = MarkdownDocumentMetrics.slimMarkerRowHeight

    // Line 0 is the document title: suppressed leading inset.
    let titleBlock = h1.totalHeight(rows: 1)
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 1)), titleBlock, accuracy: 0.5)
    // Mid-document H2 carries its full sectional air.
    let sectionTop = titleBlock + body
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 3)),
      sectionTop + h2.totalHeight(rows: 1),
      accuracy: 0.5)
    // The setext text line renders as an H1 block; its underline row is slim.
    let setextTop = sectionTop + h2.totalHeight(rows: 1) + body
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 5)),
      setextTop + setextH1.totalHeight(rows: 1),
      accuracy: 0.5)
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 6)),
      setextTop + setextH1.totalHeight(rows: 1) + slim,
      accuracy: 0.5)
    // A click inside the H2's leading air lands on the H2 line.
    XCTAssertEqual(view.endpoint(at: NSPoint(x: 100, y: sectionTop + 4)).line, 2)
  }

  func testMarkdownImageDisplaySizeFitsWidthAndCapsHeight() {
    XCTAssertEqual(
      LineRenderingTextView.markdownImageDisplaySize(
        natural: CGSize(width: 200, height: 100), contentWidth: 600),
      CGSize(width: 200, height: 100))
    XCTAssertEqual(
      LineRenderingTextView.markdownImageDisplaySize(
        natural: CGSize(width: 1200, height: 600), contentWidth: 600),
      CGSize(width: 600, height: 300))
    let tall = LineRenderingTextView.markdownImageDisplaySize(
      natural: CGSize(width: 1000, height: 4000), contentWidth: 600)
    XCTAssertEqual(tall.height, MarkdownDocumentMetrics.imageMaximumBlockHeight)
    XCTAssertEqual(
      tall.width, ceil(MarkdownDocumentMetrics.imageMaximumBlockHeight * 1000 / 4000))
  }

  func testMarkdownImageFailureCardWidthStaysCompactAndWithinContentColumn() {
    XCTAssertEqual(LineRenderingTextView.markdownImageFailureCardWidth(contentWidth: 0), 0)
    XCTAssertEqual(LineRenderingTextView.markdownImageFailureCardWidth(contentWidth: 240), 240)
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureCardWidth(contentWidth: 600),
      MarkdownDocumentMetrics.imageFailureCardMaximumWidth)
  }

  func testMarkdownImageFailureDetailPrefersHumanAltText() {
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureDetailLabel(
        for: MarkdownImageSource(
          source: "https://cdn.example.com/chart.png?token=abc",
          altText: "Quarterly sales chart")),
      "Quarterly sales chart")
  }

  func testMarkdownImageFailureDetailFallsBackToReadableSourceLabel() {
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureDetailLabel(
        for: MarkdownImageSource(source: "https://cdn.example.com/", altText: "")),
      "cdn.example.com")
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureDetailLabel(
        for: MarkdownImageSource(source: "https://h.com/?v=1", altText: "")),
      "h.com")
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureDetailLabel(
        for: MarkdownImageSource(source: "https://h.com/a.png?v=2#x", altText: "")),
      "a.png")
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureDetailLabel(
        for: MarkdownImageSource(source: #"C:\images\chart.png"#, altText: "")),
      "chart.png")
  }

  func testMarkdownImageFailureDetailFallsBackToGenericLabelForUnhelpfulSources() {
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureDetailLabel(
        for: MarkdownImageSource(source: "data:image/png;base64,iVBORw0KGgo=", altText: "")),
      "Image")
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureDetailLabel(
        for: MarkdownImageSource(source: "///", altText: "")),
      "Image")
    XCTAssertEqual(
      LineRenderingTextView.markdownImageFailureDetailLabel(
        for: MarkdownImageSource(source: "", altText: "   ")),
      "Image")
  }

  @MainActor
  func testMarkdownImageLineUsesPlaceholderThenFailureMetrics() async throws {
    let folder = try makeTemporaryImageFolder()
    let view = try makeViewer("![Missing](missing.png)\nBody")
    view.saveURL = folder.appendingPathComponent("doc.md")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    let captionRow = LineRenderingTextView.markdownImageCaptionRowHeight
    let chrome =
      MarkdownDocumentMetrics.imageBlockAir * 2 + MarkdownDocumentMetrics.imageCaptionGap
      + captionRow
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 1)),
      chrome + MarkdownDocumentMetrics.imagePlaceholderHeight,
      accuracy: 0.5)

    await view.settleMarkdownImageLoadsForTesting()

    let failureFrame = try XCTUnwrap(view.markdownImageBlockFrame(line: 0))
    XCTAssertEqual(
      failureFrame.width,
      MarkdownDocumentMetrics.imageFailureCardMaximumWidth,
      accuracy: 0.5)
    XCTAssertEqual(
      failureFrame.height,
      MarkdownDocumentMetrics.imageFailureHeight,
      accuracy: 0.5)
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 1)),
      chrome + MarkdownDocumentMetrics.imageFailureHeight,
      accuracy: 0.5)
  }

  @MainActor
  func testMarkdownImageBlockSizesToImageAndKeepsCaptionRow() async throws {
    let folder = try makeTemporaryImageFolder()
    try writePNG(width: 64, height: 32, to: folder.appendingPathComponent("chart.png"))
    let view = try makeViewer("![Chart](chart.png)\nBody")
    view.saveURL = folder.appendingPathComponent("doc.md")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    await view.settleMarkdownImageLoadsForTesting()

    let frame = try XCTUnwrap(view.markdownImageBlockFrame(line: 0))
    XCTAssertEqual(frame.minX, view.markdownTextColumnXForTesting(line: 0), accuracy: 0.5)
    XCTAssertEqual(frame.minY, MarkdownDocumentMetrics.imageBlockAir, accuracy: 0.5)
    XCTAssertEqual(frame.size, CGSize(width: 64, height: 32))
    let captionRow = LineRenderingTextView.markdownImageCaptionRowHeight
    XCTAssertEqual(
      try XCTUnwrap(view.endpointYForTesting(line: 1)),
      MarkdownDocumentMetrics.imageBlockAir * 2 + 32
        + MarkdownDocumentMetrics.imageCaptionGap + captionRow,
      accuracy: 0.5)
    // A click inside the image strip lands on the image line (its caption).
    XCTAssertEqual(view.endpoint(at: NSPoint(x: 100, y: frame.midY)).line, 0)
  }

  @MainActor
  func testMarkdownImageRelayoutKeepsFirstVisibleLineAnchored() async throws {
    let folder = try makeTemporaryImageFolder()
    let contents = (["![Missing](missing.png)"] + (0..<60).map { "Body line \($0)" })
      .joined(separator: "\n")
    let view = try makeViewer(contents)
    view.saveURL = folder.appendingPathComponent("doc.md")
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
    scrollView.documentView = view
    view.syntax = .markdown
    view.updateLayout()

    let anchorLine = 30
    let initialY = try XCTUnwrap(view.endpointYForTesting(line: anchorLine))
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: initialY))
    scrollView.reflectScrolledClipView(scrollView.contentView)

    // The probe fails: the block shrinks from the placeholder to the failure
    // card, and the anchored line must keep its viewport position.
    await view.settleMarkdownImageLoadsForTesting()

    let settledY = try XCTUnwrap(view.endpointYForTesting(line: anchorLine))
    XCTAssertNotEqual(settledY, initialY, accuracy: 0.5)
    XCTAssertEqual(scrollView.documentVisibleRect.minY, settledY, accuracy: 1.0)
  }

  @MainActor
  func testMarkdownImageFrameIsNilForPlainLines() throws {
    let view = try makeViewer("Body text")
    view.setFrameSize(NSSize(width: 520, height: 400))
    view.syntax = .markdown
    view.updateLayout()

    XCTAssertNil(view.markdownImageBlockFrame(line: 0))
  }

  private func makeTemporaryImageFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("TextViewportImageTests-\(UUID().uuidString)", isDirectory: true)
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

  func testRowVerticalInsetCentersShortFragments() {
    XCTAssertEqual(
      LineRenderingTextView.rowVerticalInset(rowHeight: 24, naturalHeight: 18), 3, accuracy: 0.01)
    XCTAssertEqual(
      LineRenderingTextView.rowVerticalInset(rowHeight: 24, naturalHeight: 24), 0, accuracy: 0.01)
    XCTAssertEqual(
      LineRenderingTextView.rowVerticalInset(rowHeight: 24, naturalHeight: 30), 0, accuracy: 0.01)
  }

  @MainActor
  func testMarkdownCopyUsesRawMarkdownForRoundTripEditing() throws {
    let view = try makeViewer("# Title\n- [x] Done\nUse **bold** and `code`")
    view.syntax = .markdown

    view.selectAll(nil)

    XCTAssertEqual(view.selectedText(), "# Title\n- [x] Done\nUse **bold** and `code`")
  }

  @MainActor
  func testMarkdownSourceModeShowsRawMarkers() throws {
    let view = try makeViewer("# Title")
    view.syntax = .markdown

    XCTAssertEqual(view.attributedLineStringForTesting(line: 0), "Title")

    view.markdownViewMode = .source

    XCTAssertEqual(view.attributedLineStringForTesting(line: 0), "# Title")
    XCTAssertEqual(view.layout.lineHeight, TextDocumentSyntax.plainText.lineHeight)
  }

  @MainActor
  func testMarkdownViewModeTogglePreservesCaretRawOffset() throws {
    let view = try makeEditableViewer("# Title")
    view.syntax = .markdown
    view.beginCaretSelection(at: .init(line: 0, columnUTF16: 2))

    view.markdownViewMode = .source

    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 4))

    view.markdownViewMode = .rendered

    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
  }

  @MainActor
  func testMarkdownViewModeToggleClampsSourceLineEndToRenderedLineEnd() throws {
    let view = try makeEditableViewer("# Title")
    view.syntax = .markdown
    view.markdownViewMode = .source
    view.beginCaretSelection(at: .init(line: 0, columnUTF16: 7))

    view.markdownViewMode = .rendered

    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 5))
  }

  func testMarkdownViewModeToggleCursorRectTracksVisibleTopTrailingCorner() {
    let visible = NSRect(x: 120, y: 340, width: 640, height: 480)

    let rect = LineRenderingTextView.markdownViewModeToggleCursorRectForTesting(in: visible)

    XCTAssertEqual(
      rect.minX,
      visible.maxX - MarkdownViewModeToggleMetrics.trailingPadding
        - MarkdownViewModeToggleMetrics.size,
      accuracy: 0.5)
    XCTAssertEqual(
      rect.minY,
      visible.minY + MarkdownViewModeToggleMetrics.topPadding,
      accuracy: 0.5)
    XCTAssertEqual(rect.width, MarkdownViewModeToggleMetrics.size, accuracy: 0.5)
    XCTAssertEqual(rect.height, MarkdownViewModeToggleMetrics.size, accuracy: 0.5)
  }

  @MainActor
  func testMarkdownCopyWholeRenderedBoldLineIncludesRawMarkers() throws {
    let view = try makeViewer("**bold**")
    view.syntax = .markdown

    view.selectAll(nil)

    XCTAssertEqual(view.selectedText(), "**bold**")
  }

  @MainActor
  func testMarkdownCopyPartialRenderedBoldSpanCopiesVisibleCharacters() throws {
    let view = try makeViewer("Use **bold** text")
    view.syntax = .markdown
    view.beginCaretSelection(at: .init(line: 0, columnUTF16: 4))
    view.extendSelection(to: .init(line: 0, columnUTF16: 8))

    XCTAssertEqual(view.selectedText(), "bold")
  }

  @MainActor
  func testMarkdownTypingAtRenderedHeadingStartInsertsAfterHiddenMarker() throws {
    let view = try makeEditableViewer("# Title")
    view.syntax = .markdown

    view.moveToDocumentEdge(end: false, extend: false)
    view.insertText("Draft ")

    XCTAssertEqual(content(of: view), "# Draft Title")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 6))
  }

  @MainActor
  func testMarkdownBackspaceAtRenderedHeadingEndDeletesVisibleCharacter() throws {
    let view = try makeEditableViewer("# Title")
    view.syntax = .markdown

    view.moveToLineEdge(end: true, extend: false)
    view.deleteBackward()

    XCTAssertEqual(content(of: view), "# Titl")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 4))
  }

  @MainActor
  func testMarkdownTypingInsideRenderedBoldSpanPreservesMarkers() throws {
    let view = try makeEditableViewer("Use **bold** text")
    view.syntax = .markdown

    view.moveToDocumentEdge(end: false, extend: false)
    for _ in 0..<8 {
      view.moveHorizontally(forward: true, extend: false)
    }
    view.insertText("er")

    XCTAssertEqual(content(of: view), "Use **bolder** text")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 10))
  }

  @MainActor
  func testMarkdownDeleteBackwardAtRenderedHeadingStartPeelsHeadingMarker() throws {
    let view = try makeEditableViewer("# Title")
    view.syntax = .markdown

    view.moveToDocumentEdge(end: false, extend: false)
    view.deleteBackward()

    XCTAssertEqual(content(of: view), "Title")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 0))
  }

  @MainActor
  func testMarkdownDeleteBackwardAtRenderedTaskStartPeelsTaskToBullet() throws {
    let view = try makeEditableViewer("- [ ] Update")
    view.syntax = .markdown

    view.moveToDocumentEdge(end: false, extend: false)
    view.deleteBackward()

    XCTAssertEqual(content(of: view), "- Update")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 0))
  }

  @MainActor
  func testMarkdownEnterAtRenderedListEndContinuesRawListPrefix() throws {
    let view = try makeEditableViewer("- Item")
    view.syntax = .markdown

    view.moveToLineEdge(end: true, extend: false)
    view.doCommand(by: #selector(NSStandardKeyBindingResponding.insertNewline(_:)))

    XCTAssertEqual(content(of: view), "- Item\n- ")
    XCTAssertEqual(view.selection?.head, .init(line: 1, columnUTF16: 0))
  }

  @MainActor
  func testMarkdownBoldCommandWrapsRenderedSelectionWithRawMarkers() throws {
    let view = try makeEditableViewer("quarterly review")
    view.syntax = .markdown
    view.selectAll(nil)

    view.toggleMarkdownEmphasis(marker: "**")

    XCTAssertEqual(content(of: view), "**quarterly review**")
    XCTAssertEqual(view.selection?.start, .init(line: 0, columnUTF16: 0))
    XCTAssertEqual(view.selection?.end, .init(line: 0, columnUTF16: 16))
  }

  @MainActor
  func testMarkdownItalicInsideRenderedBoldAddsMarkersWithoutUnwrappingBold() throws {
    let view = try makeEditableViewer("Use **summary** now")
    view.syntax = .markdown
    view.beginCaretSelection(at: .init(line: 0, columnUTF16: 4))
    view.extendSelection(to: .init(line: 0, columnUTF16: 11))

    view.toggleMarkdownEmphasis(marker: "*")

    XCTAssertEqual(content(of: view), "Use ***summary*** now")
    XCTAssertEqual(view.selection?.start, .init(line: 0, columnUTF16: 4))
    XCTAssertEqual(view.selection?.end, .init(line: 0, columnUTF16: 11))
  }

  @MainActor
  func testDeleteForwardRemovesNextCharacter() throws {
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: false, extend: false)  // caret (0,0)
    view.deleteForward()
    XCTAssertEqual(content(of: view), "bc")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 0))
  }

  @MainActor
  func testDeleteBackwardWithSelectionDeletesSelection() throws {
    let view = try makeEditableViewer("hello")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: true)
    view.moveHorizontally(forward: true, extend: true)  // select "he"
    view.deleteBackward()
    XCTAssertEqual(content(of: view), "llo")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 0))
    XCTAssertTrue(view.selection?.isEmpty == true)
  }

  @MainActor
  func testDeleteBackwardAtDocumentStartIsNoOp() throws {
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: false, extend: false)  // caret (0,0)
    view.deleteBackward()
    XCTAssertEqual(content(of: view), "abc")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 0))
  }

  @MainActor
  func testInsertingEmojiAdvancesCaretPastWholePair() throws {
    // 😀 is a surrogate pair (two UTF-16 units); the caret must land after both.
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: false, extend: false)  // caret (0,0)
    view.insertText("😀")
    XCTAssertEqual(content(of: view), "😀ab")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
  }

  @MainActor
  func testDeleteBackwardRemovesWholeEmoji() throws {
    let view = try makeEditableViewer("a😀b")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,1) after "a"
    view.moveHorizontally(forward: true, extend: false)  // caret (0,3) after 😀
    view.deleteBackward()
    XCTAssertEqual(content(of: view), "ab")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))
  }

  // MARK: Text input (IME / composition)

  private static let noReplacement = NSRange(location: NSNotFound, length: 0)

  @MainActor
  func testMarkedTextShowsWithoutChangingBuffer() throws {
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,1)
    view.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    XCTAssertTrue(view.hasMarkedText())
    XCTAssertEqual(content(of: view), "ab")  // composing text is not in the buffer yet
    XCTAssertEqual(view.markedRange(), NSRange(location: 1, length: 1))
  }

  @MainActor
  func testCommittingComposedTextInsertsIntoBuffer() throws {
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,1)
    view.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    view.insertText("が", replacementRange: Self.noReplacement)  // commit
    XCTAssertFalse(view.hasMarkedText())
    XCTAssertEqual(content(of: view), "aがb")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
  }

  @MainActor
  func testUpdatingMarkedTextReplacesPreviousComposition() throws {
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,1)
    view.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    view.setMarkedText(
      "かん", selectedRange: NSRange(location: 2, length: 0), replacementRange: Self.noReplacement)
    XCTAssertEqual(content(of: view), "ab")  // still uncommitted
    XCTAssertEqual(view.markedRange(), NSRange(location: 1, length: 2))
  }

  @MainActor
  func testUnmarkTextCommitsMarkedText() throws {
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,1)
    view.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    view.unmarkText()
    XCTAssertFalse(view.hasMarkedText())
    XCTAssertEqual(content(of: view), "aかb")
  }

  @MainActor
  func testEmptyMarkedTextCancelsComposition() throws {
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,1)
    view.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    view.setMarkedText(
      "", selectedRange: NSRange(location: 0, length: 0), replacementRange: Self.noReplacement)
    XCTAssertFalse(view.hasMarkedText())
    XCTAssertEqual(content(of: view), "ab")
  }

  @MainActor
  func testComposingReplacesActiveSelection() throws {
    let view = try makeEditableViewer("hello")
    view.selectAll(nil)
    view.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    XCTAssertTrue(view.hasMarkedText())
    XCTAssertEqual(content(of: view), "")  // the selection is replaced by the composition
    view.unmarkText()
    XCTAssertEqual(content(of: view), "か")
  }

  @MainActor
  func testReadOnlyViewerIgnoresComposition() throws {
    let view = try makeViewer("ab")  // read-only
    view.setMarkedText(
      "か", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    XCTAssertFalse(view.hasMarkedText())
    view.insertText("が", replacementRange: Self.noReplacement)
    XCTAssertEqual(content(of: view), "ab")
  }

  @MainActor
  func testSelectedRangeReflectsCompositionCursor() throws {
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: false)  // caret (0,1)
    view.setMarkedText(
      "かん", selectedRange: NSRange(location: 1, length: 0), replacementRange: Self.noReplacement)
    XCTAssertEqual(view.markedRange(), NSRange(location: 1, length: 2))
    XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 0))
  }

  @MainActor
  func testSelectedRangeWithoutCompositionReflectsSelection() throws {
    let view = try makeEditableViewer("hello")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: true)
    view.moveHorizontally(forward: true, extend: true)  // select "he"
    XCTAssertFalse(view.hasMarkedText())
    XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 2))
    XCTAssertEqual(view.markedRange().location, NSNotFound)
  }

  @MainActor
  func testFirstRectForCompositionUsesWrappedVisualRow() throws {
    let view = try makeEditableViewer(String(repeating: "word ", count: 60))
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)
    view.updateLayout()
    XCTAssertGreaterThan(view.visualRowCount, 1)

    view.moveToDocumentEdge(end: false, extend: false)
    for _ in 0..<30 {
      view.moveHorizontally(forward: true, extend: false)
    }
    view.setMarkedText(
      "あ", selectedRange: NSRange(location: 0, length: 0), replacementRange: Self.noReplacement)

    let viewRect = view.firstRectInViewCoordinates(forCharacterRange: view.markedRange())

    XCTAssertGreaterThanOrEqual(viewRect.origin.y, view.layout.lineHeight)
  }

  @MainActor
  func testDoCommandInsertNewlineInsertsLineBreak() throws {
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: true, extend: false)  // caret (0,2)
    view.doCommand(by: #selector(NSStandardKeyBindingResponding.insertNewline(_:)))
    XCTAssertEqual(content(of: view), "ab\n")
    XCTAssertEqual(view.editableBuffer?.lineCount, 2)
    XCTAssertEqual(view.selection?.head, .init(line: 1, columnUTF16: 0))
  }

  @MainActor
  func testDoCommandDeleteBackwardDeletes() throws {
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: true, extend: false)  // caret (0,3)
    view.doCommand(by: #selector(NSStandardKeyBindingResponding.deleteBackward(_:)))
    XCTAssertEqual(content(of: view), "ab")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
  }

  @MainActor
  func testDoCommandMoveRightNavigatesEvenWhenReadOnly() throws {
    let view = try makeViewer("ab")  // read-only: navigation still works
    view.moveToDocumentEdge(end: false, extend: false)
    view.doCommand(by: #selector(NSStandardKeyBindingResponding.moveRight(_:)))
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))
  }

  // MARK: Undo / redo / cut / paste

  @MainActor
  func testUndoRevertsInsertAndRedoReapplies() throws {
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: true, extend: false)  // caret (0,3)
    view.insertText("X")
    XCTAssertEqual(content(of: view), "abcX")
    view.undoEdit()
    XCTAssertEqual(content(of: view), "abc")
    view.redoEdit()
    XCTAssertEqual(content(of: view), "abcX")
  }

  @MainActor
  func testUndoRestoresDeletedText() throws {
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: true, extend: false)
    view.deleteBackward()  // "ab"
    XCTAssertEqual(content(of: view), "ab")
    view.undoEdit()
    XCTAssertEqual(content(of: view), "abc")
  }

  @MainActor
  func testUndoAndRedoAreIgnoredWhenReadOnly() throws {
    let view = try makeViewer("abc")  // read-only
    XCTAssertFalse(view.undoEdit())
    XCTAssertFalse(view.redoEdit())
    XCTAssertEqual(content(of: view), "abc")
  }

  @MainActor
  func testCutCopiesSelectionAndRemovesIt() throws {
    let view = try makeEditableViewer("hello")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveHorizontally(forward: true, extend: true)
    view.moveHorizontally(forward: true, extend: true)  // select "he"
    NSPasteboard.general.clearContents()
    view.cut(nil)
    XCTAssertEqual(content(of: view), "llo")
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "he")
  }

  @MainActor
  func testCutWithoutSelectionLeavesBufferAndPasteboardUntouched() throws {
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: true, extend: false)  // caret, no selection
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("KEEP", forType: .string)
    view.cut(nil)
    XCTAssertEqual(content(of: view), "abc")
    XCTAssertEqual(NSPasteboard.general.string(forType: .string), "KEEP")
  }

  @MainActor
  func testPasteInsertsClipboardTextAtCaret() throws {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("XY", forType: .string)
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: true, extend: false)  // caret (0,2)
    view.paste(nil)
    XCTAssertEqual(content(of: view), "abXY")
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 4))
  }

  @MainActor
  func testPasteReplacesSelection() throws {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("Z", forType: .string)
    let view = try makeEditableViewer("hello")
    view.selectAll(nil)
    view.paste(nil)
    XCTAssertEqual(content(of: view), "Z")
  }

  @MainActor
  func testPasteIsIgnoredWhenReadOnly() throws {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("XY", forType: .string)
    let view = try makeViewer("ab")  // read-only
    view.paste(nil)
    XCTAssertEqual(content(of: view), "ab")
  }

  @MainActor
  func testTypingOverSelectionIsASingleUndoStep() throws {
    // The atomic buffer replace records one undo entry, so a typed-over selection
    // is restored in a single undo (not two: delete then insert).
    let view = try makeEditableViewer("hello")
    view.selectAll(nil)
    view.insertText("Z")
    XCTAssertEqual(content(of: view), "Z")
    view.undoEdit()
    XCTAssertEqual(content(of: view), "hello")
  }

  @MainActor
  func testPasteOverSelectionIsASingleUndoStep() throws {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("XY", forType: .string)
    let view = try makeEditableViewer("hello")
    view.selectAll(nil)
    view.paste(nil)
    XCTAssertEqual(content(of: view), "XY")
    view.undoEdit()
    XCTAssertEqual(content(of: view), "hello")
  }

  @MainActor
  func testUndoAndRedoResponderMethodsDriveTheBuffer() throws {
    // The Edit-menu `undo:`/`redo:` selectors route to the same buffer stack.
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: true, extend: false)
    view.insertText("X")
    XCTAssertEqual(content(of: view), "abcX")
    view.undo(nil)
    XCTAssertEqual(content(of: view), "abc")
    view.redo(nil)
    XCTAssertEqual(content(of: view), "abcX")
  }

  @MainActor
  func testPasteRefusesOverBudgetClipboard() throws {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("abcdef", forType: .string)
    let view = try makeEditableViewer("")
    view.maximumPastedByteCount = 3
    view.paste(nil)
    XCTAssertEqual(content(of: view), "")  // refused: clipboard exceeds the budget
  }

  @MainActor
  func testCutMenuItemValidationTracksSelection() throws {
    let view = try makeEditableViewer("hello")
    let cutItem = NSMenuItem(
      title: "Cut", action: #selector(LineRenderingTextView.cut(_:)), keyEquivalent: "")
    XCTAssertFalse(view.validateUserInterfaceItem(cutItem))  // no selection
    view.selectAll(nil)
    XCTAssertTrue(view.validateUserInterfaceItem(cutItem))  // selection present
  }

  @MainActor
  func testPasteMenuItemValidationRequiresEditable() throws {
    let pasteItem = NSMenuItem(
      title: "Paste", action: #selector(LineRenderingTextView.paste(_:)), keyEquivalent: "")
    XCTAssertTrue(try makeEditableViewer("ab").validateUserInterfaceItem(pasteItem))
    XCTAssertFalse(try makeViewer("ab").validateUserInterfaceItem(pasteItem))  // read-only
  }

  // MARK: Dirty reporting (external-change conflict bridge)

  @MainActor
  func testEditingReportsDirtyThenCleanAfterUndo() throws {
    let view = try makeEditableViewer("abc")
    var reported: [Bool] = []
    view.onDirtyChange = { reported.append($0) }

    view.moveToDocumentEdge(end: true, extend: false)
    view.insertText("X")
    XCTAssertEqual(reported.last, true)  // an edit makes the buffer dirty

    view.undoEdit()
    XCTAssertEqual(reported.last, false)  // undo back to the opened state is clean
  }

  @MainActor
  func testBufferStaysEditableWhileSaving() throws {
    // The background save reads an immutable snapshot, not the live buffer, so a
    // save in flight no longer pauses editing.
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: true, extend: false)
    view.beginSaveForTesting()

    view.insertText("X")
    XCTAssertEqual(content(of: view), "abcX")  // edits apply during a save
    view.deleteBackward()
    XCTAssertEqual(content(of: view), "abc")
  }

  @MainActor
  func testBufferStaysEditableAfterSwappingAwayFromAndBackToASavingBuffer() throws {
    // The open-document-cache reuse path: a save starts, the view shows another
    // document, then returns to the original (same cached buffer). Editing is never
    // paused — the writer holds an immutable snapshot — so the buffer is editable
    // throughout, including after the swap-back.
    let view = try makeEditableViewer("abc")
    let savingBuffer = try XCTUnwrap(view.editableBuffer)
    view.beginSaveForTesting()  // a save is now in flight for `savingBuffer`

    let otherBuffer = try TextBuffer.open(bytes: Data("xyz".utf8))
    view.setBuffer(otherBuffer)  // swap away
    view.moveToDocumentEdge(end: true, extend: false)
    view.insertText("Z")
    XCTAssertEqual(content(of: view), "xyzZ")

    view.setBuffer(savingBuffer)  // swap back to the still-saving buffer
    view.moveToDocumentEdge(end: true, extend: false)
    view.insertText("Q")
    XCTAssertEqual(content(of: view), "abcQ")  // editable even while its save runs
  }

  // MARK: DocumentSaveTracker

  @MainActor
  func testSaveTrackerMarksAndClearsInFlightSaves() throws {
    let tracker = DocumentSaveTracker()
    let buffer = try TextBuffer.open(bytes: Data("abc".utf8))

    XCTAssertFalse(tracker.isSaving(buffer))
    XCTAssertTrue(tracker.begin(buffer))
    XCTAssertTrue(tracker.isSaving(buffer))
    XCTAssertFalse(tracker.begin(buffer))  // a second save is refused while one runs
    tracker.finish(buffer)
    XCTAssertFalse(tracker.isSaving(buffer))
  }

  @MainActor
  func testSaveTrackerKeepsBuffersIndependent() throws {
    let tracker = DocumentSaveTracker()
    let first = try TextBuffer.open(bytes: Data("one".utf8))
    let second = try TextBuffer.open(bytes: Data("two".utf8))

    XCTAssertTrue(tracker.begin(first))
    XCTAssertFalse(tracker.isSaving(second))  // tracked independently per buffer
    XCTAssertTrue(tracker.begin(second))
    XCTAssertTrue(tracker.isSaving(first))
    tracker.finish(first)
    XCTAssertFalse(tracker.isSaving(first))
    XCTAssertTrue(tracker.isSaving(second))  // finishing one leaves the other in flight
  }

  // MARK: completeSave (survives view teardown)

  @MainActor
  func testCompleteSaveMarksSavedAndNotifiesWithoutALiveView() throws {
    // The disk write finished. Even if SwiftUI tore down the text view mid-save,
    // the buffer must be marked saved and the host completion must still fire —
    // these run independently of the (possibly gone) view.
    let buffer = try TextBuffer.open(bytes: Data("abc".utf8))
    try buffer.insert("X", atUTF16: 3)  // make it dirty
    XCTAssertTrue(buffer.isDirty)
    let snapshot = try XCTUnwrap(buffer.takeSaveSnapshot())  // captures "abcX"

    // A save is in flight, started by a view that is now gone. The shared tracker
    // must be cleared by completion regardless, or this buffer stays blocked forever.
    let tracker = DocumentSaveTracker()
    tracker.begin(buffer)
    XCTAssertTrue(tracker.isSaving(buffer))

    var reportedSuccess: [Bool] = []
    LineRenderingTextView.completeSave(
      .success(nil),
      savedBuffer: buffer,
      snapshot: snapshot,
      saveTracker: tracker,
      completion: { result in
        if case .success = result {
          reportedSuccess.append(true)
        } else {
          reportedSuccess.append(false)
        }
      }
    )

    XCTAssertFalse(buffer.isDirty)  // marked saved despite having no view
    XCTAssertEqual(reportedSuccess, [true])  // host was notified of the success
    XCTAssertFalse(tracker.isSaving(buffer))  // in-flight mark cleared
  }

  @MainActor
  func testCompleteSaveKeepsBufferDirtyWhenEditedDuringWrite() throws {
    // The buffer is edited after the snapshot is captured (the user keeps typing
    // during the write). Only the snapshot's content reached disk, so the newer
    // content must stay dirty — but the host is still notified so the written
    // fingerprint is recorded.
    let buffer = try TextBuffer.open(bytes: Data("abc".utf8))
    try buffer.insert("X", atUTF16: 3)
    let snapshot = try XCTUnwrap(buffer.takeSaveSnapshot())  // captures "abcX"
    try buffer.insert("Y", atUTF16: 4)  // edited during the write -> "abcXY"
    XCTAssertTrue(buffer.isDirty)

    var notified = false
    LineRenderingTextView.completeSave(
      .success(nil),
      savedBuffer: buffer,
      snapshot: snapshot,
      saveTracker: DocumentSaveTracker(),
      completion: { _ in notified = true }
    )

    XCTAssertTrue(buffer.isDirty)  // newer content not written -> still dirty
    XCTAssertTrue(notified)
  }

  @MainActor
  func testCompleteSaveReportsFailureToCompletion() throws {
    // A failed write surfaces to the host and leaves the buffer dirty.
    let buffer = try TextBuffer.open(bytes: Data("abc".utf8))
    try buffer.insert("X", atUTF16: 3)
    let snapshot = try XCTUnwrap(buffer.takeSaveSnapshot())

    var reportedFailure = false
    LineRenderingTextView.completeSave(
      .failure(CocoaError(.fileWriteNoPermission)),
      savedBuffer: buffer,
      snapshot: snapshot,
      saveTracker: DocumentSaveTracker(),
      completion: { result in
        if case .failure = result {
          reportedFailure = true
        }
      }
    )

    XCTAssertTrue(reportedFailure)
    XCTAssertTrue(buffer.isDirty)  // a failed write does not mark the buffer saved
  }
}
