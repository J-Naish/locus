import AppKit
import CoreGraphics
import CoreText

// Rasterization recipe adapted from ghostty src/font/face/coretext.zig
// renderGlyph (:289-567).
struct TerminalRasterizedBitmap: Equatable {
  var width: UInt32
  var height: UInt32
  var offsetX: Int32
  var offsetY: Int32
  var isColor: Bool
  var bytes: [UInt8]
}

enum TerminalGlyphRasterizer {
  static func rasterize(
    font: CTFont,
    glyph: CGGlyph,
    scale: CGFloat,
    subpixelShift: CGFloat
  ) -> TerminalRasterizedBitmap? {
    precondition(scale > 0)

    var glyph = glyph
    let bounds = CTFontGetBoundingRectsForGlyphs(
      font,
      .horizontal,
      &glyph,
      nil,
      1
    )
    let width = bounds.width * scale
    let height = bounds.height * scale
    guard width >= 0.25, height >= 0.25 else {
      return nil
    }

    let x = bounds.origin.x * scale + subpixelShift
    let y = bounds.origin.y * scale
    let pixelX = floor(x)
    let pixelY = floor(y)
    let fractionalX = x - pixelX
    let fractionalY = y - pixelY
    let pixelWidth = Int(ceil(width + fractionalX)) + 2
    let pixelHeight = Int(ceil(height + fractionalY)) + 2
    guard pixelWidth > 0, pixelHeight > 0,
      pixelWidth <= Int(UInt32.max), pixelHeight <= Int(UInt32.max)
    else {
      return nil
    }

    // v1 uses the font-level trait. Per-glyph sbix probing, as done by
    // ghostty's isColorGlyph, is deliberately deferred until the renderer
    // needs mixed monochrome/color glyphs from one font.
    let isColor = CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
    let depth = isColor ? 4 : 1
    let bytesPerRow = pixelWidth * depth
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)

    let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
      let context: CGContext?
      if isColor {
        // ghostty renders color glyphs into Display P3. Locus stays in sRGB
        // until the complete Metal pipeline has a single audited color space.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
          return false
        }
        let bitmapInfo =
          CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.premultipliedFirst.rawValue
        context = CGContext(
          data: storage.baseAddress,
          width: pixelWidth,
          height: pixelHeight,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        )
      } else {
        // The current Swift overlay no longer accepts the null color space
        // used by Core Graphics' alpha-only C initializer. A one-component
        // device-gray context has the same byte layout and zero/ink semantics
        // required by the R8 atlas.
        context = CGContext(
          data: storage.baseAddress,
          width: pixelWidth,
          height: pixelHeight,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
      }
      guard let context else {
        return false
      }

      context.clear(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
      context.setAllowsFontSmoothing(true)
      context.setShouldSmoothFonts(false)
      context.setAllowsFontSubpixelPositioning(true)
      context.setShouldSubpixelPositionFonts(true)
      context.setAllowsFontSubpixelQuantization(false)
      context.setShouldSubpixelQuantizeFonts(false)
      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      if !isColor {
        context.setFillColor(gray: 1, alpha: 1)
      }

      // Unlike ghostty's conditional smoothing pad, Locus always leaves one
      // transparent pixel around a glyph. M2 may scale EAW-condensed quads at
      // non-texel-aligned positions, where bilinear filtering must not sample
      // a neighboring atlas entry.
      context.translateBy(x: fractionalX + 1, y: fractionalY + 1)
      context.scaleBy(x: scale, y: scale)
      var position = CGPoint(x: -bounds.origin.x, y: -bounds.origin.y)
      CTFontDrawGlyphs(font, &glyph, &position, 1, context)
      return true
    }
    guard rendered else {
      return nil
    }

    return TerminalRasterizedBitmap(
      width: UInt32(pixelWidth),
      height: UInt32(pixelHeight),
      offsetX: Int32(clamping: Int(pixelX) - 1),
      offsetY: Int32(clamping: Int(pixelY) - 1),
      isColor: isColor,
      bytes: bytes
    )
  }
}
