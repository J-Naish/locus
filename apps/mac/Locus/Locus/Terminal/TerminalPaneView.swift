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

  static func translate(_ input: TerminalKeyInput) -> TerminalKeyEvent? {
    let flags = NSEvent.ModifierFlags(rawValue: input.modifierFlagsRawValue)
    let modifiers = terminalModifiers(
      flags: flags,
      rawValue: input.modifierFlagsRawValue
    )
    guard !modifiers.contains(.command) else {
      return nil
    }

    let key = terminalKey(for: input.keyCode)
    let text = terminalText(for: input, modifiers: modifiers, key: key)
    return TerminalKeyEvent(
      action: input.isARepeat ? LOCUS_TERM_ACTION_REPEAT : LOCUS_TERM_ACTION_PRESS,
      key: key,
      modifiers: modifiers,
      consumedModifiers: [],
      composing: false,
      utf8: Data(text.utf8),
      unshiftedCodepoint: input.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0
    )
  }

  static func shouldInterpretText(_ input: TerminalKeyInput) -> Bool {
    let flags = NSEvent.ModifierFlags(rawValue: input.modifierFlagsRawValue)
    guard !flags.contains(.command), !flags.contains(.control) else {
      return false
    }
    return terminalKey(for: input.keyCode) == LOCUS_TERM_KEY_UNIDENTIFIED
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
    default:
      return LOCUS_TERM_KEY_UNIDENTIFIED
    }
  }
}

struct TerminalPane: NSViewRepresentable {
  let session: TerminalSession
  var onViewReady: ((TerminalPaneView) -> Void)?

  init(
    session: TerminalSession,
    onViewReady: ((TerminalPaneView) -> Void)? = nil
  ) {
    self.session = session
    self.onViewReady = onViewReady
  }

  func makeNSView(context: Context) -> TerminalPaneView {
    let view = TerminalPaneView(session: session)
    view.onWindowChange = onViewReady
    onViewReady?(view)
    return view
  }

  func updateNSView(_ nsView: TerminalPaneView, context: Context) {
    nsView.session = session
    nsView.onWindowChange = onViewReady
  }

  static func dismantleNSView(_ nsView: TerminalPaneView, coordinator: Void) {
    nsView.onWindowChange = nil
  }
}

final class TerminalPaneView: NSView, @preconcurrency NSTextInputClient {
  var onWindowChange: ((TerminalPaneView) -> Void)?
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
  private var markedTextStorage: NSAttributedString?
  private var markedSelection = NSRange(location: NSNotFound, length: 0)
  private var handledTextDuringKeyInterpretation = false

  override var acceptsFirstResponder: Bool { true }
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
    onWindowChange?(self)
  }

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateTerminalSizeIfNeeded()
  }

  override func layout() {
    super.layout()
    updateTerminalSizeIfNeeded()
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    super.mouseDown(with: event)
  }

  override func keyDown(with event: NSEvent) {
    let input = TerminalKeyInput(event: event)
    guard TerminalKeyTranslator.translate(input) != nil else {
      super.keyDown(with: event)
      return
    }

    let hadMarkedText = hasMarkedText()
    handledTextDuringKeyInterpretation = false
    if hadMarkedText || TerminalKeyTranslator.shouldInterpretText(input) {
      interpretKeyEvents([event])
      if hadMarkedText || handledTextDuringKeyInterpretation {
        return
      }
    }

    if let translated = TerminalKeyTranslator.translate(input) {
      session?.sendKey(translated)
    }
  }

  override func doCommand(by selector: Selector) {
    // Key bindings such as arrows and Enter return to keyDown for terminal
    // translation. Swallowing the AppKit command prevents the system beep.
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    handledTextDuringKeyInterpretation = true
    clearMarkedText()
    let text = Self.string(fromTextInput: string)
    guard !text.isEmpty else {
      return
    }
    session?.send(Data(text.utf8))
  }

  func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    handledTextDuringKeyInterpretation = true
    let attributed = Self.attributedString(fromTextInput: string)
    if attributed.length == 0 {
      clearMarkedText()
      return
    }
    markedTextStorage = attributed
    markedSelection = selectedRange
    needsDisplay = true
  }

  func unmarkText() {
    handledTextDuringKeyInterpretation = true
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

    var cursorX: UInt16 = 0
    var cursorY: UInt16 = 0
    session?.withFrame { frame in
      cursorX = frame.cursor.x
      cursorY = frame.cursor.y
    }
    let localRect = NSRect(
      x: CGFloat(cursorX) * metrics.cellWidth,
      y: rowRectY(cursorY),
      width: metrics.cellWidth,
      height: metrics.cellHeight
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
    if hasMarkedText() {
      drawMarkedText(frame.cursor, in: context)
    } else {
      drawCursor(frame.cursor, in: context)
    }
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
    let x = CGFloat(cursor.x) * metrics.cellWidth
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
  }

  private func clearMarkedText() {
    markedTextStorage = nil
    markedSelection = NSRange(location: NSNotFound, length: 0)
    needsDisplay = true
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
