import AppKit
import Foundation

enum TextDocumentSyntax: Equatable {
  case markdown
  case structuredText
  case code
  case plainText

  var font: NSFont {
    switch self {
    case .markdown, .plainText:
      return .systemFont(ofSize: 14)
    case .structuredText, .code:
      return .monospacedSystemFont(ofSize: 13, weight: .regular)
    }
  }

  /// Whether the text viewer shows a line-number gutter for this syntax. Every
  /// text kind currently does.
  var supportsLineNumbers: Bool {
    switch self {
    case .markdown, .plainText, .structuredText, .code:
      return true
    }
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
    applyRules: Bool = true
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
      highlightMarkdown(text, in: textStorage, range: highlightedRange)
    case .structuredText:
      highlightStructuredText(text, in: textStorage, range: highlightedRange)
    case .code:
      highlightCode(text, in: textStorage, range: highlightedRange)
    case .plainText:
      break
    }
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

  private static func highlightMarkdown(
    _ text: String, in textStorage: NSMutableAttributedString, range: NSRange
  ) {
    apply(rule: .markdownHeading, text: text, textStorage: textStorage, range: range)
    apply(rule: .markdownInlineCode, text: text, textStorage: textStorage, range: range)
    apply(rule: .markdownLink, text: text, textStorage: textStorage, range: range)
    apply(rule: .markdownListMarker, text: text, textStorage: textStorage, range: range)
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
