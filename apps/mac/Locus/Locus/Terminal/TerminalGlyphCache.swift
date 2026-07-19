import CoreGraphics
import CoreText
import Foundation

@MainActor
final class TerminalGlyphCache {
  struct Key: Hashable {
    var fontIndex: Int
    var glyph: CGGlyph
    var shiftBucket: UInt8
  }

  struct Entry: Equatable {
    var region: TerminalGlyphAtlas.Region
    var width: UInt32
    var height: UInt32
    var offsetX: Int32
    var offsetY: Int32
    var isColor: Bool

    static let blank = Entry(
      region: TerminalGlyphAtlas.Region(x: 0, y: 0, width: 0, height: 0),
      width: 0,
      height: 0,
      offsetX: 0,
      offsetY: 0,
      isColor: false
    )
  }

  private static let maximumAtlasSize: UInt32 = 4_096

  private var scale: CGFloat
  private let initialAtlasSize: UInt32
  private var fonts: [CTFont] = []
  private var entries: [Key: Entry] = [:]
  private(set) var grayscaleAtlas: TerminalGlyphAtlas
  private(set) var colorAtlas: TerminalGlyphAtlas?
  private(set) var rasterizationCount = 0

  init(scale: CGFloat, initialAtlasSize: UInt32 = 512) {
    precondition(scale > 0)
    precondition(initialAtlasSize >= 2)
    self.scale = scale
    self.initialAtlasSize = initialAtlasSize
    self.grayscaleAtlas = TerminalGlyphAtlas(
      size: initialAtlasSize,
      format: .grayscale
    )
  }

  func fontIndex(for font: CTFont) -> Int {
    if let index = fonts.firstIndex(where: { CFEqual($0, font) }) {
      return index
    }
    fonts.append(font)
    return fonts.count - 1
  }

  func glyph(font: CTFont, glyph: CGGlyph) -> Entry {
    let fontIndex = fontIndex(for: font)
    return self.glyph(fontIndex: fontIndex, font: font, glyph: glyph)
  }

  func glyph(fontIndex: Int, font: CTFont, glyph: CGGlyph) -> Entry {
    // v1 deliberately has a single horizontal subpixel bucket. Keeping the
    // bucket in the key avoids an API migration when M2 adds quantized shifts.
    let key = Key(fontIndex: fontIndex, glyph: glyph, shiftBucket: 0)
    if let entry = entries[key] {
      return entry
    }

    rasterizationCount &+= 1
    guard
      let bitmap = TerminalGlyphRasterizer.rasterize(
        font: font,
        glyph: glyph,
        scale: scale,
        subpixelShift: 0
      )
    else {
      entries[key] = .blank
      return .blank
    }

    let atlas = atlas(forColorGlyph: bitmap.isColor)
    guard
      let region = reserve(
        width: bitmap.width,
        height: bitmap.height,
        in: atlas,
        isColor: bitmap.isColor
      )
    else {
      // A single glyph larger than the maximum atlas is not useful to the
      // terminal grid. Cache it as blank instead of retrying every frame.
      let blank = Entry(
        region: .init(x: 0, y: 0, width: 0, height: 0),
        width: 0,
        height: 0,
        offsetX: bitmap.offsetX,
        offsetY: bitmap.offsetY,
        isColor: bitmap.isColor
      )
      entries[key] = blank
      return blank
    }

    atlas.set(region: region, data: bitmap.bytes)
    let entry = Entry(
      region: region,
      width: bitmap.width,
      height: bitmap.height,
      offsetX: bitmap.offsetX,
      offsetY: bitmap.offsetY,
      isColor: bitmap.isColor
    )
    entries[key] = entry
    return entry
  }

  func invalidate(scale: CGFloat) {
    precondition(scale > 0)
    self.scale = scale
    fonts.removeAll(keepingCapacity: true)
    entries.removeAll(keepingCapacity: true)
    grayscaleAtlas = TerminalGlyphAtlas(size: initialAtlasSize, format: .grayscale)
    colorAtlas = nil
  }

  private func atlas(forColorGlyph isColor: Bool) -> TerminalGlyphAtlas {
    guard isColor else {
      return grayscaleAtlas
    }
    if let colorAtlas {
      return colorAtlas
    }
    let atlas = TerminalGlyphAtlas(size: initialAtlasSize, format: .bgra)
    colorAtlas = atlas
    return atlas
  }

  private func reserve(
    width: UInt32,
    height: UInt32,
    in atlas: TerminalGlyphAtlas,
    isColor: Bool
  ) -> TerminalGlyphAtlas.Region? {
    while true {
      do {
        return try atlas.reserve(width: width, height: height)
      } catch TerminalGlyphAtlas.Error.atlasFull {
        if atlas.size < Self.maximumAtlasSize {
          let doubled = atlas.size.multipliedReportingOverflow(by: 2)
          let grownSize =
            doubled.overflow
            ? Self.maximumAtlasSize
            : min(doubled.partialValue, Self.maximumAtlasSize)
          atlas.grow(sizeNew: grownSize)
          continue
        }

        // Reaching 4096 is practically unreachable for a terminal working
        // set. Clearing one atlas can cause a one-frame re-rasterization storm,
        // which is preferable to unbounded texture growth.
        entries = entries.filter { $0.value.isColor != isColor }
        atlas.clear()
        return try? atlas.reserve(width: width, height: height)
      } catch {
        return nil
      }
    }
  }
}
