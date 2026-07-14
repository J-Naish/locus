import AppKit
import CoreText
import XCTest

@testable import Locus

@MainActor
final class TerminalGlyphCacheTests: XCTestCase {
  private let scale: CGFloat = 2

  func testRasterizingAProducesGrayscaleInk() throws {
    let font = terminalTestFont()
    let glyph = try glyph(for: "A", font: font)

    let bitmap = try XCTUnwrap(
      TerminalGlyphRasterizer.rasterize(
        font: font,
        glyph: glyph,
        scale: scale,
        subpixelShift: 0
      )
    )

    XCTAssertGreaterThan(bitmap.width, 2)
    XCTAssertGreaterThan(bitmap.height, 2)
    XCTAssertFalse(bitmap.isColor)
    XCTAssertTrue(bitmap.bytes.contains { $0 > 128 })
  }

  func testRasterizationIsDeterministic() throws {
    let font = terminalTestFont()
    let glyph = try glyph(for: "A", font: font)

    let first = TerminalGlyphRasterizer.rasterize(
      font: font,
      glyph: glyph,
      scale: scale,
      subpixelShift: 0
    )
    let second = TerminalGlyphRasterizer.rasterize(
      font: font,
      glyph: glyph,
      scale: scale,
      subpixelShift: 0
    )

    XCTAssertEqual(first, second)
  }

  func testSpaceRasterizesAsBlank() throws {
    let font = terminalTestFont()
    let glyph = try glyph(for: " ", font: font)

    XCTAssertNil(
      TerminalGlyphRasterizer.rasterize(
        font: font,
        glyph: glyph,
        scale: scale,
        subpixelShift: 0
      )
    )
  }

  func testRasterizedBitmapKeepsOnePixelTransparentBorder() throws {
    let font = terminalTestFont()
    let glyph = try glyph(for: "A", font: font)
    let bitmap = try XCTUnwrap(
      TerminalGlyphRasterizer.rasterize(
        font: font,
        glyph: glyph,
        scale: scale,
        subpixelShift: 0
      )
    )

    XCTAssertTrue(outerRingIsTransparent(bitmap))
  }

  func testGlyphCacheHitReusesRegionWithoutRasterizing() throws {
    let font = terminalTestFont()
    let glyph = try glyph(for: "A", font: font)
    let cache = TerminalGlyphCache(scale: scale)

    let first = cache.glyph(font: font, glyph: glyph)
    let second = cache.glyph(font: font, glyph: glyph)

    XCTAssertEqual(first.region, second.region)
    XCTAssertEqual(cache.rasterizationCount, 1)
  }

  func testFontRegistryDistinguishesRegularAndBold() {
    let metrics = TerminalCellMetrics()
    let cache = TerminalGlyphCache(scale: scale)
    let regular = metrics.font as CTFont
    let bold = metrics.boldFont as CTFont

    let regularIndex = cache.fontIndex(for: regular)
    let repeatedRegularIndex = cache.fontIndex(for: regular)
    let boldIndex = cache.fontIndex(for: bold)

    XCTAssertEqual(regularIndex, repeatedRegularIndex)
    XCTAssertNotEqual(regularIndex, boldIndex)
  }

  func testEmojiUsesColorAtlas() throws {
    let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 13, nil)
    let glyph = try glyph(for: "😀", font: font)
    let cache = TerminalGlyphCache(scale: scale)

    let entry = cache.glyph(font: font, glyph: glyph)
    let atlas = try XCTUnwrap(cache.colorAtlas)
    let bytes = bytes(in: entry.region, atlas: atlas)

    XCTAssertTrue(entry.isColor)
    XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 })
    var containsColorPixel = false
    for index in stride(from: 0, to: bytes.count - 3, by: 4) {
      let blue = bytes[index]
      let green = bytes[index + 1]
      let red = bytes[index + 2]
      if blue != green || green != red {
        containsColorPixel = true
        break
      }
    }
    XCTAssertTrue(containsColorPixel)
  }

  func testSmallAtlasGrowsAndPreservesFirstGlyph() throws {
    let font = terminalTestFont()
    let cache = TerminalGlyphCache(scale: scale, initialAtlasSize: 64)
    let firstGlyph = try glyph(for: "A", font: font)
    let firstBitmap = try XCTUnwrap(
      TerminalGlyphRasterizer.rasterize(
        font: font,
        glyph: firstGlyph,
        scale: scale,
        subpixelShift: 0
      )
    )
    let firstEntry = cache.glyph(font: font, glyph: firstGlyph)

    for character in "BCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789" {
      _ = cache.glyph(font: font, glyph: try glyph(for: String(character), font: font))
    }

    XCTAssertGreaterThan(cache.grayscaleAtlas.size, 64)
    XCTAssertGreaterThan(cache.grayscaleAtlas.resized, 0)
    XCTAssertEqual(bytes(in: firstEntry.region, atlas: cache.grayscaleAtlas), firstBitmap.bytes)
  }

  private func terminalTestFont() -> CTFont {
    NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) as CTFont
  }

  private func glyph(for text: String, font: CTFont) throws -> CGGlyph {
    let attributed = NSAttributedString(
      string: text,
      attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    guard let run = runs.first, CTRunGetGlyphCount(run) > 0 else {
      throw TerminalGlyphTestError.missingGlyph(text)
    }
    var glyph: CGGlyph = 0
    CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
    return glyph
  }

  private func outerRingIsTransparent(_ bitmap: TerminalRasterizedBitmap) -> Bool {
    let depth = bitmap.isColor ? 4 : 1
    let width = Int(bitmap.width)
    let height = Int(bitmap.height)
    let bytesPerRow = width * depth

    for x in 0..<width {
      for channel in 0..<depth {
        if bitmap.bytes[x * depth + channel] != 0
          || bitmap.bytes[(height - 1) * bytesPerRow + x * depth + channel] != 0
        {
          return false
        }
      }
    }
    for y in 0..<height {
      for channel in 0..<depth {
        if bitmap.bytes[y * bytesPerRow + channel] != 0
          || bitmap.bytes[y * bytesPerRow + (width - 1) * depth + channel] != 0
        {
          return false
        }
      }
    }
    return true
  }

  private func bytes(
    in region: TerminalGlyphAtlas.Region,
    atlas: TerminalGlyphAtlas
  ) -> [UInt8] {
    let depth = atlas.format.depth
    let atlasWidth = Int(atlas.size)
    let regionWidth = Int(region.width)
    var result: [UInt8] = []
    result.reserveCapacity(regionWidth * Int(region.height) * depth)
    for row in 0..<Int(region.height) {
      let start = ((Int(region.y) + row) * atlasWidth + Int(region.x)) * depth
      let end = start + regionWidth * depth
      result.append(contentsOf: atlas.data[start..<end])
    }
    return result
  }
}

private enum TerminalGlyphTestError: Error {
  case missingGlyph(String)
}
