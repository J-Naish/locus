import AppKit
import XCTest

@testable import Locus

/// Soft-wrap coverage: the `WrapIndex`/`LineWrap` models, view-level wrapping
/// geometry (including huge-line grid rows and the non-prose long-line
/// decision), the per-edit splice, and the chunked off-main background build.
/// Lives in its own class so wrap TDD runs narrowly via
/// `-only-testing:LocusTests/TextWrapTests`.
final class TextWrapTests: XCTestCase {
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

  @MainActor
  func testMarkdownWrapMeasurementUsesStyledHeadingFont() throws {
    let heading = "# " + String(repeating: "QuarterlyReview", count: 12)
    let viewWidth: CGFloat = 220
    let view = LineRenderingTextView()
    view.syntax = .markdown
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: 400)
    view.setBuffer(try TextBuffer.open(bytes: Data(heading.utf8)))
    let wrapWidth = view.markdownWrapContentWidthForTesting()
    let typography = MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font)
    let state = TextDocumentSyntaxHighlighter.markdownLineStates(for: [heading])[0]
    let expectedRows = LineWrap.visualRowStartOffsets(
      of: TextDocumentSyntaxHighlighter.markdownMeasurementLine(
        heading, font: TextDocumentSyntax.markdown.font, state: state, typography: typography),
      width: wrapWidth,
      maximumRows: 20_000
    ).count

    XCTAssertGreaterThan(expectedRows, 1)
    XCTAssertEqual(view.visualRowCount, expectedRows)
  }

  @MainActor
  func testMarkdownBackgroundWrapMeasurementMatchesStyledForegroundRows() async throws {
    let heading = "# " + String(repeating: "QuarterlyReview", count: 12)
    let body = String(repeating: "body ", count: 80)
    let text = "\(heading)\n\(body)"
    let viewWidth: CGFloat = 220
    let view = LineRenderingTextView()
    view.syntax = .markdown
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: 400)
    view.wrapBuildSynchronousLineLimit = 1
    view.setBuffer(try TextBuffer.open(bytes: Data(text.utf8)))
    let wrapWidth = view.markdownWrapContentWidthForTesting()
    let typography = MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font)
    let lines = text.components(separatedBy: "\n")
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let expectedRows = zip(lines, states).reduce(0) { total, pair in
      total
        + LineWrap.visualRowStartOffsets(
          of: TextDocumentSyntaxHighlighter.markdownMeasurementLine(
            pair.0,
            font: TextDocumentSyntax.markdown.font,
            state: pair.1,
            typography: typography),
          width: wrapWidth,
          maximumRows: 20_000
        ).count
    }

    await view.settleWrapBuildsForTesting()

    XCTAssertEqual(view.visualRowCount, expectedRows)
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
    XCTAssertGreaterThan(view.visualRowCount, 3)
  }

  @MainActor
  func testLargeFileOfFewLinesStillWraps() throws {
    // A multi-megabyte file (well past the former 2 MiB wrap cap) made of only a
    // couple of enormous lines must still wrap: wrapping is bounded per line, so
    // byte size alone no longer disables it.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)  // narrow viewport
    let giantLine = String(repeating: "word ", count: 800_000)  // ~4 MB on one line
    let buffer = try TextBuffer.open(bytes: Data("\(giantLine)\n\(giantLine)".utf8))
    XCTAssertGreaterThan(buffer.byteLength, 2 * 1024 * 1024)
    view.setBuffer(buffer)
    XCTAssertGreaterThan(view.visualRowCount, 3)
  }

  @MainActor
  func testHugeLineIsFullyAddressableNotClippedToTheDisplayLimit() throws {
    // A single line far longer than the per-line display clip is virtualized, so
    // its whole length stays addressable (Select All reaches the true end) rather
    // than being truncated at the clip.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    let length = 60_000
    let buffer = try TextBuffer.open(bytes: Data(String(repeating: "x", count: length).utf8))
    view.setBuffer(buffer)
    XCTAssertTrue(view.isSoftWrapping)
    view.selectAll(nil)
    XCTAssertEqual(view.selection?.head.columnUTF16, length)
  }

  @MainActor
  func testHugeLineWrapsBeyondTheDisplayClip() throws {
    // The huge line wraps over its full length, so it is much taller than a line
    // sitting at the clip would be — proof it is not laid out clipped.
    let width: CGFloat = 140
    let huge = LineRenderingTextView()
    huge.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    huge.setBuffer(try TextBuffer.open(bytes: Data(String(repeating: "x", count: 60_000).utf8)))

    let atClip = LineRenderingTextView()
    atClip.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    // 20_000 == the clip, so this line is laid out in full (not virtualized).
    atClip.setBuffer(try TextBuffer.open(bytes: Data(String(repeating: "x", count: 20_000).utf8)))

    XCTAssertGreaterThan(huge.visualRowCount, atClip.visualRowCount * 2)
  }

  @MainActor
  func testHugeLineCopyIsNotClippedToTheDisplayLimit() throws {
    // Copy reads the real selected range, so a huge line copies in full — not
    // truncated at the display clip (which would also corrupt cut).
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    let length = 60_000
    view.setBuffer(try TextBuffer.open(bytes: Data(String(repeating: "x", count: length).utf8)))
    view.selectAll(nil)
    XCTAssertEqual(view.selectedText()?.count, length)
  }

  @MainActor
  func testHugeLineCharacterStepBackwardPastClipIsSafe() throws {
    // Stepping the caret backward from beyond the display clip must resolve the
    // grapheme from a window (not index the clipped string, which would crash).
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    view.isEditable = true
    let length = 60_000
    view.setBuffer(try TextBuffer.open(bytes: Data(String(repeating: "x", count: length).utf8)))
    view.selectAll(nil)
    view.moveHorizontally(forward: true, extend: false)  // collapse the caret to the end
    XCTAssertEqual(view.selection?.head.columnUTF16, length)
    view.moveHorizontally(forward: false, extend: false)  // back one grapheme, well past the clip
    XCTAssertEqual(view.selection?.head.columnUTF16, length - 1)
  }

  @MainActor
  func testHugeLineDeleteBackwardPastClipShortensTheLine() throws {
    // Delete backward from beyond the clip removes one real character rather than
    // crashing or deleting from the clipped prefix.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    view.isEditable = true
    let length = 60_000
    view.setBuffer(try TextBuffer.open(bytes: Data(String(repeating: "x", count: length).utf8)))
    view.selectAll(nil)
    view.moveHorizontally(forward: true, extend: false)  // caret at the true end
    view.deleteBackward()
    view.selectAll(nil)
    XCTAssertEqual(view.selectedText()?.count, length - 1)
  }

  @MainActor
  func testExceedingFetchedByteBudgetFallsBackToNoWrap() throws {
    // Over the aggregate fetched-byte budget, the wrap-index build is skipped and
    // the long line scrolls horizontally instead of wrapping — the safety valve
    // that keeps the main-thread build bounded.
    let longLine = String(repeating: "word ", count: 200)  // wraps when allowed
    let contents = "\(longLine)\n\(longLine)"
    let buffer = try TextBuffer.open(bytes: Data(contents.utf8))

    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)  // narrow viewport
    view.maximumWrappableFetchedByteBudget = 16  // below this buffer's bytes
    view.setBuffer(buffer)
    // No wrap: two logical lines, one visual row each.
    XCTAssertEqual(view.visualRowCount, 2)
  }

  @MainActor
  func testShortContentStaysOneRowTall() throws {
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let buffer = try TextBuffer.open(bytes: Data("hi".utf8))
    view.setBuffer(buffer)
    XCTAssertEqual(view.visualRowCount, 1)  // fits one visual row
  }

  @MainActor
  func testClickBelowContentLandsAtDocumentEnd() throws {
    // Clicking the empty area below the last line places the caret at the document
    // end regardless of x — not at the column nearest the click on the last line.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    let buffer = try TextBuffer.open(bytes: Data("@AGENTS.md".utf8))
    view.setBuffer(buffer)
    let end = TextSelection.Endpoint(line: 0, columnUTF16: 10)  // after the final "d"

    // Far below the single line, at a left-ish x that sits over "S".
    let below = view.endpoint(at: NSPoint(x: 60, y: 300))
    XCTAssertEqual(below, end)
    // A click that is genuinely to the right of the text on the line's own row
    // also resolves to the end.
    let right = view.endpoint(at: NSPoint(x: 5000, y: 1))
    XCTAssertEqual(right, end)
  }

  @MainActor
  func testShortDocumentFillsTheViewportHeight() throws {
    // A single-row document still fills the viewport; the only row is already at
    // the top, so scroll-past-end adds no scrollable distance.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.setBuffer(try TextBuffer.open(bytes: Data("hi".utf8)))
    XCTAssertEqual(view.visualRowCount, 1)  // content is one row…
    XCTAssertEqual(view.frame.height, 400)  // …but the view fills the viewport
  }

  @MainActor
  func testDetachedTallDocumentLayoutIsIdempotentWithoutScrollPastEndTail() throws {
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.setBuffer(try TextBuffer.open(bytes: Data(numberedLines(5).utf8)))

    let firstHeight = view.frame.height
    XCTAssertEqual(firstHeight, max(contentHeight(of: view), CGFloat(400)))

    view.updateLayout()
    let secondHeight = view.frame.height
    view.updateLayout()

    XCTAssertEqual(secondHeight, firstHeight)
    XCTAssertEqual(view.frame.height, secondHeight)
  }

  @MainActor
  func testScrollPastEndFrameTracksTheScrollViewViewport() throws {
    let (scrollView, view) = try makeScrollViewViewer(numberedLines(60))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    let viewportHeight = scrollView.contentView.bounds.height
    let contentHeight = CGFloat(view.visualRowCount) * view.layout.lineHeight
    let expected = contentHeight + (viewportHeight - view.layout.lineHeight)
    XCTAssertEqual(view.frame.height, expected)
  }

  @MainActor
  func testTwoLineDocumentScrollsUntilSecondLineIsAtTop() throws {
    let (scrollView, view) = try makeScrollViewViewer("one\ntwo")
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    let viewportHeight = scrollView.contentView.bounds.height
    let expectedHeight = contentHeight(of: view) + (viewportHeight - view.layout.lineHeight)
    XCTAssertEqual(view.frame.height, expectedHeight)

    scroll(scrollView, toY: maxScrollPastEndOffset(of: view))

    XCTAssertEqual(scrollView.contentView.bounds.origin.y, view.layout.lineHeight)
  }

  @MainActor
  func testGutterChromeIsDrawnWhenTheVisibleBandIsPastTheContent() throws {
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.showsLineNumbers = true
    view.setBuffer(try TextBuffer.open(bytes: Data(numberedLines(60).utf8)))

    let contentHeight = CGFloat(view.visualRowCount) * view.layout.lineHeight
    let lineBand = render(view, dirtyRect: NSRect(x: 0, y: 0, width: 600, height: 30))
    let tailBand = render(
      view, dirtyRect: NSRect(x: 0, y: contentHeight + 40, width: 600, height: 30))

    let sampleWidth = min(120, max(1, Int(ceil(view.gutterWidth)) + 2))
    let lineColumns = verticalChromeColumns(in: lineBand, sampleXUpperBound: sampleWidth)
    let tailColumns = verticalChromeColumns(in: tailBand, sampleXUpperBound: sampleWidth)

    XCTAssertFalse(lineColumns.isEmpty)
    XCTAssertEqual(tailColumns, lineColumns)
  }

  @MainActor
  func testClickInScrollPastEndTailLandsAtDocumentEnd() throws {
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.setBuffer(try TextBuffer.open(bytes: Data(numberedLines(60).utf8)))

    let contentHeight = contentHeight(of: view)
    let endpoint = view.endpoint(at: NSPoint(x: 60, y: contentHeight + 100))

    XCTAssertEqual(endpoint, TextSelection.Endpoint(line: 59, columnUTF16: "line 59".utf16.count))
  }

  @MainActor
  func testCaretRevealAtEndOfDocumentDoesNotScrollIntoTheTail() throws {
    let (scrollView, view) = try makeScrollViewViewer(numberedLines(60))
    view.isEditable = true
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    view.moveToDocumentEdge(end: true, extend: false)

    let expected = contentHeight(of: view) - scrollView.contentView.bounds.height
    XCTAssertEqual(scrollView.contentView.bounds.origin.y, expected)
  }

  @MainActor
  func testUpdateLayoutIsIdempotentWithScrollPastEnd() throws {
    let (scrollView, view) = try makeScrollViewViewer(numberedLines(60))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    scroll(scrollView, toY: 200)

    view.updateLayout()
    let frame = view.frame
    let origin = scrollView.contentView.bounds.origin
    view.updateLayout()

    XCTAssertEqual(view.frame.origin.x, frame.origin.x)
    XCTAssertEqual(view.frame.origin.y, frame.origin.y)
    XCTAssertEqual(view.frame.size.width, frame.size.width)
    XCTAssertEqual(view.frame.size.height, frame.size.height)
    XCTAssertEqual(scrollView.contentView.bounds.origin.x, origin.x)
    XCTAssertEqual(scrollView.contentView.bounds.origin.y, origin.y)
  }

  @MainActor
  func testDocumentSwapResetsScrollFromTheTail() throws {
    let (scrollView, view) = try makeScrollViewViewer(numberedLines(60))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    scroll(scrollView, toY: maxScrollPastEndOffset(of: view))

    view.setBuffer(try TextBuffer.open(bytes: Data("short\ndoc".utf8)))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    XCTAssertEqual(scrollView.contentView.bounds.origin.x, 0)
    XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0)
    let viewportHeight = scrollView.contentView.bounds.height
    let expectedHeight = contentHeight(of: view) + (viewportHeight - view.layout.lineHeight)
    XCTAssertEqual(view.frame.height, expectedHeight)
  }

  @MainActor
  func testParkedOffsetSurvivesViewportResize() throws {
    let (scrollView, view) = try makeScrollViewViewer(numberedLines(60))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    let maxOffset = maxScrollPastEndOffset(of: view)
    scroll(scrollView, toY: maxOffset)

    scrollView.setFrameSize(NSSize(width: 600, height: 280))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    XCTAssertEqual(scrollView.contentView.bounds.origin.y, maxOffset)
  }

  @MainActor
  func testShrinkingContentClampsTheParkedOffset() throws {
    let (scrollView, view) = try makeScrollViewViewer(numberedLines(60))
    view.isEditable = true
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    scroll(scrollView, toY: maxScrollPastEndOffset(of: view))

    view.selectAll(nil)
    view.deleteBackward()
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    let originY = scrollView.contentView.bounds.origin.y
    let maxLegalOffset = max(0, view.frame.height - scrollView.contentView.bounds.height)
    XCTAssertGreaterThanOrEqual(originY, 0)
    XCTAssertLessThanOrEqual(originY, maxLegalOffset)
  }

  // MARK: Horizontal scroller / gutter alignment

  @MainActor
  func testHorizontalScrollerInsetMatchesGutterWidthAfterLayout() throws {
    let (scrollView, view) = try makeScrollerEquippedViewer(numberedLines(60))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    XCTAssertGreaterThan(view.gutterWidth, 0)
    XCTAssertEqual(scrollView.scrollerInsets.left, view.gutterWidth)
  }

  @MainActor
  func testHorizontalScrollerInsetTracksGutterDigitGrowthOnDocumentSwap() throws {
    let (scrollView, view) = try makeScrollerEquippedViewer(numberedLines(5))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    let initialInset = scrollView.scrollerInsets.left

    view.setBuffer(try TextBuffer.open(bytes: Data(numberedLines(10_000).utf8)))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    let expected = GutterMetrics.width(
      lineCount: view.lineCount, font: GutterMetrics.lineNumberFont)
    XCTAssertEqual(view.gutterWidth, expected)
    XCTAssertEqual(scrollView.scrollerInsets.left, expected)
    XCTAssertGreaterThan(scrollView.scrollerInsets.left, initialInset)
  }

  @MainActor
  func testHorizontalScrollerInsetCollapsesWhenLineNumbersAreHidden() throws {
    let (scrollView, view) = try makeScrollerEquippedViewer(numberedLines(60))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    XCTAssertGreaterThan(scrollView.scrollerInsets.left, 0)

    view.showsLineNumbers = false

    XCTAssertEqual(scrollView.scrollerInsets.left, 0)
  }

  @MainActor
  func testScrollerInsetLeavesVerticalScrollerAndOtherEdgesUntouched() throws {
    let (scrollView, view) = try makeScrollerEquippedViewer(
      numberedLines(60), autohidesScrollers: false)
    view.showsLineNumbers = false
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    scrollView.layoutSubtreeIfNeeded()
    let initialVerticalFrame = try XCTUnwrap(scrollView.verticalScroller).frame

    view.showsLineNumbers = true
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    scrollView.layoutSubtreeIfNeeded()

    XCTAssertEqual(scrollView.verticalScroller?.frame.origin.x, initialVerticalFrame.origin.x)
    XCTAssertEqual(scrollView.verticalScroller?.frame.origin.y, initialVerticalFrame.origin.y)
    XCTAssertEqual(scrollView.verticalScroller?.frame.size.width, initialVerticalFrame.size.width)
    XCTAssertEqual(scrollView.verticalScroller?.frame.size.height, initialVerticalFrame.size.height)
    XCTAssertEqual(scrollView.scrollerInsets.top, 0)
    XCTAssertEqual(scrollView.scrollerInsets.bottom, 0)
    XCTAssertEqual(scrollView.scrollerInsets.right, 0)
  }

  @MainActor
  func testHorizontalScrollerTrackStartsAtGutterEdge() throws {
    let longLine = String(repeating: "wide ", count: 200)
    let (scrollView, view) = try makeScrollerEquippedViewer("", autohidesScrollers: false)
    view.wrapsLines = false
    view.setBuffer(try TextBuffer.open(bytes: Data(longLine.utf8)))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    _ = render(view, dirtyRect: view.bounds)
    view.updateLayout()
    scrollView.layoutSubtreeIfNeeded()

    let horizontalFrame = try XCTUnwrap(scrollView.horizontalScroller).frame
    XCTAssertEqual(horizontalFrame.minX, view.gutterWidth, accuracy: 0.5)
    XCTAssertLessThanOrEqual(horizontalFrame.maxX, scrollView.bounds.maxX)
  }

  @MainActor
  func testUpdateLayoutWithScrollersStaysIdempotent() throws {
    let (scrollView, view) = try makeScrollerEquippedViewer(numberedLines(60))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()
    scroll(scrollView, toY: 120)

    view.updateLayout()
    scrollView.layoutSubtreeIfNeeded()
    let frame = view.frame
    let origin = scrollView.contentView.bounds.origin
    let inset = scrollView.scrollerInsets.left

    view.updateLayout()
    scrollView.layoutSubtreeIfNeeded()

    XCTAssertEqual(view.frame.origin.x, frame.origin.x)
    XCTAssertEqual(view.frame.origin.y, frame.origin.y)
    XCTAssertEqual(view.frame.size.width, frame.size.width)
    XCTAssertEqual(view.frame.size.height, frame.size.height)
    XCTAssertEqual(scrollView.contentView.bounds.origin.x, origin.x)
    XCTAssertEqual(scrollView.contentView.bounds.origin.y, origin.y)
    XCTAssertEqual(scrollView.scrollerInsets.left, inset)
  }

  @MainActor
  func testWrapModeKeepsViewportWidthWithScrollerInsetApplied() throws {
    let (scrollView, view) = try makeScrollerEquippedViewer(
      String(repeating: "word ", count: 200))
    scrollView.layoutSubtreeIfNeeded()
    view.updateLayout()

    XCTAssertTrue(view.isSoftWrapping)
    XCTAssertEqual(view.frame.width, scrollView.contentView.bounds.width)
    XCTAssertEqual(scrollView.scrollerInsets.left, view.gutterWidth)
  }

  @MainActor
  func testExceedingLineCountFallsBackToNoWrap() throws {
    // Past the line-count safety valve the synchronous wrap-index build is
    // skipped, so even a long line does not wrap — keeping open/resize bounded.
    let longLine = String(repeating: "word ", count: 200)  // would wrap if allowed
    let buffer = try TextBuffer.open(bytes: Data("short\n\(longLine)\nshort".utf8))  // 3 lines

    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)  // narrow viewport
    view.maximumWrappableLineCount = 2  // below this buffer's 3 lines
    view.setBuffer(buffer)
    XCTAssertEqual(view.visualRowCount, 3)  // no wrap: 3 rows
  }

  @MainActor
  func testNonProseWithoutLongLineScrollsHorizontally() throws {
    // Non-prose (code/data) with no line past the threshold scrolls horizontally,
    // even when a line is far wider than the viewport — it stays one row.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)  // narrow viewport
    view.wrapsLines = false
    view.longLineWrapThreshold = 10_000
    let buffer = try TextBuffer.open(bytes: Data(String(repeating: "word ", count: 50).utf8))
    view.setBuffer(buffer)  // 250 chars: would wrap to many rows if it wrapped
    XCTAssertFalse(view.isSoftWrapping)
    XCTAssertEqual(view.visualRowCount, 1)
  }

  @MainActor
  func testNonProseLongLineWrapsAfterInitialZeroWidthLayout() throws {
    // The first build can run before the view has a width (wrap content width ≤ 0)
    // and bail to no-wrap without scanning. The first real layout afterward must
    // still detect the long line and wrap — not stay one line until a reopen.
    let view = LineRenderingTextView()
    view.wrapsLines = false
    view.longLineWrapThreshold = 20
    // Force a zero wrap width at the first build (mirrors a not-yet-laid-out
    // scroll view), set after configuring `wrapsLines` whose didSet resizes.
    view.frame = NSRect(x: 0, y: 0, width: 0, height: 400)
    let buffer = try TextBuffer.open(bytes: Data(String(repeating: "word ", count: 50).utf8))
    view.setBuffer(buffer)
    XCTAssertFalse(view.isSoftWrapping)  // no width yet → cannot have decided to wrap

    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)  // now it has a width
    view.updateLayout()
    XCTAssertTrue(view.isSoftWrapping)  // long line detected on first real layout
  }

  @MainActor
  func testNonProseLongLineWrapsEntireDocumentWithoutMixing() throws {
    // A single line past the threshold flips the whole non-prose document to
    // wrapping — folding and horizontal scrolling never mix. The short first line
    // wraps too (it just fits one row), so the document is in wrap mode.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)  // narrow viewport
    view.wrapsLines = false
    view.longLineWrapThreshold = 20
    let longLine = String(repeating: "word ", count: 50)  // 250 chars > threshold
    let buffer = try TextBuffer.open(bytes: Data("short\n\(longLine)".utf8))
    view.setBuffer(buffer)
    XCTAssertTrue(view.isSoftWrapping)
    XCTAssertGreaterThan(view.visualRowCount, 3)
  }

  @MainActor
  func testProseWrapsBelowThresholdRegardlessOfLength() throws {
    // Prose wraps every line; the long-line threshold only governs non-prose.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)  // narrow viewport
    view.wrapsLines = true
    view.longLineWrapThreshold = 10_000  // would suppress wrap for non-prose
    let buffer = try TextBuffer.open(bytes: Data(String(repeating: "word ", count: 50).utf8))
    view.setBuffer(buffer)
    XCTAssertGreaterThan(view.visualRowCount, 3)
  }

  /// A viewer whose frame is set *before* the buffer, so soft wrap is active.
  /// Detached viewers use viewport-fill fallback until placed in an NSScrollView.
  @MainActor
  // MARK: I-beam cursor region

  // The editor shows the text I-beam right of the pinned gutter and the arrow
  // over the gutter itself, via cursor rects built from this pure region math
  // (`resetCursorRects` feeds it the visible band and the gutter's right edge).
  func testIBeamCursorRectCoversVisibleBandRightOfGutter() {
    let rect = LineRenderingTextView.iBeamCursorRect(
      visible: NSRect(x: 0, y: 0, width: 600, height: 400), gutterEdge: 42)
    XCTAssertEqual(rect, NSRect(x: 42, y: 0, width: 558, height: 400))
  }

  func testIBeamCursorRectFollowsTheScrolledVisibleBand() {
    // Scrolled 100pt right and 300pt down: the gutter is viewport-pinned, so
    // its edge moves with the scroll origin and the band tracks the viewport.
    let rect = LineRenderingTextView.iBeamCursorRect(
      visible: NSRect(x: 100, y: 300, width: 600, height: 400), gutterEdge: 142)
    XCTAssertEqual(rect, NSRect(x: 142, y: 300, width: 558, height: 400))
  }

  func testIBeamCursorRectIsNilWhenNothingIsVisibleOrGutterCoversTheBand() {
    XCTAssertNil(
      LineRenderingTextView.iBeamCursorRect(visible: .zero, gutterEdge: 0))
    XCTAssertNil(
      LineRenderingTextView.iBeamCursorRect(
        visible: NSRect(x: 0, y: 0, width: 40, height: 400), gutterEdge: 40))
  }

  // The editor corrects the pointer cursor on every mouse move (I-beam over
  // text, arrow over the gutter): entry-edge cursor rects alone go stale when
  // the pointer arrives from the titlebar tab strip, whose SwiftUI pointer
  // handling resets the cursor after the rect's enter event already fired.
  @MainActor
  func testEditorRegistersAMouseMovedTrackingAreaOverTheVisibleRect() throws {
    let (scrollView, view) = try makeScrollViewViewer(numberedLines(60))
    scrollView.layoutSubtreeIfNeeded()

    view.updateTrackingAreas()

    let area = view.trackingAreas.first { $0.options.contains(.mouseMoved) }
    XCTAssertNotNil(area, "expected a mouseMoved tracking area")
    XCTAssertEqual(area?.options.contains(.inVisibleRect), true)
    XCTAssertEqual(area?.options.contains(.mouseEnteredAndExited), true)
  }

  // Opening a document scrolls to the top — which, with a top content inset,
  // is above the content origin so the first line rests its inset below the
  // viewport edge (not pre-scrolled past the breathing room).
  @MainActor
  func testOpeningADocumentRestsAtTheInsetTopNotTheContentOrigin() throws {
    let (scrollView, view) = try makeScrollViewViewer(numberedLines(60))
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 0, right: 0)
    scrollView.layoutSubtreeIfNeeded()

    view.setBuffer(try TextBuffer.open(bytes: Data(numberedLines(40).utf8)))

    XCTAssertEqual(scrollView.contentView.bounds.origin.y, -10, accuracy: 0.5)
  }

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

  private func numberedLines(_ count: Int) -> String {
    (0..<count).map { "line \($0)" }.joined(separator: "\n")
  }

  private func contentHeight(of view: LineRenderingTextView) -> CGFloat {
    CGFloat(max(view.visualRowCount, 1)) * view.layout.lineHeight
  }

  private func maxScrollPastEndOffset(of view: LineRenderingTextView) -> CGFloat {
    max(0, contentHeight(of: view) - view.layout.lineHeight)
  }

  @MainActor
  private func scroll(_ scrollView: NSScrollView, toY y: CGFloat) {
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  @MainActor
  private func makeScrollViewViewer(
    _ contents: String, size: NSSize = NSSize(width: 600, height: 400)
  ) throws -> (NSScrollView, LineRenderingTextView) {
    let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
    let view = LineRenderingTextView()
    view.frame = NSRect(origin: .zero, size: size)
    scrollView.documentView = view
    view.setBuffer(try TextBuffer.open(bytes: Data(contents.utf8)))
    return (scrollView, view)
  }

  @MainActor
  private func makeScrollerEquippedViewer(
    _ contents: String,
    size: NSSize = NSSize(width: 600, height: 400),
    autohidesScrollers: Bool = true
  ) throws -> (NSScrollView, LineRenderingTextView) {
    let (scrollView, view) = try makeScrollViewViewer(contents, size: size)
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = autohidesScrollers
    scrollView.scrollerStyle = .legacy
    return (scrollView, view)
  }

  @MainActor
  private func render(_ view: LineRenderingTextView, dirtyRect: NSRect) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: max(1, Int(ceil(dirtyRect.width))),
      pixelsHigh: max(1, Int(ceil(dirtyRect.height))),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.translateBy(x: -dirtyRect.minX, y: -dirtyRect.minY)
    view.draw(dirtyRect)
    context.flushGraphics()
    return rep
  }

  private func verticalChromeColumns(
    in rep: NSBitmapImageRep, sampleXUpperBound: Int
  ) -> Set<Int> {
    let background = rgbPixel(in: rep, x: 0, y: 0)
    let height = rep.pixelsHigh
    let threshold = max(1, height * 3 / 4)
    var columns = Set<Int>()
    for x in 0..<min(sampleXUpperBound, rep.pixelsWide) {
      var changed = 0
      for y in 0..<height where pixelDistance(rgbPixel(in: rep, x: x, y: y), background) > 2 {
        changed += 1
      }
      if changed >= threshold {
        columns.insert(x)
      }
    }
    return columns
  }

  private func rgbPixel(in rep: NSBitmapImageRep, x: Int, y: Int) -> [Int] {
    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
      return [0, 0, 0, 0]
    }
    return [
      Int((color.redComponent * 255).rounded()),
      Int((color.greenComponent * 255).rounded()),
      Int((color.blueComponent * 255).rounded()),
      Int((color.alphaComponent * 255).rounded()),
    ]
  }

  private func pixelDistance(_ lhs: [Int], _ rhs: [Int]) -> Int {
    zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
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
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
    // Sanity: the middle line actually wraps (document is taller than 3 rows).
    XCTAssertGreaterThan(view.visualRowCount, 3)
  }

  @MainActor
  func testNonProseLeavesWrapModeWhenLastLongLineShortened() throws {
    // Shortening the only long line returns a non-prose document to horizontal
    // scroll immediately (no reload needed) — the document-wide wrap decision is
    // kept current as the single line is edited.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    view.wrapsLines = false
    view.longLineWrapThreshold = 20
    view.isEditable = true
    let buffer = try TextBuffer.open(bytes: Data(String(repeating: "x", count: 25).utf8))
    view.setBuffer(buffer)
    XCTAssertTrue(view.isSoftWrapping)  // 25 > 20 → whole document wraps

    view.moveToDocumentEdge(end: true, extend: false)
    for _ in 0..<6 { view.deleteBackward() }  // 25 - 6 = 19 ≤ 20
    XCTAssertFalse(view.isSoftWrapping)  // back to horizontal scroll
  }

  @MainActor
  func testNewlineInsertWrapsIdenticallyToAFullRebuild() throws {
    // Inserting a line break splices the rewritten lines into the wrap index;
    // the height must still match a fresh viewer of the same final text.
    let width: CGFloat = 160
    let view = try makeWrappingViewer("one two three four five\nsix", width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveToLineEdge(end: true, extend: false)  // end of the first (wrapping) line
    view.insertText("\nsplit")  // adds a line

    let reference = try makeWrappingViewer(content(of: view), width: width)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testBackspaceAtLineStartMergesAndWrapsIdenticallyToAFullRebuild() throws {
    // Deleting a line break merges two lines: one rewritten line replaces two.
    // The first line fits one visual row, so one "down" lands on logical line 1.
    let width: CGFloat = 160
    let view = try makeWrappingViewer(
      "short\nsix seven eight nine ten eleven twelve thirteen", width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveVertically(down: true, extend: false)  // start of the second line
    view.deleteBackward()  // removes the line break

    let reference = try makeWrappingViewer(content(of: view), width: width)
    XCTAssertEqual(content(of: view), "shortsix seven eight nine ten eleven twelve thirteen")
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testMultiLinePasteOverAMultiLineSelectionWrapsIdenticallyToAFullRebuild() throws {
    // Replacing a selection that spans lines with a block that spans different
    // lines exercises the general splice: removed and inserted line counts both
    // differ from one. The result must match a fresh viewer.
    let width: CGFloat = 160
    let view = try makeWrappingViewer(
      "alpha beta gamma delta epsilon zeta\nshort\ntheta iota kappa lambda mu nu xi\ntail",
      width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveToLineEdge(end: true, extend: false)  // end of line 0
    view.moveVertically(down: true, extend: true)
    view.moveVertically(down: true, extend: true)
    view.moveToLineEdge(end: false, extend: true)  // selection spans lines 0–2
    view.insertText("one two three four five six seven eight\nnine\nten eleven twelve\nthirteen")

    let reference = try makeWrappingViewer(content(of: view), width: width)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
    XCTAssertGreaterThan(view.visualRowCount, 5)  // sanity: wrapping is active
  }

  @MainActor
  func testMultiLineDeleteWrapsIdenticallyToAFullRebuild() throws {
    let width: CGFloat = 160
    let view = try makeWrappingViewer(
      "alpha beta gamma delta epsilon zeta\nmiddle one\nmiddle two\ntheta iota kappa lambda",
      width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveVertically(down: true, extend: false)  // line 1
    view.moveVertically(down: true, extend: true)
    view.moveVertically(down: true, extend: true)
    view.moveToLineEdge(end: true, extend: true)  // selection spans lines 1–3
    view.deleteBackward()

    let reference = try makeWrappingViewer(content(of: view), width: width)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testMarkdownEditWrapsIdenticallyToAFullRebuild() throws {
    let width: CGFloat = 260
    let original = """
      # A heading that is intentionally long enough to wrap across the centered prose column
      paragraph body with **strong text** and a second phrase that wraps
      """
    let view = try makeWrappingViewer(original, width: width)
    view.syntax = .markdown
    view.updateLayout()
    view.beginCaretSelection(at: .init(line: 1, columnUTF16: 0))

    view.insertText("> ")

    let reference = try makeWrappingViewer(content(of: view), width: width)
    reference.syntax = .markdown
    reference.updateLayout()
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testUndoAndRedoOfAMultiLineEditWrapIdenticallyToAFullRebuild() throws {
    // Undo/redo splice the rewritten span reported by the buffer instead of
    // re-wrapping the document; both directions must match fresh viewers.
    let width: CGFloat = 160
    let original = "first line long enough to wrap at this width\nsecond\nthird line also wraps"
    let view = try makeWrappingViewer(original, width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.moveToLineEdge(end: true, extend: false)
    view.moveVertically(down: true, extend: true)
    view.moveToLineEdge(end: true, extend: true)  // selection spans lines 0–1
    view.insertText("replacement spanning the viewport width\nwith\nextra\nlines")
    let edited = content(of: view)
    let editedReference = try makeWrappingViewer(edited, width: width)
    XCTAssertEqual(view.visualRowCount, editedReference.visualRowCount)

    XCTAssertTrue(view.undoEdit())
    XCTAssertEqual(content(of: view), original)
    let originalReference = try makeWrappingViewer(original, width: width)
    XCTAssertEqual(view.visualRowCount, originalReference.visualRowCount)

    XCTAssertTrue(view.redoEdit())
    XCTAssertEqual(content(of: view), edited)
    XCTAssertEqual(view.visualRowCount, editedReference.visualRowCount)
  }

  @MainActor
  func testMultiLineEditsAtTheDocumentEdgesWrapIdenticallyToAFullRebuild() throws {
    // Splice bands touching both document edges, including appending past a
    // trailing newline (the final empty line).
    let width: CGFloat = 160
    let view = try makeWrappingViewer(
      "middle line that wraps at this narrow width\nend\n", width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.insertText("prologue first\nprologue second longer than the viewport width\n")
    view.moveToDocumentEdge(end: true, extend: false)
    view.insertText("epilogue one\nepilogue two stretches well past the narrow viewport")

    let reference = try makeWrappingViewer(content(of: view), width: width)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testMultiLineEditBeforeAHugeLineKeepsItsGridRows() throws {
    // A huge line (past the display cap) grid-wraps from a cached global UTF-16
    // start; an edit on earlier lines shifts that start rather than re-resolving
    // (or corrupting) it. The height must match a fresh viewer, whose build
    // re-resolves the huge line from scratch.
    let width: CGFloat = 400
    let huge = String(repeating: "h", count: 25_000)  // past maximumDrawnCharactersPerLine
    let view = try makeWrappingViewer("short top\nmiddle\n\(huge)\nbottom", width: width)
    view.moveToDocumentEdge(end: false, extend: false)
    view.insertText("inserted alpha\ninserted beta\n")  // before the huge line

    let reference = try makeWrappingViewer(content(of: view), width: width)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
    XCTAssertGreaterThan(view.visualRowCount, 50)  // sanity: the huge line grid-wraps
  }

  @MainActor
  func testNonProseMultiLinePasteIntroducingALongLineEntersWrapMode() throws {
    // In a horizontally-scrolling non-prose document, a long line arriving
    // inside a multi-line paste must still flip the document to wrapping.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    view.wrapsLines = false
    view.longLineWrapThreshold = 20
    view.isEditable = true
    view.setBuffer(try TextBuffer.open(bytes: Data("short\nlines".utf8)))
    XCTAssertFalse(view.isSoftWrapping)

    view.moveToDocumentEdge(end: true, extend: false)
    view.insertText("\nmid\n" + String(repeating: "x", count: 25))
    XCTAssertTrue(view.isSoftWrapping)

    // Oracle: a fresh non-prose viewer of the final content agrees on the rows.
    let reference = LineRenderingTextView()
    reference.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    reference.wrapsLines = false
    reference.longLineWrapThreshold = 20
    reference.setBuffer(try TextBuffer.open(bytes: Data(content(of: view).utf8)))
    XCTAssertTrue(reference.isSoftWrapping)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testNonProseMultiLineDeleteRemovingTheLastLongLineLeavesWrapMode() throws {
    // Deleting a selection that swallows the document's only long line returns
    // a non-prose document to horizontal scroll immediately.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    view.wrapsLines = false
    view.longLineWrapThreshold = 20
    view.isEditable = true
    let long = String(repeating: "x", count: 25)
    view.setBuffer(try TextBuffer.open(bytes: Data("aaa\n\(long)\nbbb".utf8)))
    XCTAssertTrue(view.isSoftWrapping)  // the long line wraps the whole document

    view.moveToDocumentEdge(end: false, extend: false)
    view.moveToLineEdge(end: true, extend: false)  // end of line 0
    view.moveVertically(down: true, extend: true)
    view.moveToLineEdge(end: true, extend: true)  // selection covers the long line
    view.deleteBackward()
    XCTAssertFalse(view.isSoftWrapping)
    XCTAssertEqual(content(of: view), "aaa\nbbb")
  }

  // MARK: Background (chunked, off-main) wrap build

  /// A wrapping viewer whose knobs force the chunked background build even for
  /// tiny fixtures: any document over two lines builds off-main, three lines
  /// per chunk.
  @MainActor
  private func makeBackgroundWrappingViewer(_ contents: String, width: CGFloat) throws
    -> LineRenderingTextView
  {
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    view.wrapBuildSynchronousLineLimit = 2
    view.wrapBuildChunkLineCount = 3
    view.setBuffer(try TextBuffer.open(bytes: Data(contents.utf8)))
    view.isEditable = true
    return view
  }

  @MainActor
  func testBackgroundBuildMatchesTheSynchronousBuild() async throws {
    let contents = (0..<10)
      .map { "line \($0) with words enough to wrap at a narrow width" }
      .joined(separator: "\n")
    let view = try makeBackgroundWrappingViewer(contents, width: 160)

    // While the build is in flight the document keeps unwrapped geometry — the
    // open never blocks on a full-document measurement.
    XCTAssertFalse(view.isSoftWrapping)
    XCTAssertEqual(view.visualRowCount, 10)

    await view.settleWrapBuildsForTesting()
    let reference = try makeWrappingViewer(contents, width: 160)  // synchronous path
    XCTAssertTrue(view.isSoftWrapping)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
    XCTAssertGreaterThan(view.visualRowCount, 10)  // sanity: wrapping happened
  }

  @MainActor
  func testEditDuringBackgroundBuildSettlesToTheFinalContent() async throws {
    let contents = (0..<9).map { "alpha beta gamma delta epsilon \($0)" }.joined(separator: "\n")
    let view = try makeBackgroundWrappingViewer(contents, width: 160)

    // Edit before the first build merges: the build restarts against the new
    // content and the splice keeps the interim geometry consistent.
    view.moveToDocumentEdge(end: true, extend: false)
    view.insertText("\nzz tail line that wraps around the narrow viewport too")

    await view.settleWrapBuildsForTesting()
    let reference = try makeWrappingViewer(content(of: view), width: 160)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testResizeDuringBackgroundBuildSettlesAtTheNewWidth() async throws {
    let contents = (0..<9).map { "alpha beta gamma delta epsilon \($0)" }.joined(separator: "\n")
    let view = try makeBackgroundWrappingViewer(contents, width: 400)

    // Resize while the 400pt build is still in flight: it is superseded and the
    // settled index must describe the new width.
    view.setFrameSize(NSSize(width: 160, height: 400))
    view.updateLayout()

    await view.settleWrapBuildsForTesting()
    let reference = try makeWrappingViewer(contents, width: 160)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testBackgroundBuildResolvesHugeLinesFromTheSnapshot() async throws {
    // A line past the display cap is grid-wrapped from its true length, which
    // the worker resolves through the immutable snapshot, not the live buffer.
    let huge = String(repeating: "h", count: 25_000)
    let contents = "short top\nmiddle\n\(huge)\nbottom"
    let view = try makeBackgroundWrappingViewer(contents, width: 400)

    await view.settleWrapBuildsForTesting()
    let reference = try makeWrappingViewer(contents, width: 400)
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
    XCTAssertGreaterThan(view.visualRowCount, 50)  // sanity: the huge line grid-wraps
  }

  @MainActor
  func testNonProseBackgroundScanStaysHorizontalWithoutALongLine() async throws {
    // Phase 1 of the background build scans for long lines without measuring;
    // a non-prose document with none must settle back to horizontal scroll.
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    view.wrapsLines = false
    view.longLineWrapThreshold = 20
    view.wrapBuildSynchronousLineLimit = 2
    view.wrapBuildChunkLineCount = 3
    view.setBuffer(try TextBuffer.open(bytes: Data("aa\nbb\ncc\ndd\nee".utf8)))

    await view.settleWrapBuildsForTesting()
    XCTAssertFalse(view.isSoftWrapping)
    XCTAssertEqual(view.visualRowCount, 5)
  }

  @MainActor
  func testNonProseBackgroundScanEntersWrapModeForALongLine() async throws {
    let long = String(repeating: "x", count: 25)
    let contents = "aa\nbb\n\(long)\ndd\nee"
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 140, height: 400)
    view.wrapsLines = false
    view.longLineWrapThreshold = 20
    view.wrapBuildSynchronousLineLimit = 2
    view.wrapBuildChunkLineCount = 2
    view.setBuffer(try TextBuffer.open(bytes: Data(contents.utf8)))

    await view.settleWrapBuildsForTesting()
    XCTAssertTrue(view.isSoftWrapping)

    let reference = LineRenderingTextView()
    reference.frame = NSRect(x: 0, y: 0, width: 140, height: 400)
    reference.wrapsLines = false
    reference.longLineWrapThreshold = 20
    reference.setBuffer(try TextBuffer.open(bytes: Data(contents.utf8)))
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
  }

  @MainActor
  func testReadOnlyDocumentBuildsItsWrapIndexInBackground() async throws {
    // The read-only path snapshots the buffer the same way; rows must match a
    // synchronous read-only reference.
    let contents = (0..<10)
      .map { "read only line \($0) with words enough to wrap at this width" }
      .joined(separator: "\n")
    let view = LineRenderingTextView()
    view.frame = NSRect(x: 0, y: 0, width: 160, height: 400)
    view.wrapBuildSynchronousLineLimit = 2
    view.wrapBuildChunkLineCount = 3
    view.setReadOnlyDocument(try TextBuffer.open(bytes: Data(contents.utf8)))

    await view.settleWrapBuildsForTesting()
    let reference = LineRenderingTextView()
    reference.frame = NSRect(x: 0, y: 0, width: 160, height: 400)
    reference.setReadOnlyDocument(try TextBuffer.open(bytes: Data(contents.utf8)))
    XCTAssertEqual(view.visualRowCount, reference.visualRowCount)
    XCTAssertGreaterThan(view.visualRowCount, 10)
  }

  @MainActor
  func testTeardownDuringBackgroundBuildDoesNotCrash() async throws {
    let contents = (0..<50)
      .map { "teardown line \($0) with words enough to wrap at this width" }
      .joined(separator: "\n")
    var view: LineRenderingTextView? = try makeBackgroundWrappingViewer(contents, width: 160)
    XCTAssertNotNil(view)
    view = nil  // drop the view while its first build is (likely) in flight

    // Give the orphaned worker time to run; absence of a crash is the assertion.
    try await Task.sleep(for: .milliseconds(100))
  }

  /// The whole buffer content, for round-trip assertions (terminators normalized
  /// to LF, matching the line-based buffer read).
  @MainActor
  private func content(of view: LineRenderingTextView) -> String {
    guard let buffer = view.editableBuffer else { return "" }
    return buffer.text(forLineRange: 0, count: buffer.lineCount)
  }
}
