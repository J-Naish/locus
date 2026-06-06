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
  func testRulerThicknessIsZeroWhenLineNumbersHidden() {
    // A hidden gutter must take no horizontal space so the document fills the
    // scroll view.
    let scrollView = NSScrollView()
    let textView = LineRenderingTextView()
    scrollView.documentView = textView
    let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)

    ruler.showsLineNumbers = false
    ruler.updateThickness()

    XCTAssertEqual(ruler.ruleThickness, 0)
  }

  @MainActor
  func testRulerThicknessMatchesGutterMetricsWhenShown() {
    // With line numbers shown the ruler reserves the gutter's metric width. An
    // empty buffer reports one line, so the width is the minimum.
    let scrollView = NSScrollView()
    let textView = LineRenderingTextView()
    scrollView.documentView = textView
    let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView)

    ruler.showsLineNumbers = true
    ruler.updateThickness()

    XCTAssertEqual(
      ruler.ruleThickness,
      GutterMetrics.width(lineCount: textView.lineCount, font: GutterMetrics.lineNumberFont)
    )
  }
}
