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

  // MARK: WrapIndex (soft-wrap row mapping)

  func testWrapIndexTotalsAndLineStarts() {
    let index = WrapIndex(visualRowsPerLine: [1, 3, 1, 2])
    XCTAssertEqual(index.lineCount, 4)
    XCTAssertEqual(index.totalVisualRows, 7)
    XCTAssertEqual(index.firstVisualRow(ofLine: 0), 0)
    XCTAssertEqual(index.firstVisualRow(ofLine: 1), 1)
    XCTAssertEqual(index.firstVisualRow(ofLine: 2), 4)
    XCTAssertEqual(index.firstVisualRow(ofLine: 3), 5)
    XCTAssertEqual(index.visualRowCount(ofLine: 1), 3)
  }

  func testWrapIndexMapsVisualRowToLineAndSubRow() {
    let index = WrapIndex(visualRowsPerLine: [1, 3, 1, 2])  // rows: 0|1 2 3|4|5 6
    let expected: [(Int, Int)] = [(0, 0), (1, 0), (1, 1), (1, 2), (2, 0), (3, 0), (3, 1)]
    for (row, want) in expected.enumerated() {
      let location = index.location(ofVisualRow: row)
      XCTAssertEqual(location.line, want.0, "row \(row)")
      XCTAssertEqual(location.rowInLine, want.1, "row \(row)")
    }
  }

  func testWrapIndexClampsOutOfRangeRows() {
    let index = WrapIndex(visualRowsPerLine: [2, 2])  // total 4
    XCTAssertEqual(index.location(ofVisualRow: -5).line, 0)
    let last = index.location(ofVisualRow: 999)
    XCTAssertEqual(last.line, 1)
    XCTAssertEqual(last.rowInLine, 1)  // clamped to the final visual row
  }

  func testWrapIndexTreatsEmptyLineAsOneRow() {
    let index = WrapIndex(visualRowsPerLine: [0, 0])  // each clamped to 1
    XCTAssertEqual(index.totalVisualRows, 2)
  }

  // MARK: LineWrap (Core Text line breaking)

  @MainActor
  func testLineWrapReturnsSingleRowWhenItFits() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let line = NSAttributedString(string: "hello", attributes: [.font: font])
    XCTAssertEqual(LineWrap.visualRowStartOffsets(of: line, width: 10_000), [0])
  }

  @MainActor
  func testLineWrapRowCountMatchesWidthForFixedWidthFont() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let charWidth = ("x" as NSString).size(withAttributes: [.font: font]).width
    // No spaces, so Core Text breaks on character boundaries.
    let line = NSAttributedString(
      string: String(repeating: "x", count: 100), attributes: [.font: font])

    // A width fitting ~10 characters should wrap 100 characters into ~10 rows,
    // each starting later than the last.
    let starts = LineWrap.visualRowStartOffsets(of: line, width: charWidth * 10)
    XCTAssertEqual(starts.first, 0)
    XCTAssertEqual(starts, starts.sorted())
    XCTAssertEqual(Set(starts).count, starts.count)  // strictly increasing
    XCTAssert((9...11).contains(starts.count), "expected ~10 rows, got \(starts.count)")
  }

  @MainActor
  func testLineWrapHonorsMaximumRowsCap() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let charWidth = ("x" as NSString).size(withAttributes: [.font: font]).width
    let line = NSAttributedString(
      string: String(repeating: "x", count: 1000), attributes: [.font: font])

    // A one-character width would wrap into ~1000 rows; the cap bounds it.
    let starts = LineWrap.visualRowStartOffsets(of: line, width: charWidth, maximumRows: 8)
    XCTAssertEqual(starts.count, 8)
  }

  @MainActor
  func testLineWrapReturnsSingleRowForNonPositiveWidth() {
    let line = NSAttributedString(string: "anything")
    XCTAssertEqual(LineWrap.visualRowStartOffsets(of: line, width: 0), [0])
  }

  // MARK: View-level wrapping (document height)

  @MainActor
  func testWrappingMakesALongLineTallerThanOneRow() throws {
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)  // narrow viewport
    // One logical line, far wider than the viewport: it must wrap to many rows,
    // so the document is several rows tall.
    let buffer = try TextBuffer.open(bytes: Data(String(repeating: "word ", count: 200).utf8))
    view.setBuffer(buffer)
    XCTAssertGreaterThan(view.frame.height, view.layout.lineHeight * 3)
  }

  @MainActor
  func testShortContentStaysOneRowTall() throws {
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let buffer = try TextBuffer.open(bytes: Data("hi".utf8))
    view.setBuffer(buffer)
    XCTAssertEqual(view.frame.height, view.layout.lineHeight)  // fits one visual row
  }

  /// A viewer whose frame is set *before* the buffer, so soft wrap is active.
  @MainActor
  private func makeWrappingViewer(_ contents: String, width: CGFloat) throws
    -> LineRenderingTextView
  {
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    let buffer = try TextBuffer.open(bytes: Data(contents.utf8))
    view.setBuffer(buffer)
    view.isEditable = true
    return view
  }

  @MainActor
  func testSingleLineInsertWrapsIdenticallyToAFullRebuild() throws {
    // Typing within one line takes the incremental wrap path (only that line is
    // re-wrapped). The result must match a full rebuild of the same final text.
    let width: CGFloat = 160
    let view = try makeWrappingViewer("a\nbbbb bbbb bbbb cccc dddd\nc", width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveVertically(down: true, extend: false)  // onto the long middle line
    view.moveToLineEdge(end: true, extend: false)  // its end
    view.insertText(" eeee ffff gggg hhhh")  // single-line insert: lengthens it

    let reference = try makeWrappingViewer(content(of: view), width: width)
    XCTAssertEqual(view.frame.height, reference.frame.height)
    // Sanity: the middle line actually wraps (document is taller than 3 rows).
    XCTAssertGreaterThan(view.frame.height, view.layout.lineHeight * 3)
  }

  @MainActor
  func testNewlineInsertFallsBackToFullWrapRebuild() throws {
    // Inserting a line break changes the line count, so the incremental path must
    // defer to a full rebuild; the height must still match a fresh viewer.
    let width: CGFloat = 160
    let view = try makeWrappingViewer("one two three four five\nsix", width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveToLineEdge(end: true, extend: false)  // end of the first (wrapping) line
    view.insertText("\nsplit")  // adds a line → not single-line

    let reference = try makeWrappingViewer(content(of: view), width: width)
    XCTAssertEqual(view.frame.height, reference.frame.height)
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

  // MARK: Scroll rendering stability

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

  // MARK: Editing

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
    guard let buffer = view.buffer else { return "" }
    return buffer.text(forLineRange: 0, count: buffer.lineCount)
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
    XCTAssertEqual(view.buffer?.lineCount, 2)
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
    XCTAssertEqual(view.buffer?.lineCount, 1)
    XCTAssertEqual(view.selection?.head, .init(line: 0, columnUTF16: 2))
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
  func testDoCommandInsertNewlineInsertsLineBreak() throws {
    let view = try makeEditableViewer("ab")
    view.moveToDocumentEdge(end: true, extend: false)  // caret (0,2)
    view.doCommand(by: #selector(NSStandardKeyBindingResponding.insertNewline(_:)))
    XCTAssertEqual(content(of: view), "ab\n")
    XCTAssertEqual(view.buffer?.lineCount, 2)
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
  func testBufferMutationsArePausedWhileSaving() throws {
    // The background save reads the buffer; mutations must be paused for its
    // duration so the read never races an edit.
    let view = try makeEditableViewer("abc")
    view.moveToDocumentEdge(end: true, extend: false)
    view.isSaving = true

    view.insertText("X")
    view.deleteBackward()
    view.undoEdit()
    view.redoEdit()
    XCTAssertEqual(content(of: view), "abc")  // every mutation no-ops while saving
  }
}
