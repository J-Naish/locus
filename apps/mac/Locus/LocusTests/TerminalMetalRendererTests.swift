import AppKit
import Metal
import XCTest

@testable import Locus

@MainActor
final class TerminalMetalRendererTests: XCTestCase {
  private let metrics = TerminalCellMetrics()
  private let insets = TerminalPaneLayoutMetrics.contentInsets

  func testSolidInstanceLayoutMatchesShaderABI() {
    XCTAssertEqual(MemoryLayout<TerminalSolidInstance>.stride, 32)
  }

  func testGlyphInstanceLayoutMatchesShaderABI() {
    XCTAssertEqual(MemoryLayout<TerminalGlyphInstance>.stride, 64)
  }

  func testRendererInitializesFromDefaultLibrary() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

    XCTAssertNotNil(
      TerminalMetalRenderer(device: device, metrics: metrics, insets: insets)
    )

    var cache = TerminalForegroundColorCache()
    let defaultStyle = TerminalTextStyle(
      foreground: .defaultForeground,
      background: .defaultBackground,
      flags: []
    )
    let directDefault = TerminalMetalColor.premultipliedSRGB(.textColor)
    XCTAssertEqual(cache.color(for: defaultStyle), directDefault)
    XCTAssertEqual(cache.color(for: defaultStyle), directDefault)
    XCTAssertEqual(cache.missCountForTesting, 1)

    let faintStyle = TerminalTextStyle(
      foreground: .defaultForeground,
      background: .defaultBackground,
      flags: [.faint]
    )
    let directFaint = TerminalMetalColor.premultipliedSRGB(
      NSColor.textColor.withAlphaComponent(0.55)
    )
    XCTAssertEqual(cache.color(for: faintStyle), directFaint)
    XCTAssertEqual(cache.missCountForTesting, 2)
    cache.clear()
    XCTAssertEqual(cache.missCountForTesting, 0)
    XCTAssertEqual(cache.color(for: defaultStyle), directDefault)
    XCTAssertEqual(cache.missCountForTesting, 1)
  }

  func testSolidQuadUsesExactPixelCoordinatesAndColor() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try XCTUnwrap(
      TerminalMetalRenderer(
        device: device,
        metrics: TerminalCellMetrics(),
        insets: TerminalPaneLayoutMetrics.contentInsets
      ))
    let texture = try makeTarget(device: device, width: 32, height: 24)
    let red = SIMD4<Float>(1, 0, 0, 1)
    let clear = SIMD4<Float>(0.125, 0.25, 0.5, 1)
    let scene = TerminalMetalScene(
      viewSize: CGSize(width: 32, height: 24),
      scale: 1,
      backgroundColor: clear,
      rows: [],
      selectionRects: [CGRect(x: 3, y: 5, width: 7, height: 4)],
      selectionColor: red,
      searchRects: [],
      linkUnderlineRects: [],
      linkUnderlineColor: .zero,
      caretRect: nil,
      caretColor: .zero
    )

    XCTAssertTrue(renderer.render(scene: scene, into: texture, waitUntilCompleted: true))
    let pixels = readPixels(texture)

    assertBGRA(pixels, width: 32, x: 3, y: 15, equals: [0, 0, 255, 255])
    assertBGRA(pixels, width: 32, x: 9, y: 18, equals: [0, 0, 255, 255])
    assertBGRA(pixels, width: 32, x: 0, y: 0, equals: [128, 64, 32, 255])
    assertBGRA(pixels, width: 32, x: 31, y: 23, equals: [128, 64, 32, 255])
  }

  func testBackgroundFillUsesGridFormulaAndExactColor() throws {
    let harness = try makeHarness(columns: 8, rows: 3)
    let raw = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    let shaped = TerminalShapedRow(
      signature: [],
      runs: [],
      backgroundFills: [TerminalBackgroundFill(startColumn: 2, cellCount: 3, color: raw)],
      lastUsedPaint: 0
    )
    let scene = makeScene(harness: harness, rows: [.init(y: 1, shaped: shaped, runForegrounds: [])])

    XCTAssertTrue(
      harness.renderer.render(scene: scene, into: harness.texture, waitUntilCompleted: true)
    )
    let pixels = readPixels(harness.texture)
    let x = Int(insets.left + 2 * metrics.cellWidth)
    let top = Int(insets.top + metrics.cellHeight)
    let expected: [UInt8] = [153, 102, 51, 255]
    assertBGRA(pixels, width: harness.texture.width, x: x, y: top, equals: expected)
    assertBGRA(
      pixels,
      width: harness.texture.width,
      x: x + Int(3 * metrics.cellWidth) - 1,
      y: top + Int(metrics.cellHeight) - 1,
      equals: expected
    )
  }

  func testGlyphInkStaysInItsCellsAndUsesForegroundTint() throws {
    let harness = try makeHarness(columns: 8, rows: 2)
    let shaped = shapedRow(text: "AB")
    let foreground = SIMD4<Float>(0.8, 0.15, 0.05, 1)
    let scene = makeScene(
      harness: harness,
      rows: [.init(y: 0, shaped: shaped, runForegrounds: [foreground])]
    )

    XCTAssertTrue(
      harness.renderer.render(scene: scene, into: harness.texture, waitUntilCompleted: true)
    )
    let pixels = readPixels(harness.texture)
    let ink = inkPixels(
      pixels,
      width: harness.texture.width,
      height: harness.texture.height,
      columns: 0..<2,
      row: 0
    )
    XCTAssertFalse(ink.isEmpty)
    XCTAssertTrue(
      ink.contains { pixel in
        Int(pixel.r) > Int(pixel.g) * 2 && Int(pixel.r) > Int(pixel.b) * 2
      }
    )
    XCTAssertTrue(
      inkPixels(
        pixels,
        width: harness.texture.width,
        height: harness.texture.height,
        columns: 5..<6,
        row: 0
      ).isEmpty
    )
  }

  func testEveryGlyphInstanceRendersItsOwnCell() throws {
    let harness = try makeHarness(columns: 6, rows: 2)
    let shaped = shapedRow(text: "AWM")
    let scene = makeScene(
      harness: harness,
      rows: [.init(y: 0, shaped: shaped, runForegrounds: [SIMD4(0.1, 0.1, 0.1, 1)])]
    )

    XCTAssertTrue(
      harness.renderer.render(scene: scene, into: harness.texture, waitUntilCompleted: true)
    )
    let pixels = readPixels(harness.texture)
    for column in 0..<3 {
      XCTAssertFalse(
        inkPixels(
          pixels,
          width: harness.texture.width,
          height: harness.texture.height,
          columns: column..<(column + 1),
          row: 0
        ).isEmpty,
        "Expected glyph instance at column \(column)"
      )
    }
  }

  func testWideCJKGlyphOccupiesTwoCellBudget() throws {
    let harness = try makeHarness(columns: 5, rows: 2)
    let shaped = shapedRow(text: "漢", wideScalar: true)
    let scene = makeScene(
      harness: harness,
      rows: [.init(y: 0, shaped: shaped, runForegrounds: [SIMD4(0.1, 0.1, 0.1, 1)])]
    )

    XCTAssertTrue(
      harness.renderer.render(scene: scene, into: harness.texture, waitUntilCompleted: true)
    )
    let pixels = readPixels(harness.texture)
    XCTAssertFalse(
      inkPixels(
        pixels,
        width: harness.texture.width,
        height: harness.texture.height,
        columns: 0..<1,
        row: 0
      ).isEmpty
    )
    XCTAssertFalse(
      inkPixels(
        pixels,
        width: harness.texture.width,
        height: harness.texture.height,
        columns: 1..<2,
        row: 0
      ).isEmpty
    )
    XCTAssertTrue(
      inkPixels(
        pixels,
        width: harness.texture.width,
        height: harness.texture.height,
        columns: 2..<3,
        row: 0
      ).isEmpty
    )
  }

  func testOverflowGlyphCondensesInsideOneCell() throws {
    let harness = try makeHarness(columns: 5, rows: 2)
    let original = shapedRow(text: "漢", wideScalar: true)
    let originalRun = try XCTUnwrap(original.runs.first)
    let originalBatch = try XCTUnwrap(originalRun.glyphBatches.first)
    let condensedBatch = TerminalGlyphBatch(
      font: originalBatch.font,
      glyphs: originalBatch.glyphs,
      positions: originalBatch.positions,
      overflowScaleX: 0.5,
      overflowAnchorX: insets.left
    )
    let condensed = TerminalShapedRow(
      signature: original.signature,
      runs: [TerminalShapedRun(run: originalRun.run, glyphBatches: [condensedBatch])],
      backgroundFills: [],
      lastUsedPaint: 0
    )
    let scene = makeScene(
      harness: harness,
      rows: [.init(y: 0, shaped: condensed, runForegrounds: [SIMD4(0.1, 0.1, 0.1, 1)])]
    )

    XCTAssertTrue(
      harness.renderer.render(scene: scene, into: harness.texture, waitUntilCompleted: true)
    )
    let pixels = readPixels(harness.texture)
    let bounds = try XCTUnwrap(inkBounds(pixels, width: harness.texture.width))
    XCTAssertGreaterThanOrEqual(bounds.minX, Int(insets.left) - 1)
    XCTAssertLessThanOrEqual(bounds.maxX, Int(insets.left + metrics.cellWidth) + 1)
  }

  func testUnderlineDecorationMatchesRunCells() throws {
    let harness = try makeHarness(columns: 6, rows: 2)
    let shaped = shapedRow(text: "AB", flags: [.underline])
    let foreground = SIMD4<Float>(0.75, 0.1, 0.2, 1)
    let scene = makeScene(
      harness: harness,
      rows: [.init(y: 0, shaped: shaped, runForegrounds: [foreground])]
    )

    XCTAssertTrue(
      harness.renderer.render(scene: scene, into: harness.texture, waitUntilCompleted: true)
    )
    let pixels = readPixels(harness.texture)
    let font = metrics.font(for: [.underline]) as CTFont
    let baselineY = harness.viewSize.height - insets.top - metrics.baselineOffset
    let underline = CGRect(
      x: insets.left,
      y: baselineY + CTFontGetUnderlinePosition(font),
      width: 2 * metrics.cellWidth,
      height: max(1, CTFontGetUnderlineThickness(font))
    )
    let px = TerminalMetalRenderer.devicePixelRect(
      underline,
      viewSize: harness.viewSize,
      scale: 1
    )
    let expected: [UInt8] = [51, 26, 191, 255]
    assertBGRA(
      pixels,
      width: harness.texture.width,
      x: Int(px.x),
      y: Int(px.y),
      equals: expected
    )
    assertBGRA(
      pixels,
      width: harness.texture.width,
      x: Int(px.x + px.z) - 1,
      y: Int(px.y),
      equals: expected
    )
  }

  func testCaretAndLinkQuadsUseTheirExactColors() throws {
    let harness = try makeHarness(columns: 6, rows: 3)
    let linkRect = CGRect(x: 4, y: 7, width: 13, height: 2)
    let caretRect = CGRect(x: 25, y: 10, width: 2, height: 12)
    var scene = makeScene(harness: harness, rows: [])
    scene.linkUnderlineRects = [linkRect]
    scene.linkUnderlineColor = SIMD4(0, 0.75, 0.25, 1)
    scene.caretRect = caretRect
    scene.caretColor = SIMD4(0.75, 0.125, 0.5, 1)

    XCTAssertTrue(
      harness.renderer.render(scene: scene, into: harness.texture, waitUntilCompleted: true)
    )
    let pixels = readPixels(harness.texture)
    let linkPx = TerminalMetalRenderer.devicePixelRect(
      linkRect,
      viewSize: harness.viewSize,
      scale: 1
    )
    let caretPx = TerminalMetalRenderer.devicePixelRect(
      caretRect,
      viewSize: harness.viewSize,
      scale: 1
    )
    assertBGRA(
      pixels,
      width: harness.texture.width,
      x: Int(linkPx.x),
      y: Int(linkPx.y),
      equals: [64, 191, 0, 255]
    )
    assertBGRA(
      pixels,
      width: harness.texture.width,
      x: Int(caretPx.x),
      y: Int(caretPx.y),
      equals: [128, 32, 191, 255]
    )
  }

  func testAttachmentImageChannelOrder() throws {
    let source = PixelBuffer(width: 1, height: 1, bytes: [0, 0, 255, 255])
    let image = try XCTUnwrap(image(from: source))
    let rendered = try sRGBPixels(width: 1, height: 1) {
      image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
    }
    let pixel = rendered.pixel(x: 0, y: 0)

    XCTAssertGreaterThanOrEqual(pixel[2], 250)
    XCTAssertLessThanOrEqual(pixel[1], 5)
    XCTAssertLessThanOrEqual(pixel[0], 5)
    XCTAssertEqual(pixel[3], 255)
  }

  func testDifferentialSolidStructureMatchesCoreGraphics() throws {
    let fixture = try makeDifferentialFixture(columns: 60, rows: 18)
    defer { fixture.session.terminate() }
    let scene = buildSceneForFixture(fixture)
    let metal = try renderPixels(scene: scene, renderer: fixture.renderer)
    let cg = try coreGraphicsPixels(view: fixture.view)
    guard assertSameDimensions(cg: cg, metal: metal) else { return }
    let blankCells = blankCellCoordinates(in: fixture.session)
    var differences: [Int] = []
    var worst: [(coordinate: TerminalCellCoordinate, delta: Int)] = []
    for coordinate in blankCells {
      let deltas = cellDifferences(
        cg: cg,
        metal: metal,
        coordinate: coordinate,
        inset: 1
      )
      differences.append(contentsOf: deltas)
      worst.append((coordinate, deltas.max() ?? 0))
    }
    let mean =
      differences.isEmpty
      ? 0
      : Double(differences.reduce(0, +)) / Double(differences.count)
    let maximum = differences.max() ?? 0
    print("metal_diff_solid_mean=\(mean) metal_diff_solid_max=\(maximum)")
    if mean > 2 || maximum > 6 {
      attachDifferentialImages(cg: cg, metal: metal)
      XCTFail(
        "Solid differential exceeded limits; worst=\(worst.sorted { $0.delta > $1.delta }.prefix(10))"
      )
    }
  }

  func testDifferentialGlyphStructureMatchesCoreGraphics() throws {
    let fixture = try makeDifferentialFixture(columns: 60, rows: 18)
    defer { fixture.session.terminate() }
    let scene = buildSceneForFixture(fixture)
    let metal = try renderPixels(scene: scene, renderer: fixture.renderer)
    let cg = try coreGraphicsPixels(view: fixture.view)
    guard assertSameDimensions(cg: cg, metal: metal) else { return }
    var matches = 0
    var total = 0
    var inkDifferences: [Int] = []
    var worst: [(coordinate: TerminalCellCoordinate, delta: Int)] = []
    for row in 0..<18 {
      for column in 0..<60 {
        let coordinate = TerminalCellCoordinate(
          column: UInt16(column),
          row: UInt16(row)
        )
        let cgInk = cellHasInk(cg, coordinate: coordinate, threshold: 24)
        let metalInk = cellHasInk(metal, coordinate: coordinate, threshold: 24)
        total += 1
        if cgInk == metalInk {
          matches += 1
        }
        if cgInk || metalInk {
          let deltas = cellDifferences(
            cg: cg,
            metal: metal,
            coordinate: coordinate,
            inset: 1
          )
          inkDifferences.append(contentsOf: deltas)
          worst.append((coordinate, deltas.max() ?? 0))
        }
      }
    }
    let agreement = Double(matches) / Double(max(1, total))
    let mean =
      inkDifferences.isEmpty
      ? 0
      : Double(inkDifferences.reduce(0, +)) / Double(inkDifferences.count)
    let maximum = inkDifferences.max() ?? 0
    print(
      "metal_diff_glyph_agreement=\(agreement) metal_diff_glyph_mean=\(mean) metal_diff_glyph_max=\(maximum)"
    )
    if agreement < 0.98 || mean > 32 {
      attachDifferentialImages(cg: cg, metal: metal)
      XCTFail(
        "Glyph differential exceeded limits; worst=\(worst.sorted { $0.delta > $1.delta }.prefix(10))"
      )
    }
  }

  func testMetalRenderPassTimingProbe() throws {
    let fixture = try makeDifferentialFixture(columns: 120, rows: 40, lineCount: 40)
    defer { fixture.session.terminate() }
    var coldScene: [Double] = []
    var coldBuild: [Double] = []
    var coldGPU: [Double] = []
    var warmScene: [Double] = []
    var warmBuild: [Double] = []
    var warmGPU: [Double] = []

    for _ in 0..<20 {
      fixture.renderer.invalidateGlyphCache(scale: 1)
      let sceneStart = CFAbsoluteTimeGetCurrent()
      let scene = buildSceneForFixture(fixture)
      let sceneMilliseconds = (CFAbsoluteTimeGetCurrent() - sceneStart) * 1_000
      _ = try renderPixels(scene: scene, renderer: fixture.renderer)
      if let timing = fixture.renderer.lastTiming {
        coldScene.append(sceneMilliseconds)
        coldBuild.append(timing.buildEncodeMilliseconds)
        coldGPU.append(timing.gpuMilliseconds ?? 0)
      }
    }
    let warmup = buildSceneForFixture(fixture)
    _ = try renderPixels(scene: warmup, renderer: fixture.renderer)
    for _ in 0..<20 {
      let sceneStart = CFAbsoluteTimeGetCurrent()
      let scene = buildSceneForFixture(fixture)
      let sceneMilliseconds = (CFAbsoluteTimeGetCurrent() - sceneStart) * 1_000
      _ = try renderPixels(scene: scene, renderer: fixture.renderer)
      if let timing = fixture.renderer.lastTiming {
        warmScene.append(sceneMilliseconds)
        warmBuild.append(timing.buildEncodeMilliseconds)
        warmGPU.append(timing.gpuMilliseconds ?? 0)
      }
    }

    let coldSceneMedian = median(coldScene)
    let coldBuildMedian = median(coldBuild)
    let coldGPUMedian = median(coldGPU)
    let warmSceneMedian = median(warmScene)
    let warmBuildMedian = median(warmBuild)
    let warmGPUMedian = median(warmGPU)
    recordMetric("metal_cold_scene_ms", coldSceneMedian)
    recordMetric("metal_cold_build_encode_ms", coldBuildMedian)
    recordMetric("metal_cold_gpu_ms", coldGPUMedian)
    recordMetric("metal_warm_scene_ms", warmSceneMedian)
    recordMetric("metal_warm_build_encode_ms", warmBuildMedian)
    recordMetric("metal_warm_gpu_ms", warmGPUMedian)
    XCTAssertLessThan(
      warmBuildMedian,
      7,
      "STOP: warm Metal CPU path is structurally slower than the 7ms budget"
    )
  }

  private func makeTarget(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget]
    return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
  }

  private struct Harness {
    let renderer: TerminalMetalRenderer
    let texture: MTLTexture
    let viewSize: CGSize
  }

  private final class DifferentialFixture {
    let session: TerminalSession
    let view: TerminalPaneView
    let renderer: TerminalMetalRenderer
    let cache: TerminalRowShapingCache
    var foregroundColorCache = TerminalForegroundColorCache()

    init(
      session: TerminalSession,
      view: TerminalPaneView,
      renderer: TerminalMetalRenderer,
      cache: TerminalRowShapingCache
    ) {
      self.session = session
      self.view = view
      self.renderer = renderer
      self.cache = cache
    }
  }

  private struct PixelBuffer {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func pixel(x: Int, y: Int) -> [UInt8] {
      let offset = (y * width + x) * 4
      return Array(bytes[offset..<(offset + 4)])
    }
  }

  private func makeDifferentialFixture(
    columns: UInt16,
    rows: UInt16,
    lineCount: Int? = nil
  ) throws -> DifferentialFixture {
    let session = TerminalSession(columns: columns, rows: rows)
    let view = TerminalPaneView(session: session, metrics: metrics)
    view.appearance = NSAppearance(named: .aqua)
    view.frame = CGRect(
      x: 0,
      y: 0,
      width: insets.left + CGFloat(columns) * metrics.cellWidth + insets.right,
      height: insets.top + CGFloat(rows) * metrics.cellHeight + insets.bottom
    )
    session.start(command: "/bin/sh")
    let count = lineCount ?? max(1, Int(rows) - 2)
    let command =
      "i=0; printf '\\033[2J\\033[H'; while [ \"$i\" -lt \(count) ]; do "
      + "fg=$((i % 8)); bg=$(((i + 3) % 8)); "
      + "printf '\\033[3%sm\\033[4%smrow-%02d ASCII \\033[1mBOLD\\033[22m "
      + "\\033[4mUNDER\\033[24m \\033[7mINV\\033[27m 日本語 \\033[0m    \\r\\n' "
      + "\"$fg\" \"$bg\" \"$i\"; i=$((i + 1)); done\n"
    session.send(Data(command.utf8))
    let finalLine = String(format: "row-%02d", count - 1)
    XCTAssertTrue(
      waitForCondition(timeout: 5) {
        session.plainTextForTesting()?.contains(finalLine) == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    view.needsDisplay = true
    view.displayIfNeeded()
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    return DifferentialFixture(
      session: session,
      view: view,
      renderer: try XCTUnwrap(
        TerminalMetalRenderer(device: device, metrics: metrics, insets: insets)
      ),
      cache: TerminalRowShapingCache(metrics: metrics, insets: insets)
    )
  }

  private func buildScene(
    session: TerminalSession,
    viewSize: CGSize,
    cache: TerminalRowShapingCache,
    foregroundColorCache: inout TerminalForegroundColorCache,
    includeCaret: Bool
  ) -> TerminalMetalScene {
    var result = TerminalMetalScene(
      viewSize: viewSize,
      scale: 1,
      backgroundColor: TerminalMetalColor.premultipliedSRGB(.textBackgroundColor),
      rows: [],
      selectionRects: [],
      selectionColor: TerminalMetalColor.premultipliedSRGB(
        .unemphasizedSelectedTextBackgroundColor
      ),
      searchRects: [],
      linkUnderlineRects: [],
      linkUnderlineColor: TerminalMetalColor.premultipliedSRGB(
        NSColor.textColor.withAlphaComponent(0.8)
      ),
      caretRect: nil,
      caretColor: TerminalMetalColor.premultipliedSRGB(
        NSColor.labelColor.withAlphaComponent(0.4)
      )
    )
    cache.beginPaint()
    defer { cache.finishPaint() }
    session.withFrame { frame in
      frame.withRows { rows in
        frame.withCells { cells in
          frame.withGraphemes { graphemes in
            for (index, row) in rows.enumerated() {
              let shaped = cache.shapedRow(row: row, cells: cells, graphemes: graphemes)
              let foregrounds = shaped.runs.map {
                foregroundColorCache.color(for: $0.run.style)
              }
              result.rows.append(
                TerminalMetalScene.Row(
                  y: row.y,
                  shaped: shaped,
                  runForegrounds: foregrounds
                ))
              if let columns = frame.selectionRange(forRow: index) {
                result.selectionRects.append(
                  TerminalPaneGeometry.selectionRect(
                    columns: columns,
                    row: row.y,
                    bounds: CGRect(origin: .zero, size: viewSize),
                    metrics: metrics,
                    insets: insets
                  ))
              }
            }
          }
        }
      }
      if includeCaret, frame.cursor.visible {
        result.caretRect = caretRect(frame.cursor, viewSize: viewSize)
      }
    }
    return result
  }

  private func buildSceneForFixture(_ fixture: DifferentialFixture) -> TerminalMetalScene {
    var result: TerminalMetalScene?
    fixture.view.effectiveAppearance.performAsCurrentDrawingAppearance {
      result = buildScene(
        session: fixture.session,
        viewSize: fixture.view.bounds.size,
        cache: fixture.cache,
        foregroundColorCache: &fixture.foregroundColorCache,
        includeCaret: true
      )
    }
    return result!
  }

  private func caretRect(_ cursor: LocusTermCursor, viewSize: CGSize) -> CGRect {
    let bounds = CGRect(origin: .zero, size: viewSize)
    if cursor.style == 2 {
      let cell = TerminalPaneGeometry.cursorCellRect(
        cursor: cursor,
        bounds: bounds,
        metrics: metrics,
        insets: insets
      )
      return CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: 2)
    }
    return TerminalPaneGeometry.cursorBarRect(
      cursor: cursor,
      bounds: bounds,
      metrics: metrics,
      insets: insets
    )
  }

  private func coreGraphicsPixels(view: TerminalPaneView) throws -> PixelBuffer {
    let width = Int(view.bounds.width)
    let height = Int(view.bounds.height)
    return try sRGBPixels(width: width, height: height) {
      view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.draw(view.bounds)
      }
    }
  }

  private func sRGBPixels(
    width: Int,
    height: Int,
    draw: () -> Void
  ) throws -> PixelBuffer {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let bitmapInfo = CGBitmapInfo(
      rawValue: CGBitmapInfo.byteOrder32Little.rawValue
        | CGImageAlphaInfo.premultipliedFirst.rawValue
    )
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { storage in
      guard
        let context = CGContext(
          data: storage.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: colorSpace,
          bitmapInfo: bitmapInfo.rawValue
        )
      else {
        return false
      }
      let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = graphicsContext
      context.saveGState()
      context.clip(to: CGRect(x: 0, y: 0, width: width, height: height))
      draw()
      context.restoreGState()
      NSGraphicsContext.restoreGraphicsState()
      return true
    }
    XCTAssertTrue(rendered, "Could not create the sRGB oracle context")
    return PixelBuffer(width: width, height: height, bytes: bytes)
  }

  private func renderPixels(
    scene: TerminalMetalScene,
    renderer: TerminalMetalRenderer
  ) throws -> PixelBuffer {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let texture = try makeTarget(
      device: device,
      width: Int(scene.viewSize.width * scene.scale),
      height: Int(scene.viewSize.height * scene.scale)
    )
    XCTAssertTrue(renderer.render(scene: scene, into: texture, waitUntilCompleted: true))
    return PixelBuffer(width: texture.width, height: texture.height, bytes: readPixels(texture))
  }

  private func blankCellCoordinates(in session: TerminalSession) -> [TerminalCellCoordinate] {
    var result: [TerminalCellCoordinate] = []
    session.withFrame { frame in
      frame.withRows { rows in
        frame.withCells { cells in
          for row in rows {
            var populated = [Bool](repeating: false, count: Int(frame.columns))
            var column = 0
            for cell in cells[TerminalRowShapingCache.cellRange(for: row, cells: cells)] {
              if TerminalCellWidth(rawValue: cell.wide) == .spacerTail {
                continue
              }
              let width = TerminalCellWidth(rawValue: cell.wide) == .wide ? 2 : 1
              let scalar = cell.codepoint == 0 ? nil : UnicodeScalar(cell.codepoint)
              let isBlank = scalar == nil || scalar?.properties.isWhitespace == true
              for offset in 0..<width where column + offset < populated.count {
                populated[column + offset] = !isBlank
              }
              column += width
            }
            for column in populated.indices where !populated[column] {
              result.append(
                TerminalCellCoordinate(column: UInt16(column), row: row.y)
              )
            }
          }
        }
      }
    }
    return result
  }

  private func cellDifferences(
    cg: PixelBuffer,
    metal: PixelBuffer,
    coordinate: TerminalCellCoordinate,
    inset: Int
  ) -> [Int] {
    let rect = cellPixelRect(coordinate, width: cg.width, height: cg.height).insetBy(
      dx: CGFloat(inset),
      dy: CGFloat(inset)
    )
    guard rect.width > 0, rect.height > 0 else { return [] }
    var result: [Int] = []
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) {
        let lhs = cg.pixel(x: x, y: y)
        let rhs = metal.pixel(x: x, y: y)
        for channel in 0..<3 {
          result.append(abs(Int(lhs[channel]) - Int(rhs[channel])))
        }
      }
    }
    return result
  }

  private func cellHasInk(
    _ buffer: PixelBuffer,
    coordinate: TerminalCellCoordinate,
    threshold: Int
  ) -> Bool {
    let rect = cellPixelRect(
      coordinate,
      width: buffer.width,
      height: buffer.height
    ).insetBy(dx: 1, dy: 1)
    var histogram: [[UInt8]: Int] = [:]
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) {
        let rgb = Array(buffer.pixel(x: x, y: y).prefix(3))
        histogram[rgb, default: 0] += 1
      }
    }
    guard let dominant = histogram.max(by: { $0.value < $1.value })?.key else {
      return false
    }
    for y in Int(rect.minY)..<Int(rect.maxY) {
      for x in Int(rect.minX)..<Int(rect.maxX) {
        let pixel = buffer.pixel(x: x, y: y)
        if (0..<3).contains(where: { abs(Int(pixel[$0]) - Int(dominant[$0])) > threshold }) {
          return true
        }
      }
    }
    return false
  }

  private func cellPixelRect(
    _ coordinate: TerminalCellCoordinate,
    width: Int,
    height: Int
  ) -> CGRect {
    CGRect(
      x: insets.left + CGFloat(coordinate.column) * metrics.cellWidth,
      y: insets.top + CGFloat(coordinate.row) * metrics.cellHeight,
      width: min(metrics.cellWidth, CGFloat(width)),
      height: min(metrics.cellHeight, CGFloat(height))
    )
  }

  private func attachDifferentialImages(cg: PixelBuffer, metal: PixelBuffer) {
    for (name, buffer) in [("Core Graphics", cg), ("Metal", metal)] {
      guard let image = image(from: buffer) else { continue }
      let attachment = XCTAttachment(image: image)
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  private func image(from buffer: PixelBuffer) -> NSImage? {
    let bitmapInfo = CGBitmapInfo(
      rawValue: CGBitmapInfo.byteOrder32Little.rawValue
        | CGImageAlphaInfo.premultipliedFirst.rawValue
    )
    guard
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let provider = CGDataProvider(data: Data(buffer.bytes) as CFData),
      let image = CGImage(
        width: buffer.width,
        height: buffer.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: buffer.width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      )
    else {
      return nil
    }
    return NSImage(
      cgImage: image,
      size: NSSize(width: buffer.width, height: buffer.height)
    )
  }

  private func assertSameDimensions(cg: PixelBuffer, metal: PixelBuffer) -> Bool {
    let matches = cg.width == metal.width && cg.height == metal.height
    XCTAssertTrue(
      matches,
      "CG oracle is \(cg.width)x\(cg.height), Metal is \(metal.width)x\(metal.height)"
    )
    return matches
  }

  private func waitForCondition(
    timeout: TimeInterval,
    condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
  }

  private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2
      : sorted[middle]
  }

  private func recordMetric(_ name: String, _ value: Double) {
    let result = "\(name)=\(value)"
    print(result)
    XCTContext.runActivity(named: result) { _ in }
  }

  private func makeHarness(columns: Int, rows: Int) throws -> Harness {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let viewSize = CGSize(
      width: insets.left + CGFloat(columns) * metrics.cellWidth + insets.right,
      height: insets.top + CGFloat(rows) * metrics.cellHeight + insets.bottom
    )
    return Harness(
      renderer: try XCTUnwrap(
        TerminalMetalRenderer(device: device, metrics: metrics, insets: insets)
      ),
      texture: try makeTarget(
        device: device,
        width: Int(viewSize.width),
        height: Int(viewSize.height)
      ),
      viewSize: viewSize
    )
  }

  private func makeScene(
    harness: Harness,
    rows: [TerminalMetalScene.Row]
  ) -> TerminalMetalScene {
    TerminalMetalScene(
      viewSize: harness.viewSize,
      scale: 1,
      backgroundColor: SIMD4(1, 1, 1, 1),
      rows: rows,
      selectionRects: [],
      selectionColor: .zero,
      searchRects: [],
      linkUnderlineRects: [],
      linkUnderlineColor: .zero,
      caretRect: nil,
      caretColor: .zero
    )
  }

  private func shapedRow(
    text: String,
    flags: TerminalCellFlags = [],
    wideScalar: Bool = false
  ) -> TerminalShapedRow {
    let scalars = Array(text.unicodeScalars)
    var cells: [LocusTermCell] = scalars.map { scalar in
      LocusTermCell(
        codepoint: scalar.value,
        raw: 0,
        fg: LocusTermRgb(r: 0xC5, g: 0xC8, b: 0xC6),
        bg: LocusTermRgb(r: 0x1D, g: 0x1F, b: 0x21),
        flags: flags.rawValue,
        wide: wideScalar ? TerminalCellWidth.wide.rawValue : TerminalCellWidth.narrow.rawValue,
        grapheme_start: 0,
        grapheme_len: 0,
        hyperlink_id: 0
      )
    }
    if wideScalar {
      cells.append(
        LocusTermCell(
          codepoint: 0,
          raw: 0,
          fg: LocusTermRgb(r: 0xC5, g: 0xC8, b: 0xC6),
          bg: LocusTermRgb(r: 0x1D, g: 0x1F, b: 0x21),
          flags: flags.rawValue,
          wide: TerminalCellWidth.spacerTail.rawValue,
          grapheme_start: 0,
          grapheme_len: 0,
          hyperlink_id: 0
        ))
    }
    let row = LocusTermRow(
      y: 0,
      cell_start: 0,
      cell_count: cells.count,
      dirty: false,
      wrapped: false,
      sel_start: .max,
      sel_end: .max
    )
    let cache = TerminalRowShapingCache(metrics: metrics, insets: insets)
    return cells.withUnsafeBufferPointer { cellBuffer in
      [UInt32]().withUnsafeBufferPointer { graphemeBuffer in
        cache.beginPaint()
        return cache.shapedRow(row: row, cells: cellBuffer, graphemes: graphemeBuffer)
      }
    }
  }

  private func readPixels(_ texture: MTLTexture) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    pixels.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      texture.getBytes(
        baseAddress,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
      )
    }
    return pixels
  }

  private struct Pixel {
    let b: UInt8
    let g: UInt8
    let r: UInt8
    let a: UInt8
  }

  private func inkPixels(
    _ pixels: [UInt8],
    width: Int,
    height: Int,
    columns: Range<Int>,
    row: Int
  ) -> [Pixel] {
    let minX = Int(insets.left + CGFloat(columns.lowerBound) * metrics.cellWidth)
    let maxX = min(width, Int(insets.left + CGFloat(columns.upperBound) * metrics.cellWidth))
    let minY = Int(insets.top + CGFloat(row) * metrics.cellHeight)
    let maxY = min(height, Int(insets.top + CGFloat(row + 1) * metrics.cellHeight))
    var result: [Pixel] = []
    for y in minY..<maxY {
      for x in minX..<maxX {
        let offset = (y * width + x) * 4
        let pixel = Pixel(
          b: pixels[offset],
          g: pixels[offset + 1],
          r: pixels[offset + 2],
          a: pixels[offset + 3]
        )
        if pixel.r < 245 || pixel.g < 245 || pixel.b < 245 {
          result.append(pixel)
        }
      }
    }
    return result
  }

  private func inkBounds(_ pixels: [UInt8], width: Int) -> (minX: Int, maxX: Int)? {
    var minX = Int.max
    var maxX = Int.min
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      if pixels[offset] < 245 || pixels[offset + 1] < 245 || pixels[offset + 2] < 245 {
        let x = offset / 4 % width
        minX = min(minX, x)
        maxX = max(maxX, x)
      }
    }
    return minX == .max ? nil : (minX, maxX)
  }

  private func assertBGRA(
    _ pixels: [UInt8],
    width: Int,
    x: Int,
    y: Int,
    equals expected: [UInt8],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let offset = (y * width + x) * 4
    XCTAssertEqual(Array(pixels[offset..<(offset + 4)]), expected, file: file, line: line)
  }
}
