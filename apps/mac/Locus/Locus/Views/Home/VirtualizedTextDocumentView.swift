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

/// Custom flipped `NSView` document view that draws only the visible band of a
/// [`TextBuffer`], fetching that band from the Rust core on demand. The document
/// height is synthesized from the line count, so a multi-gigabyte file never has
/// its text assembled in memory — scrolling redraws exposed bands. Lines are not
/// wrapped; the view widens to the widest line it has drawn.
final class LineRenderingTextView: NSView {
  private(set) var buffer: TextBuffer?
  let layout: TextViewportLayout
  private let font: NSFont
  private let horizontalPadding: CGFloat = 8
  /// Extra width past the widest line so the last character is not flush against
  /// the right edge when scrolled fully right.
  private let trailingContentMargin: CGFloat = 40
  private let viewportBackgroundColor: NSColor = .textBackgroundColor

  // Line-number gutter, drawn by this view (pinned to the left of the viewport,
  // text laid out to its right). Earlier sibling and `NSRulerView` arrangements
  // had compositing issues in the SwiftUI layer-backed host (blank document, or a
  // gutter that overlapped the text), so the gutter is drawn here in the same
  // pass as the text instead.
  var showsLineNumbers = true {
    didSet {
      guard showsLineNumbers != oldValue else { return }
      updateLayout()
      invalidateVisibleArea()
    }
  }
  private let gutterFont = GutterMetrics.lineNumberFont
  private let gutterTextColor: NSColor = .secondaryLabelColor
  private let gutterSeparatorColor: NSColor = .separatorColor

  var syntax: TextDocumentSyntax = .plainText {
    didSet {
      guard syntax != oldValue else { return }
      cachedBand = nil
      invalidateVisibleArea()
    }
  }

  /// Bytes fetched per line for the visible band; longer lines are truncated for
  /// the fetch so one enormous line never crosses the FFI in full.
  private let maximumFetchedBytesPerLine = 16_384
  /// Characters actually drawn per line. Lines longer than this are clipped for
  /// display (this is a read-only viewer, not a full horizontal renderer), which
  /// also bounds the document's width.
  private let maximumDrawnCharactersPerLine = 5_000
  private var cachedBand: (revision: UInt64, range: Range<Int>, lines: [NSAttributedString])?
  private var maxObservedLineWidth: CGFloat = 0
  private var pendingLayoutUpdate = false

  var lineCount: Int { buffer?.lineCount ?? 1 }

  /// Width of the line-number gutter for the current line count, or 0 when hidden.
  var gutterWidth: CGFloat {
    showsLineNumbers ? GutterMetrics.width(lineCount: lineCount, font: gutterFont) : 0
  }

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

  override var isFlipped: Bool { true }

  func setBuffer(_ buffer: TextBuffer?) {
    self.buffer = buffer
    cachedBand = nil
    maxObservedLineWidth = 0
    updateLayout()
    // A new document always opens at the top-left; otherwise a reused scroll view
    // would keep the previous file's scroll position.
    if let scrollView = enclosingScrollView {
      scrollView.contentView.scroll(to: .zero)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }
    invalidateVisibleArea()
  }

  /// Marks only the visible portion for redisplay. Invalidating the whole view
  /// would make the dirty rect — and the band fetched to satisfy it — span the
  /// entire (potentially multi-million-point) document.
  func invalidateVisibleArea() {
    setNeedsDisplay(visibleRect)
  }

  /// Resizes the document to fit the line count (height) and the widest line seen
  /// so far (width), but never narrower than the visible content area. The width
  /// follows the widest drawn line, which is bounded by
  /// `maximumDrawnCharactersPerLine`; the scroll view only backs the visible
  /// region, so a tall/wide document does not allocate a full-size layer.
  func updateLayout() {
    let visibleWidth = enclosingScrollView?.documentVisibleRect.width ?? frame.width
    let contentWidth =
      gutterWidth + horizontalPadding + maxObservedLineWidth + trailingContentMargin
    let width = max(visibleWidth, contentWidth)
    setFrameSize(NSSize(width: width, height: layout.contentHeight(lineCount: lineCount)))
  }

  private func attributedBandLines(for buffer: TextBuffer, range: Range<Int>)
    -> [NSAttributedString]
  {
    let revision = buffer.revision
    if let cachedBand, cachedBand.revision == revision, cachedBand.range == range {
      return cachedBand.lines
    }
    let lines = buffer.text(
      forLineRange: range.lowerBound, count: range.count,
      maxBytesPerLine: maximumFetchedBytesPerLine
    )
    .components(separatedBy: "\n")
    .map(highlightedLine)
    cachedBand = (revision, range, lines)
    return lines
  }

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
    viewportBackgroundColor.setFill()
    dirtyRect.fill()

    guard let buffer else {
      return
    }
    let range = layout.visibleLineRange(in: dirtyRect, lineCount: buffer.lineCount)
    guard !range.isEmpty else {
      return
    }

    let gutter = gutterWidth
    let textX = gutter + horizontalPadding
    let lines = attributedBandLines(for: buffer, range: range)
    var widest = maxObservedLineWidth
    for (offset, attributedLine) in lines.enumerated() {
      let y = layout.yOffset(forLine: range.lowerBound + offset)
      let size = attributedLine.size()
      widest = max(widest, size.width)
      attributedLine.draw(
        with: NSRect(x: textX, y: y, width: size.width, height: layout.lineHeight),
        options: [.usesLineFragmentOrigin]
      )
    }
    if gutter > 0 {
      drawGutter(width: gutter, lineRange: range, dirtyRect: dirtyRect)
    }
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

  /// Draws the line-number gutter pinned to the left of the visible viewport, on
  /// top of the text so horizontally scrolled text slides underneath it.
  private func drawGutter(width: CGFloat, lineRange: Range<Int>, dirtyRect: NSRect) {
    // Left of the visible area, in this (document) view's coordinates. Tracks
    // horizontal scrolling so the gutter stays put while the text scrolls.
    let originX = enclosingScrollView?.contentView.bounds.origin.x ?? 0
    let columnRect = NSRect(
      x: originX, y: dirtyRect.minY, width: width, height: dirtyRect.height)
    viewportBackgroundColor.setFill()
    columnRect.fill()

    gutterSeparatorColor.setStroke()
    let separator = NSBezierPath()
    separator.move(to: NSPoint(x: originX + width - 0.5, y: dirtyRect.minY))
    separator.line(to: NSPoint(x: originX + width - 0.5, y: dirtyRect.maxY))
    separator.lineWidth = 1
    separator.stroke()

    let attributes: [NSAttributedString.Key: Any] = [
      .font: gutterFont,
      .foregroundColor: gutterTextColor,
    ]
    for line in lineRange {
      let number = NSAttributedString(string: "\(line + 1)", attributes: attributes)
      let numberWidth = number.size().width
      number.draw(
        with: NSRect(
          x: originX + max(0, width - GutterMetrics.trailingPadding - numberWidth),
          y: layout.yOffset(forLine: line),
          width: numberWidth,
          height: layout.lineHeight
        ),
        options: [.usesLineFragmentOrigin]
      )
    }
  }
}

/// Hosts the virtualized text view for SwiftUI. The scroll view is returned
/// directly — its sole child is the document view, which composites reliably in
/// the layer-backed host. The document view draws its own pinned line-number
/// gutter, so nothing is overlaid on (or placed beside) the scroll view.
struct LargeTextViewport: NSViewRepresentable {
  let buffer: TextBuffer
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    // The pinned gutter is drawn by the document view at the current scroll
    // offset, so the whole visible area must repaint on scroll (the default
    // copy-on-scroll would smear the gutter horizontally).
    scrollView.contentView.copiesOnScroll = false

    let documentView = LineRenderingTextView()
    documentView.setAccessibilityIdentifier("document-large-text-viewer")
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    documentView.showsLineNumbers = syntax.supportsLineNumbers
    scrollView.documentView = documentView

    documentView.setBuffer(buffer)

    let clipView = scrollView.contentView
    clipView.postsBoundsChangedNotifications = true
    clipView.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.viewportScrolled),
      name: NSView.boundsDidChangeNotification,
      object: clipView
    )
    NotificationCenter.default.addObserver(
      context.coordinator,
      selector: #selector(Coordinator.viewportResized),
      name: NSView.frameDidChangeNotification,
      object: clipView
    )
    context.coordinator.documentView = documentView

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let documentView = scrollView.documentView as? LineRenderingTextView else {
      return
    }
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    documentView.showsLineNumbers = syntax.supportsLineNumbers
    if documentView.buffer !== buffer {
      documentView.setBuffer(buffer)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class Coordinator: NSObject {
    weak var documentView: LineRenderingTextView?

    @objc func viewportScrolled(_ notification: Notification) {
      // Repaint so the pinned gutter follows the new horizontal offset and shows
      // the line numbers for the newly visible rows.
      documentView?.invalidateVisibleArea()
    }

    @objc func viewportResized(_ notification: Notification) {
      documentView?.updateLayout()
      documentView?.invalidateVisibleArea()
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
        let didStartAccess = target.startAccessingSecurityScopedResource()
        defer {
          if didStartAccess {
            target.stopAccessingSecurityScopedResource()
          }
        }
        return OpenedTextBuffer(buffer: try TextBuffer.open(at: target))
      }.value
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
  /// called out explicitly: the editable path decodes legacy encodings, but this
  /// large-file viewer is UTF-8 only for now, so the narrowing is not silent.
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
