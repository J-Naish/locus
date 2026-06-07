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

/// Maps between logical lines and the *visual rows* they occupy once soft-wrapped
/// (one logical line can wrap to several rows). Built from each line's wrapped-row
/// count as a prefix sum, so lookups are `O(log n)` and the total document height
/// is `totalVisualRows * lineHeight`. Pure and unit-testable.
struct WrapIndex: Equatable {
  /// `rowOffsets[i]` is the first visual row of logical line `i`; the last element
  /// is the total visual-row count. Always has `lineCount + 1` elements.
  private let rowOffsets: [Int]

  /// Builds the index from per-logical-line visual-row counts (each clamped to at
  /// least 1, since even an empty line occupies one row).
  init(visualRowsPerLine: [Int]) {
    var offsets = [Int](repeating: 0, count: visualRowsPerLine.count + 1)
    for (index, rows) in visualRowsPerLine.enumerated() {
      offsets[index + 1] = offsets[index] + max(1, rows)
    }
    rowOffsets = offsets
  }

  var lineCount: Int { max(0, rowOffsets.count - 1) }
  var totalVisualRows: Int { rowOffsets.last ?? 0 }

  /// The first visual row of `line` (clamped to the document).
  func firstVisualRow(ofLine line: Int) -> Int {
    rowOffsets[min(max(0, line), lineCount)]
  }

  /// Number of visual rows `line` wraps into.
  func visualRowCount(ofLine line: Int) -> Int {
    guard line >= 0, line < lineCount else { return 1 }
    return rowOffsets[line + 1] - rowOffsets[line]
  }

  /// The logical line and the row within it that a global visual row falls in.
  func location(ofVisualRow row: Int) -> (line: Int, rowInLine: Int) {
    guard lineCount > 0 else { return (0, 0) }
    let target = min(max(0, row), max(0, totalVisualRows - 1))
    // Largest `line` with `rowOffsets[line] <= target` (the wrapped rows of line
    // span `[rowOffsets[line], rowOffsets[line + 1])`).
    var low = 0
    var high = lineCount - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if rowOffsets[mid] <= target {
        low = mid
      } else {
        high = mid - 1
      }
    }
    return (low, target - rowOffsets[low])
  }
}

/// Splits a single laid-out line into soft-wrapped visual rows using Core Text's
/// line-breaking. Pure (no window), so it is unit-testable.
enum LineWrap {
  /// Defensive upper bound on the visual rows computed for one logical line, so a
  /// pathologically long line at a tiny width cannot materialize an unbounded
  /// array. This default is only a fallback: the view always overrides it with
  /// `maximumDrawnCharactersPerLine`, which equals the per-line character clip, so
  /// each row holds at least one character and the cap is reached only when the
  /// line is already clipped — it never drops text the clip has not already removed.
  static let defaultMaximumRows = 4096

  /// UTF-16 offsets where each wrapped visual row begins (the first is always 0).
  /// A non-positive width or an empty line yields `[0]` — a single row. Stops at
  /// `maximumRows` so the result is always bounded.
  static func visualRowStartOffsets(
    of attributed: NSAttributedString, width: CGFloat, maximumRows: Int = defaultMaximumRows
  ) -> [Int] {
    let length = attributed.length
    guard width > 0, length > 0 else { return [0] }

    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    var starts: [Int] = []
    var index = 0
    while index < length, starts.count < maximumRows {
      starts.append(index)
      let fits = CTTypesetterSuggestLineBreak(typesetter, index, Double(width))
      guard fits > 0 else { break }  // never advance by 0 (avoids an infinite loop)
      index += fits
    }
    return starts.isEmpty ? [0] : starts
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

  /// Whether the viewer accepts edits. Read-only entries keep this false; the
  /// host enables it for writable text. Editing is routed to the Rust buffer.
  var isEditable = false

  /// File the buffer is saved to on Cmd+S. The viewer owns the write so it can
  /// run it off the main thread without blocking the UI.
  var saveURL: URL?

  /// The file's original text encoding, restored on save (so a Shift JIS / UTF-16
  /// file is not silently rewritten as UTF-8).
  var saveEncoding: String.Encoding = .utf8

  /// Reports a save outcome to the host: on success the post-write file
  /// fingerprint (so the host records it before the change monitor reacts), on
  /// failure the error to surface.
  var onSaveCompletion: ((Result<DocumentFileFingerprint?, Error>) -> Void)?

  /// True while a save is writing on a background thread. Buffer *mutations* are
  /// paused while it is true so the background read never races an edit; reads
  /// (rendering, selection) stay safe because the core buffer is `Sync`. Set
  /// synchronously on the main thread by the save flow (settable for tests).
  var isSaving = false

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
  /// excluded), via two `O(log n)` position lookups. Used only for lines already
  /// suspected huge, so normal lines never pay for it.
  private func hugeLineContent(_ line: Int) -> (start: Int, length: Int) {
    guard let buffer else { return (0, 0) }
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
    guard let buffer, rowEnd > rowStart, let info = hugeLineInfo[line] else {
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
  /// wrapping. Rebuilt fully on open, width change, and undo/redo; updated for the
  /// single changed line on ordinary typing/deletion within a line.
  private var wrapIndex: WrapIndex?
  /// The per-logical-line wrapped-row counts the current `wrapIndex` was built from,
  /// kept so a single-line edit can recompute just that line instead of re-wrapping
  /// the whole document. `nil` whenever wrapping is inactive (mirrors `wrapIndex`).
  private var wrapRowCounts: [Int]?
  /// Wrap width the current `wrapIndex` was built at, so resize only rebuilds when
  /// the width actually changes.
  private var lastWrapWidth: CGFloat = -1

  var lineCount: Int { buffer?.lineCount ?? 1 }

  /// Width available for wrapped text (viewport minus gutter and padding).
  private var wrapContentWidth: CGFloat {
    let visible = enclosingScrollView?.documentVisibleRect.width ?? frame.width
    return visible - gutterWidth - horizontalPadding * 2
  }

  /// (Re)builds the wrap index for the current buffer and width when the document
  /// wraps (prose, or a non-prose document holding a long line), or clears it for
  /// horizontal scrolling. Reads the whole (bounded) document once; line widths
  /// depend only on the font, so highlighting is skipped here.
  ///
  /// `recomputeLongLine` forces re-deciding whether a non-prose document has a
  /// long line — passed when the content changed (open, multi-line edit, undo).
  /// A pure resize passes false and reuses the cached decision, *unless* the
  /// decision was never computed at a valid width yet (see `longLineDecisionValid`),
  /// so the first real layout after a width-less open still resolves it.
  private func rebuildWrapIndex(recomputeLongLine: Bool = true) {
    lastWrapWidth = wrapContentWidth
    guard let buffer, wrapContentWidth > 0,
      buffer.lineCount <= maximumWrappableLineCount,
      // Estimate the bytes the build pulls across the FFI: at most the per-line
      // fetch cap times the line count, but never more than the file. A few huge
      // lines stay tiny here and still wrap; very many long lines do not.
      min(buffer.byteLength, buffer.lineCount * maximumFetchedBytesPerLine)
        <= maximumWrappableFetchedByteBudget
    else {
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
      wrapIndex = nil
      wrapRowCounts = nil
      hugeLineInfo = [:]
      return
    }
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
    for (line, lineText) in lineStrings.enumerated() {
      if (lineText as NSString).length >= maximumDrawnCharactersPerLine {
        let content = hugeLineContent(line)
        if content.length > maximumDrawnCharactersPerLine {
          hugeLineInfo[line] = HugeLineInfo(start: content.start, length: content.length)
          counts.append(hugeRowCount(utf16Length: content.length))
          continue
        }
      }
      counts.append(wrapRowCount(text: lineText, width: width))
    }
    wrapRowCounts = counts
    wrapIndex = WrapIndex(visualRowsPerLine: counts)
  }

  /// Recomputes the wrap index after an edit confined to one logical line (no line
  /// added or removed), replacing only that line's wrapped-row count rather than
  /// re-wrapping the whole document.
  private func updateWrapIndex(forChangedLine line: Int) {
    // Horizontal-scroll mode: stay there unless this edit introduced the first
    // long line, which flips the whole document to wrapping. Reading just the one
    // edited line keeps ordinary typing in a no-wrap document O(1).
    guard var counts = wrapRowCounts else {
      guard !wrapsLines, longLineCount == 0 else { return }
      let text = displayLineStrings(forLineRange: line, count: 1).first ?? ""
      if (text as NSString).length > longLineWrapThreshold {
        rebuildWrapIndex()
      }
      return
    }
    // Already wrapping: update just the changed line's row count. Falls back to a
    // full rebuild when the fast path is not provably safe.
    guard let buffer, counts.count == buffer.lineCount, line >= 0, line < counts.count,
      lastWrapWidth == wrapContentWidth
    else {
      rebuildWrapIndex()
      return
    }
    let text = displayLineStrings(forLineRange: line, count: 1).first ?? ""
    // Editing into or out of a huge line changes its grid row count (and whether
    // it is windowed at all); a full rebuild re-resolves the true length. Rare, so
    // the cost is acceptable; ordinary lines never reach here.
    if isHugeLine(line) || (text as NSString).length >= maximumDrawnCharactersPerLine {
      rebuildWrapIndex()
      return
    }
    // Keep the long-line bookkeeping current so a non-prose document leaves wrap
    // mode the moment its last long line is shortened (not only on a later
    // reload). Prose has no `lineIsLong` and always wraps, so it is unaffected.
    if !wrapsLines, var flags = lineIsLong, line < flags.count {
      let isLong = (text as NSString).length > longLineWrapThreshold
      if flags[line] != isLong {
        flags[line] = isLong
        lineIsLong = flags
        longLineCount += isLong ? 1 : -1
        if longLineCount == 0 {
          rebuildWrapIndex(recomputeLongLine: false)  // last long line gone → scroll
          return
        }
      }
    }
    counts[line] = wrapRowCount(text: text, width: wrapContentWidth)
    wrapRowCounts = counts
    wrapIndex = WrapIndex(visualRowsPerLine: counts)
  }

  /// Number of visual rows `text` occupies at `width`.
  private func wrapRowCount(text: String, width: CGFloat) -> Int {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    return LineWrap.visualRowStartOffsets(
      of: attributed, width: width, maximumRows: maximumDrawnCharactersPerLine
    ).count
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

  /// UTF-16 start offsets of each visual row within `line` (just `[0]` when the
  /// document is not wrapping). `attributed` is the line's displayed string.
  private func visualRowStartOffsets(ofLine line: Int, attributed: NSAttributedString) -> [Int] {
    guard wrapIndex != nil else { return [0] }
    return LineWrap.visualRowStartOffsets(
      of: attributed, width: wrapContentWidth, maximumRows: maximumDrawnCharactersPerLine)
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
  override func resetCursorRects() {
    let visible = visibleRect
    guard !visible.isEmpty else { return }
    let gutterEdge = (enclosingScrollView?.contentView.bounds.origin.x ?? 0) + gutterWidth
    let textMinX = max(visible.minX, gutterEdge)
    let textRect = NSRect(
      x: textMinX, y: visible.minY, width: visible.maxX - textMinX, height: visible.height)
    guard textRect.width > 0 else { return }
    addCursorRect(textRect, cursor: .iBeam)
  }

  func setBuffer(_ buffer: TextBuffer?) {
    self.buffer = buffer
    cachedBand = nil
    maxObservedLineWidth = 0
    selection = nil
    isSelecting = false
    verticalGoalX = nil
    composition = nil
    // A save in flight (if any) was for the previous buffer; let its completion
    // mark that buffer saved, but the new document starts editable and clean.
    isSaving = false
    rebuildWrapIndex()  // the previous buffer's wrap index does not apply
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
    guard let buffer, range.location >= 0, range.length >= 0,
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
    guard let buffer, index >= 0, index <= buffer.utf16Length,
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
    guard let buffer, line >= 0, line < buffer.lineCount,
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
    guard buffer != nil else { return nil }
    let rows = visibleVisualRowRange(in: visibleRect)
    guard !rows.isEmpty else { return NSRange(location: 0, length: 0) }
    let firstLine = lineLocation(ofVisualRow: rows.lowerBound).line
    let lastLine = lineLocation(ofVisualRow: rows.upperBound - 1).line
    let start = lineUTF16Range(firstLine).location
    let lastRange = lineUTF16Range(lastLine)
    return NSRange(location: start, length: max(0, NSMaxRange(lastRange) - start))
  }

  // MARK: First responder & focus

  override var acceptsFirstResponder: Bool { buffer != nil }

  override func becomeFirstResponder() -> Bool {
    let didBecome = super.becomeFirstResponder()
    if didBecome {
      startCaretBlinking()
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
    if window == nil { stopCaretBlinking() }
  }

  // MARK: Caret blink

  /// Whether the plain insertion caret should be blinking right now: focused, not
  /// composing (the marked-text caret stays solid), and a collapsed selection.
  /// Pure for testability.
  static func caretShouldBlink(isFirstResponder: Bool, isComposing: Bool, selectionIsEmpty: Bool)
    -> Bool
  {
    isFirstResponder && !isComposing && selectionIsEmpty
  }

  private var showsBlinkingCaret: Bool {
    Self.caretShouldBlink(
      isFirstResponder: window?.firstResponder === self,
      isComposing: composition != nil,
      selectionIsEmpty: selection?.isEmpty == true)
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
    guard buffer != nil else { return }
    // Finalize any in-progress composition before moving the caret.
    if hasMarkedText() { unmarkText() }
    window?.makeFirstResponder(self)
    let endpoint = endpoint(at: convert(event.locationInWindow, from: nil))
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
    let rawRow = Int((point.y / layout.lineHeight).rounded(.down))
    // A click in the empty area padded below the last row lands at the document
    // end, regardless of x — not at the column nearest the click on the last line.
    if rawRow >= totalVisualRows {
      let lastLine = max(0, lineCount - 1)
      return TextSelection.Endpoint(line: lastLine, columnUTF16: lineLengthUTF16(lastLine))
    }
    let row = min(max(0, totalVisualRows - 1), max(0, rawRow))
    let (line, rowInLine) = lineLocation(ofVisualRow: row)
    let textRelativeX = point.x - (gutterWidth + horizontalPadding)
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
      return buffer != nil
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
    guard let buffer, let selection, !selection.isEmpty else {
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
    guard let buffer else { return "" }
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
    showCaretSolid()
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
    // Move by one *visual* row, so wrapped lines navigate row-by-row.
    let currentRow = visualRow(of: head)
    let targetRow = down ? min(currentRow + 1, max(0, totalVisualRows - 1)) : max(currentRow - 1, 0)
    let newHead: TextSelection.Endpoint
    if targetRow == currentRow {
      // Already at the first/last row: go to the line's start/end instead.
      newHead = TextSelection.Endpoint(
        line: head.line, columnUTF16: down ? lineLengthUTF16(head.line) : 0)
    } else {
      let (line, rowInLine) = lineLocation(ofVisualRow: targetRow)
      if let length = hugeLength(line) {
        let rowStart = rowInLine * hugeLineColumns
        let rowText = hugeRowText(line: line, rowIndex: rowInLine, utf16Length: length)
        newHead = TextSelection.Endpoint(
          line: line, columnUTF16: min(length, rowStart + columnUTF16(forX: goalX, in: rowText)))
      } else {
        let attributed = attributedLine(forLine: line)
        let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
        let bounds = rowRange(rowInLine, starts: starts, length: attributed.length)
        let rowText = attributed.attributedSubstring(
          from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
        newHead = TextSelection.Endpoint(
          line: line, columnUTF16: bounds.start + columnUTF16(forX: goalX, in: rowText))
      }
    }
    applyMovedHead(newHead, extend: extend, keepGoalX: true)
    verticalGoalX = goalX
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
    guard let buffer, let info = hugeLineInfo[line] else {
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
    guard !isSaving, let buffer else { return false }
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
    // A pure insert with no line break changes only the line it lands on, so the
    // wrap index can be updated for that line alone. A range replace may span or
    // introduce line breaks, so it triggers a full rebuild.
    let isSingleLineInsert = end == start && string.rangeOfCharacter(from: .newlines) == nil
    finishEdit(
      caretUTF16: start + (string as NSString).length, singleLineChange: isSingleLineInsert)
    return true
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

  /// Reverts the most recent buffer edit. Returns whether the request was handled
  /// (true while editable), regardless of whether anything was undone.
  @discardableResult
  func undoEdit() -> Bool {
    guard isEditable, !isSaving, let buffer else { return false }
    composition = nil
    if (try? buffer.undo()) == true {
      afterUndoRedo()
    }
    return true
  }

  /// Re-applies the most recently undone edit. See `undoEdit` for the return value.
  @discardableResult
  func redoEdit() -> Bool {
    guard isEditable, !isSaving, let buffer else { return false }
    composition = nil
    if (try? buffer.redo()) == true {
      afterUndoRedo()
    }
    return true
  }

  /// Refresh after undo/redo replaced buffer content beneath the current
  /// selection: drop caches, clamp the (possibly now out-of-range) selection,
  /// re-measure, and repaint.
  private func afterUndoRedo() {
    cachedBand = nil
    maxObservedLineWidth = 0
    verticalGoalX = nil
    rebuildWrapIndex()
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
    guard !isSaving, let buffer, let startOffset = utf16Offset(of: start),
      let endOffset = utf16Offset(of: end), endOffset > startOffset
    else {
      return
    }
    do {
      try buffer.delete(fromUTF16: startOffset, toUTF16: endOffset)
      // A deletion confined to one line removes no line break, so only that line's
      // wrap changes; a deletion spanning lines merges them and needs a full rebuild.
      finishEdit(caretUTF16: startOffset, singleLineChange: start.line == end.line)
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
  /// repaints the visible band. When `singleLineChange` is true the edit stayed
  /// within one logical line, so only that line's wrap is recomputed instead of
  /// the whole document.
  private func finishEdit(caretUTF16 offset: Int, singleLineChange: Bool = false) {
    cachedBand = nil
    verticalGoalX = nil
    // The widest-line high-water mark can only shrink via an edit (deleting or
    // splitting a long line), so reset it and let `draw` re-measure the visible
    // band rather than keeping a stale, too-wide horizontal extent.
    maxObservedLineWidth = 0
    var changedLine: Int?
    if let buffer, let position = try? buffer.position(forUTF16: offset) {
      selection = TextSelection(
        caretAt: .init(line: position.line, columnUTF16: position.columnUTF16))
      changedLine = position.line
    }
    if singleLineChange, let changedLine {
      updateWrapIndex(forChangedLine: changedLine)
    } else {
      rebuildWrapIndex()
    }
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
    onDirtyChange?(buffer?.isDirty ?? false)
  }

  // MARK: Save

  /// Saves the buffer to `saveURL` on a background thread so the write never
  /// blocks the UI. `isSaving` is set synchronously here (before any await) to
  /// pause buffer mutations for the write's duration; rendering keeps reading the
  /// buffer concurrently, which is sound because the core buffer is `Sync`.
  func requestSave() {
    guard isEditable, !isSaving, let buffer, buffer.isDirty, let saveURL else {
      return
    }
    isSaving = true
    invalidateVisibleArea()

    // Capture everything the completion needs at save start. The view may be
    // reused for another buffer/entry before the write finishes (reload, file
    // switch), so completion must act on the buffer that was actually saved and
    // route to the entry that requested it — never the current one.
    let savedBuffer = buffer
    let pending = SendableTextBuffer(buffer)
    let store = bufferStore
    let completion = onSaveCompletion
    let encoding = saveEncoding
    Task { [weak self] in
      let result: Result<DocumentFileFingerprint?, Error>
      do {
        let fingerprint = try await Task.detached {
          try store.save(pending.buffer, to: saveURL, encoding: encoding)
          // Read the new fingerprint here, still off-main, so the host can record
          // the post-save state before the change monitor's debounced event.
          return DocumentFileFingerprint.read(at: saveURL)
        }.value
        result = .success(fingerprint)
      } catch {
        result = .failure(error)
      }
      self?.finishSave(result, savedBuffer: savedBuffer, completion: completion)
    }
  }

  /// Main-actor continuation after the background write. Marks the buffer that was
  /// saved (not whatever the view shows now) and reports to the save's own
  /// completion. Live view state (`isSaving`, dirty, repaint) is touched only if
  /// that buffer is still the current one — a buffer swap during the save already
  /// reset `isSaving` and must not be clobbered.
  private func finishSave(
    _ result: Result<DocumentFileFingerprint?, Error>,
    savedBuffer: TextBuffer,
    completion: ((Result<DocumentFileFingerprint?, Error>) -> Void)?
  ) {
    switch result {
    case .success:
      savedBuffer.markSaved()
    case .failure:
      NSSound.beep()
    }
    if savedBuffer === buffer {
      isSaving = false
      notifyDirtyChanged()
      invalidateVisibleArea()
    }
    completion?(result)
  }

  /// Text-relative x of the caret at `endpoint`, measured within its visual row.
  private func caretX(for endpoint: TextSelection.Endpoint) -> CGFloat {
    if let length = hugeLength(endpoint.line) {
      let columns = hugeLineColumns
      let rowIndex = min(hugeRowCount(utf16Length: length) - 1, endpoint.columnUTF16 / columns)
      let rowStart = rowIndex * columns
      let rowText = hugeRowText(line: endpoint.line, rowIndex: rowIndex, utf16Length: length)
      return xOffset(forColumn: min(endpoint.columnUTF16 - rowStart, rowText.length), in: rowText)
    }
    let attributed = attributedLine(forLine: endpoint.line)
    let starts = visualRowStartOffsets(ofLine: endpoint.line, attributed: attributed)
    let rowIndex = visualRowIndex(forColumn: endpoint.columnUTF16, starts: starts)
    let bounds = rowRange(rowIndex, starts: starts, length: attributed.length)
    let rowText = attributed.attributedSubstring(
      from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
    return xOffset(forColumn: min(endpoint.columnUTF16, bounds.end) - bounds.start, in: rowText)
  }

  private func scrollCaretToVisible(_ endpoint: TextSelection.Endpoint) {
    let x = gutterWidth + horizontalPadding + caretX(for: endpoint)
    let rect = NSRect(
      x: x - caretScrollMargin,
      y: CGFloat(visualRow(of: endpoint)) * layout.lineHeight,
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
    // Resize changes the wrap width; rebuild the index when it actually changed.
    // The content has not changed, so reuse the cached long-line decision rather
    // than re-scanning the document just to resize.
    if lastWrapWidth != wrapContentWidth {
      rebuildWrapIndex(recomputeLongLine: false)
    }
    let visibleSize = enclosingScrollView?.documentVisibleRect.size
    let visibleWidth = visibleSize?.width ?? frame.width
    // Fill at least the viewport height so a short document's empty area below the
    // last line is still part of the text view: it shows the editor background,
    // takes the I-beam cursor, and accepts a click (which lands at the document
    // end). A tall document keeps its content height, so virtualization is intact.
    let contentHeight = CGFloat(max(totalVisualRows, 1)) * layout.lineHeight
    let height = max(contentHeight, visibleSize?.height ?? frame.height)
    if wrapIndex != nil {
      // Wrapped: fill the viewport width; no horizontal scrolling.
      setFrameSize(NSSize(width: visibleWidth, height: height))
    } else {
      let contentWidth =
        gutterWidth + horizontalPadding + maxObservedLineWidth + trailingContentMargin
      setFrameSize(NSSize(width: max(visibleWidth, contentWidth), height: height))
    }
    // The visible band and gutter width may have changed; re-establish the
    // I-beam cursor rect so its boundary stays aligned with the gutter edge.
    window?.invalidateCursorRects(for: self)
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
    // A pathologically long non-prose line keeps base styling but skips rule
    // highlighting (Cursor-like) — it both reads as "this is the long blob" and
    // avoids regex over a huge line. Prose always highlights.
    TextDocumentSyntaxHighlighter.apply(
      to: attributed, text: visible, syntax: syntax, font: font, range: fullRange,
      applyRules: highlightsLine(lengthUTF16: fullRange.length))
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
    let first = max(0, Int((rect.minY / layout.lineHeight).rounded(.down)))
    let last = min(total, Int((rect.maxY / layout.lineHeight).rounded(.up)))
    return first < last ? first..<last : 0..<0
  }

  override func draw(_ dirtyRect: NSRect) {
    viewportBackgroundColor.setFill()
    dirtyRect.fill()

    guard let buffer else {
      return
    }
    let rows = visibleVisualRowRange(in: dirtyRect)
    guard !rows.isEmpty else {
      return
    }
    // Visible visual rows map back to a logical-line band to fetch.
    let firstLine = lineLocation(ofVisualRow: rows.lowerBound).line
    let lastLine = lineLocation(ofVisualRow: rows.upperBound - 1).line
    let range = firstLine..<(lastLine + 1)

    let gutter = gutterWidth
    let textX = gutter + horizontalPadding
    let lines = attributedBandLines(for: buffer, range: range)

    if let selection, !selection.isEmpty {
      drawSelectionHighlight(selection, lines: lines, range: range, textX: textX, visibleRows: rows)
    }

    var widest = maxObservedLineWidth
    for (offset, attributedLine) in lines.enumerated() {
      let lineIndex = range.lowerBound + offset
      // A huge line is never laid out in full; draw only its visible rows from
      // windows fetched on demand. It always wraps, so it adds no scroll width.
      if let length = hugeLength(lineIndex) {
        drawHugeLineRows(line: lineIndex, utf16Length: length, textX: textX, visibleRows: rows)
        continue
      }
      let drawn = composedLineForDisplay(line: lineIndex, base: attributedLine)
      widest = max(widest, drawn.size().width)
      drawVisualRows(of: drawn, line: lineIndex, textX: textX)
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
      let y = CGFloat(globalRow) * layout.lineHeight
      rowText.draw(
        with: NSRect(x: textX, y: y, width: rowText.size().width, height: layout.lineHeight),
        options: [.usesLineFragmentOrigin]
      )
    }
  }

  /// Draws each soft-wrapped visual row of `attributed` (one row when not
  /// wrapping) at its row's y position.
  private func drawVisualRows(of attributed: NSAttributedString, line: Int, textX: CGFloat) {
    let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
    let firstRow = firstVisualRow(ofLine: line)
    let length = attributed.length
    for rowIndex in starts.indices {
      let bounds = rowRange(rowIndex, starts: starts, length: length)
      let rowText = attributed.attributedSubstring(
        from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
      let y = CGFloat(firstRow + rowIndex) * layout.lineHeight
      rowText.draw(
        with: NSRect(x: textX, y: y, width: rowText.size().width, height: layout.lineHeight),
        options: [.usesLineFragmentOrigin]
      )
    }
  }

  /// Fills the selected column span on each visible line, behind the text. Lines
  /// fully spanned by a multi-line selection extend a little past their last
  /// character to signal the trailing newline is selected.
  private func drawSelectionHighlight(
    _ selection: TextSelection, lines: [NSAttributedString], range: Range<Int>, textX: CGFloat,
    visibleRows: Range<Int>
  ) {
    let focused = window?.firstResponder === self
    (focused ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor)
      .setFill()
    for line in range {
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
          textX: textX, visibleRows: visibleRows)
        continue
      }
      let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
      let firstRow = firstVisualRow(ofLine: line)
      let length = attributed.length
      for rowIndex in starts.indices {
        let bounds = rowRange(rowIndex, starts: starts, length: length)
        let segmentStart = max(span.start, bounds.start)
        let segmentEnd = min(span.end, bounds.end)
        let isLastRow = rowIndex == starts.count - 1
        guard segmentEnd > segmentStart || (includesNewline && isLastRow) else { continue }
        let rowText = attributed.attributedSubstring(
          from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
        let xStart = textX + xOffset(forColumn: segmentStart - bounds.start, in: rowText)
        var xEnd = textX + xOffset(forColumn: segmentEnd - bounds.start, in: rowText)
        if includesNewline, isLastRow {
          xEnd += newlineSelectionWidth
        }
        NSRect(
          x: xStart, y: CGFloat(firstRow + rowIndex) * layout.lineHeight,
          width: max(0, xEnd - xStart), height: layout.lineHeight
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
        x: xStart, y: CGFloat(globalRow) * layout.lineHeight,
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
    // The plain caret is hidden during the blink's off phase; the composing caret
    // (handled above) is always solid.
    guard let selection, selection.isEmpty, caretBlinkOn else { return }
    let line = selection.head.line
    guard range.contains(line) else { return }
    // Caret on the displayed line (which may include in-progress marked text only
    // on the composing line — handled above).
    let displayed = composedLineForDisplay(line: line, base: lines[line - range.lowerBound])
    drawCaret(
      forColumn: selection.head.columnUTF16, line: line, attributed: displayed, textX: textX)
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
      attributed: composedLineForDisplay(line: line, base: base), textX: textX)
  }

  /// Draws a 1.5pt caret at `column` on `line`, on the correct visual row.
  private func drawCaret(
    forColumn column: Int, line: Int, attributed: NSAttributedString, textX: CGFloat
  ) {
    if let length = hugeLength(line) {
      let columns = hugeLineColumns
      let rowIndex = min(hugeRowCount(utf16Length: length) - 1, column / columns)
      let rowText = hugeRowText(line: line, rowIndex: rowIndex, utf16Length: length)
      let x =
        textX + xOffset(forColumn: min(column - rowIndex * columns, rowText.length), in: rowText)
      let y = CGFloat(firstVisualRow(ofLine: line) + rowIndex) * layout.lineHeight
      NSColor.textColor.setFill()
      NSRect(x: x, y: y, width: 1.5, height: layout.lineHeight).fill()
      return
    }
    let starts = visualRowStartOffsets(ofLine: line, attributed: attributed)
    let rowIndex = visualRowIndex(forColumn: column, starts: starts)
    let bounds = rowRange(rowIndex, starts: starts, length: attributed.length)
    let rowText = attributed.attributedSubstring(
      from: NSRange(location: bounds.start, length: bounds.end - bounds.start))
    let x = textX + xOffset(forColumn: min(column, bounds.end) - bounds.start, in: rowText)
    let y = CGFloat(firstVisualRow(ofLine: line) + rowIndex) * layout.lineHeight
    NSColor.textColor.setFill()
    NSRect(x: x, y: y, width: 1.5, height: layout.lineHeight).fill()
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
          y: CGFloat(firstVisualRow(ofLine: line)) * layout.lineHeight,
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
    // Reject input while saving before touching composition, so a save in
    // progress does not silently drop a keystroke mid-composition.
    guard !isSaving, let text = Self.plainText(from: string) else { return }
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
    guard isEditable, !isSaving, buffer != nil, let text = Self.plainText(from: string) else {
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
  /// Whether long lines soft-wrap to the viewport (prose) or scroll horizontally
  /// (structured/code/data). Decided per document by the host.
  let wrapsLines: Bool
  let isEditable: Bool
  let saveURL: URL
  let saveEncoding: String.Encoding
  /// A monotonic counter the host bumps to request a save (the viewer owns the
  /// off-main write). A change since the last seen value triggers `requestSave`.
  let saveRequest: Int
  let onSaveCompletion: (Result<DocumentFileFingerprint?, Error>) -> Void
  let onDirtyChange: (Bool) -> Void
  let onFocusChange: (Bool) -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor

    let documentView = LineRenderingTextView()
    documentView.setAccessibilityIdentifier("document-large-text-viewer")
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    documentView.showsLineNumbers = syntax.supportsLineNumbers
    // Set before the buffer so the first wrap-index build uses the right mode.
    documentView.wrapsLines = wrapsLines
    documentView.isEditable = isEditable
    documentView.saveURL = saveURL
    documentView.saveEncoding = saveEncoding
    documentView.onSaveCompletion = onSaveCompletion
    documentView.onDirtyChange = onDirtyChange
    documentView.onFocusChange = onFocusChange
    scrollView.documentView = documentView

    documentView.setBuffer(buffer)

    let clipView = scrollView.contentView
    // This view draws viewport-relative chrome (pinned gutter, caret, selection)
    // and rounds the visible band to whole rows, so it redraws the whole visible
    // band on each scroll (see `viewportDidScroll`) instead of letting the clip
    // view repaint only the newly exposed strip — which tore rows (content
    // appeared to jump a line) and left the gutter stale. (`copiesOnScroll` is a
    // no-op on macOS 11+, so the redraw is driven explicitly.)
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
    // Adopt the initial request value so the first `updateNSView` does not mistake
    // it for a save request.
    context.coordinator.lastSaveRequest = saveRequest

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let documentView = scrollView.documentView as? LineRenderingTextView else {
      return
    }
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    documentView.showsLineNumbers = syntax.supportsLineNumbers
    // Set before any buffer swap so the rebuilt wrap index uses the right mode.
    documentView.wrapsLines = wrapsLines
    documentView.isEditable = isEditable
    documentView.saveURL = saveURL
    documentView.saveEncoding = saveEncoding
    documentView.onSaveCompletion = onSaveCompletion
    documentView.onDirtyChange = onDirtyChange
    documentView.onFocusChange = onFocusChange
    if documentView.buffer !== buffer {
      documentView.setBuffer(buffer)
    }
    // A bumped save request (from the menu/Cmd+S command) asks the viewer to save.
    if context.coordinator.lastSaveRequest != saveRequest {
      context.coordinator.lastSaveRequest = saveRequest
      documentView.requestSave()
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class Coordinator: NSObject {
    weak var documentView: LineRenderingTextView?
    /// Last save-request value handled, so only an increment triggers a new save.
    var lastSaveRequest = 0

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
/// buffer; Cmd+S saves it (off the main thread, in the viewer).
struct VirtualizedTextDocumentView: View {
  let url: URL
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax
  /// Whether long lines soft-wrap to the viewport (prose) or scroll horizontally
  /// (structured/code/data). Decided per document by the host.
  let wrapsLines: Bool
  /// Whether the viewer accepts edits (false for read-only entries).
  let isEditable: Bool
  /// Changing this (e.g. on external file change) re-opens the buffer.
  let reloadToken: Int
  /// A monotonic counter the host bumps to request a save (e.g. from the Save menu
  /// command), since the viewer — not the host — owns the buffer and its write.
  var saveRequest: Int = 0
  /// Reports a save outcome to the host: on success the new file fingerprint
  /// (read synchronously right after the write) so the host can record it before
  /// the change monitor reacts; on failure the error to surface.
  var onSaveCompletion: (Result<DocumentFileFingerprint?, Error>) -> Void = { _ in }
  /// Reports the buffer's dirty state so the host can decide whether an external
  /// change may safely reload or conflicts with unsaved edits.
  var onDirtyChange: (Bool) -> Void = { _ in }
  /// Reports focus changes so the host can pause navigation shortcuts while the
  /// editor has the keyboard.
  var onFocusChange: (Bool) -> Void = { _ in }
  /// Holds opened buffers across file switches so unsaved edits survive navigating
  /// away and back; the view reads from and populates it instead of always opening
  /// a fresh buffer.
  let documentCache: OpenDocumentCache

  @State private var phase: Phase = .loading
  private let bufferStore = TextBufferStore()

  private enum Phase {
    case loading
    case loaded(TextBuffer, encoding: String.Encoding)
    case failed(String)
  }

  var body: some View {
    Group {
      switch phase {
      case .loading:
        Color(nsColor: .textBackgroundColor)
      case .loaded(let buffer, let encoding):
        LargeTextViewport(
          buffer: buffer,
          accessibilityLabel: accessibilityLabel,
          syntax: syntax,
          wrapsLines: wrapsLines,
          isEditable: isEditable,
          saveURL: url,
          saveEncoding: encoding,
          saveRequest: saveRequest,
          onSaveCompletion: onSaveCompletion,
          onDirtyChange: onDirtyChange,
          onFocusChange: onFocusChange
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
    let key = url.locusStandardizedPath
    // Reuse a retained buffer (with any unsaved edits) when switching back to a
    // file that is still open; otherwise open it fresh and retain it.
    if let cached = documentCache.cached(forKey: key) {
      phase = .loaded(cached.buffer, encoding: cached.encoding)
      onDirtyChange(cached.buffer.isDirty)
      return
    }
    phase = .loading
    let target = url
    let store = bufferStore
    do {
      let loaded = try await Task.detached(priority: .userInitiated) {
        let opened = try store.open(at: target)
        // Read the fingerprint alongside the open so the cache records the exact
        // disk state this buffer matches.
        let fingerprint = DocumentFileFingerprint.read(at: target)
        return OpenedTextBuffer(
          buffer: opened.buffer, encoding: opened.encoding, fingerprint: fingerprint)
      }.value
      guard !Task.isCancelled else {
        return
      }
      documentCache.store(
        buffer: loaded.buffer, encoding: loaded.encoding, fingerprint: loaded.fingerprint,
        forKey: key)
      phase = .loaded(loaded.buffer, encoding: loaded.encoding)
      onDirtyChange(loaded.buffer.isDirty)  // a freshly opened buffer is clean
    } catch {
      guard !Task.isCancelled else {
        return
      }
      phase = .failed(Self.failureMessage(for: error))
    }
  }

  /// Maps an open failure to a user-facing message. A large non-UTF-8 file is
  /// called out explicitly: legacy encodings are decoded in memory (so they are
  /// bounded), and above that bound only UTF-8 (memory-mapped) is supported, so
  /// the narrowing is not silent.
  static func failureMessage(for error: Error) -> String {
    if let storeError = error as? TextBufferStoreError, case .tooLargeForEncoding = storeError {
      return storeError.errorDescription ?? error.localizedDescription
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

/// Carries the non-`Sendable` `TextBuffer` (and its detected file encoding) from
/// the loader task to the main actor. It is only handed across once and then used
/// exclusively on the main actor, so the unchecked conformance is sound.
private struct OpenedTextBuffer: @unchecked Sendable {
  let buffer: TextBuffer
  let encoding: String.Encoding
  let fingerprint: DocumentFileFingerprint?
}

/// Carries the `TextBuffer` to the background save thread. Sound because the
/// save only *reads* the buffer (`write_to`) and the main thread pauses buffer
/// mutations (`isSaving`) for the write's duration; concurrent reads are safe
/// because the core buffer is `Sync`.
private struct SendableTextBuffer: @unchecked Sendable {
  let buffer: TextBuffer
  init(_ buffer: TextBuffer) {
    self.buffer = buffer
  }
}
