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
  private let layout: TextViewportLayout
  private let horizontalPadding: CGFloat = 8
  private let textColor: NSColor = .textColor
  private let backgroundColor: NSColor = .textBackgroundColor
  /// Without horizontal scrolling, only the start of a line is ever visible, so
  /// a pathologically long line is truncated before layout to bound draw cost.
  private let maximumDrawnCharactersPerLine = 5_000
  /// One-entry cache of the last fetched band so repeated draws of the same
  /// range (overlapping dirty rects, redraws without scrolling) skip the FFI
  /// fetch. Keyed by revision so any future edit invalidates it.
  private var cachedBand: (revision: UInt64, range: Range<Int>, lines: [String])?

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
    updateHeight()
    scroll(.zero)
    needsDisplay = true
  }

  /// Returns the visible band's line contents, reusing the cache when the same
  /// `(revision, range)` is requested again.
  private func bandLines(for buffer: TextBuffer, range: Range<Int>) -> [String] {
    let revision = buffer.revision
    if let cachedBand, cachedBand.revision == revision, cachedBand.range == range {
      return cachedBand.lines
    }
    // `text(forLineRange:)` joins the requested lines with "\n" (terminators
    // stripped), so splitting on "\n" recovers exactly `range.count` lines.
    let lines = buffer.text(forLineRange: range.lowerBound, count: range.count)
      .components(separatedBy: "\n")
    cachedBand = (revision, range, lines)
    return lines
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

    let lines = bandLines(for: buffer, range: range)
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
    ]
    for (offset, line) in lines.enumerated() {
      let lineIndex = range.lowerBound + offset
      // Only the line's start is visible without horizontal scrolling; cap the
      // laid-out text so one very long line cannot stall drawing.
      let visible =
        line.count > maximumDrawnCharactersPerLine
        ? String(line.prefix(maximumDrawnCharactersPerLine))
        : line
      let attributed = NSAttributedString(string: visible, attributes: attributes)
      // `.usesLineFragmentOrigin` makes the rect origin the line's top-left,
      // which is what we want in a flipped view.
      attributed.draw(
        with: NSRect(
          x: horizontalPadding,
          y: layout.yOffset(forLine: lineIndex),
          width: max(bounds.width - horizontalPadding * 2, 0),
          height: layout.lineHeight
        ),
        options: [.usesLineFragmentOrigin]
      )
    }
  }
}

/// Hosts [`LineRenderingTextView`] in an `NSScrollView` for SwiftUI.
struct LargeTextViewport: NSViewRepresentable {
  let buffer: TextBuffer
  let accessibilityLabel: String

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
    documentView.setBuffer(buffer)

    context.coordinator.documentView = documentView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let documentView = context.coordinator.documentView else {
      return
    }
    documentView.setAccessibilityLabel(accessibilityLabel)
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
/// opens the file through the Rust [`TextBuffer`] (which memory-maps very large
/// files) off the main thread, then renders it with [`LargeTextViewport`].
struct VirtualizedTextDocumentView: View {
  let url: URL
  let accessibilityLabel: String
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
        // the buffer is ready (opening is fast even for large files).
        Color(nsColor: .textBackgroundColor)
      case .loaded(let buffer):
        LargeTextViewport(buffer: buffer, accessibilityLabel: accessibilityLabel)
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
