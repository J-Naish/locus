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
///
/// Lines are not wrapped; the view widens to the widest line it has drawn so
/// the scroll view can scroll horizontally. The line-number gutter is a
/// separate pinned view ([`LineNumberGutterView`]), so it is not part of this
/// view and does not scroll horizontally with the text.
final class LineRenderingTextView: NSView {
  private(set) var buffer: TextBuffer?
  /// Exposed so the pinned gutter can align numbers to the same lines.
  let layout: TextViewportLayout
  private let font: NSFont
  private let horizontalPadding: CGFloat = 8
  private let backgroundColor: NSColor = .textBackgroundColor

  /// The document's syntax: drives per-band highlighting. Unlike the editable
  /// path there is no large-document cutoff — this view works one visible band
  /// at a time, never styling the whole string.
  var syntax: TextDocumentSyntax = .plainText {
    didSet {
      guard syntax != oldValue else { return }
      cachedBand = nil
      needsDisplay = true
    }
  }

  /// Upper bound on the bytes the core returns for any one line. Caps the FFI
  /// fetch so a file that is one enormous line never crosses the boundary in
  /// full; comfortably larger than anything the view can show.
  private let maximumFetchedBytesPerLine = 16_384
  /// A long line is also truncated before layout to bound highlighting/drawing,
  /// since horizontal scrolling can still bring much of a line into view.
  private let maximumDrawnCharactersPerLine = 5_000
  /// One-entry cache of the last band's highlighted lines so repeated draws of
  /// the same range (overlapping dirty rects, redraws without scrolling) skip
  /// both the FFI fetch and the regex highlighting. Keyed by revision so any
  /// future edit invalidates it.
  private var cachedBand: (revision: UInt64, range: Range<Int>, lines: [NSAttributedString])?
  /// Widest line measured so far. The document grows to fit it (grow-only) so a
  /// wide line can be scrolled to horizontally without measuring every line.
  private var maxObservedLineWidth: CGFloat = 0
  /// Set while an async `updateLayout` is queued, so a run of draws that each
  /// widen the document coalesces into a single layout pass.
  private var pendingLayoutUpdate = false

  var lineCount: Int { buffer?.lineCount ?? 1 }

  init() {
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    self.font = font
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
    maxObservedLineWidth = 0
    updateLayout()
    scroll(.zero)
    needsDisplay = true
  }

  /// Resizes the document to fit the line count (height) and the widest line
  /// seen so far (width), but never narrower than the clip view.
  func updateLayout() {
    let clipWidth = enclosingScrollView?.contentView.bounds.width ?? frame.width
    let width = max(clipWidth, maxObservedLineWidth + horizontalPadding * 2)
    setFrameSize(NSSize(width: width, height: layout.contentHeight(lineCount: lineCount)))
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

  /// Builds a highlighted line: syntax rules supply colors, then the font is
  /// forced uniform so a styled token cannot change the fixed line height. The
  /// char cap bounds layout/highlighting/drawing on top of the core's byte cap.
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

  override func draw(_ dirtyRect: NSRect) {
    backgroundColor.setFill()
    dirtyRect.fill()

    guard let buffer else {
      return
    }
    let range = layout.visibleLineRange(in: dirtyRect, lineCount: buffer.lineCount)
    guard !range.isEmpty else {
      return
    }

    let lines = attributedBandLines(for: buffer, range: range)
    var widest = maxObservedLineWidth
    for (offset, attributedLine) in lines.enumerated() {
      let y = layout.yOffset(forLine: range.lowerBound + offset)
      let size = attributedLine.size()
      widest = max(widest, size.width)
      // The line is already highlighted and capped; `.usesLineFragmentOrigin`
      // makes the rect origin its top-left, which is what we want when flipped.
      attributedLine.draw(
        with: NSRect(x: horizontalPadding, y: y, width: size.width, height: layout.lineHeight),
        options: [.usesLineFragmentOrigin]
      )
    }
    // Grow the document (and thus the horizontal scroll range) if a wider line
    // appeared. Deferred so the frame is not mutated mid-draw, and coalesced so
    // a run of widening draws triggers a single layout pass.
    if widest > maxObservedLineWidth {
      maxObservedLineWidth = widest
      if !pendingLayoutUpdate {
        pendingLayoutUpdate = true
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.pendingLayoutUpdate = false
          self.updateLayout()
        }
      }
    }
  }
}

/// A pinned line-number gutter drawn beside (not inside) the scrolling text, so
/// it stays fixed during horizontal scrolling while tracking vertical scroll.
final class LineNumberGutterView: NSView {
  weak var textView: LineRenderingTextView?
  weak var clipView: NSClipView?
  var showsLineNumbers = true

  private let font = GutterMetrics.lineNumberFont
  private let textColor: NSColor = .secondaryLabelColor
  private let backgroundColor: NSColor = .textBackgroundColor
  private let separatorColor: NSColor = .separatorColor

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { true }

  /// Width needed to show the current line count's digits, or 0 when hidden.
  func preferredWidth() -> CGFloat {
    guard showsLineNumbers, let textView else {
      return 0
    }
    return GutterMetrics.width(lineCount: textView.lineCount, font: font)
  }

  override func draw(_ dirtyRect: NSRect) {
    backgroundColor.setFill()
    dirtyRect.fill()
    guard showsLineNumbers, let textView, let clipView else {
      return
    }

    // Hairline at the gutter's right edge.
    separatorColor.setStroke()
    let separator = NSBezierPath()
    separator.move(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.minY))
    separator.line(to: NSPoint(x: bounds.maxX - 0.5, y: dirtyRect.maxY))
    separator.lineWidth = 1
    separator.stroke()

    // The clip view's bounds origin is the vertical scroll offset in document
    // coordinates; map each visible line's document y into the (unscrolled)
    // gutter by subtracting it.
    let visibleRect = clipView.bounds
    let layout = textView.layout
    let range = layout.visibleLineRange(in: visibleRect, lineCount: textView.lineCount)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
    ]
    for line in range {
      let gutterY = layout.yOffset(forLine: line) - visibleRect.minY
      let number = NSAttributedString(string: "\(line + 1)", attributes: attributes)
      let numberWidth = number.size().width
      number.draw(
        with: NSRect(
          x: max(0, bounds.width - GutterMetrics.trailingPadding - numberWidth),
          y: gutterY,
          width: numberWidth,
          height: layout.lineHeight
        ),
        options: [.usesLineFragmentOrigin]
      )
    }
  }
}

/// Lays out a pinned [`LineNumberGutterView`] to the left of a scrolling text
/// `NSScrollView`, sizing the gutter to its preferred width.
final class GutteredViewport: NSView {
  let gutter: LineNumberGutterView
  let scrollView: NSScrollView

  init(gutter: LineNumberGutterView, scrollView: NSScrollView) {
    self.gutter = gutter
    self.scrollView = scrollView
    super.init(frame: .zero)
    addSubview(scrollView)
    addSubview(gutter)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func layout() {
    super.layout()
    let gutterWidth = gutter.preferredWidth()
    gutter.isHidden = gutterWidth == 0
    gutter.frame = NSRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
    scrollView.frame = NSRect(
      x: gutterWidth, y: 0, width: max(bounds.width - gutterWidth, 0), height: bounds.height)
    // The text view tracks the clip width itself (no autoresizing), and the
    // gutter band changed with the new height.
    (scrollView.documentView as? LineRenderingTextView)?.updateLayout()
    gutter.needsDisplay = true
  }

  func refresh() {
    needsLayout = true
    gutter.needsDisplay = true
  }
}

/// Hosts the text view + pinned gutter for SwiftUI, with horizontal scrolling.
struct LargeTextViewport: NSViewRepresentable {
  let buffer: TextBuffer
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax

  func makeNSView(context: Context) -> GutteredViewport {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.contentView.postsBoundsChangedNotifications = true

    let documentView = LineRenderingTextView()
    documentView.setAccessibilityIdentifier("document-large-text-viewer")
    documentView.setAccessibilityLabel(accessibilityLabel)
    scrollView.documentView = documentView

    let gutter = LineNumberGutterView()
    gutter.textView = documentView
    gutter.clipView = scrollView.contentView
    gutter.showsLineNumbers = syntax.supportsLineNumbers

    documentView.syntax = syntax
    documentView.setBuffer(buffer)

    let container = GutteredViewport(gutter: gutter, scrollView: scrollView)

    // Redraw the gutter as the document scrolls vertically.
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.viewportScrolled),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    context.coordinator.gutter = gutter

    container.refresh()
    return container
  }

  func updateNSView(_ container: GutteredViewport, context: Context) {
    guard let documentView = container.scrollView.documentView as? LineRenderingTextView else {
      return
    }
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    container.gutter.showsLineNumbers = syntax.supportsLineNumbers
    // A new buffer (e.g. after an external-change reload) replaces the content.
    if documentView.buffer !== buffer {
      documentView.setBuffer(buffer)
    }
    container.refresh()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class Coordinator: NSObject {
    weak var gutter: LineNumberGutterView?

    @objc func viewportScrolled(_ notification: Notification) {
      gutter?.needsDisplay = true
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }
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
