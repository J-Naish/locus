import AppKit
import CoreText

struct TerminalGlyphBatch {
  let font: CTFont
  let glyphs: [CGGlyph]
  let positions: [CGPoint]
  let overflowScaleX: CGFloat?
  let overflowAnchorX: CGFloat?
}

struct TerminalShapedRun {
  let run: TerminalTextRun
  let glyphBatches: [TerminalGlyphBatch]
}

struct TerminalBackgroundFill {
  let startColumn: Int
  let cellCount: Int
  let color: NSColor
}

struct TerminalShapedRow {
  let signature: [UInt8]
  let runs: [TerminalShapedRun]
  let backgroundFills: [TerminalBackgroundFill]
  var lastUsedPaint: UInt64
}

@MainActor
final class TerminalRowShapingCache {
  private static let capacity = 240

  private let metrics: TerminalCellMetrics
  private let insets: TerminalContentInsets
  private var rowTextPool: [UInt64: [TerminalShapedRow]] = [:]
  private var paintCounter: UInt64 = 0
  private(set) var statisticsForTesting = (hits: 0, misses: 0)

  init(metrics: TerminalCellMetrics, insets: TerminalContentInsets) {
    self.metrics = metrics
    self.insets = insets
  }

  func shapedRow(
    row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>,
    graphemes: UnsafeBufferPointer<UInt32>
  ) -> TerminalShapedRow {
    let hash = TerminalRowSignature.hash(
      row: row,
      cells: cells,
      graphemes: graphemes
    )
    if var bucket = rowTextPool[hash],
      let index = bucket.firstIndex(where: {
        TerminalRowSignature.matches(
          $0.signature,
          row: row,
          cells: cells,
          graphemes: graphemes
        )
      })
    {
      bucket[index].lastUsedPaint = paintCounter
      let cached = bucket[index]
      rowTextPool[hash] = bucket
      statisticsForTesting.hits += 1
      return cached
    }

    statisticsForTesting.misses += 1
    let cached = buildShapedRow(
      row: row,
      cells: cells,
      graphemes: graphemes,
      signature: TerminalRowSignature.signature(
        row: row,
        cells: cells,
        graphemes: graphemes
      )
    )
    rowTextPool[hash, default: []].append(cached)
    return cached
  }

  private func buildShapedRow(
    row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>,
    graphemes: UnsafeBufferPointer<UInt32>,
    signature: [UInt8]
  ) -> TerminalShapedRow {
    let range = Self.cellRange(for: row, cells: cells)
    var renderableCells: [TerminalRenderableCell] = []
    renderableCells.reserveCapacity(range.count)
    for cell in cells[range] {
      guard TerminalCellWidth(rawValue: cell.wide) != .spacerTail else {
        continue
      }
      renderableCells.append(
        TerminalRenderableCell(
          text: text(for: cell, graphemes: graphemes),
          cellCount: displayCellCount(for: cell),
          style: TerminalTextStyle(cell)
        )
      )
    }
    let runs: [TerminalShapedRun] = TerminalLineRunBuilder.runs(for: renderableCells).compactMap {
      run -> TerminalShapedRun? in
      guard !run.text.isEmpty else {
        return nil
      }
      let line = CTLineCreateWithAttributedString(attributedString(for: run))
      return TerminalShapedRun(
        run: run,
        glyphBatches: buildGlyphBatches(run: run, line: line)
      )
    }
    return TerminalShapedRow(
      signature: signature,
      runs: runs,
      backgroundFills: buildBackgroundFills(cells: cells, range: range),
      lastUsedPaint: paintCounter
    )
  }

  private func buildBackgroundFills(
    cells: UnsafeBufferPointer<LocusTermCell>,
    range: Range<Int>
  ) -> [TerminalBackgroundFill] {
    var fills: [TerminalBackgroundFill] = []
    var activeStart = 0
    var activeCount = 0
    var activeColor: TerminalColor?
    var column = 0

    func flush() {
      guard let color = activeColor, activeCount > 0 else {
        return
      }
      fills.append(
        TerminalBackgroundFill(
          startColumn: activeStart,
          cellCount: activeCount,
          color: color.nsColor
        )
      )
      activeCount = 0
      activeColor = nil
    }

    for cell in cells[range] {
      guard TerminalCellWidth(rawValue: cell.wide) != .spacerTail else {
        continue
      }
      let width = displayCellCount(for: cell)
      let color = TerminalTextStyle(cell).resolvedColors.background
      if color == .defaultBackground {
        flush()
      } else if activeColor == color {
        activeCount += width
      } else {
        flush()
        activeStart = column
        activeCount = width
        activeColor = color
      }
      column += width
    }
    flush()
    return fills
  }

  private func attributedString(for run: TerminalTextRun) -> NSAttributedString {
    let colors = run.style.resolvedColors
    var foreground = nsColor(forForeground: colors.foreground)
    if run.style.flags.contains(.faint) {
      foreground = foreground.withAlphaComponent(0.55)
    }

    // TODO: blink, invisible, and overline require timing/decoration support.
    let attributes: [NSAttributedString.Key: Any] = [
      .font: metrics.font(for: run.style.flags),
      .foregroundColor: foreground,
      .ligature: 0,
    ]
    let attributed = NSMutableAttributedString(string: run.text, attributes: attributes)
    var utf16Offset = 0
    for cell in run.cells {
      let utf16Length = cell.text.utf16.count
      if cell.cellCount == 2, utf16Length > 0 {
        // wcwidth-wide cells shape with a grid-fitted Japanese font; ambiguous-width stays on
        // the base font so the R13 condense behavior is untouched.
        attributed.addAttribute(
          .font,
          value: metrics.wideFont(for: run.style.flags),
          range: NSRange(location: utf16Offset, length: utf16Length)
        )
      }
      utf16Offset += utf16Length
    }
    return attributed
  }

  private func buildGlyphBatches(
    run: TerminalTextRun,
    line: CTLine
  ) -> [TerminalGlyphBatch] {
    let gridCellsByUTF16Index = TerminalGlyphGridLayout.cellsByUTF16Index(for: run)
    let isPureASCII = run.text.utf8.allSatisfy { $0 < 0x80 }
    var batches: [TerminalGlyphBatch] = []
    for case let glyphRun as CTRun in CTLineGetGlyphRuns(line) as NSArray {
      batches.append(
        contentsOf: buildGlyphBatches(
          glyphRun,
          line: line,
          terminalRun: run,
          gridCellsByUTF16Index: gridCellsByUTF16Index,
          measureOverflow: !isPureASCII
        ))
    }
    return batches
  }

  private func buildGlyphBatches(
    _ glyphRun: CTRun,
    line: CTLine,
    terminalRun: TerminalTextRun,
    gridCellsByUTF16Index: [TerminalGlyphGridCell],
    measureOverflow: Bool
  ) -> [TerminalGlyphBatch] {
    let count = CTRunGetGlyphCount(glyphRun)
    guard count > 0 else {
      return []
    }

    var glyphs = [CGGlyph](repeating: 0, count: count)
    var naturalPositions = [CGPoint](repeating: .zero, count: count)
    var stringIndices = [CFIndex](repeating: 0, count: count)
    CTRunGetGlyphs(glyphRun, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(glyphRun, CFRange(location: 0, length: 0), &naturalPositions)
    CTRunGetStringIndices(glyphRun, CFRange(location: 0, length: 0), &stringIndices)

    var gridPositions: [CGPoint] = []
    gridPositions.reserveCapacity(count)
    for (index, naturalPosition) in zip(stringIndices, naturalPositions) {
      guard
        index != kCFNotFound,
        index >= 0,
        index < gridCellsByUTF16Index.count
      else {
        gridPositions.append(
          CGPoint(
            x: insets.left
              + CGFloat(terminalRun.startColumn) * metrics.cellWidth
              + naturalPosition.x,
            y: naturalPosition.y
          )
        )
        continue
      }
      let cell = gridCellsByUTF16Index[index]

      let naturalCellX = CGFloat(
        CTLineGetOffsetForStringIndex(line, cell.utf16Range.lowerBound, nil))
      let gridCellX =
        insets.left
        + CGFloat(terminalRun.startColumn + cell.startColumn) * metrics.cellWidth
      gridPositions.append(
        CGPoint(
          x: gridCellX + naturalPosition.x - naturalCellX,
          y: naturalPosition.y
        )
      )
    }

    let attributes = CTRunGetAttributes(glyphRun) as NSDictionary
    let runFont = attributes[kCTFontAttributeName as String] as? NSFont
    let font = (runFont ?? metrics.font(for: terminalRun.style.flags)) as CTFont
    guard measureOverflow else {
      return [
        TerminalGlyphBatch(
          font: font,
          glyphs: glyphs,
          positions: gridPositions,
          overflowScaleX: nil,
          overflowAnchorX: nil
        )
      ]
    }

    var advances = [CGSize](repeating: .zero, count: count)
    CTRunGetAdvances(glyphRun, CFRange(location: 0, length: 0), &advances)
    let groups = TerminalGlyphClusterLayout.groups(
      stringIndices: stringIndices,
      advances: advances,
      cellsByUTF16Index: gridCellsByUTF16Index
    )
    var mainGlyphIndices = groups.mainGlyphIndices
    var overflowClusters: [(TerminalGlyphCluster, CGFloat)] = []
    for cluster in groups.clusters {
      if let scale = TerminalGlyphOverflow.overflowScale(
        clusterAdvance: cluster.advance,
        cellCount: cluster.cell.cellCount,
        cellWidth: metrics.cellWidth
      ) {
        overflowClusters.append((cluster, scale))
      } else {
        mainGlyphIndices.append(contentsOf: cluster.glyphIndices)
      }
    }
    mainGlyphIndices.sort()
    var batches: [TerminalGlyphBatch] = []
    if let main = glyphBatch(
      at: mainGlyphIndices,
      from: glyphs,
      positions: gridPositions,
      font: font,
      overflowScaleX: nil,
      overflowAnchorX: nil
    ) {
      batches.append(main)
    }
    for (cluster, scale) in overflowClusters {
      let gridOriginX =
        insets.left
        + CGFloat(terminalRun.startColumn + cluster.cell.startColumn) * metrics.cellWidth
      // Clipping amputates arrowheads and circles. Condensing preserves the
      // complete fallback glyph while keeping its ink inside the wcwidth grid.
      if let overflow = glyphBatch(
        at: cluster.glyphIndices,
        from: glyphs,
        positions: gridPositions,
        font: font,
        overflowScaleX: scale,
        overflowAnchorX: gridOriginX
      ) {
        batches.append(overflow)
      }
    }
    return batches
  }

  private func glyphBatch(
    at indices: [Int],
    from glyphs: [CGGlyph],
    positions: [CGPoint],
    font: CTFont,
    overflowScaleX: CGFloat?,
    overflowAnchorX: CGFloat?
  ) -> TerminalGlyphBatch? {
    guard !indices.isEmpty else {
      return nil
    }
    return TerminalGlyphBatch(
      font: font,
      glyphs: indices.map { glyphs[$0] },
      positions: indices.map { positions[$0] },
      overflowScaleX: overflowScaleX,
      overflowAnchorX: overflowAnchorX
    )
  }

  static func cellRange(
    for row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>
  ) -> Range<Int> {
    let start = min(row.cell_start, cells.count)
    let end = min(row.cell_start + row.cell_count, cells.count)
    return start..<end
  }

  private func displayCellCount(for cell: LocusTermCell) -> Int {
    switch TerminalCellWidth(rawValue: cell.wide) {
    case .wide:
      return 2
    default:
      return 1
    }
  }

  func clear() {
    rowTextPool.removeAll(keepingCapacity: true)
    statisticsForTesting = (hits: 0, misses: 0)
  }

  func beginPaint() {
    if paintCounter == .max {
      rowTextPool.removeAll(keepingCapacity: true)
      paintCounter = 1
    } else {
      paintCounter += 1
    }
    statisticsForTesting = (hits: 0, misses: 0)
  }

  func finishPaint() {
    let count = rowTextPool.values.reduce(into: 0) { $0 += $1.count }
    guard count > Self.capacity else {
      return
    }

    for key in Array(rowTextPool.keys) {
      rowTextPool[key]?.removeAll { $0.lastUsedPaint != paintCounter }
      if rowTextPool[key]?.isEmpty == true {
        rowTextPool.removeValue(forKey: key)
      }
    }
  }

  private func text(
    for cell: LocusTermCell,
    graphemes: UnsafeBufferPointer<UInt32>
  ) -> String {
    var result = ""
    if cell.codepoint != 0, let scalar = UnicodeScalar(cell.codepoint) {
      result.unicodeScalars.append(scalar)
    } else {
      result = " "
    }

    let start = min(cell.grapheme_start, graphemes.count)
    let end = min(cell.grapheme_start + cell.grapheme_len, graphemes.count)
    if start < end {
      for codepoint in graphemes[start..<end] {
        if let scalar = UnicodeScalar(codepoint) {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result
  }

  private func nsColor(forForeground color: TerminalColor) -> NSColor {
    color == .defaultForeground ? .textColor : color.nsColor
  }
}
