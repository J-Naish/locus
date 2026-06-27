import AppKit
import CoreText

/// Custom flipped `NSView` document view that draws only the visible band of a
/// [`TextBuffer`], fetching that band from the Rust core on demand. The document
/// height is synthesized from the visual-row count, so a multi-gigabyte file
/// never has its text assembled in memory — scrolling redraws exposed bands.
/// Wrapping is decided per document, never mixed with horizontal scrolling:
/// prose (the host sets `wrapsLines`) always soft-wraps to the viewport width;
/// a non-prose document (structured/code/data) scrolls horizontally until any
/// single line exceeds the long-line threshold, at which point the whole
/// document wraps (and the offending long lines drop syntax highlighting), like
/// a code editor handling a pathological line. Document size alone never forces
/// no-wrap — only a pathological line count or aggregate byte estimate (the work
/// the synchronous wrap-index build would do on the main thread) does, to keep
/// open and resize responsive.
final class LineRenderingTextView: NSView, NSUserInterfaceValidations {
  /// The editable backend, present only when the document is writable. Edits,
  /// dirty tracking, and saving go through this concrete buffer; a read-only
  /// large file leaves it nil.
  private(set) var editableBuffer: TextBuffer?
  /// The read-only backend used when there is no editable buffer — a file too
  /// large to load into an editable ``TextBuffer``. Nil whenever an editable
  /// buffer is present.
  private var readOnlyDocument: (any TextDocumentReading)?
  /// The active read backend for all rendering, selection, and accessibility: the
  /// editable buffer when present, else the read-only document. Routing every read
  /// through this lets the one view render either backend identically; editing
  /// stays on ``editableBuffer`` and is gated by `isEditable`.
  private var reader: (any TextDocumentReading)? { editableBuffer ?? readOnlyDocument }
  var layout: TextViewportLayout {
    TextViewportLayout(lineHeight: displaySyntax.lineHeight)
  }
  private var font: NSFont { displaySyntax.font }
  private var displaySyntax: TextDocumentSyntax {
    TextViewportPresentation.displaySyntax(for: syntax, markdownViewMode: markdownViewMode)
  }
  private var markdownTypography: MarkdownTypography {
    MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font)
  }
  private let horizontalPadding: CGFloat = 8
  /// Extra width past the widest line so the last character is not flush against
  /// the right edge when scrolled fully right.
  private let trailingContentMargin: CGFloat = 40
  // Matches the document card (white in light, the fixed near-black in dark)
  // so the editor surface and the card never seam.
  private let viewportBackgroundColor: NSColor = LocusChromeColors.documentCard

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
      markdownLineStateCache = nil
      cancelMarkdownLineStateBuild()
      maxObservedLineWidth = 0
      rebuildWrapIndex(recomputeLongLine: true)
      updateLayout()
      invalidateVisibleArea()
    }
  }

  private struct RawSelectionOffsets {
    let anchor: Int
    let head: Int
  }

  private var pendingMarkdownViewModeSelection: RawSelectionOffsets?
  private var pendingMarkdownViewModeViewportAnchor: (line: Int, offset: CGFloat)?

  var markdownViewMode: MarkdownViewMode = .rendered {
    willSet {
      guard newValue != markdownViewMode else { return }
      pendingMarkdownViewModeSelection = selection.flatMap(rawSelectionOffsets)
      pendingMarkdownViewModeViewportAnchor = viewportAnchor()
    }

    didSet {
      guard markdownViewMode != oldValue else { return }
      let rawSelection = pendingMarkdownViewModeSelection
      let anchor = pendingMarkdownViewModeViewportAnchor
      pendingMarkdownViewModeSelection = nil
      pendingMarkdownViewModeViewportAnchor = nil
      cachedBand = nil
      markdownLineStateCache = nil
      cancelMarkdownLineStateBuild()
      maxObservedLineWidth = 0
      rebuildWrapIndex(recomputeLongLine: true)
      updateLayout()
      if let rawSelection {
        restoreSelection(from: rawSelection)
      } else {
        clampSelectionToBounds()
      }
      if let anchor {
        restoreViewportAnchor(anchor)
      }
      invalidateVisibleArea()
    }
  }

  var showsMarkdownViewModeToggleCursorRect = false {
    didSet {
      guard showsMarkdownViewModeToggleCursorRect != oldValue else { return }
      window?.invalidateCursorRects(for: self)
    }
  }

  /// Whether the viewer accepts edits. Read-only entries keep this false; the
  /// host enables it for writable text. Editing is routed to the Rust buffer.
  var isEditable = false

  /// File the buffer is saved to on Cmd+S. The viewer owns the write so it can
  /// run it off the main thread without blocking the UI. Relative markdown
  /// image paths resolve against its folder, so a change re-resolves them.
  var saveURL: URL? {
    didSet {
      guard oldValue != saveURL, let store = markdownImageStoreStorage else { return }
      store.baseURL = saveURL
      store.reset()
      scheduleMarkdownImageRelayout()
    }
  }

  /// The file's original text encoding, restored on save (so a Shift JIS / UTF-16
  /// file is not silently rewritten as UTF-8).
  var saveEncoding: String.Encoding = .utf8

  /// Reports a save outcome to the host: on success the post-write file
  /// fingerprint (so the host records it before the change monitor reacts), on
  /// failure the error to surface.
  var onSaveCompletion: ((Result<DocumentFileFingerprint?, Error>) -> Void)?

  /// Tracks which buffers have a background save in flight, keyed by the buffer so
  /// the one-save-at-a-time guard survives a document swap-and-return (the
  /// open-document cache hands back the *same* `TextBuffer`). Production wires this
  /// to the shared `DocumentSaveTracker.shared` in `makeNSView` so the guard also
  /// survives this view being torn down and recreated mid-write; the default fresh
  /// instance keeps tests isolated. A save writes an immutable snapshot, not this
  /// live buffer, so editing is never paused — the guard only keeps two writes of
  /// the same buffer from overlapping.
  var saveTracker = DocumentSaveTracker()

  /// Reports the buffer's dirty state to the host after each edit/undo, so it can
  /// decide whether an external change may safely reload (clean) or conflicts
  /// with unsaved edits.
  var onDirtyChange: ((Bool) -> Void)?

  /// Reports focus changes so the host can pause document navigation shortcuts
  /// (e.g. Cmd+[ / Cmd+]) while the editor has the keyboard.
  var onFocusChange: ((Bool) -> Void)?

  private let bufferStore = TextBufferStore()

  /// Bytes fetched per line for the visible band; longer lines are truncated for
  /// the fetch so one enormous line never crosses the FFI in full. Sized to
  /// comfortably cover `maximumDrawnCharactersPerLine` worth of multi-byte text.
  private let maximumFetchedBytesPerLine = 96 * 1024
  /// Characters actually drawn (and wrapped) per line. Lines longer than this are
  /// clipped — the viewer does not lay out arbitrarily long single lines in full,
  /// since it still composes the whole (clipped) line per draw. A genuinely huge
  /// single line is therefore shown up to this bound until intra-line
  /// virtualization streams it. Selection and copy use the same clipped text, so
  /// all three share one coordinate system.
  private let maximumDrawnCharactersPerLine = 20_000
  /// Upper bound on how many bytes one copy may materialize. Cmd+A (or a huge
  /// drag) on a multi-gigabyte file must not build a giant string on the main
  /// thread, so an over-budget copy is refused (with a beep) rather than risking
  /// an out-of-memory freeze. Internal so tests can lower it. A future
  /// range-snapshot FFI could stream instead of materializing.
  var maximumCopiedByteCount = 256 * 1024 * 1024
  /// Much lower bound for the selection text handed to assistive technology, which
  /// may poll it repeatedly. Over this, accessibility reports no selected text.
  var maximumAccessibilitySelectedTextByteCount = 1 * 1024 * 1024
  /// Upper bound (UTF-16 units) on a single accessibility text-range request, so a
  /// request for a huge span never materializes a gigabyte. Assistive technology
  /// asks for the visible/line ranges, which stay well under this.
  var maximumAccessibilityStringLength = 1 * 1024 * 1024
  /// Upper bound on a single paste, so an enormous clipboard cannot freeze the
  /// main thread being inserted. Over this, the paste is refused with a beep.
  /// Internal so tests can lower it.
  var maximumPastedByteCount = 64 * 1024 * 1024
  private var cachedBand: (revision: UInt64, range: Range<Int>, lines: [NSAttributedString])?
  private var markdownLineStateCache: (revision: UInt64, states: [MarkdownLineStyleState])?

  /// Created on first use (markdown documents containing images); nil for
  /// every other document so plain viewers never pay for it.
  private var markdownImageStoreStorage: MarkdownImageStore?
  private var markdownImageRelayoutScheduled = false

  /// The opening-fence line of the code block whose copy control was most
  /// recently clicked — drawn with a checkmark until the confirmation lapses.
  private var copiedCodeBlockStartLine: Int?
  /// Bumped on each copy so a stale revert cannot clear a newer confirmation.
  private var copiedCodeBlockToken = 0
  private let codeCopyConfirmDuration: TimeInterval = 1.2
  /// An image-driven relayout whose rebuild went to the background; restored
  /// by `completeWrapBuild` once the new geometry is live. Cleared whenever a
  /// build is superseded (`cancelWrapBuild`) or the document is swapped.
  private var pendingViewportAnchor: (line: Int, offset: CGFloat)?

  var markdownImageStore: MarkdownImageStore {
    if let store = markdownImageStoreStorage {
      return store
    }
    let store = MarkdownImageStore(baseURL: saveURL)
    store.onUpdate = { [weak self] geometryChanged in
      if geometryChanged {
        self?.scheduleMarkdownImageRelayout()
      } else {
        self?.invalidateVisibleArea()
      }
    }
    markdownImageStoreStorage = store
    return store
  }

  /// Coalesces image-store updates into one relayout per main-actor turn —
  /// several images finishing their probes together rebuild geometry once.
  private func scheduleMarkdownImageRelayout() {
    guard !markdownImageRelayoutScheduled else { return }
    markdownImageRelayoutScheduled = true
    Task { @MainActor [weak self] in
      self?.performScheduledMarkdownImageRelayout()
    }
  }

  private func performScheduledMarkdownImageRelayout() {
    guard markdownImageRelayoutScheduled else { return }
    markdownImageRelayoutScheduled = false
    guard usesMarkdownDocumentLayout else { return }
    // Keep the first visible line anchored so images sizing in above the
    // viewport do not shove the text the user is reading.
    let anchor = viewportAnchor()
    rebuildWrapIndex(recomputeLongLine: false)
    updateLayout()
    if wrapBuildTask != nil {
      // The rebuild went to the background (large document); the geometry has
      // not changed yet, so defer the restore to the build's completion.
      pendingViewportAnchor = anchor
    } else if let anchor {
      restoreViewportAnchor(anchor)
    }
    invalidateVisibleArea()
  }

  /// Scrolls so `anchor.line` sits at the same viewport offset it had when the
  /// anchor was captured, compensating for geometry changes above it.
  private func viewportAnchor() -> (line: Int, offset: CGFloat)? {
    guard let visible = enclosingScrollView?.documentVisibleRect else { return nil }
    let location = rowLocation(forY: visible.minY)
    return (location.line, visible.minY - yOffset(ofLine: location.line))
  }

  private func restoreViewportAnchor(_ anchor: (line: Int, offset: CGFloat)) {
    guard let scrollView = enclosingScrollView else { return }
    let target = yOffset(ofLine: anchor.line) + anchor.offset
    let current = scrollView.documentVisibleRect.minY
    guard abs(target - current) > 0.5 else { return }
    scrollView.contentView.scroll(
      to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: target))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  func settleMarkdownImageLoadsForTesting() async {
    guard let store = markdownImageStoreStorage else { return }
    await store.settleForTesting()
    performScheduledMarkdownImageRelayout()
  }
  private let markdownSynchronousLineStateLimit = 4_096
  private var markdownLineStateBuildGeneration = 0
  private var markdownLineStateBuildTargetRevision: UInt64?
  private var markdownLineStateBuildTask: Task<Void, Never>?
  private var maxObservedLineWidth: CGFloat = 0
  private var pendingLayoutUpdate = false

  // Read-only selection / caret. The view owns this state (it is not an
  // NSTextView), maps clicks to (line, UTF-16 column) endpoints, draws the
  // highlight and caret, and copies the selected text on demand.
  private(set) var selection: TextSelection?
  private var isSelecting = false
  /// Granularity of the in-progress drag selection: a single click extends by
  /// character, a double-click by whole words, a triple-click by whole lines.
  private enum SelectionGranularity { case character, word, line }
  private var selectionGranularity: SelectionGranularity = .character
  /// For a word/line drag, the originally selected unit's range, so dragging
  /// extends by whole units anchored to it (rather than collapsing to the click).
  private var selectionAnchorRange: (start: TextSelection.Endpoint, end: TextSelection.Endpoint)?
  /// Extra highlight width drawn past a fully selected line to signal that the
  /// line's trailing newline is part of the selection.
  private let newlineSelectionWidth: CGFloat = 6
  /// Horizontal margin kept around the caret when scrolling it into view.
  private let caretScrollMargin: CGFloat = 8
  /// Preferred horizontal offset (text-relative) the caret keeps while moving up
  /// or down, so vertical motion does not drift in/out on short lines. Reset by
  /// any non-vertical move.
  private var verticalGoalX: CGFloat?

  // MARK: Caret blink
  /// Whether the insertion caret is in its visible blink phase. The caret is shown
  /// while true and hidden while false; activity (typing, moving, clicking) forces
  /// it solid again so it never disappears right when the user acts.
  private(set) var caretBlinkOn = true
  /// Repeating timer that toggles the blink phase while focused. `nil` when not
  /// blinking (unfocused or detached from a window).
  private(set) var caretBlinkTimer: Timer?
  /// Half-period of the caret blink.
  private let caretBlinkInterval: TimeInterval = 0.5

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

  // MARK: Soft wrap
  /// Prose mode: when true (Markdown, plain text), every line soft-wraps to the
  /// viewport. When false (structured/code/data), only lines past
  /// `longLineWrapThreshold` wrap — shorter lines stay on one row and scroll
  /// horizontally, like a code editor that still folds a pathologically long
  /// line. The host sets this per document; toggling it rebuilds the wrap index
  /// and relays out.
  var wrapsLines = true {
    didSet {
      guard wrapsLines != oldValue else { return }
      rebuildWrapIndex()
      updateLayout()
      invalidateVisibleArea()
    }
  }
  /// Safety valves for soft wrapping. Building the wrap index holds one entry per
  /// logical line and is rebuilt on open and resize, reading the document once
  /// through the per-line fetch cap and laying each line out with Core Text on
  /// the main thread. Two bounds keep that pass responsive without limiting
  /// document size as such:
  /// - line count caps the number of index entries and Core Text layouts, and
  /// - the aggregate *fetched*-byte estimate caps the bytes that pass the FFI and
  ///   get laid out in one pass.
  /// The byte estimate uses the per-line fetch cap (`maximumFetchedBytesPerLine`),
  /// not the raw file size, so a file of a few enormous lines (tiny aggregate)
  /// still wraps; only a file of very many medium-or-long lines — which would
  /// read hundreds of megabytes and run that many layouts at once — falls back to
  /// no-wrap (horizontal scroll). Realistic prose is far below both. The build is
  /// still synchronous on the main actor, so these caps are also what bound that
  /// hitch on open/resize; an off-main/chunked build is the way to raise them
  /// further. `var` so tests can lower the budgets to exercise the boundaries.
  var maximumWrappableLineCount = 200_000
  var maximumWrappableFetchedByteBudget = 64 * 1024 * 1024
  /// In non-prose documents, the line length (UTF-16 units) at which the whole
  /// document switches to soft wrapping. As long as every line is at or under it,
  /// the document scrolls horizontally (a line is a record/structure unit); once
  /// any single line exceeds it, the entire document wraps — folding and
  /// horizontal scrolling never mix, matching a code editor's long-line handling.
  /// The same threshold suppresses rule highlighting on the offending long lines.
  /// `var` so tests can set it. Prose ignores this — it always wraps.
  var longLineWrapThreshold = 2_000

  /// Number of non-prose lines currently past `longLineWrapThreshold`. The whole
  /// document wraps while this is non-zero. Width-independent, so it survives a
  /// resize without re-scanning; maintained incrementally on single-line edits
  /// (via `lineIsLong`) so shortening the last long line returns the document to
  /// horizontal scroll without waiting for a reload.
  private var longLineCount = 0
  /// Per-logical-line "is past the threshold" flags backing `longLineCount`, kept
  /// only while wrapping a non-prose document (nil for prose, no-wrap, or over
  /// budget). Lets a single-line edit adjust the count without re-scanning.
  private var lineIsLong: [Bool]?
  /// Whether `longLineCount` reflects a scan at a valid width. The first build can
  /// run before the view has a width (wrap content width ≤ 0) and bail without
  /// scanning; until a scan succeeds the cached decision must not be trusted, or a
  /// non-prose document that should wrap would stay horizontally scrolling.
  private var longLineDecisionValid = false

  /// Whether the whole document soft-wraps (vs. scrolls horizontally): prose
  /// always does; a non-prose document does only while it holds a long line. The
  /// decision is document-wide, so wrapping and horizontal scrolling never mix.
  private var documentWraps: Bool { wrapsLines || longLineCount > 0 }

  /// Markdown gets a document measure instead of an editor gutter-width measure.
  /// The large-file read-only path intentionally stays on the plain fast renderer.
  private var usesMarkdownDocumentLayout: Bool {
    syntax == .markdown && markdownViewMode == .rendered && editableBuffer != nil
  }

  /// Whether the document is currently soft-wrapping rather than scrolling
  /// horizontally. Mirrors whether a wrap index is active.
  var isSoftWrapping: Bool { wrapIndex != nil }

  /// Total visual rows the document occupies — the row count the layout is built
  /// from, independent of the frame being padded to fill the viewport. Exposed
  /// for tests/inspection.
  var visualRowCount: Int { totalVisualRows }

  /// Whether a line of `length` UTF-16 units gets rule-based syntax highlighting:
  /// prose always does; non-prose skips it for lines past the long-line threshold
  /// (the same lines that drive wrapping), matching a code editor's long lines.
  private func highlightsLine(lengthUTF16 length: Int) -> Bool {
    wrapsLines || length <= longLineWrapThreshold
  }

  // MARK: Huge-line virtualization
  //
  // A logical line longer than `maximumDrawnCharactersPerLine` is not laid out in
  // full. While wrapping, it folds on a fixed-column grid and only its visible
  // rows are fetched from the buffer as UTF-16 windows — so an enormous single
  // line shows in full (and scrolls) without ever materializing it. Normal lines
  // are untouched; the geometry/draw/hit-test paths branch on `isHugeLine`.

  /// A huge line's content start (global UTF-16) and content length (UTF-16,
  /// terminator excluded), resolved once during the wrap-index build.
  private struct HugeLineInfo {
    let start: Int
    let length: Int
  }

  /// Maps a huge line's index to its cached start/length, populated during the
  /// wrap-index build (and only while wrapping). Empty otherwise. Bounded by the
  /// number of huge lines, which is tiny in practice. Caching the start keeps
  /// drawing a band of the line's rows from re-resolving it per row.
  private var hugeLineInfo: [Int: HugeLineInfo] = [:]

  private func isHugeLine(_ line: Int) -> Bool { hugeLineInfo[line] != nil }

  /// The cached true UTF-16 length of `line` if it is huge, else nil.
  private func hugeLength(_ line: Int) -> Int? { hugeLineInfo[line]?.length }

  /// Columns (UTF-16 units) per visual row when grid-wrapping a huge line. Uses
  /// the font's widest advance so a row never exceeds the content width and no
  /// glyph is clipped: exact for the monospaced fonts huge machine-data lines
  /// use, conservative (sparser rows) for proportional fonts.
  private var hugeLineColumns: Int {
    let advance = max(1, font.maximumAdvancement.width)
    return max(1, Int((wrapContentWidth / advance).rounded(.down)))
  }

  /// Visual-row count of a huge line of `utf16Length` at the current width.
  private func hugeRowCount(utf16Length: Int) -> Int {
    let columns = hugeLineColumns
    return max(1, (utf16Length + columns - 1) / columns)
  }

  /// A huge line's content start (UTF-16) and content length (terminator
  /// excluded), via two position lookups. Both backends resolve these in bounded
  /// time: the editable persistent-rope buffer in `O(log n)`, and the windowed
  /// large-file index from byte-cadence checkpoints (so an in-line seek scans at
  /// most one checkpoint gap, not the whole line). Passing a huge column for the
  /// end clamps to the line's content end, which the core resolves directly rather
  /// than by scanning. Used only for lines already suspected huge, so normal lines
  /// never pay for it.
  private func hugeLineContent(_ line: Int) -> (start: Int, length: Int) {
    guard let buffer = reader else { return (0, 0) }
    let start = (try? buffer.position(forLine: line, columnUTF16: 0).utf16) ?? 0
    // A column past the content clamps to the line's content end (terminator
    // excluded), so the difference is the content's UTF-16 length.
    let end = (try? buffer.position(forLine: line, columnUTF16: buffer.utf16Length))?.utf16 ?? start
    return (start, max(0, end - start))
  }

  /// The displayed text of a huge line's visual row, fetched as a UTF-16 window
  /// from the buffer. Rule highlighting is skipped (like other long lines); only
  /// the base font is applied.
  private func hugeRowText(line: Int, rowIndex: Int, utf16Length: Int) -> NSAttributedString {
    let columns = hugeLineColumns
    let rowStart = rowIndex * columns
    let rowEnd = min(utf16Length, rowStart + columns)
    // Use the cached content start so drawing a band of rows does not re-resolve
    // the line's start position once per visible row.
    guard let buffer = reader, rowEnd > rowStart, let info = hugeLineInfo[line] else {
      return NSAttributedString(string: "", attributes: hugeRowAttributes)
    }
    let text = buffer.text(fromUTF16: info.start + rowStart, toUTF16: info.start + rowEnd)
    return NSAttributedString(string: text, attributes: hugeRowAttributes)
  }

  /// Base styling for a huge line's rows: the editor font and the standard label
  /// color (so the text is visible in light and dark). Rule highlighting is
  /// skipped for huge lines, like other long lines.
  private var hugeRowAttributes: [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: NSColor.labelColor]
  }

  /// Per-logical-line → visual-row mapping while wrapping is active; `nil` when not
  /// wrapping. Rebuilt fully on open and width change; every edit — typing,
  /// multi-line paste/delete, undo/redo — splices just its rewritten lines via
  /// `updateWrapIndex(afterChange:)`.
  private var wrapIndex: WrapIndex?
  /// The per-logical-line wrapped-row counts the current `wrapIndex` was built from,
  /// kept so a single-line edit can recompute just that line instead of re-wrapping
  /// the whole document. `nil` whenever wrapping is inactive (mirrors `wrapIndex`).
  private var wrapRowCounts: [Int]?
  /// Wrap width the current `wrapIndex` was built at, so resize only rebuilds when
  /// the width actually changes.
  private var lastWrapWidth: CGFloat = -1

  var lineCount: Int { reader?.lineCount ?? 1 }

  /// Width available for wrapped text (viewport minus gutter and padding).
  private var wrapContentWidth: CGFloat {
    let visible = enclosingScrollView?.documentVisibleRect.width ?? frame.width
    if usesMarkdownDocumentLayout {
      return min(
        MarkdownDocumentMetrics.maxMeasureWidth,
        max(0, visible - markdownDocumentSidePadding * 2)
      )
    }
    return visible - gutterWidth - horizontalPadding * 2
  }

  private var markdownDocumentSidePadding: CGFloat {
    MarkdownDocumentMetrics.minimumHorizontalPadding
  }

  private var textColumnX: CGFloat {
    guard usesMarkdownDocumentLayout else {
      return gutterWidth + horizontalPadding
    }
    let visible = enclosingScrollView?.documentVisibleRect ?? bounds
    return visible.minX + max(0, (visible.width - wrapContentWidth) / 2)
  }

  private nonisolated static func markdownStructuralIndent(for state: MarkdownLineStyleState)
    -> CGFloat
  {
    CGFloat(max(0, state.quoteDepth)) * MarkdownDocumentMetrics.quoteIndentWidth
      + CGFloat(max(0, state.listDepth)) * MarkdownDocumentMetrics.markerColumnWidth
  }

  private nonisolated static func markdownInnerInset(for state: MarkdownLineStyleState) -> CGFloat {
    if state.insideFrontMatter {
      return MarkdownDocumentMetrics.frontMatterHorizontalInset
    }
    if state.insideFence || state.isFenceDelimiter || state.isIndentedCodeBlock {
      return MarkdownDocumentMetrics.codeCardInset
    }
    if state.isTableRow {
      return MarkdownDocumentMetrics.tableEdgeInset
    }
    return 0
  }

  private nonisolated static func markdownLineIndent(for state: MarkdownLineStyleState) -> CGFloat {
    markdownStructuralIndent(for: state) + markdownInnerInset(for: state)
  }

  private nonisolated static func markdownWrapContentWidth(
    baseWidth: CGFloat,
    state: MarkdownLineStyleState
  ) -> CGFloat {
    max(1, baseWidth - markdownLineIndent(for: state))
  }

  private nonisolated static func markdownOuterContentWidth(
    baseWidth: CGFloat,
    state: MarkdownLineStyleState
  ) -> CGFloat {
    max(1, baseWidth - markdownStructuralIndent(for: state))
  }

  private func markdownLineIndent(forLine line: Int) -> CGFloat {
    guard usesMarkdownDocumentLayout, let buffer = reader else { return 0 }
    return Self.markdownLineIndent(for: markdownLineState(forLine: line, in: buffer))
  }

  private func lineTextColumnX(forLine line: Int) -> CGFloat {
    textColumnX + markdownLineIndent(forLine: line)
  }

  private func lineOuterColumnX(forLine line: Int) -> CGFloat {
    guard usesMarkdownDocumentLayout, let buffer = reader else { return textColumnX }
    return textColumnX
      + Self.markdownStructuralIndent(
        for: markdownLineState(forLine: line, in: buffer))
  }

  private func lineWrapContentWidth(forLine line: Int) -> CGFloat {
    guard usesMarkdownDocumentLayout, let buffer = reader else { return wrapContentWidth }
    return Self.markdownWrapContentWidth(
      baseWidth: wrapContentWidth,
      state: markdownLineState(forLine: line, in: buffer))
  }

  private func lineOuterContentWidth(forLine line: Int) -> CGFloat {
    guard usesMarkdownDocumentLayout, let buffer = reader else { return wrapContentWidth }
    return Self.markdownOuterContentWidth(
      baseWidth: wrapContentWidth,
      state: markdownLineState(forLine: line, in: buffer))
  }

  /// (Re)builds the wrap index for the current buffer and width when the document
  /// wraps (prose, or a non-prose document holding a long line), or clears it for
  /// horizontal scrolling.
  ///
  /// A document up to `wrapBuildSynchronousLineLimit` lines is measured
  /// synchronously (one chunk's worth of work, no observable intermediate
  /// state). A larger document is measured by a chunked background build (see
  /// `scheduleWrapBuild`): the view keeps its current geometry — no index on
  /// open, the old-width index across a resize — and swaps the finished index
  /// in on the main actor, so the main thread never stalls on a full-document
  /// Core Text pass.
  ///
  /// `recomputeLongLine` forces re-deciding whether a non-prose document has a
  /// long line — passed when the content changed (open, multi-line edit, undo).
  /// A pure resize passes false and reuses the cached decision, *unless* the
  /// decision was never computed at a valid width yet (see `longLineDecisionValid`),
  /// so the first real layout after a width-less open still resolves it.
  private func rebuildWrapIndex(recomputeLongLine: Bool = true) {
    // Whatever triggered this rebuild supersedes any in-flight background build
    // (its inputs — content, width, or wrap mode — just changed underneath it).
    cancelWrapBuild()
    guard let buffer = reader, wrapContentWidth > 0,
      buffer.lineCount <= maximumWrappableLineCount,
      // Estimate the bytes the build pulls across the FFI: at most the per-line
      // fetch cap times the line count, but never more than the file. A few huge
      // lines stay tiny here and still wrap; very many long lines do not.
      min(buffer.byteLength, buffer.lineCount * maximumFetchedBytesPerLine)
        <= maximumWrappableFetchedByteBudget
    else {
      lastWrapWidth = wrapContentWidth
      wrapIndex = nil
      wrapRowCounts = nil
      lineIsLong = nil
      longLineCount = 0
      hugeLineInfo = [:]
      // Bailed before deciding (no buffer, zero width, or over the line/byte
      // budget), so the long-line decision is not trustworthy; a later valid
      // layout or content change must recompute it rather than reuse it.
      longLineDecisionValid = false
      return
    }
    // A horizontally-scrolling document needs no index. Skip the document read on
    // a pure resize, but only when the no-wrap decision is actually trustworthy:
    // not on a content change, and not before a valid-width scan has happened.
    if !recomputeLongLine, longLineDecisionValid, !documentWraps {
      lastWrapWidth = wrapContentWidth
      wrapIndex = nil
      wrapRowCounts = nil
      hugeLineInfo = [:]
      return
    }
    if buffer.lineCount <= wrapBuildSynchronousLineLimit {
      buildWrapIndexNow(recomputeLongLine: recomputeLongLine)
    } else {
      scheduleWrapBuild(recomputeLongLine: recomputeLongLine)
    }
  }

  /// The synchronous build for documents small enough to measure in one pass.
  /// Reads the whole (bounded) document once; line widths depend only on the
  /// font, so highlighting is skipped here.
  private func buildWrapIndexNow(recomputeLongLine: Bool) {
    guard let buffer = reader else { return }
    lastWrapWidth = wrapContentWidth
    let width = wrapContentWidth
    let lineStrings = displayLineStrings(forLineRange: 0, count: buffer.lineCount)
    // (Re)scan for long lines when the content changed or the decision has not yet
    // been made at a valid width. The decision is width-independent, so a plain
    // resize with a valid decision reuses it.
    if !wrapsLines, recomputeLongLine || !longLineDecisionValid {
      let flags = lineStrings.map { ($0 as NSString).length > longLineWrapThreshold }
      lineIsLong = flags
      longLineCount = flags.lazy.filter { $0 }.count
    }
    longLineDecisionValid = true
    guard documentWraps else {
      wrapIndex = nil
      wrapRowCounts = nil
      hugeLineInfo = [:]
      return
    }
    // A line clipped at the display cap may actually be enormous; resolve its true
    // length and, if it is huge, count its rows from the fixed-column grid rather
    // than laying it out. Only clipped (suspicious) lines pay for the lookup.
    hugeLineInfo = [:]
    var counts: [Int] = []
    counts.reserveCapacity(lineStrings.count)
    let markdownStates = usesMarkdownDocumentLayout ? markdownLineStates(for: buffer) : nil
    for (line, lineText) in lineStrings.enumerated() {
      if (lineText as NSString).length >= maximumDrawnCharactersPerLine {
        let content = hugeLineContent(line)
        if content.length > maximumDrawnCharactersPerLine {
          hugeLineInfo[line] = HugeLineInfo(start: content.start, length: content.length)
          counts.append(hugeRowCount(utf16Length: content.length))
          continue
        }
      }
      let markdownState =
        line < (markdownStates?.count ?? 0) ? markdownStates?[line] ?? .plain : .plain
      let lineWidth =
        usesMarkdownDocumentLayout
        ? Self.markdownWrapContentWidth(baseWidth: width, state: markdownState)
        : width
      counts.append(
        wrapRowCount(text: lineText, width: lineWidth, markdownLineState: markdownState))
    }
    wrapRowCounts = counts
    wrapIndex = WrapIndex(
      visualRowsPerLine: counts,
      rowMetricsPerLine: markdownRowMetrics(states: markdownStates, lineCount: counts.count),
      uniformRowHeight: layout.lineHeight)
  }

  /// Per-line vertical metrics for markdown documents containing slim marker
  /// rows (table delimiters, setext underlines) or headings (taller glyph rows
  /// with sectional air above and below), or `nil` when every line is uniform —
  /// which keeps the O(1) uniform geometry fast path.
  private func markdownRowMetrics(
    states: [MarkdownLineStyleState]?, lineCount: Int
  ) -> [LineRowMetrics]? {
    guard usesMarkdownDocumentLayout, let states, lineCount > 0 else { return nil }
    let uniform = LineRowMetrics(rowHeight: layout.lineHeight)
    var metrics: [LineRowMetrics]?
    func set(_ index: Int, _ value: LineRowMetrics) {
      if metrics == nil {
        metrics = [LineRowMetrics](repeating: uniform, count: lineCount)
      }
      metrics?[index] = value
    }
    func codeRunLine(_ i: Int) -> Bool {
      guard i >= 0, i < states.count else { return false }
      return Self.markdownLineIsCodeRun(states[i])
    }
    for index in 0..<lineCount {
      let state = index < states.count ? states[index] : .plain
      if state.isTableSeparator || state.isSetextUnderline {
        set(index, LineRowMetrics(rowHeight: MarkdownDocumentMetrics.slimMarkerRowHeight))
      } else if let level = state.headingLevel {
        set(index, Self.headingLineMetrics(level: level, isDocumentTop: index == 0))
      } else if let image = state.imageSource {
        set(index, markdownImageLineMetrics(for: image, state: state))
      } else if Self.markdownLineIsFrontMatterRun(state) {
        if let metrics = markdownFrontMatterLineMetrics(
          state: state,
          isFirst: !Self.markdownLineIsFrontMatterRun(index > 0 ? states[index - 1] : .plain),
          isLast: !Self.markdownLineIsFrontMatterRun(
            index + 1 < states.count ? states[index + 1] : .plain),
          isDocumentTop: index == 0)
        {
          set(index, metrics)
        }
      } else if Self.markdownLineIsCodeRun(state) {
        if let metrics = markdownCodeRunLineMetrics(
          state: state, isFirst: !codeRunLine(index - 1), isLast: !codeRunLine(index + 1),
          isDocumentTop: index == 0)
        {
          set(index, metrics)
        }
      }
    }
    return metrics
  }

  /// Lines that belong to a code slab: fenced or indented code.
  nonisolated static func markdownLineIsCodeRun(_ state: MarkdownLineStyleState) -> Bool {
    state.isFenceDelimiter || state.insideFence || state.isIndentedCodeBlock
  }

  nonisolated static func markdownLineIsFrontMatterRun(_ state: MarkdownLineStyleState) -> Bool {
    state.insideFrontMatter
  }

  private func markdownFrontMatterLineMetrics(
    state: MarkdownLineStyleState, isFirst: Bool, isLast: Bool, isDocumentTop: Bool
  ) -> LineRowMetrics? {
    let rowHeight =
      state.isFrontMatterDelimiter
      ? MarkdownDocumentMetrics.frontMatterVerticalPadding
      : MarkdownDocumentMetrics.frontMatterRowHeight
    let leading = isFirst && !isDocumentTop ? MarkdownDocumentMetrics.codeBlockAir : 0
    let trailing = isLast ? MarkdownDocumentMetrics.codeBlockAir : 0
    return LineRowMetrics(rowHeight: rowHeight, leadingInset: leading, trailingInset: trailing)
  }

  /// Per-line metrics for a code-slab line: empty fence delimiters collapse to
  /// slim rows (so the slab never carries a full empty row at its edge), a
  /// labeled opener gets a caption band, and the first/last line of the run
  /// gains the block air that detaches the slab from surrounding prose. Body
  /// rows keep the uniform row height. Returns nil when nothing diverges.
  private func markdownCodeRunLineMetrics(
    state: MarkdownLineStyleState, isFirst: Bool, isLast: Bool, isDocumentTop: Bool
  ) -> LineRowMetrics? {
    var rowHeight = layout.lineHeight
    if state.isFenceDelimiter {
      // A *labeled* opener gets a header band for its language caption; a bare
      // opener (and every closer) collapses to a slim row, so a language-less
      // block has no empty band of reserved label space at its top. The copy
      // control floats over the top-right corner either way.
      rowHeight =
        state.isFenceOpen && state.isFenceLabel
        ? Self.codeLabelRowHeight : MarkdownDocumentMetrics.slimMarkerRowHeight
    } else if state.isFrontMatterDelimiter {
      // The `---` lines render empty; a slim row keeps them as quiet padding
      // instead of a full empty row at the card's top and bottom.
      rowHeight = MarkdownDocumentMetrics.slimMarkerRowHeight
    }
    // A code block at the very top of the document sits at the page top (the
    // scroll inset already breathes) — no extra air above, matching headings.
    let leading = isFirst && !isDocumentTop ? MarkdownDocumentMetrics.codeBlockAir : 0
    let trailing = isLast ? MarkdownDocumentMetrics.codeBlockAir : 0
    guard rowHeight != layout.lineHeight || leading != 0 || trailing != 0 else { return nil }
    return LineRowMetrics(rowHeight: rowHeight, leadingInset: leading, trailingInset: trailing)
  }

  /// The header-band height: tall enough for the language label and at least
  /// enough to fully contain the copy control (which centers in the band, so
  /// it never overhangs the card top or the first code row).
  nonisolated static var codeLabelRowHeight: CGFloat {
    let font = MarkdownDocumentMetrics.codeLabelFont
    let labelHeight = ceil(font.ascender - font.descender + font.leading) + 4
    return max(labelHeight, MarkdownDocumentMetrics.codeCopyButtonHeight + 4)
  }

  /// An image line's vertical metrics: the image block (plus air and the gap
  /// to its caption) lives in the leading inset, so the line's text rows — the
  /// alt text rendered as a small caption — sit below the image and keep every
  /// caret, selection, and editing behavior of a normal text line.
  private func markdownImageLineMetrics(
    for image: MarkdownImageSource, state: MarkdownLineStyleState
  ) -> LineRowMetrics {
    let contentWidth = Self.markdownWrapContentWidth(baseWidth: wrapContentWidth, state: state)
    let blockHeight = markdownImageBlockHeight(source: image.source, contentWidth: contentWidth)
    return LineRowMetrics(
      rowHeight: Self.markdownImageCaptionRowHeight,
      leadingInset: MarkdownDocumentMetrics.imageBlockAir + blockHeight
        + MarkdownDocumentMetrics.imageCaptionGap,
      trailingInset: MarkdownDocumentMetrics.imageBlockAir)
  }

  nonisolated static var markdownImageCaptionRowHeight: CGFloat {
    let font = MarkdownDocumentMetrics.imageCaptionFont
    return ceil(font.ascender - font.descender + font.leading)
  }

  /// The block height for the image's current load state; querying the store
  /// starts the probe for sources seen for the first time.
  private func markdownImageBlockHeight(source: String, contentWidth: CGFloat) -> CGFloat {
    switch markdownImageStore.state(for: source) {
    case .loading:
      return MarkdownDocumentMetrics.imagePlaceholderHeight
    case .failed:
      return MarkdownDocumentMetrics.imageFailureHeight
    case .sized(let natural):
      return Self.markdownImageDisplaySize(natural: natural, contentWidth: contentWidth).height
    }
  }

  /// Fits an image's natural pixel size (treated as points) into the text
  /// column: shrink to the column width, never upscale, and cap very tall
  /// images at `imageMaximumBlockHeight` (width shrinks proportionally).
  nonisolated static func markdownImageDisplaySize(
    natural: CGSize, contentWidth: CGFloat
  ) -> CGSize {
    guard natural.width > 0, natural.height > 0, contentWidth > 0 else {
      return CGSize(width: 0, height: MarkdownDocumentMetrics.imagePlaceholderHeight)
    }
    var width = min(natural.width, contentWidth)
    var height = width * natural.height / natural.width
    if height > MarkdownDocumentMetrics.imageMaximumBlockHeight {
      height = MarkdownDocumentMetrics.imageMaximumBlockHeight
      width = height * natural.width / natural.height
    }
    return CGSize(width: ceil(width), height: ceil(height))
  }

  /// A heading line's vertical metrics: a row sized to its font plus the
  /// level's sectional insets (suppressed above a document-top title).
  nonisolated static func headingLineMetrics(level: Int, isDocumentTop: Bool) -> LineRowMetrics {
    let font = MarkdownDocumentMetrics.headingFont(level: level)
    let insets = MarkdownDocumentMetrics.headingInsets(level: level)
    return LineRowMetrics(
      rowHeight: ceil(font.ascender - font.descender + font.leading),
      leadingInset: isDocumentTop
        ? MarkdownDocumentMetrics.documentTopHeadingInset : insets.leading,
      trailingInset: insets.trailing
    )
  }

  // MARK: Background wrap build
  //
  // Above `wrapBuildSynchronousLineLimit` lines, the full-document measurement
  // moves off the main actor: an immutable source (a buffer snapshot or the
  // read-only large file) is read and measured in chunks on a detached task,
  // checking for cancellation between chunks — so a superseded build (resize,
  // edit, document switch) stops within one chunk and only one chunk's strings
  // are ever resident. The finished outcome is validated against the current
  // generation/content/width on the main actor and swapped in atomically;
  // anything stale restarts from the new state. While a build is in flight the
  // view keeps its current geometry: no index on open (horizontal scroll), the
  // old-width index across a resize.

  /// Largest document measured synchronously (one chunk's worth — keeps small
  /// documents free of any intermediate unwrapped state). `var` so tests can
  /// lower it to force the background path on tiny fixtures.
  var wrapBuildSynchronousLineLimit = 4_096
  /// Lines fetched and measured per background chunk: large enough to amortize
  /// the per-chunk FFI call, small enough that cancellation lands within a few
  /// tens of milliseconds. `var` so tests can lower it to exercise chunk
  /// boundaries on tiny fixtures.
  var wrapBuildChunkLineCount = 4_096

  /// Identifies the current build; bumped whenever a build is scheduled or
  /// cancelled so a stale completion is dropped on arrival.
  private var wrapBuildGeneration = 0
  private var wrapBuildTask: Task<Void, Never>?
  /// Width the in-flight build is measuring at, so a layout pass does not
  /// re-trigger a rebuild for a width that is already being measured. -1 when
  /// no build is in flight.
  private var wrapBuildTargetWidth: CGFloat = -1

  deinit {
    // The worker retains only the immutable source and checks cancellation per
    // chunk; cancelling here stops a torn-down view's build from measuring on
    // toward a completion the generation check would drop anyway.
    wrapBuildTask?.cancel()
    markdownLineStateBuildTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  /// Inputs captured on the main actor at schedule time, crossed once into the
  /// worker. `@unchecked Sendable`: `source` is one of the immutable,
  /// thread-safe backends (never the live buffer), and `font` is an immutable
  /// `NSFont`, which AppKit documents as thread-safe.
  private struct WrapBuildInput: @unchecked Sendable {
    let source: any WrapMeasurementReading
    let width: CGFloat
    let font: NSFont
    let markdownTypography: MarkdownTypography?
    let wrapsLines: Bool
    /// Whether the worker must (re)scan for long lines (non-prose content
    /// change, or no trustworthy decision yet).
    let scanLongLines: Bool
    /// The wrap decision to use when not scanning (the cached one).
    let wrapsWithoutScan: Bool
    let longLineWrapThreshold: Int
    let drawnCharacterCap: Int
    let fetchedBytesPerLineCap: Int
    let chunkLineCount: Int
    /// Grid columns for huge-line rows at `width`/`font` (precomputed so the
    /// worker never touches view state).
    let hugeColumns: Int
  }

  /// What a finished build hands back for the atomic swap.
  private struct WrapBuildOutcome {
    var rowCounts: [Int]
    var lineIsLong: [Bool]?
    var longLineCount: Int
    var hugeLines: [Int: HugeLineInfo]
    var markdownLineStates: [MarkdownLineStyleState]?
    /// False when the (re)scanned non-prose document holds no long line — the
    /// document stays horizontally scrolling and `rowCounts` is empty.
    var wraps: Bool
  }

  /// Captures the build inputs, or `nil` when no immutable source exists for
  /// the current backend (then the caller measures synchronously).
  private func makeWrapBuildInput(recomputeLongLine: Bool) -> WrapBuildInput? {
    let source: (any WrapMeasurementReading)?
    if let editableBuffer {
      source = editableBuffer.takeReadSnapshot()
    } else if let largeFile = readOnlyDocument as? LargeFile {
      source = largeFile
    } else if let readOnlyBuffer = readOnlyDocument as? TextBuffer {
      source = readOnlyBuffer.takeReadSnapshot()
    } else {
      source = nil
    }
    guard let source else { return nil }
    return WrapBuildInput(
      source: source,
      width: wrapContentWidth,
      font: font,
      markdownTypography: usesMarkdownDocumentLayout ? markdownTypography : nil,
      wrapsLines: wrapsLines,
      scanLongLines: !wrapsLines && (recomputeLongLine || !longLineDecisionValid),
      wrapsWithoutScan: documentWraps,
      longLineWrapThreshold: longLineWrapThreshold,
      drawnCharacterCap: maximumDrawnCharactersPerLine,
      fetchedBytesPerLineCap: maximumFetchedBytesPerLine,
      chunkLineCount: max(1, wrapBuildChunkLineCount),
      hugeColumns: hugeLineColumns
    )
  }

  /// Starts (or restarts) the chunked background build for the current state.
  private func scheduleWrapBuild(recomputeLongLine: Bool) {
    guard let input = makeWrapBuildInput(recomputeLongLine: recomputeLongLine) else {
      buildWrapIndexNow(recomputeLongLine: recomputeLongLine)
      return
    }
    wrapBuildGeneration &+= 1
    let generation = wrapBuildGeneration
    let revision = reader?.revision ?? 0
    wrapBuildTargetWidth = input.width
    wrapBuildTask = Task.detached(priority: .userInitiated) { [weak self] in
      let outcome = Self.measureWrapOutcome(input: input)
      await MainActor.run { [weak self] in
        self?.completeWrapBuild(
          generation: generation, revision: revision, input: input, outcome: outcome)
      }
    }
  }

  /// Drops any in-flight build: the worker stops at its next chunk boundary,
  /// and a completion that still arrives is dropped by the generation check.
  private func cancelWrapBuild() {
    wrapBuildGeneration &+= 1
    wrapBuildTask?.cancel()
    wrapBuildTask = nil
    wrapBuildTargetWidth = -1
    // A superseding rebuild (edit, resize, document swap) owns the viewport
    // from here; restoring a stale image anchor would fight it.
    pendingViewportAnchor = nil
  }

  /// Validates a finished build against the current state and swaps it in, or
  /// restarts from the new state when the world moved while measuring.
  private func completeWrapBuild(
    generation: Int, revision: UInt64, input: WrapBuildInput, outcome: WrapBuildOutcome?
  ) {
    guard generation == wrapBuildGeneration else { return }  // superseded
    wrapBuildTask = nil
    wrapBuildTargetWidth = -1
    guard let outcome else { return }  // cancelled mid-build, successor owns the state
    // Content, width, or wrap mode moved while measuring: this outcome
    // describes a document that no longer exists, so measure the new one. The
    // splice keeps editing responsive in the meantime, so restarting is cheap
    // for the main thread.
    guard reader?.revision == revision, wrapContentWidth == input.width,
      wrapsLines == input.wrapsLines
    else {
      rebuildWrapIndex(recomputeLongLine: true)
      return
    }
    lastWrapWidth = input.width
    if input.scanLongLines {
      lineIsLong = outcome.lineIsLong
      longLineCount = outcome.longLineCount
    }
    longLineDecisionValid = true
    if let markdownLineStates = outcome.markdownLineStates {
      markdownLineStateCache = (revision, markdownLineStates)
      markdownLineStateBuildTargetRevision = nil
      markdownLineStateBuildTask?.cancel()
      markdownLineStateBuildTask = nil
      cachedBand = nil
    }
    if outcome.wraps {
      hugeLineInfo = outcome.hugeLines
      wrapRowCounts = outcome.rowCounts
      wrapIndex = WrapIndex(
        visualRowsPerLine: outcome.rowCounts,
        rowMetricsPerLine: markdownRowMetrics(
          states: outcome.markdownLineStates, lineCount: outcome.rowCounts.count),
        uniformRowHeight: layout.lineHeight)
    } else {
      wrapIndex = nil
      wrapRowCounts = nil
      hugeLineInfo = [:]
    }
    updateLayout()
    if let anchor = pendingViewportAnchor {
      // An image-driven relayout deferred its anchor to this swap: the new
      // metrics are live now, so keep the first visible line where it was.
      pendingViewportAnchor = nil
      restoreViewportAnchor(anchor)
    }
    invalidateVisibleArea()
  }

  /// Test hook: suspends until no background wrap build (including restarts) is
  /// in flight, so geometry assertions read the settled index.
  func settleWrapBuildsForTesting() async {
    var remainingIterations = 100  // bounded: a restart loop must converge
    while let task = wrapBuildTask, remainingIterations > 0 {
      remainingIterations -= 1
      await task.value
      await Task.yield()  // let the main-actor merge (and any restart) run
    }
  }

  /// The chunked measurement pass. Runs off the main actor against an immutable
  /// source; returns `nil` when cancelled between chunks. Mirrors
  /// `buildWrapIndexNow` exactly: same clipping, same long-line flags, same
  /// huge-line grid rows.
  private nonisolated static func measureWrapOutcome(input: WrapBuildInput) -> WrapBuildOutcome? {
    let totalLines = input.source.lineCount
    var lineIsLong: [Bool]?
    var longLineCount = 0
    if input.scanLongLines {
      // Phase 1 — flags only (no Core Text): cheap, and when the document turns
      // out not to wrap the row measurement below is skipped entirely, matching
      // the synchronous build's early exit.
      var flags: [Bool] = []
      flags.reserveCapacity(totalLines)
      var start = 0
      while start < totalLines {
        if Task.isCancelled { return nil }
        let count = min(input.chunkLineCount, totalLines - start)
        autoreleasepool {
          let band = input.source.text(
            forLineRange: start, count: count, maxBytesPerLine: input.fetchedBytesPerLineCap)
          for line in band.components(separatedBy: "\n") {
            flags.append((line as NSString).length > input.longLineWrapThreshold)
          }
        }
        start += count
      }
      longLineCount = flags.lazy.filter { $0 }.count
      lineIsLong = flags
    }
    let wraps =
      input.scanLongLines
      ? (input.wrapsLines || longLineCount > 0)
      : input.wrapsWithoutScan
    guard wraps else {
      return WrapBuildOutcome(
        rowCounts: [], lineIsLong: lineIsLong, longLineCount: longLineCount,
        hugeLines: [:], markdownLineStates: nil, wraps: false)
    }
    if let typography = input.markdownTypography {
      return measureMarkdownWrapOutcome(
        input: input,
        typography: typography,
        lineIsLong: lineIsLong,
        longLineCount: longLineCount)
    }
    // Phase 2 — per-line wrapped-row counts, one chunk of lines resident at a
    // time. The autoreleasepool bounds the NSAttributedString churn per chunk.
    var counts: [Int] = []
    counts.reserveCapacity(totalLines)
    var hugeLines: [Int: HugeLineInfo] = [:]
    var start = 0
    while start < totalLines {
      if Task.isCancelled { return nil }
      let count = min(input.chunkLineCount, totalLines - start)
      autoreleasepool {
        let band = input.source.text(
          forLineRange: start, count: count, maxBytesPerLine: input.fetchedBytesPerLineCap)
        for (offset, raw) in band.components(separatedBy: "\n").enumerated() {
          let line = start + offset
          let text =
            raw.count > input.drawnCharacterCap
            ? String(raw.prefix(input.drawnCharacterCap)) : raw
          var gridRows: Int?
          if (text as NSString).length >= input.drawnCharacterCap {
            // Clipped at the display cap: resolve the true length; a genuinely
            // huge line folds on the fixed-column grid instead of a layout.
            let content = Self.hugeContent(of: line, source: input.source)
            if content.length > input.drawnCharacterCap {
              hugeLines[line] = HugeLineInfo(start: content.start, length: content.length)
              gridRows = max(1, (content.length + input.hugeColumns - 1) / input.hugeColumns)
            }
          }
          counts.append(
            gridRows
              ?? Self.wrapRowCount(
                text: text, width: input.width, font: input.font,
                maximumRows: input.drawnCharacterCap))
        }
      }
      start += count
    }
    return WrapBuildOutcome(
      rowCounts: counts, lineIsLong: lineIsLong, longLineCount: longLineCount,
      hugeLines: hugeLines, markdownLineStates: nil, wraps: true)
  }

  /// Markdown wrap measurement must use the same styled fonts as drawing and
  /// hit-testing. It runs off the main actor with a precomputed typography table,
  /// so no AppKit font conversion or appearance lookup happens on the worker.
  private nonisolated static func measureMarkdownWrapOutcome(
    input: WrapBuildInput,
    typography: MarkdownTypography,
    lineIsLong: [Bool]?,
    longLineCount: Int
  ) -> WrapBuildOutcome? {
    if Task.isCancelled { return nil }
    let totalLines = input.source.lineCount
    let text = input.source.text(
      forLineRange: 0, count: totalLines, maxBytesPerLine: input.fetchedBytesPerLineCap)
    if Task.isCancelled { return nil }
    let lines = Array(text.components(separatedBy: "\n").prefix(totalLines))
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    var counts: [Int] = []
    counts.reserveCapacity(totalLines)
    var hugeLines: [Int: HugeLineInfo] = [:]
    for line in 0..<totalLines {
      if Task.isCancelled { return nil }
      let raw = line < lines.count ? lines[line] : ""
      let display =
        raw.count > input.drawnCharacterCap ? String(raw.prefix(input.drawnCharacterCap)) : raw
      var gridRows: Int?
      if (display as NSString).length >= input.drawnCharacterCap {
        let content = Self.hugeContent(of: line, source: input.source)
        if content.length > input.drawnCharacterCap {
          hugeLines[line] = HugeLineInfo(start: content.start, length: content.length)
          gridRows = max(1, (content.length + input.hugeColumns - 1) / input.hugeColumns)
        }
      }
      let state = line < states.count ? states[line] : .plain
      let attributed = TextDocumentSyntaxHighlighter.markdownMeasurementLine(
        display, font: input.font, state: state, typography: typography)
      let lineWidth = markdownWrapContentWidth(baseWidth: input.width, state: state)
      counts.append(
        gridRows
          ?? Self.wrapRowCount(
            attributed: attributed, width: lineWidth, maximumRows: input.drawnCharacterCap))
    }
    return WrapBuildOutcome(
      rowCounts: counts,
      lineIsLong: lineIsLong,
      longLineCount: longLineCount,
      hugeLines: hugeLines,
      markdownLineStates: states,
      wraps: true)
  }

  /// A huge line's content start (global UTF-16) and length, resolved from the
  /// immutable source — the worker-side twin of `hugeLineContent(_:)`.
  private nonisolated static func hugeContent(
    of line: Int, source: any WrapMeasurementReading
  ) -> (start: Int, length: Int) {
    let start = (try? source.position(forLine: line, columnUTF16: 0).utf16) ?? 0
    // A column past the content clamps to the line's content end (terminator
    // excluded), so the difference is the content's UTF-16 length.
    let end = (try? source.position(forLine: line, columnUTF16: source.utf16Length))?.utf16 ?? start
    return (start, max(0, end - start))
  }

  /// Number of visual rows `text` occupies at `width` in `font`. Pure, so the
  /// background worker and the main-actor paths measure identically.
  private nonisolated static func wrapRowCount(
    text: String, width: CGFloat, font: NSFont, maximumRows: Int
  ) -> Int {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    return wrapRowCount(attributed: attributed, width: width, maximumRows: maximumRows)
  }

  private nonisolated static func wrapRowCount(
    attributed: NSAttributedString, width: CGFloat, maximumRows: Int
  ) -> Int {
    return LineWrap.visualRowStartOffsets(of: attributed, width: width, maximumRows: maximumRows)
      .count
  }

  /// Recomputes the wrap index for just the lines a change rewrote, splicing
  /// their new row counts into place rather than re-wrapping the whole document
  /// — the difference between an instant Return/paste/undo and a hitch that
  /// grows with the file. `change` is in post-edit coordinates. Falls back to a
  /// full rebuild whenever the splice is not provably safe.
  private func updateWrapIndex(afterChange change: TextChange) {
    // Resolve the rewritten line band [startLine, startLine + insertedBreaks]
    // in the new document. The prefix before the change is identical on both
    // sides, so `startLine` is also where the old band began.
    guard let buffer = reader,
      let startPosition = try? buffer.position(forUTF16: change.startUTF16),
      let newEndPosition = try? buffer.position(
        forUTF16: change.startUTF16 + change.newLengthUTF16)
    else {
      rebuildWrapIndex()
      return
    }
    let startLine = startPosition.line
    let insertedBreaks = newEndPosition.line - startLine
    if let counts = wrapRowCounts {
      spliceWrapIndex(
        counts, startLine: startLine, insertedBreaks: insertedBreaks,
        utf16Delta: change.newLengthUTF16 - change.oldLengthUTF16)
    } else {
      updateNoWrapDecision(startLine: startLine, insertedBreaks: insertedBreaks)
    }
  }

  /// Maintains the horizontal-scroll (no-index) state across a change by
  /// scanning only the rewritten lines: the document stays scrolling unless the
  /// change introduced its first long line, which flips it to wrapping. Keeps
  /// edits in a large no-wrap document O(rewritten lines), not O(document).
  private func updateNoWrapDecision(startLine: Int, insertedBreaks: Int) {
    // Prose without an index, or a long-line decision that was never made at a
    // valid width, means the last build bailed (zero width or over budget).
    // Re-evaluate through the full build, which re-checks those bounds first
    // and re-bails cheaply without reading the document.
    guard !wrapsLines, longLineCount == 0, longLineDecisionValid, var flags = lineIsLong,
      let buffer = reader
    else {
      rebuildWrapIndex()
      return
    }
    let removedBreaks = insertedBreaks - (buffer.lineCount - flags.count)
    let oldEndLine = startLine + removedBreaks
    guard removedBreaks >= 0, startLine >= 0, oldEndLine < flags.count else {
      rebuildWrapIndex()
      return
    }
    let newTexts = displayLineStrings(forLineRange: startLine, count: insertedBreaks + 1)
    guard newTexts.count == insertedBreaks + 1 else {
      rebuildWrapIndex()
      return
    }
    let newFlags = newTexts.map { ($0 as NSString).length > longLineWrapThreshold }
    if newFlags.contains(true) {
      rebuildWrapIndex()  // first long line → the whole document starts wrapping
      return
    }
    flags.replaceSubrange(startLine...oldEndLine, with: newFlags)
    guard flags.count == buffer.lineCount else {
      rebuildWrapIndex()
      return
    }
    lineIsLong = flags
  }

  /// Splices the rewritten band's row counts (and long-line flags) into the
  /// active wrap index. Lines after the band keep their wrap untouched — only
  /// their indices (and a huge line's cached UTF-16 start) shift by the change's
  /// line and length deltas.
  private func spliceWrapIndex(
    _ counts: [Int], startLine: Int, insertedBreaks: Int, utf16Delta: Int
  ) {
    guard let buffer = reader, lastWrapWidth == wrapContentWidth, startLine >= 0 else {
      rebuildWrapIndex()
      return
    }
    let newLineCount = buffer.lineCount
    let removedBreaks = insertedBreaks - (newLineCount - counts.count)
    let oldEndLine = startLine + removedBreaks
    guard removedBreaks >= 0, oldEndLine < counts.count else {
      rebuildWrapIndex()
      return
    }
    // A huge line inside the rewritten band changes its grid shape (or stops
    // being huge); re-resolving true lengths is the rebuild's job. Rare, so the
    // cost is acceptable; documents without huge lines never reach this.
    if hugeLineInfo.keys.contains(where: { $0 >= startLine && $0 <= oldEndLine }) {
      rebuildWrapIndex()
      return
    }
    let newTexts = displayLineStrings(forLineRange: startLine, count: insertedBreaks + 1)
    guard newTexts.count == insertedBreaks + 1 else {
      rebuildWrapIndex()
      return
    }
    // A rewritten line clipped at the display cap may actually be enormous; the
    // rebuild resolves its true length and grid row count. Also rare.
    if newTexts.contains(where: { ($0 as NSString).length >= maximumDrawnCharactersPerLine }) {
      rebuildWrapIndex()
      return
    }
    let markdownStates = usesMarkdownDocumentLayout ? markdownLineStates(for: buffer) : nil
    if usesMarkdownDocumentLayout, markdownStates == nil {
      rebuildWrapIndex()
      return
    }
    // Keep the long-line bookkeeping current so a non-prose document leaves wrap
    // mode the moment its last long line is rewritten away (not only on a later
    // reload). Prose has no `lineIsLong` and always wraps, so it is unaffected.
    if !wrapsLines {
      guard var flags = lineIsLong, flags.count == counts.count else {
        rebuildWrapIndex()
        return
      }
      let newFlags = newTexts.map { ($0 as NSString).length > longLineWrapThreshold }
      let removedLong = flags[startLine...oldEndLine].lazy.filter { $0 }.count
      let insertedLong = newFlags.lazy.filter { $0 }.count
      flags.replaceSubrange(startLine...oldEndLine, with: newFlags)
      lineIsLong = flags
      longLineCount += insertedLong - removedLong
      if longLineCount == 0 {
        rebuildWrapIndex(recomputeLongLine: false)  // last long line gone → scroll
        return
      }
    }
    // Shift the huge lines past the band: their content is untouched, but their
    // line index moves by the line delta and their cached global UTF-16 start by
    // the length delta (positions at or past the old band's end shift exactly by
    // newLength - oldLength). Huge lines before the band are untouched.
    let lineDelta = insertedBreaks - removedBreaks
    if !hugeLineInfo.isEmpty, lineDelta != 0 || utf16Delta != 0 {
      var shifted: [Int: HugeLineInfo] = [:]
      shifted.reserveCapacity(hugeLineInfo.count)
      for (line, info) in hugeLineInfo {
        if line < startLine {
          shifted[line] = info
        } else {
          shifted[line + lineDelta] =
            HugeLineInfo(start: info.start + utf16Delta, length: info.length)
        }
      }
      hugeLineInfo = shifted
    }
    var counts = counts
    counts.replaceSubrange(
      startLine...oldEndLine,
      with: newTexts.enumerated().map { offset, text in
        let line = startLine + offset
        let state =
          line < (markdownStates?.count ?? 0) ? markdownStates?[line] ?? .plain : .plain
        let lineWidth =
          usesMarkdownDocumentLayout
          ? Self.markdownWrapContentWidth(baseWidth: wrapContentWidth, state: state)
          : wrapContentWidth
        return wrapRowCount(text: text, width: lineWidth, markdownLineState: state)
      })
    guard counts.count == newLineCount else {
      rebuildWrapIndex()
      return
    }
    wrapRowCounts = counts
    wrapIndex = WrapIndex(
      visualRowsPerLine: counts,
      rowMetricsPerLine: markdownRowMetrics(states: markdownStates, lineCount: counts.count),
      uniformRowHeight: layout.lineHeight)
  }

  /// Number of visual rows `text` occupies at `width`.
  private func wrapRowCount(
    text: String,
    width: CGFloat,
    markdownLineState: MarkdownLineStyleState = .plain
  ) -> Int {
    if usesMarkdownDocumentLayout {
      let attributed = TextDocumentSyntaxHighlighter.markdownMeasurementLine(
        text, font: font, state: markdownLineState, typography: markdownTypography)
      return Self.wrapRowCount(
        attributed: attributed, width: width, maximumRows: maximumDrawnCharactersPerLine)
    }
    return Self.wrapRowCount(
      text: text, width: width, font: font, maximumRows: maximumDrawnCharactersPerLine)
  }

  /// Total visual rows in the document (equals the logical line count when not
  /// wrapping).
  private var totalVisualRows: Int { wrapIndex?.totalVisualRows ?? lineCount }

  /// The first visual row of a logical line (the line index itself when not
  /// wrapping).
  private func firstVisualRow(ofLine line: Int) -> Int {
    wrapIndex?.firstVisualRow(ofLine: line) ?? min(max(0, line), max(0, lineCount - 1))
  }

  /// The logical line and the row within it that a global visual row falls in.
  private func lineLocation(ofVisualRow row: Int) -> (line: Int, rowInLine: Int) {
    if let wrapIndex { return wrapIndex.location(ofVisualRow: row) }
    return (min(max(0, row), max(0, lineCount - 1)), 0)
  }

  /// The row height of `line` (the uniform height unless the line carries
  /// custom metrics, e.g. a slim table delimiter row or a heading).
  private func rowHeight(forLine line: Int) -> CGFloat {
    wrapIndex?.rowHeight(ofLine: line, uniformRowHeight: layout.lineHeight) ?? layout.lineHeight
  }

  /// The breathing inset above `line`'s first visual row (heading air).
  private func leadingInset(forLine line: Int) -> CGFloat {
    wrapIndex?.rowMetrics(ofLine: line, uniformRowHeight: layout.lineHeight).leadingInset ?? 0
  }

  /// The y offset of the top of `line`.
  private func yOffset(ofLine line: Int) -> CGFloat {
    wrapIndex?.yOffset(ofLine: line, uniformRowHeight: layout.lineHeight)
      ?? CGFloat(firstVisualRow(ofLine: line)) * layout.lineHeight
  }

  /// The y offset of the top of a global visual row.
  private func yOffset(ofVisualRow row: Int) -> CGFloat {
    wrapIndex?.yOffset(ofVisualRow: row, uniformRowHeight: layout.lineHeight)
      ?? CGFloat(row) * layout.lineHeight
  }

  /// The line and row-within-line whose vertical span contains `y`.
  private func rowLocation(forY y: CGFloat) -> (line: Int, rowInLine: Int) {
    if let wrapIndex {
      return wrapIndex.location(forY: y, uniformRowHeight: layout.lineHeight)
    }
    guard layout.lineHeight > 0 else { return (0, 0) }
    return lineLocation(ofVisualRow: Int((y / layout.lineHeight).rounded(.down)))
  }

  /// Total document content height (the variable-height-aware replacement for
  /// `totalVisualRows * lineHeight`).
  private var totalContentHeight: CGFloat {
    wrapIndex?.totalHeight(uniformRowHeight: layout.lineHeight)
      ?? CGFloat(totalVisualRows) * layout.lineHeight
  }

  /// UTF-16 start offsets of each visual row within `line` (just `[0]` when the
  /// document is not wrapping). `attributed` is the line's displayed string.
  private func visualRowStartOffsets(ofLine line: Int, attributed: NSAttributedString) -> [Int] {
    guard wrapIndex != nil else { return [0] }
    return LineWrap.visualRowStartOffsets(
      of: attributed, width: lineWrapContentWidth(forLine: line),
      maximumRows: maximumDrawnCharactersPerLine)
  }

  /// The visual-row index within a line for `column`, given the line's row starts.
  private func visualRowIndex(forColumn column: Int, starts: [Int]) -> Int {
    var index = 0
    for (rowIndex, start) in starts.enumerated() {
      if start <= column { index = rowIndex } else { break }
    }
    return index
  }

  /// The global visual row a caret position sits on.
  private func visualRow(of endpoint: TextSelection.Endpoint) -> Int {
    if let length = hugeLength(endpoint.line) {
      let row = min(hugeRowCount(utf16Length: length) - 1, endpoint.columnUTF16 / hugeLineColumns)
      return firstVisualRow(ofLine: endpoint.line) + row
    }
    let attributed = attributedLine(forLine: endpoint.line)
    let starts = visualRowStartOffsets(ofLine: endpoint.line, attributed: attributed)
    return firstVisualRow(ofLine: endpoint.line)
      + visualRowIndex(forColumn: endpoint.columnUTF16, starts: starts)
  }

  /// The UTF-16 range `[start, end)` of visual row `rowIndex` within `attributed`.
  private func rowRange(_ rowIndex: Int, starts: [Int], length: Int) -> (start: Int, end: Int) {
    let safe = min(max(0, rowIndex), starts.count - 1)
    let start = starts[safe]
    let end = safe + 1 < starts.count ? starts[safe + 1] : length
    return (start, end)
  }

  /// Width of the line-number gutter for the current line count, or 0 when hidden.
  var gutterWidth: CGFloat {
    showsLineNumbers ? GutterMetrics.width(lineCount: lineCount, font: gutterFont) : 0
  }

  init() {
    super.init(frame: .zero)
    registerActiveFocusObservers()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override var isFlipped: Bool { true }

  // The view fills every pixel of any dirty rect with the background before
  // drawing text, so it is fully opaque. Declaring this avoids the layer-backed
  // host compositing it against whatever is behind, which showed as brief blanks
  // while scrolling.
  override var isOpaque: Bool { true }

  // Opt out of responsive scrolling. That optimization renders an overdraw cache
  // beyond the visible rect and reuses it as the scroll offset changes — but this
  // view synthesizes a multi-million-point frame and draws viewport-relative
  // chrome (the pinned line-number gutter, caret, and selection), so the cache is
  // shown at a stale offset: rows tear (the content appears to jump by a line),
  // the gutter is left unpainted, and fast scrolls reveal blank bands before the
  // next draw. Legacy synchronous scrolling redraws the (cheap) visible band on
  // every scroll instead, which stays correct.
  override class var isCompatibleWithResponsiveScrolling: Bool { false }

  // Text-editing I-beam over the text body, like a typical editor; the
  // line-number gutter keeps the default arrow. Cursor rects are declarative —
  // AppKit switches the cursor automatically as the pointer crosses the region
  // boundary and re-evaluates them even when the pointer is already inside, so
  // the cursor is correct without depending on a scroll to refresh it. The
  // gutter is pinned to the left of the visible area (it tracks horizontal
  // scroll), so its right edge sits at the scroll origin plus the gutter width;
  // the I-beam covers the visible band to the right of it. `viewportDidScroll`
  // and `updateLayout` invalidate these rects so the boundary stays aligned as
  // the document scrolls horizontally or the gutter width changes.
  //
  // Fragile foundation, measured 2026-06-12: a SwiftUI `.clipShape` around this
  // editor used to suppress these cursor rects — they registered with correct
  // window geometry, yet the arrow won until the clip was removed. The document
  // card now clips again so the glass field can show through its rounded
  // corners; keep this cursor contract under manual review when changing the
  // card chrome.
  override func resetCursorRects() {
    let gutterEdge = (enclosingScrollView?.contentView.bounds.origin.x ?? 0) + gutterWidth
    if let textRect = Self.iBeamCursorRect(visible: visibleRect, gutterEdge: gutterEdge) {
      addCursorRect(textRect, cursor: .iBeam)
    }
    // A pointing hand over each visible copy control (added after the I-beam
    // so it wins inside the button rect).
    if usesMarkdownDocumentLayout, let range = visibleMarkdownLineRange() {
      for target in markdownCodeCopyTargets(inLineRange: range) {
        addCursorRect(target.buttonRect, cursor: .pointingHand)
      }
    }
    if let toggleRect = markdownViewModeToggleCursorRect() {
      addCursorRect(toggleRect, cursor: .pointingHand)
    }
  }

  // Cursor rects alone go stale on two paths: after the pointer visits the
  // titlebar tab strip, whose SwiftUI pointer handling resets the cursor to
  // the arrow after the rect's enter event has already fired, and under the
  // SwiftUI card clip used to make the glass field show through rounded
  // corners. Correcting on every mouse move/cursor update inside the editor is
  // self-healing regardless of where the pointer came from.
  private enum HoverCursor {
    case iBeam, arrow, pointingHand

    var nsCursor: NSCursor {
      switch self {
      case .iBeam: .iBeam
      case .arrow: .arrow
      case .pointingHand: .pointingHand
      }
    }
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let cursorCorrectionTrackingArea {
      removeTrackingArea(cursorCorrectionTrackingArea)
    }
    let area = NSTrackingArea(
      rect: .zero,
      options: [
        .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect,
      ],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    cursorCorrectionTrackingArea = area
  }

  private var cursorCorrectionTrackingArea: NSTrackingArea?

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    applyHoverCursor(for: event)
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    applyHoverCursor(for: event)
  }

  override func cursorUpdate(with event: NSEvent) {
    super.cursorUpdate(with: event)
    applyHoverCursor(for: event)
  }

  private func applyHoverCursor(for event: NSEvent) {
    let desired = hoverCursor(at: convert(event.locationInWindow, from: nil))
    // Always set, even if `desired` matches the last value. SwiftUI/AppKit
    // ancestors can reset the cursor between move/update events while our local
    // desired state is unchanged.
    desired.nsCursor.set()
  }

  private func hoverCursor(at point: NSPoint) -> HoverCursor {
    if markdownViewModeToggleContains(point) {
      return .pointingHand
    }
    if codeCopyButtonContains(point) {
      return .pointingHand
    }
    let gutterEdge = (enclosingScrollView?.contentView.bounds.origin.x ?? 0) + gutterWidth
    return point.x >= gutterEdge ? .iBeam : .arrow
  }

  private func markdownViewModeToggleContains(_ point: NSPoint) -> Bool {
    markdownViewModeToggleCursorRect()?.contains(point) ?? false
  }

  private func markdownViewModeToggleCursorRect() -> NSRect? {
    guard showsMarkdownViewModeToggleCursorRect else { return nil }
    return Self.markdownViewModeToggleCursorRect(in: visibleRect)
  }

  private static func markdownViewModeToggleCursorRect(in visible: NSRect) -> NSRect {
    return NSRect(
      x: visible.maxX - MarkdownViewModeToggleMetrics.trailingPadding
        - MarkdownViewModeToggleMetrics.size,
      y: visible.minY + MarkdownViewModeToggleMetrics.topPadding,
      width: MarkdownViewModeToggleMetrics.size,
      height: MarkdownViewModeToggleMetrics.size)
  }

  /// Whether `point` (content coordinates) falls on a visible copy control.
  private func codeCopyButtonContains(_ point: NSPoint) -> Bool {
    guard usesMarkdownDocumentLayout, let range = visibleMarkdownLineRange() else { return false }
    return markdownCodeCopyTargets(inLineRange: range).contains { $0.buttonRect.contains(point) }
  }

  /// The I-beam region of the visible band: everything right of the pinned
  /// gutter's edge. `nil` when nothing is visible or the gutter spans the
  /// whole band.
  static func iBeamCursorRect(visible: NSRect, gutterEdge: CGFloat) -> NSRect? {
    guard !visible.isEmpty else { return nil }
    let textMinX = max(visible.minX, gutterEdge)
    let textRect = NSRect(
      x: textMinX, y: visible.minY, width: visible.maxX - textMinX, height: visible.height)
    return textRect.width > 0 ? textRect : nil
  }

  /// Loads an editable document. Editing and saving are enabled when the host
  /// also sets `isEditable`.
  func setBuffer(_ buffer: TextBuffer?) {
    editableBuffer = buffer
    readOnlyDocument = nil
    didSetDocument()
  }

  /// Loads a read-only document — a file too large to load into an editable
  /// ``TextBuffer``. There is no editable backing, so editing and saving stay
  /// inert regardless of `isEditable`; the same rendering, selection, and
  /// navigation paths drive it through ``reader``.
  func setReadOnlyDocument(_ document: (any TextDocumentReading)?) {
    editableBuffer = nil
    readOnlyDocument = document
    didSetDocument()
  }

  /// Whether `document` is already the active read-only backend, so a SwiftUI
  /// update can skip a redundant reset (which would otherwise drop the scroll
  /// position and selection).
  func isShowingReadOnlyDocument(_ document: AnyObject) -> Bool {
    guard let current = readOnlyDocument else { return false }
    return (current as AnyObject) === document
  }

  /// Shared reset after swapping the document backend: drop caches and selection,
  /// rebuild the wrap index for the new content, and scroll back to the top-left
  /// so a reused scroll view does not keep the previous file's position.
  private func didSetDocument() {
    cachedBand = nil
    markdownLineStateCache = nil
    cancelMarkdownLineStateBuild()
    markdownImageStoreStorage?.reset()
    // Drop any copy confirmation so it cannot paint on a same-indexed block in
    // the new document; the token bump defuses the pending revert.
    copiedCodeBlockStartLine = nil
    copiedCodeBlockToken &+= 1
    maxObservedLineWidth = 0
    selection = nil
    isSelecting = false
    verticalGoalX = nil
    composition = nil
    // A save in flight (if any) is tracked per buffer in `saveTracker`, not on the
    // view, so it is intentionally not reset here: switching back to a buffer that
    // is still saving keeps its edits paused, and the save's completion still marks
    // the correct buffer.
    rebuildWrapIndex()  // the previous buffer's wrap index does not apply
    updateLayout()
    // A new document always opens at the top-left; otherwise a reused scroll view
    // would keep the previous file's scroll position. With content insets, the
    // rest position sits above the content origin so the first line keeps its
    // breathing room without scrolling up first.
    if let scrollView = enclosingScrollView {
      let insets = scrollView.contentInsets
      scrollView.contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
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

  /// Called when the clip view scrolls. Repaints the visible band on every scroll:
  /// copy-on-scroll is disabled (it tore rows on this synthesized-height view), and
  /// the gutter, caret, and selection are drawn relative to the current viewport,
  /// so the whole visible band — not just a newly exposed strip — must be redrawn
  /// to stay aligned. The band fetch and highlight are bounded to the visible rows,
  /// so this stays cheap even for a multi-gigabyte document.
  func viewportDidScroll() {
    invalidateVisibleArea()
    // The gutter is viewport-pinned, so its right edge (the I-beam boundary)
    // shifts with horizontal scroll; re-establish the cursor rects for it.
    window?.invalidateCursorRects(for: self)
  }

  // MARK: Accessibility

  // Expose the viewer as a text area so it resolves to `textViews` (matching the
  // editable editor) for XCUITest and is announced as a text region. The whole
  // document is never returned at once (it could be gigabytes); instead VoiceOver
  // reads it through the range/line APIs below, each bounded so no single request
  // materializes more than `maximumAccessibilityStringLength`.

  override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

  override func isAccessibilityElement() -> Bool { reader != nil }

  override func accessibilityValue() -> Any? { nil }

  override func accessibilitySelectedText() -> String? {
    // Assistive tech may poll this repeatedly, so bound it well below the (much
    // larger) explicit-copy limit; an over-budget selection reports no text.
    guard let span = selectionByteSpan(), span <= maximumAccessibilitySelectedTextByteCount else {
      return nil
    }
    return selectedText()
  }

  override func accessibilityNumberOfCharacters() -> Int { reader?.utf16Length ?? 0 }

  /// The selection as a global UTF-16 range (a collapsed range at the caret when
  /// nothing is selected).
  override func accessibilitySelectedTextRange() -> NSRange {
    guard let range = currentSelectionUTF16Range() else {
      return NSRange(location: 0, length: 0)
    }
    return NSRange(location: range.start, length: max(0, range.end - range.start))
  }

  /// The text for a UTF-16 range, in the same full-document coordinates as
  /// `accessibilityNumberOfCharacters`/`accessibilityRange(forLine:)` (so a line
  /// longer than the display clip still reads correctly). Returns `nil` for an
  /// invalid or over-budget range — including when the spanned lines are too long
  /// to read without materializing a huge string — so VoiceOver asks for a smaller
  /// span. The bounds are computed without adding `location + length`, which could
  /// overflow on a hostile range from the accessibility client.
  override func accessibilityString(for range: NSRange) -> String? {
    guard let buffer = reader, range.location >= 0, range.length >= 0,
      range.location <= buffer.utf16Length,
      range.length <= buffer.utf16Length - range.location,
      range.length <= maximumAccessibilityStringLength,
      let start = try? buffer.position(forUTF16: range.location),
      let end = try? buffer.position(forUTF16: range.location + range.length),
      spannedLineLength(fromLine: start.line, toLine: end.line) <= maximumAccessibilityStringLength
    else {
      return nil
    }
    return bufferText(
      fromLine: start.line, fromColumn: start.columnUTF16,
      toLine: end.line, toColumn: end.columnUTF16)
  }

  /// Total UTF-16 length of lines `[fromLine, toLine]` (including terminators),
  /// used to bound an unclipped read.
  private func spannedLineLength(fromLine: Int, toLine: Int) -> Int {
    let start = lineUTF16Range(fromLine).location
    return max(0, NSMaxRange(lineUTF16Range(toLine)) - start)
  }

  /// The line index containing a UTF-16 character offset.
  override func accessibilityLine(for index: Int) -> Int {
    guard let buffer = reader, index >= 0, index <= buffer.utf16Length,
      let position = try? buffer.position(forUTF16: index)
    else {
      return 0
    }
    return position.line
  }

  /// The UTF-16 range of a line, including its trailing newline.
  override func accessibilityRange(forLine line: Int) -> NSRange {
    lineUTF16Range(line)
  }

  /// The line the caret currently sits on.
  override func accessibilityInsertionPointLineNumber() -> Int {
    selection?.head.line ?? 0
  }

  /// The UTF-16 range of the text currently on screen, so VoiceOver can read the
  /// visible band without scanning the whole document.
  override func accessibilityVisibleCharacterRange() -> NSRange {
    visibleUTF16Range() ?? NSRange(location: 0, length: 0)
  }

  /// The UTF-16 range of `line` including its trailing newline; empty when out of
  /// range.
  private func lineUTF16Range(_ line: Int) -> NSRange {
    guard let buffer = reader, line >= 0, line < buffer.lineCount,
      let start = (try? buffer.position(forLine: line, columnUTF16: 0))?.utf16
    else {
      return NSRange(location: 0, length: 0)
    }
    let end: Int
    if line + 1 < buffer.lineCount,
      let next = (try? buffer.position(forLine: line + 1, columnUTF16: 0))?.utf16
    {
      end = next
    } else {
      end = buffer.utf16Length
    }
    return NSRange(location: start, length: max(0, end - start))
  }

  /// The UTF-16 range spanned by the visible visual rows' logical lines.
  private func visibleUTF16Range() -> NSRange? {
    guard reader != nil else { return nil }
    let rows = visibleVisualRowRange(in: visibleRect)
    guard !rows.isEmpty else { return NSRange(location: 0, length: 0) }
    let firstLine = lineLocation(ofVisualRow: rows.lowerBound).line
    let lastLine = lineLocation(ofVisualRow: rows.upperBound - 1).line
    let start = lineUTF16Range(firstLine).location
    let lastRange = lineUTF16Range(lastLine)
    return NSRange(location: start, length: max(0, NSMaxRange(lastRange) - start))
  }

  // MARK: First responder & focus

  override var acceptsFirstResponder: Bool { reader != nil }

  override func becomeFirstResponder() -> Bool {
    let didBecome = super.becomeFirstResponder()
    if didBecome {
      updateCaretBlinkTimerForFocusState(assumingFirstResponder: true)
      invalidateVisibleArea()
      onFocusChange?(true)
    }
    return didBecome
  }

  override func resignFirstResponder() -> Bool {
    let didResign = super.resignFirstResponder()
    if didResign {
      // Abandon any in-progress composition rather than committing it on a focus
      // change; the input context deactivates with the responder.
      composition = nil
      stopCaretBlinking()
      invalidateVisibleArea()
      onFocusChange?(false)
    }
    return didResign
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // Stop the timer when detached so it does not keep the view alive.
    if window == nil {
      stopCaretBlinking()
    } else {
      updateCaretBlinkTimerForFocusState()
    }
  }

  // MARK: Caret blink

  /// Whether the app and window are active enough for a first responder caret to
  /// communicate real keyboard focus. AppKit keeps `firstResponder` when Locus
  /// moves behind another app, so first-responder status alone is not a visible
  /// focus contract.
  private var isActiveKeyWindow: Bool {
    NSApp.isActive && window?.isKeyWindow == true
  }

  private var hasActiveKeyboardFocus: Bool {
    hasActiveKeyboardFocus(assumingFirstResponder: false)
  }

  private func hasActiveKeyboardFocus(assumingFirstResponder: Bool) -> Bool {
    (assumingFirstResponder || window?.firstResponder === self) && isActiveKeyWindow
  }

  /// Whether the plain insertion caret should be blinking right now: focused in
  /// the active key window, not composing (the marked-text caret stays solid),
  /// and a collapsed selection.
  /// Pure for testability.
  nonisolated static func caretShouldBlink(
    isFirstResponder: Bool, isActiveKeyWindow: Bool, isComposing: Bool,
    selectionIsEmpty: Bool
  ) -> Bool {
    isFirstResponder && isActiveKeyWindow && !isComposing && selectionIsEmpty
  }

  private var showsBlinkingCaret: Bool {
    guard isEditable else { return false }
    return Self.caretShouldBlink(
      isFirstResponder: window?.firstResponder === self,
      isActiveKeyWindow: isActiveKeyWindow,
      isComposing: composition != nil,
      selectionIsEmpty: selection?.isEmpty == true)
  }

  private func registerActiveFocusObservers() {
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(applicationActiveFocusStateDidChange(_:)),
      name: NSApplication.didBecomeActiveNotification,
      object: nil)
    center.addObserver(
      self,
      selector: #selector(applicationActiveFocusStateDidChange(_:)),
      name: NSApplication.didResignActiveNotification,
      object: nil)
    center.addObserver(
      self,
      selector: #selector(windowActiveFocusStateDidChange(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil)
    center.addObserver(
      self,
      selector: #selector(windowActiveFocusStateDidChange(_:)),
      name: NSWindow.didResignKeyNotification,
      object: nil)
  }

  @objc private func applicationActiveFocusStateDidChange(_ notification: Notification) {
    activeFocusStateDidChange()
  }

  @objc private func windowActiveFocusStateDidChange(_ notification: Notification) {
    guard let notificationWindow = notification.object as? NSWindow, notificationWindow === window
    else { return }
    activeFocusStateDidChange()
  }

  private func activeFocusStateDidChange() {
    updateCaretBlinkTimerForFocusState()
    invalidateVisibleArea()
  }

  private func updateCaretBlinkTimerForFocusState(assumingFirstResponder: Bool = false) {
    guard isEditable, hasActiveKeyboardFocus(assumingFirstResponder: assumingFirstResponder) else {
      stopCaretBlinking()
      return
    }
    if caretBlinkTimer == nil {
      startCaretBlinking()
    }
  }

  /// (Re)starts the blink in the solid phase. Uses target/action (not a closure) to
  /// avoid a `Sendable` capture of this non-`Sendable` view; the strong reference
  /// the timer holds is released by `stopCaretBlinking`.
  func startCaretBlinking() {
    caretBlinkTimer?.invalidate()
    caretBlinkOn = true
    caretBlinkTimer = Timer.scheduledTimer(
      timeInterval: caretBlinkInterval, target: self,
      selector: #selector(caretBlinkTimerFired), userInfo: nil, repeats: true)
  }

  func stopCaretBlinking() {
    caretBlinkTimer?.invalidate()
    caretBlinkTimer = nil
    caretBlinkOn = true
  }

  /// Keeps the caret solid right after the user acts (typing, moving, clicking). It
  /// restarts the blink timer (not just the phase flag) so a toggle that was about
  /// to fire cannot hide the caret a few milliseconds after the action. When not
  /// blinking (unfocused, no timer) it only records the solid phase for next focus.
  func showCaretSolid() {
    if caretBlinkTimer != nil {
      startCaretBlinking()
    } else {
      caretBlinkOn = true
    }
  }

  @objc private func caretBlinkTimerFired() {
    guard showsBlinkingCaret else {
      // Nothing to blink (e.g. a range is selected): make sure the caret is solid.
      if !caretBlinkOn {
        caretBlinkOn = true
        invalidateVisibleArea()
      }
      return
    }
    caretBlinkOn.toggle()
    invalidateVisibleArea()
  }

  // MARK: Mouse selection

  override func mouseDown(with event: NSEvent) {
    guard reader != nil else { return }
    let point = convert(event.locationInWindow, from: nil)
    // A click on a code block's copy control copies and consumes the event,
    // without moving the caret or starting a selection.
    if handleMarkdownCodeCopyClick(at: point) {
      window?.makeFirstResponder(self)
      return
    }
    // Finalize any in-progress composition before moving the caret.
    if hasMarkedText() { unmarkText() }
    window?.makeFirstResponder(self)
    let endpoint = caretEndpoint(at: point)
    // A double-click selects the word, a triple-click the whole line, a single
    // click places the caret. Each begins a drag that then extends at the matching
    // granularity (character / word / line).
    switch event.clickCount {
    case 3...:
      beginLineSelection(at: endpoint.line)
    case 2:
      beginWordSelection(at: endpoint)
    default:
      beginCaretSelection(at: endpoint)
    }
    showCaretSolid()
    invalidateVisibleArea()
  }

  /// Begins a character-granularity drag with a caret at `endpoint`.
  func beginCaretSelection(at endpoint: TextSelection.Endpoint) {
    selection = TextSelection(caretAt: endpoint)
    selectionGranularity = .character
    selectionAnchorRange = nil
    isSelecting = true
  }

  /// Begins a word-granularity drag, selecting the word at `endpoint`.
  func beginWordSelection(at endpoint: TextSelection.Endpoint) {
    let unit = wordSelection(at: endpoint)
    selection = unit
    selectionGranularity = .word
    selectionAnchorRange = (unit.start, unit.end)
    isSelecting = true
  }

  /// Begins a line-granularity drag, selecting the whole line.
  func beginLineSelection(at line: Int) {
    let unit = lineSelection(at: line)
    selection = unit
    selectionGranularity = .line
    selectionAnchorRange = (unit.start, unit.end)
    isSelecting = true
  }

  /// Extends the in-progress drag to `cursor` at the current granularity: by
  /// character, or by whole words/lines spanning from the anchored unit through
  /// the unit under the cursor (reversing when the cursor passes the anchor).
  func extendSelection(to cursor: TextSelection.Endpoint) {
    guard isSelecting else { return }
    switch selectionGranularity {
    case .character:
      selection?.head = cursor
    case .word:
      extendUnitSelection(cursorUnit: wordSelection(at: cursor))
    case .line:
      extendUnitSelection(cursorUnit: lineSelection(at: cursor.line))
    }
  }

  private func extendUnitSelection(cursorUnit: TextSelection) {
    guard let anchor = selectionAnchorRange else { return }
    selection = Self.extendedSelection(anchor: anchor, cursor: (cursorUnit.start, cursorUnit.end))
  }

  /// Spans a word/line drag from the anchored unit through the unit under the
  /// cursor, oriented so the head is on the cursor side (and never shrinks below
  /// the anchored unit). Pure, so the spanning logic is unit-testable.
  static func extendedSelection(
    anchor: (start: TextSelection.Endpoint, end: TextSelection.Endpoint),
    cursor: (start: TextSelection.Endpoint, end: TextSelection.Endpoint)
  ) -> TextSelection {
    if cursor.start >= anchor.start {
      return TextSelection(anchor: anchor.start, head: Swift.max(anchor.end, cursor.end))
    }
    return TextSelection(anchor: anchor.end, head: Swift.min(anchor.start, cursor.start))
  }

  /// The locale-aware word selection at `endpoint`, via the OS tokenizer (so CJK
  /// and other scripts segment correctly). An empty line, or a position in the
  /// empty area past the last character, yields a caret rather than a far-away word.
  func wordSelection(at endpoint: TextSelection.Endpoint) -> TextSelection {
    let line = attributedLine(forLine: endpoint.line).string as NSString
    guard line.length > 0, endpoint.columnUTF16 < line.length else {
      return TextSelection(caretAt: endpoint)
    }
    let word = Self.wordRange(in: line, at: endpoint.columnUTF16)
    return TextSelection(
      anchor: .init(line: endpoint.line, columnUTF16: word.location),
      head: .init(line: endpoint.line, columnUTF16: NSMaxRange(word)))
  }

  /// Selects the word containing `endpoint` (see `wordSelection(at:)`).
  func selectWord(at endpoint: TextSelection.Endpoint) {
    selection = wordSelection(at: endpoint)
  }

  /// The locale-aware word-boundary range (UTF-16) containing `index` in `string`,
  /// via the OS text tokenizer (so CJK and other scripts segment correctly).
  /// Falls back to the single composed character at `index` when the tokenizer
  /// reports no token there.
  static func wordRange(in string: NSString, at index: Int) -> NSRange {
    let tokenizer = CFStringTokenizerCreate(
      kCFAllocatorDefault, string as CFString,
      CFRange(location: 0, length: string.length),
      kCFStringTokenizerUnitWordBoundary, CFLocaleCopyCurrent())
    CFStringTokenizerGoToTokenAtIndex(tokenizer, index)
    let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
    guard range.location != kCFNotFound, range.length > 0 else {
      return string.rangeOfComposedCharacterSequence(at: index)
    }
    return NSRange(location: range.location, length: range.length)
  }

  /// The whole-logical-line selection (its content, not the trailing newline).
  func lineSelection(at line: Int) -> TextSelection {
    let clamped = min(max(0, line), max(0, lineCount - 1))
    return TextSelection(
      anchor: .init(line: clamped, columnUTF16: 0),
      head: .init(line: clamped, columnUTF16: lineLengthUTF16(clamped)))
  }

  /// Selects the whole logical line (see `lineSelection(at:)`).
  func selectLine(at line: Int) {
    selection = lineSelection(at: line)
  }

  override func mouseDragged(with event: NSEvent) {
    guard isSelecting, selection != nil else { return }
    autoscroll(with: event)
    extendSelection(to: endpoint(at: convert(event.locationInWindow, from: nil)))
    invalidateVisibleArea()
  }

  override func mouseUp(with event: NSEvent) {
    isSelecting = false
  }

  /// Maps a point in this view's coordinates to the nearest (line, UTF-16 column)
  /// endpoint, clamped to the document. Internal so hit-testing can be tested.
  func endpoint(at point: NSPoint) -> TextSelection.Endpoint {
    // A click in the empty area padded below the last row lands at the document
    // end, regardless of x — not at the column nearest the click on the last line.
    if point.y >= totalContentHeight {
      let lastLine = max(0, lineCount - 1)
      return TextSelection.Endpoint(line: lastLine, columnUTF16: lineLengthUTF16(lastLine))
    }
    let (line, rowInLine) = rowLocation(forY: max(0, point.y))
    let textRelativeX = point.x - lineTextColumnX(forLine: line)
    if let length = hugeLength(line) {
      let rowStart = rowInLine * hugeLineColumns
      let rowText = hugeRowText(line: line, rowIndex: rowInLine, utf16Length: length)
      let columnInRow = columnUTF16(forX: textRelativeX, in: rowText)
      return TextSelection.Endpoint(
        line: line, columnUTF16: min(length, rowStart + columnInRow))
    }
    let attributed = attributedLine(forLine: line)
    let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
    let bounds = rowRange(rowInLine, starts: starts, length: attributed.length)
    let rowText = attributed.attributedSubstring(
      from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
    let columnInRow = columnUTF16(forX: textRelativeX, in: rowText)
    return TextSelection.Endpoint(line: line, columnUTF16: bounds.start + columnInRow)
  }

  /// A click target, snapped off concealed structural delimiter rows (fence
  /// markers, frontmatter `---`, table delimiters, setext underlines) to the
  /// nearest editable line — so a click in the empty slim band of, say, a code
  /// block's closing fence lands at the end of the last code line rather than
  /// on the phantom delimiter row. The raw `endpoint(at:)` is left untouched so
  /// a drag head can still cross those rows and select their source.
  func caretEndpoint(at point: NSPoint) -> TextSelection.Endpoint {
    let raw = endpoint(at: point)
    guard isConcealedDelimiterLine(raw.line) else { return raw }
    // Which side to snap to is chosen by which half of the slim row the click
    // is in (the row sits below any leading block air): the upper half belongs
    // to the content above, the lower half to the content below.
    let rowTop = yOffset(ofLine: raw.line) + leadingInset(forLine: raw.line)
    let preferDown = point.y >= rowTop + rowHeight(forLine: raw.line) / 2
    if preferDown, let next = nearestEditableLine(from: raw.line + 1, forward: true) {
      return TextSelection.Endpoint(line: next, columnUTF16: 0)
    }
    if let previous = nearestEditableLine(from: raw.line - 1, forward: false) {
      return TextSelection.Endpoint(line: previous, columnUTF16: lineLengthUTF16(previous))
    }
    if let next = nearestEditableLine(from: raw.line + 1, forward: true) {
      return TextSelection.Endpoint(line: next, columnUTF16: 0)
    }
    return raw  // The whole document is concealed; leave the caret where it landed.
  }

  /// A line that renders empty as a concealed structural delimiter and so
  /// should not be a caret target — fence open/close (except a *labeled* opener,
  /// whose language word is real editable text), frontmatter `---`, table
  /// delimiter rows, and setext underlines. A genuinely blank source line is
  /// `.plain` and is NOT concealed, so it stays clickable.
  func isConcealedDelimiterLine(_ line: Int) -> Bool {
    guard usesMarkdownDocumentLayout, syntax == .markdown, let buffer = reader,
      let states = markdownLineStates(for: buffer),
      line >= 0, line < states.count
    else {
      return false
    }
    let state = states[line]
    if state.isFenceDelimiter {
      return !(state.isFenceOpen && state.isFenceLabel)
    }
    return state.isFrontMatterDelimiter || state.isTableSeparator || state.isSetextUnderline
  }

  /// Moves a navigation/edit result off a concealed delimiter line, continuing
  /// in the move's direction (forward → next editable line START, backward →
  /// previous editable line END), so left/right/word/Home-End/undo never park
  /// the caret on a phantom row. Falls back to the other side when the move
  /// direction is exhausted (e.g. a closing fence at the document edge), and
  /// returns the endpoint unchanged when it is already editable.
  private func steppedOffConcealedLine(_ endpoint: TextSelection.Endpoint, forward: Bool)
    -> TextSelection.Endpoint
  {
    guard isConcealedDelimiterLine(endpoint.line) else { return endpoint }
    let forwardStart = { () -> TextSelection.Endpoint? in
      self.nearestEditableLine(from: endpoint.line + 1, forward: true)
        .map { TextSelection.Endpoint(line: $0, columnUTF16: 0) }
    }
    let backwardEnd = { () -> TextSelection.Endpoint? in
      self.nearestEditableLine(from: endpoint.line - 1, forward: false)
        .map { TextSelection.Endpoint(line: $0, columnUTF16: self.lineLengthUTF16($0)) }
    }
    if forward {
      return forwardStart() ?? backwardEnd() ?? endpoint
    }
    return backwardEnd() ?? forwardStart() ?? endpoint
  }

  /// The first non-concealed line at or beyond `start`, scanning `forward` or
  /// backward; nil when only concealed lines remain in that direction.
  private func nearestEditableLine(from start: Int, forward: Bool) -> Int? {
    var line = start
    while line >= 0, line < lineCount {
      if !isConcealedDelimiterLine(line) { return line }
      line += forward ? 1 : -1
    }
    return nil
  }

  // MARK: Selection commands

  override func selectAll(_ sender: Any?) {
    guard let buffer = reader, buffer.lineCount > 0 else { return }
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

  /// Copies the selection (bounded like `copy`) and deletes it. The copy happens
  /// only after the delete succeeds, so a failed cut never leaves the clipboard
  /// holding text that is still in the document. A no-op without a selection or
  /// when read-only.
  @objc func cut(_ sender: Any?) {
    guard isEditable, let text = selectedText(), !text.isEmpty,
      let range = currentSelectionUTF16Range(), range.end > range.start
    else {
      return
    }
    if replace(globalStart: range.start, globalEnd: range.end, with: "") {
      ClipboardService().copyPlainText(text)
    }
  }

  /// Replaces the selection (or inserts at the caret) with the pasteboard's plain
  /// text. A no-op when read-only or the pasteboard has no string; an over-budget
  /// clipboard is refused with a beep so a giant paste cannot freeze the main
  /// thread.
  @objc func paste(_ sender: Any?) {
    guard isEditable, let string = NSPasteboard.general.string(forType: .string),
      !string.isEmpty
    else {
      return
    }
    if string.utf8.count > maximumPastedByteCount {
      NSSound.beep()
      return
    }
    insertText(string)
  }

  // Edit-menu (`undo:` / `redo:`) dispatch. Cmd+Z is intercepted in
  // `performKeyEquivalent`, but the menu sends these action selectors to the
  // first responder, so route them to the same buffer undo stack.
  @objc func undo(_ sender: Any?) { undoEdit() }
  @objc func redo(_ sender: Any?) { redoEdit() }

  // Editing shortcuts are intercepted here (rather than relying on the Edit
  // menu's validation) so they work whenever the viewer is focused. Cmd+Z routes
  // to the buffer's own undo stack, which is the single source of truth (and
  // coalesces typing), so the system undo manager is intentionally not used.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    // Only act while focused; otherwise let the focused responder (e.g. the
    // editable editor) handle the shortcut.
    guard window?.firstResponder === self else {
      return super.performKeyEquivalent(with: event)
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    // Command, optionally with Shift; ignore Control/Option chords.
    guard modifiers.contains(.command), modifiers.subtracting([.command, .shift]).isEmpty,
      let key = event.charactersIgnoringModifiers?.lowercased()
    else {
      return super.performKeyEquivalent(with: event)
    }
    let shift = modifiers.contains(.shift)
    switch (key, shift) {
    case ("a", false):
      selectAll(nil)
    case ("c", false):
      copy(nil)
    case ("x", false) where isEditable:
      cut(nil)
    case ("v", false) where isEditable:
      paste(nil)
    case ("z", false) where isEditable:
      undoEdit()
    case ("z", true) where isEditable:
      redoEdit()
    case ("b", false) where isEditable && syntax == .markdown:
      toggleMarkdownEmphasis(marker: "**")
    case ("i", false) where isEditable && syntax == .markdown:
      toggleMarkdownEmphasis(marker: "*")
    case ("s", false) where isEditable:
      requestSave()
    default:
      return super.performKeyEquivalent(with: event)
    }
    return true
  }

  /// Enables/disables the editing menu items this view handles. Undo/redo are
  /// enabled whenever editable (the buffer owns the actual undo stack and no-ops
  /// when empty); copy/cut need a selection; paste needs editing.
  func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    switch item.action {
    case #selector(copy(_:)):
      return hasNonEmptySelection
    case #selector(cut(_:)):
      return isEditable && hasNonEmptySelection
    case #selector(paste(_:)), #selector(undo(_:)), #selector(redo(_:)):
      return isEditable
    case #selector(selectAll(_:)):
      return reader != nil
    default:
      return true
    }
  }

  private var hasNonEmptySelection: Bool {
    if let selection { return !selection.isEmpty }
    return false
  }

  /// The selected text for copying. Returns `nil` for an empty/absent selection,
  /// or when the selection is larger than `maximumCopiedByteCount` (in which case
  /// it beeps rather than materializing a giant string on the main thread).
  ///
  /// Reads the selection's actual UTF-16 range from the buffer, so a selection
  /// inside a huge line copies in full rather than being clipped to the display
  /// limit. Line terminators are normalized to LF — the view is line-based and
  /// does not retain original terminators, so a CRLF file copies with LF.
  func selectedText() -> String? {
    guard let buffer = reader, let selection, !selection.isEmpty else {
      return nil
    }
    if let span = selectionByteSpan(), span > maximumCopiedByteCount {
      NSSound.beep()
      return nil
    }
    guard let range = currentSelectionUTF16Range(), range.end > range.start else {
      return nil
    }
    return buffer.text(fromUTF16: range.start, toUTF16: range.end)
      .replacingOccurrences(of: "\r\n", with: "\n")
  }

  /// The unclipped buffer text spanning `[(fromLine, fromColumn), (toLine, toColumn))`,
  /// joined with LF. Unlike `displayText`, lines are not clipped to the display
  /// limit, so accessibility reads the real document in full-document coordinates.
  /// Callers bound the spanned length first.
  private func bufferText(fromLine: Int, fromColumn: Int, toLine: Int, toColumn: Int) -> String {
    guard let buffer = reader else { return "" }
    let count = toLine - fromLine + 1
    let lines = buffer.text(forLineRange: fromLine, count: count).components(separatedBy: "\n")
    return Self.sliceLines(lines, fromColumn: fromColumn, toColumn: toColumn)
  }

  /// Joins `lines` with LF after trimming the first line to start at `fromColumn`
  /// and the last to end at `toColumn` (clamped). For a single line, returns the
  /// `[fromColumn, toColumn)` slice.
  private static func sliceLines(_ lines: [String], fromColumn: Int, toColumn: Int) -> String {
    guard !lines.isEmpty else { return "" }
    if lines.count == 1 {
      let line = lines[0] as NSString
      let from = min(fromColumn, line.length)
      let to = min(toColumn, line.length)
      guard to > from else { return "" }
      return line.substring(with: NSRange(location: from, length: to - from))
    }
    var result = lines
    let first = result[0] as NSString
    result[0] = first.substring(from: min(fromColumn, first.length))
    let last = result[result.count - 1] as NSString
    result[result.count - 1] = last.substring(to: min(toColumn, last.length))
    return result.joined(separator: "\n")
  }

  /// Byte length of the current selection, computed cheaply from its endpoints'
  /// positions, or `nil` when there is no selection or a position lookup fails.
  /// Used to bound how much text copy and accessibility will materialize.
  private func selectionByteSpan() -> Int? {
    guard let buffer = reader, let selection, !selection.isEmpty,
      let range = currentSelectionUTF16Range(),
      let startByte = (try? buffer.position(forUTF16: range.start))?.byte,
      let endByte = (try? buffer.position(forUTF16: range.end))?.byte
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
    guard reader != nil else {
      super.keyDown(with: event)
      return
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if !isEditable,
      let characters = event.charactersIgnoringModifiers,
      characters == " ",
      modifiers.subtracting([.shift]).isEmpty
    {
      scrollPage(down: !modifiers.contains(.shift))
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
    case #selector(NSStandardKeyBindingResponding.scrollPageDown(_:)):
      scrollPage(down: true)
    case #selector(NSStandardKeyBindingResponding.scrollPageUp(_:)):
      scrollPage(down: false)
    case #selector(NSStandardKeyBindingResponding.insertNewline(_:)),
      #selector(NSStandardKeyBindingResponding.insertLineBreak(_:)),
      #selector(NSStandardKeyBindingResponding.insertParagraphSeparator(_:)):
      insertMarkdownAwareNewline()
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
    showCaretSolid()
    scrollCaretToVisible(newHead)
    invalidateVisibleArea()
  }

  func moveHorizontally(forward: Bool, extend: Bool) {
    if !extend, let current = selection, !current.isEmpty {
      applyMovedHead(
        steppedOffConcealedLine(forward ? current.end : current.start, forward: forward),
        extend: false)
      return
    }
    applyMovedHead(
      steppedOffConcealedLine(
        steppedCharacterEndpoint(from: navigationHead, forward: forward), forward: forward),
      extend: extend)
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
    applyMovedHead(
      steppedOffConcealedLine(
        steppedWordEndpoint(from: origin, forward: forward), forward: forward),
      extend: extend)
  }

  func moveToLineEdge(end: Bool, extend: Bool) {
    let head = navigationHead
    applyMovedHead(
      steppedOffConcealedLine(
        TextSelection.Endpoint(line: head.line, columnUTF16: end ? lineLengthUTF16(head.line) : 0),
        forward: end),
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
    // Move by one *visual* row, so wrapped lines navigate row-by-row.
    let currentRow = visualRow(of: head)
    var targetRow = down ? min(currentRow + 1, max(0, totalVisualRows - 1)) : max(currentRow - 1, 0)
    // Skip concealed delimiter rows so the caret never parks on a phantom line
    // (e.g. a code block's empty closing fence); they are single slim rows, so
    // stepping the visual row advances past the whole run.
    while targetRow != currentRow,
      isConcealedDelimiterLine(lineLocation(ofVisualRow: targetRow).line)
    {
      let next = down ? targetRow + 1 : targetRow - 1
      guard next >= 0, next < totalVisualRows else { break }
      targetRow = next
    }
    let newHead: TextSelection.Endpoint
    if targetRow == currentRow
      || isConcealedDelimiterLine(lineLocation(ofVisualRow: targetRow).line)
    {
      // At a document edge, or only concealed rows remain in this direction: go
      // to the current line's start/end rather than onto a concealed row.
      newHead = TextSelection.Endpoint(
        line: head.line, columnUTF16: down ? lineLengthUTF16(head.line) : 0)
    } else {
      newHead = endpoint(forVisualRow: targetRow, goalX: goalX)
    }
    applyMovedHead(newHead, extend: extend, keepGoalX: true)
    verticalGoalX = goalX
  }

  /// The caret endpoint at the horizontal goal `goalX` on visual row `row`.
  private func endpoint(forVisualRow row: Int, goalX: CGFloat) -> TextSelection.Endpoint {
    let (line, rowInLine) = lineLocation(ofVisualRow: row)
    if let length = hugeLength(line) {
      let rowStart = rowInLine * hugeLineColumns
      let rowText = hugeRowText(line: line, rowIndex: rowInLine, utf16Length: length)
      return TextSelection.Endpoint(
        line: line, columnUTF16: min(length, rowStart + columnUTF16(forX: goalX, in: rowText)))
    }
    let attributed = attributedLine(forLine: line)
    let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
    let bounds = rowRange(rowInLine, starts: starts, length: attributed.length)
    let rowText = attributed.attributedSubstring(
      from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
    return TextSelection.Endpoint(
      line: line, columnUTF16: bounds.start + columnUTF16(forX: goalX, in: rowText))
  }

  /// One composed-character step left/right, wrapping across line boundaries.
  private func steppedCharacterEndpoint(from endpoint: TextSelection.Endpoint, forward: Bool)
    -> TextSelection.Endpoint
  {
    // A huge line is not laid out in full, so its clipped displayed string cannot
    // index the caret's column; step the grapheme using a small window read.
    if let length = hugeLength(endpoint.line) {
      return steppedHugeCharacterEndpoint(
        line: endpoint.line, column: endpoint.columnUTF16, length: length, forward: forward)
    }
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

  /// One composed-character step within a huge line, resolving the grapheme
  /// boundary from a small UTF-16 window around the caret (the line is never laid
  /// out in full). Crossing the line's start/end wraps to the adjacent line.
  private func steppedHugeCharacterEndpoint(
    line: Int, column: Int, length: Int, forward: Bool
  ) -> TextSelection.Endpoint {
    // Wide enough for any ordinary grapheme cluster (surrogate pair, emoji,
    // combining marks); a pathologically long cluster at a huge-line boundary is
    // not worth a larger read.
    let window = 16
    guard let buffer = reader, let info = hugeLineInfo[line] else {
      return .init(line: line, columnUTF16: column)
    }
    if forward {
      if column < length {
        let end = min(length, column + window)
        let text =
          buffer.text(fromUTF16: info.start + column, toUTF16: info.start + end) as NSString
        let step = text.length > 0 ? NSMaxRange(text.rangeOfComposedCharacterSequence(at: 0)) : 1
        return .init(line: line, columnUTF16: min(length, column + step))
      }
      return line < lineCount - 1
        ? .init(line: line + 1, columnUTF16: 0)
        : .init(
          line: line, columnUTF16: column)
    }
    if column > 0 {
      let start = max(0, column - window)
      let text =
        buffer.text(fromUTF16: info.start + start, toUTF16: info.start + column) as NSString
      let location =
        text.length > 0 ? text.rangeOfComposedCharacterSequence(at: text.length - 1).location : 0
      return .init(line: line, columnUTF16: start + location)
    }
    return line > 0
      ? .init(line: line - 1, columnUTF16: lineLengthUTF16(line - 1))
      : .init(line: line, columnUTF16: 0)
  }

  /// One word step using the OS text tokenizer's word boundaries, so it is
  /// locale-aware (CJK and other scripts split into words rather than skipping a
  /// whole run). Forward lands on the end of the next word, backward on the start
  /// of the previous word; both wrap across line boundaries at the ends. Word
  /// ranges fall on grapheme boundaries, so the caret never splits a composed
  /// sequence (surrogate pair, emoji, combining mark).
  private func steppedWordEndpoint(from endpoint: TextSelection.Endpoint, forward: Bool)
    -> TextSelection.Endpoint
  {
    let line = attributedLine(forLine: endpoint.line).string as NSString
    let words = Self.wordTokenRanges(in: line)
    let index = endpoint.columnUTF16

    if forward {
      if let end = words.first(where: { $0.end > index })?.end {
        return .init(line: endpoint.line, columnUTF16: end)
      }
      // No word ahead on this line: move to the line end, or to the next line when
      // already there.
      if index < line.length {
        return .init(line: endpoint.line, columnUTF16: line.length)
      }
      return endpoint.line < lineCount - 1
        ? .init(line: endpoint.line + 1, columnUTF16: 0) : endpoint
    }

    if let start = words.last(where: { $0.start < index })?.start {
      return .init(line: endpoint.line, columnUTF16: start)
    }
    // No word before this point on the line: move to the line start, or to the
    // previous line when already there.
    if index > 0 {
      return .init(line: endpoint.line, columnUTF16: 0)
    }
    return endpoint.line > 0
      ? .init(line: endpoint.line - 1, columnUTF16: lineLengthUTF16(endpoint.line - 1)) : endpoint
  }

  /// Word token ranges (UTF-16) in `string`, locale-aware via the OS tokenizer, so
  /// CJK and other scripts segment into words. Whitespace and punctuation between
  /// words are not tokens. Shared by word navigation.
  static func wordTokenRanges(in string: NSString) -> [(start: Int, end: Int)] {
    guard string.length > 0 else { return [] }
    let tokenizer = CFStringTokenizerCreate(
      kCFAllocatorDefault, string as CFString,
      CFRange(location: 0, length: string.length),
      kCFStringTokenizerUnitWord, CFLocaleCopyCurrent())
    var ranges: [(start: Int, end: Int)] = []
    while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
      let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
      ranges.append((range.location, range.location + range.length))
    }
    return ranges
  }

  // MARK: Editing

  // Basic insert/delete routed to the Rust buffer. Endpoints (line, UTF-16
  // column) are mapped to global UTF-16 offsets via the buffer's position
  // lookups, so a multi-gigabyte file never has its text assembled to edit it.
  // Composition (IME), undo/redo, and cut/paste are later slices; these methods
  // are the shared primitives those will build on.

  /// Inserts `string`, replacing the current selection if any, and leaves the
  /// caret after the inserted text. A no-op when read-only, empty, or absent.
  func insertText(_ string: String) {
    guard isEditable, !string.isEmpty, let range = currentSelectionUTF16Range() else {
      return
    }
    replace(globalStart: range.start, globalEnd: range.end, with: string)
  }

  /// Replaces the global UTF-16 range `[start, end)` with `string`, leaving the
  /// caret after the inserted text. Returns whether the buffer was changed.
  ///
  /// A range replace goes through the buffer's atomic `replace` (one undo step,
  /// no partial state). A pure insert (empty range) uses `insert`, which
  /// coalesces consecutive typing into a single undo step.
  @discardableResult
  private func replace(globalStart start: Int, globalEnd end: Int, with string: String) -> Bool {
    guard let buffer = editableBuffer else { return false }
    do {
      if end > start {
        try buffer.replace(string, fromUTF16: start, toUTF16: end)
      } else if !string.isEmpty {
        try buffer.insert(string, atUTF16: start)
      } else {
        return false
      }
    } catch {
      NSSound.beep()
      return false
    }
    let newLengthUTF16 = (string as NSString).length
    finishEdit(
      caretUTF16: start + newLengthUTF16,
      change: TextChange(
        startUTF16: start,
        oldLengthUTF16: max(0, end - start),
        newLengthUTF16: newLengthUTF16
      )
    )
    return true
  }

  /// Deletes the selection, or one composed character before the caret (merging
  /// lines at a line start). A no-op at the document start.
  func deleteBackward() {
    guard isEditable, editableBuffer != nil else { return }
    if let selection, !selection.isEmpty {
      deleteRange(from: selection.start, to: selection.end)
      return
    }
    let caret = navigationHead
    if peelMarkdownBlockPrefixIfNeeded(at: caret) {
      return
    }
    let previous = steppedCharacterEndpoint(from: caret, forward: false)
    guard previous != caret else { return }
    deleteRange(from: previous, to: caret)
  }

  private static func isMarkdownBulletMarker(_ value: unichar) -> Bool {
    value == 45 || value == 42 || value == 43
  }

  /// Inserts a newline. In rendered Markdown, a list item continues with the same
  /// raw prefix so the next visual line still starts at column zero.
  private func insertMarkdownAwareNewline() {
    guard syntax == .markdown, isEditable, editableBuffer != nil, selection?.isEmpty != false,
      let prefix = markdownContinuationPrefix(at: navigationHead)
    else {
      insertText("\n")
      return
    }
    insertText("\n" + prefix)
  }

  /// Wraps or unwraps the current display-space selection with Markdown emphasis
  /// markers. The edit is made in raw buffer coordinates so the on-screen marker
  /// removal remains a pure rendering concern.
  func toggleMarkdownEmphasis(marker: String) {
    guard syntax == .markdown, isEditable, let buffer = editableBuffer,
      marker == "*" || marker == "**",
      let selection, !selection.isEmpty,
      let range = currentSelectionUTF16Range(), range.end > range.start
    else {
      return
    }

    let markerLength = (marker as NSString).length
    let selected = buffer.text(fromUTF16: range.start, toUTF16: range.end)
    let isAlreadyWrapped =
      range.start >= markerLength
      && range.end + markerLength <= buffer.utf16Length
      && buffer.text(fromUTF16: range.start - markerLength, toUTF16: range.start) == marker
      && buffer.text(fromUTF16: range.end, toUTF16: range.end + markerLength) == marker
      && !markdownMarkerTouchesSameMarker(
        marker: marker,
        beforeOpeningAt: range.start - markerLength,
        afterClosingAt: range.end + markerLength,
        in: buffer)

    let editStart: Int
    let editEnd: Int
    let replacement: String
    let selectedStartAfterEdit: Int
    let selectedEndAfterEdit: Int

    if isAlreadyWrapped {
      editStart = range.start - markerLength
      editEnd = range.end + markerLength
      replacement = selected
      selectedStartAfterEdit = editStart
      selectedEndAfterEdit = editStart + (selected as NSString).length
    } else {
      editStart = range.start
      editEnd = range.end
      replacement = marker + selected + marker
      selectedStartAfterEdit = range.start + markerLength
      selectedEndAfterEdit = selectedStartAfterEdit + (selected as NSString).length
    }

    do {
      try buffer.replace(replacement, fromUTF16: editStart, toUTF16: editEnd)
    } catch {
      NSSound.beep()
      return
    }

    finishEdit(
      caretUTF16: selectedEndAfterEdit,
      change: TextChange(
        startUTF16: editStart,
        oldLengthUTF16: max(0, editEnd - editStart),
        newLengthUTF16: (replacement as NSString).length
      )
    )
    setSelection(globalStart: selectedStartAfterEdit, globalEnd: selectedEndAfterEdit)
  }

  private func peelMarkdownBlockPrefixIfNeeded(at caret: TextSelection.Endpoint) -> Bool {
    guard syntax == .markdown, caret.columnUTF16 == 0, caret.line >= 0, caret.line < lineCount,
      let buffer = reader,
      let states = markdownLineStates(for: buffer),
      caret.line < states.count
    else {
      return false
    }
    let state = states[caret.line]
    guard !state.insideFence, !state.insideFrontMatter else { return false }
    let line = rawLineText(caret.line)
    guard let prefix = markdownPeelPrefix(in: line),
      let lineStart = globalUTF16Offset(line: caret.line, column: 0)
    else {
      return false
    }
    let replacementLength = (prefix.replacement as NSString).length
    if replace(
      globalStart: lineStart + prefix.location,
      globalEnd: lineStart + prefix.location + prefix.length,
      with: prefix.replacement
    ) {
      setSelection(
        globalStart: lineStart + prefix.location + replacementLength,
        globalEnd: lineStart + prefix.location + replacementLength)
      return true
    }
    return false
  }

  private func markdownContinuationPrefix(at caret: TextSelection.Endpoint) -> String? {
    guard caret.line >= 0, caret.line < lineCount,
      let buffer = reader,
      let states = markdownLineStates(for: buffer),
      caret.line < states.count,
      !states[caret.line].insideFence,
      !states[caret.line].insideFrontMatter
    else {
      return nil
    }
    let line = rawLineText(caret.line)
    guard caret.columnUTF16 >= lineLengthUTF16(caret.line),
      let prefix = markdownListContinuationPrefix(in: line)
    else {
      return nil
    }
    return prefix
  }

  private func markdownMarkerTouchesSameMarker(
    marker: String, beforeOpeningAt openingStart: Int, afterClosingAt closingEnd: Int,
    in buffer: TextBuffer
  ) -> Bool {
    guard marker == "*" else { return false }
    let previous =
      openingStart > 0
      ? buffer.text(fromUTF16: openingStart - 1, toUTF16: openingStart)
      : ""
    let next =
      closingEnd < buffer.utf16Length
      ? buffer.text(fromUTF16: closingEnd, toUTF16: closingEnd + 1)
      : ""
    return previous == marker || next == marker
  }

  private func markdownPeelPrefix(in line: String) -> (
    location: Int, length: Int, replacement: String
  )? {
    let nsLine = line as NSString
    let index = markdownLeadingSpaceLength(in: nsLine)
    var headingLevel = 0
    while index + headingLevel < nsLine.length, headingLevel < 6,
      nsLine.character(at: index + headingLevel) == 35
    {
      headingLevel += 1
    }
    if headingLevel > 0, index + headingLevel < nsLine.length,
      nsLine.character(at: index + headingLevel) == 32
    {
      return (index, headingLevel + 1, "")
    }
    if index < nsLine.length, nsLine.character(at: index) == 62 {
      var end = index + 1
      if end < nsLine.length, nsLine.character(at: end) == 32 {
        end += 1
      }
      return (index, end - index, "")
    }
    if let list = markdownListMarker(in: line) {
      if list.taskRange.length > 0 {
        return (list.taskRange.location, list.taskRange.length, "")
      }
      return (list.markerRange.location, list.markerRange.length, "")
    }
    return nil
  }

  private func markdownListContinuationPrefix(in line: String) -> String? {
    guard let list = markdownListMarker(in: line) else { return nil }
    let nsLine = line as NSString
    let marker = nsLine.substring(with: list.markerRange)
    if list.taskRange.length > 0 {
      return marker + "[ ] "
    }
    return marker
  }

  private func markdownListMarker(in line: String) -> (
    markerRange: NSRange, taskRange: NSRange
  )? {
    let nsLine = line as NSString
    let index = markdownLeadingSpaceLength(in: nsLine)
    guard index < nsLine.length else { return nil }
    if index + 1 < nsLine.length, Self.isMarkdownBulletMarker(nsLine.character(at: index)),
      nsLine.character(at: index + 1) == 32
    {
      let markerRange = NSRange(location: index, length: 2)
      let taskStart = index + 2
      if taskStart + 3 <= nsLine.length,
        nsLine.character(at: taskStart) == 91,
        nsLine.character(at: taskStart + 2) == 93
      {
        var taskEnd = taskStart + 3
        if taskEnd < nsLine.length, nsLine.character(at: taskEnd) == 32 {
          taskEnd += 1
        }
        return (markerRange, NSRange(location: taskStart, length: taskEnd - taskStart))
      }
      return (markerRange, NSRange(location: 0, length: 0))
    }

    var digitEnd = index
    while digitEnd < nsLine.length,
      CharacterSet.decimalDigits.contains(
        UnicodeScalar(nsLine.character(at: digitEnd)) ?? "\0")
    {
      digitEnd += 1
    }
    if digitEnd > index, digitEnd + 1 < nsLine.length {
      let delimiter = nsLine.character(at: digitEnd)
      if delimiter == 46 || delimiter == 41, nsLine.character(at: digitEnd + 1) == 32 {
        return (
          NSRange(location: index, length: digitEnd + 2 - index),
          NSRange(location: 0, length: 0)
        )
      }
    }
    return nil
  }

  private func markdownLeadingSpaceLength(in line: NSString) -> Int {
    var index = 0
    while index < line.length, line.character(at: index) == 32 {
      index += 1
    }
    return index
  }

  /// Deletes the selection, or one composed character after the caret (merging
  /// the next line at a line end). A no-op at the document end.
  func deleteForward() {
    guard isEditable, editableBuffer != nil else { return }
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
    guard isEditable, editableBuffer != nil else { return }
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
    guard isEditable, editableBuffer != nil else { return }
    if let selection, !selection.isEmpty {
      deleteRange(from: selection.start, to: selection.end)
      return
    }
    let caret = navigationHead
    let next = steppedWordEndpoint(from: caret, forward: true)
    guard next != caret else { return }
    deleteRange(from: caret, to: next)
  }

  /// Reverts the most recent buffer edit. Returns whether the request was handled
  /// (true while editable), regardless of whether anything was undone.
  @discardableResult
  func undoEdit() -> Bool {
    guard isEditable, let buffer = editableBuffer else { return false }
    composition = nil
    if let change = (try? buffer.undo()) ?? nil {
      afterUndoRedo(change: change)
    }
    return true
  }

  /// Re-applies the most recently undone edit. See `undoEdit` for the return value.
  @discardableResult
  func redoEdit() -> Bool {
    guard isEditable, let buffer = editableBuffer else { return false }
    composition = nil
    if let change = (try? buffer.redo()) ?? nil {
      afterUndoRedo(change: change)
    }
    return true
  }

  /// Refresh after undo/redo replaced buffer content beneath the current
  /// selection: drop caches, clamp the (possibly now out-of-range) selection,
  /// re-measure, and repaint. `change` is the span the step rewrote, so the
  /// wrap index can be updated for just those lines.
  private func afterUndoRedo(change: TextChange) {
    cachedBand = nil
    invalidateMarkdownLineStateCacheAfterContentChange()
    maxObservedLineWidth = 0
    verticalGoalX = nil
    updateWrapIndex(afterChange: change)
    clampSelectionToBounds()
    showCaretSolid()
    updateLayout()
    if let head = selection?.head {
      scrollCaretToVisible(head)
    }
    invalidateVisibleArea()
    notifyDirtyChanged()
  }

  /// Clamps the selection endpoints into the current document bounds, since
  /// undo/redo can shrink the content beneath a stale selection.
  private func clampSelectionToBounds() {
    guard let selection else { return }
    self.selection = TextSelection(
      anchor: clampedEndpoint(selection.anchor), head: clampedEndpoint(selection.head))
  }

  private func clampedEndpoint(_ endpoint: TextSelection.Endpoint) -> TextSelection.Endpoint {
    let line = min(max(0, endpoint.line), max(0, lineCount - 1))
    let column = min(max(0, endpoint.columnUTF16), lineLengthUTF16(line))
    return TextSelection.Endpoint(line: line, columnUTF16: column)
  }

  /// Deletes the UTF-16 range between two endpoints and collapses the caret to
  /// the start. Endpoints must already be ordered (`from` before `to`).
  private func deleteRange(from start: TextSelection.Endpoint, to end: TextSelection.Endpoint) {
    let selection = TextSelection(anchor: start, head: end)
    guard let buffer = editableBuffer, let range = rawUTF16Range(for: selection),
      range.end > range.start
    else {
      return
    }
    do {
      try buffer.delete(fromUTF16: range.start, toUTF16: range.end)
      finishEdit(
        caretUTF16: range.start,
        change: TextChange(
          startUTF16: range.start,
          oldLengthUTF16: range.end - range.start,
          newLengthUTF16: 0
        )
      )
    } catch {
      NSSound.beep()
    }
  }

  /// The current selection as a global UTF-16 range, or a zero-length range at
  /// the caret when nothing is selected. `nil` only if a position lookup fails.
  private func currentSelectionUTF16Range() -> (start: Int, end: Int)? {
    let selection = self.selection ?? TextSelection(caretAt: navigationHead)
    return rawUTF16Range(for: selection)
  }

  private func rawUTF16Range(for selection: TextSelection) -> (start: Int, end: Int)? {
    if selection.isEmpty {
      guard let offset = utf16Offset(of: selection.head) else { return nil }
      return (offset, offset)
    }
    if selection.start.line == selection.end.line {
      guard
        let lineStart = globalUTF16Offset(line: selection.start.line, column: 0),
        let range = rawColumnRange(
          line: selection.start.line,
          displayStart: selection.start.columnUTF16,
          displayEnd: selection.end.columnUTF16)
      else {
        return nil
      }
      return (lineStart + range.location, lineStart + NSMaxRange(range))
    }
    guard
      let startLineStart = globalUTF16Offset(line: selection.start.line, column: 0),
      let endLineStart = globalUTF16Offset(line: selection.end.line, column: 0),
      let startLineRange = rawColumnRange(
        line: selection.start.line,
        displayStart: selection.start.columnUTF16,
        displayEnd: lineLengthUTF16(selection.start.line)),
      let endLineRange = rawColumnRange(
        line: selection.end.line,
        displayStart: 0,
        displayEnd: selection.end.columnUTF16)
    else {
      return nil
    }
    let start = startLineStart + startLineRange.location
    let end = endLineStart + NSMaxRange(endLineRange)
    return (min(start, end), max(start, end))
  }

  private func rawSelectionOffsets(for selection: TextSelection) -> RawSelectionOffsets? {
    guard let anchor = utf16Offset(of: selection.anchor),
      let head = utf16Offset(of: selection.head)
    else {
      return nil
    }
    return RawSelectionOffsets(anchor: anchor, head: head)
  }

  private func restoreSelection(from offsets: RawSelectionOffsets) {
    guard let buffer = reader,
      let anchor = try? buffer.position(forUTF16: offsets.anchor),
      let head = try? buffer.position(forUTF16: offsets.head)
    else {
      clampSelectionToBounds()
      return
    }
    selection = TextSelection(
      anchor: displayEndpoint(for: anchor), head: displayEndpoint(for: head))
  }

  private func setSelection(globalStart: Int, globalEnd: Int) {
    guard let buffer = reader,
      let start = try? buffer.position(forUTF16: globalStart),
      let end = try? buffer.position(forUTF16: globalEnd)
    else {
      return
    }
    selection = TextSelection(
      anchor: displayEndpoint(for: start),
      head: displayEndpoint(for: end)
    )
    if let head = selection?.head {
      scrollCaretToVisible(head)
    }
    invalidateVisibleArea()
  }

  /// The global UTF-16 offset of a (line, column) endpoint, or `nil` if the
  /// buffer is absent or the lookup fails.
  private func utf16Offset(of endpoint: TextSelection.Endpoint) -> Int? {
    rawUTF16Offset(
      line: endpoint.line,
      displayColumn: endpoint.columnUTF16)
  }

  private func rawUTF16Offset(line: Int, displayColumn: Int) -> Int? {
    let rawColumn =
      markdownDisplayMap(forLine: line)?.bufferColumn(forDisplayColumn: displayColumn)
      ?? displayColumn
    return globalUTF16Offset(line: line, column: rawColumn)
  }

  private func rawColumnRange(line: Int, displayStart: Int, displayEnd: Int) -> NSRange? {
    if let map = markdownDisplayMap(forLine: line) {
      let includeWholeLineMarkers = displayStart <= 0 && displayEnd >= map.displayLength
      return map.bufferRange(
        forDisplayStart: displayStart,
        end: displayEnd,
        includeWholeLineMarkers: includeWholeLineMarkers)
    }
    let lineLength = lineLengthUTF16(line)
    let start = min(max(0, displayStart), lineLength)
    let end = min(max(start, displayEnd), lineLength)
    return NSRange(location: start, length: end - start)
  }

  private func globalUTF16Offset(line: Int, column: Int) -> Int? {
    guard let buffer = reader else { return nil }
    return (try? buffer.position(forLine: line, columnUTF16: column))?.utf16
  }

  private func displayEndpoint(for position: TextPosition) -> TextSelection.Endpoint {
    if let map = markdownDisplayMap(forLine: position.line) {
      return TextSelection.Endpoint(
        line: position.line,
        columnUTF16: map.displayColumn(forBufferColumn: position.columnUTF16))
    }
    return TextSelection.Endpoint(line: position.line, columnUTF16: position.columnUTF16)
  }

  /// Shared post-edit refresh: places the caret at `offset`, drops cached band
  /// and geometry (the buffer revision changed), re-measures the document, and
  /// repaints the visible band. `change` is the span the edit rewrote; the wrap
  /// index is spliced for just those lines.
  private func finishEdit(caretUTF16 offset: Int, change: TextChange) {
    cachedBand = nil
    invalidateMarkdownLineStateCacheAfterContentChange()
    verticalGoalX = nil
    // The widest-line high-water mark can only shrink via an edit (deleting or
    // splitting a long line), so reset it and let `draw` re-measure the visible
    // band rather than keeping a stale, too-wide horizontal extent.
    maxObservedLineWidth = 0
    if let buffer = reader, let position = try? buffer.position(forUTF16: offset) {
      selection = TextSelection(
        caretAt: steppedOffConcealedLine(displayEndpoint(for: position), forward: true))
    }
    updateWrapIndex(afterChange: change)
    showCaretSolid()
    updateLayout()
    if let head = selection?.head {
      scrollCaretToVisible(head)
    }
    invalidateVisibleArea()
    notifyDirtyChanged()
  }

  /// Reports the buffer's current dirty state to the host (after an edit/undo).
  private func notifyDirtyChanged() {
    onDirtyChange?(editableBuffer?.isDirty ?? false)
  }

  // MARK: Save

  /// Saves the buffer to `saveURL` on a background thread so the write never blocks
  /// the UI. Captures an immutable snapshot synchronously (before any await), then
  /// streams that off-main; the live buffer stays editable during the write because
  /// the snapshot is independent of it. A per-buffer in-flight guard keeps two
  /// writes of the same buffer from overlapping.
  func requestSave() {
    guard isEditable, let buffer = editableBuffer, buffer.isDirty, let saveURL,
      saveTracker.begin(buffer)
    else {
      return
    }
    // Capture an immutable snapshot of the current content on the main actor
    // (`O(1)`); the background write reads only this, so the live buffer stays
    // editable during the save. If the core somehow refuses, release the in-flight
    // mark so a later edit can retry.
    guard let snapshot = buffer.takeSaveSnapshot() else {
      saveTracker.finish(buffer)
      return
    }
    invalidateVisibleArea()

    // Capture everything the completion needs at save start. The view may be
    // reused for another buffer/entry before the write finishes (reload, file
    // switch), so completion must act on the buffer that was actually saved and
    // route to the entry that requested it — never the current one.
    let savedBuffer = buffer
    let store = bufferStore
    let completion = onSaveCompletion
    let encoding = saveEncoding
    // Capture the (shared) tracker so completion can clear the in-flight mark even
    // if this view is gone — never reach back through `self` for it.
    let tracker = saveTracker
    Task { [weak self] in
      let result: Result<DocumentFileFingerprint?, Error>
      do {
        let fingerprint = try await Task.detached {
          try store.save(snapshot, to: saveURL, encoding: encoding)
          // Read the new fingerprint here, still off-main, so the host can record
          // the post-save state before the change monitor's debounced event.
          return DocumentFileFingerprint.read(at: saveURL)
        }.value
        result = .success(fingerprint)
      } catch {
        result = .failure(error)
      }
      // View-independent: the disk write finished, so always record the saved
      // state and notify the host — even if SwiftUI tore down this representable
      // mid-write. Otherwise markSaved, the fingerprint update, the dirty mirror,
      // and save-error reporting would be silently dropped (leaving the cached
      // buffer stuck dirty or provoking a false external-change conflict later).
      Self.completeSave(
        result, savedBuffer: savedBuffer, snapshot: snapshot, saveTracker: tracker,
        completion: completion)
      // Live-view cleanup: repaint and re-report dirty state. The in-flight mark was
      // already cleared in `completeSave`; this is skipped harmlessly if the view is
      // already gone.
      self?.finishSaveOnView(savedBuffer: savedBuffer)
    }
  }

  /// View-independent save completion. Runs after the background write whether or
  /// not the text view still exists, so a finished write always updates the saved
  /// buffer, clears the buffer's in-flight-save mark, and reports to the save's own
  /// completion. Clearing the mark here (rather than in the view-local continuation)
  /// is what guarantees a torn-down view never leaves the shared tracker stuck
  /// "saving". Marking "saved" records exactly the written snapshot's content, so a
  /// buffer edited during the write stays dirty until its newer content is saved.
  @MainActor
  static func completeSave(
    _ result: Result<DocumentFileFingerprint?, Error>,
    savedBuffer: TextBuffer,
    snapshot: TextBufferSnapshot,
    saveTracker: DocumentSaveTracker,
    completion: ((Result<DocumentFileFingerprint?, Error>) -> Void)?
  ) {
    switch result {
    case .success:
      // Mark exactly the written snapshot's content as saved — not the buffer's
      // current content — so a buffer edited during the write stays dirty (its
      // newer content is not yet on disk) and undoing back to the saved content
      // reads clean again.
      savedBuffer.markSaved(snapshot)
      if !savedBuffer.isDirty {
        savedBuffer.markSavedAndClearHistory()
      }
    case .failure:
      NSSound.beep()
    }
    // Always clear the in-flight mark so a later save can start, even if the
    // originating view is gone; the shared tracker would otherwise block this
    // buffer's saves forever.
    saveTracker.finish(savedBuffer)
    completion?(result)
  }

  /// Live-view continuation after the write: repaints and re-reports dirty state if
  /// the saved buffer is still the one shown. The saved-state, in-flight-mark clear,
  /// and host-notification side effects already ran in `completeSave`, so this is
  /// safe to skip entirely when the view is gone.
  private func finishSaveOnView(savedBuffer: TextBuffer) {
    if savedBuffer === editableBuffer {
      notifyDirtyChanged()
      invalidateVisibleArea()
    }
  }

  /// Test seam: marks the current buffer as having a save in flight — the same
  /// state `requestSave` sets at the start of a write — so tests can drive
  /// save-in-flight behavior without the asynchronous, disk-touching writer.
  func beginSaveForTesting() {
    guard let buffer = editableBuffer else { return }
    saveTracker.begin(buffer)
  }

  /// Text-relative x of the caret at `endpoint`, measured within its visual row.
  private func caretX(for endpoint: TextSelection.Endpoint) -> CGFloat {
    let attributed = attributedLine(forLine: endpoint.line)
    return caretGeometry(
      forColumn: endpoint.columnUTF16, line: endpoint.line, attributed: attributed
    )
    .x
  }

  private struct CaretGeometry {
    let x: CGFloat
    let visualRow: Int
  }

  /// Text-relative x and global visual row for a caret column in `line`.
  private func caretGeometry(
    forColumn column: Int, line: Int, attributed: NSAttributedString
  ) -> CaretGeometry {
    if let length = hugeLength(line) {
      let columns = hugeLineColumns
      let rowIndex = min(hugeRowCount(utf16Length: length) - 1, max(0, column) / columns)
      let rowStart = rowIndex * columns
      let rowText = hugeRowText(line: line, rowIndex: rowIndex, utf16Length: length)
      return CaretGeometry(
        x: xOffset(forColumn: min(max(0, column - rowStart), rowText.length), in: rowText),
        visualRow: firstVisualRow(ofLine: line) + rowIndex
      )
    }
    let boundedColumn = max(0, min(column, attributed.length))
    let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
    let rowIndex = visualRowIndex(forColumn: boundedColumn, starts: starts)
    let bounds = rowRange(rowIndex, starts: starts, length: attributed.length)
    let rowText = attributed.attributedSubstring(
      from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
    return CaretGeometry(
      x: xOffset(forColumn: min(boundedColumn, bounds.end) - bounds.start, in: rowText),
      visualRow: firstVisualRow(ofLine: line) + rowIndex
    )
  }

  private func scrollCaretToVisible(_ endpoint: TextSelection.Endpoint) {
    let x = lineTextColumnX(forLine: endpoint.line) + caretX(for: endpoint)
    let rect = NSRect(
      x: x - caretScrollMargin,
      y: yOffset(ofVisualRow: visualRow(of: endpoint)),
      width: caretScrollMargin * 2,
      height: rowHeight(forLine: endpoint.line))
    scrollToVisible(rect)
  }

  private func scrollPage(down: Bool) {
    guard let scrollView = enclosingScrollView else { return }
    let visible = scrollView.contentView.bounds
    let delta = max(layout.lineHeight, visible.height - layout.lineHeight)
    scrollViewport(toY: visible.origin.y + (down ? delta : -delta))
  }

  private func scrollViewport(toY requestedY: CGFloat) {
    guard let scrollView = enclosingScrollView else { return }
    let visible = scrollView.contentView.bounds
    let insets = scrollView.contentInsets
    let minY = -insets.top
    let maxY = max(minY, frame.height - visible.height)
    let y = min(max(requestedY, minY), maxY)
    scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: y))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    viewportDidScroll()
  }

  /// Resizes the document to fit the line count (height) and the widest line seen
  /// so far (width), but never narrower than the visible content area. The width
  /// follows the widest drawn line, which is bounded by
  /// `maximumDrawnCharactersPerLine`; the scroll view only backs the visible
  /// region, so a tall/wide document does not allocate a full-size layer.
  func updateLayout() {
    // Resize changes the wrap width; rebuild the index when it actually changed.
    // The content has not changed, so reuse the cached long-line decision rather
    // than re-scanning the document just to resize. A background build already
    // measuring at the current width is left to finish — re-triggering it here
    // would restart the build once per layout pass and never converge.
    if lastWrapWidth != wrapContentWidth, wrapBuildTargetWidth != wrapContentWidth {
      rebuildWrapIndex(recomputeLongLine: false)
    }
    let visibleSize = enclosingScrollView?.documentVisibleRect.size
    let visibleWidth = visibleSize?.width ?? frame.width
    let contentHeight = max(totalContentHeight, layout.lineHeight)
    let height: CGFloat
    if let viewportHeight = visibleSize?.height {
      // VS Code-style scroll past end: the document gets a tail of empty space
      // below the last row, so it can scroll until that row reaches the top.
      // Empty and single-row documents still fill only the viewport because the
      // first row is already at the top.
      let lastLine = max(0, lineCount - 1)
      let tailHeight = max(
        0,
        viewportHeight
          - CGFloat(TextViewportLayout.overscrollAnchorRowCount) * rowHeight(forLine: lastLine))
      height = max(viewportHeight, contentHeight + tailHeight)
    } else {
      // Detached views do not have a stable viewport height. Feeding frame.height
      // back into the scroll-past-end formula would grow the frame on every pass.
      height = max(contentHeight, frame.height)
    }
    if wrapIndex != nil {
      // Wrapped: fill the viewport width; no horizontal scrolling.
      setFrameSize(NSSize(width: visibleWidth, height: height))
    } else {
      let contentWidth =
        textColumnX + maxObservedLineWidth + trailingContentMargin
      setFrameSize(NSSize(width: max(visibleWidth, contentWidth), height: height))
    }
    // Align the horizontal scroller's track with the text area: the gutter is
    // pinned viewport chrome drawn by this view, so the scroller track starts at
    // the gutter's right edge. The vertical scroller is governed by the other
    // insets and stays untouched. Write only on change so repeated layout passes
    // remain idempotent and do not re-tile the scrollers.
    if let scrollView = enclosingScrollView {
      let horizontalScrollerInset = gutterWidth
      if scrollView.scrollerInsets.left != horizontalScrollerInset {
        scrollView.scrollerInsets.left = horizontalScrollerInset
      }
    }
    // The visible band and gutter width may have changed; re-establish the
    // I-beam cursor rect so its boundary stays aligned with the gutter edge.
    window?.invalidateCursorRects(for: self)
  }

  private func attributedBandLines(for buffer: any TextDocumentReading, range: Range<Int>)
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
    let states = markdownLineStates(for: buffer)
    let highlighted = lines.enumerated().map { offset, line in
      let lineIndex = range.lowerBound + offset
      let state =
        lineIndex >= 0 && lineIndex < (states?.count ?? 0)
        ? states?[lineIndex] ?? .plain
        : .plain
      return highlightedLine(line, lineIndex: lineIndex, markdownLineState: state)
    }
    cachedBand = (revision, range, highlighted)
    return highlighted
  }

  private func markdownLineStates(for buffer: any TextDocumentReading) -> [MarkdownLineStyleState]?
  {
    guard usesMarkdownDocumentLayout, syntax == .markdown else { return nil }
    let revision = buffer.revision
    if let markdownLineStateCache, markdownLineStateCache.revision == revision {
      return markdownLineStateCache.states
    }
    guard buffer.lineCount <= markdownSynchronousLineStateLimit else {
      if wrapBuildTask == nil || wrapBuildTargetWidth != wrapContentWidth {
        scheduleMarkdownLineStateBuild(revision: revision)
      }
      return nil
    }
    let lines = buffer.text(
      forLineRange: 0,
      count: buffer.lineCount,
      maxBytesPerLine: maximumFetchedBytesPerLine
    )
    .components(separatedBy: "\n")
    var states = TextDocumentSyntaxHighlighter.markdownLineStates(
      for: Array(lines.prefix(buffer.lineCount)))
    while states.count < buffer.lineCount {
      states.append(.plain)
    }
    markdownLineStateCache = (revision, states)
    return states
  }

  private func scheduleMarkdownLineStateBuild(revision: UInt64) {
    guard markdownLineStateBuildTargetRevision != revision else { return }
    guard let source = editableBuffer?.takeReadSnapshot() else { return }
    markdownLineStateBuildGeneration &+= 1
    let generation = markdownLineStateBuildGeneration
    markdownLineStateBuildTargetRevision = revision
    let maxBytesPerLine = maximumFetchedBytesPerLine
    markdownLineStateBuildTask?.cancel()
    markdownLineStateBuildTask = Task.detached(priority: .utility) { [weak self] in
      let states = Self.buildMarkdownLineStates(source: source, maxBytesPerLine: maxBytesPerLine)
      await MainActor.run { [weak self] in
        self?.completeMarkdownLineStateBuild(
          generation: generation, revision: revision, states: states)
      }
    }
  }

  private nonisolated static func buildMarkdownLineStates(
    source: any WrapMeasurementReading,
    maxBytesPerLine: Int
  ) -> [MarkdownLineStyleState]? {
    if Task.isCancelled { return nil }
    let lineCount = source.lineCount
    let text = source.text(forLineRange: 0, count: lineCount, maxBytesPerLine: maxBytesPerLine)
    if Task.isCancelled { return nil }
    var states = TextDocumentSyntaxHighlighter.markdownLineStates(
      for: Array(text.components(separatedBy: "\n").prefix(lineCount)))
    while states.count < lineCount {
      states.append(.plain)
    }
    return states
  }

  private func completeMarkdownLineStateBuild(
    generation: Int,
    revision: UInt64,
    states: [MarkdownLineStyleState]?
  ) {
    guard generation == markdownLineStateBuildGeneration else { return }
    markdownLineStateBuildTask = nil
    markdownLineStateBuildTargetRevision = nil
    guard let states, reader?.revision == revision else { return }
    markdownLineStateCache = (revision, states)
    cachedBand = nil
    invalidateVisibleArea()
  }

  private func cancelMarkdownLineStateBuild() {
    markdownLineStateBuildGeneration &+= 1
    markdownLineStateBuildTargetRevision = nil
    markdownLineStateBuildTask?.cancel()
    markdownLineStateBuildTask = nil
  }

  private func invalidateMarkdownLineStateCacheAfterContentChange() {
    guard usesMarkdownDocumentLayout, let buffer = reader else {
      markdownLineStateCache = nil
      cancelMarkdownLineStateBuild()
      return
    }
    let revision = buffer.revision
    if buffer.lineCount <= markdownSynchronousLineStateLimit {
      markdownLineStateCache = nil
      cancelMarkdownLineStateBuild()
    } else {
      if markdownLineStateCache?.revision != revision {
        markdownLineStateCache = nil
      }
      scheduleMarkdownLineStateBuild(revision: revision)
    }
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
    guard let buffer = reader else { return [] }
    return
      buffer.text(forLineRange: start, count: count, maxBytesPerLine: maximumFetchedBytesPerLine)
      .components(separatedBy: "\n")
      .map(clippedDisplayLine)
  }

  private func rawLineText(_ line: Int) -> String {
    guard let buffer = reader else { return "" }
    return
      buffer.text(forLineRange: line, count: 1, maxBytesPerLine: maximumFetchedBytesPerLine)
      .components(separatedBy: "\n").first ?? ""
  }

  private func markdownDisplayMap(forLine line: Int) -> MarkdownDisplayMap? {
    guard usesMarkdownDocumentLayout, syntax == .markdown, let buffer = reader,
      line >= 0, line < buffer.lineCount
    else {
      return nil
    }
    let raw = rawLineText(line)
    let visible = clippedDisplayLine(raw)
    let states = markdownLineStates(for: buffer)
    let state =
      line >= 0 && line < (states?.count ?? 0)
      ? states?[line] ?? .plain
      : .plain
    return TextDocumentSyntaxHighlighter.markdownDisplayMap(for: visible, state: state)
  }

  private func highlightedLine(
    _ line: String,
    lineIndex: Int,
    markdownLineState: MarkdownLineStyleState = .plain
  )
    -> NSAttributedString
  {
    let visible = clippedDisplayLine(line)
    let length = (visible as NSString).length
    // A pathologically long non-prose line keeps base styling but skips rule
    // highlighting (Cursor-like) — it both reads as "this is the long blob" and
    // avoids regex over a huge line. Prose always highlights.
    let applyRules = highlightsLine(lengthUTF16: length)
    if usesMarkdownDocumentLayout, syntax == .markdown {
      return TextDocumentSyntaxHighlighter.highlightedLine(
        visible,
        syntax: syntax,
        font: font,
        applyRules: applyRules,
        markdownLineState: markdownLineState,
        markdownTypography: markdownTypography
      )
    }
    let attributed = NSMutableAttributedString(string: visible)
    let fullRange = NSRange(location: 0, length: length)
    let effectiveSyntax = displaySyntax
    TextDocumentSyntaxHighlighter.apply(
      to: attributed, text: visible, syntax: effectiveSyntax, font: font, range: fullRange,
      applyRules: effectiveSyntax == .markdown ? false : applyRules)
    return attributed
  }

  // MARK: Line geometry (selection / caret hit-testing)

  /// The displayed (highlighted, possibly truncated) attributed string for a
  /// line, reusing the cached band when the line falls within it.
  private func attributedLine(forLine line: Int) -> NSAttributedString {
    if let cachedBand, cachedBand.range.contains(line) {
      return cachedBand.lines[line - cachedBand.range.lowerBound]
    }
    guard let buffer = reader else { return NSAttributedString() }
    let text =
      buffer.text(forLineRange: line, count: 1, maxBytesPerLine: maximumFetchedBytesPerLine)
      .components(separatedBy: "\n").first ?? ""
    let states = markdownLineStates(for: buffer)
    let state =
      line >= 0 && line < (states?.count ?? 0)
      ? states?[line] ?? .plain
      : .plain
    return highlightedLine(text, lineIndex: line, markdownLineState: state)
  }

  private func lineLengthUTF16(_ line: Int) -> Int {
    // A huge line is never laid out in full, so its true length comes from the
    // grid bookkeeping, not the clipped displayed string.
    if let length = hugeLength(line) { return length }
    return attributedLine(forLine: line).length
  }

  /// UTF-16 column at horizontal offset `x` (relative to the text's left edge)
  /// within `attributed` (a line or a single wrapped visual row), clamped.
  private func columnUTF16(forX x: CGFloat, in attributed: NSAttributedString) -> Int {
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

  /// The half-open range of global visual rows intersecting `rect`.
  private func visibleVisualRowRange(in rect: CGRect) -> Range<Int> {
    let total = totalVisualRows
    guard total > 0, layout.lineHeight > 0, rect.height > 0 else { return 0..<0 }
    guard let wrapIndex, wrapIndex.hasCustomRowHeights else {
      let first = max(0, Int((rect.minY / layout.lineHeight).rounded(.down)))
      let last = min(total, Int((rect.maxY / layout.lineHeight).rounded(.up)))
      return first < last ? first..<last : 0..<0
    }
    let (firstLine, firstRowInLine) = rowLocation(forY: max(0, rect.minY))
    let first = max(0, wrapIndex.firstVisualRow(ofLine: firstLine) + firstRowInLine)
    let (lastLine, lastRowInLine) = rowLocation(forY: max(0, rect.maxY))
    let last = min(total, wrapIndex.firstVisualRow(ofLine: lastLine) + lastRowInLine + 1)
    return first < last ? first..<last : 0..<0
  }

  override func draw(_ dirtyRect: NSRect) {
    viewportBackgroundColor.setFill()
    dirtyRect.fill()

    guard let buffer = reader else {
      return
    }
    let rows = visibleVisualRowRange(in: dirtyRect)
    let gutter = gutterWidth
    guard !rows.isEmpty else {
      // In the scroll-past-end tail, the dirty band can sit entirely past the
      // content. Keep the viewport-pinned gutter chrome visible there; numbers
      // stop at the last line, matching the area below a short document.
      if gutter > 0 {
        drawGutter(width: gutter, lineRange: 0..<0, dirtyRect: dirtyRect)
      }
      return
    }
    // Visible visual rows map back to a logical-line band to fetch.
    let firstLine = lineLocation(ofVisualRow: rows.lowerBound).line
    let lastLine = lineLocation(ofVisualRow: rows.upperBound - 1).line
    let range = firstLine..<(lastLine + 1)

    let textX = textColumnX
    let lines = attributedBandLines(for: buffer, range: range)

    if usesMarkdownDocumentLayout {
      drawMarkdownBlockDecorations(
        lines: lines, range: range, textX: textX, visibleRows: rows, buffer: buffer)
    }

    if let selection, !selection.isEmpty {
      drawSelectionHighlight(selection, lines: lines, range: range, textX: textX, visibleRows: rows)
    }

    var widest = maxObservedLineWidth
    for (offset, attributedLine) in lines.enumerated() {
      let lineIndex = range.lowerBound + offset
      // A huge line is never laid out in full; draw only its visible rows from
      // windows fetched on demand. It always wraps, so it adds no scroll width.
      if let length = hugeLength(lineIndex) {
        drawHugeLineRows(
          line: lineIndex,
          utf16Length: length,
          textX: lineTextColumnX(forLine: lineIndex),
          visibleRows: rows)
        continue
      }
      let drawn = composedLineForDisplay(line: lineIndex, base: attributedLine)
      widest = max(widest, drawn.size().width)
      drawVisualRows(of: drawn, line: lineIndex, textX: lineTextColumnX(forLine: lineIndex))
    }
    // Copy controls draw above the code so a long line never occludes them.
    if usesMarkdownDocumentLayout {
      drawMarkdownCodeCopyControls(range: range, visibleRows: rows)
    }
    drawCaretIfNeeded(lines: lines, range: range, textX: textX)
    if gutter > 0 {
      drawGutter(width: gutter, lineRange: range, dirtyRect: dirtyRect)
    }
    // The widest-line tracking only drives horizontal scroll when not wrapping.
    if wrapIndex == nil, widest > maxObservedLineWidth {
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

  /// Draws only the visible visual rows of a huge line, each fetched as a UTF-16
  /// window — so an enormous line renders without ever being laid out in full.
  private func drawHugeLineRows(
    line: Int, utf16Length: Int, textX: CGFloat, visibleRows: Range<Int>
  ) {
    let firstRow = firstVisualRow(ofLine: line)
    let count = hugeRowCount(utf16Length: utf16Length)
    let lo = max(firstRow, visibleRows.lowerBound)
    let hi = min(firstRow + count, visibleRows.upperBound)
    guard lo < hi else { return }
    for globalRow in lo..<hi {
      let rowText = hugeRowText(
        line: line, rowIndex: globalRow - firstRow, utf16Length: utf16Length)
      let natural = rowText.size()
      let y =
        yOffset(ofVisualRow: globalRow)
        + Self.rowVerticalInset(rowHeight: layout.lineHeight, naturalHeight: natural.height)
      rowText.draw(
        with: NSRect(x: textX, y: y, width: natural.width, height: layout.lineHeight),
        options: [.usesLineFragmentOrigin]
      )
    }
  }

  /// Draws each soft-wrapped visual row of `attributed` (one row when not
  /// wrapping) at its row's y position.
  private func drawVisualRows(of attributed: NSAttributedString, line: Int, textX: CGFloat) {
    let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
    let rowsTop = yOffset(ofLine: line) + leadingInset(forLine: line)
    let height = rowHeight(forLine: line)
    let length = attributed.length
    for rowIndex in starts.indices {
      let bounds = rowRange(rowIndex, starts: starts, length: length)
      let rowText = attributed.attributedSubstring(
        from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
      let natural = rowText.size()
      let y =
        rowsTop + CGFloat(rowIndex) * height
        + Self.rowVerticalInset(rowHeight: height, naturalHeight: natural.height)
      rowText.draw(
        with: NSRect(x: textX, y: y, width: natural.width, height: height),
        options: [.usesLineFragmentOrigin]
      )
    }
  }

  /// Centers a fragment shorter than its row: the slack splits evenly above
  /// and below instead of pooling at the bottom of the row.
  nonisolated static func rowVerticalInset(rowHeight: CGFloat, naturalHeight: CGFloat) -> CGFloat {
    max(0, (rowHeight - naturalHeight) / 2)
  }

  private enum MarkdownBlockDecoration: Equatable {
    case bullet
    case ordered(String)
    case task(checked: Bool)
    case rule
    case fence
  }

  private func drawMarkdownBlockDecorations(
    lines: [NSAttributedString], range: Range<Int>, textX: CGFloat, visibleRows: Range<Int>,
    buffer: any TextDocumentReading
  ) {
    let rawLines = markdownRawLines(for: range, buffer: buffer)
    drawMarkdownTableBackgrounds(
      rawLines: rawLines, range: range, visibleRows: visibleRows, buffer: buffer)
    drawMarkdownFrontMatterBackgrounds(
      rawLines: rawLines, range: range, visibleRows: visibleRows, buffer: buffer)
    drawMarkdownFenceBackgrounds(
      rawLines: rawLines, range: range, visibleRows: visibleRows)
    for (offset, rawLine) in rawLines.enumerated() {
      let line = range.lowerBound + offset
      guard !isHugeLine(line) else {
        continue
      }
      let state = markdownLineState(forLine: line, in: buffer)
      let firstRow = firstVisualRow(ofLine: line)
      let rowCount = max(1, wrapIndex?.visualRowCount(ofLine: line) ?? 1)
      let lineTextX = lineTextColumnX(forLine: line)
      let lineY = yOffset(ofLine: line)
      if state.quoteDepth > 0 {
        let startRow = max(firstRow, visibleRows.lowerBound)
        let endRow = min(firstRow + rowCount, visibleRows.upperBound)
        if startRow < endRow {
          drawMarkdownQuoteBar(
            depth: state.quoteDepth,
            textX: textX,
            y: yOffset(ofVisualRow: startRow),
            height: CGFloat(endRow - startRow) * rowHeight(forLine: line))
        }
      }
      if let imageSource = state.imageSource, visibleRows.contains(firstRow) {
        drawMarkdownImageBlock(source: imageSource, line: line)
      }
      if state.insideFrontMatter, visibleRows.contains(firstRow) {
        drawMarkdownFrontMatterChips(
          field: state.frontMatterField,
          sequenceValue: state.frontMatterSequenceValue,
          line: line,
          y: lineY)
      }
      guard let decoration = markdownBlockDecoration(for: rawLine, state: state) else {
        continue
      }
      switch decoration {
      case .bullet:
        guard visibleRows.contains(firstRow) else { continue }
        drawMarkdownBullet(
          markerX: lineTextX - MarkdownDocumentMetrics.markerColumnWidth,
          y: lineY)
      case .ordered(let marker):
        guard visibleRows.contains(firstRow) else { continue }
        drawMarkdownOrderedMarker(
          marker,
          markerX: lineTextX - MarkdownDocumentMetrics.markerColumnWidth,
          y: lineY)
      case .task(let checked):
        guard visibleRows.contains(firstRow) else { continue }
        drawMarkdownTaskCheckbox(
          checked: checked,
          markerX: lineTextX - MarkdownDocumentMetrics.markerColumnWidth,
          y: lineY)
      case .rule:
        guard visibleRows.contains(firstRow) else { continue }
        drawMarkdownRule(textX: lineTextX, width: lineWrapContentWidth(forLine: line), y: lineY)
      case .fence:
        break
      }
    }
  }

  private func markdownRawLines(
    for range: Range<Int>, buffer: any TextDocumentReading
  ) -> [String] {
    let lines = buffer.text(
      forLineRange: range.lowerBound,
      count: range.count,
      maxBytesPerLine: maximumFetchedBytesPerLine
    )
    .components(separatedBy: "\n")
    if lines.count >= range.count {
      return Array(lines.prefix(range.count))
    }
    return lines + Array(repeating: "", count: range.count - lines.count)
  }

  private func drawMarkdownFenceBackgrounds(
    rawLines: [String], range: Range<Int>, visibleRows: Range<Int>
  ) {
    guard let buffer = reader else { return }
    let states = markdownLineStates(for: buffer)
    var runStart: Int?
    for (offset, _) in rawLines.enumerated() {
      let line = range.lowerBound + offset
      let state =
        line >= 0 && line < (states?.count ?? 0)
        ? states?[line] ?? .plain
        : .plain
      if state.isFenceDelimiter || state.insideFence || state.isIndentedCodeBlock {
        if runStart == nil {
          runStart = line
        }
      } else if let start = runStart {
        drawMarkdownCodeBlockBackground(
          fromLine: start, toLine: max(start, line - 1), visibleRows: visibleRows)
        runStart = nil
      }
    }
    if let start = runStart {
      drawMarkdownCodeBlockBackground(
        fromLine: start, toLine: max(start, range.upperBound - 1), visibleRows: visibleRows)
    }
  }

  private func drawMarkdownFrontMatterBackgrounds(
    rawLines: [String], range: Range<Int>, visibleRows: Range<Int>,
    buffer: any TextDocumentReading
  ) {
    let states = markdownLineStates(for: buffer)
    var runStart: Int?
    for (offset, _) in rawLines.enumerated() {
      let line = range.lowerBound + offset
      let state =
        line >= 0 && line < (states?.count ?? 0)
        ? states?[line] ?? .plain
        : .plain
      if state.insideFrontMatter {
        if runStart == nil {
          runStart = line
        }
      } else if let start = runStart {
        drawMarkdownFrontMatterBackground(
          fromLine: start, toLine: max(start, line - 1), visibleRows: visibleRows)
        runStart = nil
      }
    }
    if let start = runStart {
      drawMarkdownFrontMatterBackground(
        fromLine: start, toLine: max(start, range.upperBound - 1), visibleRows: visibleRows)
    }
  }

  private func drawMarkdownBullet(markerX: CGFloat, y: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.75),
    ]
    let bullet = NSAttributedString(string: "•", attributes: attributes)
    let centeredY =
      y + Self.rowVerticalInset(rowHeight: layout.lineHeight, naturalHeight: bullet.size().height)
    bullet.draw(
      with: NSRect(x: markerX + 6, y: centeredY, width: 12, height: layout.lineHeight),
      options: [.usesLineFragmentOrigin])
  }

  private func drawMarkdownOrderedMarker(_ marker: String, markerX: CGFloat, y: CGFloat) {
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .right
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.75),
      .paragraphStyle: paragraphStyle,
    ]
    let number = NSAttributedString(string: marker, attributes: attributes)
    let centeredY =
      y + Self.rowVerticalInset(rowHeight: layout.lineHeight, naturalHeight: number.size().height)
    number.draw(
      with: NSRect(x: markerX - 4, y: centeredY, width: 22, height: layout.lineHeight),
      options: [.usesLineFragmentOrigin])
  }

  private func drawMarkdownTaskCheckbox(checked: Bool, markerX: CGFloat, y: CGFloat) {
    let size = MarkdownDocumentMetrics.checkboxSize
    let rect = NSRect(
      x: markerX + 4,
      y: y + (layout.lineHeight - size) / 2,
      width: size,
      height: size)
    let path = NSBezierPath(
      roundedRect: rect,
      xRadius: 3,
      yRadius: 3)
    (checked ? MarkdownDocumentMetrics.accentColor : NSColor.secondaryLabelColor)
      .withAlphaComponent(checked ? 0.75 : 0.5)
      .setStroke()
    path.lineWidth = 1.4
    path.stroke()
    guard checked else { return }
    MarkdownDocumentMetrics.accentColor.setStroke()
    let mark = NSBezierPath()
    mark.lineWidth = 1.6
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    mark.move(to: NSPoint(x: rect.minX + 3.5, y: rect.midY))
    mark.line(to: NSPoint(x: rect.minX + 6, y: rect.midY + 3.5))
    mark.line(to: NSPoint(x: rect.maxX - 3, y: rect.midY - 3.5))
    mark.stroke()
  }

  private func drawMarkdownTableBackgrounds(
    rawLines: [String],
    range: Range<Int>,
    visibleRows: Range<Int>,
    buffer: any TextDocumentReading
  ) {
    let states = markdownLineStates(for: buffer)
    var runStart: Int?
    for (offset, _) in rawLines.enumerated() {
      let line = range.lowerBound + offset
      let state =
        line >= 0 && line < (states?.count ?? 0)
        ? states?[line] ?? .plain
        : .plain
      if state.isTableRow || state.isTableSeparator {
        if runStart == nil {
          runStart = line
        }
      } else if let start = runStart {
        drawMarkdownTableBackground(
          fromLine: start, toLine: max(start, line - 1), states: states ?? [],
          visibleRows: visibleRows)
        runStart = nil
      }
    }
    if let start = runStart {
      drawMarkdownTableBackground(
        fromLine: start, toLine: max(start, range.upperBound - 1), states: states ?? [],
        visibleRows: visibleRows)
    }
  }

  /// Draws the table's three rules (booktab style): above the header, through
  /// the vertical center of the delimiter row, and under the last body row.
  /// No boxes, no fills, no column lines — structure comes from the rules,
  /// the column gutters, and the alignment of the cells themselves.
  private func drawMarkdownTableBackground(
    fromLine startLine: Int,
    toLine endLine: Int,
    states: [MarkdownLineStyleState],
    visibleRows: Range<Int>
  ) {
    guard
      let frame = markdownTableFrameForTesting(
        fromLine: startLine, toLine: endLine, states: states, visibleRows: visibleRows),
      let ruleYs = markdownTableRuleYs(
        fromLine: startLine, toLine: endLine, states: states, visibleRows: visibleRows),
      !ruleYs.isEmpty
    else {
      return
    }
    MarkdownDocumentMetrics.tableRuleColor.setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    for y in ruleYs {
      path.move(to: NSPoint(x: frame.minX, y: y))
      path.line(to: NSPoint(x: frame.minX + frame.width, y: y))
    }
    path.stroke()
  }

  func markdownTableRuleYsForTesting(
    fromLine startLine: Int,
    toLine endLine: Int,
    visibleRows: Range<Int>
  ) -> [CGFloat]? {
    guard let buffer = reader else { return nil }
    return markdownTableRuleYs(
      fromLine: startLine,
      toLine: endLine,
      states: markdownLineStates(for: buffer) ?? [],
      visibleRows: visibleRows)
  }

  private func markdownTableRuleYs(
    fromLine startLine: Int,
    toLine endLine: Int,
    states: [MarkdownLineStyleState],
    visibleRows: Range<Int>
  ) -> [CGFloat]? {
    guard startLine >= 0, startLine < states.count, endLine >= startLine else { return nil }
    var top = yOffset(ofLine: startLine)
    var bottom =
      yOffset(ofLine: endLine)
      + CGFloat(max(1, wrapIndex?.visualRowCount(ofLine: endLine) ?? 1))
      * rowHeight(forLine: endLine)
    if markdownLineIsBlank(startLine - 1) {
      top -= MarkdownDocumentMetrics.tableRuleBreath
    }
    if markdownLineIsBlank(endLine + 1) {
      bottom += MarkdownDocumentMetrics.tableRuleBreath
    }

    var rules = [top]
    let separatorLine = (startLine...endLine).first { line in
      line < states.count && states[line].isTableSeparator
    }
    if let separatorLine {
      rules.append(yOffset(ofLine: separatorLine) + rowHeight(forLine: separatorLine) / 2)
    }
    rules.append(bottom)

    let tolerance = MarkdownDocumentMetrics.tableRuleBreath + 0.5
    let visibleTop = yOffset(ofVisualRow: visibleRows.lowerBound)
    let visibleBottom = yOffset(ofVisualRow: visibleRows.upperBound)
    return rules.filter { $0 >= visibleTop - tolerance && $0 <= visibleBottom + tolerance }
  }

  /// Whether `line` exists and contains only whitespace — the condition under
  /// which the table's outer rules may breathe into it.
  private func markdownLineIsBlank(_ line: Int) -> Bool {
    guard let buffer = reader, line >= 0, line < buffer.lineCount else { return false }
    let text = buffer.text(
      forLineRange: line, count: 1, maxBytesPerLine: maximumFetchedBytesPerLine)
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func drawMarkdownQuoteBar(depth: Int, textX: CGFloat, y: CGFloat, height: CGFloat) {
    MarkdownDocumentMetrics.accentColor.setFill()
    for level in 0..<max(1, min(depth, 3)) {
      NSRect(
        x: textX + CGFloat(level) * MarkdownDocumentMetrics.quoteIndentWidth
          + (MarkdownDocumentMetrics.quoteIndentWidth - MarkdownDocumentMetrics.quoteBarWidth) / 2,
        y: y + 1,
        width: MarkdownDocumentMetrics.quoteBarWidth,
        height: max(0, height - 2)
      )
      .fill()
    }
  }

  private func markdownLineState(
    forLine line: Int, in buffer: any TextDocumentReading
  ) -> MarkdownLineStyleState {
    let states = markdownLineStates(for: buffer)
    return line >= 0 && line < (states?.count ?? 0) ? states?[line] ?? .plain : .plain
  }

  private func markdownBlockDecoration(
    for line: String, state: MarkdownLineStyleState
  ) -> MarkdownBlockDecoration? {
    guard !state.insideFrontMatter, !state.insideFence, !state.isSetextUnderline,
      !state.isReferenceDefinition, !state.isIndentedCodeBlock
    else { return nil }
    let body = markdownQuoteBody(in: line)
    let nsLine = body as NSString
    var index = 0
    while index < nsLine.length, nsLine.character(at: index) == 32 {
      index += 1
    }
    let trimmed = body.trimmingCharacters(in: .whitespaces)
    if state.isFenceDelimiter, TextDocumentSyntaxHighlighter.isMarkdownFenceLine(body) {
      return .fence
    }
    if TextDocumentSyntaxHighlighter.markdownLineIsHorizontalRule(trimmed) {
      return .rule
    }
    if index + 1 < nsLine.length, Self.isMarkdownBulletMarker(nsLine.character(at: index)),
      nsLine.character(at: index + 1) == 32
    {
      let taskStart = index + 2
      if taskStart + 3 <= nsLine.length,
        nsLine.character(at: taskStart) == 91,
        nsLine.character(at: taskStart + 2) == 93
      {
        let value = nsLine.character(at: taskStart + 1)
        return .task(checked: value == 120 || value == 88)
      }
      return .bullet
    }
    var digitEnd = index
    while digitEnd < nsLine.length {
      let value = nsLine.character(at: digitEnd)
      guard value >= 48, value <= 57 else { break }
      digitEnd += 1
    }
    if digitEnd > index, digitEnd + 1 < nsLine.length,
      nsLine.character(at: digitEnd) == 46 || nsLine.character(at: digitEnd) == 41,
      nsLine.character(at: digitEnd + 1) == 32
    {
      let number = nsLine.substring(with: NSRange(location: index, length: digitEnd - index))
      return .ordered("\(number).")
    }
    return nil
  }

  /// Draws a code card: a rounded, faintly-toned surface, no border. The
  /// language label and the copy control live in its header band; the copy
  /// control itself draws later, above the code, in `drawMarkdownCodeCopyControls`.
  private func drawMarkdownCodeBlockBackground(
    fromLine startLine: Int, toLine endLine: Int, visibleRows: Range<Int>
  ) {
    guard
      let rect = markdownCodeBlockFrameForTesting(
        fromLine: startLine, toLine: endLine, visibleRows: visibleRows)
    else {
      return
    }
    MarkdownDocumentMetrics.codeBackground.setFill()
    NSBezierPath(
      roundedRect: rect,
      xRadius: MarkdownDocumentMetrics.codeBlockCornerRadius,
      yRadius: MarkdownDocumentMetrics.codeBlockCornerRadius
    )
    .fill()
  }

  private func drawMarkdownFrontMatterBackground(
    fromLine startLine: Int, toLine endLine: Int, visibleRows: Range<Int>
  ) {
    guard
      let rect = markdownFrontMatterFrameForTesting(
        fromLine: startLine, toLine: endLine, visibleRows: visibleRows)
    else {
      return
    }
    MarkdownDocumentMetrics.frontMatterBackground.setFill()
    let path = NSBezierPath(
      roundedRect: rect,
      xRadius: MarkdownDocumentMetrics.frontMatterCornerRadius,
      yRadius: MarkdownDocumentMetrics.frontMatterCornerRadius)
    path.fill()
  }

  private func drawMarkdownFrontMatterChips(
    field: MarkdownFrontMatterField?,
    sequenceValue: MarkdownFrontMatterValue?,
    line: Int,
    y: CGFloat
  ) {
    let values: [MarkdownFrontMatterValue]
    if let field, field.rendersValuesAsChips, !field.values.isEmpty {
      values = field.values
    } else if let sequenceValue {
      values = [sequenceValue]
    } else {
      return
    }

    var x =
      lineTextColumnX(forLine: line)
      + MarkdownDocumentMetrics.frontMatterKeyColumnWidth
      + MarkdownDocumentMetrics.frontMatterChipHorizontalPadding
    let rowTop = y + leadingInset(forLine: line)
    let chipHeight = MarkdownDocumentMetrics.frontMatterChipHeight
    let chipY = rowTop + max(0, (rowHeight(forLine: line) - chipHeight) / 2)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: MarkdownDocumentMetrics.frontMatterChipFont
    ]
    let separatorWidth = NSAttributedString(
      string: MarkdownDocumentMetrics.frontMatterChipDisplaySeparator,
      attributes: attributes
    ).size().width
    for value in values {
      let text = NSAttributedString(string: value.text, attributes: attributes)
      let textWidth = ceil(text.size().width)
      let width = textWidth + 2 * MarkdownDocumentMetrics.frontMatterChipHorizontalPadding
      let rect = NSRect(
        x: x - MarkdownDocumentMetrics.frontMatterChipHorizontalPadding,
        y: chipY,
        width: width,
        height: chipHeight)
      MarkdownDocumentMetrics.frontMatterChipBackground.setFill()
      NSBezierPath(
        roundedRect: backingAlignedRect(rect, options: .alignAllEdgesNearest),
        xRadius: MarkdownDocumentMetrics.frontMatterChipCornerRadius,
        yRadius: MarkdownDocumentMetrics.frontMatterChipCornerRadius
      )
      .fill()
      x += textWidth + separatorWidth
    }
  }

  /// The copy control of one fenced code block: its block's opening-fence line,
  /// the body lines it copies, and the on-screen rect of the button.
  struct MarkdownCodeCopyTarget: Equatable {
    let startLine: Int
    let contentRange: Range<Int>
    let buttonRect: NSRect
  }

  /// The copy controls for every fenced block whose opener falls in `range`,
  /// each pinned to its card's top-right corner. Indented code and frontmatter
  /// (no fence delimiters) get no control.
  func markdownCodeCopyTargets(inLineRange range: Range<Int>) -> [MarkdownCodeCopyTarget] {
    guard usesMarkdownDocumentLayout, let buffer = reader,
      let states = markdownLineStates(for: buffer)
    else {
      return []
    }
    let lower = max(0, range.lowerBound)
    let upper = min(states.count, range.upperBound)
    guard lower < upper else { return [] }
    var targets: [MarkdownCodeCopyTarget] = []
    for line in lower..<upper {
      // The authoritative opener flag, so a block stacked directly on another
      // (or on frontmatter) is still recognized — a neighbour-line heuristic
      // would mistake its opener for the previous block's closer.
      guard states[line].isFenceOpen else { continue }
      var closer = line + 1
      while closer < states.count, !states[closer].isFenceDelimiter { closer += 1 }
      guard closer < states.count else { continue }  // unmatched — never for closed fences
      let cardRight = lineOuterColumnX(forLine: line) + lineOuterContentWidth(forLine: line)
      let cardTop = yOffset(ofLine: line) + leadingInset(forLine: line)
      let width = MarkdownDocumentMetrics.codeCopyButtonWidth
      let height = MarkdownDocumentMetrics.codeCopyButtonHeight
      let inset = MarkdownDocumentMetrics.codeCopyButtonInset
      // Pinned a small inset below the card top (works for a labeled header
      // band and for a bare fence, where it floats over the first code row).
      let buttonRect = NSRect(
        x: cardRight - inset - width,
        y: cardTop + MarkdownDocumentMetrics.codeCopyButtonTopInset,
        width: width,
        height: height)
      targets.append(
        MarkdownCodeCopyTarget(
          startLine: line, contentRange: (line + 1)..<closer, buttonRect: buttonRect))
    }
    return targets
  }

  private func drawMarkdownCodeCopyControls(
    range: Range<Int>, visibleRows: Range<Int>
  ) {
    let visibleTop = yOffset(ofVisualRow: visibleRows.lowerBound)
    let visibleBottom = yOffset(ofVisualRow: visibleRows.upperBound)
    for target in markdownCodeCopyTargets(inLineRange: range) {
      let rect = target.buttonRect
      guard rect.maxY > visibleTop, rect.minY < visibleBottom else { continue }
      drawMarkdownCopyButton(in: rect, copied: target.startLine == copiedCodeBlockStartLine)
    }
  }

  private func drawMarkdownCopyButton(in rect: NSRect, copied: Bool) {
    let aligned = backingAlignedRect(rect, options: .alignAllEdgesNearest)
    let radius = MarkdownDocumentMetrics.codeCopyButtonCornerRadius
    // Mask any code behind the control with the card tint, then the bare icon
    // (no border) — a quiet glyph rather than a boxed button.
    MarkdownDocumentMetrics.codeBackground.setFill()
    NSBezierPath(roundedRect: aligned, xRadius: radius, yRadius: radius).fill()
    let symbol =
      copied
      ? Self.codeCopySymbol(named: "checkmark", color: MarkdownDocumentMetrics.codeCopyConfirmColor)
      : Self.codeCopySymbol(named: "doc.on.doc", color: MarkdownDocumentMetrics.codeCopyIconColor)
    guard let symbol else { return }
    let size = symbol.size
    symbol.draw(
      in: NSRect(
        x: aligned.midX - size.width / 2,
        y: aligned.midY - size.height / 2,
        width: size.width,
        height: size.height))
  }

  private static func codeCopySymbol(named name: String, color: NSColor) -> NSImage? {
    let configuration = NSImage.SymbolConfiguration(
      pointSize: MarkdownDocumentMetrics.codeCopyIconPointSize, weight: .medium
    )
    .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return NSImage(systemSymbolName: name, accessibilityDescription: "Copy code")?
      .withSymbolConfiguration(configuration)
  }

  /// The verbatim source of a fenced block's body (the lines between its
  /// delimiters), for the copy control.
  func markdownCopyableCodeText(contentRange: Range<Int>) -> String {
    guard let buffer = reader, !contentRange.isEmpty else { return "" }
    return buffer.text(
      forLineRange: contentRange.lowerBound,
      count: contentRange.count,
      maxBytesPerLine: maximumFetchedBytesPerLine)
  }

  /// Copies a fenced block's body to the pasteboard and shows a brief checkmark
  /// confirmation in its control.
  private func performCopyForCodeBlock(_ target: MarkdownCodeCopyTarget) {
    let text = markdownCopyableCodeText(contentRange: target.contentRange)
    // Route through ClipboardService for the same clear-then-set + failure
    // logging as the view's other copy paths.
    ClipboardService().copyPlainText(text)
    copiedCodeBlockStartLine = target.startLine
    copiedCodeBlockToken &+= 1
    let token = copiedCodeBlockToken
    DispatchQueue.main.asyncAfter(deadline: .now() + codeCopyConfirmDuration) { [weak self] in
      guard let self, self.copiedCodeBlockToken == token else { return }
      self.copiedCodeBlockStartLine = nil
      self.invalidateVisibleArea()
    }
    invalidateVisibleArea()
  }

  /// The logical-line band currently on screen, for hit-testing viewport chrome.
  private func visibleMarkdownLineRange() -> Range<Int>? {
    let rows = visibleVisualRowRange(in: visibleRect)
    guard !rows.isEmpty else { return nil }
    let first = lineLocation(ofVisualRow: rows.lowerBound).line
    let last = lineLocation(ofVisualRow: rows.upperBound - 1).line
    return first..<(last + 1)
  }

  /// Handles a click on a code block's copy control, returning true when one
  /// was hit (so the caller skips caret placement).
  private func handleMarkdownCodeCopyClick(at point: NSPoint) -> Bool {
    guard usesMarkdownDocumentLayout, let range = visibleMarkdownLineRange() else { return false }
    guard
      let target = markdownCodeCopyTargets(inLineRange: range).first(where: {
        $0.buttonRect.contains(point)
      })
    else {
      return false
    }
    performCopyForCodeBlock(target)
    return true
  }

  private func drawMarkdownRule(textX: CGFloat, width: CGFloat, y: CGFloat) {
    MarkdownDocumentMetrics.ruleColor.setStroke()
    let path = NSBezierPath()
    let lineY = y + layout.lineHeight / 2
    path.move(to: NSPoint(x: textX, y: lineY))
    path.line(to: NSPoint(x: textX + width, y: lineY))
    path.lineWidth = 1
    path.stroke()
  }

  /// Draws the image block living in an image line's leading inset: the
  /// decoded pixels when ready, a quiet placeholder card while loading or
  /// decoding, and a labeled card when the source cannot be loaded.
  private func drawMarkdownImageBlock(source: MarkdownImageSource, line: Int) {
    guard var frame = markdownImageBlockFrame(line: line) else { return }
    // The store can learn a size one turn before the coalesced relayout lands;
    // keep the drawn block inside the inset the wrap index actually allocated
    // so a freshly-sized image never overdraws the caption and lines below.
    let allocatedHeight =
      leadingInset(forLine: line) - MarkdownDocumentMetrics.imageBlockAir
      - MarkdownDocumentMetrics.imageCaptionGap
    if frame.height > allocatedHeight, allocatedHeight > 0 {
      let scale = allocatedHeight / frame.height
      frame.size = NSSize(width: frame.width * scale, height: allocatedHeight)
    }
    switch markdownImageStore.state(for: source.source) {
    case .loading:
      drawMarkdownImagePlaceholder(in: frame)
    case .failed:
      drawMarkdownImageFailureCard(in: frame, source: source)
    case .sized:
      let scale = window?.backingScaleFactor ?? 2
      let pixelSize = ceil(max(frame.width, frame.height) * scale)
      guard
        let image = markdownImageStore.decodedImage(
          for: source.source, maxPixelSize: pixelSize),
        let context = NSGraphicsContext.current?.cgContext
      else {
        drawMarkdownImagePlaceholder(in: frame)
        return
      }
      let aligned = backingAlignedRect(frame, options: .alignAllEdgesNearest)
      context.saveGState()
      NSBezierPath(
        roundedRect: aligned,
        xRadius: MarkdownDocumentMetrics.imageCornerRadius,
        yRadius: MarkdownDocumentMetrics.imageCornerRadius
      ).addClip()
      // CGContext.draw assumes a bottom-left origin; flip within the rect so
      // the image renders upright in this flipped view.
      context.translateBy(x: aligned.minX, y: aligned.maxY)
      context.scaleBy(x: 1, y: -1)
      context.interpolationQuality = .high
      context.draw(image, in: CGRect(origin: .zero, size: aligned.size))
      context.restoreGState()
    }
  }

  private func drawMarkdownImagePlaceholder(in frame: NSRect) {
    MarkdownDocumentMetrics.codeBackground.setFill()
    NSBezierPath(
      roundedRect: frame,
      xRadius: MarkdownDocumentMetrics.imageCornerRadius,
      yRadius: MarkdownDocumentMetrics.imageCornerRadius
    ).fill()
  }

  /// Strips Unicode directional formatting characters so attacker-authored
  /// alt text or paths cannot visually reorder the failure message.
  private static func sanitizedImageLabel(_ label: String) -> String {
    String(
      String.UnicodeScalarView(
        label.unicodeScalars.filter { scalar in
          switch scalar.value {
          case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return false
          default:
            return true
          }
        }))
  }

  private func drawMarkdownImageFailureCard(in frame: NSRect, source: MarkdownImageSource) {
    drawMarkdownImagePlaceholder(in: frame)
    let label = Self.sanitizedImageLabel(
      source.altText.isEmpty ? source.source : source.altText)
    let text = NSAttributedString(
      string: "Image unavailable · \(label)",
      attributes: [
        .font: MarkdownDocumentMetrics.imageCaptionFont,
        .foregroundColor: NSColor.tertiaryLabelColor,
      ])
    let inset = MarkdownDocumentMetrics.codeCardInset
    let size = text.size()
    let origin = NSPoint(
      x: frame.minX + inset,
      y: frame.midY - size.height / 2)
    text.draw(
      with: NSRect(
        origin: origin,
        size: NSSize(width: max(0, frame.width - inset * 2), height: size.height)),
      options: [.usesLineFragmentOrigin])
  }

  private func markdownQuoteBody(in line: String) -> String {
    let nsLine = line as NSString
    var index = 0
    while index < nsLine.length {
      let markerStart = index
      var spaces = 0
      while spaces < 3, index < nsLine.length, nsLine.character(at: index) == 32 {
        spaces += 1
        index += 1
      }
      guard index < nsLine.length, nsLine.character(at: index) == 62 else {
        index = markerStart
        break
      }
      index += 1
      if index < nsLine.length, nsLine.character(at: index) == 32 {
        index += 1
      }
    }
    return nsLine.substring(from: index)
  }

  /// Fills the selected column span on each visible line, behind the text. Lines
  /// fully spanned by a multi-line selection extend a little past their last
  /// character to signal the trailing newline is selected.
  private func drawSelectionHighlight(
    _ selection: TextSelection, lines: [NSAttributedString], range: Range<Int>, textX: CGFloat,
    visibleRows: Range<Int>
  ) {
    let focused = hasActiveKeyboardFocus
    (focused ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor)
      .setFill()
    for line in range {
      let lineTextX = lineTextColumnX(forLine: line)
      let attributed = lines[line - range.lowerBound]
      // A fully-selected line includes its trailing newline; mark it on the line's
      // last visual row.
      let includesNewline = line < selection.end.line
      guard let span = selection.columnSpan(onLine: line, lineLengthUTF16: lineLengthUTF16(line))
      else {
        continue
      }
      if let length = hugeLength(line) {
        drawHugeSelectionHighlight(
          line: line, utf16Length: length, span: span, includesNewline: includesNewline,
          textX: lineTextX, visibleRows: visibleRows)
        continue
      }
      let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
      let rowsTop = yOffset(ofLine: line) + leadingInset(forLine: line)
      let height = rowHeight(forLine: line)
      let length = attributed.length
      for rowIndex in starts.indices {
        let bounds = rowRange(rowIndex, starts: starts, length: length)
        let segmentStart = max(span.start, bounds.start)
        let segmentEnd = min(span.end, bounds.end)
        let isLastRow = rowIndex == starts.count - 1
        guard segmentEnd > segmentStart || (includesNewline && isLastRow) else { continue }
        let rowText = attributed.attributedSubstring(
          from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
        let xStart = lineTextX + xOffset(forColumn: segmentStart - bounds.start, in: rowText)
        var xEnd = lineTextX + xOffset(forColumn: segmentEnd - bounds.start, in: rowText)
        if includesNewline, isLastRow {
          xEnd += newlineSelectionWidth
        }
        NSRect(
          x: xStart, y: rowsTop + CGFloat(rowIndex) * height,
          width: max(0, xEnd - xStart), height: height
        ).fill()
      }
    }
  }

  /// Selection highlight for a huge line: only its visible grid rows are filled,
  /// each measured from a fetched window, so a selection spanning thousands of
  /// wrapped rows costs only the visible band.
  private func drawHugeSelectionHighlight(
    line: Int, utf16Length: Int, span: (start: Int, end: Int), includesNewline: Bool,
    textX: CGFloat, visibleRows: Range<Int>
  ) {
    let columns = hugeLineColumns
    let firstRow = firstVisualRow(ofLine: line)
    let count = hugeRowCount(utf16Length: utf16Length)
    let lo = max(firstRow, visibleRows.lowerBound)
    let hi = min(firstRow + count, visibleRows.upperBound)
    guard lo < hi else { return }
    for globalRow in lo..<hi {
      let rowIndex = globalRow - firstRow
      let rowStart = rowIndex * columns
      let rowEnd = min(utf16Length, rowStart + columns)
      let segmentStart = max(span.start, rowStart)
      let segmentEnd = min(span.end, rowEnd)
      let isLastRow = rowIndex == count - 1
      guard segmentEnd > segmentStart || (includesNewline && isLastRow) else { continue }
      let rowText = hugeRowText(line: line, rowIndex: rowIndex, utf16Length: utf16Length)
      let xStart = textX + xOffset(forColumn: segmentStart - rowStart, in: rowText)
      var xEnd = textX + xOffset(forColumn: segmentEnd - rowStart, in: rowText)
      if includesNewline, isLastRow {
        xEnd += newlineSelectionWidth
      }
      NSRect(
        x: xStart, y: yOffset(ofVisualRow: globalRow),
        width: max(0, xEnd - xStart), height: layout.lineHeight
      ).fill()
    }
  }

  /// Draws the caret at the (empty) selection head while focused and visible, or
  /// within the marked text while composing.
  private func drawCaretIfNeeded(lines: [NSAttributedString], range: Range<Int>, textX: CGFloat) {
    guard isEditable, hasActiveKeyboardFocus else { return }
    if let composition {
      drawCompositionCaret(composition, lines: lines, range: range, textX: textX)
      return
    }
    // The plain caret is hidden during the blink's off phase; the composing caret
    // (handled above) is always solid.
    guard let selection, selection.isEmpty, caretBlinkOn else { return }
    let line = selection.head.line
    guard range.contains(line) else { return }
    // Caret on the displayed line (which may include in-progress marked text only
    // on the composing line — handled above).
    let displayed = composedLineForDisplay(line: line, base: lines[line - range.lowerBound])
    drawCaret(
      forColumn: selection.head.columnUTF16, line: line, attributed: displayed,
      textX: lineTextColumnX(forLine: line))
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
    // The caret sits inside the marked run; map it to the composed line's column.
    drawCaret(
      forColumn: column + within, line: line,
      attributed: composedLineForDisplay(line: line, base: base),
      textX: lineTextColumnX(forLine: line))
  }

  /// Draws a 1.5pt caret at `column` on `line`, on the correct visual row.
  private func drawCaret(
    forColumn column: Int, line: Int, attributed: NSAttributedString, textX: CGFloat
  ) {
    let geometry = caretGeometry(forColumn: column, line: line, attributed: attributed)
    let x = textX + geometry.x
    let y = yOffset(ofVisualRow: geometry.visualRow)
    NSColor.textColor.setFill()
    NSRect(x: x, y: y, width: 1.5, height: rowHeight(forLine: line)).fill()
  }

  func markdownWrapContentWidthForTesting() -> CGFloat {
    wrapContentWidth
  }

  func endpointYForTesting(line: Int) -> CGFloat? {
    guard line >= 0, line < lineCount else { return nil }
    return yOffset(ofLine: line)
  }

  func markdownWrapContentWidthForTesting(line: Int) -> CGFloat {
    lineWrapContentWidth(forLine: line)
  }

  func markdownOuterContentWidthForTesting(line: Int) -> CGFloat {
    lineOuterContentWidth(forLine: line)
  }

  func markdownTextColumnXForTesting() -> CGFloat {
    textColumnX
  }

  func markdownTextColumnXForTesting(line: Int) -> CGFloat {
    lineTextColumnX(forLine: line)
  }

  func markdownOuterColumnXForTesting(line: Int) -> CGFloat {
    lineOuterColumnX(forLine: line)
  }

  func attributedLineStringForTesting(line: Int) -> String {
    attributedLine(forLine: line).string
  }

  static func markdownViewModeToggleCursorRectForTesting(in visible: NSRect) -> NSRect {
    markdownViewModeToggleCursorRect(in: visible)
  }

  func markdownCodeBlockFrameForTesting(
    fromLine startLine: Int,
    toLine endLine: Int,
    visibleRows: Range<Int>
  ) -> NSRect? {
    let startRow = firstVisualRow(ofLine: startLine)
    let endRowCount = max(1, wrapIndex?.visualRowCount(ofLine: endLine) ?? 1)
    let endRow = firstVisualRow(ofLine: endLine) + endRowCount
    guard endRow > visibleRows.lowerBound, startRow < visibleRows.upperBound else { return nil }
    // The slab spans the content rows only — the block air lives in the first
    // line's leading inset and the last line's trailing inset, outside the fill.
    let slabTop = yOffset(ofLine: startLine) + leadingInset(forLine: startLine)
    let slabBottom =
      yOffset(ofLine: endLine) + leadingInset(forLine: endLine)
      + rowHeight(forLine: endLine) * CGFloat(endRowCount)
    let y = max(slabTop, yOffset(ofVisualRow: visibleRows.lowerBound))
    let bottom = min(slabBottom, yOffset(ofVisualRow: visibleRows.upperBound))
    guard bottom > y else { return nil }
    return NSRect(
      x: lineOuterColumnX(forLine: startLine),
      y: y,
      width: lineOuterContentWidth(forLine: startLine),
      height: bottom - y
    )
  }

  func markdownFrontMatterFrameForTesting(
    fromLine startLine: Int,
    toLine endLine: Int,
    visibleRows: Range<Int>
  ) -> NSRect? {
    let startRow = firstVisualRow(ofLine: startLine)
    let endRowCount = max(1, wrapIndex?.visualRowCount(ofLine: endLine) ?? 1)
    let endRow = firstVisualRow(ofLine: endLine) + endRowCount
    guard endRow > visibleRows.lowerBound, startRow < visibleRows.upperBound else { return nil }
    let slabTop = yOffset(ofLine: startLine) + leadingInset(forLine: startLine)
    let slabBottom =
      yOffset(ofLine: endLine) + leadingInset(forLine: endLine)
      + rowHeight(forLine: endLine) * CGFloat(endRowCount)
    let y = max(slabTop, yOffset(ofVisualRow: visibleRows.lowerBound))
    let bottom = min(slabBottom, yOffset(ofVisualRow: visibleRows.upperBound))
    guard bottom > y else { return nil }
    return NSRect(
      x: lineOuterColumnX(forLine: startLine),
      y: y,
      width: lineOuterContentWidth(forLine: startLine),
      height: bottom - y)
  }

  /// The image block's frame inside an image line's leading inset, or nil for
  /// lines that are not image-only lines. Width and height follow the load
  /// state: full column width for the placeholder and failure cards, the
  /// fitted display size once the natural size is known. Internal so tests
  /// can assert on it; the draw path is its production consumer.
  func markdownImageBlockFrame(line: Int) -> NSRect? {
    guard usesMarkdownDocumentLayout, let buffer = reader,
      line >= 0, line < lineCount,
      let image = markdownLineState(forLine: line, in: buffer).imageSource
    else {
      return nil
    }
    let x = lineTextColumnX(forLine: line)
    let y = yOffset(ofLine: line) + MarkdownDocumentMetrics.imageBlockAir
    let contentWidth = lineWrapContentWidth(forLine: line)
    switch markdownImageStore.state(for: image.source) {
    case .loading:
      return NSRect(
        x: x, y: y, width: contentWidth,
        height: MarkdownDocumentMetrics.imagePlaceholderHeight)
    case .failed:
      return NSRect(
        x: x, y: y, width: contentWidth, height: MarkdownDocumentMetrics.imageFailureHeight)
    case .sized(let natural):
      let size = Self.markdownImageDisplaySize(natural: natural, contentWidth: contentWidth)
      return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
  }

  func markdownTableFrameForTesting(
    fromLine startLine: Int,
    toLine endLine: Int,
    visibleRows: Range<Int>
  ) -> NSRect? {
    guard let buffer = reader else { return nil }
    return markdownTableFrameForTesting(
      fromLine: startLine,
      toLine: endLine,
      states: markdownLineStates(for: buffer) ?? [],
      visibleRows: visibleRows)
  }

  func markdownTableFrameForTesting(
    fromLine startLine: Int,
    toLine endLine: Int,
    states: [MarkdownLineStyleState],
    visibleRows: Range<Int>
  ) -> NSRect? {
    guard startLine >= 0, startLine < states.count else { return nil }
    let columns = states[startLine].tableColumns
    guard !columns.isEmpty else { return nil }
    let startRow = firstVisualRow(ofLine: startLine)
    let endRow =
      firstVisualRow(ofLine: endLine) + max(1, wrapIndex?.visualRowCount(ofLine: endLine) ?? 1)
    guard endRow > visibleRows.lowerBound, startRow < visibleRows.upperBound else { return nil }
    let y = yOffset(ofVisualRow: max(startRow, visibleRows.lowerBound))
    let bottom = yOffset(ofVisualRow: min(endRow, visibleRows.upperBound))
    guard bottom > y else { return nil }
    let contentWidth =
      columns.reduce(CGFloat(0)) { $0 + $1.width }
      + MarkdownDocumentMetrics.tableColumnGutter * CGFloat(max(0, columns.count - 1))
      + MarkdownDocumentMetrics.tableEdgeInset * 2
    let width = min(contentWidth, lineOuterContentWidth(forLine: startLine))
    return NSRect(
      x: lineOuterColumnX(forLine: startLine),
      y: y,
      width: width,
      height: bottom - y
    )
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
      // The number sits on the line's first visual row; wrapped continuation rows
      // get no number.
      number.draw(
        with: NSRect(
          x: originX + max(0, width - GutterMetrics.trailingPadding - numberWidth),
          y: yOffset(ofLine: line),
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
    guard isEditable, editableBuffer != nil else {
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
    guard isEditable, editableBuffer != nil, let text = Self.plainText(from: string)
    else {
      return
    }

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
    return window.convertToScreen(
      convert(firstRectInViewCoordinates(forCharacterRange: range), to: nil))
  }

  func firstRectInViewCoordinates(forCharacterRange range: NSRange) -> NSRect {
    let geometry: CaretGeometry
    let rectLine: Int
    if let composition, let anchor = utf16Offset(of: composition.anchor) {
      let line = composition.anchor.line
      rectLine = line
      let base = attributedLine(forLine: line)
      let column = max(0, min(composition.anchor.columnUTF16, base.length))
      let markedText = composition.text as NSString
      let within = max(0, min(range.location - anchor, markedText.length))
      geometry = caretGeometry(
        forColumn: column + within,
        line: line,
        attributed: composedLineForDisplay(line: line, base: base)
      )
    } else {
      let caret = selection?.head ?? navigationHead
      rectLine = caret.line
      let attributed = attributedLine(forLine: caret.line)
      geometry = caretGeometry(
        forColumn: caret.columnUTF16,
        line: caret.line,
        attributed: attributed
      )
    }
    return NSRect(
      x: lineTextColumnX(forLine: rectLine) + geometry.x,
      y: yOffset(ofVisualRow: geometry.visualRow),
      width: 1,
      height: rowHeight(forLine: rectLine))
  }

  func characterIndex(for point: NSPoint) -> Int {
    guard reader != nil, let window else { return NSNotFound }
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
