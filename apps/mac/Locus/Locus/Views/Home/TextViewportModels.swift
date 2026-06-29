import AppKit
import CoreText

// Tested in TextViewportLayoutTests.swift (viewport, selection, editing, IME, save)
// and TextWrapTests.swift (soft wrap and the background wrap build).
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

  /// Rows that stay anchored at the viewport top at maximum overscroll.
  static let overscrollAnchorRowCount = 1

  /// Document frame height for VS Code-style scroll past end: every document gets
  /// enough tail space below the final row that it can scroll until that row
  /// reaches the top of the viewport. Empty and single-row documents still collapse
  /// to the viewport-fill height because the first row is already at the top.
  func frameHeight(visualRows: Int, viewportHeight: CGFloat) -> CGFloat {
    let contentHeight = contentHeight(lineCount: visualRows)
    let tailHeight = max(0, viewportHeight - CGFloat(Self.overscrollAnchorRowCount) * lineHeight)
    return max(viewportHeight, contentHeight + tailHeight)
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

/// Per-line vertical metrics: the height each wrapped visual row occupies, plus
/// breathing insets above the first row and below the last one (heading air).
struct LineRowMetrics: Equatable {
  var rowHeight: CGFloat
  var leadingInset: CGFloat = 0
  var trailingInset: CGFloat = 0

  /// Total vertical extent of a line wrapping into `rows` visual rows.
  func totalHeight(rows: Int) -> CGFloat {
    leadingInset + CGFloat(max(1, rows)) * rowHeight + trailingInset
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
  /// Per-line vertical metrics, present only when at least one line diverges
  /// from the uniform height (slim marker rows, heading air). All wrapped rows
  /// of a line share its row height; the insets apply once per line. `nil`
  /// keeps the uniform O(1) arithmetic fast path.
  private let lineMetrics: [LineRowMetrics]?
  /// Cumulative y offsets per line (`lineCount + 1` elements); present exactly
  /// when `lineMetrics` is.
  private let lineYOffsets: [CGFloat]?

  /// Builds the index from per-logical-line visual-row counts (each clamped to at
  /// least 1, since even an empty line occupies one row). `rowMetricsPerLine`
  /// supplies custom vertical metrics per line; pass `nil` (or all-uniform
  /// metrics) for uniform documents.
  init(
    visualRowsPerLine: [Int],
    rowMetricsPerLine: [LineRowMetrics]? = nil,
    uniformRowHeight: CGFloat = 0
  ) {
    var offsets = [Int](repeating: 0, count: visualRowsPerLine.count + 1)
    for (index, rows) in visualRowsPerLine.enumerated() {
      offsets[index + 1] = offsets[index] + max(1, rows)
    }
    rowOffsets = offsets
    let uniform = LineRowMetrics(rowHeight: uniformRowHeight)
    if let metrics = rowMetricsPerLine,
      metrics.count == visualRowsPerLine.count,
      metrics.contains(where: { $0 != uniform })
    {
      var ys = [CGFloat](repeating: 0, count: metrics.count + 1)
      for (index, rows) in visualRowsPerLine.enumerated() {
        ys[index + 1] = ys[index] + metrics[index].totalHeight(rows: rows)
      }
      lineMetrics = metrics
      lineYOffsets = ys
    } else {
      lineMetrics = nil
      lineYOffsets = nil
    }
  }

  var lineCount: Int { max(0, rowOffsets.count - 1) }
  var totalVisualRows: Int { rowOffsets.last ?? 0 }
  /// Whether any line carries non-uniform vertical metrics.
  var hasCustomRowHeights: Bool { lineMetrics != nil }

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

  /// The vertical metrics of `line` under the given uniform fallback.
  func rowMetrics(ofLine line: Int, uniformRowHeight: CGFloat) -> LineRowMetrics {
    guard let metrics = lineMetrics, line >= 0, line < metrics.count else {
      return LineRowMetrics(rowHeight: uniformRowHeight)
    }
    return metrics[line]
  }

  /// The row height of `line` under the given uniform fallback.
  func rowHeight(ofLine line: Int, uniformRowHeight: CGFloat) -> CGFloat {
    rowMetrics(ofLine: line, uniformRowHeight: uniformRowHeight).rowHeight
  }

  /// The y offset of the top of `line`'s block (including its leading inset).
  func yOffset(ofLine line: Int, uniformRowHeight: CGFloat) -> CGFloat {
    guard let ys = lineYOffsets else {
      return CGFloat(firstVisualRow(ofLine: line)) * uniformRowHeight
    }
    return ys[min(max(0, line), lineCount)]
  }

  /// The y offset of the top of a global visual row (below its line's leading
  /// inset).
  func yOffset(ofVisualRow row: Int, uniformRowHeight: CGFloat) -> CGFloat {
    guard lineYOffsets != nil else { return CGFloat(row) * uniformRowHeight }
    guard lineCount > 0 else { return 0 }
    if row >= totalVisualRows {
      return totalHeight(uniformRowHeight: uniformRowHeight)
        + CGFloat(row - totalVisualRows) * uniformRowHeight
    }
    let (line, rowInLine) = location(ofVisualRow: row)
    let metrics = rowMetrics(ofLine: line, uniformRowHeight: uniformRowHeight)
    return yOffset(ofLine: line, uniformRowHeight: uniformRowHeight)
      + metrics.leadingInset + CGFloat(rowInLine) * metrics.rowHeight
  }

  /// Total document content height.
  func totalHeight(uniformRowHeight: CGFloat) -> CGFloat {
    guard let ys = lineYOffsets else { return CGFloat(totalVisualRows) * uniformRowHeight }
    return ys.last ?? 0
  }

  /// The line and row-within-line whose vertical span contains `y` (clamped to
  /// the document). A y inside a line's leading inset resolves to its first
  /// row; inside the trailing inset, to its last — padding strips are never
  /// dead zones.
  func location(forY y: CGFloat, uniformRowHeight: CGFloat) -> (line: Int, rowInLine: Int) {
    guard let ys = lineYOffsets else {
      guard uniformRowHeight > 0 else { return (0, 0) }
      return location(ofVisualRow: Int((y / uniformRowHeight).rounded(.down)))
    }
    guard lineCount > 0 else { return (0, 0) }
    let target = min(max(0, y), max(0, (ys.last ?? 0) - 0.001))
    // Largest `line` with `ys[line] <= target`.
    var low = 0
    var high = lineCount - 1
    while low < high {
      let mid = (low + high + 1) / 2
      if ys[mid] <= target {
        low = mid
      } else {
        high = mid - 1
      }
    }
    let metrics = rowMetrics(ofLine: low, uniformRowHeight: uniformRowHeight)
    guard metrics.rowHeight > 0 else { return (low, 0) }
    let withinRows = target - ys[low] - metrics.leadingInset
    let rowInLine = min(
      visualRowCount(ofLine: low) - 1,
      max(0, Int((withinRows / metrics.rowHeight).rounded(.down))))
    return (low, rowInLine)
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
  /// Core Text treats embedded `\n` as a mandatory break even when `width` is
  /// large; markdown front matter relies on that to stack a key above its value
  /// while keeping both pieces inside one logical source line. A non-positive
  /// width or an empty line yields `[0]` — a single row. Stops at `maximumRows`
  /// so the result is always bounded.
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

/// The read surface a background wrap measurement consumes. Only immutable,
/// thread-safe backends conform — a snapshot of the editable buffer or the
/// read-only large file — never the live, main-actor-bound `TextBuffer`, so the
/// chunked build can run on a detached task while the user keeps editing.
protocol WrapMeasurementReading: AnyObject {
  /// Number of logical lines captured by the source.
  var lineCount: Int { get }
  /// Total UTF-16 code units captured by the source.
  var utf16Length: Int { get }
  /// Text of lines `[start, start + count)` (clamped), joined by `\n`, each
  /// line's content truncated to at most `maxBytesPerLine` bytes.
  func text(forLineRange start: Int, count: Int, maxBytesPerLine: Int) -> String
  /// Maps a 0-based line and UTF-16 column (clamped to the line's content end)
  /// to a full position; an out-of-range line throws.
  func position(forLine line: Int, columnUTF16: Int) throws -> TextPosition
}

/// Both conformances are declaration-only: the snapshot exposes exactly this
/// surface for background reads, and the large file's `TextDocumentReading`
/// methods are already safe from any thread (read-only `&self` FFI calls).
extension TextBufferSnapshot: WrapMeasurementReading {}
extension LargeFile: WrapMeasurementReading {}

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
