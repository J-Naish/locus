import AppKit
import XCTest

@testable import Locus

final class TextViewportLayoutTests: XCTestCase {
  private let layout = TextViewportLayout(lineHeight: 10)

  func testContentHeightScalesWithLineCount() {
    XCTAssertEqual(layout.contentHeight(lineCount: 5), 50)
    XCTAssertEqual(layout.contentHeight(lineCount: 1), 10)
  }

  func testContentHeightTreatsEmptyBufferAsOneLine() {
    // An empty buffer reports one (empty) line, so height is never zero.
    XCTAssertEqual(layout.contentHeight(lineCount: 0), 10)
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

  @MainActor
  func testFailureMessageCallsOutLargeNonUTF8() {
    // A large non-UTF-8 file is rejected by the UTF-8-only buffer; the message
    // must explain the narrowing rather than surface a raw error.
    let message = VirtualizedTextDocumentView.failureMessage(for: TextBufferError.notUTF8)
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

  // MARK: selectedText (copy)

  @MainActor
  private func makeViewer(_ contents: String) throws -> LineRenderingTextView {
    let buffer = try TextBuffer.open(bytes: Data(contents.utf8))
    let view = LineRenderingTextView()
    view.setBuffer(buffer)
    return view
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
    let view = try makeViewer(String(repeating: "x", count: 6000))
    view.selectAll(nil)
    XCTAssertEqual(view.selectedText()?.count, 5000)
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
    let view = try makeViewer("a😀b")
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveByWord(forward: true, extend: false)  // end of "a" / start of 😀
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 1))
    view.moveByWord(forward: true, extend: false)  // end of "b"
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 4))
  }

  // MARK: Accessibility

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
}
