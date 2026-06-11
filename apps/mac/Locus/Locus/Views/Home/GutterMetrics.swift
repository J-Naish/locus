import AppKit

// Tested in TextViewportLayoutTests.swift (there is no GutterMetricsTests.swift).
/// Shared line-number gutter geometry, used by both the editable text view and
/// the large-file viewer so their gutters render identically. Kept pure (no
/// view state) so it is unit-testable and neither view owns the other's layout.
enum GutterMetrics {
  /// Space before the line number.
  static let leadingPadding: CGFloat = 6
  /// Space after the line number (before the text/separator).
  static let trailingPadding: CGFloat = 10
  /// Floor on gutter width so single-digit files still have a comfortable gutter.
  static let minimumWidth: CGFloat = 42

  /// The font line numbers are drawn in (monospaced digits keep them aligned).
  static var lineNumberFont: NSFont {
    .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
  }

  /// Width needed to show `lineCount`'s widest digit count in `font`, with
  /// padding, never below `minimumWidth`.
  static func width(lineCount: Int, font: NSFont) -> CGFloat {
    let digitCount = max(2, String(max(1, lineCount)).count)
    let sample = String(repeating: "8", count: digitCount) as NSString
    let digitWidth = sample.size(withAttributes: [.font: font]).width
    return ceil(max(minimumWidth, leadingPadding + digitWidth + trailingPadding))
  }
}
