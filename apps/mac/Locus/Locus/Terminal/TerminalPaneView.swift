import AppKit
import Carbon.HIToolbox
import Combine
import CoreText
import Metal
import QuartzCore
import SwiftUI

enum TerminalRenderBackend: Equatable {
  case coreGraphics
  case metal

  static func fromEnvironment(_ value: String?) -> TerminalRenderBackend {
    value == "cg" ? .coreGraphics : .metal
  }
}

struct TerminalGridSize: Equatable {
  let columns: UInt16
  let rows: UInt16
}

struct TerminalCellCoordinate: Equatable, Sendable {
  let column: UInt16
  let row: UInt16
}

struct TerminalContentInsets: Equatable {
  let top: CGFloat
  let left: CGFloat
  let bottom: CGFloat
  let right: CGFloat

  static let zero = TerminalContentInsets(top: 0, left: 0, bottom: 0, right: 0)
}

enum TerminalPaneLayoutMetrics {
  static let contentInsets = TerminalContentInsets(top: 10, left: 12, bottom: 10, right: 12)
}

private enum TerminalCursorMetrics {
  static let thickness: CGFloat = 2
  static let activeAlpha: CGFloat = 0.9
  static let inactiveAlpha: CGFloat = 0.4
}

enum TerminalCaretBlink {
  static let phaseDuration: TimeInterval = 0.6

  /// The frame's blinking flag mirrors DEC private mode 12, whose default is
  /// false and which shells never touch. The app treats a focused caret as
  /// blinking by default; the frame flag can only turn blinking ON (a DECSCUSR
  /// steady request cannot opt out until the core exposes an "explicitly set"
  /// marker).
  static let defaultBlinks = true

  static func effectiveBlinking(_ frameFlag: Bool) -> Bool {
    frameFlag || defaultBlinks
  }

  static func caretVisible(
    at time: TimeInterval,
    lastInput: TimeInterval,
    blinking: Bool
  ) -> Bool {
    guard blinking else {
      return true
    }
    let elapsed = max(0, time - lastInput)
    let phase = Int(floor(elapsed / phaseDuration))
    return phase.isMultiple(of: 2)
  }
}

enum TerminalCaretInvalidation {
  static func shouldInvalidate(
    previousDrawnVisible: Bool?,
    currentVisible: Bool,
    focused: Bool,
    blinking: Bool
  ) -> Bool {
    guard focused, blinking, let previousDrawnVisible else {
      return false
    }
    return previousDrawnVisible != currentVisible
  }

  static func invalidationRect(previous: NSRect?, current: NSRect?) -> NSRect? {
    switch (previous, current) {
    case (.some(let previous), .some(let current)):
      return previous.union(current)
    case (.some(let previous), .none):
      return previous
    case (.none, .some(let current)):
      return current
    case (.none, .none):
      return nil
    }
  }
}

private enum TerminalPaneTiming {
  static let resizeDebounce: Duration = .milliseconds(60)
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
  static let defaultWideGlyphFillRatio: CGFloat = 0.9
  private static let wideRegularPostScriptName = "HiraginoSans-W4"
  private static let wideBoldPostScriptName = "HiraginoSans-W6"
  private static let wideFontFamily = "Hiragino Sans"

  let font: NSFont
  let boldFont: NSFont
  let italicFont: NSFont
  let boldItalicFont: NSFont
  let wideFont: NSFont
  let wideBoldFont: NSFont
  let wideItalicFont: NSFont
  let wideBoldItalicFont: NSFont
  let cellWidth: CGFloat
  let cellHeight: CGFloat
  let baselineOffset: CGFloat

  init(
    font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
    wideGlyphFillRatio: CGFloat = Self.defaultWideGlyphFillRatio
  ) {
    self.font = font
    let manager = NSFontManager.shared
    boldFont = manager.convert(font, toHaveTrait: .boldFontMask)
    italicFont = manager.convert(font, toHaveTrait: .italicFontMask)
    boldItalicFont = manager.convert(boldFont, toHaveTrait: .italicFontMask)

    let ctFont = font as CTFont
    let resolvedCellWidth = ceil(Self.advance(for: "0", font: font))
    cellWidth = resolvedCellWidth
    let wideFontSize = wideGlyphFillRatio * 2 * resolvedCellWidth
    wideFont = Self.wideFont(
      postScriptName: Self.wideRegularPostScriptName,
      size: wideFontSize,
      fallback: font
    )
    wideBoldFont = Self.wideFont(
      postScriptName: Self.wideBoldPostScriptName,
      size: wideFontSize,
      fallback: boldFont
    )
    wideItalicFont = Self.wideFont(
      postScriptName: Self.wideRegularPostScriptName,
      size: wideFontSize,
      fallback: italicFont
    )
    wideBoldItalicFont = Self.wideFont(
      postScriptName: Self.wideBoldPostScriptName,
      size: wideFontSize,
      fallback: boldItalicFont
    )
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

  func wideFont(for flags: TerminalCellFlags) -> NSFont {
    switch (flags.contains(.bold), flags.contains(.italic)) {
    case (true, true):
      return wideBoldItalicFont
    case (true, false):
      return wideBoldFont
    case (false, true):
      return wideItalicFont
    case (false, false):
      return wideFont
    }
  }

  static func gridSize(
    for size: CGSize,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets = .zero
  ) -> TerminalGridSize {
    let contentWidth = max(0, size.width - insets.left - insets.right)
    let contentHeight = max(0, size.height - insets.top - insets.bottom)
    let columns = max(1, Int(floor(contentWidth / metrics.cellWidth)))
    let rows = max(1, Int(floor(contentHeight / metrics.cellHeight)))
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

  private static func wideFont(
    postScriptName: String,
    size: CGFloat,
    fallback: NSFont
  ) -> NSFont {
    guard
      let font = NSFont(name: postScriptName, size: size),
      font.familyName == wideFontFamily,
      font.fontName == postScriptName
    else {
      return fallback
    }
    return font
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
  let cells: [TerminalRenderableCell]
}

enum TerminalLineRunBuilder {
  static func runs(for cells: [TerminalRenderableCell]) -> [TerminalTextRun] {
    var runs: [TerminalTextRun] = []
    var currentText = ""
    var currentStyle: TerminalTextStyle?
    var currentStart = 0
    var currentCellCount = 0
    var currentCells: [TerminalRenderableCell] = []
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
          style: style,
          cells: currentCells
        )
      )
      currentText = ""
      currentStyle = nil
      currentCellCount = 0
      currentCells.removeAll(keepingCapacity: true)
    }

    for cell in cells {
      if currentStyle != cell.style {
        flush()
        currentStyle = cell.style
        currentStart = column
      }
      currentText += cell.text
      currentCellCount += cell.cellCount
      currentCells.append(cell)
      column += cell.cellCount
    }
    flush()
    return runs
  }
}

enum TerminalRowSignature {
  private static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037
  private static let fnvPrime: UInt64 = 1_099_511_628_211

  /// Materialized byte signature used only when a new cache entry is stored.
  static func signature(
    row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>,
    graphemes: UnsafeBufferPointer<UInt32>
  ) -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(min(row.cell_count, cells.count) * 32)
    _ = stream(row: row, cells: cells, graphemes: graphemes) { bytes in
      result.append(contentsOf: bytes)
      return true
    }
    return result
  }

  static func hash(
    row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>,
    graphemes: UnsafeBufferPointer<UInt32>
  ) -> UInt64 {
    var result = fnvOffsetBasis
    _ = stream(row: row, cells: cells, graphemes: graphemes) { bytes in
      for byte in bytes {
        result = (result ^ UInt64(byte)) &* fnvPrime
      }
      return true
    }
    return result
  }

  static func hash(signature: [UInt8]) -> UInt64 {
    signature.reduce(into: fnvOffsetBasis) { hash, byte in
      hash = (hash ^ UInt64(byte)) &* fnvPrime
    }
  }

  static func matches(
    _ signature: [UInt8],
    row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>,
    graphemes: UnsafeBufferPointer<UInt32>
  ) -> Bool {
    var cursor = 0
    let matched = stream(row: row, cells: cells, graphemes: graphemes) { bytes in
      guard cursor + bytes.count <= signature.count else {
        return false
      }
      for byte in bytes {
        guard signature[cursor] == byte else {
          return false
        }
        cursor += 1
      }
      return true
    }
    return matched && cursor == signature.count
  }

  private static func stream(
    row: LocusTermRow,
    cells: UnsafeBufferPointer<LocusTermCell>,
    graphemes: UnsafeBufferPointer<UInt32>,
    consume: (UnsafeRawBufferPointer) -> Bool
  ) -> Bool {
    func emit<Value: FixedWidthInteger>(_ value: Value) -> Bool {
      var littleEndian = value.littleEndian
      return withUnsafeBytes(of: &littleEndian, consume)
    }

    let start = min(row.cell_start, cells.count)
    let count = min(row.cell_count, cells.count - start)
    guard emit(UInt64(count)) else {
      return false
    }

    for cell in cells[start..<(start + count)] {
      guard
        emit(cell.codepoint),
        emit(cell.raw),
        emit(cell.fg.r),
        emit(cell.fg.g),
        emit(cell.fg.b),
        emit(cell.bg.r),
        emit(cell.bg.g),
        emit(cell.bg.b),
        emit(cell.flags),
        emit(cell.wide)
      else {
        return false
      }

      let graphemeStart = min(cell.grapheme_start, graphemes.count)
      let graphemeCount = min(cell.grapheme_len, graphemes.count - graphemeStart)
      guard emit(UInt64(graphemeCount)) else {
        return false
      }
      for codepoint in graphemes[graphemeStart..<(graphemeStart + graphemeCount)] {
        guard emit(codepoint) else {
          return false
        }
      }
    }
    return true
  }
}

struct TerminalGlyphGridCell: Equatable, Hashable {
  let utf16Range: Range<Int>
  let startColumn: Int
  let cellCount: Int
}

struct TerminalGlyphCluster: Equatable {
  let cell: TerminalGlyphGridCell
  var glyphIndices: [Int]
  var advance: CGFloat
}

struct TerminalGlyphClusterGroups: Equatable {
  var mainGlyphIndices: [Int]
  var clusters: [TerminalGlyphCluster]
}

enum TerminalGlyphOverflow {
  static let advanceSlack: CGFloat = 0.5

  static func overflowScale(
    clusterAdvance: CGFloat,
    cellCount: Int,
    cellWidth: CGFloat
  ) -> CGFloat? {
    guard
      clusterAdvance.isFinite,
      cellWidth.isFinite,
      clusterAdvance > 0,
      cellCount > 0,
      cellWidth > 0
    else {
      return nil
    }
    let budget = CGFloat(cellCount) * cellWidth
    guard clusterAdvance > budget + advanceSlack else {
      return nil
    }
    return min(1, budget / clusterAdvance)
  }
}

enum TerminalGlyphClusterLayout {
  static func groups(
    stringIndices: [CFIndex],
    advances: [CGSize],
    cellsByUTF16Index: [TerminalGlyphGridCell]
  ) -> TerminalGlyphClusterGroups {
    var mainGlyphIndices: [Int] = []
    var clusters: [TerminalGlyphCluster] = []
    var clusterIndices: [TerminalGlyphGridCell: Int] = [:]

    for (glyphIndex, stringIndex) in stringIndices.enumerated() {
      guard
        glyphIndex < advances.count,
        stringIndex != kCFNotFound,
        stringIndex >= 0,
        stringIndex < cellsByUTF16Index.count
      else {
        mainGlyphIndices.append(glyphIndex)
        continue
      }
      let cell = cellsByUTF16Index[stringIndex]
      if let clusterIndex = clusterIndices[cell] {
        clusters[clusterIndex].glyphIndices.append(glyphIndex)
        clusters[clusterIndex].advance += advances[glyphIndex].width
      } else {
        clusterIndices[cell] = clusters.count
        clusters.append(
          TerminalGlyphCluster(
            cell: cell,
            glyphIndices: [glyphIndex],
            advance: advances[glyphIndex].width
          )
        )
      }
    }
    return TerminalGlyphClusterGroups(
      mainGlyphIndices: mainGlyphIndices,
      clusters: clusters
    )
  }
}

enum TerminalGlyphGridLayout {
  static func cells(for run: TerminalTextRun) -> [TerminalGlyphGridCell] {
    var utf16Offset = 0
    var column = 0
    return run.cells.map { cell in
      let length = cell.text.utf16.count
      defer {
        utf16Offset += length
        column += cell.cellCount
      }
      return TerminalGlyphGridCell(
        utf16Range: utf16Offset..<(utf16Offset + length),
        startColumn: column,
        cellCount: cell.cellCount
      )
    }
  }

  static func cellXPositions(
    for run: TerminalTextRun,
    cellWidth: CGFloat,
    leftInset: CGFloat
  ) -> [CGFloat] {
    cells(for: run).map {
      leftInset + CGFloat(run.startColumn + $0.startColumn) * cellWidth
    }
  }

  static func cellsByUTF16Index(for run: TerminalTextRun) -> [TerminalGlyphGridCell] {
    var result: [TerminalGlyphGridCell] = []
    result.reserveCapacity(run.text.utf16.count)
    for cell in cells(for: run) {
      result.append(contentsOf: repeatElement(cell, count: cell.utf16Range.count))
    }
    return result
  }
}

enum TerminalPaneGeometry {
  static func rowTopOffset(
    _ row: UInt16,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets
  ) -> CGFloat {
    insets.top + CGFloat(row) * metrics.cellHeight
  }

  static func rowRectY(
    _ row: UInt16,
    bounds: NSRect,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets
  ) -> CGFloat {
    bounds.height - rowTopOffset(row, metrics: metrics, insets: insets) - metrics.cellHeight
  }

  static func cursorCellRect(
    cursor: LocusTermCursor,
    bounds: NSRect,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets
  ) -> NSRect {
    let column = cursor.wide_tail ? max(0, Int(cursor.x) - 1) : Int(cursor.x)
    return NSRect(
      x: insets.left + CGFloat(column) * metrics.cellWidth,
      y: rowRectY(cursor.y, bounds: bounds, metrics: metrics, insets: insets),
      width: cursor.wide_tail ? metrics.cellWidth * 2 : metrics.cellWidth,
      height: metrics.cellHeight
    )
  }

  static func cursorBarRect(
    cursor: LocusTermCursor,
    bounds: NSRect,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets
  ) -> NSRect {
    let cellRect = cursorCellRect(
      cursor: cursor,
      bounds: bounds,
      metrics: metrics,
      insets: insets
    )
    return NSRect(
      x: cellRect.minX,
      y: cellRect.minY,
      width: TerminalCursorMetrics.thickness,
      height: metrics.cellHeight
    )
  }

  /// Converts a top-left-origin point in the terminal view into a clamped cell.
  static func cellCoordinate(
    for point: NSPoint,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets,
    grid: TerminalGridSize
  ) -> TerminalCellCoordinate {
    let rawColumn = Int(floor((point.x - insets.left) / metrics.cellWidth))
    let rawRow = Int(floor((point.y - insets.top) / metrics.cellHeight))
    let column = min(max(rawColumn, 0), max(0, Int(grid.columns) - 1))
    let row = min(max(rawRow, 0), max(0, Int(grid.rows) - 1))
    return TerminalCellCoordinate(
      column: UInt16(clamping: column),
      row: UInt16(clamping: row)
    )
  }

  static func cellHit(
    for point: NSPoint,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets,
    grid: TerminalGridSize
  ) -> (coordinate: TerminalCellCoordinate, fractionX: Float) {
    let coordinate = cellCoordinate(
      for: point,
      metrics: metrics,
      insets: insets,
      grid: grid
    )
    let cellMinX = insets.left + CGFloat(coordinate.column) * metrics.cellWidth
    let rawFraction = (point.x - cellMinX) / metrics.cellWidth
    return (
      coordinate,
      Float(min(max(rawFraction, 0), 1))
    )
  }

  static func autoscrollDirection(forY y: CGFloat, height: CGFloat) -> Int32? {
    if y < 0 {
      return -1
    }
    if y > height {
      return 1
    }
    return nil
  }

  static func selectionRect(
    columns: ClosedRange<UInt16>,
    row: UInt16,
    bounds: NSRect,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets
  ) -> NSRect {
    NSRect(
      x: insets.left + CGFloat(columns.lowerBound) * metrics.cellWidth,
      y: rowRectY(row, bounds: bounds, metrics: metrics, insets: insets),
      width: CGFloat(Int(columns.upperBound) - Int(columns.lowerBound) + 1)
        * metrics.cellWidth,
      height: metrics.cellHeight
    )
  }

  static func searchMatchRect(
    _ match: TerminalSearchMatch,
    bounds: NSRect,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets
  ) -> NSRect {
    selectionRect(
      columns: match.xStart...match.xEnd,
      row: match.y,
      bounds: bounds,
      metrics: metrics,
      insets: insets
    )
  }

  static func linkUnderlineRect(
    _ match: TerminalLinkMatch,
    bounds: NSRect,
    metrics: TerminalCellMetrics,
    insets: TerminalContentInsets
  ) -> NSRect {
    let baselineY =
      bounds.height - rowTopOffset(match.y, metrics: metrics, insets: insets)
      - metrics.baselineOffset
    let font = metrics.font as CTFont
    return NSRect(
      x: insets.left + CGFloat(match.xStart) * metrics.cellWidth,
      y: baselineY + CGFloat(CTFontGetUnderlinePosition(font)),
      width: CGFloat(Int(match.xEnd) - Int(match.xStart) + 1) * metrics.cellWidth,
      height: max(1, CGFloat(CTFontGetUnderlineThickness(font)))
    )
  }
}

enum TerminalLinkHitTester {
  static func match(
    at coordinate: TerminalCellCoordinate,
    in matches: [TerminalLinkMatch]
  ) -> TerminalLinkMatch? {
    matches.first { match in
      match.y == coordinate.row
        && match.xStart <= coordinate.column
        && coordinate.column <= match.xEnd
    }
  }
}

enum TerminalLinkURLValidator {
  static func url(from uri: String) -> URL? {
    guard let url = URL(string: uri), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else {
      return nil
    }
    return url
  }
}

/// Accumulates AppKit scrolling deltas into whole terminal rows. AppKit's
/// positive Y direction points toward older content, while the terminal FFI
/// uses negative row deltas for that direction.
struct TerminalWheelAccumulator {
  static let maxWheelRowsPerEvent: CGFloat = 4096

  private var pendingRows: CGFloat = 0

  mutating func ffiDeltaRows(
    scrollingDeltaY: CGFloat,
    hasPreciseDeltas: Bool,
    cellHeight: CGFloat
  ) -> Int32 {
    guard scrollingDeltaY.isFinite, cellHeight.isFinite, cellHeight > 0 else {
      return 0
    }

    pendingRows += hasPreciseDeltas ? scrollingDeltaY / cellHeight : scrollingDeltaY
    let wholeRows = pendingRows.rounded(.towardZero)
    pendingRows -= wholeRows
    let clampedRows = min(
      max(wholeRows, -Self.maxWheelRowsPerEvent),
      Self.maxWheelRowsPerEvent
    )
    return -Int32(clampedRows)
  }
}

struct TerminalKeyInput: Equatable, Sendable {
  let keyCode: UInt16
  let modifierFlagsRawValue: UInt
  let characters: String?
  let charactersIgnoringModifiers: String?
  let isARepeat: Bool

  init(
    keyCode: UInt16,
    modifierFlagsRawValue: UInt,
    characters: String?,
    charactersIgnoringModifiers: String?,
    isARepeat: Bool
  ) {
    self.keyCode = keyCode
    self.modifierFlagsRawValue = modifierFlagsRawValue
    self.characters = characters
    self.charactersIgnoringModifiers = charactersIgnoringModifiers
    self.isARepeat = isARepeat
  }

  init(event: NSEvent) {
    self.init(
      keyCode: event.keyCode,
      modifierFlagsRawValue: event.modifierFlags.rawValue,
      characters: event.characters,
      charactersIgnoringModifiers: event.charactersIgnoringModifiers,
      isARepeat: event.isARepeat
    )
  }
}

struct TerminalKeyEvent: Equatable, Sendable {
  let action: UInt32
  let key: UInt32
  let modifiers: TerminalModifiers
  let consumedModifiers: TerminalModifiers
  let composing: Bool
  let utf8: Data
  let unshiftedCodepoint: UInt32

  func withLocusEvent<Result>(
    _ body: (LocusTermKeyEvent) throws -> Result
  ) rethrows -> Result {
    try utf8.withUnsafeBytes { buffer in
      let event = LocusTermKeyEvent(
        action: action,
        key: key,
        mods: modifiers.rawValue,
        consumed_mods: consumedModifiers.rawValue,
        composing: composing,
        utf8: buffer.bindMemory(to: UInt8.self).baseAddress,
        utf8_len: buffer.count,
        unshifted_codepoint: unshiftedCodepoint
      )
      return try body(event)
    }
  }
}

enum TerminalCaretMovement {
  static func events(
    from current: TerminalCellCoordinate,
    to destination: TerminalCellCoordinate
  ) -> [TerminalKeyEvent] {
    guard current.row == destination.row else {
      return []
    }
    let delta = Int(destination.column) - Int(current.column)
    guard delta != 0 else {
      return []
    }
    let key = delta > 0 ? LOCUS_TERM_KEY_ARROW_RIGHT : LOCUS_TERM_KEY_ARROW_LEFT
    let event = TerminalKeyEvent.keyPress(key)
    return Array(repeating: event, count: abs(delta))
  }
}

enum TerminalCaretClickResolver {
  static func resolveCaretClick(
    row: Int,
    column: Int,
    cursorRow: Int,
    frameRows: [Bool]
  ) -> Int? {
    guard
      row >= 0,
      row < frameRows.count,
      cursorRow >= 0,
      cursorRow < frameRows.count,
      column >= 0
    else {
      return nil
    }

    if abs(row - cursorRow) <= 1 {
      return column
    }
    if row > cursorRow, frameRows[row...].allSatisfy({ $0 }) {
      return column
    }
    return nil
  }
}

enum TerminalCommandKeyTranslator {
  static func terminalKey(for selector: Selector) -> TerminalKeyEvent? {
    let key: UInt32
    switch NSStringFromSelector(selector) {
    case "moveLeft:":
      key = LOCUS_TERM_KEY_ARROW_LEFT
    case "moveRight:":
      key = LOCUS_TERM_KEY_ARROW_RIGHT
    case "moveUp:":
      key = LOCUS_TERM_KEY_ARROW_UP
    case "moveDown:":
      key = LOCUS_TERM_KEY_ARROW_DOWN
    case "insertNewline:":
      key = LOCUS_TERM_KEY_ENTER
    case "deleteBackward:":
      key = LOCUS_TERM_KEY_BACKSPACE
    case "deleteForward:":
      key = LOCUS_TERM_KEY_DELETE
    case "insertTab:":
      key = LOCUS_TERM_KEY_TAB
    case "cancelOperation:":
      key = LOCUS_TERM_KEY_ESCAPE
    case "pageUp:":
      key = LOCUS_TERM_KEY_PAGE_UP
    case "pageDown:":
      key = LOCUS_TERM_KEY_PAGE_DOWN
    case "scrollToBeginningOfDocument:":
      key = LOCUS_TERM_KEY_HOME
    case "scrollToEndOfDocument:":
      key = LOCUS_TERM_KEY_END
    default:
      return nil
    }
    return TerminalKeyEvent.keyPress(key)
  }
}

extension TerminalKeyEvent {
  fileprivate static func keyPress(_ key: UInt32) -> TerminalKeyEvent {
    TerminalKeyEvent(
      action: LOCUS_TERM_ACTION_PRESS,
      key: key,
      modifiers: [],
      consumedModifiers: [],
      composing: false,
      utf8: Data(),
      unshiftedCodepoint: 0
    )
  }
}

@MainActor
enum TerminalKeyTranslator {
  // Device-dependent masks from IOKit/hidsystem/IOLLEvent.h. NSEvent always
  // supplies the device-independent modifier, but these low bits are present
  // only when macOS can identify the physical side. Unknown sides stay Left.
  private enum DeviceMask {
    static let leftControl: UInt = 0x0000_0001
    static let leftShift: UInt = 0x0000_0002
    static let rightShift: UInt = 0x0000_0004
    static let leftCommand: UInt = 0x0000_0008
    static let rightCommand: UInt = 0x0000_0010
    static let leftOption: UInt = 0x0000_0020
    static let rightOption: UInt = 0x0000_0040
    static let rightControl: UInt = 0x0000_2000
  }

  static func translate(
    _ input: TerminalKeyInput,
    action: UInt32 = LOCUS_TERM_ACTION_PRESS,
    composing: Bool = false
  ) -> TerminalKeyEvent? {
    let flags = NSEvent.ModifierFlags(rawValue: input.modifierFlagsRawValue)
    let modifiers = terminalModifiers(
      flags: flags,
      rawValue: input.modifierFlagsRawValue
    )
    // Cmd+Delete clears the whole command line, like Terminal.app and
    // Ghostty: translate it to Ctrl+U (kill-whole-line in the shell) instead
    // of passing it to the system, which has no binding for it.
    if modifiers.contains(.command), input.keyCode == 51 {
      return TerminalKeyEvent(
        action: action,
        key: LOCUS_TERM_KEY_UNIDENTIFIED,
        modifiers: .control,
        consumedModifiers: [],
        composing: composing,
        utf8: Data("u".utf8),
        unshiftedCodepoint: UnicodeScalar("u").value
      )
    }

    guard !modifiers.contains(.command) else {
      return nil
    }

    let key = terminalKey(for: input.keyCode)
    let text = terminalText(for: input, modifiers: modifiers, key: key)
    return TerminalKeyEvent(
      action: input.isARepeat ? LOCUS_TERM_ACTION_REPEAT : action,
      key: key,
      modifiers: modifiers,
      consumedModifiers: [],
      composing: composing,
      utf8: Data(text.utf8),
      unshiftedCodepoint: TerminalUnshiftedCodepointResolver.current(
        keyCode: input.keyCode,
        charactersIgnoringModifiers: input.charactersIgnoringModifiers
      )
    )
  }

  static func suppressesTextInsertion(_ text: String) -> Bool {
    !text.isEmpty
      && text.unicodeScalars.allSatisfy({ (0xF710...0xF717).contains($0.value) })
  }

  static func modifiers(for event: NSEvent) -> TerminalModifiers {
    terminalModifiers(flags: event.modifierFlags, rawValue: event.modifierFlags.rawValue)
  }

  private static func terminalText(
    for input: TerminalKeyInput,
    modifiers: TerminalModifiers,
    key: UInt32
  ) -> String {
    guard key == LOCUS_TERM_KEY_UNIDENTIFIED else {
      return ""
    }
    if modifiers.contains(.control) {
      return input.charactersIgnoringModifiers ?? input.characters ?? ""
    }
    return input.characters ?? input.charactersIgnoringModifiers ?? ""
  }

  private static func terminalModifiers(
    flags: NSEvent.ModifierFlags,
    rawValue: UInt
  ) -> TerminalModifiers {
    var result: TerminalModifiers = []
    let hasShift =
      flags.contains(.shift)
      || rawValue & (DeviceMask.leftShift | DeviceMask.rightShift) != 0
    let hasControl =
      flags.contains(.control)
      || rawValue & (DeviceMask.leftControl | DeviceMask.rightControl) != 0
    let hasOption =
      flags.contains(.option)
      || rawValue & (DeviceMask.leftOption | DeviceMask.rightOption) != 0
    let hasCommand =
      flags.contains(.command)
      || rawValue & (DeviceMask.leftCommand | DeviceMask.rightCommand) != 0

    if hasShift {
      result.insert(.shift)
      if rawValue & DeviceMask.rightShift != 0 {
        result.insert(.rightShift)
      }
    }
    if hasControl {
      result.insert(.control)
      if rawValue & DeviceMask.rightControl != 0 {
        result.insert(.rightControl)
      }
    }
    if hasOption {
      result.insert(.option)
      if rawValue & DeviceMask.rightOption != 0 {
        result.insert(.rightOption)
      }
    }
    if hasCommand {
      result.insert(.command)
      if rawValue & DeviceMask.rightCommand != 0 {
        result.insert(.rightCommand)
      }
    }
    if flags.contains(.capsLock) {
      result.insert(.capsLock)
    }
    return result
  }

  private static func terminalKey(for keyCode: UInt16) -> UInt32 {
    switch keyCode {
    case 36, 76:
      return LOCUS_TERM_KEY_ENTER
    case 48:
      return LOCUS_TERM_KEY_TAB
    case 51:
      return LOCUS_TERM_KEY_BACKSPACE
    case 53:
      return LOCUS_TERM_KEY_ESCAPE
    case 123:
      return LOCUS_TERM_KEY_ARROW_LEFT
    case 124:
      return LOCUS_TERM_KEY_ARROW_RIGHT
    case 125:
      return LOCUS_TERM_KEY_ARROW_DOWN
    case 126:
      return LOCUS_TERM_KEY_ARROW_UP
    case 115:
      return LOCUS_TERM_KEY_HOME
    case 119:
      return LOCUS_TERM_KEY_END
    case 116:
      return LOCUS_TERM_KEY_PAGE_UP
    case 121:
      return LOCUS_TERM_KEY_PAGE_DOWN
    case 117:
      return LOCUS_TERM_KEY_DELETE
    case 122:
      return LOCUS_TERM_KEY_F1
    case 120:
      return LOCUS_TERM_KEY_F2
    case 99:
      return LOCUS_TERM_KEY_F3
    case 118:
      return LOCUS_TERM_KEY_F4
    case 96:
      return LOCUS_TERM_KEY_F5
    case 97:
      return LOCUS_TERM_KEY_F6
    case 98:
      return LOCUS_TERM_KEY_F7
    case 100:
      return LOCUS_TERM_KEY_F8
    case 101:
      return LOCUS_TERM_KEY_F9
    case 109:
      return LOCUS_TERM_KEY_F10
    case 103:
      return LOCUS_TERM_KEY_F11
    case 111:
      return LOCUS_TERM_KEY_F12
    case 105:
      return LOCUS_TERM_KEY_F13
    case 107:
      return LOCUS_TERM_KEY_F14
    case 113:
      return LOCUS_TERM_KEY_F15
    case 106:
      return LOCUS_TERM_KEY_F16
    case 64:
      return LOCUS_TERM_KEY_F17
    case 79:
      return LOCUS_TERM_KEY_F18
    case 80:
      return LOCUS_TERM_KEY_F19
    case 90:
      return LOCUS_TERM_KEY_F20
    default:
      return LOCUS_TERM_KEY_UNIDENTIFIED
    }
  }
}

@MainActor
enum TerminalUnshiftedCodepointResolver {
  private static var cache = TerminalUnshiftedCodepointCache()

  nonisolated static func resolve(
    charactersIgnoringModifiers: String?,
    translate: () -> String?
  ) -> UInt32 {
    if let translated = translate(),
      translated.unicodeScalars.count == 1,
      let scalar = translated.unicodeScalars.first
    {
      return scalar.value
    }
    if let text = charactersIgnoringModifiers,
      text.unicodeScalars.count == 1,
      let scalar = text.unicodeScalars.first
    {
      if scalar.isASCII, let lowered = UnicodeScalar(String(scalar).lowercased()) {
        return lowered.value
      }
      return scalar.value
    }
    return 0
  }

  static func current(keyCode: UInt16, charactersIgnoringModifiers: String?) -> UInt32 {
    guard
      let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let identifierPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
      let identifier = Unmanaged<CFString>.fromOpaque(identifierPointer).takeUnretainedValue()
        as String?
    else {
      return resolve(charactersIgnoringModifiers: charactersIgnoringModifiers) { nil }
    }
    let keyboardType = UInt32(LMGetKbdType())
    return cache.resolve(
      layoutIdentifier: identifier,
      keyCode: keyCode,
      keyboardType: keyboardType,
      charactersIgnoringModifiers: charactersIgnoringModifiers
    ) {
      translatedCharacter(
        source: source,
        keyCode: keyCode,
        keyboardType: keyboardType
      )
    }
  }

  private static func translatedCharacter(
    source: TISInputSource,
    keyCode: UInt16,
    keyboardType: UInt32
  ) -> String? {
    guard
      let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else {
      return nil
    }
    let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(layoutData) else {
      return nil
    }
    let layout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
    var deadKeyState: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 4)
    let status = UCKeyTranslate(
      layout,
      keyCode,
      UInt16(kUCKeyActionDown),
      0,
      keyboardType,
      OptionBits(kUCKeyTranslateNoDeadKeysBit),
      &deadKeyState,
      characters.count,
      &length,
      &characters
    )
    guard status == noErr, length > 0 else {
      return nil
    }
    return String(utf16CodeUnits: characters, count: length)
  }
}

struct TerminalUnshiftedCodepointCache {
  private struct Key: Hashable {
    let layoutIdentifier: String
    let keyCode: UInt16
    let keyboardType: UInt32
  }

  private var values: [Key: UInt32] = [:]

  mutating func resolve(
    layoutIdentifier: String,
    keyCode: UInt16,
    keyboardType: UInt32,
    charactersIgnoringModifiers: String?,
    translate: () -> String?
  ) -> UInt32 {
    let key = Key(
      layoutIdentifier: layoutIdentifier,
      keyCode: keyCode,
      keyboardType: keyboardType
    )
    if let cached = values[key] {
      return cached
    }
    let value = TerminalUnshiftedCodepointResolver.resolve(
      charactersIgnoringModifiers: charactersIgnoringModifiers,
      translate: translate
    )
    values[key] = value
    return value
  }
}

struct TerminalPane: NSViewRepresentable {
  let session: TerminalSession
  var onViewReady: ((TerminalPaneView) -> Void)?
  var onFindRequested: (() -> Void)?

  init(
    session: TerminalSession,
    onViewReady: ((TerminalPaneView) -> Void)? = nil,
    onFindRequested: (() -> Void)? = nil
  ) {
    self.session = session
    self.onViewReady = onViewReady
    self.onFindRequested = onFindRequested
  }

  func makeNSView(context: Context) -> TerminalPaneView {
    let view = TerminalPaneView(session: session)
    view.onWindowChange = onViewReady
    view.onFindRequested = onFindRequested
    onViewReady?(view)
    return view
  }

  func updateNSView(_ nsView: TerminalPaneView, context: Context) {
    nsView.session = session
    nsView.onWindowChange = onViewReady
    nsView.onFindRequested = onFindRequested
  }

  static func dismantleNSView(_ nsView: TerminalPaneView, coordinator: Void) {
    nsView.onWindowChange = nil
    nsView.onFindRequested = nil
  }
}

final class TerminalPaneView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
  private enum MouseRouting {
    case none
    case localSelection
    case application
  }

  private struct PendingClick {
    let location: NSPoint
    let cell: TerminalCellCoordinate
  }

  private struct HoveredLink: Equatable {
    let match: TerminalLinkMatch
    let uri: String
  }

  private static let selectionAutoscrollInterval: TimeInterval = 0.05

  private struct MetalPaint {
    var scene: TerminalMetalScene
    var caretVisible: Bool
    var caretRect: NSRect?
  }

  var onWindowChange: ((TerminalPaneView) -> Void)?
  var onFindRequested: (() -> Void)?
  var session: TerminalSession? {
    didSet {
      guard oldValue !== session else {
        return
      }
      cachedLinks = nil
      clearHoveredLink()
      rowShapingCache.clear()
      subscribeToSession()
      if window != nil {
        synchronizeTerminalSize()
      }
      hasPendingFrameChange = true
      requestViewPaint()
    }
  }

  private(set) var backend: TerminalRenderBackend
  private let metrics: TerminalCellMetrics
  private let rowShapingCache: TerminalRowShapingCache
  private var foregroundColorCache = TerminalForegroundColorCache()
  private let pasteboard: NSPasteboard
  private let resizeObserver: ((TerminalGridSize) -> Void)?
  private let keyEventObserver: ((TerminalKeyEvent) -> Void)?
  private let caretResetObserver: (() -> Void)?
  private var cancellable: AnyCancellable?
  private var hasPendingFrameChange = true
  private var lastScheduledGeneration: UInt64?
  private var lastGridSize: TerminalGridSize?
  private var frameDisplayLink: CADisplayLink?
  private var markedTextStorage: NSAttributedString?
  private var markedSelection = NSRange(location: NSNotFound, length: 0)
  private var handledInputDuringKeyInterpretation = false
  private var pendingGridSize: TerminalGridSize?
  private var resizeTask: Task<Void, Never>?
  private var pendingClick: PendingClick?
  private var mouseRouting: MouseRouting = .none
  private var lastDragRectangle = false
  private var selectionAutoscrollTimer: Timer?
  private var lastAutoscrollContext: (direction: Int32, column: UInt16, fractionX: Float)?
  private var hasRenderedSelection = false
  private var lastCaretInputTime = CACurrentMediaTime()
  private var lastDrawnCaretVisibility: Bool?
  private var lastDrawnCaretRect: NSRect?
  private var wheelAccumulator = TerminalWheelAccumulator()
  private var linkTrackingArea: NSTrackingArea?
  private var hoveredLink: HoveredLink?
  private var cachedLinks: (generation: UInt64, matches: [TerminalLinkMatch])?
  private var metalRenderer: TerminalMetalRenderer?
  private var metalRendererInitializationAttempted = false
  private var loggedMetalFallback = false
  private(set) var rowsDrawnForTesting = 0
  private(set) var metalRendersForTesting = 0
  private(set) var lastMetalRenderSucceededForTesting: Bool?
  var metalFramebufferOnlyForTesting = true {
    didSet {
      (layer as? CAMetalLayer)?.framebufferOnly = metalFramebufferOnlyForTesting
    }
  }
  var metalContentsScaleForTesting: CGFloat? {
    didSet {
      updateMetalLayerGeometry()
    }
  }
  var hasActiveKeyboardFocusForTesting: Bool?

  var hasRenderedSelectionForTesting: Bool {
    hasRenderedSelection
  }

  var rowTextPoolStatisticsForTesting: (hits: Int, misses: Int) {
    rowShapingCache.statisticsForTesting
  }

  override var acceptsFirstResponder: Bool { true }
  override var isOpaque: Bool { true }
  override var wantsUpdateLayer: Bool { backend == .metal }

  override func makeBackingLayer() -> CALayer {
    guard backend == .metal else {
      return super.makeBackingLayer()
    }
    guard let device = MTLCreateSystemDefaultDevice() else {
      backend = .coreGraphics
      logMetalFallbackIfNeeded()
      return super.makeBackingLayer()
    }
    let metalLayer = CAMetalLayer()
    metalLayer.device = device
    metalLayer.pixelFormat = .bgra8Unorm
    metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    metalLayer.isOpaque = true
    metalLayer.framebufferOnly = metalFramebufferOnlyForTesting
    return metalLayer
  }

  override func updateLayer() {}

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    rowShapingCache.clear()
    foregroundColorCache.clear()
    requestViewPaint()
  }

  /// A new snapshot generation always schedules a paint. Frame dirty state
  /// must not gate this: query-only feeds can consume earlier dirty flags,
  /// while each frame still contains the complete terminal contents.
  static func shouldSchedulePaint(
    generation: UInt64?,
    lastScheduledGeneration: UInt64?
  ) -> Bool {
    guard let generation else {
      return false
    }
    return generation != lastScheduledGeneration
  }

  private static func isFindShortcut(_ event: NSEvent) -> Bool {
    let significant = event.modifierFlags.intersection([
      .command, .control, .option, .shift,
    ])
    return significant == .command
      && event.charactersIgnoringModifiers?.lowercased() == "f"
  }

  init(
    session: TerminalSession? = nil,
    metrics: TerminalCellMetrics = TerminalCellMetrics(),
    backend: TerminalRenderBackend = .fromEnvironment(
      ProcessInfo.processInfo.environment["LOCUS_TERMINAL_RENDERER"]
    ),
    pasteboard: NSPasteboard = .general,
    resizeObserver: ((TerminalGridSize) -> Void)? = nil,
    keyEventObserver: ((TerminalKeyEvent) -> Void)? = nil,
    caretResetObserver: (() -> Void)? = nil
  ) {
    self.session = session
    self.metrics = metrics
    self.backend = backend
    self.rowShapingCache = TerminalRowShapingCache(
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets
    )
    self.pasteboard = pasteboard
    self.resizeObserver = resizeObserver
    self.keyEventObserver = keyEventObserver
    self.caretResetObserver = caretResetObserver
    super.init(frame: .zero)
    wantsLayer = true
    if backend == .metal {
      layerContentsRedrawPolicy = .never
    }
    observeActiveFocusChanges()
    subscribeToSession()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    MainActor.assumeIsolated {
      stopSelectionAutoscroll()
      resizeTask?.cancel()
      stopDisplayLink()
      NotificationCenter.default.removeObserver(self)
    }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      stopSelectionAutoscroll()
      cancelPendingTerminalResize()
      stopDisplayLink()
    } else {
      startDisplayLink()
      synchronizeTerminalSize()
      updateMetalLayerGeometry()
    }
    onWindowChange?(self)
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateMetalLayerGeometry()
    requestViewPaint()
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateMetalLayerGeometry()
    if backend == .metal, inLiveResize {
      renderMetalFrame()
    }
    scheduleTerminalResizeIfNeeded()
  }

  override func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()
    (layer as? CAMetalLayer)?.presentsWithTransaction = true
  }

  override func viewDidEndLiveResize() {
    (layer as? CAMetalLayer)?.presentsWithTransaction = false
    super.viewDidEndLiveResize()
    renderMetalFrame()
  }

  override func layout() {
    super.layout()
    scheduleTerminalResizeIfNeeded()
  }

  override func updateTrackingAreas() {
    if let linkTrackingArea {
      removeTrackingArea(linkTrackingArea)
    }
    let trackingArea = NSTrackingArea(
      rect: .zero,
      options: [
        .mouseMoved,
        .mouseEnteredAndExited,
        .activeInKeyWindow,
        .inVisibleRect,
      ],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(trackingArea)
    linkTrackingArea = trackingArea
    super.updateTrackingAreas()
  }

  override func mouseMoved(with event: NSEvent) {
    updateLinkHover(with: event)
    super.mouseMoved(with: event)
  }

  override func mouseEntered(with event: NSEvent) {
    updateLinkHover(with: event)
    super.mouseEntered(with: event)
  }

  override func mouseExited(with event: NSEvent) {
    clearHoveredLink()
    super.mouseExited(with: event)
  }

  override func flagsChanged(with event: NSEvent) {
    updateLinkHover(with: event)
    super.flagsChanged(with: event)
  }

  override func scrollWheel(with event: NSEvent) {
    guard let session, let gridSize = currentGridSize() else {
      super.scrollWheel(with: event)
      return
    }
    let deltaRows = wheelAccumulator.ffiDeltaRows(
      scrollingDeltaY: event.scrollingDeltaY,
      hasPreciseDeltas: event.hasPreciseScrollingDeltas,
      cellHeight: metrics.cellHeight
    )
    guard deltaRows != 0 else {
      return
    }
    let hit = cellHit(for: event, gridSize: gridSize)
    session.scrollWheel(
      deltaRows: deltaRows,
      column: hit.coordinate.column,
      row: hit.coordinate.row,
      modifiers: TerminalKeyTranslator.modifiers(for: event)
    )
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    guard let session, let gridSize = currentGridSize() else {
      mouseRouting = .none
      pendingClick = nil
      super.mouseDown(with: event)
      return
    }
    let point = topLeftPoint(for: event)
    let hit = TerminalPaneGeometry.cellHit(
      for: point,
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets,
      grid: gridSize
    )
    let modifiers = TerminalKeyTranslator.modifiers(for: event)
    if event.modifierFlags.contains(.command), event.clickCount == 1,
      let link = resolvedLink(at: hit.coordinate)
    {
      mouseRouting = .none
      pendingClick = nil
      if let url = TerminalLinkURLValidator.url(from: link.uri) {
        NSWorkspace.shared.open(url)
      }
      return
    }
    if session.routeMousePress(
      button: .left,
      column: hit.coordinate.column,
      row: hit.coordinate.row,
      modifiers: modifiers
    ) {
      mouseRouting = .application
      pendingClick = nil
      super.mouseDown(with: event)
      return
    }

    mouseRouting = .localSelection
    lastDragRectangle = event.modifierFlags.contains(.option)
    session.selectionGesture(
      event.clickCount == 1 ? .press : .pressRepeat,
      column: hit.coordinate.column,
      row: hit.coordinate.row,
      cellFractionX: hit.fractionX,
      rectangle: lastDragRectangle
    )
    let significantModifiers = event.modifierFlags.intersection([
      .command, .control, .option, .shift,
    ])
    if event.clickCount == 1, significantModifiers.isEmpty {
      pendingClick = PendingClick(location: point, cell: hit.coordinate)
    } else {
      pendingClick = nil
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    clearHoveredLink()
    guard let session, let gridSize = currentGridSize() else {
      pendingClick = nil
      super.mouseDragged(with: event)
      return
    }
    let point = topLeftPoint(for: event)
    let hit = TerminalPaneGeometry.cellHit(
      for: point,
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets,
      grid: gridSize
    )
    if let pendingClick,
      distance(from: pendingClick.location, to: point) > metrics.cellWidth
        || pendingClick.cell != hit.coordinate
    {
      self.pendingClick = nil
    }

    switch mouseRouting {
    case .application:
      session.sendMouse(
        kind: .motion,
        button: .left,
        column: hit.coordinate.column,
        row: hit.coordinate.row,
        modifiers: TerminalKeyTranslator.modifiers(for: event)
      )
    case .localSelection:
      lastDragRectangle = event.modifierFlags.contains(.option)
      if let direction = TerminalPaneGeometry.autoscrollDirection(
        forY: point.y,
        height: bounds.height
      ) {
        lastAutoscrollContext = (
          direction,
          hit.coordinate.column,
          hit.fractionX
        )
        startSelectionAutoscrollIfNeeded()
      } else {
        stopSelectionAutoscroll()
        session.selectionGesture(
          .drag,
          column: hit.coordinate.column,
          row: hit.coordinate.row,
          cellFractionX: hit.fractionX,
          rectangle: lastDragRectangle
        )
      }
    case .none:
      break
    }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      stopSelectionAutoscroll()
      mouseRouting = .none
      pendingClick = nil
      super.mouseUp(with: event)
    }
    guard let session, let gridSize = currentGridSize() else {
      return
    }
    let releasePoint = topLeftPoint(for: event)
    let hit = TerminalPaneGeometry.cellHit(
      for: releasePoint,
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets,
      grid: gridSize
    )
    switch mouseRouting {
    case .application:
      session.sendMouse(
        kind: .release,
        button: .left,
        column: hit.coordinate.column,
        row: hit.coordinate.row,
        modifiers: TerminalKeyTranslator.modifiers(for: event)
      )
    case .localSelection:
      session.selectionGesture(
        .release,
        column: hit.coordinate.column,
        row: hit.coordinate.row,
        cellFractionX: hit.fractionX,
        rectangle: lastDragRectangle
      )
    case .none:
      break
    }

    guard let pendingClick,
      distance(from: pendingClick.location, to: releasePoint) <= metrics.cellWidth
    else {
      return
    }
    moveCaret(to: hit.coordinate)
  }

  override func otherMouseDown(with event: NSEvent) {
    guard event.buttonNumber == 2, let session, let gridSize = currentGridSize() else {
      super.otherMouseDown(with: event)
      return
    }
    let hit = cellHit(for: event, gridSize: gridSize)
    session.sendMouse(
      kind: .press,
      button: .middle,
      column: hit.coordinate.column,
      row: hit.coordinate.row,
      modifiers: TerminalKeyTranslator.modifiers(for: event)
    )
  }

  override func otherMouseUp(with event: NSEvent) {
    guard event.buttonNumber == 2, let session, let gridSize = currentGridSize() else {
      super.otherMouseUp(with: event)
      return
    }
    let hit = cellHit(for: event, gridSize: gridSize)
    session.sendMouse(
      kind: .release,
      button: .middle,
      column: hit.coordinate.column,
      row: hit.coordinate.row,
      modifiers: TerminalKeyTranslator.modifiers(for: event)
    )
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    // Right-click stays local in P1 so copy and paste remain available even
    // when the child application has enabled mouse reporting.
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: ""))
    return menu
  }

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    switch menuItem.action {
    case #selector(copy(_:)):
      return hasRenderedSelection
    case #selector(paste(_:)):
      return pasteboard.string(forType: .string)?.isEmpty == false
    default:
      return true
    }
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .iBeam)
    guard let hoveredLink else {
      return
    }
    for match in linkSegments(for: hoveredLink.match.linkID) {
      addCursorRect(
        TerminalPaneGeometry.selectionRect(
          columns: match.xStart...match.xEnd,
          row: match.y,
          bounds: bounds,
          metrics: metrics,
          insets: TerminalPaneLayoutMetrics.contentInsets
        ),
        cursor: .pointingHand
      )
    }
  }

  override func becomeFirstResponder() -> Bool {
    let didBecome = super.becomeFirstResponder()
    if didBecome {
      lastDrawnCaretVisibility = nil
      requestViewPaint()
    }
    return didBecome
  }

  override func resignFirstResponder() -> Bool {
    let didResign = super.resignFirstResponder()
    if didResign {
      requestViewPaint()
    }
    return didResign
  }

  override func keyDown(with event: NSEvent) {
    if Self.isFindShortcut(event) {
      onFindRequested?()
      return
    }
    let input = TerminalKeyInput(event: event)
    guard let translated = TerminalKeyTranslator.translate(input) else {
      super.keyDown(with: event)
      return
    }
    resetCaretBlink()

    let hadMarkedText = hasMarkedText()
    handledInputDuringKeyInterpretation = false
    if hadMarkedText {
      interpretKeyEvents([event])
      return
    }

    if translated.key != LOCUS_TERM_KEY_UNIDENTIFIED
      || translated.modifiers.contains(.control)
    {
      sendTerminalKey(translated)
      return
    }

    interpretKeyEvents([event])
    if !handledInputDuringKeyInterpretation {
      sendTerminalKey(translated)
    }
  }

  override func keyUp(with event: NSEvent) {
    // Forwarding releases is safe: the core emits no bytes unless the active
    // kitty keyboard protocol explicitly requests event types.
    let input = TerminalKeyInput(event: event)
    guard
      let translated = TerminalKeyTranslator.translate(
        input,
        action: LOCUS_TERM_ACTION_RELEASE,
        composing: hasMarkedText()
      )
    else {
      super.keyUp(with: event)
      return
    }
    sendTerminalKey(translated)
  }

  override func doCommand(by selector: Selector) {
    handledInputDuringKeyInterpretation = true
    guard let event = TerminalCommandKeyTranslator.terminalKey(for: selector) else {
      return
    }
    resetCaretBlink()
    sendTerminalKey(event)
  }

  @objc func paste(_ sender: Any?) {
    guard let session,
      let text = pasteboard.string(forType: .string),
      !text.isEmpty
    else {
      return
    }
    session.paste(text) { [weak self] outcome in
      guard outcome == .needsConfirmation else {
        return
      }
      self?.confirmUnsafePaste(text)
    }
  }

  @objc func copy(_ sender: Any?) {
    guard let text = session?.selectionText(), !text.isEmpty else {
      return
    }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    handledInputDuringKeyInterpretation = true
    clearMarkedText()
    let text = Self.string(fromTextInput: string)
    guard !text.isEmpty else {
      return
    }
    // AppKit represents F13-F20 as private-use text on some paths. Those keys
    // are handled by keyDown and must never leak literal PUA bytes to the PTY.
    if TerminalKeyTranslator.suppressesTextInsertion(text) {
      return
    }
    resetCaretBlink()
    if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first {
      sendTerminalKey(
        TerminalKeyEvent(
          action: LOCUS_TERM_ACTION_PRESS,
          key: LOCUS_TERM_KEY_UNIDENTIFIED,
          modifiers: [],
          consumedModifiers: [],
          composing: false,
          utf8: Data(text.utf8),
          unshiftedCodepoint: scalar.value
        )
      )
    } else {
      // An IME commit can contain multiple scalars without corresponding
      // physical key events, so it must remain a raw UTF-8 write.
      session?.send(Data(text.utf8))
    }
  }

  func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    handledInputDuringKeyInterpretation = true
    let attributed = Self.attributedString(fromTextInput: string)
    if attributed.length == 0 {
      clearMarkedText()
      return
    }
    markedTextStorage = attributed
    markedSelection = selectedRange
    requestViewPaint()
  }

  func unmarkText() {
    handledInputDuringKeyInterpretation = true
    let text = markedTextStorage?.string ?? ""
    clearMarkedText()
    if !text.isEmpty {
      session?.send(Data(text.utf8))
    }
  }

  func hasMarkedText() -> Bool {
    (markedTextStorage?.length ?? 0) > 0
  }

  func markedRange() -> NSRange {
    guard let markedTextStorage, markedTextStorage.length > 0 else {
      return NSRange(location: NSNotFound, length: 0)
    }
    return NSRange(location: 0, length: markedTextStorage.length)
  }

  func selectedRange() -> NSRange {
    hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0)
  }

  func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    nil
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.font, .foregroundColor, .underlineStyle]
  }

  func firstRect(
    forCharacterRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSRect {
    actualRange?.pointee = range
    guard let window else {
      return .zero
    }

    var cursor = LocusTermCursor(
      x: 0,
      y: 0,
      visible: false,
      blinking: false,
      wide_tail: false,
      style: 0
    )
    session?.withFrame { frame in
      cursor = frame.cursor
    }
    let localRect = TerminalPaneGeometry.cursorCellRect(
      cursor: cursor,
      bounds: bounds,
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets
    )
    return window.convertToScreen(convert(localRect, to: nil))
  }

  func characterIndex(for point: NSPoint) -> Int {
    0
  }

  override func draw(_ dirtyRect: NSRect) {
    guard let context = NSGraphicsContext.current?.cgContext else {
      return
    }
    rowShapingCache.beginPaint()
    rowsDrawnForTesting = 0
    defer {
      rowShapingCache.finishPaint()
    }

    backgroundColor.setFill()
    dirtyRect.fill()

    hasRenderedSelection = false
    guard let session else {
      return
    }

    let drawTime = CACurrentMediaTime()
    let searchMatches = session.snapshot?.search?.viewportMatches ?? []
    let hoveredLinkMatches = hoveredLink.map { linkSegments(for: $0.match.linkID) } ?? []
    session.withFrame { frame in
      let caretVisible = caretIsVisible(cursor: frame.cursor, at: drawTime)
      draw(
        frame: frame,
        searchMatches: searchMatches,
        hoveredLinkMatches: hoveredLinkMatches,
        caretVisible: caretVisible,
        dirtyRect: dirtyRect,
        in: context
      )
      lastDrawnCaretVisibility = caretVisible
      lastDrawnCaretRect =
        caretVisible && !hasMarkedText()
        ? caretRect(for: frame.cursor)
        : nil
    }
  }

  override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
    guard let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmapImageRep) else {
      super.cacheDisplay(in: rect, to: bitmapImageRep)
      return
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    graphicsContext.cgContext.saveGState()
    graphicsContext.cgContext.clip(to: rect)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      draw(rect)
    }
    graphicsContext.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
  }

  @discardableResult
  func renderMetalFrame() -> Bool {
    metalRendersForTesting &+= 1
    guard backend == .metal, window != nil, bounds.width > 0, bounds.height > 0 else {
      lastMetalRenderSucceededForTesting = false
      return false
    }
    updateMetalLayerGeometry()
    guard
      let metalLayer = layer as? CAMetalLayer,
      metalLayer.drawableSize.width > 0,
      metalLayer.drawableSize.height > 0,
      let renderer = terminalMetalRenderer(),
      let drawable = metalLayer.nextDrawable()
    else {
      lastMetalRenderSucceededForTesting = false
      return false
    }
    var paint: MetalPaint?
    effectiveAppearance.performAsCurrentDrawingAppearance {
      paint = buildMetalPaint(at: CACurrentMediaTime())
    }
    guard let paint else {
      lastMetalRenderSucceededForTesting = false
      return false
    }
    let present: TerminalMetalRenderer.PresentMode =
      inLiveResize ? .withTransaction(drawable) : .afterCommit(drawable)
    let succeeded = renderer.render(
      scene: paint.scene,
      into: drawable.texture,
      present: present,
      waitUntilCompleted: false
    )
    lastMetalRenderSucceededForTesting = succeeded
    if succeeded {
      lastDrawnCaretVisibility = paint.caretVisible
      lastDrawnCaretRect = paint.caretRect
    }
    return succeeded
  }

  func buildMetalSceneForTesting() -> TerminalMetalScene? {
    var scene: TerminalMetalScene?
    effectiveAppearance.performAsCurrentDrawingAppearance {
      scene = buildMetalPaint(at: CACurrentMediaTime())?.scene
    }
    return scene
  }

  private func buildMetalPaint(at drawTime: TimeInterval) -> MetalPaint? {
    guard let session else {
      return nil
    }
    let searchMatches = session.snapshot?.search?.viewportMatches ?? []
    let hoveredLinkMatches = hoveredLink.map { linkSegments(for: $0.match.linkID) } ?? []
    var result: MetalPaint?
    rowShapingCache.beginPaint()
    defer {
      rowShapingCache.finishPaint()
    }
    session.withFrame { frame in
      frame.withRows { rows in
        frame.withCells { cells in
          frame.withGraphemes { graphemes in
            var sceneRows: [TerminalMetalScene.Row] = []
            sceneRows.reserveCapacity(rows.count)
            for row in rows {
              let shaped = rowShapingCache.shapedRow(
                row: row,
                cells: cells,
                graphemes: graphemes
              )
              sceneRows.append(
                TerminalMetalScene.Row(
                  y: row.y,
                  shaped: shaped,
                  runForegrounds: shaped.runs.map {
                    foregroundColorCache.color(for: $0.run.style)
                  }
                ))
            }

            let selectionColor: NSColor =
              hasActiveKeyboardFocus
              ? .selectedTextBackgroundColor
              : .unemphasizedSelectedTextBackgroundColor
            var selectionRects: [CGRect] = []
            for (index, row) in rows.enumerated() {
              guard let columns = frame.selectionRange(forRow: index) else {
                continue
              }
              selectionRects.append(
                TerminalPaneGeometry.selectionRect(
                  columns: columns,
                  row: row.y,
                  bounds: bounds,
                  metrics: metrics,
                  insets: TerminalPaneLayoutMetrics.contentInsets
                ))
            }
            hasRenderedSelection = !selectionRects.isEmpty

            let metalSearchRects = searchMatches.map { match in
              let color =
                match.isSelected
                ? NSColor.findHighlightColor
                : NSColor.findHighlightColor.withAlphaComponent(0.35)
              return (
                rect: TerminalPaneGeometry.searchMatchRect(
                  match,
                  bounds: bounds,
                  metrics: metrics,
                  insets: TerminalPaneLayoutMetrics.contentInsets
                ),
                color: TerminalMetalColor.premultipliedSRGB(color)
              )
            }
            let linkRects = hoveredLinkMatches.map {
              TerminalPaneGeometry.linkUnderlineRect(
                $0,
                bounds: bounds,
                metrics: metrics,
                insets: TerminalPaneLayoutMetrics.contentInsets
              )
            }
            let caretVisible = caretIsVisible(cursor: frame.cursor, at: drawTime)
            let regularCaretRect =
              caretVisible && !hasMarkedText()
              ? caretRect(for: frame.cursor)
              : nil
            let markedText = metalMarkedTextScene(cursor: frame.cursor)
            let scene = TerminalMetalScene(
              viewSize: bounds.size,
              scale: currentMetalContentsScale(),
              backgroundColor: TerminalMetalColor.premultipliedSRGB(backgroundColor),
              rows: sceneRows,
              selectionRects: selectionRects,
              selectionColor: TerminalMetalColor.premultipliedSRGB(selectionColor),
              searchRects: metalSearchRects,
              linkUnderlineRects: linkRects,
              linkUnderlineColor: TerminalMetalColor.premultipliedSRGB(
                NSColor.textColor.withAlphaComponent(0.8)
              ),
              caretRect: regularCaretRect,
              caretColor: TerminalMetalColor.premultipliedSRGB(cursorColor),
              markedText: markedText
            )
            result = MetalPaint(
              scene: scene,
              caretVisible: caretVisible,
              caretRect: regularCaretRect
            )
          }
        }
      }
    }
    return result
  }

  private func metalMarkedTextScene(cursor: LocusTermCursor) -> TerminalMetalMarkedTextScene? {
    guard let markedTextStorage, markedTextStorage.length > 0 else {
      return nil
    }
    let attributed = NSMutableAttributedString(attributedString: markedTextStorage)
    attributed.addAttributes(
      [
        .font: metrics.font,
        .foregroundColor: NSColor.textColor,
      ],
      range: NSRange(location: 0, length: attributed.length)
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let width = max(
      metrics.cellWidth,
      CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    )
    let x =
      TerminalPaneLayoutMetrics.contentInsets.left
      + CGFloat(cursor.x) * metrics.cellWidth
    let baselineY = bounds.height - rowTopOffset(cursor.y) - metrics.baselineOffset
    let font = metrics.font as CTFont
    let underlineThickness = max(1, CGFloat(CTFontGetUnderlineThickness(font)))
    let cursorX = min(
      x + width,
      bounds.maxX
        - TerminalPaneLayoutMetrics.contentInsets.right
        - TerminalCursorMetrics.thickness
    )
    return TerminalMetalMarkedTextScene(
      backgroundRect: NSRect(
        x: x,
        y: rowRectY(cursor.y),
        width: width,
        height: metrics.cellHeight
      ),
      attributedString: attributed,
      baselineOrigin: CGPoint(x: x, y: baselineY),
      underlineRect: NSRect(
        x: x,
        y: baselineY + CGFloat(CTFontGetUnderlinePosition(font)),
        width: width,
        height: underlineThickness
      ),
      caretRect: NSRect(
        x: cursorX,
        y: rowRectY(cursor.y),
        width: TerminalCursorMetrics.thickness,
        height: metrics.cellHeight
      ),
      backgroundColor: TerminalMetalColor.premultipliedSRGB(backgroundColor),
      textColor: TerminalMetalColor.premultipliedSRGB(.textColor),
      caretColor: TerminalMetalColor.premultipliedSRGB(cursorColor)
    )
  }

  private func terminalMetalRenderer() -> TerminalMetalRenderer? {
    if let metalRenderer {
      return metalRenderer
    }
    guard !metalRendererInitializationAttempted else {
      return nil
    }
    metalRendererInitializationAttempted = true
    guard
      let device = (layer as? CAMetalLayer)?.device ?? MTLCreateSystemDefaultDevice(),
      let renderer = TerminalMetalRenderer(
        device: device,
        metrics: metrics,
        insets: TerminalPaneLayoutMetrics.contentInsets
      )
    else {
      fallBackToCoreGraphics()
      return nil
    }
    metalRenderer = renderer
    return renderer
  }

  private func fallBackToCoreGraphics() {
    guard backend == .metal else {
      return
    }
    backend = .coreGraphics
    logMetalFallbackIfNeeded()
    wantsLayer = false
    wantsLayer = true
    layerContentsRedrawPolicy = .duringViewResize
    needsDisplay = true
  }

  private func logMetalFallbackIfNeeded() {
    guard !loggedMetalFallback else {
      return
    }
    NSLog("Locus terminal: Metal renderer unavailable; falling back to Core Graphics")
    loggedMetalFallback = true
  }

  private func currentMetalContentsScale() -> CGFloat {
    max(1, metalContentsScaleForTesting ?? window?.backingScaleFactor ?? 2)
  }

  private func updateMetalLayerGeometry() {
    guard backend == .metal, let metalLayer = layer as? CAMetalLayer else {
      return
    }
    let scale = currentMetalContentsScale()
    metalLayer.contentsScale = scale
    metalLayer.drawableSize = CGSize(
      width: max(0, bounds.width * scale),
      height: max(0, bounds.height * scale)
    )
  }

  private func requestViewPaint() {
    if backend == .metal, window != nil {
      renderMetalFrame()
    } else {
      needsDisplay = true
    }
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
    let renderedBlinkTransition = invalidateCaretForBlinkIfNeeded(at: CACurrentMediaTime())

    guard hasPendingFrameChange else {
      return
    }
    let generation = session?.snapshot?.generation
    guard
      Self.shouldSchedulePaint(
        generation: generation,
        lastScheduledGeneration: lastScheduledGeneration
      )
    else {
      if generation == lastScheduledGeneration {
        hasPendingFrameChange = false
      }
      return
    }
    guard let generation else {
      return
    }

    if cachedLinks?.generation != generation {
      cachedLinks = nil
      clearHoveredLink()
    }
    if backend == .metal {
      if !renderedBlinkTransition, !renderMetalFrame() {
        // A temporarily unavailable drawable must not consume this frame.
        // Keep the generation pending so the next display-link tick retries.
        if backend == .metal {
          return
        }
      }
    }
    hasPendingFrameChange = false
    lastScheduledGeneration = generation
    if backend == .coreGraphics {
      needsDisplay = true
    }
  }

  private func scheduleTerminalResizeIfNeeded() {
    guard window != nil, let gridSize = currentGridSize() else {
      return
    }

    if gridSize == lastGridSize {
      cancelPendingTerminalResize()
      return
    }

    if gridSize == pendingGridSize {
      return
    }

    pendingGridSize = gridSize
    resizeTask?.cancel()
    resizeTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: TerminalPaneTiming.resizeDebounce)
      } catch {
        return
      }
      self?.deliverPendingTerminalResize()
    }
  }

  private func synchronizeTerminalSize() {
    cancelPendingTerminalResize()
    guard let gridSize = currentGridSize() else {
      return
    }
    deliverTerminalResize(gridSize)
  }

  private func currentGridSize() -> TerminalGridSize? {
    guard bounds.width > 0, bounds.height > 0 else {
      return nil
    }
    return TerminalCellMetrics.gridSize(
      for: bounds.size,
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets
    )
  }

  private func deliverPendingTerminalResize() {
    guard let gridSize = pendingGridSize else {
      return
    }
    pendingGridSize = nil
    resizeTask = nil
    deliverTerminalResize(gridSize)
  }

  private func deliverTerminalResize(_ gridSize: TerminalGridSize) {
    if lastGridSize != gridSize {
      rowShapingCache.clear()
    }
    lastGridSize = gridSize
    resizeObserver?(gridSize)
    // TerminalSession performs a full terminal render after every delivered
    // resize, so the final debounced dimensions repaint the complete frame.
    session?.resize(columns: gridSize.columns, rows: gridSize.rows)
  }

  private func cancelPendingTerminalResize() {
    resizeTask?.cancel()
    resizeTask = nil
    pendingGridSize = nil
  }

  private func confirmUnsafePaste(_ text: String) {
    guard let window else {
      return
    }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Paste multi-line text?"
    alert.informativeText =
      "The running program is not using bracketed paste, so each line may run as a command as soon as it is pasted."
    alert.addButton(withTitle: "Paste")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard response == .alertFirstButtonReturn else {
        return
      }
      self?.session?.paste(text, allowUnsafe: true)
    }
  }

  private var backgroundColor: NSColor {
    .textBackgroundColor
  }

  private var hasActiveKeyboardFocus: Bool {
    hasActiveKeyboardFocusForTesting
      ?? (window?.firstResponder === self && window?.isKeyWindow == true && NSApp.isActive)
  }

  private func draw(
    frame: TerminalFrame,
    searchMatches: [TerminalSearchMatch],
    hoveredLinkMatches: [TerminalLinkMatch],
    caretVisible: Bool,
    dirtyRect: NSRect,
    in context: CGContext
  ) {
    frame.withRows { rows in
      frame.withCells { cells in
        frame.withGraphemes { graphemes in
          var cachedRows: [(row: LocusTermRow, cached: TerminalShapedRow)] = []
          cachedRows.reserveCapacity(rows.count)
          for row in rows where rowPaintRect(row.y).intersects(dirtyRect) {
            cachedRows.append(
              (row, rowShapingCache.shapedRow(row: row, cells: cells, graphemes: graphemes))
            )
          }

          for item in cachedRows {
            drawBackgrounds(row: item.row, cached: item.cached, in: context)
          }
          drawSelection(frame: frame, rows: rows, dirtyRect: dirtyRect)
          drawSearchMatches(searchMatches, dirtyRect: dirtyRect)
          for item in cachedRows {
            drawText(row: item.row, cached: item.cached, in: context)
          }
          drawHoveredLinkUnderlines(hoveredLinkMatches, dirtyRect: dirtyRect, in: context)
        }
      }
    }
    if hasMarkedText() {
      drawMarkedText(frame.cursor, in: context)
    } else {
      drawCursor(frame.cursor, visible: caretVisible, in: context)
    }
  }

  private func drawSelection(
    frame: TerminalFrame,
    rows: UnsafeBufferPointer<LocusTermRow>,
    dirtyRect: NSRect
  ) {
    let color: NSColor =
      hasActiveKeyboardFocus
      ? .selectedTextBackgroundColor
      : .unemphasizedSelectedTextBackgroundColor
    var drewSelection = false
    color.setFill()
    for (index, row) in rows.enumerated() {
      guard let columns = frame.selectionRange(forRow: index) else {
        continue
      }
      drewSelection = true
      if rowPaintRect(row.y).intersects(dirtyRect) {
        TerminalPaneGeometry.selectionRect(
          columns: columns,
          row: row.y,
          bounds: bounds,
          metrics: metrics,
          insets: TerminalPaneLayoutMetrics.contentInsets
        ).fill()
      }
    }
    hasRenderedSelection = drewSelection
  }

  private func drawSearchMatches(_ matches: [TerminalSearchMatch], dirtyRect: NSRect) {
    for match in matches where rowPaintRect(match.y).intersects(dirtyRect) {
      let color =
        match.isSelected
        ? NSColor.findHighlightColor
        : NSColor.findHighlightColor.withAlphaComponent(0.35)
      color.setFill()
      TerminalPaneGeometry.searchMatchRect(
        match,
        bounds: bounds,
        metrics: metrics,
        insets: TerminalPaneLayoutMetrics.contentInsets
      ).fill()
    }
  }

  private func drawHoveredLinkUnderlines(
    _ matches: [TerminalLinkMatch],
    dirtyRect: NSRect,
    in context: CGContext
  ) {
    context.setFillColor(NSColor.textColor.withAlphaComponent(0.8).cgColor)
    for match in matches where rowPaintRect(match.y).intersects(dirtyRect) {
      context.fill(
        TerminalPaneGeometry.linkUnderlineRect(
          match,
          bounds: bounds,
          metrics: metrics,
          insets: TerminalPaneLayoutMetrics.contentInsets
        )
      )
    }
  }

  private func drawBackgrounds(
    row: LocusTermRow,
    cached: TerminalShapedRow,
    in context: CGContext
  ) {
    for fill in cached.backgroundFills {
      context.setFillColor(fill.color.cgColor)
      context.fill(
        NSRect(
          x: TerminalPaneLayoutMetrics.contentInsets.left
            + CGFloat(fill.startColumn) * metrics.cellWidth,
          y: rowRectY(row.y),
          width: CGFloat(fill.cellCount) * metrics.cellWidth,
          height: metrics.cellHeight
        )
      )
    }
  }

  private func drawText(
    row: LocusTermRow,
    cached: TerminalShapedRow,
    in context: CGContext
  ) {
    guard !cached.runs.isEmpty else {
      return
    }
    rowsDrawnForTesting += 1
    let baselineY = bounds.height - rowTopOffset(row.y) - metrics.baselineOffset
    for run in cached.runs {
      drawCachedTextRun(run, baselineY: baselineY, in: context)
    }
  }

  private func drawCachedTextRun(
    _ cached: TerminalShapedRun,
    baselineY: CGFloat,
    in context: CGContext
  ) {
    let foreground = resolvedForegroundColor(for: cached.run.style)
    context.saveGState()
    context.textMatrix = .identity
    context.setFillColor(foreground.cgColor)
    context.translateBy(x: 0, y: baselineY)
    for batch in cached.glyphBatches {
      context.saveGState()
      if let scale = batch.overflowScaleX, let anchor = batch.overflowAnchorX {
        context.translateBy(x: anchor, y: 0)
        context.scaleBy(x: scale, y: 1)
        context.translateBy(x: -anchor, y: 0)
      }
      drawGlyphs(batch.glyphs, at: batch.positions, font: batch.font, in: context)
      context.restoreGState()
    }
    context.restoreGState()
    drawDecorations(
      for: cached.run,
      baselineY: baselineY,
      color: foreground,
      in: context
    )
  }

  private func drawGlyphs(
    _ glyphs: [CGGlyph],
    at positions: [CGPoint],
    font: CTFont,
    in context: CGContext
  ) {
    guard !glyphs.isEmpty, glyphs.count == positions.count else {
      return
    }
    glyphs.withUnsafeBufferPointer { glyphBuffer in
      positions.withUnsafeBufferPointer { positionBuffer in
        guard
          let glyphBaseAddress = glyphBuffer.baseAddress,
          let positionBaseAddress = positionBuffer.baseAddress
        else {
          return
        }
        CTFontDrawGlyphs(
          font,
          glyphBaseAddress,
          positionBaseAddress,
          glyphs.count,
          context
        )
      }
    }
  }

  private func drawDecorations(
    for run: TerminalTextRun,
    baselineY: CGFloat,
    color: NSColor,
    in context: CGContext
  ) {
    guard run.style.flags.contains(.underline) || run.style.flags.contains(.strikethrough) else {
      return
    }

    let font = metrics.font(for: run.style.flags) as CTFont
    let x =
      TerminalPaneLayoutMetrics.contentInsets.left
      + CGFloat(run.startColumn) * metrics.cellWidth
    let width = CGFloat(run.cellCount) * metrics.cellWidth
    context.setFillColor(color.cgColor)
    if run.style.flags.contains(.underline) {
      let thickness = max(1, CGFloat(CTFontGetUnderlineThickness(font)))
      let y = baselineY + CGFloat(CTFontGetUnderlinePosition(font))
      context.fill(CGRect(x: x, y: y, width: width, height: thickness))
    }
    if run.style.flags.contains(.strikethrough) {
      let thickness = max(1, CGFloat(CTFontGetUnderlineThickness(font)))
      let y = baselineY + CGFloat(CTFontGetXHeight(font)) * 0.5
      context.fill(CGRect(x: x, y: y, width: width, height: thickness))
    }
  }

  private func drawCursor(
    _ cursor: LocusTermCursor,
    visible: Bool,
    in context: CGContext
  ) {
    guard visible else {
      return
    }

    cursorColor.setFill()
    caretRect(for: cursor).fill()
  }

  private func caretRect(for cursor: LocusTermCursor) -> NSRect {
    if cursor.style == 2 {
      let cellRect = TerminalPaneGeometry.cursorCellRect(
        cursor: cursor,
        bounds: bounds,
        metrics: metrics,
        insets: TerminalPaneLayoutMetrics.contentInsets
      )
      return NSRect(
        x: cellRect.minX,
        y: cellRect.minY,
        width: cellRect.width,
        height: TerminalCursorMetrics.thickness
      )
    }

    // The frame cannot distinguish the startup block cursor from an app's
    // explicit block request, so both block and bar styles use the quiet bar.
    return TerminalPaneGeometry.cursorBarRect(
      cursor: cursor,
      bounds: bounds,
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets
    )
  }

  private func drawMarkedText(_ cursor: LocusTermCursor, in context: CGContext) {
    guard let markedTextStorage, markedTextStorage.length > 0 else {
      return
    }

    let attributed = NSMutableAttributedString(attributedString: markedTextStorage)
    let range = NSRange(location: 0, length: attributed.length)
    attributed.addAttributes(
      [
        .font: metrics.font,
        .foregroundColor: NSColor.textColor,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ],
      range: range
    )
    let line = CTLineCreateWithAttributedString(attributed)
    let width = max(
      metrics.cellWidth,
      CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    )
    let x =
      TerminalPaneLayoutMetrics.contentInsets.left
      + CGFloat(cursor.x) * metrics.cellWidth
    backgroundColor.setFill()
    NSRect(x: x, y: rowRectY(cursor.y), width: width, height: metrics.cellHeight).fill()

    context.saveGState()
    context.textMatrix = .identity
    context.textPosition = CGPoint(
      x: x,
      y: bounds.height - rowTopOffset(cursor.y) - metrics.baselineOffset
    )
    CTLineDraw(line, context)
    context.restoreGState()

    let cursorX = min(
      x + width,
      bounds.maxX
        - TerminalPaneLayoutMetrics.contentInsets.right
        - TerminalCursorMetrics.thickness
    )
    cursorColor.setFill()
    NSRect(
      x: cursorX,
      y: rowRectY(cursor.y),
      width: TerminalCursorMetrics.thickness,
      height: metrics.cellHeight
    ).fill()
  }

  private var cursorColor: NSColor {
    NSColor.labelColor.withAlphaComponent(
      hasActiveKeyboardFocus
        ? TerminalCursorMetrics.activeAlpha
        : TerminalCursorMetrics.inactiveAlpha
    )
  }

  private func topLeftPoint(for event: NSEvent) -> NSPoint {
    let localPoint = convert(event.locationInWindow, from: nil)
    return NSPoint(x: localPoint.x, y: bounds.height - localPoint.y)
  }

  private func cellHit(
    for event: NSEvent,
    gridSize: TerminalGridSize
  ) -> (coordinate: TerminalCellCoordinate, fractionX: Float) {
    TerminalPaneGeometry.cellHit(
      for: topLeftPoint(for: event),
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets,
      grid: gridSize
    )
  }

  private func updateLinkHover(with event: NSEvent) {
    guard event.modifierFlags.contains(.command), mouseRouting == .none,
      let gridSize = currentGridSize()
    else {
      clearHoveredLink()
      restoreIBeamIfPointerIsInside(event)
      return
    }
    let hit = cellHit(for: event, gridSize: gridSize)
    guard let link = resolvedLink(at: hit.coordinate) else {
      clearHoveredLink()
      NSCursor.iBeam.set()
      return
    }
    guard hoveredLink != link else {
      NSCursor.pointingHand.set()
      return
    }

    hoveredLink = link
    toolTip = link.uri
    window?.invalidateCursorRects(for: self)
    requestViewPaint()
    NSCursor.pointingHand.set()
  }

  private func resolvedLink(at coordinate: TerminalCellCoordinate) -> HoveredLink? {
    guard let match = TerminalLinkHitTester.match(at: coordinate, in: linksForCurrentGeneration()),
      let uri = session?.linkURI(UInt32(match.linkID))
    else {
      return nil
    }
    return HoveredLink(match: match, uri: uri)
  }

  private func linksForCurrentGeneration() -> [TerminalLinkMatch] {
    guard let session, let generation = session.snapshot?.generation else {
      return []
    }
    if let cachedLinks, cachedLinks.generation == generation {
      return cachedLinks.matches
    }
    let matches = session.viewportLinks()
    cachedLinks = (generation, matches)
    return matches
  }

  private func linkSegments(for linkID: UInt16) -> [TerminalLinkMatch] {
    guard let generation = session?.snapshot?.generation,
      let cachedLinks,
      cachedLinks.generation == generation
    else {
      return []
    }
    return cachedLinks.matches.filter { $0.linkID == linkID }
  }

  private func clearHoveredLink() {
    guard hoveredLink != nil || toolTip != nil else {
      return
    }
    hoveredLink = nil
    toolTip = nil
    window?.invalidateCursorRects(for: self)
    requestViewPaint()
  }

  private func restoreIBeamIfPointerIsInside(_ event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if bounds.contains(point) {
      NSCursor.iBeam.set()
    }
  }

  private func startSelectionAutoscrollIfNeeded() {
    guard selectionAutoscrollTimer == nil else {
      return
    }
    let timer = Timer(
      timeInterval: Self.selectionAutoscrollInterval,
      target: self,
      selector: #selector(selectionAutoscrollTimerDidFire(_:)),
      userInfo: nil,
      repeats: true
    )
    timer.tolerance = 0.01
    RunLoop.main.add(timer, forMode: .common)
    selectionAutoscrollTimer = timer
  }

  private func stopSelectionAutoscroll() {
    selectionAutoscrollTimer?.invalidate()
    selectionAutoscrollTimer = nil
    lastAutoscrollContext = nil
  }

  @objc private func selectionAutoscrollTimerDidFire(_ timer: Timer) {
    guard mouseRouting == .localSelection, let context = lastAutoscrollContext else {
      stopSelectionAutoscroll()
      return
    }
    session?.selectionAutoscrollTick(
      direction: context.direction,
      column: context.column,
      cellFractionX: context.fractionX,
      rectangle: lastDragRectangle
    )
  }

  private func distance(from start: NSPoint, to end: NSPoint) -> CGFloat {
    hypot(end.x - start.x, end.y - start.y)
  }

  private func moveCaret(to clickedCoordinate: TerminalCellCoordinate) {
    guard let session else {
      return
    }
    var cursorCoordinate: TerminalCellCoordinate?
    var resolvedColumn: UInt16?
    session.withFrame { frame in
      guard frame.columns > 0, frame.rows > 0 else {
        return
      }
      cursorCoordinate = TerminalCellCoordinate(
        column: min(frame.cursor.x, frame.columns - 1),
        row: min(frame.cursor.y, frame.rows - 1)
      )
      let frameRows = terminalBlankRows(frame: frame)
      if let column = TerminalCaretClickResolver.resolveCaretClick(
        row: Int(min(clickedCoordinate.row, frame.rows - 1)),
        column: Int(min(clickedCoordinate.column, frame.columns - 1)),
        cursorRow: Int(frame.cursor.y),
        frameRows: frameRows
      ) {
        resolvedColumn = UInt16(clamping: column)
      }
    }
    guard let cursorCoordinate, let resolvedColumn else {
      return
    }
    let destination = TerminalCellCoordinate(
      column: resolvedColumn,
      row: cursorCoordinate.row
    )
    let events = TerminalCaretMovement.events(from: cursorCoordinate, to: destination)
    guard !events.isEmpty else {
      return
    }
    resetCaretBlink()
    sendTerminalKeys(events)
  }

  private func observeActiveFocusChanges() {
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(activeFocusStateDidChange(_:)),
      name: NSApplication.didBecomeActiveNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(activeFocusStateDidChange(_:)),
      name: NSApplication.didResignActiveNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(activeFocusStateDidChange(_:)),
      name: NSWindow.didBecomeKeyNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(activeFocusStateDidChange(_:)),
      name: NSWindow.didResignKeyNotification,
      object: nil
    )
  }

  @objc private func activeFocusStateDidChange(_ notification: Notification) {
    if let notificationWindow = notification.object as? NSWindow,
      notificationWindow !== window
    {
      return
    }
    lastDrawnCaretVisibility = nil
    requestViewPaint()
  }

  private func caretIsVisible(cursor: LocusTermCursor, at time: TimeInterval) -> Bool {
    guard cursor.visible else {
      return false
    }
    guard hasActiveKeyboardFocus, !hasMarkedText() else {
      return true
    }
    return TerminalCaretBlink.caretVisible(
      at: time,
      lastInput: lastCaretInputTime,
      blinking: TerminalCaretBlink.effectiveBlinking(cursor.blinking)
    )
  }

  @discardableResult
  private func invalidateCaretForBlinkIfNeeded(at time: TimeInterval) -> Bool {
    guard
      hasActiveKeyboardFocus,
      !hasMarkedText(),
      let snapshot = session?.snapshot,
      snapshot.cursorVisible
    else {
      return false
    }

    let blinking = TerminalCaretBlink.effectiveBlinking(snapshot.cursorBlinking)
    let currentVisible = TerminalCaretBlink.caretVisible(
      at: time,
      lastInput: lastCaretInputTime,
      blinking: blinking
    )
    guard
      TerminalCaretInvalidation.shouldInvalidate(
        previousDrawnVisible: lastDrawnCaretVisibility,
        currentVisible: currentVisible,
        focused: true,
        blinking: blinking
      )
    else {
      return false
    }

    if backend == .metal {
      let rendered = renderMetalFrame()
      if backend == .metal {
        return rendered
      }
    }

    var currentRect: NSRect?
    if currentVisible {
      session?.withFrame { frame in
        if frame.cursor.visible {
          currentRect = caretRect(for: frame.cursor)
        }
      }
    }
    guard
      let invalidationRect = TerminalCaretInvalidation.invalidationRect(
        previous: lastDrawnCaretRect,
        current: currentRect
      )
    else {
      return false
    }
    setNeedsDisplay(invalidationRect)
    return false
  }

  func invalidateCaretForBlinkForTesting(at time: TimeInterval) {
    invalidateCaretForBlinkIfNeeded(at: time)
  }

  private func resetCaretBlink() {
    lastCaretInputTime = CACurrentMediaTime()
    caretResetObserver?()
    requestViewPaint()
  }

  private func sendTerminalKey(_ event: TerminalKeyEvent) {
    keyEventObserver?(event)
    session?.sendKey(event)
  }

  private func sendTerminalKeys(_ events: [TerminalKeyEvent]) {
    guard !events.isEmpty else {
      return
    }
    for event in events {
      keyEventObserver?(event)
    }
    session?.sendKeys(events)
  }

  private func terminalBlankRows(frame: TerminalFrame) -> [Bool] {
    var result = [Bool](repeating: true, count: Int(frame.rows))
    frame.withRows { rows in
      frame.withCells { cells in
        for row in rows where Int(row.y) < result.count {
          result[Int(row.y)] = TerminalRowShapingCache.cellRange(
            for: row,
            cells: cells
          ).allSatisfy { index in
            let codepoint = cells[index].codepoint
            guard codepoint != 0 else {
              return true
            }
            return UnicodeScalar(codepoint)?.properties.isWhitespace == true
          }
        }
      }
    }
    return result
  }

  private func clearMarkedText() {
    markedTextStorage = nil
    markedSelection = NSRange(location: NSNotFound, length: 0)
    requestViewPaint()
  }

  private static func string(fromTextInput input: Any) -> String {
    if let attributed = input as? NSAttributedString {
      return attributed.string
    }
    if let string = input as? String {
      return string
    }
    return String(describing: input)
  }

  private static func attributedString(fromTextInput input: Any) -> NSAttributedString {
    if let attributed = input as? NSAttributedString {
      return attributed
    }
    return NSAttributedString(string: string(fromTextInput: input))
  }

  func clearRowTextPoolForTesting() {
    rowShapingCache.clear()
  }

  private func rowTopOffset(_ row: UInt16) -> CGFloat {
    TerminalPaneGeometry.rowTopOffset(
      row,
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets
    )
  }

  private func rowRectY(_ row: UInt16) -> CGFloat {
    TerminalPaneGeometry.rowRectY(
      row,
      bounds: bounds,
      metrics: metrics,
      insets: TerminalPaneLayoutMetrics.contentInsets
    )
  }

  private func rowPaintRect(_ row: UInt16) -> NSRect {
    NSRect(
      x: bounds.minX,
      y: rowRectY(row),
      width: bounds.width,
      height: metrics.cellHeight
    )
  }

  private func resolvedForegroundColor(for style: TerminalTextStyle) -> NSColor {
    var foreground = nsColor(forForeground: style.resolvedColors.foreground)
    if style.flags.contains(.faint) {
      foreground = foreground.withAlphaComponent(0.55)
    }
    return foreground
  }

  private func nsColor(forForeground color: TerminalColor) -> NSColor {
    color == .defaultForeground ? .textColor : color.nsColor
  }
}
