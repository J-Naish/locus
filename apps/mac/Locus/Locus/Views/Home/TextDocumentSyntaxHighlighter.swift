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
  static let checkboxSize: CGFloat = 14
  static let codeBlockCornerRadius: CGFloat = 8
  static let inlineCodeCornerRadius: CGFloat = 4

  static func headingFont(level: Int) -> NSFont {
    switch level {
    case 1:
      return .systemFont(ofSize: 20, weight: .bold)
    case 2:
      return .systemFont(ofSize: 18, weight: .bold)
    case 3:
      return .systemFont(ofSize: 16, weight: .semibold)
    case 4:
      return .systemFont(ofSize: 15, weight: .semibold)
    case 5:
      return .systemFont(ofSize: 14, weight: .semibold)
    default:
      return .systemFont(ofSize: 13, weight: .semibold)
    }
  }

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
}

struct MarkdownLineStyleState: Equatable, Sendable {
  var insideFence = false
  var setextHeadingLevel: Int?
  var isSetextUnderline = false
  var insideFrontMatter = false

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
    func fontSet(base: NSFont, boldWeight: NSFont.Weight = .bold) -> MarkdownFontSet {
      let bold = NSFont.systemFont(ofSize: base.pointSize, weight: boldWeight)
      let italic = manager.convert(base, toHaveTrait: .italicFontMask)
      return MarkdownFontSet(
        regular: base,
        bold: bold,
        italic: italic,
        boldItalic: manager.convert(bold, toHaveTrait: .italicFontMask)
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

struct MarkdownRevealContext: Equatable, Sendable {
  var activeColumnUTF16: Int?

  static let hidden = MarkdownRevealContext(activeColumnUTF16: nil)

  var revealsLineMarkers: Bool {
    activeColumnUTF16 != nil
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
    markdownTypography: MarkdownTypography? = nil,
    markdownRevealContext: MarkdownRevealContext = .hidden
  ) -> NSAttributedString {
    let visible = line
    let attributed = NSMutableAttributedString(string: visible)
    let fullRange = NSRange(location: 0, length: (visible as NSString).length)
    if syntax == .markdown, applyRules,
      fullRange.length <= maximumHighlightedUTF16Length
    {
      attributed.setAttributes(baseAttributes(font: font), range: fullRange)
      styleMarkdownLine(
        visible,
        lineRange: fullRange,
        in: attributed,
        state: markdownLineState,
        typography: markdownTypography ?? MarkdownTypography(baseFont: font),
        includeVisualAttributes: true,
        revealContext: markdownRevealContext
      )
    } else {
      apply(
        to: attributed, text: visible, syntax: syntax, font: font, range: fullRange,
        applyRules: applyRules)
    }
    return attributed
  }

  static func markdownMeasurementLine(
    _ line: String,
    font: NSFont,
    state: MarkdownLineStyleState,
    typography: MarkdownTypography
  ) -> NSAttributedString {
    let attributed = NSMutableAttributedString(string: line)
    let fullRange = NSRange(location: 0, length: (line as NSString).length)
    guard fullRange.length > 0 else {
      return attributed
    }
    attributed.setAttributes([.font: font], range: fullRange)
    styleMarkdownLine(
      line,
      lineRange: fullRange,
      in: attributed,
      state: state,
      typography: typography,
      includeVisualAttributes: false,
      revealContext: .hidden)
    return attributed
  }

  static func isMarkdownFenceLine(_ line: String) -> Bool {
    markdownFenceInfo(in: line) != nil
  }

  static func markdownLineStates(for lines: [String]) -> [MarkdownLineStyleState] {
    var states = Array(repeating: MarkdownLineStyleState.plain, count: lines.count)
    guard !lines.isEmpty else { return states }

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

    var insideFence = false
    for index in lines.indices {
      guard !states[index].insideFrontMatter else { continue }
      states[index].insideFence = insideFence
      if isMarkdownFenceLine(lines[index]) {
        insideFence.toggle()
      }
    }

    for index in lines.indices.dropFirst() {
      guard !states[index].insideFence, !states[index].insideFrontMatter,
        !states[index - 1].insideFence, !states[index - 1].insideFrontMatter,
        let level = markdownSetextHeadingLevel(in: lines[index]),
        markdownCanBecomeSetextHeading(lines[index - 1], state: states[index - 1])
      else {
        continue
      }
      states[index - 1].setextHeadingLevel = level
      states[index].isSetextUnderline = true
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
          includeVisualAttributes: includeVisualAttributes,
          revealContext: .hidden
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
    includeVisualAttributes: Bool,
    revealContext: MarkdownRevealContext
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

    if let fence = markdownFenceInfo(in: line) {
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
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
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
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
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
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
    } else if let prefixLength = markdownBlockPrefixLength(in: line) {
      lineFonts = typography.body
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location, length: prefixLength),
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
    } else if markdownThematicBreak(in: line) {
      lineFonts = typography.body
      muteMarkdownSyntax(
        range: lineRange,
        in: textStorage,
        font: typography.body.regular,
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
    } else {
      lineFonts = typography.body
    }

    highlightMarkdownInline(
      in: line,
      lineRange: lineRange,
      textStorage: textStorage,
      lineFonts: lineFonts,
      typography: typography,
      includeVisualAttributes: includeVisualAttributes,
      revealContext: revealContext)
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
    includeVisualAttributes: Bool,
    revealContext: MarkdownRevealContext
  ) {
    var protectedRanges = applyInlineCode(
      in: line,
      lineRange: lineRange,
      textStorage: textStorage,
      typography: typography,
      includeVisualAttributes: includeVisualAttributes,
      revealContext: revealContext)
    protectedRanges += applyLinks(
      in: line,
      lineRange: lineRange,
      textStorage: textStorage,
      lineFonts: lineFonts,
      includeVisualAttributes: includeVisualAttributes,
      revealContext: revealContext)
    applyDelimitedSpan(
      expression: boldItalicExpression,
      markerLength: 3,
      style: .boldItalic,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes,
      revealContext: revealContext)
    applyDelimitedSpan(
      expression: boldExpression,
      markerLength: 2,
      style: .bold,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes,
      revealContext: revealContext)
    applyDelimitedSpan(
      expression: italicExpression,
      markerLength: 1,
      style: .italic,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes,
      revealContext: revealContext)
    applyDelimitedSpan(
      expression: strikeExpression,
      markerLength: 2,
      style: .strike,
      protectedRanges: protectedRanges,
      in: line,
      lineRange: lineRange,
      lineFonts: lineFonts,
      textStorage: textStorage,
      includeVisualAttributes: includeVisualAttributes,
      revealContext: revealContext)
  }

  private static func applyInlineCode(
    in line: String,
    lineRange: NSRange,
    textStorage: NSMutableAttributedString,
    typography: MarkdownTypography,
    includeVisualAttributes: Bool,
    revealContext: MarkdownRevealContext
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
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1, length: 1),
        in: textStorage,
        font: typography.inlineCode,
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
    }
    return protectedRanges
  }

  private static func applyLinks(
    in line: String,
    lineRange: NSRange,
    textStorage: NSMutableAttributedString,
    lineFonts: MarkdownFontSet,
    includeVisualAttributes: Bool,
    revealContext: MarkdownRevealContext
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
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
      muteMarkdownSyntax(
        range: NSRange(location: NSMaxRange(label), length: 2),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
      muteMarkdownSyntax(
        range: url,
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
      muteMarkdownSyntax(
        range: NSRange(location: lineRange.location + NSMaxRange(match.range) - 1, length: 1),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
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
    includeVisualAttributes: Bool,
    revealContext: MarkdownRevealContext
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
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
      muteMarkdownSyntax(
        range: NSRange(
          location: lineRange.location + NSMaxRange(match.range) - markerLength,
          length: markerLength),
        in: textStorage,
        font: lineFonts.regular,
        includeVisualAttributes: includeVisualAttributes,
        revealContext: revealContext)
    }
  }

  private static func muteMarkdownSyntax(
    range: NSRange,
    in textStorage: NSMutableAttributedString,
    font: NSFont,
    includeVisualAttributes: Bool,
    revealContext: MarkdownRevealContext
  ) {
    guard range.length > 0 else { return }
    var attributes: [NSAttributedString.Key: Any] = [.font: font]
    if includeVisualAttributes {
      attributes[.foregroundColor] =
        revealContext.revealsLineMarkers ? MarkdownDocumentMetrics.markerColor : NSColor.clear
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
    var level = 0
    while level < min(6, nsLine.length), nsLine.character(at: level) == 35 {  // "#"
      level += 1
    }
    guard level > 0, nsLine.length > level, nsLine.character(at: level) == 32 else {
      return nil
    }
    return (level, level + 1)
  }

  private static func markdownBlockPrefixLength(in line: String) -> Int? {
    let nsLine = line as NSString
    let length = nsLine.length
    var index = 0
    while index < length, nsLine.character(at: index) == 32 {
      index += 1
    }
    if index < length, nsLine.character(at: index) == 62 {  // ">"
      while index < length, nsLine.character(at: index) == 62 || nsLine.character(at: index) == 32 {
        index += 1
      }
      return index
    }
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
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return false }
    if markdownHeadingInfo(in: line) != nil { return false }
    if markdownBlockPrefixLength(in: line) != nil { return false }
    if markdownFenceInfo(in: line) != nil { return false }
    if markdownThematicBreak(in: line) { return false }
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
