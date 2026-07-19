import AppKit
import CoreText
import Metal
import QuartzCore
import XCTest

@testable import Locus

@MainActor
final class TerminalPaneViewTests: XCTestCase {
  func testTerminalPaneUsesMetalLayerByDefault() {
    XCTAssertTrue(TerminalPaneView().layer is CAMetalLayer)
  }

  func testTerminalPaneMetalLayerIsOpaqueAndFramebufferOnly() throws {
    let layer = try XCTUnwrap(TerminalPaneView().layer as? CAMetalLayer)

    XCTAssertTrue(layer.isOpaque)
    XCTAssertTrue(layer.framebufferOnly)
  }

  func testMetalLayerUsesBGRA8SRGBConfiguration() throws {
    let view = TerminalPaneView()
    let layer = try XCTUnwrap(view.layer as? CAMetalLayer)

    XCTAssertEqual(layer.pixelFormat, .bgra8Unorm)
    XCTAssertEqual(layer.colorspace?.name, CGColorSpace.sRGB)
  }

  func testMetalDrawableSizeTracksTestingScale() throws {
    let view = TerminalPaneView()
    view.metalContentsScaleForTesting = 2
    view.setFrameSize(NSSize(width: 200, height: 100))
    let layer = try XCTUnwrap(view.layer as? CAMetalLayer)
    XCTAssertEqual(layer.drawableSize, CGSize(width: 400, height: 200))

    view.metalContentsScaleForTesting = 1
    XCTAssertEqual(layer.drawableSize, CGSize(width: 200, height: 100))
  }

  func testLinkHitTesterHandlesInsideOutsideAndMultiRowLinks() {
    let matches = [
      TerminalLinkMatch(y: 2, xStart: 4, xEnd: 9, linkID: 7),
      TerminalLinkMatch(y: 3, xStart: 0, xEnd: 5, linkID: 7),
      TerminalLinkMatch(y: 5, xStart: 2, xEnd: 6, linkID: 8),
    ]

    XCTAssertEqual(
      TerminalLinkHitTester.match(
        at: TerminalCellCoordinate(column: 6, row: 2),
        in: matches
      ),
      matches[0]
    )
    XCTAssertEqual(
      TerminalLinkHitTester.match(
        at: TerminalCellCoordinate(column: 3, row: 3),
        in: matches
      ),
      matches[1]
    )
    XCTAssertNil(
      TerminalLinkHitTester.match(
        at: TerminalCellCoordinate(column: 10, row: 2),
        in: matches
      )
    )
    XCTAssertNil(
      TerminalLinkHitTester.match(
        at: TerminalCellCoordinate(column: 4, row: 4),
        in: matches
      )
    )
  }

  func testLinkUnderlineRectUsesInclusiveGridCellsAndFontBaseline() {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
    let match = TerminalLinkMatch(y: 2, xStart: 3, xEnd: 5, linkID: 7)

    let rect = TerminalPaneGeometry.linkUnderlineRect(
      match,
      bounds: bounds,
      metrics: metrics,
      insets: insets
    )
    let baselineY =
      bounds.height - insets.top - CGFloat(match.y) * metrics.cellHeight
      - metrics.baselineOffset

    XCTAssertEqual(rect.minX, insets.left + 3 * metrics.cellWidth, accuracy: 0.001)
    XCTAssertEqual(rect.width, 3 * metrics.cellWidth, accuracy: 0.001)
    XCTAssertEqual(
      rect.minY,
      baselineY + CGFloat(CTFontGetUnderlinePosition(metrics.font as CTFont)),
      accuracy: 0.001
    )
    XCTAssertGreaterThanOrEqual(rect.height, 1)
  }

  func testLinkURLValidatorAllowsOnlyHttpAndHttps() {
    XCTAssertEqual(
      TerminalLinkURLValidator.url(from: "https://example.com/path")?.absoluteString,
      "https://example.com/path"
    )
    XCTAssertEqual(
      TerminalLinkURLValidator.url(from: "HTTP://example.com")?.scheme?.lowercased(),
      "http"
    )
    XCTAssertNil(TerminalLinkURLValidator.url(from: "file:///tmp/private"))
    XCTAssertNil(TerminalLinkURLValidator.url(from: "javascript:alert(1)"))
    XCTAssertNil(TerminalLinkURLValidator.url(from: "not a url"))
  }

  func testWheelAccumulatorEmitsWholeRowsWithCarry() {
    var accumulator = TerminalWheelAccumulator()

    XCTAssertEqual(
      accumulator.ffiDeltaRows(
        scrollingDeltaY: 40,
        hasPreciseDeltas: true,
        cellHeight: 16
      ),
      -2
    )
    XCTAssertEqual(
      accumulator.ffiDeltaRows(
        scrollingDeltaY: 8,
        hasPreciseDeltas: true,
        cellHeight: 16
      ),
      -1
    )
    XCTAssertEqual(
      accumulator.ffiDeltaRows(
        scrollingDeltaY: -16,
        hasPreciseDeltas: true,
        cellHeight: 16
      ),
      1
    )
    XCTAssertEqual(
      accumulator.ffiDeltaRows(
        scrollingDeltaY: 3,
        hasPreciseDeltas: false,
        cellHeight: 16
      ),
      -3
    )
  }

  func testWheelAccumulatorClampsToFFILimit() {
    var accumulator = TerminalWheelAccumulator()

    XCTAssertEqual(
      accumulator.ffiDeltaRows(
        scrollingDeltaY: 16 * 10_000,
        hasPreciseDeltas: true,
        cellHeight: 16
      ),
      -4096
    )
  }

  func testPaintSchedulingIgnoresFrameDirtyStateByDesign() {
    // The signature intentionally has no dirty/frame parameter so a clean
    // follow-up render cannot suppress an earlier generation's repaint.
    XCTAssertFalse(
      TerminalPaneView.shouldSchedulePaint(
        generation: nil,
        lastScheduledGeneration: nil
      )
    )
    XCTAssertFalse(
      TerminalPaneView.shouldSchedulePaint(
        generation: 5,
        lastScheduledGeneration: 5
      )
    )
    XCTAssertTrue(
      TerminalPaneView.shouldSchedulePaint(
        generation: 5,
        lastScheduledGeneration: nil
      )
    )
    XCTAssertTrue(
      TerminalPaneView.shouldSchedulePaint(
        generation: 6,
        lastScheduledGeneration: 5
      )
    )
  }

  func testCellMetricsAreConsistent() {
    let metrics = TerminalCellMetrics()

    XCTAssertGreaterThan(metrics.cellWidth, 0)
    XCTAssertGreaterThan(metrics.cellHeight, 0)
    XCTAssertEqual(metrics.advance(for: "0"), metrics.advance(for: "W"), accuracy: 0.5)
  }

  func testGridSizeFromViewBounds() {
    let metrics = TerminalCellMetrics()
    let grid = TerminalCellMetrics.gridSize(
      for: CGSize(width: 400, height: 300),
      metrics: metrics
    )

    XCTAssertEqual(grid.columns, UInt16(floor(400 / metrics.cellWidth)))
    XCTAssertEqual(grid.rows, UInt16(floor(300 / metrics.cellHeight)))

    let clamped = TerminalCellMetrics.gridSize(for: .zero, metrics: metrics)
    XCTAssertEqual(clamped, TerminalGridSize(columns: 1, rows: 1))
  }

  func testGridSizeAccountsForInsets() {
    let metrics = TerminalCellMetrics()
    let size = CGSize(width: 400, height: 300)
    let insets = TerminalPaneLayoutMetrics.contentInsets

    let grid = TerminalCellMetrics.gridSize(
      for: size,
      metrics: metrics,
      insets: insets
    )

    XCTAssertEqual(
      grid.columns,
      UInt16(floor((size.width - insets.left - insets.right) / metrics.cellWidth))
    )
    XCTAssertEqual(
      grid.rows,
      UInt16(floor((size.height - insets.top - insets.bottom) / metrics.cellHeight))
    )
  }

  func testInsetsAppliedSymmetrically() {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    let size = CGSize(
      width: insets.left + metrics.cellWidth * 40 + insets.right,
      height: insets.top + metrics.cellHeight * 10 + insets.bottom
    )

    XCTAssertEqual(insets, TerminalContentInsets(top: 10, left: 12, bottom: 10, right: 12))
    XCTAssertEqual(insets.left, insets.right)
    XCTAssertEqual(insets.top, insets.bottom)
    XCTAssertEqual(
      TerminalCellMetrics.gridSize(for: size, metrics: metrics, insets: insets),
      TerminalGridSize(columns: 40, rows: 10)
    )
  }

  func testStyleRunGroupingBuildsAttributedLine() {
    let normal = TerminalTextStyle(
      foreground: .defaultForeground,
      background: .defaultBackground,
      flags: []
    )
    let bold = TerminalTextStyle(
      foreground: .defaultForeground,
      background: .defaultBackground,
      flags: [.bold]
    )

    let runs = TerminalLineRunBuilder.runs(
      for: [
        TerminalRenderableCell(text: "a", cellCount: 1, style: normal),
        TerminalRenderableCell(text: "b", cellCount: 1, style: bold),
        TerminalRenderableCell(text: "c", cellCount: 1, style: bold),
        TerminalRenderableCell(text: "d", cellCount: 1, style: normal),
      ]
    )

    XCTAssertEqual(runs.map(\.cellCount), [1, 2, 1])
    XCTAssertEqual(runs.map(\.text), ["a", "bc", "d"])
  }

  func testGlyphPositionsAreGridAligned() throws {
    let metrics = TerminalCellMetrics()
    let style = TerminalTextStyle(
      foreground: .defaultForeground,
      background: .defaultBackground,
      flags: []
    )
    let run = try XCTUnwrap(
      TerminalLineRunBuilder.runs(
        for: [
          TerminalRenderableCell(text: "a", cellCount: 1, style: style),
          TerminalRenderableCell(text: "b", cellCount: 1, style: style),
          TerminalRenderableCell(text: "c", cellCount: 1, style: style),
        ]
      ).first
    )

    let positions = TerminalGlyphGridLayout.cellXPositions(
      for: run,
      cellWidth: metrics.cellWidth,
      leftInset: TerminalPaneLayoutMetrics.contentInsets.left
    )

    XCTAssertEqual(
      positions,
      [
        TerminalPaneLayoutMetrics.contentInsets.left,
        TerminalPaneLayoutMetrics.contentInsets.left + metrics.cellWidth,
        TerminalPaneLayoutMetrics.contentInsets.left + metrics.cellWidth * 2,
      ]
    )
  }

  func testGlyphGridCellsPreserveCellCounts() throws {
    let style = TerminalTextStyle(
      foreground: .defaultForeground,
      background: .defaultBackground,
      flags: []
    )
    let run = try XCTUnwrap(
      TerminalLineRunBuilder.runs(
        for: [
          TerminalRenderableCell(text: "A", cellCount: 1, style: style),
          TerminalRenderableCell(text: "界", cellCount: 2, style: style),
          TerminalRenderableCell(text: "→", cellCount: 1, style: style),
          TerminalRenderableCell(text: "e\u{301}", cellCount: 1, style: style),
        ]
      ).first
    )

    let cells = TerminalGlyphGridLayout.cells(for: run)

    XCTAssertEqual(cells.map(\.startColumn), [0, 1, 3, 4])
    XCTAssertEqual(cells.map(\.cellCount), [1, 2, 1, 1])
    XCTAssertEqual(cells.map(\.utf16Range), [0..<1, 1..<2, 2..<3, 3..<5])
  }

  func testGlyphOverflowScaleUsesCellBudget() throws {
    let cellWidth: CGFloat = 9
    let slack = TerminalGlyphOverflow.advanceSlack

    XCTAssertNil(
      TerminalGlyphOverflow.overflowScale(
        clusterAdvance: cellWidth,
        cellCount: 1,
        cellWidth: cellWidth
      )
    )
    XCTAssertNil(
      TerminalGlyphOverflow.overflowScale(
        clusterAdvance: cellWidth + slack,
        cellCount: 1,
        cellWidth: cellWidth
      )
    )
    XCTAssertEqual(
      try XCTUnwrap(
        TerminalGlyphOverflow.overflowScale(
          clusterAdvance: cellWidth + slack + 0.1,
          cellCount: 1,
          cellWidth: cellWidth
        )
      ),
      cellWidth / (cellWidth + slack + 0.1),
      accuracy: 0.0001
    )
    XCTAssertNil(
      TerminalGlyphOverflow.overflowScale(
        clusterAdvance: cellWidth * 2 + slack,
        cellCount: 2,
        cellWidth: cellWidth
      )
    )
    let doubleCellScale = try XCTUnwrap(
      TerminalGlyphOverflow.overflowScale(
        clusterAdvance: cellWidth * 2 + slack + 0.1,
        cellCount: 2,
        cellWidth: cellWidth
      )
    )
    XCTAssertEqual(doubleCellScale, cellWidth * 2 / (cellWidth * 2 + slack + 0.1), accuracy: 0.0001)
    XCTAssertLessThanOrEqual(doubleCellScale, 1)
    XCTAssertNil(
      TerminalGlyphOverflow.overflowScale(
        clusterAdvance: 0,
        cellCount: 1,
        cellWidth: cellWidth
      )
    )
    XCTAssertNil(
      TerminalGlyphOverflow.overflowScale(
        clusterAdvance: cellWidth,
        cellCount: 0,
        cellWidth: cellWidth
      )
    )
  }

  func testGlyphClustersGroupByGridCellIdentity() throws {
    let first = TerminalGlyphGridCell(utf16Range: 0..<2, startColumn: 0, cellCount: 1)
    let second = TerminalGlyphGridCell(utf16Range: 2..<3, startColumn: 1, cellCount: 1)

    let groups = TerminalGlyphClusterLayout.groups(
      stringIndices: [2, 0, 1, kCFNotFound, 99],
      advances: [
        CGSize(width: 4, height: 0),
        CGSize(width: 3, height: 0),
        CGSize(width: 2, height: 0),
        CGSize(width: 7, height: 0),
        CGSize(width: 8, height: 0),
      ],
      cellsByUTF16Index: [first, first, second]
    )

    XCTAssertEqual(groups.mainGlyphIndices, [3, 4])
    let firstCluster = try XCTUnwrap(groups.clusters.first { $0.cell.startColumn == 0 })
    XCTAssertEqual(firstCluster.glyphIndices, [1, 2])
    XCTAssertEqual(firstCluster.advance, 5)
    let secondCluster = try XCTUnwrap(groups.clusters.first { $0.cell.startColumn == 1 })
    XCTAssertEqual(secondCluster.glyphIndices, [0])
    XCTAssertEqual(secondCluster.advance, 4)
  }

  func testCoreTextGlyphOverflowMeasurementStaysWithinFitRange() throws {
    let metrics = TerminalCellMetrics()
    let style = TerminalTextStyle(
      foreground: .defaultForeground,
      background: .defaultBackground,
      flags: []
    )
    let run = try XCTUnwrap(
      TerminalLineRunBuilder.runs(
        for: [
          TerminalRenderableCell(text: "結", cellCount: 2, style: style),
          TerminalRenderableCell(text: "果", cellCount: 2, style: style),
          TerminalRenderableCell(text: "→", cellCount: 1, style: style),
          TerminalRenderableCell(text: "次", cellCount: 2, style: style),
        ]
      ).first
    )
    let attributed = NSAttributedString(
      string: run.text,
      attributes: [.font: metrics.font, .ligature: 0]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let cellsByUTF16Index = TerminalGlyphGridLayout.cellsByUTF16Index(for: run)
    var measuredScales: [CGFloat] = []
    var arrowScale: CGFloat?

    for case let glyphRun as CTRun in CTLineGetGlyphRuns(line) as NSArray {
      let count = CTRunGetGlyphCount(glyphRun)
      var stringIndices = [CFIndex](repeating: 0, count: count)
      var advances = [CGSize](repeating: .zero, count: count)
      CTRunGetStringIndices(glyphRun, CFRange(location: 0, length: 0), &stringIndices)
      CTRunGetAdvances(glyphRun, CFRange(location: 0, length: 0), &advances)
      let groups = TerminalGlyphClusterLayout.groups(
        stringIndices: stringIndices,
        advances: advances,
        cellsByUTF16Index: cellsByUTF16Index
      )
      for cluster in groups.clusters {
        let gridOrigin =
          TerminalPaneLayoutMetrics.contentInsets.left
          + CGFloat(cluster.cell.startColumn) * metrics.cellWidth
        XCTAssertEqual(
          (gridOrigin - TerminalPaneLayoutMetrics.contentInsets.left) / metrics.cellWidth,
          CGFloat(cluster.cell.startColumn),
          accuracy: 0.0001
        )
        guard
          let scale = TerminalGlyphOverflow.overflowScale(
            clusterAdvance: cluster.advance,
            cellCount: cluster.cell.cellCount,
            cellWidth: metrics.cellWidth
          )
        else {
          continue
        }
        measuredScales.append(scale)
        if cluster.cell.startColumn == 4 {
          arrowScale = scale
        }
      }
    }

    XCTAssertTrue(measuredScales.allSatisfy { (0.5...1).contains($0) })
    if let arrowScale {
      XCTAssertTrue((0.5...1).contains(arrowScale))
    }
  }

  func testWideRegularFontUsesGridFittedHiraginoSans() {
    let metrics = TerminalCellMetrics()
    let font = metrics.wideFont(for: [])

    XCTAssertEqual(font.familyName, "Hiragino Sans")
    XCTAssertEqual(font.fontName, "HiraginoSans-W4")
    XCTAssertEqual(
      font.pointSize,
      TerminalCellMetrics.defaultWideGlyphFillRatio * 2 * metrics.cellWidth,
      accuracy: 0.001
    )
  }

  func testWideBoldFontUsesGridFittedHiraginoSansW6() {
    let metrics = TerminalCellMetrics()
    let font = metrics.wideFont(for: [.bold])

    XCTAssertEqual(font.familyName, "Hiragino Sans")
    XCTAssertEqual(font.fontName, "HiraginoSans-W6")
    XCTAssertEqual(
      font.pointSize,
      TerminalCellMetrics.defaultWideGlyphFillRatio * 2 * metrics.cellWidth,
      accuracy: 0.001
    )
  }

  func testWideCellShapesWithWideFontWhileNarrowCellsKeepBaseFont() {
    let metrics = TerminalCellMetrics()
    let shaped = terminalShapedRow(
      cells: [
        terminalShapingCell(codepoint: 0x61, width: .narrow),
        terminalShapingCell(codepoint: 0x6F22, width: .wide),
        terminalShapingCell(codepoint: 0, width: .spacerTail),
        terminalShapingCell(codepoint: 0x62, width: .narrow),
      ],
      metrics: metrics
    )
    let batchFonts = shaped.runs.flatMap(\.glyphBatches).map(\.font)

    XCTAssertTrue(
      batchFonts.contains {
        CTFontCopyPostScriptName($0) as String == "HiraginoSans-W4"
          && abs(CTFontGetSize($0) - metrics.wideFont(for: []).pointSize) < 0.001
      }
    )
    XCTAssertTrue(
      batchFonts.contains {
        CTFontCopyPostScriptName($0) as String == metrics.font.fontName
      }
    )
  }

  func testAmbiguousWidthCellDoesNotUseWideFont() {
    let metrics = TerminalCellMetrics()
    let shaped = terminalShapedRow(
      cells: [terminalShapingCell(codepoint: 0x2460, width: .narrow)],
      metrics: metrics
    )

    XCTAssertFalse(
      shaped.runs.flatMap(\.glyphBatches).contains {
        CTFontCopyPostScriptName($0.font) as String == "HiraginoSans-W4"
      }
    )
  }

  func testGridFittedWideKanjiDoesNotRequireCondensing() throws {
    let metrics = TerminalCellMetrics()
    let font = metrics.wideFont(for: []) as CTFont
    var character = UniChar(0x6F22)
    var glyph = CGGlyph()
    XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)

    XCTAssertNil(
      TerminalGlyphOverflow.overflowScale(
        clusterAdvance: advance.width,
        cellCount: 2,
        cellWidth: metrics.cellWidth
      )
    )
  }

  func testCursorRectMatchesColumnPosition() {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    let cursor = LocusTermCursor(
      x: 30,
      y: 2,
      visible: true,
      blinking: false,
      wide_tail: false,
      style: 1
    )

    let rect = TerminalPaneGeometry.cursorCellRect(
      cursor: cursor,
      bounds: NSRect(x: 0, y: 0, width: 800, height: 400),
      metrics: metrics,
      insets: insets
    )

    XCTAssertEqual(rect.minX, insets.left + 30 * metrics.cellWidth)
  }

  func testCursorBarRectAtColumn() {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    let cursor = LocusTermCursor(
      x: 7,
      y: 2,
      visible: true,
      blinking: false,
      wide_tail: false,
      style: 1
    )

    let rect = TerminalPaneGeometry.cursorBarRect(
      cursor: cursor,
      bounds: NSRect(x: 0, y: 0, width: 800, height: 400),
      metrics: metrics,
      insets: insets
    )

    XCTAssertEqual(rect.minX, insets.left + 7 * metrics.cellWidth)
    XCTAssertEqual(rect.width, 2)
    XCTAssertEqual(rect.height, metrics.cellHeight)
  }

  func testCellCoordinateFromPoint() {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    let grid = TerminalGridSize(columns: 10, rows: 5)

    XCTAssertEqual(
      TerminalPaneGeometry.cellCoordinate(
        for: NSPoint(
          x: insets.left + metrics.cellWidth * 2.5,
          y: insets.top + metrics.cellHeight * 1.5
        ),
        metrics: metrics,
        insets: insets,
        grid: grid
      ),
      TerminalCellCoordinate(column: 2, row: 1)
    )
    XCTAssertEqual(
      TerminalPaneGeometry.cellCoordinate(
        for: NSPoint(x: -100, y: -100),
        metrics: metrics,
        insets: insets,
        grid: grid
      ),
      TerminalCellCoordinate(column: 0, row: 0)
    )
    XCTAssertEqual(
      TerminalPaneGeometry.cellCoordinate(
        for: NSPoint(x: 10_000, y: 10_000),
        metrics: metrics,
        insets: insets,
        grid: grid
      ),
      TerminalCellCoordinate(column: 9, row: 4)
    )
  }

  func testCellHitFractionAtCellCentersAndEdges() {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    let grid = TerminalGridSize(columns: 4, rows: 3)

    let center = TerminalPaneGeometry.cellHit(
      for: NSPoint(
        x: insets.left + metrics.cellWidth * 1.5,
        y: insets.top + metrics.cellHeight * 0.5
      ),
      metrics: metrics,
      insets: insets,
      grid: grid
    )
    XCTAssertEqual(center.coordinate, TerminalCellCoordinate(column: 1, row: 0))
    XCTAssertEqual(center.fractionX, 0.5, accuracy: 0.001)

    let leftEdge = TerminalPaneGeometry.cellHit(
      for: NSPoint(x: insets.left + metrics.cellWidth, y: insets.top),
      metrics: metrics,
      insets: insets,
      grid: grid
    )
    XCTAssertEqual(leftEdge.coordinate.column, 1)
    XCTAssertEqual(leftEdge.fractionX, 0, accuracy: 0.001)

    let beyondRight = TerminalPaneGeometry.cellHit(
      for: NSPoint(x: insets.left + metrics.cellWidth * 8, y: insets.top),
      metrics: metrics,
      insets: insets,
      grid: grid
    )
    XCTAssertEqual(beyondRight.coordinate.column, 3)
    XCTAssertEqual(beyondRight.fractionX, 1, accuracy: 0.001)

    let beforeLeft = TerminalPaneGeometry.cellHit(
      for: NSPoint(x: 0, y: insets.top),
      metrics: metrics,
      insets: insets,
      grid: grid
    )
    XCTAssertEqual(beforeLeft.coordinate.column, 0)
    XCTAssertEqual(beforeLeft.fractionX, 0, accuracy: 0.001)
  }

  func testAutoscrollDirectionAtVerticalEdges() {
    XCTAssertEqual(TerminalPaneGeometry.autoscrollDirection(forY: -5, height: 200), -1)
    XCTAssertEqual(TerminalPaneGeometry.autoscrollDirection(forY: 205, height: 200), 1)
    XCTAssertNil(TerminalPaneGeometry.autoscrollDirection(forY: 100, height: 200))
  }

  func testSelectionRectSpansInclusiveColumns() {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

    let rect = TerminalPaneGeometry.selectionRect(
      columns: 3...5,
      row: 2,
      bounds: bounds,
      metrics: metrics,
      insets: insets
    )

    XCTAssertEqual(rect.minX, insets.left + 3 * metrics.cellWidth, accuracy: 0.001)
    XCTAssertEqual(rect.width, 3 * metrics.cellWidth, accuracy: 0.001)
    XCTAssertEqual(
      rect.minY,
      TerminalPaneGeometry.rowRectY(2, bounds: bounds, metrics: metrics, insets: insets),
      accuracy: 0.001
    )
  }

  func testSearchMatchRectsUseInclusiveCells() {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)
    let match = TerminalSearchMatch(y: 2, xStart: 3, xEnd: 5, isSelected: false)

    let rect = TerminalPaneGeometry.searchMatchRect(
      match,
      bounds: bounds,
      metrics: metrics,
      insets: insets
    )

    XCTAssertEqual(
      rect,
      TerminalPaneGeometry.selectionRect(
        columns: 3...5,
        row: 2,
        bounds: bounds,
        metrics: metrics,
        insets: insets
      )
    )
  }

  func testCaretMoveEventsRightAndLeft() {
    let rightEvents = TerminalCaretMovement.events(
      fromColumn: 5,
      fromIsWideTail: false,
      toColumn: 9,
      rowWideCodes: Array(repeating: 0, count: 10)
    )
    let leftEvents = TerminalCaretMovement.events(
      fromColumn: 9,
      fromIsWideTail: false,
      toColumn: 5,
      rowWideCodes: Array(repeating: 0, count: 10)
    )
    let unchangedEvents = TerminalCaretMovement.events(
      fromColumn: 5,
      fromIsWideTail: false,
      toColumn: 5,
      rowWideCodes: Array(repeating: 0, count: 10)
    )

    XCTAssertEqual(rightEvents.count, 4)
    XCTAssertTrue(rightEvents.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_RIGHT })
    XCTAssertEqual(leftEvents.count, 4)
    XCTAssertTrue(leftEvents.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_LEFT })
    XCTAssertTrue(unchangedEvents.isEmpty)
  }

  func testCaretMovementPreservesAllNarrowCellDelta() {
    let events = TerminalCaretMovement.events(
      fromColumn: 9,
      fromIsWideTail: false,
      toColumn: 0,
      rowWideCodes: Array(repeating: 0, count: 10)
    )

    XCTAssertEqual(events.count, 9)
    XCTAssertTrue(events.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_LEFT })
  }

  func testCaretMovementCountsWideCharactersWhenMovingLeft() {
    let events = TerminalCaretMovement.events(
      fromColumn: 9,
      fromIsWideTail: false,
      toColumn: 0,
      rowWideCodes: [1, 3, 1, 3, 1, 3, 0, 0, 0]
    )

    XCTAssertEqual(events.count, 6)
    XCTAssertTrue(events.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_LEFT })
  }

  func testCaretMovementCountsWideCharactersWhenMovingRight() {
    let events = TerminalCaretMovement.events(
      fromColumn: 0,
      fromIsWideTail: false,
      toColumn: 6,
      rowWideCodes: [1, 3, 1, 3, 1, 3, 0, 0, 0]
    )

    XCTAssertEqual(events.count, 3)
    XCTAssertTrue(events.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_RIGHT })
  }

  func testCaretMovementTreatsWideHeadAndTailClicksAsCharacterBoundaries() {
    let wideCodes: [UInt8] = [1, 3, 1, 3, 1, 3, 0, 0, 0]
    let headEvents = TerminalCaretMovement.events(
      fromColumn: 0,
      fromIsWideTail: false,
      toColumn: 4,
      rowWideCodes: wideCodes
    )
    let tailEvents = TerminalCaretMovement.events(
      fromColumn: 0,
      fromIsWideTail: false,
      toColumn: 5,
      rowWideCodes: wideCodes
    )

    XCTAssertEqual(headEvents.count, 2)
    XCTAssertEqual(tailEvents.count, 3)
    XCTAssertTrue(headEvents.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_RIGHT })
    XCTAssertTrue(tailEvents.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_RIGHT })
  }

  func testCaretMovementNormalizesCursorFromWideTailToHead() {
    let wideCodes: [UInt8] = [1, 3, 1, 3, 1, 3, 0, 0, 0]
    let fromTail = TerminalCaretMovement.events(
      fromColumn: 5,
      fromIsWideTail: true,
      toColumn: 0,
      rowWideCodes: wideCodes
    )
    let fromHead = TerminalCaretMovement.events(
      fromColumn: 4,
      fromIsWideTail: false,
      toColumn: 0,
      rowWideCodes: wideCodes
    )

    XCTAssertEqual(fromTail, fromHead)
    XCTAssertEqual(fromTail.count, 2)
  }

  func testCaretMovementSkipsSpacerHeadAtLineEnd() {
    let events = TerminalCaretMovement.events(
      fromColumn: 0,
      fromIsWideTail: false,
      toColumn: 2,
      rowWideCodes: [0, 2]
    )

    XCTAssertEqual(events.count, 1)
    XCTAssertTrue(events.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_RIGHT })
  }

  func testWideCellNormalizerMapsTailToHead() {
    let wideCodes: [UInt8] = [1, 3, 1, 3]

    XCTAssertEqual(TerminalWideCellNormalizer.headColumn(for: 1, rowWideCodes: wideCodes), 0)
    XCTAssertEqual(TerminalWideCellNormalizer.headColumn(for: 3, rowWideCodes: wideCodes), 2)
  }

  func testWideCellNormalizerLeavesHeadAndNarrowUnchanged() {
    XCTAssertEqual(
      TerminalWideCellNormalizer.headColumn(for: 0, rowWideCodes: [1, 3]),
      0
    )
    XCTAssertEqual(
      TerminalWideCellNormalizer.headColumn(for: 1, rowWideCodes: [0, 0]),
      1
    )
  }

  func testWideCellNormalizerHandlesOutOfBoundsAndMalformedRows() {
    XCTAssertEqual(
      TerminalWideCellNormalizer.headColumn(for: 7, rowWideCodes: [1, 3, 1, 3]),
      7
    )
    XCTAssertEqual(TerminalWideCellNormalizer.headColumn(for: 4, rowWideCodes: []), 4)
    XCTAssertEqual(TerminalWideCellNormalizer.headColumn(for: 0, rowWideCodes: [3]), 0)
  }

  func testCaretClickOnJapaneseInputEmitsOneArrowPerCharacter() {
    let session = TerminalSession(columns: 40, rows: 10)
    var received: [TerminalKeyEvent] = []
    let view = TerminalPaneView(
      session: session,
      keyEventObserver: { received.append($0) }
    )
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    session.send(Data("printf '\\033[2J\\033[H日本語abc'; sleep 5\n".utf8))

    var cursor: TerminalCellCoordinate?
    XCTAssertTrue(
      waitForPaneCondition {
        session.withFrame { frame in
          guard frame.cursor.x == 9 else {
            return
          }
          cursor = TerminalCellCoordinate(column: frame.cursor.x, row: frame.cursor.y)
        }
        return cursor != nil
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    guard let cursor else {
      return
    }

    view.moveCaretForTesting(to: TerminalCellCoordinate(column: 0, row: cursor.row))

    XCTAssertEqual(received.count, 6)
    XCTAssertTrue(received.allSatisfy { $0.key == LOCUS_TERM_KEY_ARROW_LEFT })
  }

  func testDoubleClickWideTailSelectsWholeGlyph() throws {
    let fixture = try makeMetalPaneFixture(text: "日本語", hosted: true)
    defer { fixture.session.terminate() }

    try terminalDoubleClick(
      view: fixture.view,
      column: 1,
      row: fixture.contentRow
    )

    XCTAssertTrue(
      waitForPaneCondition {
        var range: ClosedRange<UInt16>?
        fixture.session.withFrame { frame in
          range = frame.selectionRange(forRow: Int(fixture.contentRow))
        }
        return range == 0...1 && fixture.session.selectionText() == "日"
      },
      "Selection was \(fixture.session.selectionText())"
    )
  }

  func testDoubleClickWideHeadStillSelectsWholeGlyph() throws {
    let fixture = try makeMetalPaneFixture(text: "日本語", hosted: true)
    defer { fixture.session.terminate() }

    try terminalDoubleClick(
      view: fixture.view,
      column: 0,
      row: fixture.contentRow
    )

    XCTAssertTrue(
      waitForPaneCondition {
        var range: ClosedRange<UInt16>?
        fixture.session.withFrame { frame in
          range = frame.selectionRange(forRow: Int(fixture.contentRow))
        }
        return range == 0...1 && fixture.session.selectionText() == "日"
      },
      "Selection was \(fixture.session.selectionText())"
    )
  }

  func testCaretBlinkVisibilityResetsAndAlternates() {
    XCTAssertTrue(TerminalCaretBlink.caretVisible(at: 10, lastInput: 10, blinking: true))
    XCTAssertFalse(TerminalCaretBlink.caretVisible(at: 10.7, lastInput: 10, blinking: true))
    XCTAssertTrue(TerminalCaretBlink.caretVisible(at: 10.7, lastInput: 10, blinking: false))
  }

  func testDefaultCaretBlinksWhenFrameFlagFalse() {
    // DEC mode 12 defaults to false and shells never touch it; the app-level
    // default must keep a focused caret blinking regardless.
    XCTAssertTrue(TerminalCaretBlink.effectiveBlinking(false))
    XCTAssertTrue(TerminalCaretBlink.effectiveBlinking(true))
    let blinking = TerminalCaretBlink.effectiveBlinking(false)
    XCTAssertTrue(TerminalCaretBlink.caretVisible(at: 10, lastInput: 10, blinking: blinking))
    XCTAssertFalse(TerminalCaretBlink.caretVisible(at: 10.7, lastInput: 10, blinking: blinking))
  }

  func testBlinkInvalidationTriggersOnPhaseFlip() {
    XCTAssertTrue(
      TerminalCaretInvalidation.shouldInvalidate(
        previousDrawnVisible: true,
        currentVisible: false,
        focused: true,
        blinking: true
      )
    )
    XCTAssertFalse(
      TerminalCaretInvalidation.shouldInvalidate(
        previousDrawnVisible: true,
        currentVisible: false,
        focused: false,
        blinking: true
      )
    )
    XCTAssertFalse(
      TerminalCaretInvalidation.shouldInvalidate(
        previousDrawnVisible: true,
        currentVisible: false,
        focused: true,
        blinking: false
      )
    )
  }

  func testBlinkInvalidationRectCoversOldAndNewCaret() throws {
    let oldRect = NSRect(x: 10, y: 20, width: 2, height: 16)
    let newRect = NSRect(x: 42, y: 36, width: 2, height: 16)

    let invalidation = try XCTUnwrap(
      TerminalCaretInvalidation.invalidationRect(previous: oldRect, current: newRect)
    )

    XCTAssertEqual(invalidation, oldRect.union(newRect))
  }

  func testLastInputNotResetByOutput() {
    var resetCount = 0
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }
    let view = TerminalPaneView(
      session: session,
      caretResetObserver: { resetCount += 1 }
    )

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForPaneCondition { session.snapshot != nil })
    session.send(Data("printf OUTPUT-ONLY\\n".utf8))
    XCTAssertTrue(
      waitForPaneCondition {
        session.plainTextForTesting()?.contains("OUTPUT-ONLY") == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )

    XCTAssertEqual(resetCount, 0)
    withExtendedLifetime(view) {}
  }

  func testResolveCaretClickAcceptsCursorRow() {
    XCTAssertEqual(
      TerminalCaretClickResolver.resolveCaretClick(
        row: 2,
        column: 9,
        cursorRow: 2,
        frameRows: [false, false, false, true]
      ),
      9
    )
  }

  func testResolveCaretClickAcceptsAdjacentRows() {
    let rows = [false, false, false, false, true]

    XCTAssertEqual(
      TerminalCaretClickResolver.resolveCaretClick(
        row: 1,
        column: 7,
        cursorRow: 2,
        frameRows: rows
      ),
      7
    )
    XCTAssertEqual(
      TerminalCaretClickResolver.resolveCaretClick(
        row: 3,
        column: 8,
        cursorRow: 2,
        frameRows: rows
      ),
      8
    )
  }

  func testResolveCaretClickAcceptsTrailingBlankRows() {
    XCTAssertEqual(
      TerminalCaretClickResolver.resolveCaretClick(
        row: 4,
        column: 11,
        cursorRow: 2,
        frameRows: [false, false, false, false, true, true, true]
      ),
      11
    )
  }

  func testResolveCaretClickRejectsDistantContentRow() {
    XCTAssertNil(
      TerminalCaretClickResolver.resolveCaretClick(
        row: 1,
        column: 6,
        cursorRow: 3,
        frameRows: [false, false, false, false, true]
      )
    )
  }

  func testInverseSwapsColors() {
    let style = TerminalTextStyle(
      foreground: TerminalColor(red: 1, green: 2, blue: 3),
      background: TerminalColor(red: 4, green: 5, blue: 6),
      flags: [.inverse]
    )

    XCTAssertEqual(
      style.resolvedColors,
      TerminalResolvedColors(
        foreground: TerminalColor(red: 4, green: 5, blue: 6),
        background: TerminalColor(red: 1, green: 2, blue: 3)
      )
    )
  }

  func testMetalSceneIncludesSelectionAndUpdatesMenuValidation() throws {
    let fixture = try makeMetalPaneFixture(text: "selection-value")
    defer { fixture.session.terminate() }
    fixture.session.selectionGesture(
      .press,
      column: 0,
      row: fixture.contentRow,
      cellFractionX: 0.5,
      rectangle: false
    )
    fixture.session.selectionGesture(
      .drag,
      column: 8,
      row: fixture.contentRow,
      cellFractionX: 0.9,
      rectangle: false
    )
    fixture.session.selectionGesture(
      .release,
      column: 8,
      row: fixture.contentRow,
      cellFractionX: 0.9,
      rectangle: false
    )
    XCTAssertTrue(waitForPaneCondition { !fixture.session.selectionText().isEmpty })

    let scene = try XCTUnwrap(fixture.view.buildMetalSceneForTesting())

    XCTAssertEqual(scene.selectionRects.count, 1)
    XCTAssertTrue(fixture.view.hasRenderedSelectionForTesting)
  }

  func testMetalSceneIncludesSelectedAndUnselectedSearchMatches() throws {
    let fixture = try makeMetalPaneFixture(text: "needle needle")
    defer { fixture.session.terminate() }
    fixture.session.searchStart("needle")
    XCTAssertTrue(
      waitForPaneCondition {
        (fixture.session.snapshot?.search?.viewportMatches.count ?? 0) >= 2
      }
    )
    fixture.session.searchSelect(.next)
    XCTAssertTrue(
      waitForPaneCondition {
        fixture.session.snapshot?.search?.viewportMatches.contains(where: \.isSelected) == true
      }
    )

    let scene = try XCTUnwrap(fixture.view.buildMetalSceneForTesting())
    let alphas = scene.searchRects.map { $0.color.w }

    XCTAssertEqual(scene.searchRects.count, 2)
    XCTAssertTrue(alphas.contains { $0 > 0.35 })
    XCTAssertTrue(alphas.contains { abs($0 - 0.35) < 0.001 })
  }

  func testMetalSceneUsesMarkedTextInsteadOfRegularCaret() throws {
    let fixture = try makeMetalPaneFixture(text: "ime")
    defer { fixture.session.terminate() }
    fixture.view.setMarkedText(
      "日本",
      selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )

    let scene = try XCTUnwrap(fixture.view.buildMetalSceneForTesting())

    XCTAssertNil(scene.caretRect)
    XCTAssertEqual(scene.markedText?.attributedString.string, "日本")
    XCTAssertNotNil(scene.markedText?.underlineRect)
    XCTAssertNotNil(scene.markedText?.caretRect)
  }

  func testMetalBlinkTransitionRequestsRender() throws {
    let fixture = try makeMetalPaneFixture(text: "blink", hosted: true)
    defer { fixture.session.terminate() }
    fixture.view.hasActiveKeyboardFocusForTesting = true
    fixture.view.renderMetalFrame()
    let rendersBeforeBlink = fixture.view.metalRendersForTesting

    fixture.view.invalidateCaretForBlinkForTesting(
      at: CACurrentMediaTime() + TerminalCaretBlink.phaseDuration + 0.1
    )

    XCTAssertGreaterThan(fixture.view.metalRendersForTesting, rendersBeforeBlink)
  }

  func testMetalProductionPathRendersIntoLayerDrawable() throws {
    let fixture = try makeMetalPaneFixture(text: "live-metal", hosted: true)
    defer { fixture.session.terminate() }

    fixture.view.renderMetalFrame()

    XCTAssertEqual(fixture.view.lastMetalRenderSucceededForTesting, true)
    XCTAssertGreaterThan(fixture.view.metalRendersForTesting, 0)
  }

  func testRowSignatureChangesWithContentAndStyle() {
    let row = LocusTermRow(
      y: 0,
      cell_start: 0,
      cell_count: 1,
      dirty: false,
      wrapped: false,
      sel_start: .max,
      sel_end: .max
    )
    let base = terminalTestCell(codepoint: 0x41, foregroundRed: 1, graphemeLength: 1)
    let changedCodepoint = terminalTestCell(
      codepoint: 0x42,
      foregroundRed: 1,
      graphemeLength: 1
    )
    let changedForeground = terminalTestCell(
      codepoint: 0x41,
      foregroundRed: 2,
      graphemeLength: 1
    )
    let baseGraphemes: [UInt32] = [0x301]
    let changedGraphemes: [UInt32] = [0x302]

    let signature = [base].withUnsafeBufferPointer { cells in
      baseGraphemes.withUnsafeBufferPointer { graphemes in
        TerminalRowSignature.signature(row: row, cells: cells, graphemes: graphemes)
      }
    }
    let equalSignature = [base].withUnsafeBufferPointer { cells in
      baseGraphemes.withUnsafeBufferPointer { graphemes in
        TerminalRowSignature.signature(row: row, cells: cells, graphemes: graphemes)
      }
    }
    let codepointSignature = [changedCodepoint].withUnsafeBufferPointer { cells in
      baseGraphemes.withUnsafeBufferPointer { graphemes in
        TerminalRowSignature.signature(row: row, cells: cells, graphemes: graphemes)
      }
    }
    let foregroundSignature = [changedForeground].withUnsafeBufferPointer { cells in
      baseGraphemes.withUnsafeBufferPointer { graphemes in
        TerminalRowSignature.signature(row: row, cells: cells, graphemes: graphemes)
      }
    }
    let graphemeSignature = [base].withUnsafeBufferPointer { cells in
      changedGraphemes.withUnsafeBufferPointer { graphemes in
        TerminalRowSignature.signature(row: row, cells: cells, graphemes: graphemes)
      }
    }

    XCTAssertEqual(signature, equalSignature)
    XCTAssertNotEqual(signature, codepointSignature)
    XCTAssertNotEqual(signature, foregroundSignature)
    XCTAssertNotEqual(signature, graphemeSignature)
  }

  func testRowSignatureStreamingAgreesWithMaterializedBytes() {
    let row = LocusTermRow(
      y: 0,
      cell_start: 0,
      cell_count: 1,
      dirty: false,
      wrapped: false,
      sel_start: .max,
      sel_end: .max
    )
    let base = terminalTestCell(codepoint: 0x41, foregroundRed: 1, graphemeLength: 1)
    let changed = terminalTestCell(codepoint: 0x41, foregroundRed: 2, graphemeLength: 1)
    let graphemes: [UInt32] = [0x301]
    let signature = [base].withUnsafeBufferPointer { cells in
      graphemes.withUnsafeBufferPointer { graphemes in
        TerminalRowSignature.signature(row: row, cells: cells, graphemes: graphemes)
      }
    }
    let streamedHash = [base].withUnsafeBufferPointer { cells in
      graphemes.withUnsafeBufferPointer { graphemes in
        TerminalRowSignature.hash(row: row, cells: cells, graphemes: graphemes)
      }
    }

    XCTAssertEqual(streamedHash, TerminalRowSignature.hash(signature: signature))
    XCTAssertTrue(
      [base].withUnsafeBufferPointer { cells in
        graphemes.withUnsafeBufferPointer { graphemes in
          TerminalRowSignature.matches(
            signature,
            row: row,
            cells: cells,
            graphemes: graphemes
          )
        }
      }
    )
    XCTAssertFalse(
      [changed].withUnsafeBufferPointer { cells in
        graphemes.withUnsafeBufferPointer { graphemes in
          TerminalRowSignature.matches(
            signature,
            row: row,
            cells: cells,
            graphemes: graphemes
          )
        }
      }
    )
  }

  func testScrolledContentReusesPooledRows() throws {
    let fixture = makeTerminalRenderFixture(columns: 60, rows: 12, lineCount: 16)
    defer {
      fixture.session.terminate()
    }
    XCTAssertNotNil(fixture.view.buildMetalSceneForTesting())
    let generation = fixture.session.snapshot?.generation ?? 0

    fixture.session.send(Data("printf 'new-0\\r\\nnew-1\\r\\nnew-2\\r\\n'\n".utf8))
    XCTAssertTrue(
      waitForPaneCondition {
        (fixture.session.snapshot?.generation ?? 0) > generation
          && fixture.session.plainTextForTesting()?.contains("new-2") == true
      }
    )
    XCTAssertNotNil(fixture.view.buildMetalSceneForTesting())

    XCTAssertGreaterThan(fixture.view.rowTextPoolStatisticsForTesting.hits, 0)
    XCTAssertGreaterThan(fixture.view.rowTextPoolStatisticsForTesting.misses, 0)
  }

  func testCopyWritesSelectionToInjectedPasteboard() {
    let pasteboard = NSPasteboard(name: .init("locus-terminal-copy-\(UUID().uuidString)"))
    pasteboard.clearContents()
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
      pasteboard.clearContents()
    }
    let view = TerminalPaneView(session: session, pasteboard: pasteboard)
    session.start(command: "/bin/sh")
    session.send(Data("echo copy-me\n".utf8))

    var row: UInt16?
    XCTAssertTrue(
      waitForPaneCondition {
        session.withFrame { frame in
          let lines = frame.plainText().split(separator: "\n", omittingEmptySubsequences: false)
          if let index = lines.firstIndex(where: { $0.hasPrefix("copy-me") }) {
            row = UInt16(clamping: index)
          }
        }
        return row != nil
      }
    )
    guard let row else {
      return
    }
    // Drag fraction 0.9 selects through column 3 (the endpoint cell only
    // joins the selection once the pointer passes its midpoint).
    session.selectionGesture(.press, column: 0, row: row, cellFractionX: 0.5, rectangle: false)
    session.selectionGesture(.drag, column: 3, row: row, cellFractionX: 0.9, rectangle: false)
    session.selectionGesture(.release, column: 3, row: row, cellFractionX: 0.9, rectangle: false)
    XCTAssertTrue(waitForPaneCondition { session.selectionText() == "copy" })

    view.copy(nil)

    XCTAssertEqual(pasteboard.string(forType: .string), "copy")
  }

  func testViewResizeDrivesSessionResize() {
    let session = TerminalSession(columns: 10, rows: 5)
    defer {
      session.terminate()
    }
    let metrics = TerminalCellMetrics()
    let view = TerminalPaneView(session: session, metrics: metrics)
    view.frame = gridFrame(columns: 40, rows: 10, metrics: metrics)
    let host = TerminalPaneViewHost(view: view)

    session.start(command: "/bin/sh")

    XCTAssertTrue(
      waitForPaneCondition {
        session.snapshot?.columns == 40 && session.snapshot?.rows == 10
      },
      "Snapshot was: \(String(describing: session.snapshot))"
    )
    withExtendedLifetime(host) {}
  }

  func testResizeDebounceDeliversFinalSizeOnly() {
    let metrics = TerminalCellMetrics()
    var deliveredSizes: [TerminalGridSize] = []
    let view = TerminalPaneView(metrics: metrics) { gridSize in
      deliveredSizes.append(gridSize)
    }
    view.frame = gridFrame(columns: 40, rows: 10, metrics: metrics)
    let host = TerminalPaneViewHost(view: view)
    deliveredSizes.removeAll()

    for columns in 41...45 {
      view.setFrameSize(gridFrame(columns: UInt16(columns), rows: 10, metrics: metrics).size)
    }

    XCTAssertTrue(waitForPaneCondition { deliveredSizes.count == 1 })
    XCTAssertEqual(deliveredSizes, [TerminalGridSize(columns: 45, rows: 10)])
    withExtendedLifetime(host) {}
  }

  func testReshowSyncsCurrentSize() {
    let metrics = TerminalCellMetrics()
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }
    let view = TerminalPaneView(session: session, metrics: metrics)
    view.frame = gridFrame(columns: 40, rows: 10, metrics: metrics)
    let host = TerminalPaneViewHost(view: view)
    session.start(command: "/bin/sh")
    XCTAssertTrue(
      waitForPaneCondition {
        session.snapshot?.columns == 40 && session.snapshot?.rows == 10
      },
      "Snapshot was: \(String(describing: session.snapshot))"
    )

    view.removeFromSuperview()
    view.setFrameSize(gridFrame(columns: 52, rows: 14, metrics: metrics).size)
    RunLoop.current.run(until: Date().addingTimeInterval(0.12))
    XCTAssertEqual(session.snapshot?.columns, 40)
    XCTAssertEqual(session.snapshot?.rows, 10)

    host.contentView.addSubview(view)
    XCTAssertTrue(
      waitForPaneCondition {
        session.snapshot?.columns == 52 && session.snapshot?.rows == 14
      },
      "Snapshot was: \(String(describing: session.snapshot))"
    )
  }
}

@MainActor
private final class TerminalPaneViewHost {
  let window: NSWindow
  let contentView: NSView

  init(view: TerminalPaneView) {
    contentView = NSView(frame: view.frame)
    window = NSWindow(
      contentRect: contentView.frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = contentView
    contentView.addSubview(view)
  }
}

@MainActor
private struct TerminalMetalPaneFixture {
  let session: TerminalSession
  let view: TerminalPaneView
  let contentRow: UInt16
  let host: TerminalPaneViewHost?
}

@MainActor
private func makeMetalPaneFixture(
  text: String,
  hosted: Bool = false
) throws -> TerminalMetalPaneFixture {
  let columns: UInt16 = 40
  let rows: UInt16 = 10
  let metrics = TerminalCellMetrics()
  let session = TerminalSession(columns: columns, rows: rows)
  let view = TerminalPaneView(session: session, metrics: metrics)
  view.metalContentsScaleForTesting = 1
  view.frame = gridFrame(columns: columns, rows: rows, metrics: metrics)
  let host = hosted ? TerminalPaneViewHost(view: view) : nil
  session.start(command: "/bin/sh")
  session.send(Data("printf '\\033[2J\\033[H%s\\r\\n' '\(text)'\n".utf8))
  var contentRow: UInt16?
  XCTAssertTrue(
    waitForPaneCondition(timeout: 5) {
      session.withFrame { frame in
        let lines = frame.plainText().split(separator: "\n", omittingEmptySubsequences: false)
        if let index = lines.firstIndex(where: { $0.contains(text) }) {
          contentRow = UInt16(clamping: index)
        }
      }
      return contentRow != nil
    },
    "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
  )
  return TerminalMetalPaneFixture(
    session: session,
    view: view,
    contentRow: try XCTUnwrap(contentRow),
    host: host
  )
}

private func gridFrame(
  columns: UInt16,
  rows: UInt16,
  metrics: TerminalCellMetrics
) -> NSRect {
  let insets = TerminalPaneLayoutMetrics.contentInsets
  return NSRect(
    x: 0,
    y: 0,
    width: insets.left + metrics.cellWidth * CGFloat(columns) + insets.right,
    height: insets.top + metrics.cellHeight * CGFloat(rows) + insets.bottom
  )
}

@MainActor
private func terminalDoubleClick(
  view: TerminalPaneView,
  column: UInt16,
  row: UInt16
) throws {
  let metrics = TerminalCellMetrics()
  let insets = TerminalPaneLayoutMetrics.contentInsets
  let topLeftPoint = NSPoint(
    x: insets.left + (CGFloat(column) + 0.5) * metrics.cellWidth,
    y: insets.top + (CGFloat(row) + 0.5) * metrics.cellHeight
  )
  let localPoint = NSPoint(x: topLeftPoint.x, y: view.bounds.height - topLeftPoint.y)
  let windowPoint = view.convert(localPoint, to: nil)
  let event: (NSEvent.EventType, Int) throws -> NSEvent = { type, clickCount in
    try XCTUnwrap(
      NSEvent.mouseEvent(
        with: type,
        location: windowPoint,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 0,
        clickCount: clickCount,
        pressure: 1
      )
    )
  }
  view.mouseDown(with: try event(.leftMouseDown, 1))
  view.mouseUp(with: try event(.leftMouseUp, 1))
  view.mouseDown(with: try event(.leftMouseDown, 2))
}

@MainActor
private func waitForPaneCondition(
  timeout: TimeInterval = 3.0,
  interval: TimeInterval = 0.01,
  condition: () -> Bool
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() {
      return true
    }
    RunLoop.current.run(until: Date().addingTimeInterval(interval))
  }
  return condition()
}

@MainActor
private func makeTerminalRenderFixture(
  columns: UInt16,
  rows: UInt16,
  lineCount: Int
) -> (session: TerminalSession, view: TerminalPaneView, metrics: TerminalCellMetrics) {
  let metrics = TerminalCellMetrics()
  let session = TerminalSession(columns: columns, rows: rows)
  let view = TerminalPaneView(session: session, metrics: metrics)
  view.frame = gridFrame(columns: columns, rows: rows, metrics: metrics)
  session.start(command: "/bin/sh")
  let command =
    "i=0; printf '\\033[2J\\033[H'; while [ \"$i\" -lt \(lineCount) ]; do "
    + "c=$((i % 7 + 1)); printf '\\033[3%smfixture-%02d 日本語-%02d "
    + "payload-abcdefghijklmnopqrstuvwxyz\\033[0m\\r\\n' \"$c\" \"$i\" \"$i\"; "
    + "i=$((i + 1)); done\n"
  session.send(Data(command.utf8))
  let finalLine = String(format: "fixture-%02d", max(0, lineCount - 1))
  XCTAssertTrue(
    waitForPaneCondition(timeout: 5) {
      session.plainTextForTesting()?.contains(finalLine) == true
    },
    "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
  )
  view.needsDisplay = true
  view.displayIfNeeded()
  return (session, view, metrics)
}

private func terminalTestCell(
  codepoint: UInt32,
  foregroundRed: UInt8,
  graphemeLength: Int
) -> LocusTermCell {
  LocusTermCell(
    codepoint: codepoint,
    raw: 0,
    fg: LocusTermRgb(r: foregroundRed, g: 3, b: 4),
    bg: LocusTermRgb(r: 5, g: 6, b: 7),
    flags: 0,
    wide: 0,
    grapheme_start: 0,
    grapheme_len: graphemeLength,
    hyperlink_id: 0
  )
}

private func terminalShapingCell(
  codepoint: UInt32,
  width: TerminalCellWidth,
  flags: TerminalCellFlags = []
) -> LocusTermCell {
  LocusTermCell(
    codepoint: codepoint,
    raw: 0,
    fg: LocusTermRgb(r: 0xC5, g: 0xC8, b: 0xC6),
    bg: LocusTermRgb(r: 0x1D, g: 0x1F, b: 0x21),
    flags: flags.rawValue,
    wide: width.rawValue,
    grapheme_start: 0,
    grapheme_len: 0,
    hyperlink_id: 0
  )
}

@MainActor
private func terminalShapedRow(
  cells: [LocusTermCell],
  metrics: TerminalCellMetrics
) -> TerminalShapedRow {
  let row = LocusTermRow(
    y: 0,
    cell_start: 0,
    cell_count: cells.count,
    dirty: false,
    wrapped: false,
    sel_start: .max,
    sel_end: .max
  )
  let cache = TerminalRowShapingCache(
    metrics: metrics,
    insets: TerminalPaneLayoutMetrics.contentInsets
  )
  return cells.withUnsafeBufferPointer { cellBuffer in
    [UInt32]().withUnsafeBufferPointer { graphemeBuffer in
      cache.beginPaint()
      return cache.shapedRow(row: row, cells: cellBuffer, graphemes: graphemeBuffer)
    }
  }
}
