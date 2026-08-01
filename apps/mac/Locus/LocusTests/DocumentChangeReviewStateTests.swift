import AppKit
import XCTest

@testable import Locus

@MainActor
final class DocumentChangeReviewStateTests: XCTestCase {
  private let firstURL = URL(fileURLWithPath: "/tmp/locus-review-first.md")
  private let secondURL = URL(fileURLWithPath: "/tmp/locus-review-second.md")

  func testCaptureKeepsOriginalBaselineAcrossSuccessiveExternalChanges() {
    let state = DocumentChangeReviewState()
    state.selectDocument(firstURL)

    state.captureBaseline("original", for: firstURL)
    state.reconcileReloadedText("first rewrite", for: firstURL)
    state.captureBaseline("first rewrite", for: firstURL)
    state.reconcileReloadedText("second rewrite", for: firstURL)

    XCTAssertEqual(state.pendingBaseline(for: firstURL), "original")
    XCTAssertEqual(
      state.currentDiff?.rows,
      [
        DocumentDiffRow(kind: .removed, text: "original"),
        DocumentDiffRow(kind: .added, text: "second rewrite"),
      ])
  }

  func testReloadMatchingBaselineClearsPendingReview() {
    let state = DocumentChangeReviewState()
    state.selectDocument(firstURL)
    state.captureBaseline("same", for: firstURL)

    state.reconcileReloadedText("same", for: firstURL)

    XCTAssertFalse(state.hasPendingBaseline(for: firstURL))
    XCTAssertFalse(state.showsChip)
  }

  func testClosingOrDismissingClearsOnlyCurrentDocumentBaseline() {
    let state = DocumentChangeReviewState()
    state.captureBaseline("first", for: firstURL)
    state.captureBaseline("second", for: secondURL)
    state.selectDocument(firstURL)
    state.reconcileReloadedText("changed first", for: firstURL)
    state.presentReview()

    state.closeReview()

    XCTAssertFalse(state.hasPendingBaseline(for: firstURL))
    XCTAssertTrue(state.hasPendingBaseline(for: secondURL))

    state.selectDocument(secondURL)
    state.reconcileReloadedText("changed second", for: secondURL)
    state.dismissChip()

    XCTAssertFalse(state.hasPendingBaseline(for: secondURL))
  }

  func testUnsavedBufferTextIsCapturedInsteadOfDiskText() throws {
    let cache = OpenDocumentCache()
    let buffer = try TextBuffer.open(bytes: Data("disk text".utf8))
    cache.store(buffer: buffer, encoding: .utf8, fingerprint: nil, forKey: "document")
    try buffer.insert("unsaved ", atUTF16: 0)
    let state = DocumentChangeReviewState()

    state.captureBaseline(try XCTUnwrap(cache.currentText(forKey: "document")), for: firstURL)

    XCTAssertEqual(state.pendingBaseline(for: firstURL), "unsaved disk text")
  }

  func testReviewPresentationContainsCombinedRowsAndDecorationState() throws {
    let state = DocumentChangeReviewState()
    state.selectDocument(firstURL)
    state.captureBaseline("one\nold", for: firstURL)
    state.reconcileReloadedText("one\nnew", for: firstURL)

    state.presentReview()

    let presentation = try XCTUnwrap(state.presentation)
    XCTAssertEqual(presentation.text, "one\nold\nnew")
    XCTAssertEqual(presentation.rowKinds, [.common, .removed, .added])

    let view = LineRenderingTextView()
    view.setBuffer(presentation.buffer)
    view.setDocumentDiffRowKinds(presentation.rowKinds)
    XCTAssertEqual(view.documentDiffRowKindsForTesting, presentation.rowKinds)
    XCTAssertEqual(DocumentDiffDrawingMetrics.addedTintAlpha, 0.10)
    XCTAssertEqual(DocumentDiffDrawingMetrics.removedTintAlpha, 0.10)
    XCTAssertEqual(DocumentDiffDrawingMetrics.removedStrikeAlpha, 0.45)
    XCTAssertEqual(DocumentDiffDrawingMetrics.removedStrikeWidth, 1)
    XCTAssertTrue(view.documentDiffDecorationForTesting(at: 1).drawsStrike)
    XCTAssertFalse(view.documentDiffDecorationForTesting(at: 2).drawsStrike)
  }

  func testReviewIsReadOnlyAndLeavesEditableContentAndCaretUntouched() throws {
    let editableBuffer = try TextBuffer.open(bytes: Data("editable".utf8))
    let editableView = LineRenderingTextView()
    editableView.isEditable = true
    editableView.setBuffer(editableBuffer)
    editableView.beginCaretSelection(at: .init(line: 0, columnUTF16: 4))
    let originalSelection = editableView.selection

    let state = DocumentChangeReviewState()
    state.selectDocument(firstURL)
    state.captureBaseline("before", for: firstURL)
    state.reconcileReloadedText("after", for: firstURL)
    state.presentReview()
    let presentation = try XCTUnwrap(state.presentation)
    let reviewView = LineRenderingTextView()
    reviewView.isEditable = false
    reviewView.setBuffer(presentation.buffer)

    reviewView.insertText("ignored")
    state.closeReview()

    XCTAssertEqual(
      editableBuffer.text(forLineRange: 0, count: editableBuffer.lineCount),
      "editable")
    XCTAssertEqual(editableView.selection, originalSelection)
  }

  func testMarkdownReviewUsesCombinedMarkdownAndPlainTextReviewHidesGutter() throws {
    let state = DocumentChangeReviewState()
    state.selectDocument(firstURL)
    state.captureBaseline("# Old heading", for: firstURL)
    state.reconcileReloadedText("# New heading", for: firstURL)
    state.presentReview()
    let presentation = try XCTUnwrap(state.presentation)

    let markdownView = LineRenderingTextView()
    markdownView.syntax = .markdown
    markdownView.setBuffer(presentation.buffer)
    let removedHeading = markdownView.attributedLineForTesting(forLine: 0)
    let headingFont = try XCTUnwrap(
      removedHeading.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

    XCTAssertGreaterThan(headingFont.pointSize, TextDocumentSyntax.markdown.font.pointSize)
    XCTAssertFalse(
      TextViewportPresentation.resolvedLineNumberVisibility(
        syntax: .plainText,
        markdownViewMode: .rendered,
        backendIsReadOnly: false,
        override: false))
  }

  func testChipFlowPresentsAndClosesReview() {
    let state = DocumentChangeReviewState()
    state.selectDocument(firstURL)
    state.captureBaseline("before", for: firstURL)
    state.reconcileReloadedText("after", for: firstURL)

    XCTAssertTrue(state.showsChip)
    XCTAssertFalse(state.isReviewVisible)

    state.presentReview()

    XCTAssertTrue(state.isReviewVisible)
    XCTAssertNotNil(state.presentation)

    state.closeReview()

    XCTAssertFalse(state.isReviewVisible)
    XCTAssertFalse(state.showsChip)
    XCTAssertFalse(state.hasPendingBaseline(for: firstURL))
  }

  func testVisibleReviewRefreshesAfterAnotherExternalChange() throws {
    let state = DocumentChangeReviewState()
    state.selectDocument(firstURL)
    state.captureBaseline("same\nbefore", for: firstURL)
    state.reconcileReloadedText("same\nfirst", for: firstURL)
    state.presentReview()

    state.reconcileReloadedText("same\nsecond", for: firstURL)

    XCTAssertTrue(state.isReviewVisible)
    let presentation = try XCTUnwrap(state.presentation)
    XCTAssertEqual(presentation.text, "same\nbefore\nsecond")
    XCTAssertEqual(presentation.rowKinds, [.common, .removed, .added])
  }
}
