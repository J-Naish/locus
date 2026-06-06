import AppKit
import CoreText
import SwiftUI

/// Pure geometry for a uniform-line-height virtualized text view: it maps
/// between scroll offsets and line indices so only the visible band is drawn.
/// Kept free of AppKit state so it is unit-testable without a window.
struct TextViewportLayout: Equatable {
  /// Height of one line in points. Must be positive.
  let lineHeight: CGFloat

  /// Total document height for `lineCount` lines. An empty buffer still has one
  /// (empty) line, so the height is never zero for a valid buffer.
  func contentHeight(lineCount: Int) -> CGFloat {
    CGFloat(max(lineCount, 1)) * lineHeight
  }

  /// The y offset of the top of `line`.
  func yOffset(forLine line: Int) -> CGFloat {
    CGFloat(line) * lineHeight
  }

  /// The half-open range of line indices that intersect `rect`, clamped to
  /// `[0, lineCount)`. Returns an empty range when nothing is visible.
  func visibleLineRange(in rect: CGRect, lineCount: Int) -> Range<Int> {
    guard lineCount > 0, lineHeight > 0, rect.height > 0 else {
      return 0..<0
    }
    let first = max(0, Int((rect.minY / lineHeight).rounded(.down)))
    let last = min(lineCount, Int((rect.maxY / lineHeight).rounded(.up)))
    guard first < last else {
      return 0..<0
    }
    return first..<last
  }
}

/// A text selection (or caret, when empty) as two endpoints in line/UTF-16-column
/// coordinates. `anchor` is the fixed end set when the gesture began; `head` is
/// the moving end the caret follows. Kept free of AppKit state so the ordering
/// and per-line span logic are unit-testable.
struct TextSelection: Equatable {
  struct Endpoint: Equatable, Comparable {
    var line: Int
    var columnUTF16: Int

    static func < (lhs: Endpoint, rhs: Endpoint) -> Bool {
      (lhs.line, lhs.columnUTF16) < (rhs.line, rhs.columnUTF16)
    }
  }

  var anchor: Endpoint
  var head: Endpoint

  init(anchor: Endpoint, head: Endpoint) {
    self.anchor = anchor
    self.head = head
  }

  /// A zero-length selection (caret) at a single endpoint.
  init(caretAt endpoint: Endpoint) {
    self.anchor = endpoint
    self.head = endpoint
  }

  var isEmpty: Bool { anchor == head }
  /// The earlier endpoint in document order.
  var start: Endpoint { Swift.min(anchor, head) }
  /// The later endpoint in document order.
  var end: Endpoint { Swift.max(anchor, head) }

  /// The half-open UTF-16 column span `[start, end)` selected on `line`, or `nil`
  /// when the line lies outside the selection. A line fully spanned by a
  /// multi-line selection reports `lineLengthUTF16` as its end so the highlight
  /// can extend to (and past) the line's last character.
  func columnSpan(onLine line: Int, lineLengthUTF16: Int) -> (start: Int, end: Int)? {
    guard !isEmpty else {
      return nil
    }
    let lower = start
    let upper = end
    guard line >= lower.line, line <= upper.line else {
      return nil
    }
    let startColumn = line == lower.line ? lower.columnUTF16 : 0
    let endColumn = line == upper.line ? upper.columnUTF16 : lineLengthUTF16
    return (startColumn, endColumn)
  }
}

/// Custom flipped `NSView` document view that draws only the visible band of a
/// [`TextBuffer`], fetching that band from the Rust core on demand. The document
/// height is synthesized from the line count, so a multi-gigabyte file never has
/// its text assembled in memory — scrolling redraws exposed bands. Lines are not
/// wrapped; the view widens to the widest line it has drawn.
final class LineRenderingTextView: NSView {
  private(set) var buffer: TextBuffer?
  let layout: TextViewportLayout
  private let font: NSFont
  private let horizontalPadding: CGFloat = 8
  /// Extra width past the widest line so the last character is not flush against
  /// the right edge when scrolled fully right.
  private let trailingContentMargin: CGFloat = 40
  private let viewportBackgroundColor: NSColor = .textBackgroundColor

  // Line-number gutter, drawn by this view (pinned to the left of the viewport,
  // text laid out to its right). Earlier sibling and `NSRulerView` arrangements
  // had compositing issues in the SwiftUI layer-backed host (blank document, or a
  // gutter that overlapped the text), so the gutter is drawn here in the same
  // pass as the text instead.
  var showsLineNumbers = true {
    didSet {
      guard showsLineNumbers != oldValue else { return }
      updateLayout()
      invalidateVisibleArea()
    }
  }
  private let gutterFont = GutterMetrics.lineNumberFont
  private let gutterTextColor: NSColor = .secondaryLabelColor
  private let gutterSeparatorColor: NSColor = .separatorColor

  var syntax: TextDocumentSyntax = .plainText {
    didSet {
      guard syntax != oldValue else { return }
      cachedBand = nil
      invalidateVisibleArea()
    }
  }

  /// Whether the viewer accepts edits. Read-only entries (and the not-yet-saved
  /// large-file path before its save story exists) keep this false; the host
  /// enables it for writable text. Editing is routed to the Rust buffer; saving
  /// is a later slice, so edits are in-memory until then.
  var isEditable = false

  /// Bytes fetched per line for the visible band; longer lines are truncated for
  /// the fetch so one enormous line never crosses the FFI in full.
  private let maximumFetchedBytesPerLine = 16_384
  /// Characters actually drawn per line. Lines longer than this are clipped for
  /// display (this is a read-only viewer, not a full horizontal renderer), which
  /// also bounds the document's width. Selection and copy use the same clipped
  /// text, so all three share one coordinate system.
  private let maximumDrawnCharactersPerLine = 5_000
  /// Upper bound on how many bytes one copy may materialize. Cmd+A (or a huge
  /// drag) on a multi-gigabyte file must not build a giant string on the main
  /// thread, so an over-budget copy is refused (with a beep) rather than risking
  /// an out-of-memory freeze. Internal so tests can lower it. A future
  /// range-snapshot FFI could stream instead of materializing.
  var maximumCopiedByteCount = 256 * 1024 * 1024
  /// Much lower bound for the selection text handed to assistive technology, which
  /// may poll it repeatedly. Over this, accessibility reports no selected text.
  var maximumAccessibilitySelectedTextByteCount = 1 * 1024 * 1024
  private var cachedBand: (revision: UInt64, range: Range<Int>, lines: [NSAttributedString])?
  private var maxObservedLineWidth: CGFloat = 0
  private var pendingLayoutUpdate = false

  // Read-only selection / caret. The view owns this state (it is not an
  // NSTextView), maps clicks to (line, UTF-16 column) endpoints, draws the
  // highlight and caret, and copies the selected text on demand.
  private(set) var selection: TextSelection?
  private var isSelecting = false
  /// Extra highlight width drawn past a fully selected line to signal that the
  /// line's trailing newline is part of the selection.
  private let newlineSelectionWidth: CGFloat = 6
  /// Horizontal margin kept around the caret when scrolling it into view.
  private let caretScrollMargin: CGFloat = 8
  /// Smallest horizontal scroll change that counts as a horizontal scroll (and so
  /// triggers a gutter repaint); below this is treated as a pure vertical scroll.
  private let horizontalScrollEpsilon: CGFloat = 0.01
  /// Preferred horizontal offset (text-relative) the caret keeps while moving up
  /// or down, so vertical motion does not drift in/out on short lines. Reset by
  /// any non-vertical move.
  private var verticalGoalX: CGFloat?
  /// Last seen horizontal scroll offset, to detect horizontal scrolling (which
  /// requires repainting the pinned gutter) versus vertical scrolling (handled by
  /// copy-on-scroll).
  private var lastHorizontalOffset: CGFloat = 0

  /// In-progress input-method composition (marked text). The uncommitted text is
  /// held here and drawn inline at `anchor`; it is not written to the buffer
  /// until the input method commits it. `nil` when not composing.
  private struct Composition {
    var text: String
    /// The input method's cursor/selection within `text`, in UTF-16.
    var selectedRange: NSRange
    /// The buffer caret (line, UTF-16 column) the marked text is anchored at.
    var anchor: TextSelection.Endpoint
  }
  private var composition: Composition?

  var lineCount: Int { buffer?.lineCount ?? 1 }

  /// Width of the line-number gutter for the current line count, or 0 when hidden.
  var gutterWidth: CGFloat {
    showsLineNumbers ? GutterMetrics.width(lineCount: lineCount, font: gutterFont) : 0
  }

  init() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    self.font = font
    self.layout = TextViewportLayout(
      lineHeight: ceil(font.ascender - font.descender + font.leading))
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override var isFlipped: Bool { true }

  func setBuffer(_ buffer: TextBuffer?) {
    self.buffer = buffer
    cachedBand = nil
    maxObservedLineWidth = 0
    selection = nil
    isSelecting = false
    verticalGoalX = nil
    lastHorizontalOffset = 0
    composition = nil
    updateLayout()
    // A new document always opens at the top-left; otherwise a reused scroll view
    // would keep the previous file's scroll position.
    if let scrollView = enclosingScrollView {
      scrollView.contentView.scroll(to: .zero)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    invalidateVisibleArea()
  }

  /// Marks only the visible portion for redisplay. Invalidating the whole view
  /// would make the dirty rect — and the band fetched to satisfy it — span the
  /// entire (potentially multi-million-point) document.
  func invalidateVisibleArea() {
    setNeedsDisplay(visibleRect)
  }

  /// Called when the clip view scrolls. Vertical scrolling is left to
  /// copy-on-scroll (cheap); only a change in the horizontal offset forces a
  /// repaint, to re-pin the gutter and caret at the new offset.
  func viewportDidScroll() {
    let offsetX = enclosingScrollView?.contentView.bounds.origin.x ?? 0
    guard abs(offsetX - lastHorizontalOffset) > horizontalScrollEpsilon else { return }
    lastHorizontalOffset = offsetX
    invalidateVisibleArea()
  }

  // MARK: Accessibility

  // Expose the viewer as a text area so it resolves to `textViews` (matching the
  // editable editor) for XCUITest and is announced as a text region. The value is
  // deliberately *not* the whole document — it could be gigabytes — so only the
  // bounded selected text is exposed (for copy). Full VoiceOver text-range reading
  // of the body is a later accessibility pass.

  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

  override func isAccessibilityElement() -> Bool { buffer != nil }

  override func accessibilityValue() -> Any? { nil }

  override func accessibilitySelectedText() -> String? {
    // Assistive tech may poll this repeatedly, so bound it well below the (much
    // larger) explicit-copy limit; an over-budget selection reports no text.
    guard let span = selectionByteSpan(), span <= maximumAccessibilitySelectedTextByteCount else {
      return nil
    }
    return selectedText()
  }

  override func accessibilityNumberOfCharacters() -> Int { buffer?.utf16Length ?? 0 }

  // MARK: First responder & focus

  override var acceptsFirstResponder: Bool { buffer != nil }

  override func becomeFirstResponder() -> Bool {
    let didBecome = super.becomeFirstResponder()
    if didBecome { invalidateVisibleArea() }
    return didBecome
  }

  override func resignFirstResponder() -> Bool {
    let didResign = super.resignFirstResponder()
    if didResign {
      // Abandon any in-progress composition rather than committing it on a focus
      // change; the input context deactivates with the responder.
      composition = nil
      invalidateVisibleArea()
    }
    return didResign
  }

  // MARK: Mouse selection

  override func mouseDown(with event: NSEvent) {
    guard buffer != nil else { return }
    // Finalize any in-progress composition before moving the caret.
    if hasMarkedText() { unmarkText() }
    window?.makeFirstResponder(self)
    let endpoint = endpoint(at: convert(event.locationInWindow, from: nil))
    selection = TextSelection(caretAt: endpoint)
    isSelecting = true
    invalidateVisibleArea()
  }

  override func mouseDragged(with event: NSEvent) {
    guard isSelecting, selection != nil else { return }
    autoscroll(with: event)
    selection?.head = endpoint(at: convert(event.locationInWindow, from: nil))
    invalidateVisibleArea()
  }

  override func mouseUp(with event: NSEvent) {
    isSelecting = false
  }

  /// Maps a point in this view's coordinates to the nearest (line, UTF-16 column)
  /// endpoint, clamped to the document.
  private func endpoint(at point: NSPoint) -> TextSelection.Endpoint {
    let lastLine = max(0, lineCount - 1)
    let line = min(lastLine, max(0, Int((point.y / layout.lineHeight).rounded(.down))))
    let column = columnUTF16(forX: point.x - (gutterWidth + horizontalPadding), in: line)
    return TextSelection.Endpoint(line: line, columnUTF16: column)
  }

  // MARK: Selection commands

  override func selectAll(_ sender: Any?) {
    guard let buffer, buffer.lineCount > 0 else { return }
    let lastLine = buffer.lineCount - 1
    selection = TextSelection(
      anchor: .init(line: 0, columnUTF16: 0),
      head: .init(line: lastLine, columnUTF16: lineLengthUTF16(lastLine))
    )
    invalidateVisibleArea()
  }

  @objc func copy(_ sender: Any?) {
    guard let text = selectedText(), !text.isEmpty else { return }
    ClipboardService().copyPlainText(text)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Only act while focused; otherwise let the focused responder (e.g. the
    // editable editor) handle the shortcut.
    guard window?.firstResponder === self,
      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      let key = event.charactersIgnoringModifiers
    else {
      return super.performKeyEquivalent(with: event)
    }
    switch key {
    case "a":
      selectAll(nil)
      return true
    case "c":
      copy(nil)
      return true
    default:
      return super.performKeyEquivalent(with: event)
    }
  }

  /// The selected text for copying. Returns `nil` for an empty/absent selection,
  /// or when the selection is larger than `maximumCopiedByteCount` (in which case
  /// it beeps rather than materializing a giant string on the main thread).
  ///
  /// The selection operates on the same clipped per-line text the view displays
  /// (`maximumDrawnCharactersPerLine`), so what is copied matches what is shown
  /// and selectable. Line terminators are normalized to LF — the view is
  /// line-based and does not retain original terminators (a CRLF file copies with
  /// LF); preserving them would require a terminator-aware range snapshot.
  func selectedText() -> String? {
    guard buffer != nil, let selection, !selection.isEmpty else {
      return nil
    }
    if let span = selectionByteSpan(), span > maximumCopiedByteCount {
      NSSound.beep()
      return nil
    }

    let lower = selection.start
    let upper = selection.end
    let count = upper.line - lower.line + 1
    var lines = displayLineStrings(forLineRange: lower.line, count: count)
    guard !lines.isEmpty else {
      return ""
    }

    if lines.count == 1 {
      let line = lines[0] as NSString
      let from = min(lower.columnUTF16, line.length)
      let to = min(upper.columnUTF16, line.length)
      guard to > from else { return "" }
      return line.substring(with: NSRange(location: from, length: to - from))
    }

    let first = lines[0] as NSString
    lines[0] = first.substring(from: min(lower.columnUTF16, first.length))
    let last = lines[lines.count - 1] as NSString
    lines[lines.count - 1] = last.substring(to: min(upper.columnUTF16, last.length))
    return lines.joined(separator: "\n")
  }

  /// Byte length of the current selection, computed cheaply from its endpoints'
  /// positions, or `nil` when there is no selection or a position lookup fails.
  /// Used to bound how much text copy and accessibility will materialize.
  private func selectionByteSpan() -> Int? {
    guard let buffer, let selection, !selection.isEmpty,
      let startByte =
        (try? buffer.position(
          forLine: selection.start.line, columnUTF16: selection.start.columnUTF16))?.byte,
      let endByte =
        (try? buffer.position(
          forLine: selection.end.line, columnUTF16: selection.end.columnUTF16))?.byte
    else {
      return nil
    }
    return endByte - startByte
  }

  // MARK: Key input

  // Key events are routed through the input context so input methods (CJK IME,
  // dead keys, accents, dictation) drive `insertText`/`setMarkedText`, and
  // navigation/editing arrive as `doCommand(by:)` selectors. This keeps input
  // generic across every language the OS supports rather than hardcoding keys.
  override func keyDown(with event: NSEvent) {
    guard buffer != nil else {
      super.keyDown(with: event)
      return
    }
    interpretKeyEvents([event])
  }

  /// Standard key-binding commands from `interpretKeyEvents`. Navigation works in
  /// both read-only and editable modes; editing commands no-op when read-only
  /// (their handlers guard on `isEditable`). Unhandled commands are ignored
  /// without a beep — self-inserting text arrives via `insertText`, not here.
  override func doCommand(by selector: Selector) {
    switch selector {
    case #selector(NSStandardKeyBindingResponding.moveLeft(_:)):
      moveHorizontally(forward: false, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveRight(_:)):
      moveHorizontally(forward: true, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveLeftAndModifySelection(_:)):
      moveHorizontally(forward: false, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveRightAndModifySelection(_:)):
      moveHorizontally(forward: true, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveUp(_:)):
      moveVertically(down: false, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveDown(_:)):
      moveVertically(down: true, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveUpAndModifySelection(_:)):
      moveVertically(down: false, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveDownAndModifySelection(_:)):
      moveVertically(down: true, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveWordLeft(_:)),
      #selector(NSStandardKeyBindingResponding.moveWordBackward(_:)):
      moveByWord(forward: false, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveWordRight(_:)),
      #selector(NSStandardKeyBindingResponding.moveWordForward(_:)):
      moveByWord(forward: true, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveWordLeftAndModifySelection(_:)),
      #selector(NSStandardKeyBindingResponding.moveWordBackwardAndModifySelection(_:)):
      moveByWord(forward: false, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveWordRightAndModifySelection(_:)),
      #selector(NSStandardKeyBindingResponding.moveWordForwardAndModifySelection(_:)):
      moveByWord(forward: true, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveToLeftEndOfLine(_:)),
      #selector(NSStandardKeyBindingResponding.moveToBeginningOfLine(_:)):
      moveToLineEdge(end: false, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveToRightEndOfLine(_:)),
      #selector(NSStandardKeyBindingResponding.moveToEndOfLine(_:)):
      moveToLineEdge(end: true, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveToLeftEndOfLineAndModifySelection(_:)),
      #selector(NSStandardKeyBindingResponding.moveToBeginningOfLineAndModifySelection(_:)):
      moveToLineEdge(end: false, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveToRightEndOfLineAndModifySelection(_:)),
      #selector(NSStandardKeyBindingResponding.moveToEndOfLineAndModifySelection(_:)):
      moveToLineEdge(end: true, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveToBeginningOfDocument(_:)):
      moveToDocumentEdge(end: false, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveToEndOfDocument(_:)):
      moveToDocumentEdge(end: true, extend: false)
    case #selector(NSStandardKeyBindingResponding.moveToBeginningOfDocumentAndModifySelection(_:)):
      moveToDocumentEdge(end: false, extend: true)
    case #selector(NSStandardKeyBindingResponding.moveToEndOfDocumentAndModifySelection(_:)):
      moveToDocumentEdge(end: true, extend: true)
    case #selector(NSStandardKeyBindingResponding.insertNewline(_:)),
      #selector(NSStandardKeyBindingResponding.insertLineBreak(_:)),
      #selector(NSStandardKeyBindingResponding.insertParagraphSeparator(_:)):
      insertText("\n")
    case #selector(NSStandardKeyBindingResponding.insertTab(_:)):
      insertText("\t")
    case #selector(NSStandardKeyBindingResponding.deleteBackward(_:)):
      deleteBackward()
    case #selector(NSStandardKeyBindingResponding.deleteForward(_:)):
      deleteForward()
    case #selector(NSStandardKeyBindingResponding.deleteWordBackward(_:)):
      deleteWordBackward()
    case #selector(NSStandardKeyBindingResponding.deleteWordForward(_:)):
      deleteWordForward()
    case #selector(NSResponder.selectAll(_:)):
      selectAll(nil)
    default:
      break
    }
  }

  /// The caret/extension origin, defaulting to the document start when nothing is
  /// selected yet so the keys work before the first click.
  private var navigationHead: TextSelection.Endpoint {
    selection?.head ?? TextSelection.Endpoint(line: 0, columnUTF16: 0)
  }

  private func applyMovedHead(
    _ newHead: TextSelection.Endpoint, extend: Bool, keepGoalX: Bool = false
  ) {
    if !keepGoalX { verticalGoalX = nil }
    if extend, let current = selection {
      selection = TextSelection(anchor: current.anchor, head: newHead)
    } else {
      selection = TextSelection(caretAt: newHead)
    }
    scrollCaretToVisible(newHead)
    invalidateVisibleArea()
  }

  func moveHorizontally(forward: Bool, extend: Bool) {
    if !extend, let current = selection, !current.isEmpty {
      applyMovedHead(forward ? current.end : current.start, extend: false)
      return
    }
    applyMovedHead(steppedCharacterEndpoint(from: navigationHead, forward: forward), extend: extend)
  }

  func moveByWord(forward: Bool, extend: Bool) {
    // Match `moveHorizontally`: a non-extending move with an existing selection
    // starts from the directional edge, not the head (which may be the trailing
    // end of a reversed selection), then steps one word.
    let origin: TextSelection.Endpoint
    if !extend, let current = selection, !current.isEmpty {
      origin = forward ? current.end : current.start
    } else {
      origin = navigationHead
    }
    applyMovedHead(steppedWordEndpoint(from: origin, forward: forward), extend: extend)
  }

  func moveToLineEdge(end: Bool, extend: Bool) {
    let head = navigationHead
    applyMovedHead(
      TextSelection.Endpoint(line: head.line, columnUTF16: end ? lineLengthUTF16(head.line) : 0),
      extend: extend)
  }

  func moveToDocumentEdge(end: Bool, extend: Bool) {
    let line = end ? max(0, lineCount - 1) : 0
    applyMovedHead(
      TextSelection.Endpoint(line: line, columnUTF16: end ? lineLengthUTF16(line) : 0),
      extend: extend)
  }

  func moveVertically(down: Bool, extend: Bool) {
    let head = navigationHead
    let goalX = verticalGoalX ?? caretX(for: head)
    let targetLine = down ? min(head.line + 1, max(0, lineCount - 1)) : max(head.line - 1, 0)
    let newHead: TextSelection.Endpoint
    if targetLine == head.line {
      // Already at the first/last line: go to its start/end instead.
      newHead = TextSelection.Endpoint(
        line: head.line, columnUTF16: down ? lineLengthUTF16(head.line) : 0)
    } else {
      newHead = TextSelection.Endpoint(
        line: targetLine, columnUTF16: columnUTF16(forX: goalX, in: targetLine))
    }
    applyMovedHead(newHead, extend: extend, keepGoalX: true)
    verticalGoalX = goalX
  }

  /// One composed-character step left/right, wrapping across line boundaries.
  private func steppedCharacterEndpoint(from endpoint: TextSelection.Endpoint, forward: Bool)
    -> TextSelection.Endpoint
  {
    let line = attributedLine(forLine: endpoint.line).string as NSString
    if forward {
      if endpoint.columnUTF16 < line.length {
        let range = line.rangeOfComposedCharacterSequence(at: endpoint.columnUTF16)
        return .init(line: endpoint.line, columnUTF16: NSMaxRange(range))
      }
      if endpoint.line < lineCount - 1 { return .init(line: endpoint.line + 1, columnUTF16: 0) }
      return endpoint
    }
    if endpoint.columnUTF16 > 0 {
      let range = line.rangeOfComposedCharacterSequence(at: endpoint.columnUTF16 - 1)
      return .init(line: endpoint.line, columnUTF16: range.location)
    }
    if endpoint.line > 0 {
      return .init(line: endpoint.line - 1, columnUTF16: lineLengthUTF16(endpoint.line - 1))
    }
    return endpoint
  }

  /// One word step, advancing by whole composed character sequences (so the caret
  /// never lands inside a surrogate pair, emoji, or combining sequence) using a
  /// simple alphanumeric-run heuristic. Wraps across line boundaries at the ends.
  private func steppedWordEndpoint(from endpoint: TextSelection.Endpoint, forward: Bool)
    -> TextSelection.Endpoint
  {
    let line = attributedLine(forLine: endpoint.line).string as NSString
    // Classify the composed character that begins at `index` (a valid boundary).
    func isWordCharacter(at index: Int) -> Bool {
      let range = line.rangeOfComposedCharacterSequence(at: index)
      guard let scalar = line.substring(with: range).unicodeScalars.first else { return false }
      return CharacterSet.alphanumerics.contains(scalar)
    }
    func boundary(after index: Int) -> Int {
      NSMaxRange(line.rangeOfComposedCharacterSequence(at: index))
    }
    func boundary(before index: Int) -> Int {
      line.rangeOfComposedCharacterSequence(at: index - 1).location
    }

    if forward {
      var index = endpoint.columnUTF16
      if index >= line.length {
        return endpoint.line < lineCount - 1
          ? .init(line: endpoint.line + 1, columnUTF16: 0) : endpoint
      }
      while index < line.length, !isWordCharacter(at: index) { index = boundary(after: index) }
      while index < line.length, isWordCharacter(at: index) { index = boundary(after: index) }
      return .init(line: endpoint.line, columnUTF16: index)
    }

    var index = endpoint.columnUTF16
    if index <= 0 {
      return endpoint.line > 0
        ? .init(line: endpoint.line - 1, columnUTF16: lineLengthUTF16(endpoint.line - 1)) : endpoint
    }
    while index > 0, !isWordCharacter(at: boundary(before: index)) {
      index = boundary(before: index)
    }
    while index > 0, isWordCharacter(at: boundary(before: index)) {
      index = boundary(before: index)
    }
    return .init(line: endpoint.line, columnUTF16: index)
  }

  // MARK: Editing

  // Basic insert/delete routed to the Rust buffer. Endpoints (line, UTF-16
  // column) are mapped to global UTF-16 offsets via the buffer's position
  // lookups, so a multi-gigabyte file never has its text assembled to edit it.
  // Composition (IME), undo/redo, and cut/paste are later slices; these methods
  // are the shared primitives those will build on.

  /// Inserts `string`, replacing the current selection if any, and leaves the
  /// caret after the inserted text. A no-op when read-only, empty, or absent.
  ///
  /// A selection replace is two buffer ops (delete then insert). To keep it
  /// atomic, a failed insert rolls the delete back via the buffer's own undo so
  /// the selected text is never silently lost. (A single coalesced `replace`
  /// also matters for undo granularity and is a later slice.)
  func insertText(_ string: String) {
    guard isEditable, !string.isEmpty, let range = currentSelectionUTF16Range() else {
      return
    }
    replace(globalStart: range.start, globalEnd: range.end, with: string)
  }

  /// Replaces the global UTF-16 range `[start, end)` with `string`, leaving the
  /// caret after the inserted text. The two ops (delete then insert) are kept
  /// atomic: a failed insert rolls the delete back via the buffer's undo so text
  /// is never silently lost.
  private func replace(globalStart start: Int, globalEnd end: Int, with string: String) {
    guard let buffer else { return }
    let deleting = end > start
    if deleting {
      do {
        try buffer.delete(fromUTF16: start, toUTF16: end)
      } catch {
        NSSound.beep()
        return
      }
    }
    if !string.isEmpty {
      do {
        try buffer.insert(string, atUTF16: start)
      } catch {
        if deleting {
          _ = try? buffer.undo()  // restore the just-deleted range
        }
        NSSound.beep()
        finishEdit(caretUTF16: start)
        return
      }
    }
    finishEdit(caretUTF16: start + (string as NSString).length)
  }

  /// Deletes the selection, or one composed character before the caret (merging
  /// lines at a line start). A no-op at the document start.
  func deleteBackward() {
    guard isEditable, buffer != nil else { return }
    if let selection, !selection.isEmpty {
      deleteRange(from: selection.start, to: selection.end)
      return
    }
    let caret = navigationHead
    let previous = steppedCharacterEndpoint(from: caret, forward: false)
    guard previous != caret else { return }
    deleteRange(from: previous, to: caret)
  }

  /// Deletes the selection, or one composed character after the caret (merging
  /// the next line at a line end). A no-op at the document end.
  func deleteForward() {
    guard isEditable, buffer != nil else { return }
    if let selection, !selection.isEmpty {
      deleteRange(from: selection.start, to: selection.end)
      return
    }
    let caret = navigationHead
    let next = steppedCharacterEndpoint(from: caret, forward: true)
    guard next != caret else { return }
    deleteRange(from: caret, to: next)
  }

  /// Deletes the selection, or from the previous word boundary to the caret.
  func deleteWordBackward() {
    guard isEditable, buffer != nil else { return }
    if let selection, !selection.isEmpty {
      deleteRange(from: selection.start, to: selection.end)
      return
    }
    let caret = navigationHead
    let previous = steppedWordEndpoint(from: caret, forward: false)
    guard previous != caret else { return }
    deleteRange(from: previous, to: caret)
  }

  /// Deletes the selection, or from the caret to the next word boundary.
  func deleteWordForward() {
    guard isEditable, buffer != nil else { return }
    if let selection, !selection.isEmpty {
      deleteRange(from: selection.start, to: selection.end)
      return
    }
    let caret = navigationHead
    let next = steppedWordEndpoint(from: caret, forward: true)
    guard next != caret else { return }
    deleteRange(from: caret, to: next)
  }

  /// Deletes the UTF-16 range between two endpoints and collapses the caret to
  /// the start. Endpoints must already be ordered (`from` before `to`).
  private func deleteRange(from start: TextSelection.Endpoint, to end: TextSelection.Endpoint) {
    guard let buffer, let startOffset = utf16Offset(of: start),
      let endOffset = utf16Offset(of: end), endOffset > startOffset
    else {
      return
    }
    do {
      try buffer.delete(fromUTF16: startOffset, toUTF16: endOffset)
      finishEdit(caretUTF16: startOffset)
    } catch {
      NSSound.beep()
    }
  }

  /// The current selection as a global UTF-16 range, or a zero-length range at
  /// the caret when nothing is selected. `nil` only if a position lookup fails.
  private func currentSelectionUTF16Range() -> (start: Int, end: Int)? {
    let selection = self.selection ?? TextSelection(caretAt: navigationHead)
    guard let start = utf16Offset(of: selection.start), let end = utf16Offset(of: selection.end)
    else {
      return nil
    }
    return (start, end)
  }

  /// The global UTF-16 offset of a (line, column) endpoint, or `nil` if the
  /// buffer is absent or the lookup fails.
  private func utf16Offset(of endpoint: TextSelection.Endpoint) -> Int? {
    guard let buffer else { return nil }
    return (try? buffer.position(forLine: endpoint.line, columnUTF16: endpoint.columnUTF16))?.utf16
  }

  /// Shared post-edit refresh: places the caret at `offset`, drops cached band
  /// and geometry (the buffer revision changed), re-measures the document, and
  /// repaints the visible band.
  private func finishEdit(caretUTF16 offset: Int) {
    cachedBand = nil
    verticalGoalX = nil
    // The widest-line high-water mark can only shrink via an edit (deleting or
    // splitting a long line), so reset it and let `draw` re-measure the visible
    // band rather than keeping a stale, too-wide horizontal extent.
    maxObservedLineWidth = 0
    if let buffer, let position = try? buffer.position(forUTF16: offset) {
      selection = TextSelection(
        caretAt: .init(line: position.line, columnUTF16: position.columnUTF16))
    }
    updateLayout()
    if let head = selection?.head {
      scrollCaretToVisible(head)
    }
    invalidateVisibleArea()
  }

  /// Text-relative x of the caret at `endpoint`.
  private func caretX(for endpoint: TextSelection.Endpoint) -> CGFloat {
    xOffset(forColumn: endpoint.columnUTF16, in: attributedLine(forLine: endpoint.line))
  }

  private func scrollCaretToVisible(_ endpoint: TextSelection.Endpoint) {
    let x = gutterWidth + horizontalPadding + caretX(for: endpoint)
    let rect = NSRect(
      x: x - caretScrollMargin,
      y: layout.yOffset(forLine: endpoint.line),
      width: caretScrollMargin * 2,
      height: layout.lineHeight)
    scrollToVisible(rect)
  }

  /// Resizes the document to fit the line count (height) and the widest line seen
  /// so far (width), but never narrower than the visible content area. The width
  /// follows the widest drawn line, which is bounded by
  /// `maximumDrawnCharactersPerLine`; the scroll view only backs the visible
  /// region, so a tall/wide document does not allocate a full-size layer.
  func updateLayout() {
    let visibleWidth = enclosingScrollView?.documentVisibleRect.width ?? frame.width
    let contentWidth =
      gutterWidth + horizontalPadding + maxObservedLineWidth + trailingContentMargin
    let width = max(visibleWidth, contentWidth)
    setFrameSize(NSSize(width: width, height: layout.contentHeight(lineCount: lineCount)))
  }

  private func attributedBandLines(for buffer: TextBuffer, range: Range<Int>)
    -> [NSAttributedString]
  {
    let revision = buffer.revision
    if let cachedBand, cachedBand.revision == revision, cachedBand.range == range {
      return cachedBand.lines
    }
    let lines = buffer.text(
      forLineRange: range.lowerBound, count: range.count,
      maxBytesPerLine: maximumFetchedBytesPerLine
    )
    .components(separatedBy: "\n")
    .map(highlightedLine)
    cachedBand = (revision, range, lines)
    return lines
  }

  /// A single line clipped to the displayed character limit. Display, selection,
  /// and copy all go through this so they share one coordinate system.
  private func clippedDisplayLine(_ line: String) -> String {
    line.count > maximumDrawnCharactersPerLine
      ? String(line.prefix(maximumDrawnCharactersPerLine))
      : line
  }

  /// The clipped plain text of lines `[start, start + count)`, matching what the
  /// view displays. Used by copy so the copied text equals the selectable text.
  private func displayLineStrings(forLineRange start: Int, count: Int) -> [String] {
    guard let buffer else { return [] }
    return
      buffer.text(forLineRange: start, count: count, maxBytesPerLine: maximumFetchedBytesPerLine)
      .components(separatedBy: "\n")
      .map(clippedDisplayLine)
  }

  private func highlightedLine(_ line: String) -> NSAttributedString {
    let visible = clippedDisplayLine(line)
    let attributed = NSMutableAttributedString(string: visible)
    let fullRange = NSRange(location: 0, length: (visible as NSString).length)
    TextDocumentSyntaxHighlighter.apply(
      to: attributed, text: visible, syntax: syntax, font: font, range: fullRange)
    attributed.addAttribute(.font, value: font, range: fullRange)
    return attributed
  }

  // MARK: Line geometry (selection / caret hit-testing)

  /// The displayed (highlighted, possibly truncated) attributed string for a
  /// line, reusing the cached band when the line falls within it.
  private func attributedLine(forLine line: Int) -> NSAttributedString {
    if let cachedBand, cachedBand.range.contains(line) {
      return cachedBand.lines[line - cachedBand.range.lowerBound]
    }
    guard let buffer else { return NSAttributedString() }
    let text =
      buffer.text(forLineRange: line, count: 1, maxBytesPerLine: maximumFetchedBytesPerLine)
      .components(separatedBy: "\n").first ?? ""
    return highlightedLine(text)
  }

  private func lineLengthUTF16(_ line: Int) -> Int {
    attributedLine(forLine: line).length
  }

  /// UTF-16 column at horizontal offset `x` (relative to the text's left edge)
  /// within `line`, clamped to the line.
  private func columnUTF16(forX x: CGFloat, in line: Int) -> Int {
    let attributed = attributedLine(forLine: line)
    guard x > 0, attributed.length > 0 else { return 0 }
    let ctLine = CTLineCreateWithAttributedString(attributed)
    let index = CTLineGetStringIndexForPosition(ctLine, CGPoint(x: x, y: 0))
    guard index != kCFNotFound else { return attributed.length }
    return max(0, min(index, attributed.length))
  }

  /// Horizontal offset (relative to the text's left edge) of UTF-16 `column`.
  private func xOffset(forColumn column: Int, in attributed: NSAttributedString) -> CGFloat {
    let clamped = max(0, min(column, attributed.length))
    let ctLine = CTLineCreateWithAttributedString(attributed)
    return CTLineGetOffsetForStringIndex(ctLine, clamped, nil)
  }

  override func draw(_ dirtyRect: NSRect) {
    viewportBackgroundColor.setFill()
    dirtyRect.fill()

    guard let buffer else {
      return
    }
    let range = layout.visibleLineRange(in: dirtyRect, lineCount: buffer.lineCount)
    guard !range.isEmpty else {
      return
    }

    let gutter = gutterWidth
    let textX = gutter + horizontalPadding
    let lines = attributedBandLines(for: buffer, range: range)

    if let selection, !selection.isEmpty {
      drawSelectionHighlight(selection, lines: lines, range: range, textX: textX)
    }

    var widest = maxObservedLineWidth
    for (offset, attributedLine) in lines.enumerated() {
      let lineIndex = range.lowerBound + offset
      let drawn = composedLineForDisplay(line: lineIndex, base: attributedLine)
      let y = layout.yOffset(forLine: lineIndex)
      let size = drawn.size()
      widest = max(widest, size.width)
      drawn.draw(
        with: NSRect(x: textX, y: y, width: size.width, height: layout.lineHeight),
        options: [.usesLineFragmentOrigin]
      )
    }
    drawCaretIfNeeded(lines: lines, range: range, textX: textX)
    if gutter > 0 {
      drawGutter(width: gutter, lineRange: range, dirtyRect: dirtyRect)
    }
    if widest > maxObservedLineWidth {
      maxObservedLineWidth = widest
      if !pendingLayoutUpdate {
        pendingLayoutUpdate = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.pendingLayoutUpdate = false
          self.updateLayout()
        }
      }
    }
  }

  /// Fills the selected column span on each visible line, behind the text. Lines
  /// fully spanned by a multi-line selection extend a little past their last
  /// character to signal the trailing newline is selected.
  private func drawSelectionHighlight(
    _ selection: TextSelection, lines: [NSAttributedString], range: Range<Int>, textX: CGFloat
  ) {
    let focused = window?.firstResponder === self
    (focused ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor)
      .setFill()
    for line in range {
      let attributed = lines[line - range.lowerBound]
      guard let span = selection.columnSpan(onLine: line, lineLengthUTF16: attributed.length) else {
        continue
      }
      let xStart = textX + xOffset(forColumn: span.start, in: attributed)
      var xEnd = textX + xOffset(forColumn: span.end, in: attributed)
      if line < selection.end.line {
        xEnd += newlineSelectionWidth
      }
      NSRect(
        x: xStart, y: layout.yOffset(forLine: line),
        width: max(0, xEnd - xStart), height: layout.lineHeight
      ).fill()
    }
  }

  /// Draws the caret at the (empty) selection head while focused and visible, or
  /// within the marked text while composing.
  private func drawCaretIfNeeded(lines: [NSAttributedString], range: Range<Int>, textX: CGFloat) {
    guard window?.firstResponder === self else { return }
    if let composition {
      drawCompositionCaret(composition, lines: lines, range: range, textX: textX)
      return
    }
    guard let selection, selection.isEmpty else { return }
    let line = selection.head.line
    guard range.contains(line) else { return }
    let attributed = lines[line - range.lowerBound]
    let x = textX + xOffset(forColumn: selection.head.columnUTF16, in: attributed)
    NSColor.textColor.setFill()
    NSRect(x: x, y: layout.yOffset(forLine: line), width: 1.5, height: layout.lineHeight).fill()
  }

  /// Draws the caret within the marked (composing) text at the input method's
  /// cursor position.
  private func drawCompositionCaret(
    _ composition: Composition, lines: [NSAttributedString], range: Range<Int>, textX: CGFloat
  ) {
    let line = composition.anchor.line
    guard range.contains(line) else { return }
    let base = lines[line - range.lowerBound]
    let column = max(0, min(composition.anchor.columnUTF16, base.length))
    let markedText = composition.text as NSString
    let within = max(0, min(composition.selectedRange.location, markedText.length))
    let prefixWidth = markedText.substring(to: within).size(withAttributes: [.font: font]).width
    let x = textX + xOffset(forColumn: column, in: base) + prefixWidth
    NSColor.textColor.setFill()
    NSRect(x: x, y: layout.yOffset(forLine: line), width: 1.5, height: layout.lineHeight).fill()
  }

  /// The attributed string to draw for `line`: the base line with any in-progress
  /// marked (composing) text inserted at the composition anchor and underlined.
  private func composedLineForDisplay(line: Int, base: NSAttributedString) -> NSAttributedString {
    guard let composition, composition.anchor.line == line, !composition.text.isEmpty else {
      return base
    }
    let column = max(0, min(composition.anchor.columnUTF16, base.length))
    let result = NSMutableAttributedString(
      attributedString: base.attributedSubstring(from: NSRange(location: 0, length: column)))
    result.append(
      NSAttributedString(
        string: composition.text,
        attributes: [
          .font: font,
          .foregroundColor: NSColor.textColor,
          .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]))
    result.append(
      base.attributedSubstring(from: NSRange(location: column, length: base.length - column)))
    return result
  }

  /// Draws the line-number gutter pinned to the left of the visible viewport, on
  /// top of the text so horizontally scrolled text slides underneath it.
  private func drawGutter(width: CGFloat, lineRange: Range<Int>, dirtyRect: NSRect) {
    // Left of the visible area, in this (document) view's coordinates. Tracks
    // horizontal scrolling so the gutter stays put while the text scrolls.
    let originX = enclosingScrollView?.contentView.bounds.origin.x ?? 0
    let columnRect = NSRect(
      x: originX, y: dirtyRect.minY, width: width, height: dirtyRect.height)
    viewportBackgroundColor.setFill()
    columnRect.fill()

    gutterSeparatorColor.setStroke()
    let separator = NSBezierPath()
    separator.move(to: NSPoint(x: originX + width - 0.5, y: dirtyRect.minY))
    separator.line(to: NSPoint(x: originX + width - 0.5, y: dirtyRect.maxY))
    separator.lineWidth = 1
    separator.stroke()

    let attributes: [NSAttributedString.Key: Any] = [
      .font: gutterFont,
      .foregroundColor: gutterTextColor,
    ]
    for line in lineRange {
      let number = NSAttributedString(string: "\(line + 1)", attributes: attributes)
      let numberWidth = number.size().width
      number.draw(
        with: NSRect(
          x: originX + max(0, width - GutterMetrics.trailingPadding - numberWidth),
          y: layout.yOffset(forLine: line),
          width: numberWidth,
          height: layout.lineHeight
        ),
        options: [.usesLineFragmentOrigin]
      )
    }
  }
}

extension LineRenderingTextView: @preconcurrency NSTextInputClient {
  // International text input. The input method (CJK IME, dead keys, accents,
  // dictation) drives these; nothing is hardcoded per language. Marked
  // (composing) text is held in `composition`, drawn inline, and only written to
  // the buffer on commit. Positions exchanged here are global UTF-16 offsets,
  // mapped to/from the buffer's (line, column) on demand so the document is never
  // materialized.

  /// Commit path: insert (replacing the selection, or `replacementRange`) and end
  /// any composition. Also the plain typing path when not composing.
  func insertText(_ string: Any, replacementRange: NSRange) {
    guard let text = Self.plainText(from: string) else { return }
    let wasComposing = composition != nil
    composition = nil
    guard isEditable, buffer != nil else {
      if wasComposing { refreshAfterComposition() }
      return
    }
    if replacementRange.location != NSNotFound {
      replace(
        globalStart: replacementRange.location,
        globalEnd: replacementRange.location + replacementRange.length, with: text)
    } else if !text.isEmpty {
      insertText(text)
    } else {
      refreshAfterComposition()
    }
  }

  /// Updates the in-progress composition. The marked text is not written to the
  /// buffer; it is drawn inline at a collapsed caret until committed.
  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard isEditable, buffer != nil, let text = Self.plainText(from: string) else { return }

    if composition == nil {
      // Begin composing: clear whatever the marked text replaces so it sits at a
      // collapsed caret.
      if replacementRange.location != NSNotFound {
        replace(
          globalStart: replacementRange.location,
          globalEnd: replacementRange.location + replacementRange.length, with: "")
      } else if let range = currentSelectionUTF16Range(), range.end > range.start {
        replace(globalStart: range.start, globalEnd: range.end, with: "")
      }
      composition = Composition(
        text: "", selectedRange: NSRange(location: 0, length: 0), anchor: navigationHead)
    }

    if text.isEmpty {
      composition = nil  // empty marked text cancels the composition
    } else {
      composition?.text = text
      composition?.selectedRange = selectedRange
    }
    if let anchor = composition?.anchor {
      selection = TextSelection(caretAt: anchor)
      scrollCaretToVisible(anchor)
    }
    refreshAfterComposition()
  }

  /// Finalizes the composition, committing the marked text at the anchor.
  func unmarkText() {
    guard let composition else { return }
    let text = composition.text
    self.composition = nil
    if isEditable, !text.isEmpty {
      insertText(text)
    } else {
      refreshAfterComposition()
    }
  }

  func hasMarkedText() -> Bool { composition != nil }

  func markedRange() -> NSRange {
    guard let composition, let anchor = utf16Offset(of: composition.anchor) else {
      return NSRange(location: NSNotFound, length: 0)
    }
    return NSRange(location: anchor, length: (composition.text as NSString).length)
  }

  func selectedRange() -> NSRange {
    if let composition, let anchor = utf16Offset(of: composition.anchor) {
      return NSRange(
        location: anchor + composition.selectedRange.location,
        length: composition.selectedRange.length)
    }
    guard let range = currentSelectionUTF16Range() else {
      return NSRange(location: 0, length: 0)
    }
    return NSRange(location: range.start, length: range.end - range.start)
  }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
    -> NSAttributedString?
  {
    // Only the marked text the input method asks about is materialized; the
    // (possibly huge) document body is never assembled here.
    guard let composition, let anchor = utf16Offset(of: composition.anchor) else {
      actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
      return nil
    }
    let markedText = composition.text as NSString
    let intersection = NSIntersectionRange(
      range, NSRange(location: anchor, length: markedText.length))
    guard intersection.length > 0 else {
      actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
      return nil
    }
    actualRange?.pointee = intersection
    let local = NSRange(location: intersection.location - anchor, length: intersection.length)
    return NSAttributedString(string: markedText.substring(with: local), attributes: [.font: font])
  }

  // The view draws marked text with its own underline, so no IME-provided marked
  // attributes are honored.
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  /// Screen rect for the start of `range` — where the input method anchors its
  /// candidate window (at the composing caret, or the selection when not
  /// composing).
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = range
    guard let window else { return .zero }
    let line: Int
    let textRelativeX: CGFloat
    if let composition, let anchor = utf16Offset(of: composition.anchor) {
      line = composition.anchor.line
      let base = attributedLine(forLine: line)
      let column = max(0, min(composition.anchor.columnUTF16, base.length))
      let markedText = composition.text as NSString
      let within = max(0, min(range.location - anchor, markedText.length))
      textRelativeX =
        xOffset(forColumn: column, in: base)
        + markedText.substring(to: within).size(withAttributes: [.font: font]).width
    } else {
      let caret = selection?.head ?? navigationHead
      line = caret.line
      textRelativeX = caretX(for: caret)
    }
    let rect = NSRect(
      x: gutterWidth + horizontalPadding + textRelativeX,
      y: layout.yOffset(forLine: line),
      width: 1,
      height: layout.lineHeight)
    return window.convertToScreen(convert(rect, to: nil))
  }

  func characterIndex(for point: NSPoint) -> Int {
    guard buffer != nil, let window else { return NSNotFound }
    let viewPoint = convert(window.convertPoint(fromScreen: point), from: nil)
    return utf16Offset(of: endpoint(at: viewPoint)) ?? NSNotFound
  }

  /// Stringifies an `insertText`/`setMarkedText` argument (`String` or
  /// `NSAttributedString`).
  fileprivate static func plainText(from object: Any) -> String? {
    if let string = object as? String { return string }
    if let attributed = object as? NSAttributedString { return attributed.string }
    return nil
  }

  /// Repaints and re-measures after the composition state changes, and asks the
  /// input method to reposition its candidate window.
  fileprivate func refreshAfterComposition() {
    maxObservedLineWidth = 0
    updateLayout()
    invalidateVisibleArea()
    inputContext?.invalidateCharacterCoordinates()
  }
}

/// Hosts the virtualized text view for SwiftUI. The scroll view is returned
/// directly — its sole child is the document view, which composites reliably in
/// the layer-backed host. The document view draws its own pinned line-number
/// gutter, so nothing is overlaid on (or placed beside) the scroll view.
struct LargeTextViewport: NSViewRepresentable {
  let buffer: TextBuffer
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax
  let isEditable: Bool

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    // Keep copy-on-scroll (the default): vertical scrolling then only repaints
    // the newly exposed rows, and the gutter/selection/caret — drawn in document
    // coordinates — move with the copied content. Horizontal scrolling needs the
    // pinned gutter repainted, which the coordinator handles explicitly.

    let documentView = LineRenderingTextView()
    documentView.setAccessibilityIdentifier("document-large-text-viewer")
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    documentView.showsLineNumbers = syntax.supportsLineNumbers
    documentView.isEditable = isEditable
    scrollView.documentView = documentView

    documentView.setBuffer(buffer)

    let clipView = scrollView.contentView
    clipView.postsBoundsChangedNotifications = true
    clipView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.viewportScrolled),
      name: NSView.boundsDidChangeNotification,
      object: clipView
    )
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.viewportResized),
      name: NSView.frameDidChangeNotification,
      object: clipView
    )
    context.coordinator.documentView = documentView

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let documentView = scrollView.documentView as? LineRenderingTextView else {
      return
    }
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    documentView.showsLineNumbers = syntax.supportsLineNumbers
    documentView.isEditable = isEditable
    if documentView.buffer !== buffer {
      documentView.setBuffer(buffer)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class Coordinator: NSObject {
    weak var documentView: LineRenderingTextView?

    @objc func viewportScrolled(_ notification: Notification) {
      documentView?.viewportDidScroll()
    }

    @objc func viewportResized(_ notification: Notification) {
      documentView?.updateLayout()
      documentView?.invalidateVisibleArea()
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }
  }
}

/// Viewer for text files too large for the editable string path. It opens the
/// file through the Rust [`TextBuffer`] off the main thread, then renders it
/// with [`LargeTextViewport`]. Editing (when `isEditable`) is routed to the
/// buffer in memory; saving large-file edits is a later slice.
struct VirtualizedTextDocumentView: View {
  let url: URL
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax
  /// Whether the viewer accepts edits (false for read-only entries).
  let isEditable: Bool
  /// Changing this (e.g. on external file change) re-opens the buffer.
  let reloadToken: Int

  @State private var phase: Phase = .loading

  private enum Phase {
    case loading
    case loaded(TextBuffer)
    case failed(String)
  }

  var body: some View {
    Group {
      switch phase {
      case .loading:
        Color(nsColor: .textBackgroundColor)
      case .loaded(let buffer):
        LargeTextViewport(
          buffer: buffer,
          accessibilityLabel: accessibilityLabel,
          syntax: syntax,
          isEditable: isEditable
        )
      case .failed(let message):
        ContentUnavailableView {
          Label("Document Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: TextViewportLoad(url: url, token: reloadToken)) {
      await open()
    }
  }

  private func open() async {
    phase = .loading
    let target = url
    do {
      let loaded = try await Task.detached(priority: .userInitiated) {
        let didStartAccess = target.startAccessingSecurityScopedResource()
        defer {
          if didStartAccess {
            target.stopAccessingSecurityScopedResource()
          }
        }
        return OpenedTextBuffer(buffer: try TextBuffer.open(at: target))
      }.value
      guard !Task.isCancelled else {
        return
      }
      phase = .loaded(loaded.buffer)
    } catch {
      guard !Task.isCancelled else {
        return
      }
      phase = .failed(Self.failureMessage(for: error))
    }
  }

  /// Maps an open failure to a user-facing message. Large non-UTF-8 files are
  /// called out explicitly: the editable path decodes legacy encodings, but this
  /// large-file viewer is UTF-8 only for now, so the narrowing is not silent.
  static func failureMessage(for error: Error) -> String {
    if let bufferError = error as? TextBufferError, bufferError == .notUTF8 {
      return
        "This file is too large to open as non-UTF-8 text. Large files currently open only in UTF-8."
    }
    return error.localizedDescription
  }
}

/// Identity for the load `task`: re-open when either the file or the reload
/// token changes.
private struct TextViewportLoad: Equatable {
  let url: URL
  let token: Int
}

/// Carries the non-`Sendable` `TextBuffer` from the loader task to the main
/// actor. It is only handed across once and then used exclusively on the main
/// actor, so the unchecked conformance is sound (mirrors `ImageDocument`).
private struct OpenedTextBuffer: @unchecked Sendable {
  let buffer: TextBuffer
}
