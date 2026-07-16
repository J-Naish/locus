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

  func testMarkedTextSceneRendersBackgroundGlyphUnderlineAndCaret() throws {
    let harness = try makeHarness(columns: 12, rows: 3)
    var scene = makeScene(harness: harness, rows: [])
    let backgroundRect = CGRect(x: 12, y: 10, width: 54, height: metrics.cellHeight)
    let underlineRect = CGRect(x: 14, y: 14, width: 28, height: 2)
    let caretRect = CGRect(x: 62, y: 10, width: 2, height: metrics.cellHeight)
    scene.markedText = TerminalMetalMarkedTextScene(
      backgroundRect: backgroundRect,
      attributedString: NSAttributedString(
        string: "IME",
        attributes: [.font: metrics.font]
      ),
      baselineOrigin: CGPoint(x: 14, y: 20),
      underlineRect: underlineRect,
      caretRect: caretRect,
      backgroundColor: SIMD4(0.125, 0.25, 0.5, 1),
      textColor: SIMD4(0.8, 0.1, 0.05, 1),
      caretColor: SIMD4(0.1, 0.75, 0.25, 1)
    )

    XCTAssertTrue(
      harness.renderer.render(scene: scene, into: harness.texture, waitUntilCompleted: true)
    )
    let pixels = readPixels(harness.texture)
    let backgroundPx = TerminalMetalRenderer.devicePixelRect(
      backgroundRect,
      viewSize: harness.viewSize,
      scale: 1
    )
    let underlinePx = TerminalMetalRenderer.devicePixelRect(
      underlineRect,
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
      x: Int(backgroundPx.x) + 1,
      y: Int(backgroundPx.y) + 1,
      equals: [128, 64, 32, 255]
    )
    XCTAssertTrue(
      pixelsContain(
        pixels,
        width: harness.texture.width,
        rect: backgroundPx,
        where: { $0[2] > 150 && $0[1] < 80 && $0[0] < 80 }
      )
    )
    assertBGRA(
      pixels,
      width: harness.texture.width,
      x: Int(underlinePx.x),
      y: Int(underlinePx.y),
      equals: [13, 26, 204, 255]
    )
    assertBGRA(
      pixels,
      width: harness.texture.width,
      x: Int(caretPx.x),
      y: Int(caretPx.y),
      equals: [64, 191, 26, 255]
    )
  }

  func testMarkedTextOccludesCellContentBeneath() throws {
    let harness = try makeHarness(columns: 8, rows: 3)
    let shaped = shapedRow(text: "MMM")
    let row = TerminalMetalScene.Row(
      y: 0,
      shaped: shaped,
      runForegrounds: [SIMD4(0.08, 0.08, 0.08, 1)]
    )
    let sceneWithoutMarkedText = makeScene(harness: harness, rows: [row])

    XCTAssertTrue(
      harness.renderer.render(
        scene: sceneWithoutMarkedText,
        into: harness.texture,
        waitUntilCompleted: true
      )
    )
    let pixelsWithoutMarkedText = readPixels(harness.texture)
    let firstCellRect = cellPixelRect(
      TerminalCellCoordinate(column: 0, row: 0),
      width: harness.texture.width,
      height: harness.texture.height
    )
    let probe = try XCTUnwrap(
      firstPixelCoordinate(
        pixelsWithoutMarkedText,
        width: harness.texture.width,
        rect: firstCellRect,
        where: { pixel in pixel[0] < 200 || pixel[1] < 200 || pixel[2] < 200 }
      ),
      "Expected visible row glyph ink in the first cell"
    )

    var sceneWithMarkedText = sceneWithoutMarkedText
    let backgroundRect = CGRect(
      x: insets.left,
      y: harness.viewSize.height - insets.top - metrics.cellHeight,
      width: 3 * metrics.cellWidth,
      height: metrics.cellHeight
    )
    sceneWithMarkedText.markedText = TerminalMetalMarkedTextScene(
      backgroundRect: backgroundRect,
      attributedString: NSAttributedString(
        string: " ",
        attributes: [.font: metrics.font]
      ),
      baselineOrigin: CGPoint(x: insets.left, y: backgroundRect.minY + metrics.baselineOffset),
      underlineRect: CGRect(x: insets.left, y: 1, width: metrics.cellWidth, height: 1),
      caretRect: CGRect(x: insets.left, y: 2, width: 1, height: 1),
      backgroundColor: SIMD4(1, 1, 1, 1),
      textColor: SIMD4(0, 0, 0, 1),
      caretColor: SIMD4(0, 0, 0, 1)
    )

    XCTAssertTrue(
      harness.renderer.render(
        scene: sceneWithMarkedText,
        into: harness.texture,
        waitUntilCompleted: true
      )
    )
    let pixelsWithMarkedText = readPixels(harness.texture)
    assertBGRA(
      pixelsWithMarkedText,
      width: harness.texture.width,
      x: probe.x,
      y: probe.y,
      equals: [255, 255, 255, 255]
    )
  }

  func testWarmShapingCacheRendersPixelIdenticalToCold() throws {
    let fixture = try makeDifferentialFixture(columns: 60, rows: 18)
    defer { fixture.session.terminate() }

    fixture.cache.clear()
    let cold = try renderPixels(
      scene: buildSceneForFixture(fixture),
      renderer: fixture.renderer
    )
    XCTAssertGreaterThan(fixture.cache.statisticsForTesting.misses, 0)

    let warm = try renderPixels(
      scene: buildSceneForFixture(fixture),
      renderer: fixture.renderer
    )

    XCTAssertEqual(warm.bytes, cold.bytes)
    XCTAssertGreaterThan(fixture.cache.statisticsForTesting.hits, 0)
    XCTAssertEqual(fixture.cache.statisticsForTesting.misses, 0)
  }

  func testWarmCacheIdentityForInverseWideOverflowRow() throws {
    let fixture = try makeDifferentialFixture(columns: 60, rows: 18)
    defer { fixture.session.terminate() }
    let generation = fixture.session.snapshot?.generation ?? 0
    fixture.session.send(Data("printf '\\033[7m逆向き-日本語→○\\033[0m\\r\\n'\n".utf8))
    XCTAssertTrue(
      waitForCondition(timeout: 5) {
        (fixture.session.snapshot?.generation ?? 0) > generation
          && fixture.session.plainTextForTesting()?.contains("逆向き-日本語→○") == true
      }
    )

    fixture.cache.clear()
    let cold = try renderPixels(
      scene: buildSceneForFixture(fixture),
      renderer: fixture.renderer
    )
    XCTAssertGreaterThan(fixture.cache.statisticsForTesting.misses, 0)

    let warm = try renderPixels(
      scene: buildSceneForFixture(fixture),
      renderer: fixture.renderer
    )

    XCTAssertEqual(warm.bytes, cold.bytes)
    XCTAssertGreaterThan(fixture.cache.statisticsForTesting.hits, 0)
    XCTAssertEqual(fixture.cache.statisticsForTesting.misses, 0)
  }

  func testWideGlyphFillReducesInternalInkGap() throws {
    let defaultMetrics = TerminalCellMetrics()
    let legacyMetrics = TerminalCellMetrics(
      wideGlyphFillRatio: 12 / (2 * defaultMetrics.cellWidth)
    )

    let defaultGap = try metalWideGlyphInternalGap(metrics: defaultMetrics)
    let legacyGap = try metalWideGlyphInternalGap(metrics: legacyMetrics)

    XCTAssertLessThan(
      defaultGap,
      legacyGap,
      "Grid-fitted wide glyphs should leave less internal whitespace than the legacy 12pt look"
    )
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

  private func metalWideGlyphInternalGap(metrics: TerminalCellMetrics) throws -> Int {
    let columns: UInt16 = 8
    let rows: UInt16 = 4
    let text = "漢漢"
    let session = TerminalSession(columns: columns, rows: rows)
    defer { session.terminate() }
    let view = TerminalPaneView(session: session, metrics: metrics)
    view.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
    view.metalContentsScaleForTesting = 1
    view.frame = CGRect(
      x: 0,
      y: 0,
      width: insets.left + CGFloat(columns) * metrics.cellWidth + insets.right,
      height: insets.top + CGFloat(rows) * metrics.cellHeight + insets.bottom
    )
    session.start(command: "/bin/cat")
    session.send(Data(text.utf8))
    XCTAssertTrue(
      waitForCondition(timeout: 5) {
        session.plainTextForTesting()?.contains(text) == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )

    let scene = try XCTUnwrap(view.buildMetalSceneForTesting())
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let renderer = try XCTUnwrap(
      TerminalMetalRenderer(device: device, metrics: metrics, insets: insets)
    )
    let pixels = try renderPixels(scene: scene, renderer: renderer)
    let contentRow = try XCTUnwrap(
      scene.rows.first(where: { row in
        row.shaped.runs.contains(where: { $0.run.text.contains(text) })
      })?.y
    )
    let region = CGRect(
      x: insets.left,
      y: insets.top + CGFloat(contentRow) * metrics.cellHeight,
      width: metrics.cellWidth * 4,
      height: metrics.cellHeight
    )
    return try maximumInternalInkGap(in: pixels, region: region)
  }

  private func maximumInternalInkGap(
    in pixels: PixelBuffer,
    region: CGRect
  ) throws -> Int {
    let xRange =
      max(
        0, Int(floor(region.minX)))..<min(
        pixels.width,
        Int(ceil(region.maxX))
      )
    let yRange =
      max(
        0, Int(floor(region.minY)))..<min(
        pixels.height,
        Int(ceil(region.maxY))
      )
    let inkedColumns = xRange.filter { x in
      yRange.contains { y in
        let pixel = pixels.pixel(x: x, y: y)
        return pixel[0] < 166 || pixel[1] < 166 || pixel[2] < 166
      }
    }
    let firstInk = try XCTUnwrap(inkedColumns.first)
    let lastInk = try XCTUnwrap(inkedColumns.last)
    let inked = Set(inkedColumns)
    var longestGap = 0
    var currentGap = 0
    for x in (firstInk + 1)..<lastInk {
      if inked.contains(x) {
        longestGap = max(longestGap, currentGap)
        currentGap = 0
      } else {
        currentGap += 1
      }
    }
    return max(longestGap, currentGap)
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

  private func pixelsContain(
    _ pixels: [UInt8],
    width: Int,
    rect: SIMD4<Float>,
    where predicate: ([UInt8]) -> Bool
  ) -> Bool {
    let height = pixels.count / (width * 4)
    let minX = max(0, Int(rect.x))
    let maxX = min(width, Int(rect.x + rect.z))
    let minY = max(0, Int(rect.y))
    let maxY = min(height, Int(rect.y + rect.w))
    for y in minY..<maxY {
      for x in minX..<maxX {
        let offset = (y * width + x) * 4
        if predicate(Array(pixels[offset..<(offset + 4)])) {
          return true
        }
      }
    }
    return false
  }

  private func firstPixelCoordinate(
    _ pixels: [UInt8],
    width: Int,
    rect: CGRect,
    where predicate: ([UInt8]) -> Bool
  ) -> (x: Int, y: Int)? {
    let height = pixels.count / (width * 4)
    let minX = max(0, Int(rect.minX))
    let maxX = min(width, Int(rect.maxX))
    let minY = max(0, Int(rect.minY))
    let maxY = min(height, Int(rect.maxY))
    for y in minY..<maxY {
      for x in minX..<maxX {
        let offset = (y * width + x) * 4
        let pixel = Array(pixels[offset..<(offset + 4)])
        if predicate(pixel) {
          return (x, y)
        }
      }
    }
    return nil
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
