import AppKit
import CoreText
import Metal
import XCTest

@testable import Locus

@MainActor
final class TerminalMetalSmokeTests: XCTestCase {
  func testDeviceAvailable() {
    XCTAssertNotNil(MTLCreateSystemDefaultDevice())
  }

  func testGlyphPipelineCompiles() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

    let pipeline = try makePipeline(device: device)

    XCTAssertEqual(pipeline.device.registryID, device.registryID)
  }

  func testAtlasGlyphRendersOffscreen() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let pipeline = try makePipeline(device: device)
    let commandQueue = try XCTUnwrap(device.makeCommandQueue())
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
    let glyph = try glyph(for: "A", font: font)
    let cache = TerminalGlyphCache(scale: 2)
    let entry = cache.glyph(font: font, glyph: glyph)
    let atlas = cache.grayscaleAtlas
    XCTAssertGreaterThan(atlas.data.filter { $0 != 0 }.count, 10)

    let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .r8Unorm,
      width: Int(atlas.size),
      height: Int(atlas.size),
      mipmapped: false
    )
    atlasDescriptor.storageMode = .shared
    atlasDescriptor.usage = .shaderRead
    let atlasTexture = try XCTUnwrap(device.makeTexture(descriptor: atlasDescriptor))
    atlas.data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return
      }
      atlasTexture.replace(
        region: MTLRegionMake2D(0, 0, Int(atlas.size), Int(atlas.size)),
        mipmapLevel: 0,
        withBytes: baseAddress,
        bytesPerRow: Int(atlas.size) * atlas.format.depth
      )
    }

    let targetSize = 64
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: targetSize,
      height: targetSize,
      mipmapped: false
    )
    targetDescriptor.storageMode = .shared
    targetDescriptor.usage = [.renderTarget]
    let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
    let quadOrigin = SIMD2<Float>(16, 16)
    let quadSize = SIMD2<Float>(Float(entry.width), Float(entry.height))
    let vertices = quadVertices(
      origin: quadOrigin,
      size: quadSize,
      targetSize: Float(targetSize),
      region: entry.region,
      atlasSize: Float(atlas.size)
    )

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
    let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
    encoder.setRenderPipelineState(pipeline)
    vertices.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return
      }
      encoder.setVertexBytes(baseAddress, length: bytes.count, index: 0)
    }
    encoder.setFragmentTexture(atlasTexture, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    XCTAssertEqual(commandBuffer.status, .completed)
    XCTAssertNil(commandBuffer.error)

    var pixels = [UInt8](repeating: 0, count: targetSize * targetSize * 4)
    pixels.withUnsafeMutableBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return
      }
      target.getBytes(
        baseAddress,
        bytesPerRow: targetSize * 4,
        from: MTLRegionMake2D(0, 0, targetSize, targetSize),
        mipmapLevel: 0
      )
    }

    let minX = Int(quadOrigin.x)
    let minY = Int(quadOrigin.y)
    let maxX = min(targetSize, minX + Int(quadSize.x))
    let maxY = min(targetSize, minY + Int(quadSize.y))
    let hasWhitePixel = (minY..<maxY).contains { y in
      (minX..<maxX).contains { x in
        let offset = (y * targetSize + x) * 4
        return pixels[offset] > 0 || pixels[offset + 1] > 0 || pixels[offset + 2] > 0
      }
    }
    XCTAssertTrue(hasWhitePixel)
    for (x, y) in [
      (0, 0), (targetSize - 1, 0), (0, targetSize - 1),
      (targetSize - 1, targetSize - 1),
    ] {
      let offset = (y * targetSize + x) * 4
      XCTAssertEqual(Array(pixels[offset..<(offset + 3)]), [0, 0, 0])
    }
  }

  private func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
    let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "terminal_glyph_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "terminal_glyph_fragment")
    let attachment = descriptor.colorAttachments[0]
    attachment?.pixelFormat = .bgra8Unorm
    attachment?.isBlendingEnabled = true
    attachment?.sourceRGBBlendFactor = .one
    attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment?.sourceAlphaBlendFactor = .one
    attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private func glyph(for text: String, font: CTFont) throws -> CGGlyph {
    let attributed = NSAttributedString(
      string: text,
      attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    guard let run = runs.first, CTRunGetGlyphCount(run) > 0 else {
      throw TerminalMetalSmokeError.missingGlyph
    }
    var glyph: CGGlyph = 0
    CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
    return glyph
  }

  private func quadVertices(
    origin: SIMD2<Float>,
    size: SIMD2<Float>,
    targetSize: Float,
    region: TerminalGlyphAtlas.Region,
    atlasSize: Float
  ) -> [SIMD4<Float>] {
    let left = origin.x / targetSize * 2 - 1
    let right = (origin.x + size.x) / targetSize * 2 - 1
    let top = 1 - origin.y / targetSize * 2
    let bottom = 1 - (origin.y + size.y) / targetSize * 2
    let u0 = Float(region.x) / atlasSize
    let u1 = Float(region.x + region.width) / atlasSize
    let v0 = Float(region.y) / atlasSize
    let v1 = Float(region.y + region.height) / atlasSize
    return [
      SIMD4(left, top, u0, v0),
      SIMD4(left, bottom, u0, v1),
      SIMD4(right, bottom, u1, v1),
      SIMD4(left, top, u0, v0),
      SIMD4(right, bottom, u1, v1),
      SIMD4(right, top, u1, v0),
    ]
  }

  private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct GlyphVertexOut {
      float4 position [[position]];
      float2 uv;
    };

    vertex GlyphVertexOut terminal_glyph_vertex(
      uint vertexID [[vertex_id]],
      constant float4 *vertices [[buffer(0)]]) {
      GlyphVertexOut result;
      float4 vertexData = vertices[vertexID];
      result.position = float4(vertexData.xy, 0.0, 1.0);
      result.uv = vertexData.zw;
      return result;
    }

    fragment float4 terminal_glyph_fragment(
      GlyphVertexOut input [[stage_in]],
      texture2d<float> atlas [[texture(0)]]) {
      constexpr sampler glyphSampler(
        coord::normalized,
        address::clamp_to_zero,
        filter::linear);
      float alpha = atlas.sample(glyphSampler, input.uv).r;
      return float4(alpha, alpha, alpha, alpha);
    }
    """
}

private enum TerminalMetalSmokeError: Error {
  case missingGlyph
}
