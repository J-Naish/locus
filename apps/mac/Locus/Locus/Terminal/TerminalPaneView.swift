import AppKit
import Combine
import CoreText
import QuartzCore
import SwiftUI

struct TerminalGridSize: Equatable {
  let columns: UInt16
  let rows: UInt16
}

struct TerminalColor: Equatable {
  let red: UInt8
  let green: UInt8
  let blue: UInt8

  static let defaultForeground = TerminalColor(red: 0xC5, green: 0xC8, blue: 0xC6)
  static let defaultBackground = TerminalColor(red: 0x1D, green: 0x1F, blue: 0x21)

  init(red: UInt8, green: UInt8, blue: UInt8) {
    self.red = red
    self.green = green
    self.blue = blue
  }

  init(_ rgb: LocusTermRgb) {
    red = rgb.r
    green = rgb.g
    blue = rgb.b
  }

  var nsColor: NSColor {
    NSColor(
      red: CGFloat(red) / 255,
      green: CGFloat(green) / 255,
      blue: CGFloat(blue) / 255,
      alpha: 1
    )
  }
}

struct TerminalResolvedColors: Equatable {
  let foreground: TerminalColor
  let background: TerminalColor
}

struct TerminalTextStyle: Equatable {
  let foreground: TerminalColor
  let background: TerminalColor
  let flags: TerminalCellFlags

  init(foreground: TerminalColor, background: TerminalColor, flags: TerminalCellFlags) {
    self.foreground = foreground
    self.background = background
    self.flags = flags
  }

  init(_ cell: LocusTermCell) {
    foreground = TerminalColor(cell.fg)
    background = TerminalColor(cell.bg)
    flags = TerminalCellFlags(rawValue: cell.flags)
  }

  var resolvedColors: TerminalResolvedColors {
    if flags.contains(.inverse) {
      return TerminalResolvedColors(foreground: background, background: foreground)
    }
    return TerminalResolvedColors(foreground: foreground, background: background)
  }
}

struct TerminalCellMetrics {
  let font: NSFont
  let boldFont: NSFont
  let italicFont: NSFont
  let boldItalicFont: NSFont
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  let baselineOffset: CGFloat

  init(font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) {
    self.font = font
    let manager = NSFontManager.shared
    boldFont = manager.convert(font, toHaveTrait: .boldFontMask)
    italicFont = manager.convert(font, toHaveTrait: .italicFontMask)
    boldItalicFont = manager.convert(boldFont, toHaveTrait: .italicFontMask)

    let ctFont = font as CTFont
    cellWidth = ceil(Self.advance(for: "0", font: font))
    let ascent = CTFontGetAscent(ctFont)
    let descent = CTFontGetDescent(ctFont)
    let leading = CTFontGetLeading(ctFont)
    cellHeight = ceil(ascent + descent + leading)
    baselineOffset = ceil(ascent)
  }

  func advance(for text: String) -> CGFloat {
    Self.advance(for: text, font: font)
  }

  func font(for flags: TerminalCellFlags) -> NSFont {
    switch (flags.contains(.bold), flags.contains(.italic)) {
    case (true, true):
      return boldItalicFont
    case (true, false):
      return boldFont
    case (false, true):
      return italicFont
    case (false, false):
      return font
    }
  }

  static func gridSize(for size: CGSize, metrics: TerminalCellMetrics) -> TerminalGridSize {
    let columns = max(1, Int(floor(size.width / metrics.cellWidth)))
    let rows = max(1, Int(floor(size.height / metrics.cellHeight)))
    return TerminalGridSize(
      columns: UInt16(clamping: columns),
      rows: UInt16(clamping: rows)
    )
  }

  private static func advance(for text: String, font: NSFont) -> CGFloat {
    let attributed = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attributed)
    return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
  }
}

struct TerminalRenderableCell: Equatable {
  let text: String
  let cellCount: Int
  let style: TerminalTextStyle
}

struct TerminalTextRun: Equatable {
  let text: String
  let startColumn: Int
  let cellCount: Int
  let style: TerminalTextStyle
}

enum TerminalLineRunBuilder {
  static func runs(for cells: [TerminalRenderableCell]) -> [TerminalTextRun] {
    var runs: [TerminalTextRun] = []
    var currentText = ""
    var currentStyle: TerminalTextStyle?
    var currentStart = 0
    var currentCellCount = 0
    var column = 0

    func flush() {
      guard let style = currentStyle else {
        return
      }
      runs.append(
        TerminalTextRun(
          text: currentText,
          startColumn: currentStart,
          cellCount: currentCellCount,
          style: style
        )
      )
      currentText = ""
      currentStyle = nil
      currentCellCount = 0
    }

    for cell in cells {
      if currentStyle != cell.style {
        flush()
        currentStyle = cell.style
        currentStart = column
      }
      currentText += cell.text
      currentCellCount += cell.cellCount
      column += cell.cellCount
    }
    flush()
    return runs
  }
}

struct TerminalPane: NSViewRepresentable {
  let session: TerminalSession

  func makeNSView(context: Context) -> TerminalPaneView {
    TerminalPaneView(session: session)
  }

  func updateNSView(_ nsView: TerminalPaneView, context: Context) {
    nsView.session = session
  }
}

final class TerminalPaneView: NSView {
  var session: TerminalSession? {
    didSet {
      guard oldValue !== session else {
        return
      }
      subscribeToSession()
      updateTerminalSizeIfNeeded()
      hasPendingFrameChange = true
      needsDisplay = true
    }
  }

  private let metrics: TerminalCellMetrics
  private var cancellable: AnyCancellable?
  private var hasPendingFrameChange = true
  private var lastScheduledGeneration: UInt64?
  private var lastDrawnGeneration: UInt64?
  private var lastGridSize: TerminalGridSize?
  private var frameDisplayLink: CADisplayLink?

  override var acceptsFirstResponder: Bool { false }
  override var isOpaque: Bool { true }

  init(
    session: TerminalSession? = nil,
    metrics: TerminalCellMetrics = TerminalCellMetrics()
  ) {
    self.session = session
    self.metrics = metrics
    super.init(frame: .zero)
    wantsLayer = true
    subscribeToSession()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    MainActor.assumeIsolated {
      stopDisplayLink()
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      stopDisplayLink()
    } else {
      startDisplayLink()
    }
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateTerminalSizeIfNeeded()
  }

  override func layout() {
    super.layout()
    updateTerminalSizeIfNeeded()
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else {
      return
    }

    backgroundColor.setFill()
    dirtyRect.fill()

    guard let session else {
      return
    }

    session.withFrame { frame in
      draw(frame: frame, in: context)
    }
    lastDrawnGeneration = session.snapshot?.generation
  }

  override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapImageRep) else {
      super.cacheDisplay(in: rect, to: bitmapImageRep)
      return
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    draw(rect)
    NSGraphicsContext.restoreGraphicsState()
  }

  private func subscribeToSession() {
    cancellable = session?.objectWillChange.sink { [weak self] _ in
      self?.hasPendingFrameChange = true
    }
  }

  private func startDisplayLink() {
    guard frameDisplayLink == nil else {
      return
    }
    let link = displayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
    link.add(to: .main, forMode: .common)
    frameDisplayLink = link
  }

  private func stopDisplayLink() {
    frameDisplayLink?.invalidate()
    frameDisplayLink = nil
  }

  @objc private func displayLinkDidTick(_ link: CADisplayLink) {
    guard hasPendingFrameChange, let generation = session?.snapshot?.generation else {
      return
    }
    guard generation != lastScheduledGeneration else {
      hasPendingFrameChange = false
      return
    }

    var hasRenderableChange = true
    session?.withFrame { frame in
      hasRenderableChange = frame.dirtyKind != .none || lastDrawnGeneration == nil
    }
    guard hasRenderableChange else {
      hasPendingFrameChange = false
      lastScheduledGeneration = generation
      return
    }

    hasPendingFrameChange = false
    lastScheduledGeneration = generation
    needsDisplay = true
  }

  private func updateTerminalSizeIfNeeded() {
    guard bounds.width > 0, bounds.height > 0 else {
      return
    }

    let gridSize = TerminalCellMetrics.gridSize(for: bounds.size, metrics: metrics)
    guard gridSize != lastGridSize else {
      return
    }
    lastGridSize = gridSize
    session?.resize(columns: gridSize.columns, rows: gridSize.rows)
  }

  private var backgroundColor: NSColor {
    .textBackgroundColor
  }

  private func draw(frame: TerminalFrame, in context: CGContext) {
    frame.withRows { rows in
      frame.withCells { cells in
        frame.withGraphemes { graphemes in
          for row in rows {
            drawBackgrounds(row: row, cells: cells, in: context)
          }
          for row in rows {
            drawText(row: row, cells: cells, graphemes: graphemes, in: context)
          }
        }
      }
    }
    drawCursor(frame.cursor, in: context)
  }

  private func drawBackgrounds(
    row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>,
    in context: CGContext
  ) {
    let range = cellRange(for: row, cells: cells)
    guard !range.isEmpty else {
      return
    }

    var column = 0
    for cell in cells[range] {
      guard TerminalCellWidth(rawValue: cell.wide) != .spacerTail else {
        column += 1
        continue
      }

      let style = TerminalTextStyle(cell)
      let colors = style.resolvedColors
      let width = displayCellCount(for: cell)
      if colors.background != .defaultBackground {
        colors.background.nsColor.setFill()
        NSRect(
          x: CGFloat(column) * metrics.cellWidth,
          y: rowRectY(row.y),
          width: CGFloat(width) * metrics.cellWidth,
          height: metrics.cellHeight
        ).fill()
      }
      column += width
    }
  }

  private func drawText(
    row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>,
    graphemes: UnsafeBufferPointer<UInt32>,
    in context: CGContext
  ) {
    let range = cellRange(for: row, cells: cells)
    guard !range.isEmpty else {
      return
    }

    var renderableCells: [TerminalRenderableCell] = []
    renderableCells.reserveCapacity(range.count)
    for cell in cells[range] {
      guard TerminalCellWidth(rawValue: cell.wide) != .spacerTail else {
        continue
      }
      renderableCells.append(
        TerminalRenderableCell(
          text: text(for: cell, graphemes: graphemes),
          cellCount: displayCellCount(for: cell),
          style: TerminalTextStyle(cell)
        )
      )
    }

    let baselineFromTop = rowTopOffset(row.y) + metrics.baselineOffset
    for run in TerminalLineRunBuilder.runs(for: renderableCells) where !run.text.isEmpty {
      let attributed = attributedString(for: run)
      let line = CTLineCreateWithAttributedString(attributed)
      context.saveGState()
      context.textMatrix = .identity
      context.textPosition = CGPoint(
        x: CGFloat(run.startColumn) * metrics.cellWidth,
        y: bounds.height - baselineFromTop
      )
      CTLineDraw(line, context)
      context.restoreGState()
    }
  }

  private func attributedString(for run: TerminalTextRun) -> NSAttributedString {
    let colors = run.style.resolvedColors
    var foreground = nsColor(forForeground: colors.foreground)
    if run.style.flags.contains(.faint) {
      foreground = foreground.withAlphaComponent(0.55)
    }

    // TODO: blink, invisible, and overline require timing/decoration support.
    var attributes: [NSAttributedString.Key: Any] = [
      .font: metrics.font(for: run.style.flags),
      .foregroundColor: foreground,
    ]
    if run.style.flags.contains(.underline) {
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    if run.style.flags.contains(.strikethrough) {
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return NSAttributedString(string: run.text, attributes: attributes)
  }

  private func drawCursor(_ cursor: LocusTermCursor, in context: CGContext) {
    guard cursor.visible else {
      return
    }

    let cursorWidth = cursor.wide_tail ? metrics.cellWidth * 2 : metrics.cellWidth
    let cursorX =
      cursor.wide_tail
      ? CGFloat(cursor.x == 0 ? 0 : cursor.x - 1) * metrics.cellWidth
      : CGFloat(cursor.x) * metrics.cellWidth
    let cursorY = rowRectY(cursor.y)
    let rect: NSRect
    switch cursor.style {
    case 2:
      rect = NSRect(
        x: cursorX,
        y: cursorY + metrics.cellHeight - 2,
        width: cursorWidth,
        height: 2
      )
    case 3:
      rect = NSRect(x: cursorX, y: cursorY, width: 2, height: metrics.cellHeight)
    default:
      rect = NSRect(x: cursorX, y: cursorY, width: cursorWidth, height: metrics.cellHeight)
    }

    NSColor.textColor.withAlphaComponent(cursor.style == 1 ? 0.28 : 0.9).setFill()
    rect.fill()
  }

  private func cellRange(
    for row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>
  ) -> Range<Int> {
    let start = min(row.cell_start, cells.count)
    let end = min(row.cell_start + row.cell_count, cells.count)
    return start..<end
  }

  private func displayCellCount(for cell: LocusTermCell) -> Int {
    switch TerminalCellWidth(rawValue: cell.wide) {
    case .wide:
      return 2
    default:
      return 1
    }
  }

  private func text(
    for cell: LocusTermCell,
    graphemes: UnsafeBufferPointer<UInt32>
  ) -> String {
    var result = ""
    if cell.codepoint != 0, let scalar = UnicodeScalar(cell.codepoint) {
      result.unicodeScalars.append(scalar)
    } else {
      result = " "
    }

    let start = min(cell.grapheme_start, graphemes.count)
    let end = min(cell.grapheme_start + cell.grapheme_len, graphemes.count)
    if start < end {
      for codepoint in graphemes[start..<end] {
        if let scalar = UnicodeScalar(codepoint) {
          result.unicodeScalars.append(scalar)
        }
      }
    }
    return result
  }

  private func rowTopOffset(_ row: UInt16) -> CGFloat {
    CGFloat(row) * metrics.cellHeight
  }

  private func rowRectY(_ row: UInt16) -> CGFloat {
    bounds.height - rowTopOffset(row) - metrics.cellHeight
  }

  private func nsColor(forForeground color: TerminalColor) -> NSColor {
    color == .defaultForeground ? .textColor : color.nsColor
  }
}
