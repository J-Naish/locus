import AppKit
import CoreText
import Metal

struct TerminalSolidInstance {
  var rectPx: SIMD4<Float>
  var color: SIMD4<Float>
}

struct TerminalGlyphInstance {
  var rectPx: SIMD4<Float>
  var uv: SIMD4<Float>
  var color: SIMD4<Float>
  var flags: UInt32
  var padding0: UInt32 = 0
  var padding1: UInt32 = 0
  var padding2: UInt32 = 0
}

struct TerminalMetalScene {
  struct Row {
    var y: UInt16
    var shaped: TerminalShapedRow
    var runForegrounds: [SIMD4<Float>]
  }

  var viewSize: CGSize
  var scale: CGFloat
  var backgroundColor: SIMD4<Float>
  var rows: [Row]
  var selectionRects: [CGRect]
  var selectionColor: SIMD4<Float>
  var searchRects: [(rect: CGRect, color: SIMD4<Float>)]
  var linkUnderlineRects: [CGRect]
  var linkUnderlineColor: SIMD4<Float>
  var caretRect: CGRect?
  var caretColor: SIMD4<Float>
}

enum TerminalMetalColor {
  static func premultipliedSRGB(
    _ color: NSColor,
    alpha alphaMultiplier: CGFloat = 1
  ) -> SIMD4<Float> {
    guard let converted = color.usingColorSpace(.sRGB) else {
      return .zero
    }
    let alpha = converted.alphaComponent * alphaMultiplier
    return SIMD4(
      Float(converted.redComponent * alpha),
      Float(converted.greenComponent * alpha),
      Float(converted.blueComponent * alpha),
      Float(alpha)
    )
  }
}

@MainActor
struct TerminalForegroundColorCache {
  private struct Key: Hashable {
    var foreground: TerminalColor?
    var faint: Bool

    static func == (lhs: Key, rhs: Key) -> Bool {
      lhs.foreground == rhs.foreground && lhs.faint == rhs.faint
    }

    func hash(into hasher: inout Hasher) {
      if let foreground {
        hasher.combine(foreground.red)
        hasher.combine(foreground.green)
        hasher.combine(foreground.blue)
      } else {
        hasher.combine(UInt8.max)
      }
      hasher.combine(faint)
    }
  }

  private var memo: [Key: SIMD4<Float>] = [:]
  private(set) var missCountForTesting = 0

  mutating func color(for style: TerminalTextStyle) -> SIMD4<Float> {
    let resolved = style.resolvedColors.foreground
    let key = Key(
      foreground: resolved == .defaultForeground ? nil : resolved,
      faint: style.flags.contains(.faint)
    )
    if let cached = memo[key] {
      return cached
    }
    missCountForTesting &+= 1
    let color = key.foreground?.nsColor ?? .textColor
    let resolvedColor = TerminalMetalColor.premultipliedSRGB(
      key.faint ? color.withAlphaComponent(0.55) : color
    )
    memo[key] = resolvedColor
    return resolvedColor
  }

  mutating func clear() {
    memo.removeAll(keepingCapacity: true)
    missCountForTesting = 0
  }
}

struct TerminalMetalRenderTiming {
  var buildEncodeMilliseconds: Double
  var gpuMilliseconds: Double?
}

@MainActor
final class TerminalMetalRenderer {
  private struct Uniforms {
    var drawableSizePx: SIMD2<Float>
  }

  private struct GlyphDraft {
    var entry: TerminalGlyphCache.Entry
    var rectPx: SIMD4<Float>
    var color: SIMD4<Float>
  }

  private struct BufferSet {
    var segmentA: MTLBuffer?
    var glyphs: MTLBuffer?
    var segmentB: MTLBuffer?
  }

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let solidPipeline: MTLRenderPipelineState
  private let glyphPipeline: MTLRenderPipelineState
  private let metrics: TerminalCellMetrics
  private let insets: TerminalContentInsets
  private var glyphCache: TerminalGlyphCache?
  private var glyphCacheScale: CGFloat?
  private var grayscaleTexture: MTLTexture?
  private var colorTexture: MTLTexture?
  private var grayscaleModified = -1
  private var grayscaleResized = -1
  private var colorModified = -1
  private var colorResized = -1
  private var bufferRing = [BufferSet(), BufferSet(), BufferSet()]
  private var bufferRingIndex = 0

  private(set) var lastTiming: TerminalMetalRenderTiming?

  init?(
    device: MTLDevice,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets
  ) {
    guard
      let commandQueue = device.makeCommandQueue(),
      let library = try? device.makeDefaultLibrary(bundle: Bundle(for: Self.self)),
      let solidPipeline = Self.makePipeline(
        device: device,
        library: library,
        vertexName: "terminal_solid_vertex",
        fragmentName: "terminal_solid_fragment"
      ),
      let glyphPipeline = Self.makePipeline(
        device: device,
        library: library,
        vertexName: "terminal_glyph_vertex",
        fragmentName: "terminal_glyph_fragment"
      )
    else {
      return nil
    }
    self.device = device
    self.commandQueue = commandQueue
    self.solidPipeline = solidPipeline
    self.glyphPipeline = glyphPipeline
    self.metrics = metrics
    self.insets = insets
  }

  func render(
    scene: TerminalMetalScene,
    into texture: MTLTexture,
    waitUntilCompleted: Bool
  ) -> Bool {
    guard
      scene.scale > 0,
      scene.viewSize.width > 0,
      scene.viewSize.height > 0,
      texture.pixelFormat == .bgra8Unorm,
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      return false
    }
    let started = CFAbsoluteTimeGetCurrent()
    prepareGlyphCache(scale: scene.scale)
    guard let glyphCache else {
      return false
    }

    var segmentA: [TerminalSolidInstance] = []
    var segmentB: [TerminalSolidInstance] = []
    var glyphDrafts: [GlyphDraft] = []
    let runEstimate = scene.rows.reduce(into: 0) { $0 += $1.shaped.runs.count }
    segmentA.reserveCapacity(
      scene.rows.count * 2 + scene.selectionRects.count + scene.searchRects.count)
    segmentB.reserveCapacity(
      runEstimate + scene.linkUnderlineRects.count + (scene.caretRect == nil ? 0 : 1))
    glyphDrafts.reserveCapacity(runEstimate * 8)
    buildInstances(
      scene: scene,
      glyphCache: glyphCache,
      segmentA: &segmentA,
      glyphDrafts: &glyphDrafts,
      segmentB: &segmentB
    )
    let glyphs = finishGlyphInstances(glyphDrafts, cache: glyphCache)
    guard synchronizeAtlasTextures(cache: glyphCache) else {
      return false
    }

    bufferRingIndex = (bufferRingIndex + 1) % bufferRing.count
    bufferRing[bufferRingIndex].segmentA = upload(
      segmentA,
      reusing: bufferRing[bufferRingIndex].segmentA
    )
    bufferRing[bufferRingIndex].glyphs = upload(
      glyphs,
      reusing: bufferRing[bufferRingIndex].glyphs
    )
    bufferRing[bufferRingIndex].segmentB = upload(
      segmentB,
      reusing: bufferRing[bufferRingIndex].segmentB
    )

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: Double(scene.backgroundColor.x),
      green: Double(scene.backgroundColor.y),
      blue: Double(scene.backgroundColor.z),
      alpha: Double(scene.backgroundColor.w)
    )
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      return false
    }
    var uniforms = Uniforms(
      drawableSizePx: SIMD2(Float(texture.width), Float(texture.height))
    )
    encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    encodeSolids(
      segmentA,
      buffer: bufferRing[bufferRingIndex].segmentA,
      encoder: encoder
    )
    encodeGlyphs(
      glyphs,
      buffer: bufferRing[bufferRingIndex].glyphs,
      encoder: encoder
    )
    encodeSolids(
      segmentB,
      buffer: bufferRing[bufferRingIndex].segmentB,
      encoder: encoder
    )
    encoder.endEncoding()
    commandBuffer.commit()
    let committed = CFAbsoluteTimeGetCurrent()
    if waitUntilCompleted {
      commandBuffer.waitUntilCompleted()
    }
    let gpuMilliseconds: Double?
    if waitUntilCompleted, commandBuffer.status == .completed,
      commandBuffer.gpuEndTime >= commandBuffer.gpuStartTime
    {
      gpuMilliseconds = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
    } else {
      gpuMilliseconds = nil
    }
    lastTiming = TerminalMetalRenderTiming(
      buildEncodeMilliseconds: (committed - started) * 1_000,
      gpuMilliseconds: gpuMilliseconds
    )
    return waitUntilCompleted
      ? commandBuffer.status == .completed && commandBuffer.error == nil
      : true
  }

  func invalidateGlyphCache(scale: CGFloat) {
    if let glyphCache {
      glyphCache.invalidate(scale: scale)
    } else {
      glyphCache = TerminalGlyphCache(scale: scale)
    }
    glyphCacheScale = scale
    resetAtlasSynchronization()
  }

  static func devicePixelRect(
    _ rect: CGRect,
    viewSize: CGSize,
    scale: CGFloat
  ) -> SIMD4<Float> {
    SIMD4(
      Float(rect.minX * scale),
      Float((viewSize.height - rect.minY - rect.height) * scale),
      Float(rect.width * scale),
      Float(rect.height * scale)
    )
  }

  private func buildInstances(
    scene: TerminalMetalScene,
    glyphCache: TerminalGlyphCache,
    segmentA: inout [TerminalSolidInstance],
    glyphDrafts: inout [GlyphDraft],
    segmentB: inout [TerminalSolidInstance]
  ) {
    for row in scene.rows {
      for fill in row.shaped.backgroundFills {
        // Mirrors TerminalPaneView.drawBackgrounds (:2227-2243).
        let rect = CGRect(
          x: insets.left + CGFloat(fill.startColumn) * metrics.cellWidth,
          y: scene.viewSize.height - (insets.top + CGFloat(row.y) * metrics.cellHeight)
            - metrics.cellHeight,
          width: CGFloat(fill.cellCount) * metrics.cellWidth,
          height: metrics.cellHeight
        )
        segmentA.append(
          solid(
            rect: rect,
            color: TerminalMetalColor.premultipliedSRGB(fill.color),
            scene: scene
          ))
      }
    }
    for rect in scene.selectionRects {
      segmentA.append(solid(rect: rect, color: scene.selectionColor, scene: scene))
    }
    for item in scene.searchRects {
      segmentA.append(solid(rect: item.rect, color: item.color, scene: scene))
    }

    for row in scene.rows {
      // Mirrors TerminalPaneView.drawText baseline (:2255) and rowTopOffset (:512).
      let baselineY =
        scene.viewSize.height
        - (insets.top + CGFloat(row.y) * metrics.cellHeight)
        - metrics.baselineOffset
      for (runIndex, shapedRun) in row.shaped.runs.enumerated() {
        guard runIndex < row.runForegrounds.count else {
          continue
        }
        let foreground = row.runForegrounds[runIndex]
        for batch in shapedRun.glyphBatches {
          let fontIndex = glyphCache.fontIndex(for: batch.font)
          for (glyph, position) in zip(batch.glyphs, batch.positions) {
            let entry = glyphCache.glyph(
              fontIndex: fontIndex,
              font: batch.font,
              glyph: glyph
            )
            guard entry.width > 0, entry.height > 0 else {
              continue
            }
            let originX = position.x
            let originY = baselineY + position.y
            let left: CGFloat
            let width: CGFloat
            if let scaleX = batch.overflowScaleX, let anchor = batch.overflowAnchorX {
              // Mirrors the CG translate-scale-translate overflow CTM (:2574-2577).
              left = anchor + scaleX * (originX + CGFloat(entry.offsetX) / scene.scale - anchor)
              width = scaleX * CGFloat(entry.width)
            } else {
              left = originX + CGFloat(entry.offsetX) / scene.scale
              width = CGFloat(entry.width)
            }
            let bottom = originY + CGFloat(entry.offsetY) / scene.scale
            let xPx = round(left * scene.scale)
            let yTopPx =
              round((scene.viewSize.height - bottom) * scene.scale)
              - CGFloat(entry.height)
            glyphDrafts.append(
              GlyphDraft(
                entry: entry,
                rectPx: SIMD4(
                  Float(xPx),
                  Float(yTopPx),
                  Float(width),
                  Float(entry.height)
                ),
                color: foreground
              ))
          }
        }
      }
    }

    // Unlike CG (:2583), Metal draws all glyphs before all decorations. The
    // only observable difference is italic ink overhanging a neighboring
    // run's underline; keeping three batches avoids per-run draw calls.
    for row in scene.rows {
      let baselineY =
        scene.viewSize.height
        - (insets.top + CGFloat(row.y) * metrics.cellHeight)
        - metrics.baselineOffset
      for (runIndex, shapedRun) in row.shaped.runs.enumerated() {
        guard runIndex < row.runForegrounds.count else {
          continue
        }
        let run = shapedRun.run
        let foreground = row.runForegrounds[runIndex]
        let font = metrics.font(for: run.style.flags) as CTFont
        let x = insets.left + CGFloat(run.startColumn) * metrics.cellWidth
        let width = CGFloat(run.cellCount) * metrics.cellWidth
        let thickness = max(1, CGFloat(CTFontGetUnderlineThickness(font)))
        if run.style.flags.contains(.underline) {
          let rect = CGRect(
            x: x,
            y: baselineY + CGFloat(CTFontGetUnderlinePosition(font)),
            width: width,
            height: thickness
          )
          segmentB.append(solid(rect: rect, color: foreground, scene: scene))
        }
        if run.style.flags.contains(.strikethrough) {
          let rect = CGRect(
            x: x,
            y: baselineY + CGFloat(CTFontGetXHeight(font)) * 0.5,
            width: width,
            height: thickness
          )
          segmentB.append(solid(rect: rect, color: foreground, scene: scene))
        }
      }
    }
    for rect in scene.linkUnderlineRects {
      segmentB.append(solid(rect: rect, color: scene.linkUnderlineColor, scene: scene))
    }
    if let caretRect = scene.caretRect {
      segmentB.append(solid(rect: caretRect, color: scene.caretColor, scene: scene))
    }
  }

  private func finishGlyphInstances(
    _ drafts: [GlyphDraft],
    cache: TerminalGlyphCache
  ) -> [TerminalGlyphInstance] {
    let graySize = Float(cache.grayscaleAtlas.size)
    let colorSize = Float(cache.colorAtlas?.size ?? cache.grayscaleAtlas.size)
    return drafts.map { draft in
      let size = draft.entry.isColor ? colorSize : graySize
      let region = draft.entry.region
      return TerminalGlyphInstance(
        rectPx: draft.rectPx,
        uv: SIMD4(
          Float(region.x) / size,
          Float(region.y) / size,
          Float(region.x + region.width) / size,
          Float(region.y + region.height) / size
        ),
        color: draft.color,
        flags: draft.entry.isColor ? 1 : 0
      )
    }
  }

  private func solid(
    rect: CGRect,
    color: SIMD4<Float>,
    scene: TerminalMetalScene
  ) -> TerminalSolidInstance {
    TerminalSolidInstance(
      rectPx: Self.devicePixelRect(rect, viewSize: scene.viewSize, scale: scene.scale),
      color: color
    )
  }

  private func prepareGlyphCache(scale: CGFloat) {
    guard glyphCacheScale != scale else {
      return
    }
    invalidateGlyphCache(scale: scale)
  }

  private func synchronizeAtlasTextures(cache: TerminalGlyphCache) -> Bool {
    guard
      synchronize(
        atlas: cache.grayscaleAtlas,
        pixelFormat: .r8Unorm,
        texture: &grayscaleTexture,
        lastModified: &grayscaleModified,
        lastResized: &grayscaleResized
      ),
      let grayscaleTexture
    else {
      return false
    }
    if let colorAtlas = cache.colorAtlas {
      guard
        synchronize(
          atlas: colorAtlas,
          pixelFormat: .bgra8Unorm,
          texture: &colorTexture,
          lastModified: &colorModified,
          lastResized: &colorResized
        )
      else {
        return false
      }
    } else {
      colorTexture = grayscaleTexture
      colorModified = -1
      colorResized = -1
    }
    return colorTexture != nil
  }

  private func synchronize(
    atlas: TerminalGlyphAtlas,
    pixelFormat: MTLPixelFormat,
    texture: inout MTLTexture?,
    lastModified: inout Int,
    lastResized: inout Int
  ) -> Bool {
    if texture == nil || atlas.resized != lastResized {
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: Int(atlas.size),
        height: Int(atlas.size),
        mipmapped: false
      )
      descriptor.storageMode = .shared
      descriptor.usage = .shaderRead
      texture = device.makeTexture(descriptor: descriptor)
      lastResized = atlas.resized
      lastModified = -1
    }
    guard let texture else {
      return false
    }
    if atlas.modified != lastModified {
      atlas.data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else {
          return
        }
        texture.replace(
          region: MTLRegionMake2D(0, 0, Int(atlas.size), Int(atlas.size)),
          mipmapLevel: 0,
          withBytes: baseAddress,
          bytesPerRow: Int(atlas.size) * atlas.format.depth
        )
      }
      lastModified = atlas.modified
    }
    return true
  }

  private func resetAtlasSynchronization() {
    grayscaleTexture = nil
    colorTexture = nil
    grayscaleModified = -1
    grayscaleResized = -1
    colorModified = -1
    colorResized = -1
  }

  private func upload<Value>(_ values: [Value], reusing buffer: MTLBuffer?) -> MTLBuffer? {
    guard !values.isEmpty else {
      return buffer
    }
    let required = values.count * MemoryLayout<Value>.stride
    let result: MTLBuffer
    if let buffer, buffer.length >= required {
      result = buffer
    } else {
      guard let created = device.makeBuffer(length: max(required, 256), options: .storageModeShared)
      else {
        return nil
      }
      result = created
    }
    values.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return
      }
      result.contents().copyMemory(from: baseAddress, byteCount: bytes.count)
    }
    return result
  }

  private func encodeSolids(
    _ instances: [TerminalSolidInstance],
    buffer: MTLBuffer?,
    encoder: MTLRenderCommandEncoder
  ) {
    guard !instances.isEmpty, let buffer else {
      return
    }
    encoder.setRenderPipelineState(solidPipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.drawPrimitives(
      type: .triangleStrip,
      vertexStart: 0,
      vertexCount: 4,
      instanceCount: instances.count
    )
  }

  private func encodeGlyphs(
    _ instances: [TerminalGlyphInstance],
    buffer: MTLBuffer?,
    encoder: MTLRenderCommandEncoder
  ) {
    guard
      !instances.isEmpty,
      let buffer,
      let grayscaleTexture,
      let colorTexture
    else {
      return
    }
    encoder.setRenderPipelineState(glyphPipeline)
    encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    encoder.setFragmentTexture(grayscaleTexture, index: 0)
    encoder.setFragmentTexture(colorTexture, index: 1)
    encoder.drawPrimitives(
      type: .triangleStrip,
      vertexStart: 0,
      vertexCount: 4,
      instanceCount: instances.count
    )
  }

  private static func makePipeline(
    device: MTLDevice,
    library: MTLLibrary,
    vertexName: String,
    fragmentName: String
  ) -> MTLRenderPipelineState? {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: vertexName)
    descriptor.fragmentFunction = library.makeFunction(name: fragmentName)
    let attachment = descriptor.colorAttachments[0]
    attachment?.pixelFormat = .bgra8Unorm
    attachment?.isBlendingEnabled = true
    attachment?.sourceRGBBlendFactor = .one
    attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment?.sourceAlphaBlendFactor = .one
    attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try? device.makeRenderPipelineState(descriptor: descriptor)
  }
}
