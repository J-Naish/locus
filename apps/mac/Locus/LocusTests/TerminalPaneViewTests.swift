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
    view.frame = NSRect(
      x: 0,
      y: 0,
      width: metrics.cellWidth * 40,
      height: metrics.cellHeight * 10
    )

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
    view.frame = NSRect(
      x: 0,
      y: 0,
      width: metrics.cellWidth * 40,
      height: metrics.cellHeight * 10
    )

    session.start(command: "/bin/sh")

    XCTAssertTrue(
      waitForPaneCondition {
        session.snapshot?.columns == 40 && session.snapshot?.rows == 10
      },
      "Snapshot was: \(String(describing: session.snapshot))"
    )
  }
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
