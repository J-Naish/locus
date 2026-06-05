import AppKit
import SwiftUI

/// Pure geometry for a uniform-line-height virtualized text view: it maps
/// between scroll offsets and line indices so only the visible band is drawn.
/// Kept free of AppKit state so it is unit-testable without a window.
struct TextViewportLayout: Equatable {
  /// Height of one line in points. Must be positive.
  let lineHeight: CGFloat

  /// Total document height for `lineCount` lines. An empty buffer still has one
  /// (empty) line, so the height is never zero for a valid buffer.
  func contentHeight(lineCount: Int) -> CGFloat {
    CGFloat(max(lineCount, 1)) * lineHeight
  }

  /// The y offset of the top of `line`.
  func yOffset(forLine line: Int) -> CGFloat {
    CGFloat(line) * lineHeight
  }

  /// The half-open range of line indices that intersect `rect`, clamped to
  /// `[0, lineCount)`. Returns an empty range when nothing is visible.
  func visibleLineRange(in rect: CGRect, lineCount: Int) -> Range<Int> {
    guard lineCount > 0, lineHeight > 0, rect.height > 0 else {
      return 0..<0
    }
    let first = max(0, Int((rect.minY / lineHeight).rounded(.down)))
    let last = min(lineCount, Int((rect.maxY / lineHeight).rounded(.up)))
    guard first < last else {
      return 0..<0
    }
    return first..<last
  }
}

/// Custom flipped `NSView` that draws only the visible band of a
/// [`TextBuffer`], fetching that band from the Rust core on demand. The
/// document height is synthesized from the line count, so a multi-gigabyte file
/// never has its text assembled in memory — scrolling redraws exposed bands.
final class LineRenderingTextView: NSView {
  private(set) var buffer: TextBuffer?
  private let font: NSFont
  private let lineNumberFont: NSFont
  private let layout: TextViewportLayout
  private let horizontalPadding: CGFloat = 8
  private let backgroundColor: NSColor = .textBackgroundColor
  private let lineNumberColor: NSColor = .secondaryLabelColor
  private let gutterSeparatorColor: NSColor = .separatorColor
  /// The document's syntax. It drives both line-number visibility (via the
  /// syntax's own support policy) and per-band highlighting. Unlike the editable
  /// path there is no large-document cutoff: the editor stops at ~200K
  /// characters only because it styles/indexes the whole string, whereas this
  /// view works one visible band at a time.
  var syntax: TextDocumentSyntax = .plainText {
    didSet {
      guard syntax != oldValue else { return }
      cachedBand = nil
      recomputeGutterWidth()
      needsDisplay = true
    }
  }
  /// Width of the line-number gutter, recomputed when the buffer or `syntax`
  /// changes. The gutter scrolls vertically with its lines (it is drawn in the
  /// document view's left margin) and stays at the left edge because the view
  /// does not scroll horizontally yet.
  private var gutterWidth: CGFloat = 0

  // Gutter geometry, kept local so the viewer does not depend on the editor's
  // line-number helper.
  private static let gutterLeadingPadding: CGFloat = 6
  private static let gutterTrailingPadding: CGFloat = 10
  private static let minimumGutterWidth: CGFloat = 42
  /// Upper bound on the bytes the core returns for any one line. Caps the FFI
  /// fetch so a file that is one enormous line never crosses the boundary in
  /// full; comfortably larger than anything the view can show.
  private let maximumFetchedBytesPerLine = 16_384
  /// Without horizontal scrolling, only the start of a line is ever visible, so
  /// a long line is also truncated before layout to bound highlighting/drawing.
  private let maximumDrawnCharactersPerLine = 5_000
  /// One-entry cache of the last band's highlighted lines so repeated draws of
  /// the same range (overlapping dirty rects, redraws without scrolling) skip
  /// both the FFI fetch and the regex highlighting. Keyed by revision so any
  /// future edit invalidates it.
  private var cachedBand: (revision: UInt64, range: Range<Int>, lines: [NSAttributedString])?

  init() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    self.font = font
    self.lineNumberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    self.layout = TextViewportLayout(
      lineHeight: ceil(font.ascender - font.descender + font.leading))
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  // Flipped so line 0 sits at the top and y grows downward, matching the
  // line-index math in `TextViewportLayout`.
  override var isFlipped: Bool { true }

  // Each draw fills its dirty rect with the background, so the view is opaque;
  // declaring it lets AppKit use responsive (banded) scrolling.
  override var isOpaque: Bool { true }

  func setBuffer(_ buffer: TextBuffer?) {
    self.buffer = buffer
    cachedBand = nil
    recomputeGutterWidth()
    updateHeight()
    scroll(.zero)
    needsDisplay = true
  }

  private func recomputeGutterWidth() {
    guard syntax.supportsLineNumbers, let buffer else {
      gutterWidth = 0
      return
    }
    gutterWidth = Self.gutterWidth(lineCount: buffer.lineCount, font: lineNumberFont)
  }

  private static func gutterWidth(lineCount: Int, font: NSFont) -> CGFloat {
    let digitCount = max(2, String(max(1, lineCount)).count)
    let sample = String(repeating: "8", count: digitCount) as NSString
    let digitWidth = sample.size(withAttributes: [.font: font]).width
    return ceil(max(minimumGutterWidth, gutterLeadingPadding + digitWidth + gutterTrailingPadding))
  }

  /// Returns the visible band's lines, already highlighted, reusing the cache
  /// when the same `(revision, range)` is requested again.
  private func attributedBandLines(for buffer: TextBuffer, range: Range<Int>)
    -> [NSAttributedString]
  {
    let revision = buffer.revision
    if let cachedBand, cachedBand.revision == revision, cachedBand.range == range {
      return cachedBand.lines
    }
    // Fetch + highlight runs synchronously on each new band. The work is bounded
    // by the visible band (a screenful of lines) and the per-line cap, so it is
    // small for normal text; on-device profiling is the acceptance gate, and the
    // fallbacks if it ever hitches are base-only styling or async highlighting.
    //
    // The capped read bounds each line so even a one-enormous-line file never
    // crosses the FFI in full. The result joins lines with "\n" (terminators
    // stripped), so splitting on "\n" recovers exactly `range.count` lines.
    let lines = buffer.text(
      forLineRange: range.lowerBound, count: range.count,
      maxBytesPerLine: maximumFetchedBytesPerLine
    )
    .components(separatedBy: "\n")
    .map(highlightedLine)
    cachedBand = (revision, range, lines)
    return lines
  }

  /// Builds a highlighted, draw-ready line: only the start is laid out (no
  /// horizontal scrolling yet), syntax rules supply colors, and the font is
  /// forced uniform afterwards so a styled token cannot change the line height.
  ///
  /// The core already capped the fetched bytes; this char cap is a second bound
  /// on layout/highlighting/drawing, since the fetched line can still be wider
  /// than the viewport.
  private func highlightedLine(_ line: String) -> NSAttributedString {
    let visible =
      line.count > maximumDrawnCharactersPerLine
      ? String(line.prefix(maximumDrawnCharactersPerLine))
      : line
    let attributed = NSMutableAttributedString(string: visible)
    let fullRange = NSRange(location: 0, length: (visible as NSString).length)
    TextDocumentSyntaxHighlighter.apply(
      to: attributed, text: visible, syntax: syntax, font: font, range: fullRange)
    attributed.addAttribute(.font, value: font, range: fullRange)
    return attributed
  }

  /// Resizes the document height to the current line count. Width is left to the
  /// `.width` autoresizing mask so the view fills the scroll view horizontally;
  /// long lines are clipped for now (horizontal scrolling is a later slice).
  func updateHeight() {
    let lineCount = buffer?.lineCount ?? 1
    let width = max(frame.width, enclosingScrollView?.contentView.bounds.width ?? 0)
    setFrameSize(NSSize(width: width, height: layout.contentHeight(lineCount: lineCount)))
  }

  override func draw(_ dirtyRect: NSRect) {
    backgroundColor.setFill()
    dirtyRect.fill()

    guard let buffer else {
      return
    }
    let lineCount = buffer.lineCount
    let range = layout.visibleLineRange(in: dirtyRect, lineCount: lineCount)
    guard !range.isEmpty else {
      return
    }

    // Hairline separating the gutter from the text, across the dirty band only.
    if gutterWidth > 0 {
      gutterSeparatorColor.setStroke()
      let separator = NSBezierPath()
      separator.move(to: NSPoint(x: gutterWidth, y: dirtyRect.minY))
      separator.line(to: NSPoint(x: gutterWidth, y: dirtyRect.maxY))
      separator.lineWidth = 1
      separator.stroke()
    }

    let lines = attributedBandLines(for: buffer, range: range)
    let textOriginX = gutterWidth + horizontalPadding
    let textWidth = max(bounds.width - textOriginX - horizontalPadding, 0)
    let numberAttributes: [NSAttributedString.Key: Any] = [
      .font: lineNumberFont,
      .foregroundColor: lineNumberColor,
    ]
    for (offset, attributedLine) in lines.enumerated() {
      let lineIndex = range.lowerBound + offset
      let y = layout.yOffset(forLine: lineIndex)

      // Right-aligned 1-based line number in the gutter.
      if gutterWidth > 0 {
        let number = NSAttributedString(string: "\(lineIndex + 1)", attributes: numberAttributes)
        let numberWidth = number.size().width
        number.draw(
          with: NSRect(
            x: max(0, gutterWidth - Self.gutterTrailingPadding - numberWidth),
            y: y,
            width: numberWidth,
            height: layout.lineHeight
          ),
          options: [.usesLineFragmentOrigin]
        )
      }

      // The line is already highlighted and capped; `.usesLineFragmentOrigin`
      // makes the rect origin its top-left, which is what we want when flipped.
      attributedLine.draw(
        with: NSRect(x: textOriginX, y: y, width: textWidth, height: layout.lineHeight),
        options: [.usesLineFragmentOrigin]
      )
    }
  }
}

/// Hosts [`LineRenderingTextView`] in an `NSScrollView` for SwiftUI.
struct LargeTextViewport: NSViewRepresentable {
  let buffer: TextBuffer
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor

    let documentView = LineRenderingTextView()
    documentView.translatesAutoresizingMaskIntoConstraints = true
    // Track the clip view's width; height is driven by the line count.
    documentView.autoresizingMask = [.width]
    documentView.setAccessibilityIdentifier("document-large-text-viewer")
    documentView.setAccessibilityLabel(accessibilityLabel)

    scrollView.documentView = documentView
    documentView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: 0))
    // Set before the buffer so the gutter width is computed on the first layout.
    documentView.syntax = syntax
    documentView.setBuffer(buffer)

    context.coordinator.documentView = documentView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let documentView = context.coordinator.documentView else {
      return
    }
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    // A new buffer (e.g. after an external-change reload) replaces the content.
    if documentView.buffer !== buffer {
      documentView.setBuffer(buffer)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class Coordinator {
    var documentView: LineRenderingTextView?
  }
}

/// Read-only viewer for text files too large for the editable string path. It
/// opens the file through the Rust [`TextBuffer`] off the main thread, then
/// renders it with [`LargeTextViewport`].
struct VirtualizedTextDocumentView: View {
  let url: URL
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax
  /// Changing this (e.g. on external file change) re-opens the buffer.
  let reloadToken: Int

  @State private var phase: Phase = .loading

  private enum Phase {
    case loading
    case loaded(TextBuffer)
    case failed(String)
  }

  var body: some View {
    Group {
      switch phase {
      case .loading:
        // Matches the editable surface: no spinner, just a blank canvas until
        // the buffer finishes opening off the main thread.
        Color(nsColor: .textBackgroundColor)
      case .loaded(let buffer):
        LargeTextViewport(
          buffer: buffer,
          accessibilityLabel: accessibilityLabel,
          syntax: syntax
        )
      case .failed(let message):
        ContentUnavailableView {
          Label("Document Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: TextViewportLoad(url: url, token: reloadToken)) {
      await open()
    }
  }

  private func open() async {
    phase = .loading
    let target = url
    do {
      let loaded = try await Task.detached(priority: .userInitiated) {
        // Balance security-scoped access like `TextDocumentStore`, keeping the
        // path ready for bookmark-backed access; the buffer holds its own
        // reference to the file once opened.
        let didStartAccess = target.startAccessingSecurityScopedResource()
        defer {
          if didStartAccess {
            target.stopAccessingSecurityScopedResource()
          }
        }
        return OpenedTextBuffer(buffer: try TextBuffer.open(at: target))
      }.value
      // The detached open is not itself cancellable, so a slow open for a file
      // the user already navigated away from can still finish. Drop the result
      // rather than clobber the newer document.
      guard !Task.isCancelled else {
        return
      }
      phase = .loaded(loaded.buffer)
    } catch {
      guard !Task.isCancelled else {
        return
      }
      phase = .failed(Self.failureMessage(for: error))
    }
  }

  /// Maps an open failure to a user-facing message. Large non-UTF-8 files are
  /// called out explicitly: the editable path decodes legacy encodings, but
  /// this large-file viewer is UTF-8 only for now, so the narrowing is not
  /// silent.
  static func failureMessage(for error: Error) -> String {
    if let bufferError = error as? TextBufferError, bufferError == .notUTF8 {
      return
        "This file is too large to open as non-UTF-8 text. Large files currently open only in UTF-8."
    }
    return error.localizedDescription
  }
}

/// Identity for the load `task`: re-open when either the file or the reload
/// token changes.
private struct TextViewportLoad: Equatable {
  let url: URL
  let token: Int
}

/// Carries the non-`Sendable` `TextBuffer` from the loader task to the main
/// actor. It is only handed across once and then used exclusively on the main
/// actor, so the unchecked conformance is sound (mirrors `ImageDocument`).
private struct OpenedTextBuffer: @unchecked Sendable {
  let buffer: TextBuffer
}
