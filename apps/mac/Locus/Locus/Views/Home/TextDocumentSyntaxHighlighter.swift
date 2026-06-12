import AppKit
import Foundation

// Tested in TextViewportLayoutTests.swift and WorkspaceTextDocumentSupportTests.swift
// (there is no TextDocumentSyntaxHighlighterTests.swift).
enum TextDocumentSyntax: Equatable, Sendable {
  case markdown
  case structuredText
  case code
  case plainText

  var font: NSFont {
    switch self {
    case .markdown:
      return .systemFont(ofSize: 15)
    case .plainText:
      return .monospacedSystemFont(ofSize: 12, weight: .regular)
    case .structuredText, .code:
      return .monospacedSystemFont(ofSize: 13, weight: .regular)
    }
  }

  var lineHeight: CGFloat {
    switch self {
    case .markdown:
      return 24
    case .plainText:
      return ceil(font.ascender - font.descender + font.leading)
    case .structuredText, .code:
      return ceil(font.ascender - font.descender + font.leading)
    }
  }

  /// Whether the text viewer shows a line-number gutter for this syntax.
  var supportsLineNumbers: Bool {
    switch self {
    case .markdown:
      return false
    case .plainText, .structuredText, .code:
      return true
    }
  }
}

enum MarkdownDocumentMetrics {
  static let maxMeasureWidth: CGFloat = 600
  static let minimumHorizontalPadding: CGFloat = 32
  static let bodyFontSize: CGFloat = 15
  static let inlineCodeFontSize: CGFloat = 13
  static let codeBlockFontSize: CGFloat = 13
  static let codeFenceFontSize: CGFloat = 11
  static let quoteBarWidth: CGFloat = 3
  static let quoteBarInset: CGFloat = 14
  static let markerColumnWidth: CGFloat = 24
  static let quoteIndentWidth: CGFloat = 17
  static let checkboxSize: CGFloat = 14
  static let codeCardInset: CGFloat = 12
  static let codeBlockCornerRadius: CGFloat = 8
  static let inlineCodeCornerRadius: CGFloat = 4
  static let tableColumnGutter: CGFloat = 40
  static let tableColumnMinimumWidth: CGFloat = 48
  static let tableColumnMaximumWidth: CGFloat = 240
  static let tableFallbackColumnWidth: CGFloat = 160
  static let tableHeaderFontSize: CGFloat = 12
  /// How far the top and bottom rules breathe outward into an adjacent blank
  /// line, so the text inside the table is never pressed against its rules.
  static let tableRuleBreath: CGFloat = 4
  /// Row height of marker-only rows (table delimiters, setext underlines) —
  /// slim rows, so structural source lines read as spacing instead of
  /// consuming a full text row.
  static let slimMarkerRowHeight: CGFloat = 6
  /// Horizontal inset between the rules' ends and the first/last column's
  /// text, so the rules extend slightly past the content on both sides.
  static let tableEdgeInset: CGFloat = 10

  static func headingFont(level: Int) -> NSFont {
    switch level {
    case 1:
      return .systemFont(ofSize: 28, weight: .bold)
    case 2:
      return .systemFont(ofSize: 22, weight: .bold)
    case 3:
      return .systemFont(ofSize: 19, weight: .semibold)
    case 4:
      return .systemFont(ofSize: 16, weight: .semibold)
    case 5:
      return .systemFont(ofSize: 14, weight: .semibold)
    default:
      return .systemFont(ofSize: 13, weight: .semibold)
    }
  }

  /// Slight negative tracking tightens large bold headings the way the system
  /// treats large titles; zero for body-adjacent sizes.
  static func headingTracking(level: Int) -> CGFloat {
    switch level {
    case 1:
      return -0.4
    case 2:
      return -0.2
    default:
      return 0
    }
  }

  /// Breathing room around a heading line: generous above, tight below, so the
  /// heading binds to the section it introduces.
  static func headingInsets(level: Int) -> (leading: CGFloat, trailing: CGFloat) {
    switch level {
    case 1:
      return (22, 6)
    case 2:
      return (18, 5)
    case 3:
      return (14, 4)
    case 4:
      return (10, 3)
    default:
      return (8, 2)
    }
  }

  /// Leading inset for a heading on the document's first line — the title sits
  /// at the page top instead of floating below sectional air.
  static let documentTopHeadingInset: CGFloat = 4

  static var inlineCodeBackground: NSColor {
    codeBackground.withAlphaComponent(0.75)
  }

  static var codeBackground: NSColor {
    let card = LocusChromeColors.documentCard.usingColorSpace(.sRGB) ?? .textBackgroundColor
    let appearance = NSAppearance.currentDrawing()
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    if dark {
      return card.blended(withFraction: 0.18, of: .white) ?? NSColor.controlBackgroundColor
    }
    return card.blended(withFraction: 0.05, of: .black) ?? NSColor.controlBackgroundColor
  }

  static var ruleColor: NSColor { .separatorColor }
  static var accentColor: NSColor { .controlAccentColor }
  static var markerColor: NSColor { .tertiaryLabelColor }
  static var tableRuleColor: NSColor { .separatorColor }

  static var tableHeaderFont: NSFont {
    .systemFont(ofSize: tableHeaderFontSize, weight: .semibold)
  }
}

enum MarkdownTableColumnAlignment: Equatable, Sendable {
  case left
  case center
  case right
}

struct MarkdownTableColumn: Equatable, Sendable {
  var width: CGFloat
  var alignment: MarkdownTableColumnAlignment
}

struct MarkdownLineStyleState: Equatable, Sendable {
  var insideFence = false
  var setextHeadingLevel: Int?
  var isSetextUnderline = false
  /// 1–6 when the line renders as a heading (ATX or setext text line).
  var headingLevel: Int?
  var insideFrontMatter = false
  var isFenceDelimiter = false
  var isIndentedCodeBlock = false
  var isReferenceDefinition = false
  var isTableRow = false
  var isTableHeader = false
  var isTableSeparator = false
  var tableColumns: [MarkdownTableColumn] = []
  var quoteDepth = 0
  var listDepth = 0

  static let plain = MarkdownLineStyleState()
}

struct MarkdownFontSet: @unchecked Sendable {
  let regular: NSFont
  let bold: NSFont
  let italic: NSFont
  let boldItalic: NSFont
}

struct MarkdownTypography: @unchecked Sendable {
  let body: MarkdownFontSet
  let headings: [MarkdownFontSet]
  let inlineCode: NSFont
  let codeBlock: NSFont
  let codeFence: NSFont

  init(baseFont: NSFont) {
    let manager = NSFontManager.shared
    self.init(baseFont: baseFont) { manager.convert($0, toHaveTrait: .italicFontMask) }
  }

  /// A typography whose italic variants reuse the upright fonts. Italic
  /// advances match the upright ones for the system font, so this measures
  /// identically — without touching `NSFontManager`, which is not safe off
  /// the main thread (table column widths are computed on the wrap worker).
  static func measurement(baseFont: NSFont) -> MarkdownTypography {
    MarkdownTypography(baseFont: baseFont) { $0 }
  }

  init(baseFont: NSFont, italicize: (NSFont) -> NSFont) {
    func fontSet(base: NSFont, boldWeight: NSFont.Weight = .bold) -> MarkdownFontSet {
      let bold = NSFont.systemFont(ofSize: base.pointSize, weight: boldWeight)
      let italic = italicize(base)
      return MarkdownFontSet(
        regular: base,
        bold: bold,
        italic: italic,
        boldItalic: italicize(bold)
      )
    }

    body = fontSet(base: baseFont)
    headings = (1...6).map { level in
      let regular = MarkdownDocumentMetrics.headingFont(level: level)
      return fontSet(base: regular)
    }
    inlineCode = .monospacedSystemFont(
      ofSize: MarkdownDocumentMetrics.inlineCodeFontSize, weight: .regular)
    codeBlock = .monospacedSystemFont(
      ofSize: MarkdownDocumentMetrics.codeBlockFontSize, weight: .regular)
    codeFence = .monospacedSystemFont(
      ofSize: MarkdownDocumentMetrics.codeFenceFontSize, weight: .regular)
  }

  func heading(level: Int) -> MarkdownFontSet {
    headings[min(max(1, level), headings.count) - 1]
  }
}

struct MarkdownDisplayMap: Equatable, Sendable {
  let sourceText: String
  let displayText: String
  private let boundaryColumns: [Int]
  private let characterRanges: [NSRange]

  init(
    sourceText: String,
    displayText: String,
    boundaryColumns: [Int],
    characterRanges: [NSRange]
  ) {
    let displayLength = (displayText as NSString).length
    self.sourceText = sourceText
    self.displayText = displayText
    if boundaryColumns.count == displayLength + 1 {
      self.boundaryColumns = boundaryColumns
    } else {
      self.boundaryColumns = Array(0...displayLength)
    }
    if characterRanges.count == displayLength {
      self.characterRanges = characterRanges
    } else {
      self.characterRanges = (0..<displayLength).map { NSRange(location: $0, length: 1) }
    }
  }

  var displayLength: Int { (displayText as NSString).length }
  var sourceLength: Int { (sourceText as NSString).length }

  static func identity(_ text: String) -> MarkdownDisplayMap {
    map(sourceText: text, displayText: text, sourceStart: 0)
  }

  static func empty(sourceText: String, insertionColumn: Int? = nil) -> MarkdownDisplayMap {
    let length = (sourceText as NSString).length
    return MarkdownDisplayMap(
      sourceText: sourceText,
      displayText: "",
      boundaryColumns: [min(max(0, insertionColumn ?? length), length)],
      characterRanges: [])
  }

  static func map(sourceText: String, displayText: String, sourceStart: Int) -> MarkdownDisplayMap {
    let displayLength = (displayText as NSString).length
    let sourceLength = (sourceText as NSString).length
    let start = min(max(0, sourceStart), sourceLength)
    return MarkdownDisplayMap(
      sourceText: sourceText,
      displayText: displayText,
      boundaryColumns: (0...displayLength).map { min(sourceLength, start + $0) },
      characterRanges: (0..<displayLength).map {
        NSRange(location: min(sourceLength, start + $0), length: 1)
      })
  }

  func bufferColumn(forDisplayColumn column: Int) -> Int {
    let clamped = min(max(0, column), displayLength)
    return boundaryColumns[clamped]
  }

  func displayColumn(forBufferColumn column: Int) -> Int {
    let clamped = min(max(0, column), sourceLength)
    var best = 0
    var bestDistance = Int.max
    for (index, boundary) in boundaryColumns.enumerated() {
      let distance = abs(boundary - clamped)
      if distance < bestDistance || (distance == bestDistance && boundary <= clamped) {
        best = index
        bestDistance = distance
      }
    }
    return min(max(0, best), displayLength)
  }

  func bufferRange(forDisplayStart start: Int, end: Int, includeWholeLineMarkers: Bool) -> NSRange {
    let lower = min(max(0, start), displayLength)
    let upper = min(max(0, end), displayLength)
    guard upper > lower else {
      let column = bufferColumn(forDisplayColumn: lower)
      return NSRange(location: column, length: 0)
    }
    if includeWholeLineMarkers, lower == 0, upper == displayLength {
      return NSRange(location: 0, length: sourceLength)
    }
    let selectedRanges = characterRanges[lower..<upper]
    let rawStart = selectedRanges.map(\.location).min() ?? bufferColumn(forDisplayColumn: lower)
    let rawEnd = selectedRanges.map { NSMaxRange($0) }.max() ?? rawStart
    return NSRange(location: rawStart, length: max(0, rawEnd - rawStart))
  }

  fileprivate func replacing(match matchRange: NSRange, withGroup groupRange: NSRange)
    -> MarkdownDisplayMap
  {
    let nsDisplay = displayText as NSString
    let displayLength = nsDisplay.length
    guard matchRange.location >= 0, groupRange.location >= 0,
      NSMaxRange(matchRange) <= displayLength,
      NSMaxRange(groupRange) <= displayLength,
      NSIntersectionRange(matchRange, groupRange) == groupRange
    else {
      return self
    }

    let prefix = nsDisplay.substring(to: matchRange.location)
    let replacement = nsDisplay.substring(with: groupRange)
    let suffix = nsDisplay.substring(from: NSMaxRange(matchRange))
    let newText = prefix + replacement + suffix

    var newBoundaries: [Int] = []
    if matchRange.location > 0 {
      newBoundaries.append(contentsOf: boundaryColumns[0..<matchRange.location])
    }
    newBoundaries.append(contentsOf: boundaryColumns[groupRange.location...NSMaxRange(groupRange)])
    if NSMaxRange(matchRange) < displayLength {
      newBoundaries.append(
        contentsOf: boundaryColumns[(NSMaxRange(matchRange) + 1)...displayLength])
    }

    var newCharacterRanges: [NSRange] = []
    if matchRange.location > 0 {
      newCharacterRanges.append(contentsOf: characterRanges[0..<matchRange.location])
    }
    if groupRange.length > 0 {
      newCharacterRanges.append(
        contentsOf: characterRanges[groupRange.location..<NSMaxRange(groupRange)])
    }
    if NSMaxRange(matchRange) < displayLength {
      newCharacterRanges.append(contentsOf: characterRanges[NSMaxRange(matchRange)..<displayLength])
    }

    return MarkdownDisplayMap(
      sourceText: sourceText,
      displayText: newText,
      boundaryColumns: newBoundaries,
      characterRanges: newCharacterRanges)
  }
}

enum TextDocumentSyntaxHighlighter {
  // Rule highlighting is skipped when the text passed to a *single* `apply`
  // call exceeds this size, to avoid broad regex work on the main thread. This
  // is a per-call limit on the supplied `text`, not on the whole document: the
  // editable path passes the entire document (so large files fall back to base
  // styling), while the large-file viewer passes one visible line at a time (so
  // it stays highlighted regardless of total file size).
  static let maximumHighlightedUTF16Length = 200_000

  static func apply(
    to textStorage: NSTextStorage?,
    text: String,
    syntax: TextDocumentSyntax,
    font: NSFont
  ) {
    guard let textStorage else {
      return
    }

    let fullRange = NSRange(location: 0, length: (text as NSString).length)
    apply(to: textStorage, text: text, syntax: syntax, font: font, range: fullRange)
  }

  // Accepts any `NSMutableAttributedString` (an `NSTextStorage` is one) so the
  // editable path can style its storage and the large-file viewer can style a
  // throwaway per-band string with the same rules.
  static func apply(
    to textStorage: NSMutableAttributedString,
    text: String,
    syntax: TextDocumentSyntax,
    font: NSFont,
    range: NSRange,
    applyRules: Bool = true,
    markdownTypography: MarkdownTypography? = nil
  ) {
    let textLength = (text as NSString).length
    let highlightedRange = range.clamped(toTextLength: textLength)
    guard highlightedRange.length > 0 else {
      return
    }

    textStorage.beginEditing()
    defer {
      textStorage.endEditing()
    }
    textStorage.setAttributes(baseAttributes(font: font), range: highlightedRange)
    // Base styling (font/color) is always applied; rule highlighting is skipped
    // when the caller opts out (e.g. a pathologically long line) or the text is
    // too large to scan on the main thread.
    guard applyRules, textLength <= maximumHighlightedUTF16Length else {
      return
    }

    switch syntax {
    case .markdown:
      highlightMarkdownDocument(
        text,
        in: textStorage,
        range: highlightedRange,
        typography: markdownTypography ?? MarkdownTypography(baseFont: font),
        includeVisualAttributes: true)
    case .structuredText:
      highlightStructuredText(text, in: textStorage, range: highlightedRange)
    case .code:
      highlightCode(text, in: textStorage, range: highlightedRange)
    case .plainText:
      break
    }
  }

  static func highlightedLine(
    _ line: String,
    syntax: TextDocumentSyntax,
    font: NSFont,
    applyRules: Bool = true,
    markdownLineState: MarkdownLineStyleState = .plain,
    markdownTypography: MarkdownTypography? = nil
  ) -> NSAttributedString {
    let visible = line
    if syntax == .markdown {
      return renderedMarkdownLine(
        visible,
        font: font,
        state: markdownLineState,
        typography: markdownTypography ?? MarkdownTypography(baseFont: font),
        includeVisualAttributes: true)
    }
    let attributed = NSMutableAttributedString(string: visible)
    let fullRange = NSRange(location: 0, length: (visible as NSString).length)
    apply(
      to: attributed, text: visible, syntax: syntax, font: font, range: fullRange,
      applyRules: applyRules)
    return attributed
  }

  static func markdownMeasurementLine(
    _ line: String,
    font: NSFont,
    state: MarkdownLineStyleState,
    typography: MarkdownTypography
  ) -> NSAttributedString {
    renderedMarkdownLine(
      line,
      font: font,
      state: state,
      typography: typography,
      includeVisualAttributes: false)
  }

  static func renderedMarkdownLineText(
    _ line: String,
    font: NSFont,
    state: MarkdownLineStyleState = .plain,
    typography: MarkdownTypography? = nil
  ) -> String {
    renderedMarkdownLine(
      line,
      font: font,
      state: state,
      typography: typography ?? MarkdownTypography(baseFont: font),
      includeVisualAttributes: false
    )
    .string
  }

  static func markdownDisplayMap(
    for line: String,
    state: MarkdownLineStyleState = .plain
  ) -> MarkdownDisplayMap {
    renderedMarkdownDisplayMap(line, state: state)
  }

  static func isMarkdownFenceLine(_ line: String) -> Bool {
    markdownFenceInfo(in: line) != nil
  }

  private struct MarkdownRenderedBlock {
    var text: String
    var fonts: MarkdownFontSet
    var font: NSFont
    var foregroundColor: NSColor
    var stylesInline: Bool
  }

  private struct MarkdownLineContext {
    let quoteDepth: Int
    let quotePrefixLength: Int
    let body: String
  }

  private static func renderedMarkdownLine(
    _ line: String,
    font: NSFont,
    state: MarkdownLineStyleState,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool
  ) -> NSAttributedString {
    let displayMap = renderedMarkdownBlockDisplayMap(line, state: state)
    let block = renderedMarkdownBlock(
      line, displayText: displayMap.displayText, font: font, state: state, typography: typography)
    let attributed = NSMutableAttributedString(string: displayMap.displayText)
    let fullRange = NSRange(location: 0, length: (displayMap.displayText as NSString).length)
    guard fullRange.length > 0 else {
      return attributed
    }
    attributed.setAttributes(
      markdownAttributes(
        font: block.font,
        foregroundColor: block.foregroundColor,
        includeVisualAttributes: includeVisualAttributes),
      range: fullRange)
    if let level = state.headingLevel {
      let tracking = MarkdownDocumentMetrics.headingTracking(level: level)
      if tracking != 0 {
        // Tracking affects glyph advances, so it applies to measurement and
        // drawing alike — never gate it on visual attributes.
        attributed.addAttribute(.kern, value: tracking, range: fullRange)
      }
    }
    if state.isTableRow {
      attributed.addAttribute(
        .paragraphStyle,
        value: markdownTableParagraphStyle(columns: state.tableColumns),
        range: fullRange)
    }
    if block.stylesInline {
      applyRenderedMarkdownInline(
        to: attributed,
        lineFonts: block.fonts,
        typography: typography,
        includeVisualAttributes: includeVisualAttributes)
    }
    return attributed
  }

  private static func renderedMarkdownBlock(
    _ line: String,
    displayText: String,
    font: NSFont,
    state: MarkdownLineStyleState,
    typography: MarkdownTypography
  ) -> MarkdownRenderedBlock {
    func block(
      fonts: MarkdownFontSet = typography.body,
      displayFont: NSFont? = nil,
      foregroundColor: NSColor = .labelColor,
      stylesInline: Bool = true
    ) -> MarkdownRenderedBlock {
      MarkdownRenderedBlock(
        text: displayText,
        fonts: fonts,
        font: displayFont ?? font,
        foregroundColor: foregroundColor,
        stylesInline: stylesInline)
    }

    let context = markdownLineContext(in: line)

    if state.insideFrontMatter {
      return block(
        displayFont: typography.codeBlock,
        foregroundColor: .secondaryLabelColor,
        stylesInline: false)
    }

    if state.isReferenceDefinition || state.isTableSeparator {
      return block(stylesInline: false)
    }

    if state.isTableHeader {
      return block(
        displayFont: MarkdownDocumentMetrics.tableHeaderFont,
        foregroundColor: .secondaryLabelColor)
    }

    if state.isIndentedCodeBlock {
      return block(displayFont: typography.codeBlock, stylesInline: false)
    }

    if state.isFenceDelimiter, markdownFenceInfo(in: line) != nil {
      return block(
        displayFont: typography.codeFence,
        foregroundColor: .secondaryLabelColor,
        stylesInline: false)
    }

    if state.insideFence {
      return block(displayFont: typography.codeBlock, stylesInline: false)
    }

    if let level = state.setextHeadingLevel {
      let fonts = typography.heading(level: level)
      return block(
        fonts: fonts,
        displayFont: fonts.regular,
        foregroundColor: level == 6 ? .secondaryLabelColor : .labelColor)
    }

    if state.isSetextUnderline {
      return block(stylesInline: false)
    }

    if let heading = markdownHeadingInfo(in: context.body) {
      let fonts = typography.heading(level: heading.level)
      return block(
        fonts: fonts,
        displayFont: fonts.regular,
        foregroundColor: heading.level == 6 ? .secondaryLabelColor : .labelColor)
    }

    if markdownThematicBreak(in: context.body) {
      return block(stylesInline: false)
    }

    if markdownBlockPrefixLength(in: context.body, allowIndentedList: state.listDepth > 0) != nil {
      return block()
    }

    return block()
  }

  private static func renderedMarkdownDisplayMap(
    _ line: String,
    state: MarkdownLineStyleState
  ) -> MarkdownDisplayMap {
    let baseMap = renderedMarkdownBlockDisplayMap(line, state: state)
    let context = markdownLineContext(in: line)
    guard !state.insideFence, !state.insideFrontMatter, !state.isSetextUnderline,
      !state.isIndentedCodeBlock, !state.isReferenceDefinition, !state.isTableSeparator,
      !markdownThematicBreak(in: context.body)
    else {
      return baseMap
    }
    return renderedInlineDisplayMap(from: baseMap)
  }

  private static func renderedMarkdownBlockDisplayMap(
    _ line: String,
    state: MarkdownLineStyleState
  ) -> MarkdownDisplayMap {
    let nsLine = line as NSString
    let sourceLength = nsLine.length
    let context = markdownLineContext(in: line)

    if state.isReferenceDefinition || state.isTableSeparator {
      return .empty(sourceText: line)
    }

    if state.isTableRow, let table = markdownTableDisplayMap(for: line) {
      return table
    }

    if state.insideFrontMatter {
      if markdownFrontMatterDelimiter(in: line) {
        return .empty(sourceText: line)
      }
      return .identity(line)
    }
    if state.isFenceDelimiter, let fence = markdownFenceInfo(in: line) {
      if state.insideFence {
        return .empty(sourceText: line)
      }
      let infoRange = markdownFenceInfoTextRange(in: line, markerLength: fence.markerLength)
      if infoRange.length > 0 {
        return .map(
          sourceText: line,
          displayText: nsLine.substring(with: infoRange),
          sourceStart: infoRange.location)
      }
      return .empty(sourceText: line)
    }
    if state.insideFence {
      return .identity(line)
    }
    if state.isIndentedCodeBlock {
      let body = context.body as NSString
      let startInBody = min(markdownLeadingSpaceLength(in: body), 4)
      let sourceStart = min(sourceLength, context.quotePrefixLength + startInBody)
      return .map(
        sourceText: line,
        displayText: nsLine.substring(from: sourceStart),
        sourceStart: sourceStart)
    }
    if state.isSetextUnderline || markdownThematicBreak(in: line) {
      return .empty(sourceText: line)
    }
    if let heading = markdownHeadingInfo(in: context.body) {
      let start = min(context.quotePrefixLength + heading.prefixLength, sourceLength)
      return .map(
        sourceText: line, displayText: nsLine.substring(from: start), sourceStart: start)
    }
    if let prefixLength = markdownBlockPrefixLength(
      in: context.body, allowIndentedList: state.listDepth > 0)
    {
      let start = min(context.quotePrefixLength + prefixLength, sourceLength)
      return .map(
        sourceText: line, displayText: nsLine.substring(from: start), sourceStart: start)
    }
    if context.quoteDepth > 0 {
      let start = min(context.quotePrefixLength, sourceLength)
      return .map(
        sourceText: line,
        displayText: nsLine.substring(from: start),
        sourceStart: start)
    }
    return .identity(line)
  }

  private static func markdownFenceInfoTextRange(in line: String, markerLength: Int) -> NSRange {
    let nsLine = line as NSString
    var index = 0
    while index < nsLine.length,
      nsLine.character(at: index) == 32 || nsLine.character(at: index) == 9
    {
      index += 1
    }
    index = min(nsLine.length, index + markerLength)
    while index < nsLine.length,
      nsLine.character(at: index) == 32 || nsLine.character(at: index) == 9
    {
      index += 1
    }
    var end = nsLine.length
    while end > index {
      let character = nsLine.character(at: end - 1)
      guard character == 32 || character == 9 else { break }
      end -= 1
    }
    return NSRange(location: index, length: max(0, end - index))
  }

  private static func renderedInlineDisplayMap(from map: MarkdownDisplayMap)
    -> MarkdownDisplayMap
  {
    var current = map
    var protectedRanges: [NSRange] = []
    replaceRenderedMatchesInMap(
      expression: escapeExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatchesInMap(
      expression: inlineCodeExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatchesInMap(
      expression: imageExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatchesInMap(
      expression: renderedLinkExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatchesInMap(
      expression: referenceLinkExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatchesInMap(
      expression: autolinkExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatchesInMap(
      expression: boldItalicExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true,
      allowsContainedProtectedRanges: true)
    replaceRenderedMatchesInMap(
      expression: boldExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true,
      allowsContainedProtectedRanges: true)
    replaceRenderedMatchesInMap(
      expression: italicExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true,
      allowsContainedProtectedRanges: true)
    replaceRenderedMatchesInMap(
      expression: strikeExpression,
      replacementGroup: 1,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true,
      allowsContainedProtectedRanges: true)
    return current
  }

  private static func replaceRenderedMatchesInMap(
    expression: NSRegularExpression,
    replacementGroup: Int,
    map: inout MarkdownDisplayMap,
    protectedRanges: inout [NSRange],
    protectsReplacement: Bool,
    allowsContainedProtectedRanges: Bool = false
  ) {
    let original = map.displayText
    let nsOriginal = original as NSString
    let matches = expression.matches(
      in: original,
      range: NSRange(location: 0, length: nsOriginal.length))
    var locationDelta = 0
    for match in matches {
      let group = match.range(at: replacementGroup)
      guard group.location != NSNotFound else { continue }
      let adjustedMatch = match.range.offset(by: locationDelta)
      let adjustedGroup = group.offset(by: locationDelta)
      guard
        !protectedRanges.contains(where: {
          protectedRangeBlocksReplacement(
            $0, match: adjustedMatch, group: adjustedGroup,
            allowsContainedProtectedRanges: allowsContainedProtectedRanges)
        })
      else {
        continue
      }
      guard adjustedMatch.location >= 0,
        NSMaxRange(adjustedMatch) <= map.displayLength,
        adjustedGroup.location >= 0,
        NSMaxRange(adjustedGroup) <= map.displayLength
      else {
        continue
      }
      let beforeLength = map.displayLength
      map = map.replacing(match: adjustedMatch, withGroup: adjustedGroup)
      let replacementRange = NSRange(location: adjustedMatch.location, length: adjustedGroup.length)
      let delta = map.displayLength - beforeLength
      locationDelta += delta
      protectedRanges = remapRanges(
        protectedRanges, replacing: adjustedMatch, withGroup: adjustedGroup, by: delta)
      if protectsReplacement, replacementRange.length > 0 {
        protectedRanges.append(replacementRange)
      }
    }
  }

  private static func applyRenderedMarkdownInline(
    to attributed: NSMutableAttributedString,
    lineFonts: MarkdownFontSet,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool
  ) {
    var protectedRanges: [NSRange] = []
    replaceRenderedMatches(
      expression: escapeExpression,
      replacementGroup: 1,
      attributes: markdownAttributes(
        font: lineFonts.regular,
        foregroundColor: .labelColor,
        includeVisualAttributes: includeVisualAttributes),
      in: attributed,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatches(
      expression: inlineCodeExpression,
      replacementGroup: 1,
      attributes: markdownInlineCodeAttributes(
        font: typography.inlineCode,
        includeVisualAttributes: includeVisualAttributes),
      in: attributed,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatches(
      expression: imageExpression,
      replacementGroup: 1,
      attributes: markdownAttributes(
        font: lineFonts.regular,
        foregroundColor: .secondaryLabelColor,
        includeVisualAttributes: includeVisualAttributes),
      in: attributed,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatches(
      expression: renderedLinkExpression,
      replacementGroup: 1,
      attributes: renderedLinkAttributes(
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes),
      in: attributed,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatches(
      expression: referenceLinkExpression,
      replacementGroup: 1,
      attributes: renderedLinkAttributes(
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes),
      in: attributed,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    replaceRenderedMatches(
      expression: autolinkExpression,
      replacementGroup: 1,
      attributes: renderedLinkAttributes(
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes),
      in: attributed,
      protectedRanges: &protectedRanges,
      protectsReplacement: true)
    applyRenderedDelimitedSpan(
      expression: boldItalicExpression,
      style: .boldItalic,
      to: attributed,
      lineFonts: lineFonts,
      protectedRanges: &protectedRanges,
      includeVisualAttributes: includeVisualAttributes)
    applyRenderedDelimitedSpan(
      expression: boldExpression,
      style: .bold,
      to: attributed,
      lineFonts: lineFonts,
      protectedRanges: &protectedRanges,
      includeVisualAttributes: includeVisualAttributes)
    applyRenderedDelimitedSpan(
      expression: italicExpression,
      style: .italic,
      to: attributed,
      lineFonts: lineFonts,
      protectedRanges: &protectedRanges,
      includeVisualAttributes: includeVisualAttributes)
    applyRenderedDelimitedSpan(
      expression: strikeExpression,
      style: .strike,
      to: attributed,
      lineFonts: lineFonts,
      protectedRanges: &protectedRanges,
      includeVisualAttributes: includeVisualAttributes)
  }

  private static func replaceRenderedMatches(
    expression: NSRegularExpression,
    replacementGroup: Int,
    attributes: [NSAttributedString.Key: Any],
    in attributed: NSMutableAttributedString,
    protectedRanges: inout [NSRange],
    protectsReplacement: Bool,
    allowsContainedProtectedRanges: Bool = false,
    preservesProtectedAttributes: Bool = false
  ) {
    let original = attributed.string
    let nsOriginal = original as NSString
    let matches = expression.matches(
      in: original,
      range: NSRange(location: 0, length: nsOriginal.length))
    var locationDelta = 0
    for match in matches {
      let group = match.range(at: replacementGroup)
      guard group.location != NSNotFound else { continue }
      let adjustedMatch = match.range.offset(by: locationDelta)
      let adjustedGroup = group.offset(by: locationDelta)
      guard
        !protectedRanges.contains(where: {
          protectedRangeBlocksReplacement(
            $0, match: adjustedMatch, group: adjustedGroup,
            allowsContainedProtectedRanges: allowsContainedProtectedRanges)
        })
      else {
        continue
      }
      guard adjustedGroup.location >= 0,
        NSMaxRange(adjustedGroup) <= (attributed.string as NSString).length
      else {
        continue
      }
      let preservedAttributes: [(range: NSRange, string: NSAttributedString)] =
        preservesProtectedAttributes
        ? protectedRanges.compactMap { range in
          guard range.location >= adjustedGroup.location,
            NSMaxRange(range) <= NSMaxRange(adjustedGroup)
          else {
            return nil
          }
          return (
            NSRange(
              location: adjustedMatch.location + (range.location - adjustedGroup.location),
              length: range.length),
            attributed.attributedSubstring(from: range)
          )
        }
        : []
      let replacement = attributed.attributedSubstring(from: adjustedGroup)
      let replacementLength = replacement.length
      attributed.replaceCharacters(in: adjustedMatch, with: replacement)
      let replacementRange = NSRange(location: adjustedMatch.location, length: replacementLength)
      if replacementLength > 0 {
        attributed.addAttributes(attributes, range: replacementRange)
        for preserved in preservedAttributes
        where preserved.range.length > 0
          && NSMaxRange(preserved.range) <= attributed.length
        {
          attributed.replaceCharacters(in: preserved.range, with: preserved.string)
        }
      }
      let delta = replacementLength - adjustedMatch.length
      locationDelta += delta
      protectedRanges = remapRanges(
        protectedRanges, replacing: adjustedMatch, withGroup: adjustedGroup, by: delta)
      if protectsReplacement {
        protectedRanges.append(replacementRange)
      }
    }
  }

  private static func applyRenderedDelimitedSpan(
    expression: NSRegularExpression,
    style: MarkdownDelimitedStyle,
    to attributed: NSMutableAttributedString,
    lineFonts: MarkdownFontSet,
    protectedRanges: inout [NSRange],
    includeVisualAttributes: Bool
  ) {
    var attributes: [NSAttributedString.Key: Any]
    switch style {
    case .boldItalic:
      attributes = [.font: lineFonts.boldItalic]
    case .bold:
      attributes = [.font: lineFonts.bold]
    case .italic:
      attributes = [.font: lineFonts.italic]
    case .strike:
      attributes = [.font: lineFonts.regular]
      if includeVisualAttributes {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
    }
    replaceRenderedMatches(
      expression: expression,
      replacementGroup: 1,
      attributes: attributes,
      in: attributed,
      protectedRanges: &protectedRanges,
      protectsReplacement: true,
      allowsContainedProtectedRanges: true,
      preservesProtectedAttributes: true)
  }

  private static func protectedRangeBlocksReplacement(
    _ protected: NSRange,
    match: NSRange,
    group: NSRange,
    allowsContainedProtectedRanges: Bool
  ) -> Bool {
    guard rangesIntersect(protected, match) else { return false }
    if allowsContainedProtectedRanges,
      protected.location >= group.location,
      NSMaxRange(protected) <= NSMaxRange(group)
    {
      return false
    }
    return true
  }

  private static func remapRanges(
    _ ranges: [NSRange],
    replacing match: NSRange,
    withGroup group: NSRange,
    by delta: Int
  ) -> [NSRange] {
    ranges.map { range in
      if range.location >= group.location, NSMaxRange(range) <= NSMaxRange(group) {
        return NSRange(
          location: match.location + (range.location - group.location),
          length: range.length)
      }
      if range.location >= NSMaxRange(match) {
        return NSRange(location: range.location + delta, length: range.length)
      }
      return range
    }
  }

  private static func markdownLineContext(in line: String) -> MarkdownLineContext {
    let nsLine = line as NSString
    var index = 0
    var depth = 0
    while index < nsLine.length {
      let markerStart = index
      var spaces = 0
      while spaces < 3, index < nsLine.length, nsLine.character(at: index) == 32 {
        spaces += 1
        index += 1
      }
      guard index < nsLine.length, nsLine.character(at: index) == 62 else {  // ">"
        index = markerStart
        break
      }
      depth += 1
      index += 1
      if index < nsLine.length, nsLine.character(at: index) == 32 {
        index += 1
      }
    }
    return MarkdownLineContext(
      quoteDepth: depth,
      quotePrefixLength: index,
      body: nsLine.substring(from: index))
  }

  private static func markdownLeadingSpaceLength(in line: NSString) -> Int {
    var index = 0
    while index < line.length, line.character(at: index) == 32 {
      index += 1
    }
    return index
  }

  private static func markdownReferenceDefinition(in line: String) -> Bool {
    referenceDefinitionExpression.firstMatch(
      in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
  }

  private static func markdownTableCells(in line: String) -> [NSRange]? {
    let nsLine = line as NSString
    var start = 0
    var end = nsLine.length
    while start < end, nsLine.character(at: start) == 32 || nsLine.character(at: start) == 9 {
      start += 1
    }
    while end > start {
      let character = nsLine.character(at: end - 1)
      guard character == 32 || character == 9 else { break }
      end -= 1
    }
    guard start < end else { return nil }
    if nsLine.character(at: start) == 124 { start += 1 }  // "|"
    if end > start, nsLine.character(at: end - 1) == 124 { end -= 1 }
    guard start < end else { return nil }

    var cells: [NSRange] = []
    var cellStart = start
    var cursor = start
    while cursor <= end {
      if cursor == end || nsLine.character(at: cursor) == 124 {
        var trimmedStart = cellStart
        var trimmedEnd = cursor
        while trimmedStart < trimmedEnd {
          let character = nsLine.character(at: trimmedStart)
          guard character == 32 || character == 9 else { break }
          trimmedStart += 1
        }
        while trimmedEnd > trimmedStart {
          let character = nsLine.character(at: trimmedEnd - 1)
          guard character == 32 || character == 9 else { break }
          trimmedEnd -= 1
        }
        cells.append(NSRange(location: trimmedStart, length: max(0, trimmedEnd - trimmedStart)))
        cellStart = cursor + 1
      }
      cursor += 1
    }
    return cells.count >= 2 ? cells : nil
  }

  private static func markdownTableSeparatorAlignments(in line: String)
    -> [MarkdownTableColumnAlignment]?
  {
    guard let cells = markdownTableCells(in: line) else { return nil }
    let nsLine = line as NSString
    var alignments: [MarkdownTableColumnAlignment] = []
    for cell in cells {
      let text = nsLine.substring(with: cell)
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      guard trimmed.count >= 3 else { return nil }
      let body = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
      guard body.count >= 3, body.allSatisfy({ $0 == "-" }) else { return nil }
      if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
        alignments.append(.center)
      } else if trimmed.hasSuffix(":") {
        alignments.append(.right)
      } else {
        alignments.append(.left)
      }
    }
    return alignments
  }

  private static func markdownTableDisplayMap(for line: String) -> MarkdownDisplayMap? {
    guard let cells = markdownTableCells(in: line) else { return nil }
    let nsLine = line as NSString
    let sourceLength = nsLine.length
    var display = ""
    var boundaries: [Int] = [cells.first?.location ?? 0]
    var characterRanges: [NSRange] = []

    func appendText(_ text: String, sourceRange: NSRange) {
      let nsText = text as NSString
      for offset in 0..<nsText.length {
        characterRanges.append(NSRange(location: sourceRange.location + offset, length: 1))
        boundaries.append(min(sourceLength, sourceRange.location + offset + 1))
      }
      display += text
    }

    func appendTab(after sourceColumn: Int) {
      display += "\t"
      characterRanges.append(NSRange(location: min(sourceColumn, sourceLength), length: 0))
      boundaries.append(min(sourceColumn, sourceLength))
    }

    for (index, cell) in cells.enumerated() {
      if index > 0 {
        appendTab(after: cell.location)
      }
      appendText(nsLine.substring(with: cell), sourceRange: cell)
    }

    return MarkdownDisplayMap(
      sourceText: line,
      displayText: display,
      boundaryColumns: boundaries,
      characterRanges: characterRanges)
  }

  private static func markdownTableColumns(
    rowBodies: [String],
    alignments: [MarkdownTableColumnAlignment]
  ) -> [MarkdownTableColumn] {
    guard !alignments.isEmpty else { return [] }
    let font = TextDocumentSyntax.markdown.font
    let typography = MarkdownTypography.measurement(baseFont: font)
    var widths = Array(
      repeating: MarkdownDocumentMetrics.tableColumnMinimumWidth,
      count: alignments.count)

    for (rowIndex, rowBody) in rowBodies.enumerated() {
      var state = MarkdownLineStyleState()
      state.isTableRow = true
      state.isTableHeader = rowIndex == 0
      let rendered = markdownMeasurementLine(
        rowBody, font: font, state: state, typography: typography)
      var location = 0
      for (column, cell) in rendered.string.components(separatedBy: "\t").enumerated() {
        let length = (cell as NSString).length
        defer { location += length + 1 }
        guard column < widths.count else { break }
        let measured = ceil(
          rendered.attributedSubstring(from: NSRange(location: location, length: length))
            .size().width)
        widths[column] = min(
          MarkdownDocumentMetrics.tableColumnMaximumWidth,
          max(widths[column], measured))
      }
    }

    let gutters =
      MarkdownDocumentMetrics.tableColumnGutter * CGFloat(max(0, alignments.count - 1))
    let maxTotal =
      MarkdownDocumentMetrics.maxMeasureWidth - gutters
      - MarkdownDocumentMetrics.tableEdgeInset * 2
    let total = widths.reduce(0, +)
    if total > maxTotal, total > 0 {
      let scale = maxTotal / total
      widths = widths.map {
        max(MarkdownDocumentMetrics.tableColumnMinimumWidth, floor($0 * scale))
      }
    }

    return zip(widths, alignments).map { width, alignment in
      MarkdownTableColumn(width: width, alignment: alignment)
    }
  }

  private static func markdownListMarkerPrefixLength(
    in line: String,
    allowIndentedList: Bool
  ) -> Int? {
    let nsLine = line as NSString
    let length = nsLine.length
    let index = markdownLeadingSpaceLength(in: nsLine)
    guard index < length else { return nil }
    guard allowIndentedList || index < 4 else { return nil }
    if index + 1 < length, isBulletMarker(nsLine.character(at: index)),
      nsLine.character(at: index + 1) == 32
    {
      var prefixEnd = index + 2
      if prefixEnd + 3 <= length,
        nsLine.character(at: prefixEnd) == 91,  // "["
        nsLine.character(at: prefixEnd + 1) == 32
          || nsLine.character(at: prefixEnd + 1) == 120
          || nsLine.character(at: prefixEnd + 1) == 88,
        nsLine.character(at: prefixEnd + 2) == 93  // "]"
      {
        prefixEnd += 3
        if prefixEnd < length, nsLine.character(at: prefixEnd) == 32 {
          prefixEnd += 1
        }
      }
      return prefixEnd
    }

    var digitEnd = index
    while digitEnd < length {
      let value = nsLine.character(at: digitEnd)
      guard value >= 48, value <= 57 else { break }
      digitEnd += 1
    }
    if digitEnd > index, digitEnd + 1 < length,
      nsLine.character(at: digitEnd) == 46 || nsLine.character(at: digitEnd) == 41,
      nsLine.character(at: digitEnd + 1) == 32
    {
      return digitEnd + 2
    }
    return nil
  }

  static func markdownLineStates(for lines: [String]) -> [MarkdownLineStyleState] {
    var states = Array(repeating: MarkdownLineStyleState.plain, count: lines.count)
    guard !lines.isEmpty else { return states }

    for index in lines.indices {
      let context = markdownLineContext(in: lines[index])
      states[index].quoteDepth = context.quoteDepth
      if markdownReferenceDefinition(in: context.body) {
        states[index].isReferenceDefinition = true
      }
    }

    if markdownFrontMatterDelimiter(in: lines[0]) {
      var closingIndex: Int?
      for index in lines.indices.dropFirst() {
        if markdownFrontMatterDelimiter(in: lines[index]) {
          closingIndex = index
          break
        }
      }
      if let closingIndex {
        for index in 0...closingIndex {
          states[index].insideFrontMatter = true
        }
      }
    }

    var fenceOpeningIndex: Int?
    for index in lines.indices {
      guard !states[index].insideFrontMatter, isMarkdownFenceLine(lines[index]) else {
        continue
      }
      if let openingIndex = fenceOpeningIndex {
        states[openingIndex].isFenceDelimiter = true
        states[index].isFenceDelimiter = true
        if openingIndex + 1 < index {
          for fencedIndex in (openingIndex + 1)..<index {
            guard !states[fencedIndex].insideFrontMatter else { continue }
            states[fencedIndex].insideFence = true
          }
        }
        fenceOpeningIndex = nil
      } else {
        fenceOpeningIndex = index
      }
    }

    var listIndentStack: [Int] = []
    for index in lines.indices {
      guard !states[index].insideFrontMatter, !states[index].insideFence,
        !states[index].isFenceDelimiter
      else {
        listIndentStack.removeAll()
        continue
      }
      let body = markdownLineContext(in: lines[index]).body
      let nsBody = body as NSString
      let trimmed = body.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else {
        states[index].listDepth = listIndentStack.count
        continue
      }
      let leadingSpaces = markdownLeadingSpaceLength(in: nsBody)
      let markerPrefix = markdownListMarkerPrefixLength(
        in: body, allowIndentedList: !listIndentStack.isEmpty)
      if leadingSpaces >= 4, listIndentStack.isEmpty {
        states[index].isIndentedCodeBlock = true
        listIndentStack.removeAll()
        continue
      }
      if markerPrefix != nil {
        if listIndentStack.isEmpty {
          listIndentStack = [leadingSpaces]
        } else {
          while let last = listIndentStack.last, leadingSpaces < last {
            listIndentStack.removeLast()
          }
          if let last = listIndentStack.last, leadingSpaces > last {
            listIndentStack.append(leadingSpaces)
          } else if listIndentStack.isEmpty {
            listIndentStack = [leadingSpaces]
          }
        }
        states[index].listDepth = max(1, listIndentStack.count)
      } else if !listIndentStack.isEmpty, leadingSpaces > 0 {
        states[index].listDepth = listIndentStack.count
      } else {
        listIndentStack.removeAll()
      }
    }

    for index in lines.indices.dropFirst() {
      guard !states[index].insideFence, !states[index].insideFrontMatter,
        !states[index].isIndentedCodeBlock,
        let alignments = markdownTableSeparatorAlignments(
          in: markdownLineContext(in: lines[index]).body),
        let previousCells = markdownTableCells(in: markdownLineContext(in: lines[index - 1]).body),
        previousCells.count == alignments.count
      else {
        continue
      }
      var tableRowIndices = [index - 1]
      states[index].isTableSeparator = true
      states[index - 1].isTableRow = true
      states[index - 1].isTableHeader = true
      var rowIndex = index + 1
      while rowIndex < lines.count,
        !states[rowIndex].insideFence,
        !states[rowIndex].insideFrontMatter,
        let cells = markdownTableCells(in: markdownLineContext(in: lines[rowIndex]).body),
        cells.count == alignments.count
      {
        states[rowIndex].isTableRow = true
        tableRowIndices.append(rowIndex)
        rowIndex += 1
      }
      let columns = markdownTableColumns(
        rowBodies: tableRowIndices.map { markdownLineContext(in: lines[$0]).body },
        alignments: alignments)
      states[index].tableColumns = columns
      for tableRow in tableRowIndices {
        states[tableRow].tableColumns = columns
      }
    }

    for index in lines.indices.dropFirst() {
      guard !states[index].insideFence, !states[index].insideFrontMatter,
        !states[index - 1].insideFence, !states[index - 1].insideFrontMatter,
        !states[index].isTableSeparator, !states[index - 1].isTableRow,
        let level = markdownSetextHeadingLevel(in: lines[index]),
        markdownCanBecomeSetextHeading(lines[index - 1], state: states[index - 1])
      else {
        continue
      }
      states[index - 1].setextHeadingLevel = level
      states[index].isSetextUnderline = true
    }

    for index in lines.indices {
      let state = states[index]
      if let setext = state.setextHeadingLevel {
        states[index].headingLevel = setext
        continue
      }
      guard !state.insideFence, !state.insideFrontMatter, !state.isFenceDelimiter,
        !state.isIndentedCodeBlock, !state.isTableRow, !state.isTableSeparator,
        !state.isReferenceDefinition, !state.isSetextUnderline,
        let heading = markdownHeadingInfo(in: markdownLineContext(in: lines[index]).body)
      else {
        continue
      }
      states[index].headingLevel = heading.level
    }

    return states
  }

  static func highlightedParagraphRange(for editedRange: NSRange, in text: String) -> NSRange {
    let nsText = text as NSString
    let textLength = nsText.length
    let clampedRange = editedRange.clamped(toTextLength: textLength)
    return nsText.paragraphRange(for: clampedRange)
  }

  private static func baseAttributes(font: NSFont) -> [NSAttributedString.Key: Any] {
    [
      .font: font,
      .foregroundColor: NSColor.labelColor,
    ]
  }

  private static func highlightMarkdownDocument(
    _ text: String,
    in textStorage: NSMutableAttributedString,
    range: NSRange,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool
  ) {
    let nsText = text as NSString
    let fullLength = nsText.length
    let lineStates = markdownLineStates(for: text.components(separatedBy: "\n"))
    var lineIndex = 0
    var location = 0
    while location < fullLength {
      let lineRange = nsText.lineRange(for: NSRange(location: location, length: 0))
      var start = 0
      var end = 0
      var contentsEnd = 0
      nsText.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: lineRange)
      let contentRange = NSRange(location: start, length: max(0, contentsEnd - start))
      let line = nsText.substring(with: contentRange)
      let intersects = NSIntersectionRange(contentRange, range)
      if intersects.length > 0 {
        styleMarkdownLine(
          line,
          lineRange: contentRange,
          in: textStorage,
          state: lineIndex < lineStates.count ? lineStates[lineIndex] : .plain,
          typography: typography,
          includeVisualAttributes: includeVisualAttributes
        )
      }
      let next = NSMaxRange(lineRange)
      guard next > location else { break }
      location = next
      lineIndex += 1
    }
  }

  private static func styleMarkdownLine(
    _ line: String,
    lineRange: NSRange,
    in textStorage: NSMutableAttributedString,
    state: MarkdownLineStyleState,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool
  ) {
    let length = (line as NSString).length
    guard length > 0 else { return }

    if state.insideFrontMatter {
      textStorage.addAttributes(
        markdownAttributes(
          font: typography.codeBlock,
          foregroundColor: .secondaryLabelColor,
          includeVisualAttributes: includeVisualAttributes),
        range: lineRange)
      return
    }

    if state.isFenceDelimiter, let fence = markdownFenceInfo(in: line) {
      textStorage.addAttributes(
        markdownAttributes(
          font: typography.codeFence,
          foregroundColor: .secondaryLabelColor,
          includeVisualAttributes: includeVisualAttributes),
        range: lineRange)
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location, length: fence.markerLength),
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes)
      return
    }

    if state.insideFence {
      textStorage.addAttributes(
        markdownAttributes(
          font: typography.codeBlock,
          foregroundColor: .labelColor,
          includeVisualAttributes: includeVisualAttributes),
        range: lineRange)
      return
    }

    let lineFonts: MarkdownFontSet
    if let level = state.setextHeadingLevel {
      lineFonts = typography.heading(level: level)
      textStorage.addAttributes(
        markdownAttributes(
          font: lineFonts.regular,
          foregroundColor: level == 6 ? .secondaryLabelColor : .labelColor,
          includeVisualAttributes: includeVisualAttributes),
        range: lineRange)
    } else if state.isSetextUnderline {
      muteMarkdownSyntax(
        range: lineRange,
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes)
      return
    } else if let heading = markdownHeadingInfo(in: line) {
      lineFonts = typography.heading(level: heading.level)
      textStorage.addAttributes(
        markdownAttributes(
          font: lineFonts.regular,
          foregroundColor: heading.level == 6 ? .secondaryLabelColor : .labelColor,
          includeVisualAttributes: includeVisualAttributes),
        range: lineRange)
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location, length: heading.prefixLength),
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes)
    } else if let prefixLength = markdownBlockPrefixLength(in: line) {
      lineFonts = typography.body
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location, length: prefixLength),
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes)
    } else if markdownThematicBreak(in: line) {
      lineFonts = typography.body
      muteMarkdownSyntax(
        range: lineRange,
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes)
    } else {
      lineFonts = typography.body
    }

    highlightMarkdownInline(
      in: line,
      lineRange: lineRange,
      textStorage: textStorage,
      lineFonts: lineFonts,
      typography: typography,
      includeVisualAttributes: includeVisualAttributes)
  }

  private enum MarkdownDelimitedStyle {
    case boldItalic
    case bold
    case italic
    case strike
  }

  private static func highlightMarkdownInline(
    in line: String,
    lineRange: NSRange,
    textStorage: NSMutableAttributedString,
    lineFonts: MarkdownFontSet,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool
  ) {
    var protectedRanges = applyInlineCode(
      in: line,
      lineRange: lineRange,
      textStorage: textStorage,
      typography: typography,
      includeVisualAttributes: includeVisualAttributes)
    protectedRanges += applyLinks(
      in: line,
      lineRange: lineRange,
      textStorage: textStorage,
      lineFonts: lineFonts,
      includeVisualAttributes: includeVisualAttributes)
    applyDelimitedSpan(
      expression: boldItalicExpression,
      markerLength: 3,
      style: .boldItalic,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes)
    applyDelimitedSpan(
      expression: boldExpression,
      markerLength: 2,
      style: .bold,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes)
    applyDelimitedSpan(
      expression: italicExpression,
      markerLength: 1,
      style: .italic,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes)
    applyDelimitedSpan(
      expression: strikeExpression,
      markerLength: 2,
      style: .strike,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes)
  }

  private static func applyInlineCode(
    in line: String,
    lineRange: NSRange,
    textStorage: NSMutableAttributedString,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool
  ) -> [NSRange] {
    let expression = inlineCodeExpression
    let nsLine = line as NSString
    let full = NSRange(location: 0, length: nsLine.length)
    var protectedRanges: [NSRange] = []
    for match in expression.matches(in: line, range: full) {
      protectedRanges.append(match.range)
      let content = match.range(at: 1).offset(by: lineRange.location)
      textStorage.addAttributes(
        markdownInlineCodeAttributes(
          font: typography.inlineCode, includeVisualAttributes: includeVisualAttributes),
        range: content)
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location + match.range.location, length: 1),
        in: textStorage,
        font: typography.inlineCode,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1, length: 1),
        in: textStorage,
        font: typography.inlineCode,
        includeVisualAttributes: includeVisualAttributes)
    }
    return protectedRanges
  }

  private static func applyLinks(
    in line: String,
    lineRange: NSRange,
    textStorage: NSMutableAttributedString,
    lineFonts: MarkdownFontSet,
    includeVisualAttributes: Bool
  ) -> [NSRange] {
    let expression = linkExpression
    let nsLine = line as NSString
    let full = NSRange(location: 0, length: nsLine.length)
    var protectedRanges: [NSRange] = []
    for match in expression.matches(in: line, range: full) {
      protectedRanges.append(match.range)
      let label = match.range(at: 1).offset(by: lineRange.location)
      let url = match.range(at: 2).offset(by: lineRange.location)
      if includeVisualAttributes {
        textStorage.addAttributes([.foregroundColor: NSColor.linkColor], range: label)
      }
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location + match.range.location, length: 1),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSyntax(
        range: NSRange(location: NSMaxRange(label), length: 2),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSyntax(
        range: url,
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1, length: 1),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
    }
    return protectedRanges
  }

  private static func applyDelimitedSpan(
    expression: NSRegularExpression,
    markerLength: Int,
    style: MarkdownDelimitedStyle,
    protectedRanges: [NSRange],
    in line: String,
    lineRange: NSRange,
    lineFonts: MarkdownFontSet,
    textStorage: NSMutableAttributedString,
    includeVisualAttributes: Bool
  ) {
    let nsLine = line as NSString
    let full = NSRange(location: 0, length: nsLine.length)
    for match in expression.matches(in: line, range: full) {
      guard !protectedRanges.contains(where: { rangesIntersect($0, match.range) }) else {
        continue
      }
      let content = match.range(at: 1).offset(by: lineRange.location)
      var attributes: [NSAttributedString.Key: Any]
      switch style {
      case .boldItalic:
        attributes = [.font: lineFonts.boldItalic]
      case .bold:
        attributes = [.font: lineFonts.bold]
      case .italic:
        attributes = [.font: lineFonts.italic]
      case .strike:
        attributes = [.font: lineFonts.regular]
        if includeVisualAttributes {
          attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
      }
      textStorage.addAttributes(attributes, range: content)
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location + match.range.location, length: markerLength),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSyntax(
        range: NSRange(
          location: lineRange.location + NSMaxRange(match.range) - markerLength,
          length: markerLength),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
    }
  }

  private static func muteMarkdownSyntax(
    range: NSRange,
    in textStorage: NSMutableAttributedString,
    font: NSFont,
    includeVisualAttributes: Bool
  ) {
    guard range.length > 0 else { return }
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if includeVisualAttributes {
      attributes[.foregroundColor] = NSColor.clear
    }
    textStorage.addAttributes(attributes, range: range)
  }

  private static func markdownAttributes(
    font: NSFont,
    foregroundColor: NSColor,
    includeVisualAttributes: Bool
  ) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if includeVisualAttributes {
      attributes[.foregroundColor] = foregroundColor
    }
    return attributes
  }

  private static func markdownTableParagraphStyle(columns: [MarkdownTableColumn])
    -> NSParagraphStyle
  {
    let style = NSMutableParagraphStyle()
    style.defaultTabInterval = 0
    let columns =
      columns.isEmpty
      ? [
        MarkdownTableColumn(
          width: MarkdownDocumentMetrics.tableFallbackColumnWidth,
          alignment: .left)
      ]
      : columns
    let gutter = MarkdownDocumentMetrics.tableColumnGutter
    var origin: CGFloat = 0
    var tabStops: [NSTextTab] = []
    for index in 1..<columns.count {
      origin += columns[index - 1].width + gutter
      let column = columns[index]
      let location: CGFloat
      let alignment: NSTextAlignment
      switch column.alignment {
      case .left:
        location = origin
        alignment = .left
      case .center:
        location = origin + column.width / 2
        alignment = .center
      case .right:
        location = origin + column.width
        alignment = .right
      }
      tabStops.append(NSTextTab(textAlignment: alignment, location: location, options: [:]))
    }
    style.tabStops = tabStops
    return style
  }

  private static func renderedLinkAttributes(
    font: NSFont,
    includeVisualAttributes: Bool
  ) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if includeVisualAttributes {
      attributes[.foregroundColor] = NSColor.linkColor
    }
    return attributes
  }

  private static func markdownInlineCodeAttributes(
    font: NSFont,
    includeVisualAttributes: Bool
  ) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if includeVisualAttributes {
      attributes[.foregroundColor] = NSColor.labelColor
      attributes[.backgroundColor] = MarkdownDocumentMetrics.inlineCodeBackground
    }
    return attributes
  }

  private static func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    NSIntersectionRange(lhs, rhs).length > 0
  }

  private static func markdownHeadingInfo(in line: String) -> (level: Int, prefixLength: Int)? {
    let nsLine = line as NSString
    var index = 0
    while index < min(3, nsLine.length), nsLine.character(at: index) == 32 {
      index += 1
    }
    var level = 0
    while index + level < nsLine.length, level < 6,
      nsLine.character(at: index + level) == 35
    {  // "#"
      level += 1
    }
    guard level > 0, nsLine.length > index + level,
      nsLine.character(at: index + level) == 32
    else {
      return nil
    }
    return (level, index + level + 1)
  }

  private static func markdownBlockPrefixLength(
    in line: String,
    allowIndentedList: Bool = false
  ) -> Int? {
    let nsLine = line as NSString
    let length = nsLine.length
    var index = markdownLeadingSpaceLength(in: nsLine)
    if index < length, nsLine.character(at: index) == 62 {  // ">"
      while index < length, nsLine.character(at: index) == 62 || nsLine.character(at: index) == 32 {
        index += 1
      }
      return index
    }
    return markdownListMarkerPrefixLength(in: line, allowIndentedList: allowIndentedList)
  }

  private static func markdownFenceInfo(in line: String) -> (markerLength: Int, marker: Character)?
  {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
    let marker = trimmed.first ?? "`"
    let count = trimmed.prefix { $0 == marker }.count
    return count >= 3 ? (count, marker) : nil
  }

  private static func markdownFrontMatterDelimiter(in line: String) -> Bool {
    line.trimmingCharacters(in: .whitespaces) == "---"
  }

  private static func markdownSetextHeadingLevel(in line: String) -> Int? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2 else { return nil }
    let characters = Set(trimmed)
    guard characters.count == 1 else { return nil }
    if characters.first == "=" { return 1 }
    if characters.first == "-" { return 2 }
    return nil
  }

  private static func markdownCanBecomeSetextHeading(
    _ line: String, state: MarkdownLineStyleState
  ) -> Bool {
    guard !state.insideFence, !state.insideFrontMatter else { return false }
    let body = markdownLineContext(in: line).body
    let trimmed = body.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    if markdownHeadingInfo(in: body) != nil { return false }
    if markdownBlockPrefixLength(in: body, allowIndentedList: state.listDepth > 0) != nil {
      return false
    }
    if markdownFenceInfo(in: body) != nil { return false }
    if markdownThematicBreak(in: body) { return false }
    return true
  }

  private static func markdownThematicBreak(in line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else { return false }
    let scalars = Set(trimmed)
    return scalars.count == 1 && ["-", "*", "_"].contains(scalars.first ?? " ")
  }

  private static func isBulletMarker(_ value: unichar) -> Bool {
    value == 45 || value == 42 || value == 43  // "-", "*", "+"
  }

  private static let inlineCodeExpression = markdownRegex(#"`([^`\n]+)`"#)
  private static let linkExpression = markdownRegex(#"(?<!!)\[([^\]\n]+)\]\((https?://[^\)\n]+)\)"#)
  private static let renderedLinkExpression = markdownRegex(#"(?<!!)\[([^\]\n]+)\]\(([^\)\n]+)\)"#)
  private static let referenceLinkExpression = markdownRegex(#"(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]"#)
  private static let referenceDefinitionExpression = markdownRegex(#"^\s{0,3}\[[^\]\n]+\]:\s+\S+"#)
  private static let autolinkExpression = markdownRegex(#"<(https?://[^>\s]+)>"#)
  private static let escapeExpression = markdownRegex(#"\\([\\`*_{}\[\]()#+\-.!>~|])"#)
  private static let imageExpression = markdownRegex(#"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
  private static let boldItalicExpression = markdownRegex(
    #"(?<![\\*])\*\*\*([^\*\n]+)(?<!\\)\*\*\*(?!\*)"#)
  private static let boldExpression = markdownRegex(#"(?<![\\*])\*\*([^\*\n]+)(?<!\\)\*\*(?!\*)"#)
  private static let italicExpression = markdownRegex(#"(?<![\\*])\*([^\*\n]+)(?<!\\)\*(?!\*)"#)
  private static let strikeExpression = markdownRegex(#"(?<![\\~])~~([^~\n]+)(?<!\\)~~(?!~)"#)

  private static func markdownRegex(_ pattern: String) -> NSRegularExpression {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      preconditionFailure("Invalid markdown styling pattern: \(pattern)")
    }
    return expression
  }

  private static func highlightStructuredText(
    _ text: String, in textStorage: NSMutableAttributedString, range: NSRange
  ) {
    apply(rule: .structuredKey, text: text, textStorage: textStorage, range: range)
    apply(rule: .structuredString, text: text, textStorage: textStorage, range: range)
    apply(rule: .structuredNumber, text: text, textStorage: textStorage, range: range)
    apply(rule: .structuredBoolean, text: text, textStorage: textStorage, range: range)
  }

  private static func highlightCode(
    _ text: String, in textStorage: NSMutableAttributedString, range: NSRange
  ) {
    apply(rule: .codeComment, text: text, textStorage: textStorage, range: range)
    apply(rule: .codeString, text: text, textStorage: textStorage, range: range)
    apply(rule: .codeKeyword, text: text, textStorage: textStorage, range: range)
  }

  private static func apply(
    rule: TextHighlightRule,
    text: String,
    textStorage: NSMutableAttributedString,
    range: NSRange
  ) {
    for match in rule.expression.matches(in: text, range: range) {
      textStorage.addAttributes(rule.attributes, range: match.range)
    }
  }
}

extension NSRange {
  fileprivate func offset(by delta: Int) -> NSRange {
    NSRange(location: location + delta, length: length)
  }
}

private enum TextHighlightRule {
  case markdownHeading
  case markdownInlineCode
  case markdownLink
  case markdownListMarker
  case structuredKey
  case structuredString
  case structuredNumber
  case structuredBoolean
  case codeComment
  case codeString
  case codeKeyword

  var expression: NSRegularExpression {
    switch self {
    case .markdownHeading:
      return Self.markdownHeadingExpression
    case .markdownInlineCode:
      return Self.markdownInlineCodeExpression
    case .markdownLink:
      return Self.markdownLinkExpression
    case .markdownListMarker:
      return Self.markdownListMarkerExpression
    case .structuredKey:
      return Self.structuredKeyExpression
    case .structuredString:
      return Self.structuredStringExpression
    case .structuredNumber:
      return Self.structuredNumberExpression
    case .structuredBoolean:
      return Self.structuredBooleanExpression
    case .codeComment:
      return Self.codeCommentExpression
    case .codeString:
      return Self.codeStringExpression
    case .codeKeyword:
      return Self.codeKeywordExpression
    }
  }

  var attributes: [NSAttributedString.Key: Any] {
    switch self {
    case .markdownHeading:
      return [
        .foregroundColor: NSColor.controlAccentColor,
        .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
      ]
    case .markdownInlineCode:
      return [
        .foregroundColor: NSColor.systemPurple,
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
      ]
    case .markdownLink:
      return [.foregroundColor: NSColor.linkColor]
    case .markdownListMarker, .codeComment:
      return [.foregroundColor: NSColor.secondaryLabelColor]
    case .structuredKey, .codeKeyword:
      return [
        .foregroundColor: NSColor.controlAccentColor,
        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
      ]
    case .structuredString, .codeString:
      return [.foregroundColor: NSColor.systemGreen]
    case .structuredNumber:
      return [.foregroundColor: NSColor.systemPurple]
    case .structuredBoolean:
      return [.foregroundColor: NSColor.systemOrange]
    }
  }

  private static let markdownHeadingExpression = regex(#"(?m)^#{1,6}\s.+$"#)
  private static let markdownInlineCodeExpression = regex(#"`[^`\n]+`"#)
  private static let markdownLinkExpression = regex(#"\[[^\]\n]+\]\([^\)\n]+\)"#)
  private static let markdownListMarkerExpression = regex(#"(?m)^\s*[-*+]\s+"#)
  private static let structuredKeyExpression = regex(#"(?m)^\s*["A-Za-z0-9_.-]+(?=\s*[:=])"#)
  private static let structuredStringExpression = regex(#""(?:\\.|[^"\\])*""#)
  private static let structuredNumberExpression = regex(#"(?<![\w.-])-?\b\d+(?:\.\d+)?\b"#)
  private static let structuredBooleanExpression = regex(#"\b(true|false|null)\b"#)
  private static let codeCommentExpression = regex(#"(?m)(?<![\w:])//.*$|#.*$"#)
  private static let codeStringExpression = regex(#""(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'"#)
  private static let codeKeywordExpression = regex(
    #"\b(func|let|var|if|else|for|while|return|struct|class|enum|import|case|switch|public|private|async|await|throws)\b"#
  )

  private static func regex(_ pattern: String) -> NSRegularExpression {
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      preconditionFailure("Invalid syntax highlight pattern: \(pattern)")
    }

    return expression
  }
}

extension NSRange {
  fileprivate func clamped(toTextLength textLength: Int) -> NSRange {
    guard location <= textLength else {
      return NSRange(location: textLength, length: 0)
    }

    let maximumLength = Swift.max(0, textLength - location)
    return NSRange(location: location, length: Swift.min(length, maximumLength))
  }
}
