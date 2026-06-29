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
  /// Inset from the code card's edges to the code glyphs on both sides.
  static let codeCardInset: CGFloat = 12
  static let codeBlockCornerRadius: CGFloat = 8
  static let inlineCodeCornerRadius: CGFloat = 4
  /// Breathing room above and below a code card, detaching it from prose the
  /// way image blocks and headings breathe (matches `imageBlockAir`).
  static let codeBlockAir: CGFloat = 10
  /// Tracking on the language label so a short word reads as a quiet caption
  /// rather than body text.
  static let codeCaptionTracking: CGFloat = 0.4
  /// The persistent copy control in a fenced block's top-right corner.
  static let codeCopyButtonWidth: CGFloat = 26
  static let codeCopyButtonHeight: CGFloat = 20
  /// Inset from the card's right edge to the control.
  static let codeCopyButtonInset: CGFloat = 8
  /// Inset from the card's top edge to the control — a small drop so the icon
  /// sits just below the top rather than flush against it.
  static let codeCopyButtonTopInset: CGFloat = 5
  static let codeCopyButtonCornerRadius: CGFloat = 5
  static let codeCopyIconPointSize: CGFloat = 12
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
  /// Breathing room above an image block and below its caption row.
  static let imageBlockAir: CGFloat = 10
  /// Gap between an image and its caption (the alt text) below it.
  static let imageCaptionGap: CGFloat = 6
  /// Block height while the image's natural size is still being probed.
  static let imagePlaceholderHeight: CGFloat = 120
  /// Height of the quiet card shown when an image cannot be loaded.
  static let imageFailureHeight: CGFloat = 48
  /// Tall images scale down to this height so one screenshot never fills
  /// several screens; width shrinks proportionally.
  static let imageMaximumBlockHeight: CGFloat = 560
  /// Slight rounding keeps image blocks calm against the page background.
  static let imageCornerRadius: CGFloat = 4
  /// The alt text renders as a small muted caption below the image.
  static let imageCaptionFontSize: CGFloat = 12
  static let frontMatterHorizontalInset: CGFloat = 34
  static let frontMatterKeyColumnWidth: CGFloat = 150
  static let frontMatterVerticalPadding: CGFloat = 18
  static let frontMatterRowHeight: CGFloat = 34
  static let frontMatterCornerRadius: CGFloat = 10
  static let frontMatterChipHorizontalPadding: CGFloat = 10
  static let frontMatterChipHeight: CGFloat = 24
  static let frontMatterChipCornerRadius: CGFloat = 7
  static let frontMatterChipDisplaySeparator = "        "

  static func headingFont(level: Int) -> NSFont {
    switch level {
    case 1:
      return .systemFont(ofSize: 30, weight: .bold)
    case 2:
      return .systemFont(ofSize: 24, weight: .bold)
    case 3:
      return .systemFont(ofSize: 21, weight: .semibold)
    case 4:
      return .systemFont(ofSize: 18, weight: .semibold)
    case 5:
      return .systemFont(ofSize: 16, weight: .semibold)
    default:
      return .systemFont(ofSize: 15, weight: .semibold)
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

  static var frontMatterBackground: NSColor {
    let card = LocusChromeColors.documentCard.usingColorSpace(.sRGB) ?? .textBackgroundColor
    let appearance = NSAppearance.currentDrawing()
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    if dark {
      return card.blended(withFraction: 0.12, of: .white) ?? NSColor.controlBackgroundColor
    }
    return card.blended(withFraction: 0.025, of: .black) ?? NSColor.controlBackgroundColor
  }

  static var frontMatterChipBackground: NSColor {
    let base = frontMatterBackground.usingColorSpace(.sRGB) ?? frontMatterBackground
    let appearance = NSAppearance.currentDrawing()
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    if dark {
      return base.blended(withFraction: 0.10, of: .white) ?? base
    }
    return base.blended(withFraction: 0.04, of: .black) ?? base
  }

  static var ruleColor: NSColor { .separatorColor }
  static var accentColor: NSColor { .controlAccentColor }
  static var markerColor: NSColor { .tertiaryLabelColor }
  static var brokenLinkColor: NSColor {
    NSColor.systemRed.blended(withFraction: 0.30, of: .secondaryLabelColor) ?? .systemRed
  }
  static var tableRuleColor: NSColor { .separatorColor }
  static var codeCopyIconColor: NSColor { .secondaryLabelColor }
  static var codeCopyConfirmColor: NSColor { .controlAccentColor }
  /// Comments recede to marker grey; strings are calm theme-coherent ink. Both
  /// are language-agnostic (comment + quoted-string surface), never keywords.
  static var codeCommentColor: NSColor { .tertiaryLabelColor }
  static var codeStringColor: NSColor {
    NSColor.controlAccentColor.blended(withFraction: 0.55, of: .labelColor)
      ?? NSColor.controlAccentColor
  }

  static var tableHeaderFont: NSFont {
    .systemFont(ofSize: tableHeaderFontSize, weight: .semibold)
  }

  static var imageCaptionFont: NSFont {
    .systemFont(ofSize: imageCaptionFontSize)
  }

  static var frontMatterKeyFont: NSFont {
    .systemFont(ofSize: bodyFontSize, weight: .medium)
  }

  static var frontMatterValueFont: NSFont {
    .systemFont(ofSize: bodyFontSize, weight: .regular)
  }

  static var frontMatterEmphasizedValueFont: NSFont {
    .systemFont(ofSize: bodyFontSize, weight: .semibold)
  }

  static var frontMatterChipFont: NSFont {
    .systemFont(ofSize: 13, weight: .medium)
  }

  /// The language label above a code slab: a small muted system caption in the
  /// same register as table headers and image captions (not the mono body).
  static var codeLabelFont: NSFont {
    .systemFont(ofSize: codeFenceFontSize, weight: .medium)
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

/// The destination and alt text of a line whose only content is one image,
/// e.g. `![alt](images/chart.png)` — such lines render as image blocks.
struct MarkdownImageSource: Equatable, Hashable, Sendable {
  var source: String
  var altText: String
  var linkDestination: String?

  init(source: String, altText: String, linkDestination: String? = nil) {
    self.source = source
    self.altText = altText
    self.linkDestination = linkDestination
  }
}

struct MarkdownFrontMatterValue: Equatable, Sendable {
  var text: String
  var sourceRange: NSRange
}

struct MarkdownFrontMatterField: Equatable, Sendable {
  var key: String
  var keyRange: NSRange
  var values: [MarkdownFrontMatterValue]
  var rendersValuesAsChips: Bool

  var displayValueText: String {
    values.map(\.text).joined(
      separator: rendersValuesAsChips ? MarkdownDocumentMetrics.frontMatterChipDisplaySeparator : ""
    )
  }

  var displayText: String {
    key + "\t" + displayValueText
  }
}

struct MarkdownLineStyleState: Equatable, Sendable {
  var insideFence = false
  var setextHeadingLevel: Int?
  var isSetextUnderline = false
  /// 1–6 when the line renders as a heading (ATX or setext text line).
  var headingLevel: Int?
  var insideFrontMatter = false
  /// True for the opening and closing `---` lines of a frontmatter block, which
  /// render empty and so collapse to slim rows (like fence/table delimiters)
  /// rather than full empty rows inside the card.
  var isFrontMatterDelimiter = false
  /// Parsed metadata field for frontmatter rows that should be visible.
  var frontMatterField: MarkdownFrontMatterField?
  /// A YAML sequence item inside frontmatter. It renders aligned with the value
  /// column, but maps back to the real `- value` source range so it stays editable.
  var frontMatterSequenceValue: MarkdownFrontMatterValue?
  var isFenceDelimiter = false
  /// True for the opening fence delimiter of a block (vs the closer). The
  /// authoritative opener/closer distinction from the pairing pass, so callers
  /// never have to re-derive it from neighbouring lines (which fails for
  /// back-to-back blocks or a fence right after frontmatter).
  var isFenceOpen = false
  /// True for an opening fence delimiter carrying a non-empty info string —
  /// the only fence line that renders a language label (others render empty).
  var isFenceLabel = false
  var isIndentedCodeBlock = false
  var isReferenceDefinition = false
  var isTableRow = false
  var isTableHeader = false
  var isTableSeparator = false
  var tableColumns: [MarkdownTableColumn] = []
  var quoteDepth = 0
  var listDepth = 0
  var imageSource: MarkdownImageSource?

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

  func displayRange(forSourceRange sourceRange: NSRange) -> NSRange? {
    guard sourceRange.location != NSNotFound, sourceRange.length > 0 else { return nil }
    var lower: Int?
    var upper: Int?
    for (index, characterRange) in characterRanges.enumerated()
    where NSIntersectionRange(characterRange, sourceRange).length > 0 {
      lower = min(lower ?? index, index)
      upper = max(upper ?? index, index + 1)
    }
    guard let lower, let upper, upper > lower else { return nil }
    return NSRange(location: lower, length: upper - lower)
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

  /// Replaces `matchRange` with a `literal` string that is not a substring of
  /// the source (an HTML entity's character, or a `<br>`'s space). Every UTF-16
  /// unit of the literal collapses to the match's start source column and points
  /// at the whole match's source range, so the caret can only land before or
  /// after the literal — never inside it, and never between a surrogate pair.
  fileprivate func replacingWithLiteral(match matchRange: NSRange, literal: String)
    -> MarkdownDisplayMap
  {
    let nsDisplay = displayText as NSString
    let displayLength = nsDisplay.length
    guard matchRange.location >= 0, matchRange.length > 0,
      NSMaxRange(matchRange) <= displayLength
    else {
      return self
    }
    let literalLength = (literal as NSString).length
    let prefix = nsDisplay.substring(to: matchRange.location)
    let suffix = nsDisplay.substring(from: NSMaxRange(matchRange))
    let newText = prefix + literal + suffix

    let matchSourceRange = bufferRange(
      forDisplayStart: matchRange.location, end: NSMaxRange(matchRange),
      includeWholeLineMarkers: false)
    let startColumn = boundaryColumns[matchRange.location]
    let endColumn = boundaryColumns[NSMaxRange(matchRange)]

    var newBoundaries: [Int] = []
    if matchRange.location > 0 {
      newBoundaries.append(contentsOf: boundaryColumns[0..<matchRange.location])
    }
    newBoundaries.append(contentsOf: Array(repeating: startColumn, count: literalLength))
    newBoundaries.append(endColumn)
    if NSMaxRange(matchRange) < displayLength {
      newBoundaries.append(
        contentsOf: boundaryColumns[(NSMaxRange(matchRange) + 1)...displayLength])
    }

    var newCharacterRanges: [NSRange] = []
    if matchRange.location > 0 {
      newCharacterRanges.append(contentsOf: characterRanges[0..<matchRange.location])
    }
    newCharacterRanges.append(contentsOf: Array(repeating: matchSourceRange, count: literalLength))
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

struct MarkdownLinkTarget: Equatable, Sendable {
  let displayRange: NSRange
  let destination: String
}

typealias MarkdownLinkStatusProvider = (String) -> MarkdownLinkVisualState

private struct MarkdownPendingLinkTarget {
  let sourceRange: NSRange
  let destination: String
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
      // Source fallback only. The document-like Markdown editor renders through
      // `highlightedLine` / `markdownMeasurementLine`, where display text can be
      // shorter than source text. This in-place path keeps source length fixed
      // for read-only/plain fallback surfaces.
      styleMarkdownSourceDocument(
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
    markdownTypography: MarkdownTypography? = nil,
    markdownLinkStatus: MarkdownLinkStatusProvider? = nil
  ) -> NSAttributedString {
    let visible = line
    if syntax == .markdown {
      return renderedMarkdownLine(
        visible,
        font: font,
        state: markdownLineState,
        typography: markdownTypography ?? MarkdownTypography(baseFont: font),
        includeVisualAttributes: true,
        linkStatus: markdownLinkStatus)
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

  static func markdownLinkTargets(
    for line: String,
    state: MarkdownLineStyleState = .plain
  ) -> [MarkdownLinkTarget] {
    let baseMap = renderedMarkdownBlockDisplayMap(line, state: state)
    let context = markdownLineContext(in: line)
    guard !state.insideFence, !state.insideFrontMatter, !state.isSetextUnderline,
      !state.isIndentedCodeBlock, !state.isReferenceDefinition, !state.isTableSeparator,
      !markdownLineIsHorizontalRule(context.body)
    else {
      return []
    }

    var targets: [MarkdownLinkTarget] = []
    _ = renderedInlineDisplayMap(from: baseMap, collectingLinkTargets: &targets)
    return targets
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

  // MARK: - Markdown rendered document path

  private static func renderedMarkdownLine(
    _ line: String,
    font: NSFont,
    state: MarkdownLineStyleState,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool,
    linkStatus: MarkdownLinkStatusProvider? = nil
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
    if state.isFenceDelimiter {
      // Only a labeled opener reaches here (empty delimiters return above).
      // Tracking widens the caption; metrics-affecting, so apply unconditionally.
      attributed.addAttribute(
        .kern, value: MarkdownDocumentMetrics.codeCaptionTracking, range: fullRange)
    }
    if state.insideFrontMatter, state.frontMatterSequenceValue != nil {
      applyMarkdownFrontMatterSequenceAttributes(
        to: attributed,
        includeVisualAttributes: includeVisualAttributes)
    } else if state.insideFrontMatter,
      let field = state.frontMatterField ?? markdownFrontMatterField(in: line)
    {
      applyMarkdownFrontMatterAttributes(
        to: attributed,
        field: field,
        includeVisualAttributes: includeVisualAttributes)
    }
    if state.isTableRow {
      attributed.addAttribute(
        .paragraphStyle,
        value: markdownTableParagraphStyle(columns: state.tableColumns),
        range: fullRange)
    }
    if includeVisualAttributes, markdownLineCarriesCodeTint(state) {
      applyMarkdownCodeTint(to: attributed)
    }
    if block.stylesInline {
      applyRenderedMarkdownInline(
        to: attributed,
        sourceLine: line,
        markdownLineState: state,
        lineFonts: block.fonts,
        typography: typography,
        includeVisualAttributes: includeVisualAttributes,
        linkStatus: linkStatus)
    }
    return attributed
  }

  /// Whether `state` is a code body line that receives the calm
  /// comment/string tint — fenced, indented, or frontmatter content, but not
  /// the fence delimiter lines themselves (their label stays a muted caption).
  private static func markdownLineCarriesCodeTint(_ state: MarkdownLineStyleState) -> Bool {
    guard !state.isFenceDelimiter else { return false }
    return state.insideFence || state.isIndentedCodeBlock
  }

  /// Two language-agnostic tints over a code body line: comments recede to
  /// marker grey, quoted strings take a calm ink. Applied comment-first so a
  /// string wins inside its quotes. Never touches keywords — honest keyword
  /// colour needs a per-language grammar, which is IDE territory.
  private static func applyMarkdownCodeTint(to attributed: NSMutableAttributedString) {
    let text = attributed.string
    let full = NSRange(location: 0, length: (text as NSString).length)
    guard full.length > 0 else { return }
    for match in TextHighlightRule.codeComment.expression.matches(in: text, range: full) {
      attributed.addAttribute(
        .foregroundColor, value: MarkdownDocumentMetrics.codeCommentColor, range: match.range)
    }
    for match in TextHighlightRule.codeString.expression.matches(in: text, range: full) {
      attributed.addAttribute(
        .foregroundColor, value: MarkdownDocumentMetrics.codeStringColor, range: match.range)
    }
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
      if state.frontMatterSequenceValue != nil {
        return block(
          displayFont: MarkdownDocumentMetrics.frontMatterValueFont,
          foregroundColor: .labelColor,
          stylesInline: false)
      }
      if markdownFrontMatterField(in: line) != nil {
        return block(
          displayFont: MarkdownDocumentMetrics.frontMatterValueFont,
          foregroundColor: .labelColor,
          stylesInline: false)
      }
      return block(
        displayFont: MarkdownDocumentMetrics.frontMatterValueFont,
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
      // The language label reads as a muted caption (system font), in the same
      // register as table headers and image captions — not the mono body.
      return block(
        displayFont: MarkdownDocumentMetrics.codeLabelFont,
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
        foregroundColor: .labelColor)
    }

    if state.isSetextUnderline {
      return block(stylesInline: false)
    }

    if state.imageSource != nil {
      // The line's visible text is the alt text, rendered as a small muted
      // caption below the image block. The caption font set keeps the inline
      // image pass (which restyles the alt text) at caption size too.
      let caption = MarkdownDocumentMetrics.imageCaptionFont
      let captionSet = MarkdownFontSet(
        regular: caption, bold: caption, italic: caption, boldItalic: caption)
      return block(
        fonts: captionSet,
        displayFont: caption,
        foregroundColor: .secondaryLabelColor)
    }

    if let heading = markdownHeadingInfo(in: context.body) {
      let fonts = typography.heading(level: heading.level)
      return block(
        fonts: fonts,
        displayFont: fonts.regular,
        foregroundColor: .labelColor)
    }

    if markdownLineIsHorizontalRule(context.body) {
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
      !markdownLineIsHorizontalRule(context.body)
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
      if let value = state.frontMatterSequenceValue {
        return markdownFrontMatterSequenceDisplayMap(for: value, sourceText: line)
      }
      if let field = state.frontMatterField ?? markdownFrontMatterField(in: line) {
        return markdownFrontMatterDisplayMap(for: field, sourceText: line)
      }
      return .identity(line)
    }
    if state.isFenceDelimiter, let fence = markdownFenceInfo(in: line) {
      if state.insideFence {
        return .empty(sourceText: line)
      }
      // Only the matched opener shows a label; a closer (even one written with
      // trailing text like ```end) collapses to empty so it matches its slim row.
      let infoRange = markdownFenceInfoTextRange(in: line, markerLength: fence.markerLength)
      if state.isFenceLabel, infoRange.length > 0 {
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
    if state.isSetextUnderline || markdownLineIsHorizontalRule(context.body) {
      return .empty(sourceText: line)
    }
    if state.imageSource != nil, let map = markdownImageCaptionDisplayMap(for: line) {
      return map
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

  private static func markdownImageCaptionDisplayMap(for line: String) -> MarkdownDisplayMap? {
    guard let body = trimmedMarkdownBody(in: line) else { return nil }
    let range = NSRange(location: 0, length: body.nsTrimmed.length)
    let expressions = [
      linkedImageExpression,
      linkedReferenceImageExpression,
      imageExpression,
      referenceImageExpression,
    ]
    for expression in expressions {
      guard let match = expression.firstMatch(in: body.trimmed, range: range),
        match.range == range
      else {
        continue
      }
      let altRange = match.range(at: 1)
      let sourceStart = body.sourceOffset + altRange.location
      if altRange.length == 0 {
        return .empty(sourceText: line, insertionColumn: sourceStart)
      }
      return .map(
        sourceText: line,
        displayText: body.nsTrimmed.substring(with: altRange),
        sourceStart: sourceStart)
    }
    if let match = htmlImageExpression.firstMatch(in: body.trimmed, range: range),
      match.range == range,
      htmlImageAltLiteral(forMatch: body.trimmed) != nil
    {
      var map = MarkdownDisplayMap.map(
        sourceText: line,
        displayText: body.trimmed,
        sourceStart: body.sourceOffset)
      var protectedRanges: [NSRange] = []
      replaceLiteralMatchesInMap(
        expression: htmlImageExpression,
        decode: htmlImageAltLiteral(forMatch:),
        map: &map,
        protectedRanges: &protectedRanges)
      return map
    }
    return nil
  }

  private static func trimmedMarkdownBody(in line: String) -> (
    trimmed: String, nsTrimmed: NSString, sourceOffset: Int
  )? {
    let context = markdownLineContext(in: line)
    let nsBody = context.body as NSString
    var start = 0
    var end = nsBody.length
    while start < end {
      guard markdownTrimWhitespaceContains(nsBody.character(at: start)) else { break }
      start += 1
    }
    while end > start {
      guard markdownTrimWhitespaceContains(nsBody.character(at: end - 1)) else { break }
      end -= 1
    }
    guard start < end else { return nil }
    let range = NSRange(location: start, length: end - start)
    let trimmed = nsBody.substring(with: range)
    return (trimmed, trimmed as NSString, context.quotePrefixLength + start)
  }

  private static func markdownTrimWhitespaceContains(_ character: unichar) -> Bool {
    guard let scalar = UnicodeScalar(Int(character)) else { return false }
    return CharacterSet.whitespaces.contains(scalar)
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

  static func markdownFrontMatterField(in line: String) -> MarkdownFrontMatterField? {
    let nsLine = line as NSString
    let length = nsLine.length
    guard let colon = (0..<length).first(where: { nsLine.character(at: $0) == 58 }) else {
      return nil
    }

    let keyRange = trimmedRange(in: nsLine, range: NSRange(location: 0, length: colon))
    guard keyRange.length > 0 else { return nil }
    let key = nsLine.substring(with: keyRange)
    let valueRange = trimmedRange(
      in: nsLine,
      range: NSRange(location: min(length, colon + 1), length: max(0, length - colon - 1)))
    guard valueRange.length > 0 else {
      return MarkdownFrontMatterField(
        key: key,
        keyRange: keyRange,
        values: [
          MarkdownFrontMatterValue(text: "", sourceRange: NSRange(location: colon, length: 0))
        ],
        rendersValuesAsChips: false)
    }

    if let bracketValues = markdownFrontMatterBracketValues(in: nsLine, valueRange: valueRange) {
      return MarkdownFrontMatterField(
        key: key, keyRange: keyRange, values: bracketValues, rendersValuesAsChips: true)
    }

    if key == "allowed-tools",
      let listValues = markdownFrontMatterCommaValues(in: nsLine, valueRange: valueRange),
      listValues.count > 1
    {
      return MarkdownFrontMatterField(
        key: key, keyRange: keyRange, values: listValues, rendersValuesAsChips: true)
    }

    let scalar = strippedFrontMatterScalar(in: nsLine, valueRange: valueRange)
    return MarkdownFrontMatterField(
      key: key,
      keyRange: keyRange,
      values: [scalar],
      rendersValuesAsChips: false)
  }

  private static func markdownFrontMatterDisplayMap(
    for field: MarkdownFrontMatterField,
    sourceText: String
  ) -> MarkdownDisplayMap {
    var display = ""
    var boundaries: [Int] = [field.keyRange.location]
    var ranges: [NSRange] = []

    func appendMapped(_ text: String, sourceRange: NSRange) {
      let length = (text as NSString).length
      for index in 0..<length {
        display += (text as NSString).substring(with: NSRange(location: index, length: 1))
        let sourceLocation = min(NSMaxRange(sourceRange), sourceRange.location + index)
        ranges.append(NSRange(location: sourceLocation, length: min(1, sourceRange.length)))
        boundaries.append(min(NSMaxRange(sourceRange), sourceLocation + 1))
      }
    }

    func appendLiteral(_ text: String, sourceColumn: Int) {
      let length = (text as NSString).length
      for index in 0..<length {
        display += (text as NSString).substring(with: NSRange(location: index, length: 1))
        ranges.append(NSRange(location: sourceColumn, length: 0))
        boundaries.append(sourceColumn)
      }
    }

    appendMapped(field.key, sourceRange: field.keyRange)
    appendLiteral("\t", sourceColumn: NSMaxRange(field.keyRange))
    for (index, value) in field.values.enumerated() {
      if index > 0 {
        appendLiteral(
          field.rendersValuesAsChips
            ? MarkdownDocumentMetrics.frontMatterChipDisplaySeparator : "",
          sourceColumn: value.sourceRange.location)
      }
      appendMapped(value.text, sourceRange: value.sourceRange)
    }

    return MarkdownDisplayMap(
      sourceText: sourceText,
      displayText: display,
      boundaryColumns: boundaries,
      characterRanges: ranges)
  }

  private static func markdownFrontMatterSequenceDisplayMap(
    for value: MarkdownFrontMatterValue,
    sourceText: String
  ) -> MarkdownDisplayMap {
    var display = ""
    var boundaries: [Int] = [value.sourceRange.location]
    var ranges: [NSRange] = []

    func appendMapped(_ text: String, sourceRange: NSRange) {
      let length = (text as NSString).length
      for index in 0..<length {
        display += (text as NSString).substring(with: NSRange(location: index, length: 1))
        let sourceLocation = min(NSMaxRange(sourceRange), sourceRange.location + index)
        ranges.append(NSRange(location: sourceLocation, length: min(1, sourceRange.length)))
        boundaries.append(min(NSMaxRange(sourceRange), sourceLocation + 1))
      }
    }

    display += "\t"
    ranges.append(NSRange(location: value.sourceRange.location, length: 0))
    boundaries.append(value.sourceRange.location)
    appendMapped(value.text, sourceRange: value.sourceRange)

    return MarkdownDisplayMap(
      sourceText: sourceText,
      displayText: display,
      boundaryColumns: boundaries,
      characterRanges: ranges)
  }

  private static func markdownFrontMatterBracketValues(
    in nsLine: NSString,
    valueRange: NSRange
  ) -> [MarkdownFrontMatterValue]? {
    guard valueRange.length >= 2,
      nsLine.character(at: valueRange.location) == 91,
      nsLine.character(at: NSMaxRange(valueRange) - 1) == 93
    else {
      return nil
    }
    let inner = NSRange(location: valueRange.location + 1, length: valueRange.length - 2)
    return markdownFrontMatterCommaValues(in: nsLine, valueRange: inner) ?? []
  }

  private static func markdownFrontMatterCommaValues(
    in nsLine: NSString,
    valueRange: NSRange
  ) -> [MarkdownFrontMatterValue]? {
    var values: [MarkdownFrontMatterValue] = []
    var start = valueRange.location
    let end = NSMaxRange(valueRange)
    var index = start
    var quote: unichar?
    while index <= end {
      let atEnd = index == end
      let character = atEnd ? 0 : nsLine.character(at: index)
      if !atEnd, character == 34 || character == 39 {
        if quote == character {
          quote = nil
        } else if quote == nil {
          quote = character
        }
      }
      if atEnd || (character == 44 && quote == nil) {
        let rawRange = NSRange(location: start, length: max(0, index - start))
        let trimmed = trimmedRange(in: nsLine, range: rawRange)
        if trimmed.length > 0 {
          values.append(strippedFrontMatterScalar(in: nsLine, valueRange: trimmed))
        }
        start = min(end, index + 1)
      }
      index += 1
    }
    return values.isEmpty ? nil : values
  }

  private static func markdownFrontMatterSequenceValue(in line: String) -> MarkdownFrontMatterValue?
  {
    let nsLine = line as NSString
    let lineRange = NSRange(location: 0, length: nsLine.length)
    let trimmed = trimmedRange(in: nsLine, range: lineRange)
    guard trimmed.length >= 2,
      nsLine.character(at: trimmed.location) == 45,
      nsLine.character(at: trimmed.location + 1) == 32
    else {
      return nil
    }
    let valueRange = trimmedRange(
      in: nsLine,
      range: NSRange(
        location: trimmed.location + 2,
        length: max(0, NSMaxRange(trimmed) - trimmed.location - 2)))
    guard valueRange.length > 0 else { return nil }
    return strippedFrontMatterScalar(in: nsLine, valueRange: valueRange)
  }

  private static func strippedFrontMatterScalar(
    in nsLine: NSString,
    valueRange: NSRange
  ) -> MarkdownFrontMatterValue {
    guard valueRange.length >= 2 else {
      return MarkdownFrontMatterValue(
        text: nsLine.substring(with: valueRange), sourceRange: valueRange)
    }
    let first = nsLine.character(at: valueRange.location)
    let last = nsLine.character(at: NSMaxRange(valueRange) - 1)
    if (first == 34 && last == 34) || (first == 39 && last == 39) {
      let inner = NSRange(location: valueRange.location + 1, length: valueRange.length - 2)
      return MarkdownFrontMatterValue(text: nsLine.substring(with: inner), sourceRange: inner)
    }
    return MarkdownFrontMatterValue(
      text: nsLine.substring(with: valueRange), sourceRange: valueRange)
  }

  private static func trimmedRange(in nsLine: NSString, range: NSRange) -> NSRange {
    var start = max(0, range.location)
    var end = min(nsLine.length, NSMaxRange(range))
    while start < end {
      let character = nsLine.character(at: start)
      guard character == 32 || character == 9 else { break }
      start += 1
    }
    while end > start {
      let character = nsLine.character(at: end - 1)
      guard character == 32 || character == 9 else { break }
      end -= 1
    }
    return NSRange(location: start, length: max(0, end - start))
  }

  private static func renderedInlineDisplayMap(from map: MarkdownDisplayMap)
    -> MarkdownDisplayMap
  {
    var targets: [MarkdownLinkTarget] = []
    return renderedInlineDisplayMap(from: map, collectingLinkTargets: &targets)
  }

  private static func renderedInlineDisplayMap(
    from map: MarkdownDisplayMap,
    collectingLinkTargets targets: inout [MarkdownLinkTarget]
  )
    -> MarkdownDisplayMap
  {
    var current = map
    var collectedTargets: [MarkdownPendingLinkTarget] = []
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
    // A single-line <img> collapses to its alt caption — after inline-code
    // protection, so a code example like `<img …>` keeps its literal tag, but
    // before entity decoding, so entities inside the tag's own attributes cannot
    // leave protected ranges that would block the tag from collapsing. The alt
    // run is protected, so it is not re-interpreted as markup.
    replaceLiteralMatchesInMap(
      expression: htmlImageExpression, decode: htmlImageAltLiteral(forMatch:),
      map: &current, protectedRanges: &protectedRanges)
    // HTML entities decode right after inline code, so an entity inside `code`
    // (now a protected span) stays literal; the decoded char is protected too,
    // so escaped HTML like &lt;b&gt; is not re-interpreted as a tag.
    replaceLiteralMatchesInMap(
      expression: htmlEntityNamedExpression, decode: htmlNamedEntityLiteral(forMatch:),
      map: &current, protectedRanges: &protectedRanges)
    replaceLiteralMatchesInMap(
      expression: htmlEntityNumericExpression, decode: htmlNumericEntityLiteral(forMatch:),
      map: &current, protectedRanges: &protectedRanges)
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
      protectsReplacement: true,
      onReplace: { match, text, _, _, sourceGroupRange in
        let destination = text.substring(with: match.range(at: 2))
        collectedTargets.append(
          MarkdownPendingLinkTarget(sourceRange: sourceGroupRange, destination: destination))
      })
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
      protectsReplacement: true,
      onReplace: { match, text, _, _, sourceGroupRange in
        let destination = text.substring(with: match.range(at: 1))
        collectedTargets.append(
          MarkdownPendingLinkTarget(sourceRange: sourceGroupRange, destination: destination))
      })
    // Inline HTML formatting tags strip to their inner text (group 1), like the
    // markdown emphasis rules; a safe-href <a> strips to its text (group 2);
    // <br> becomes a space. allowsContainedProtectedRanges lets a tag wrap a
    // decoded entity, inline code, or a nested tag and still strip. (Markdown
    // emphasis written inside a tag keeps its markers — a rare mix.)
    // Repeat the paired-tag pass while it keeps stripping, so a nested tag
    // (<b><i>x</i></b>) fully unwraps once the inner tag collapses. A line with
    // no tags changes nothing on the first pass and exits immediately, so plain
    // prose pays a single pass; the cap bounds pathological nesting.
    var pairedPasses = 0
    var pairedChanged = true
    while pairedChanged, pairedPasses < htmlMaxNestingPasses {
      let before = current.displayLength
      for expression in htmlPairedInlineExpressions {
        replaceRenderedMatchesInMap(
          expression: expression,
          replacementGroup: 1,
          map: &current,
          protectedRanges: &protectedRanges,
          protectsReplacement: true,
          allowsContainedProtectedRanges: true)
      }
      pairedChanged = current.displayLength != before
      pairedPasses += 1
    }
    replaceRenderedMatchesInMap(
      expression: htmlLinkExpression,
      replacementGroup: 2,
      map: &current,
      protectedRanges: &protectedRanges,
      protectsReplacement: true,
      allowsContainedProtectedRanges: true,
      shouldReplace: htmlLinkHasSafeHref,
      onReplace: { match, text, _, _, sourceGroupRange in
        guard let raw = htmlTagAttribute("href", in: text.substring(with: match.range)),
          let destination = sanitizedHTMLHref(raw)
        else {
          return
        }
        collectedTargets.append(
          MarkdownPendingLinkTarget(sourceRange: sourceGroupRange, destination: destination))
      })
    replaceLiteralMatchesInMap(
      expression: htmlLineBreakExpression, decode: { _ in " " },
      map: &current, protectedRanges: &protectedRanges)
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
    targets.append(
      contentsOf: collectedTargets.compactMap { target in
        guard let displayRange = current.displayRange(forSourceRange: target.sourceRange) else {
          return nil
        }
        return MarkdownLinkTarget(displayRange: displayRange, destination: target.destination)
      })
    return current
  }

  private static func replaceRenderedMatchesInMap(
    expression: NSRegularExpression,
    replacementGroup: Int,
    map: inout MarkdownDisplayMap,
    protectedRanges: inout [NSRange],
    protectsReplacement: Bool,
    allowsContainedProtectedRanges: Bool = false,
    shouldReplace: ((NSTextCheckingResult, NSString) -> Bool)? = nil,
    onReplace: (
      (
        _ match: NSTextCheckingResult,
        _ text: NSString,
        _ adjustedMatch: NSRange,
        _ adjustedGroup: NSRange,
        _ sourceGroupRange: NSRange
      ) -> Void
    )? = nil
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
      if let shouldReplace, !shouldReplace(match, nsOriginal) { continue }
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
      let sourceGroupRange = map.bufferRange(
        forDisplayStart: adjustedGroup.location,
        end: NSMaxRange(adjustedGroup),
        includeWholeLineMarkers: false)
      onReplace?(match, nsOriginal, adjustedMatch, adjustedGroup, sourceGroupRange)
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
    sourceLine: String,
    markdownLineState: MarkdownLineStyleState,
    lineFonts: MarkdownFontSet,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool,
    linkStatus: MarkdownLinkStatusProvider?
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
    // Mirror the map pass: collapse a single-line <img> to its alt caption after
    // inline-code protection (so `<img …>` in a code example stays literal) but
    // before entity decoding, styled like a markdown image's alt (muted, line
    // font). Same decode closure, so the attributed string stays byte-identical
    // to the display string.
    replaceLiteralMatches(
      expression: htmlImageExpression, decode: htmlImageAltLiteral(forMatch:),
      attributes: markdownAttributes(
        font: lineFonts.regular,
        foregroundColor: .secondaryLabelColor,
        includeVisualAttributes: includeVisualAttributes),
      in: attributed, protectedRanges: &protectedRanges)
    let entityAttributes = markdownAttributes(
      font: lineFonts.regular, foregroundColor: .labelColor,
      includeVisualAttributes: includeVisualAttributes)
    replaceLiteralMatches(
      expression: htmlEntityNamedExpression, decode: htmlNamedEntityLiteral(forMatch:),
      attributes: entityAttributes, in: attributed, protectedRanges: &protectedRanges)
    replaceLiteralMatches(
      expression: htmlEntityNumericExpression, decode: htmlNumericEntityLiteral(forMatch:),
      attributes: entityAttributes, in: attributed, protectedRanges: &protectedRanges)
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
    // Inline HTML formatting tags — mirror the map pass exactly (same order and
    // same safe-href skip), so the attributed string stays byte-identical to the
    // display string and the caret map round-trips.
    let regular = lineFonts.regular
    let htmlInlineAttributes: [(NSRegularExpression, [NSAttributedString.Key: Any])] = [
      (htmlBoldExpression, [.font: lineFonts.bold]),
      (htmlItalicExpression, [.font: lineFonts.italic]),
      (
        htmlStrikeExpression,
        markdownHTMLStrikeAttributes(
          font: regular, includeVisualAttributes: includeVisualAttributes)
      ),
      (
        htmlCodeExpression,
        markdownInlineCodeAttributes(
          font: typography.inlineCode, includeVisualAttributes: includeVisualAttributes)
      ),
      (
        htmlKbdExpression,
        markdownInlineCodeAttributes(
          font: typography.inlineCode, includeVisualAttributes: includeVisualAttributes)
      ),
      (
        htmlMarkExpression,
        markdownInlineCodeAttributes(
          font: regular, includeVisualAttributes: includeVisualAttributes)
      ),
      (
        htmlUnderlineExpression,
        markdownHTMLUnderlineAttributes(
          font: regular, includeVisualAttributes: includeVisualAttributes)
      ),
      (
        htmlSmallExpression,
        markdownAttributes(
          font: regular, foregroundColor: .secondaryLabelColor,
          includeVisualAttributes: includeVisualAttributes)
      ),
    ]
    // Mirror the map pass's bounded fixpoint so nested tags fully unwrap and
    // the attributed string stays in parity with the display string.
    var pairedPasses = 0
    var pairedChanged = true
    while pairedChanged, pairedPasses < htmlMaxNestingPasses {
      let before = attributed.length
      for (expression, attributes) in htmlInlineAttributes {
        replaceRenderedMatches(
          expression: expression,
          replacementGroup: 1,
          attributes: attributes,
          in: attributed,
          protectedRanges: &protectedRanges,
          protectsReplacement: true,
          allowsContainedProtectedRanges: true)
      }
      pairedChanged = attributed.length != before
      pairedPasses += 1
    }
    replaceRenderedMatches(
      expression: htmlLinkExpression,
      replacementGroup: 2,
      attributes: renderedLinkAttributes(
        font: regular, includeVisualAttributes: includeVisualAttributes),
      in: attributed,
      protectedRanges: &protectedRanges,
      protectsReplacement: true,
      allowsContainedProtectedRanges: true,
      shouldReplace: htmlLinkHasSafeHref)
    replaceLiteralMatches(
      expression: htmlLineBreakExpression, decode: { _ in " " },
      attributes: markdownAttributes(
        font: regular, foregroundColor: .labelColor,
        includeVisualAttributes: includeVisualAttributes),
      in: attributed, protectedRanges: &protectedRanges)
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
    applyRenderedLinkColors(
      to: attributed,
      sourceLine: sourceLine,
      state: markdownLineState,
      includeVisualAttributes: includeVisualAttributes,
      linkStatus: linkStatus)
  }

  private static func applyRenderedLinkColors(
    to attributed: NSMutableAttributedString,
    sourceLine: String,
    state: MarkdownLineStyleState,
    includeVisualAttributes: Bool,
    linkStatus: MarkdownLinkStatusProvider?
  ) {
    guard includeVisualAttributes else { return }
    for target in markdownLinkTargets(for: sourceLine, state: state) {
      guard target.displayRange.location >= 0,
        target.displayRange.length > 0,
        NSMaxRange(target.displayRange) <= attributed.length
      else {
        continue
      }
      attributed.addAttribute(
        .foregroundColor,
        value: renderedLinkColor(destination: target.destination, linkStatus: linkStatus),
        range: target.displayRange)
    }
  }

  private static func replaceRenderedMatches(
    expression: NSRegularExpression,
    replacementGroup: Int,
    attributes: [NSAttributedString.Key: Any],
    in attributed: NSMutableAttributedString,
    protectedRanges: inout [NSRange],
    protectsReplacement: Bool,
    allowsContainedProtectedRanges: Bool = false,
    preservesProtectedAttributes: Bool = false,
    shouldReplace: ((NSTextCheckingResult, NSString) -> Bool)? = nil
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
      if let shouldReplace, !shouldReplace(match, nsOriginal) { continue }
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
      if protectsReplacement, replacementRange.length > 0 {
        protectedRanges.append(replacementRange)
      }
    }
  }

  /// Replaces each match of `expression` with the literal returned by `decode`
  /// (nil leaves the match untouched), maintaining the display↔buffer map. Used
  /// for HTML entities (the decoded character) and `<br>` (a space). The decoded
  /// run is protected so escaped HTML like `&lt;b&gt;` is not re-interpreted.
  private static func replaceLiteralMatchesInMap(
    expression: NSRegularExpression,
    decode: (String) -> String?,
    map: inout MarkdownDisplayMap,
    protectedRanges: inout [NSRange]
  ) {
    let nsOriginal = NSString(string: map.displayText)
    let matches = expression.matches(
      in: nsOriginal as String, range: NSRange(location: 0, length: nsOriginal.length))
    var locationDelta = 0
    for match in matches {
      guard let literal = decode(nsOriginal.substring(with: match.range)) else { continue }
      let adjustedMatch = match.range.offset(by: locationDelta)
      guard adjustedMatch.location >= 0, NSMaxRange(adjustedMatch) <= map.displayLength,
        !protectedRanges.contains(where: { rangesIntersect($0, adjustedMatch) })
      else {
        continue
      }
      let literalLength = (literal as NSString).length
      let beforeLength = map.displayLength
      map = map.replacingWithLiteral(match: adjustedMatch, literal: literal)
      let delta = map.displayLength - beforeLength
      let replacementRange = NSRange(location: adjustedMatch.location, length: literalLength)
      protectedRanges = remapRanges(
        protectedRanges, replacing: adjustedMatch, withGroup: adjustedMatch, by: delta)
      locationDelta += delta
      if literalLength > 0 { protectedRanges.append(replacementRange) }
    }
  }

  /// The attributed-string twin of `replaceLiteralMatchesInMap`: the exact same
  /// matches must decode (the closure is pure) so the display string and the
  /// attributed string stay byte-identical for caret parity.
  private static func replaceLiteralMatches(
    expression: NSRegularExpression,
    decode: (String) -> String?,
    attributes: [NSAttributedString.Key: Any],
    in attributed: NSMutableAttributedString,
    protectedRanges: inout [NSRange]
  ) {
    // An immutable snapshot — NSMutableAttributedString.string is a live view
    // that would shift the precomputed match ranges as we splice.
    let nsOriginal = NSString(string: attributed.string)
    let matches = expression.matches(
      in: nsOriginal as String, range: NSRange(location: 0, length: nsOriginal.length))
    var locationDelta = 0
    for match in matches {
      guard let literal = decode(nsOriginal.substring(with: match.range)) else { continue }
      let adjustedMatch = match.range.offset(by: locationDelta)
      guard adjustedMatch.location >= 0, NSMaxRange(adjustedMatch) <= attributed.length,
        !protectedRanges.contains(where: { rangesIntersect($0, adjustedMatch) })
      else {
        continue
      }
      let replacement = NSAttributedString(string: literal, attributes: attributes)
      attributed.replaceCharacters(in: adjustedMatch, with: replacement)
      let replacementRange = NSRange(location: adjustedMatch.location, length: replacement.length)
      let delta = replacement.length - adjustedMatch.length
      protectedRanges = remapRanges(
        protectedRanges, replacing: adjustedMatch, withGroup: adjustedMatch, by: delta)
      locationDelta += delta
      if replacement.length > 0 { protectedRanges.append(replacementRange) }
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

  private static func markdownReferenceDefinitions(
    in lines: [String],
    states: [MarkdownLineStyleState]
  ) -> [String: String] {
    var definitions: [String: String] = [:]
    for index in lines.indices {
      let state = index < states.count ? states[index] : .plain
      guard state.isReferenceDefinition, !state.insideFence, !state.insideFrontMatter,
        !state.isIndentedCodeBlock
      else {
        continue
      }
      guard
        let definition = markdownReferenceDefinitionParts(
          in: markdownLineContext(in: lines[index]).body)
      else {
        continue
      }
      definitions[definition.id] = definition.destination
    }
    return definitions
  }

  private static func markdownReferenceDefinitionParts(in line: String) -> (
    id: String, destination: String
  )? {
    let nsLine = line as NSString
    let range = NSRange(location: 0, length: nsLine.length)
    guard
      let match = referenceDefinitionPartsExpression.firstMatch(in: line, range: range),
      let id = markdownReferenceIdentifier(nsLine.substring(with: match.range(at: 1))),
      let destination = markdownReferenceDefinitionDestination(
        in: nsLine.substring(with: match.range(at: 2)))
    else {
      return nil
    }
    return (id, destination)
  }

  private static func markdownReferenceDefinitionDestination(in raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let nsTrimmed = trimmed as NSString

    if trimmed.hasPrefix("<") {
      let end = nsTrimmed.range(of: ">").location
      guard end != NSNotFound else { return nil }
      return markdownImageDestination(in: nsTrimmed.substring(to: end + 1))
    }

    var end = 0
    while end < nsTrimmed.length {
      guard !markdownTrimWhitespaceContains(nsTrimmed.character(at: end)) else { break }
      end += 1
    }
    guard end > 0 else { return nil }
    return markdownImageDestination(in: nsTrimmed.substring(to: end))
  }

  private static func markdownReferenceIdentifier(_ raw: String) -> String? {
    let parts = raw.split(whereSeparator: { $0.isWhitespace })
    let normalized = parts.joined(separator: " ").lowercased()
    return normalized.isEmpty ? nil : normalized
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
        // The opening and closing `---` lines render empty, so collapse them
        // to slim rows rather than leaving a full empty row at the card edges.
        states[0].isFrontMatterDelimiter = true
        states[closingIndex].isFrontMatterDelimiter = true
        annotateMarkdownFrontMatterFields(in: lines, states: &states, closingIndex: closingIndex)
      }
    }

    var fenceOpeningIndex: Int?
    for index in lines.indices {
      guard !states[index].insideFrontMatter, isMarkdownFenceLine(lines[index]) else {
        continue
      }
      if let openingIndex = fenceOpeningIndex {
        states[openingIndex].isFenceDelimiter = true
        states[openingIndex].isFenceOpen = true
        if let fence = markdownFenceInfo(in: lines[openingIndex]) {
          let infoRange = markdownFenceInfoTextRange(
            in: lines[openingIndex], markerLength: fence.markerLength)
          states[openingIndex].isFenceLabel = infoRange.length > 0
        }
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

    let referenceDefinitions = markdownReferenceDefinitions(in: lines, states: states)

    for index in lines.indices {
      let state = states[index]
      guard !state.insideFence, !state.insideFrontMatter, !state.isFenceDelimiter,
        !state.isIndentedCodeBlock, !state.isTableRow, !state.isTableSeparator,
        !state.isReferenceDefinition, !state.isSetextUnderline,
        state.setextHeadingLevel == nil, state.headingLevel == nil
      else {
        continue
      }
      states[index].imageSource = markdownImageOnlyLine(
        in: markdownLineContext(in: lines[index]).body,
        referenceDefinitions: referenceDefinitions)
    }

    return states
  }

  private static func annotateMarkdownFrontMatterFields(
    in lines: [String],
    states: inout [MarkdownLineStyleState],
    closingIndex: Int
  ) {
    guard closingIndex > 1 else { return }
    var index = 1
    while index < closingIndex {
      if let value = markdownFrontMatterSequenceValue(in: lines[index]) {
        states[index].frontMatterSequenceValue = value
      } else if let field = markdownFrontMatterField(in: lines[index]) {
        states[index].frontMatterField = field
      }
      index += 1
    }
  }

  /// Longest body that may classify as an image-only line. Far above any real
  /// `![alt](path-or-url)`, and far below the engine's huge-line clipping
  /// threshold — a clipped huge line (e.g. an unsupported base64 data URI)
  /// must never carry image-block metrics its grid-drawn rows cannot honor.
  private static let imageOnlyLineMaximumLength = 2_048

  /// The image source when the line's whole body is a single image — either a
  /// markdown `![alt](…)` or an HTML `<img src=… alt=…>`; nil otherwise. Such
  /// lines render as image blocks.
  private static func markdownImageOnlyLine(
    in body: String,
    referenceDefinitions: [String: String] = [:]
  ) -> MarkdownImageSource? {
    let trimmed = body.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let nsTrimmed = trimmed as NSString
    guard nsTrimmed.length <= imageOnlyLineMaximumLength else { return nil }
    let range = NSRange(location: 0, length: nsTrimmed.length)
    if let image = markdownLinkedImageOnlyLine(
      trimmed: trimmed,
      nsTrimmed: nsTrimmed,
      range: range,
      referenceDefinitions: referenceDefinitions)
    {
      return image
    }
    if let match = imageExpression.firstMatch(in: trimmed, range: range),
      match.range == range,
      let source = markdownImageDestination(in: nsTrimmed.substring(with: match.range(at: 2)))
    {
      return MarkdownImageSource(
        source: source,
        altText: nsTrimmed.substring(with: match.range(at: 1)))
    }
    if let match = referenceImageExpression.firstMatch(in: trimmed, range: range),
      match.range == range,
      let source = markdownReferenceImageDestination(
        altText: nsTrimmed.substring(with: match.range(at: 1)),
        referenceText: nsTrimmed.substring(with: match.range(at: 2)),
        definitions: referenceDefinitions)
    {
      return MarkdownImageSource(
        source: source,
        altText: nsTrimmed.substring(with: match.range(at: 1)))
    }
    return htmlImageOnlyLine(trimmed: trimmed, nsTrimmed: nsTrimmed, range: range)
  }

  private static func markdownLinkedImageOnlyLine(
    trimmed: String,
    nsTrimmed: NSString,
    range: NSRange,
    referenceDefinitions: [String: String]
  ) -> MarkdownImageSource? {
    if let match = linkedImageExpression.firstMatch(in: trimmed, range: range),
      match.range == range,
      let source = markdownImageDestination(in: nsTrimmed.substring(with: match.range(at: 2))),
      let linkDestination = markdownImageDestination(
        in: nsTrimmed.substring(with: match.range(at: 3)))
    {
      return MarkdownImageSource(
        source: source,
        altText: nsTrimmed.substring(with: match.range(at: 1)),
        linkDestination: linkDestination)
    }
    if let match = linkedReferenceImageExpression.firstMatch(in: trimmed, range: range),
      match.range == range,
      let source = markdownReferenceImageDestination(
        altText: nsTrimmed.substring(with: match.range(at: 1)),
        referenceText: nsTrimmed.substring(with: match.range(at: 2)),
        definitions: referenceDefinitions),
      let linkDestination = markdownImageDestination(
        in: nsTrimmed.substring(with: match.range(at: 3)))
    {
      return MarkdownImageSource(
        source: source,
        altText: nsTrimmed.substring(with: match.range(at: 1)),
        linkDestination: linkDestination)
    }
    return nil
  }

  private static func markdownReferenceImageDestination(
    altText: String,
    referenceText: String,
    definitions: [String: String]
  ) -> String? {
    let rawID = referenceText.isEmpty ? altText : referenceText
    guard let id = markdownReferenceIdentifier(rawID) else { return nil }
    return definitions[id]
  }

  /// The image source when the trimmed body is a single, safe HTML `<img>` tag.
  private static func htmlImageOnlyLine(
    trimmed: String, nsTrimmed: NSString, range: NSRange
  ) -> MarkdownImageSource? {
    guard let match = htmlImageExpression.firstMatch(in: trimmed, range: range),
      match.range == range,
      let source = htmlImageSource(in: trimmed)
    else {
      return nil
    }
    return MarkdownImageSource(source: source, altText: htmlImageAlt(in: trimmed) ?? "")
  }

  /// Extracts the destination from an image target, dropping an optional
  /// quoted title (`a.png "title"`) and surrounding angle brackets (`<a b.png>`).
  private static func markdownImageDestination(in target: String) -> String? {
    var destination = target.trimmingCharacters(in: .whitespaces)
    if let match = imageTitleExpression.firstMatch(
      in: destination,
      range: NSRange(location: 0, length: (destination as NSString).length))
    {
      destination = (destination as NSString).substring(with: match.range(at: 1))
    }
    if destination.hasPrefix("<"), destination.hasSuffix(">"), destination.count >= 2 {
      destination = String(destination.dropFirst().dropLast())
    }
    destination = destination.trimmingCharacters(in: .whitespaces)
    return destination.isEmpty ? nil : destination
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

  // MARK: - Markdown source fallback path

  private static func styleMarkdownSourceDocument(
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
        styleMarkdownSourceLine(
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

  private static func styleMarkdownSourceLine(
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
      muteMarkdownSourceSyntax(
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
          foregroundColor: .labelColor,
          includeVisualAttributes: includeVisualAttributes),
        range: lineRange)
    } else if state.isSetextUnderline {
      muteMarkdownSourceSyntax(
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
          foregroundColor: .labelColor,
          includeVisualAttributes: includeVisualAttributes),
        range: lineRange)
      muteMarkdownSourceSyntax(
        range: NSRange(location: lineRange.location, length: heading.prefixLength),
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes)
    } else if let prefixLength = markdownBlockPrefixLength(in: line) {
      lineFonts = typography.body
      muteMarkdownSourceSyntax(
        range: NSRange(location: lineRange.location, length: prefixLength),
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes)
    } else if markdownLineIsHorizontalRule(line) {
      lineFonts = typography.body
      muteMarkdownSourceSyntax(
        range: lineRange,
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes)
    } else {
      lineFonts = typography.body
    }

    styleMarkdownSourceInline(
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

  private static func styleMarkdownSourceInline(
    in line: String,
    lineRange: NSRange,
    textStorage: NSMutableAttributedString,
    lineFonts: MarkdownFontSet,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool
  ) {
    var protectedRanges = styleMarkdownSourceInlineCode(
      in: line,
      lineRange: lineRange,
      textStorage: textStorage,
      typography: typography,
      includeVisualAttributes: includeVisualAttributes)
    protectedRanges += styleMarkdownSourceLinks(
      in: line,
      lineRange: lineRange,
      textStorage: textStorage,
      lineFonts: lineFonts,
      includeVisualAttributes: includeVisualAttributes)
    styleMarkdownSourceDelimitedSpan(
      expression: boldItalicExpression,
      markerLength: 3,
      style: .boldItalic,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes)
    styleMarkdownSourceDelimitedSpan(
      expression: boldExpression,
      markerLength: 2,
      style: .bold,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes)
    styleMarkdownSourceDelimitedSpan(
      expression: italicExpression,
      markerLength: 1,
      style: .italic,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes)
    styleMarkdownSourceDelimitedSpan(
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

  private static func styleMarkdownSourceInlineCode(
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
      muteMarkdownSourceSyntax(
        range: NSRange(location: lineRange.location + match.range.location, length: 1),
        in: textStorage,
        font: typography.inlineCode,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSourceSyntax(
        range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1, length: 1),
        in: textStorage,
        font: typography.inlineCode,
        includeVisualAttributes: includeVisualAttributes)
    }
    return protectedRanges
  }

  private static func styleMarkdownSourceLinks(
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
      muteMarkdownSourceSyntax(
        range: NSRange(location: lineRange.location + match.range.location, length: 1),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSourceSyntax(
        range: NSRange(location: NSMaxRange(label), length: 2),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSourceSyntax(
        range: url,
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSourceSyntax(
        range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1, length: 1),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
    }
    return protectedRanges
  }

  private static func styleMarkdownSourceDelimitedSpan(
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
      muteMarkdownSourceSyntax(
        range: NSRange(location: lineRange.location + match.range.location, length: markerLength),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
      muteMarkdownSourceSyntax(
        range: NSRange(
          location: lineRange.location + NSMaxRange(match.range) - markerLength,
          length: markerLength),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes)
    }
  }

  private static func muteMarkdownSourceSyntax(
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

  private static func applyMarkdownFrontMatterAttributes(
    to attributed: NSMutableAttributedString,
    field: MarkdownFrontMatterField,
    includeVisualAttributes: Bool
  ) {
    let keyLength = (field.key as NSString).length
    let fullRange = NSRange(location: 0, length: attributed.length)
    guard keyLength > 0, attributed.length >= keyLength else { return }

    attributed.addAttribute(
      .paragraphStyle,
      value: markdownFrontMatterParagraphStyle(rendersValuesAsChips: field.rendersValuesAsChips),
      range: fullRange)
    attributed.addAttribute(
      .font, value: MarkdownDocumentMetrics.frontMatterKeyFont,
      range: NSRange(location: 0, length: keyLength))
    if includeVisualAttributes {
      attributed.addAttribute(
        .foregroundColor,
        value: NSColor.tertiaryLabelColor,
        range: NSRange(location: 0, length: keyLength))
    }

    let valueStart = min(attributed.length, keyLength + 1)
    guard valueStart < attributed.length else { return }
    var offset = valueStart
    let chipSeparatorLength = (MarkdownDocumentMetrics.frontMatterChipDisplaySeparator as NSString)
      .length
    for (index, value) in field.values.enumerated() {
      if index > 0, field.rendersValuesAsChips {
        let separatorRange = NSRange(location: offset, length: chipSeparatorLength)
        if NSMaxRange(separatorRange) <= attributed.length {
          attributed.addAttribute(
            .font, value: MarkdownDocumentMetrics.frontMatterChipFont, range: separatorRange)
        }
        offset += chipSeparatorLength
      }
      let length = (value.text as NSString).length
      guard length > 0, offset + length <= attributed.length else { continue }
      let range = NSRange(location: offset, length: length)
      let font =
        field.rendersValuesAsChips
        ? MarkdownDocumentMetrics.frontMatterChipFont
        : (field.key == "name"
          ? MarkdownDocumentMetrics.frontMatterEmphasizedValueFont
          : MarkdownDocumentMetrics.frontMatterValueFont)
      attributed.addAttribute(.font, value: font, range: range)
      if includeVisualAttributes {
        attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
      }
      offset += length
    }
  }

  private static func applyMarkdownFrontMatterSequenceAttributes(
    to attributed: NSMutableAttributedString,
    includeVisualAttributes: Bool
  ) {
    let fullRange = NSRange(location: 0, length: attributed.length)
    guard fullRange.length > 0 else { return }
    attributed.addAttribute(
      .paragraphStyle,
      value: markdownFrontMatterParagraphStyle(rendersValuesAsChips: true),
      range: fullRange)
    attributed.addAttribute(
      .font,
      value: MarkdownDocumentMetrics.frontMatterChipFont,
      range: fullRange)
    if includeVisualAttributes {
      attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
    }
  }

  private static func markdownFrontMatterParagraphStyle(
    rendersValuesAsChips: Bool
  ) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    let valueColumn =
      MarkdownDocumentMetrics.frontMatterKeyColumnWidth
      + (rendersValuesAsChips ? MarkdownDocumentMetrics.frontMatterChipHorizontalPadding : 0)
    style.defaultTabInterval = 0
    style.tabStops = [NSTextTab(textAlignment: .left, location: valueColumn)]
    style.headIndent = valueColumn
    return style
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

  private static func renderedLinkColor(
    destination: String?,
    linkStatus: MarkdownLinkStatusProvider?
  ) -> NSColor {
    let state = destination.flatMap { linkStatus?($0) } ?? .valid
    return state == .invalid ? MarkdownDocumentMetrics.brokenLinkColor : .linkColor
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

  // MARK: Inline HTML

  private static func markdownHTMLUnderlineAttributes(font: NSFont, includeVisualAttributes: Bool)
    -> [NSAttributedString.Key: Any]
  {
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if includeVisualAttributes {
      attributes[.foregroundColor] = NSColor.labelColor
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }
    return attributes
  }

  private static func markdownHTMLStrikeAttributes(font: NSFont, includeVisualAttributes: Bool)
    -> [NSAttributedString.Key: Any]
  {
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if includeVisualAttributes {
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }
    return attributes
  }

  /// The decoded character for a named HTML entity match (the whole `&name;`),
  /// or nil for an unknown name (left literal, like a browser) or one that
  /// decodes to an unsafe invisible/control scalar.
  private static func htmlNamedEntityLiteral(forMatch match: String) -> String? {
    let name = String(match.dropFirst().dropLast())  // strip & and ;
    guard let literal = htmlNamedEntities[name],
      literal.unicodeScalars.allSatisfy(isSafeHTMLScalar)
    else {
      return nil
    }
    return literal
  }

  /// The decoded character for a numeric entity match (`&#123;` / `&#x1F600;`),
  /// or nil when the code point is invalid or an unsafe control/format scalar.
  private static func htmlNumericEntityLiteral(forMatch match: String) -> String? {
    let body = match.dropFirst(2).dropLast()  // strip "&#" and ";"
    let value: UInt32?
    if let first = body.first, first == "x" || first == "X" {
      value = UInt32(body.dropFirst(), radix: 16)
    } else {
      value = UInt32(body, radix: 10)
    }
    guard let value, let scalar = Unicode.Scalar(value), isSafeHTMLScalar(scalar) else {
      return nil
    }
    return String(scalar)
  }

  /// Rejects NUL, C0/C1 controls (except tab), soft hyphen, and the invisible
  /// bidi/format/zero-width characters so a decoded entity cannot inject
  /// invisible reordering, joiners, or control characters.
  private static func isSafeHTMLScalar(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    if value == 0 { return false }
    if value < 0x20, value != 0x09 { return false }  // C0 except tab
    if (0x7F...0x9F).contains(value) { return false }  // DEL + C1
    switch value {
    case 0x00AD,  // soft hyphen
      0x061C,  // Arabic letter mark
      0x180E,  // Mongolian vowel separator
      0x200B...0x200F,  // zero-width space/joiners, LRM/RLM
      0x202A...0x202E,  // bidi embeddings/overrides
      0x2060...0x2064,  // word joiner + invisible operators
      0x2066...0x206F,  // bidi isolates + deprecated format controls
      0xFEFF:  // zero-width no-break space / BOM
      return false
    default:
      return true
    }
  }

  /// A safe `<a href>` value or nil. The raw attribute value (optionally quoted)
  /// is entity-decoded first — so `&#106;avascript:` cannot slip through — then
  /// allowed only for http/https/mailto or a scheme-less relative reference; any
  /// other scheme (javascript:, data:, file:, vbscript:, blob:, about:) or a
  /// control character is rejected, leaving the whole tag literal.
  private static func sanitizedHTMLHref(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespaces)
    if value.count >= 2, let first = value.first, first == "\"" || first == "'",
      value.last == first
    {
      value = String(value.dropFirst().dropLast())
    }
    value = decodeHTMLEntities(in: value).trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty, !value.unicodeScalars.contains(where: { !isSafeHTMLScalar($0) })
    else {
      return nil
    }
    guard let schemeEnd = value.firstIndex(of: ":") else {
      return value  // no scheme: a relative reference, safe (inert in Phase 1)
    }
    // A "scheme" containing / or # before the colon is really a path (e.g. a/b:c).
    let scheme = value[value.startIndex..<schemeEnd]
    if scheme.contains("/") || scheme.contains("#") || scheme.contains("?") { return value }
    return ["http", "https", "mailto"].contains(scheme.lowercased()) ? value : nil
  }

  /// Decodes named + numeric HTML entities in a small string (used to harden the
  /// href scheme check); leaves unknown entities literal.
  private static func decodeHTMLEntities(in text: String) -> String {
    let nsText = text as NSString
    let full = NSRange(location: 0, length: nsText.length)
    var result = text
    for match in htmlEntityNamedExpression.matches(in: text, range: full).reversed() {
      if let literal = htmlNamedEntityLiteral(forMatch: nsText.substring(with: match.range)) {
        result = (result as NSString).replacingCharacters(in: match.range, with: literal)
      }
    }
    let nsResult = result as NSString
    for match in htmlEntityNumericExpression.matches(
      in: result, range: NSRange(location: 0, length: nsResult.length)
    ).reversed() {
      if let literal = htmlNumericEntityLiteral(forMatch: nsResult.substring(with: match.range)) {
        result = (result as NSString).replacingCharacters(in: match.range, with: literal)
      }
    }
    return result
  }

  /// Whether an `<a …>` match carries a safe href. The href is read with the
  /// quote-aware tag scanner over the whole match (the scanner stops at the
  /// opening tag's `>`), so an `href=` appearing inside another attribute's
  /// quoted value is never mistaken for the real href.
  private static func htmlLinkHasSafeHref(_ match: NSTextCheckingResult, _ text: NSString) -> Bool {
    guard let href = htmlTagAttribute("href", in: text.substring(with: match.range)) else {
      return false
    }
    return sanitizedHTMLHref(href) != nil
  }

  /// The caption an `<img>` tag collapses to in the inline pass: its alt text
  /// (possibly empty) when the tag is well-formed and carries a usable, safe
  /// src — otherwise nil so a srcless, unsafe, or malformed `<img>` stays
  /// literal rather than vanishing. Used as the `decode` closure for both inline
  /// passes, so they stay byte-identical.
  private static func htmlImageAltLiteral(forMatch match: String) -> String? {
    guard htmlTagHasBalancedQuotes(match), htmlImageSource(in: match) != nil else { return nil }
    return htmlImageAlt(in: match) ?? ""
  }

  /// The safe, resolved source of an `<img>` tag, or nil. The src attribute is
  /// read with the quote-aware scanner, entity-decoded, then limited to https
  /// remotes or scheme-less local paths — every explicit scheme except https is
  /// rejected.
  private static func htmlImageSource(in tag: String) -> String? {
    guard let raw = htmlTagAttribute("src", in: tag) else { return nil }
    return sanitizedHTMLImageSource(raw)
  }

  /// The unquoted, entity-decoded alt attribute of an `<img>` tag, or nil.
  private static func htmlImageAlt(in tag: String) -> String? {
    guard let raw = htmlTagAttribute("alt", in: tag) else { return nil }
    let decoded = decodeHTMLEntities(in: raw).trimmingCharacters(in: .whitespaces)
    return decoded.isEmpty ? nil : decoded
  }

  /// The raw (still entity-encoded) value of the first `name` attribute
  /// (case-insensitive) in a single HTML tag, honoring quoted spans — so an
  /// attribute keyword appearing *inside* another attribute's quoted value
  /// (e.g. `src=` within `alt="… src=…"`) is never read as a real attribute.
  /// nil when the attribute is absent, valueless, or its quote is unterminated.
  /// Callers decode and validate. Linear in the tag length.
  private static func htmlTagAttribute(_ name: String, in tag: String) -> String? {
    let scalars = Array(tag.unicodeScalars)
    let count = scalars.count
    func isSpace(_ index: Int) -> Bool {
      scalars[index] == " " || scalars[index] == "\t"
    }
    var index = 0
    // Skip the leading "<" and the tag name.
    guard index < count, scalars[index] == "<" else { return nil }
    index += 1
    while index < count, !isSpace(index), scalars[index] != ">", scalars[index] != "/" {
      index += 1
    }
    while index < count {
      while index < count, isSpace(index) || scalars[index] == "/" { index += 1 }
      guard index < count, scalars[index] != ">" else { break }
      let nameStart = index
      while index < count, !isSpace(index), scalars[index] != "=", scalars[index] != ">",
        scalars[index] != "/"
      {
        index += 1
      }
      let attributeName = String(String.UnicodeScalarView(scalars[nameStart..<index]))
      var cursor = index
      while cursor < count, isSpace(cursor) { cursor += 1 }
      var value: String?
      if cursor < count, scalars[cursor] == "=" {
        index = cursor + 1
        while index < count, isSpace(index) { index += 1 }
        if index < count, scalars[index] == "\"" || scalars[index] == "'" {
          let quote = scalars[index]
          index += 1
          let valueStart = index
          while index < count, scalars[index] != quote { index += 1 }
          if index < count {  // closing quote found
            value = String(String.UnicodeScalarView(scalars[valueStart..<index]))
            index += 1
          } else {
            value = nil  // unterminated quote: malformed, treat as no value
          }
        } else {
          let valueStart = index
          while index < count, !isSpace(index), scalars[index] != ">" { index += 1 }
          value = String(String.UnicodeScalarView(scalars[valueStart..<index]))
        }
      }
      if attributeName.lowercased() == name, let value { return value }
    }
    return nil
  }

  /// Whether a single HTML tag's quotes are balanced — i.e. the closing `>` is
  /// not inside a quoted attribute value. The tag regexes match a single
  /// `[^<>\n]*` run, so a `>` inside a quoted value truncates the match and
  /// leaves an unbalanced quote; such a malformed tag stays literal.
  private static func htmlTagHasBalancedQuotes(_ tag: String) -> Bool {
    var insideSingle = false
    var insideDouble = false
    for scalar in tag.unicodeScalars {
      if scalar == "\"", !insideSingle {
        insideDouble.toggle()
      } else if scalar == "'", !insideDouble {
        insideSingle.toggle()
      }
    }
    return !insideSingle && !insideDouble
  }

  /// A safe image source: a scheme-less relative/absolute local path, or an
  /// https URL. The value is entity-decoded first (so `&amp;` in a URL and
  /// `&#106;avascript` obfuscation are normalised), then every explicit scheme
  /// except https (javascript:, data:, file:, vbscript:, blob:, about:, http:)
  /// is rejected, and a control/format scalar leaves the tag literal. The image
  /// store performs the actual resolution and only fetches https remotely.
  private static func sanitizedHTMLImageSource(_ raw: String) -> String? {
    let value = decodeHTMLEntities(in: raw).trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty, !value.unicodeScalars.contains(where: { !isSafeHTMLScalar($0) })
    else {
      return nil
    }
    guard let schemeEnd = value.firstIndex(of: ":") else {
      return value  // no scheme: a relative or absolute local path
    }
    let scheme = value[value.startIndex..<schemeEnd]
    if scheme.contains("/") || scheme.contains("#") || scheme.contains("?") { return value }
    return scheme.lowercased() == "https" ? value : nil
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
    if markdownLineIsHorizontalRule(body) { return false }
    return true
  }

  private static func markdownThematicBreak(in line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 3 else { return false }
    let scalars = Set(trimmed)
    return scalars.count == 1 && ["-", "*", "_"].contains(scalars.first ?? " ")
  }

  /// Whether the whole (trimmed) line is a single HTML `<hr>` tag.
  private static func markdownHTMLHorizontalRule(in line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let ns = trimmed as NSString
    let range = NSRange(location: 0, length: ns.length)
    guard let match = htmlHorizontalRuleExpression.firstMatch(in: trimmed, range: range) else {
      return false
    }
    return match.range == range
  }

  /// Whether a line renders as a horizontal rule — a markdown thematic break
  /// (`---`/`***`/`___`) or a whole-line HTML `<hr>`. Shared with the text view
  /// so the highlighter and the renderer draw the rule on exactly the same lines.
  static func markdownLineIsHorizontalRule(_ line: String) -> Bool {
    markdownThematicBreak(in: line) || markdownHTMLHorizontalRule(in: line)
  }

  private static func isBulletMarker(_ value: unichar) -> Bool {
    value == 45 || value == 42 || value == 43  // "-", "*", "+"
  }

  private static let inlineCodeExpression = markdownRegex(#"`([^`\n]+)`"#)
  private static let linkExpression = markdownRegex(#"(?<!!)\[([^\]\n]+)\]\((https?://[^\)\n]+)\)"#)
  private static let renderedLinkExpression = markdownRegex(#"(?<!!)\[([^\]\n]+)\]\(([^\)\n]+)\)"#)
  private static let referenceLinkExpression = markdownRegex(#"(?<!!)\[([^\]\n]+)\]\[([^\]\n]*)\]"#)
  private static let referenceDefinitionExpression = markdownRegex(#"^\s{0,3}\[[^\]\n]+\]:\s+\S+"#)
  private static let referenceDefinitionPartsExpression = markdownRegex(
    #"^\s{0,3}\[([^\]\n]+)\]:\s+(.+?)\s*$"#)
  private static let autolinkExpression = markdownRegex(#"<(https?://[^>\s]+)>"#)
  private static let escapeExpression = markdownRegex(#"\\([\\`*_{}\[\]()#+\-.!>~|])"#)
  private static let imageExpression = markdownRegex(#"!\[([^\]\n]*)\]\(([^\)\n]+)\)"#)
  private static let referenceImageExpression = markdownRegex(#"!\[([^\]\n]*)\]\[([^\]\n]*)\]"#)
  private static let linkedImageExpression = markdownRegex(
    #"^\[!\[([^\]\n]*)\]\(([^\)\n]+)\)\]\(([^\)\n]+)\)$"#)
  private static let linkedReferenceImageExpression = markdownRegex(
    #"^\[!\[([^\]\n]*)\]\[([^\]\n]*)\]\]\(([^\)\n]+)\)$"#)
  private static let imageTitleExpression = markdownRegex(#"^(.+?)\s+("[^"]*"|'[^']*')$"#)
  private static let boldItalicExpression = markdownRegex(
    #"(?<![\\*])\*\*\*([^\*\n]+)(?<!\\)\*\*\*(?!\*)"#)
  private static let boldExpression = markdownRegex(#"(?<![\\*])\*\*([^\*\n]+)(?<!\\)\*\*(?!\*)"#)
  private static let italicExpression = markdownRegex(#"(?<![\\*])\*([^\*\n]+)(?<!\\)\*(?!\*)"#)
  private static let strikeExpression = markdownRegex(#"(?<![\\~])~~([^~\n]+)(?<!\\)~~(?!~)"#)

  // Inline HTML. Each paired tag keeps group 1 (inner text); the content class
  // forbids `<` and newline so a single rule matches only the innermost,
  // single-line, properly-closed tag — anything malformed degrades to literal.
  private static let htmlEntityNamedExpression = markdownRegex(#"&([a-zA-Z][a-zA-Z0-9]{1,31});"#)
  private static let htmlEntityNumericExpression = markdownRegex(
    #"&#(?:[0-9]{1,7}|[xX][0-9A-Fa-f]{1,6});"#)
  private static let htmlBoldExpression = markdownRegex(
    #"(?i)<(?:b|strong)>([^<\n]*)</(?:b|strong)>"#)
  private static let htmlItalicExpression = markdownRegex(
    #"(?i)<(?:i|em|cite)>([^<\n]*)</(?:i|em|cite)>"#)
  private static let htmlStrikeExpression = markdownRegex(
    #"(?i)<(?:s|strike|del)>([^<\n]*)</(?:s|strike|del)>"#)
  private static let htmlCodeExpression = markdownRegex(#"(?i)<code>([^<\n]*)</code>"#)
  private static let htmlKbdExpression = markdownRegex(#"(?i)<kbd>([^<\n]*)</kbd>"#)
  private static let htmlMarkExpression = markdownRegex(#"(?i)<mark>([^<\n]*)</mark>"#)
  private static let htmlUnderlineExpression = markdownRegex(
    #"(?i)<(?:u|ins)>([^<\n]*)</(?:u|ins)>"#)
  private static let htmlSmallExpression = markdownRegex(#"(?i)<small>([^<\n]*)</small>"#)
  // Group 1 = the attribute span, group 2 = link text. A single greedy
  // attribute run terminated by `>` (no overlapping lazy+greedy pair), so an
  // unterminated `<a ` line fails in linear time instead of backtracking. The
  // href is read from the matched tag by the quote-aware scanner.
  private static let htmlLinkExpression = markdownRegex(
    #"(?i)<a(\s[^<>\n]*)>([^<\n]*)</a>"#)
  private static let htmlLineBreakExpression = markdownRegex(#"(?i)<br\s*/?>"#)
  // Single-line block HTML. `<img>` maps to the image-block renderer (its src is
  // resolved like a markdown image; its alt becomes the caption), and a
  // whole-line `<hr>` maps to the thematic-break rule. The `\b` after the name
  // rejects `<image>`/`<header>`, and `[^<>\n]*` is a single greedy run
  // terminated by `>`, so a malformed/unterminated tag fails in linear time.
  // Attribute values are read from the matched tag by the quote-aware scanner
  // (htmlTagAttribute), not a regex, so a keyword inside another attribute's
  // quoted value is never mistaken for a real attribute.
  private static let htmlImageExpression = markdownRegex(#"(?i)<img\b[^<>\n]*>"#)
  private static let htmlHorizontalRuleExpression = markdownRegex(#"(?i)<hr\b[^<>\n]*>"#)
  /// The paired formatting tags whose display-map removal is identical (keep
  /// group 1); kept in one list so both inline passes use the same order.
  private static let htmlPairedInlineExpressions: [NSRegularExpression] = [
    htmlBoldExpression, htmlItalicExpression, htmlStrikeExpression, htmlCodeExpression,
    htmlKbdExpression, htmlMarkExpression, htmlUnderlineExpression, htmlSmallExpression,
  ]
  /// Upper bound on paired-tag fixpoint passes (one per level of tag nesting);
  /// realistic nesting is one or two deep, and a line with no tags exits after
  /// a single no-op pass.
  private static let htmlMaxNestingPasses = 4

  /// Common, safe-to-render named HTML entities (keyed without the `&`/`;`).
  /// Pure text — no executable meaning. Unknown names are left literal.
  private static let htmlNamedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
    "copy": "©", "reg": "®", "trade": "™", "mdash": "—", "ndash": "–", "hellip": "…",
    "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
    "times": "×", "divide": "÷", "deg": "°", "plusmn": "±", "micro": "µ", "para": "¶",
    "sect": "§", "middot": "·", "bull": "•", "dagger": "†", "Dagger": "‡", "permil": "‰",
    "prime": "′", "Prime": "″", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
    "curren": "¤", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
    "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "equiv": "≡",
    "sum": "∑", "prod": "∏", "radic": "√", "part": "∂", "nabla": "∇", "int": "∫",
    "frac12": "½", "frac14": "¼", "frac34": "¾", "sup1": "¹", "sup2": "²", "sup3": "³",
    "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
    "check": "✓", "cross": "✗", "star": "★",
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ",
    "lambda": "λ", "mu": "μ", "pi": "π", "sigma": "σ", "phi": "φ", "omega": "ω",
    "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
    "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Omega": "Ω",
    "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å",
    "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë", "iacute": "í",
    "ntilde": "ñ", "ograve": "ò", "oacute": "ó", "ocirc": "ô", "ouml": "ö", "uacute": "ú",
    "uuml": "ü", "szlig": "ß", "Aacute": "Á", "Eacute": "É", "Uuml": "Ü", "Ouml": "Ö",
    "Auml": "Ä",
  ]

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
