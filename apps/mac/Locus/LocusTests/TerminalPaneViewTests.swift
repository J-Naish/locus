import AppKit
import XCTest

@testable import Locus

@MainActor
final class TerminalPaneViewTests: XCTestCase {
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

  func testOffscreenRenderSmoke() throws {
    let metrics = TerminalCellMetrics()
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }
    let view = TerminalPaneView(session: session, metrics: metrics)
    view.frame = gridFrame(columns: 40, rows: 10, metrics: metrics)
    session.start(command: "/bin/sh")
    session.send(Data("echo hi\n".utf8))
    XCTAssertTrue(
      waitForPaneCondition { session.snapshot?.plainText.contains("hi") == true },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )
    var frameText = ""
    session.withFrame { frame in
      frameText = terminalPanePlainText(in: frame)
    }
    XCTAssertTrue(frameText.contains("hi"), "Frame was: \(frameText)")
    view.needsDisplay = true
    view.displayIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      XCTFail("Failed to create bitmap")
      return
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)

    XCTAssertTrue(bitmapHasMultipleColors(bitmap))
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

private func bitmapHasMultipleColors(_ bitmap: NSBitmapImageRep) -> Bool {
  var firstColor: NSColor?
  var y = 0
  while y < bitmap.pixelsHigh {
    var x = 0
    while x < bitmap.pixelsWide {
      guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
        x += 1
        continue
      }
      if let firstColor {
        if abs(firstColor.redComponent - color.redComponent) > 0.01
          || abs(firstColor.greenComponent - color.greenComponent) > 0.01
          || abs(firstColor.blueComponent - color.blueComponent) > 0.01
          || abs(firstColor.alphaComponent - color.alphaComponent) > 0.01
        {
          return true
        }
      } else {
        firstColor = color
      }
      x += 1
    }
    y += 1
  }
  return false
}

private func terminalPanePlainText(in frame: TerminalFrame) -> String {
  var result = ""
  frame.withRows { rows in
    frame.withCells { cells in
      for row in rows {
        let start = min(row.cell_start, cells.count)
        let end = min(row.cell_start + row.cell_count, cells.count)
        for cell in cells[start..<end] {
          if cell.codepoint != 0, let scalar = UnicodeScalar(cell.codepoint) {
            result.unicodeScalars.append(scalar)
          } else {
            result.append(" ")
          }
        }
        result.append("\n")
      }
    }
  }
  return result
}
