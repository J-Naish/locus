import AppKit
import SwiftUI

struct TextDocumentEditorView: NSViewRepresentable {
  @Binding var text: String
  let syntax: TextDocumentSyntax
  let isReadOnly: Bool
  let accessibilityLabel: String
  let onFocusChange: (Bool) -> Void

  func makeNSView(context: Context) -> TextDocumentEditorContainerView {
    let textView = FocusReportingTextView()
    textView.delegate = context.coordinator
    textView.textStorage?.delegate = context.coordinator
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.allowsUndo = true
    textView.drawsBackground = true
    textView.backgroundColor = .textBackgroundColor
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: 0,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    // Lay out only the visible region; the text view grows its own height
    // lazily as TextKit lays out fragments. This is what keeps large files
    // responsive on open and while scrolling.
    textView.layoutManager?.allowsNonContiguousLayout = true
    textView.autoresizingMask = [.width]
    textView.frame = NSRect(x: 0, y: 0, width: 1, height: 0)
    textView.setAccessibilityIdentifier("document-text-editor")
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.onFocusChange = context.coordinator.reportFocus

    let scrollView = NSScrollView()
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.documentView = textView
    scrollView.contentView.postsBoundsChangedNotifications = true

    let lineNumberGutter = TextLineNumberGutterView(textView: textView)
    let container = TextDocumentEditorContainerView(
      gutterView: lineNumberGutter,
      scrollView: scrollView,
      textView: textView
    )
    context.coordinator.attach(lineNumberGutter, to: scrollView)

    context.coordinator.configure(textView, text: text, syntax: syntax, isReadOnly: isReadOnly)
    return container
  }

  func updateNSView(_ container: TextDocumentEditorContainerView, context: Context) {
    let textView = container.textView
    if textView.accessibilityLabel() != accessibilityLabel {
      textView.setAccessibilityLabel(accessibilityLabel)
    }
    context.coordinator.configure(textView, text: text, syntax: syntax, isReadOnly: isReadOnly)
    container.needsLayout = true
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, onFocusChange: onFocusChange)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    private var text: Binding<String>
    private let onFocusChange: (Bool) -> Void
    private var isUpdatingTextView = false
    private var isApplyingHighlight = false
    private var currentSyntax: TextDocumentSyntax?
    private weak var lineNumberGutter: TextLineNumberGutterView?
    private weak var observedClipView: NSClipView?
    private var pendingLineNumberReload = false

    init(text: Binding<String>, onFocusChange: @escaping (Bool) -> Void) {
      self.text = text
      self.onFocusChange = onFocusChange
    }

    deinit {
      if let observedClipView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.boundsDidChangeNotification,
          object: observedClipView
        )
      }
    }

    func attach(_ lineNumberGutter: TextLineNumberGutterView, to scrollView: NSScrollView) {
      if let observedClipView {
        NotificationCenter.default.removeObserver(
          self,
          name: NSView.boundsDidChangeNotification,
          object: observedClipView
        )
      }

      self.lineNumberGutter = lineNumberGutter
      observedClipView = scrollView.contentView
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(visibleBoundsDidChange),
        name: NSView.boundsDidChangeNotification,
        object: scrollView.contentView
      )
    }

    func configure(
      _ textView: NSTextView?,
      text: String,
      syntax: TextDocumentSyntax,
      isReadOnly: Bool
    ) {
      guard let textView else {
        return
      }

      textView.isEditable = !isReadOnly
      textView.isSelectable = true
      textView.font = syntax.font

      let textChanged = textView.string != text
      let needsSyntaxUpdate = currentSyntax != syntax
      guard textChanged || needsSyntaxUpdate else {
        updateLineNumberVisibility(for: textView, syntax: syntax, reload: false)
        return
      }

      let selectedRanges = textView.selectedRanges
      isUpdatingTextView = true
      if textChanged {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.textStorage?.replaceCharacters(in: fullRange, with: text)
      }
      applyHighlight(to: textView, syntax: syntax)
      textView.selectedRanges = selectedRanges.clamped(
        toTextLength: (textView.string as NSString).length)
      currentSyntax = syntax
      updateLineNumberVisibility(for: textView, syntax: syntax, reload: true)
      isUpdatingTextView = false
    }

    func reportFocus(_ isFocused: Bool) {
      onFocusChange(isFocused)
    }

    func textDidChange(_ notification: Notification) {
      guard !isUpdatingTextView,
        let textView = notification.object as? NSTextView
      else {
        return
      }

      text.wrappedValue = textView.string
      updateLineNumberVisibility(
        for: textView,
        syntax: currentSyntax ?? .plainText,
        reload: pendingLineNumberReload
      )
      if !pendingLineNumberReload {
        lineNumberGutter?.needsDisplay = true
      }
      pendingLineNumberReload = false
    }

    func textDidBeginEditing(_ notification: Notification) {
      reportFocus(true)
    }

    func textDidEndEditing(_ notification: Notification) {
      reportFocus(false)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView,
        textView.window?.firstResponder === textView
      else {
        return
      }

      reportFocus(true)
    }

    func textView(
      _ textView: NSTextView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      pendingLineNumberReload =
        pendingLineNumberReload
        || TextLineNumberLayout.editCanChangeLineStarts(
          currentText: textView.string,
          affectedRange: affectedCharRange,
          replacementText: replacementString
        )
      return true
    }

    func textStorage(
      _ textStorage: NSTextStorage,
      didProcessEditing editedMask: NSTextStorageEditActions,
      range editedRange: NSRange,
      changeInLength delta: Int
    ) {
      guard !isUpdatingTextView,
        !isApplyingHighlight,
        editedMask.contains(.editedCharacters)
      else {
        return
      }

      let syntax = currentSyntax ?? .plainText
      let text = textStorage.string
      let highlightedRange = TextDocumentSyntaxHighlighter.highlightedParagraphRange(
        for: editedRange,
        in: text
      )

      isApplyingHighlight = true
      TextDocumentSyntaxHighlighter.apply(
        to: textStorage,
        text: text,
        syntax: syntax,
        font: syntax.font,
        range: highlightedRange
      )
      isApplyingHighlight = false
    }

    private func applyHighlight(to textView: NSTextView, syntax: TextDocumentSyntax) {
      isApplyingHighlight = true
      TextDocumentSyntaxHighlighter.apply(
        to: textView.textStorage,
        text: textView.string,
        syntax: syntax,
        font: syntax.font
      )
      isApplyingHighlight = false
    }

    private func updateLineNumberVisibility(
      for textView: NSTextView,
      syntax: TextDocumentSyntax,
      reload: Bool
    ) {
      guard let lineNumberGutter else {
        return
      }

      let shouldShowLineNumbers = TextLineNumberLayout.shouldShowLineNumbers(
        syntax: syntax,
        textUTF16Length: (textView.string as NSString).length
      )
      lineNumberGutter.setLineNumbersVisible(shouldShowLineNumbers)

      guard shouldShowLineNumbers else {
        return
      }

      if reload {
        lineNumberGutter.reloadLineNumbers()
      } else {
        lineNumberGutter.needsDisplay = true
      }
    }

    @objc private func visibleBoundsDidChange(_ notification: Notification) {
      lineNumberGutter?.needsDisplay = true
    }
  }
}

final class TextDocumentEditorContainerView: NSView {
  let textView: FocusReportingTextView
  private let scrollView: NSScrollView

  init(
    gutterView: TextLineNumberGutterView,
    scrollView: NSScrollView,
    textView: FocusReportingTextView
  ) {
    self.textView = textView
    self.scrollView = scrollView
    super.init(frame: .zero)

    gutterView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(gutterView)
    addSubview(scrollView)

    NSLayoutConstraint.activate([
      gutterView.leadingAnchor.constraint(equalTo: leadingAnchor),
      gutterView.topAnchor.constraint(equalTo: topAnchor),
      gutterView.bottomAnchor.constraint(equalTo: bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  override func layout() {
    super.layout()

    // Match the text view width to the clip view and keep a short document
    // filling the viewport via minSize. Height is owned by the vertically
    // resizable text view, which grows it lazily as TextKit lays out the
    // visible region. Forcing full-document layout here (ensureLayout/usedRect)
    // would defeat lazy layout and stall on large files.
    let contentWidth = max(1, scrollView.contentSize.width)
    let contentHeight = max(1, scrollView.contentSize.height)

    if textView.frame.width != contentWidth {
      textView.setFrameSize(NSSize(width: contentWidth, height: textView.frame.height))
    }
    if textView.minSize.height != contentHeight {
      textView.minSize.height = contentHeight
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class TextLineNumberGutterView: NSView {
  weak var textView: NSTextView?
  private let font = TextDocumentSyntax.lineNumberFont

  private var lineNumbersVisible = true
  private var lineStartLocations = [0]
  private var widthConstraint: NSLayoutConstraint?

  init(textView: NSTextView) {
    self.textView = textView
    super.init(frame: .zero)
    widthConstraint = widthAnchor.constraint(
      equalToConstant: TextLineNumberLayout.gutterWidth(
        lineCount: lineStartLocations.count,
        font: font
      )
    )
    widthConstraint?.isActive = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isFlipped: Bool {
    true
  }

  func setLineNumbersVisible(_ isVisible: Bool) {
    guard lineNumbersVisible != isVisible else {
      return
    }

    lineNumbersVisible = isVisible
    if isVisible {
      reloadLineNumbers()
    } else {
      widthConstraint?.constant = 0
      needsDisplay = true
    }
  }

  func reloadLineNumbers() {
    guard lineNumbersVisible else {
      widthConstraint?.constant = 0
      needsDisplay = true
      return
    }

    lineStartLocations = TextLineNumberLayout.lineStartLocations(in: textView?.string ?? "")
    widthConstraint?.constant = TextLineNumberLayout.gutterWidth(
      lineCount: lineStartLocations.count,
      font: font
    )
    needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    guard lineNumbersVisible else {
      return
    }

    NSColor.textBackgroundColor.setFill()
    dirtyRect.fill()
    NSColor.separatorColor.setFill()
    NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()

    guard let textView,
      let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer,
      let scrollView = textView.enclosingScrollView
    else {
      return
    }

    let visibleRect = scrollView.contentView.bounds
    var visibleTextContainerRect = visibleRect
    visibleTextContainerRect.origin.x -= textView.textContainerOrigin.x
    visibleTextContainerRect.origin.y -= textView.textContainerOrigin.y

    let glyphRange = layoutManager.glyphRange(
      forBoundingRect: visibleTextContainerRect,
      in: textContainer
    )
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .right
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.tertiaryLabelColor,
      .paragraphStyle: paragraphStyle,
    ]

    func drawLineNumber(_ lineNumber: Int, usedRect: NSRect) {
      let lineHeight = max(usedRect.height, self.font.boundingRectForFont.height)
      let y = textView.textContainerOrigin.y + usedRect.minY - visibleRect.minY
      let labelRect = NSRect(
        x: TextLineNumberLayout.leadingPadding,
        y: y,
        width: self.bounds.width - TextLineNumberLayout.leadingPadding
          - TextLineNumberLayout.trailingPadding,
        height: lineHeight
      )
      "\(lineNumber)".draw(in: labelRect, withAttributes: attributes)
    }

    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
      [self] _, usedRect, _, lineGlyphRange, _ in
      let characterRange = layoutManager.characterRange(
        forGlyphRange: lineGlyphRange,
        actualGlyphRange: nil
      )
      guard
        TextLineNumberLayout.isLineStart(
          characterRange.location,
          in: self.lineStartLocations
        )
      else {
        return
      }

      let lineNumber = TextLineNumberLayout.lineNumber(
        forCharacterLocation: characterRange.location,
        in: self.lineStartLocations
      )
      drawLineNumber(lineNumber, usedRect: usedRect)
    }

    let textLength = (textView.string as NSString).length
    if lineStartLocations.last == textLength,
      layoutManager.extraLineFragmentTextContainer === textContainer
    {
      let extraLineFragmentRect = layoutManager.extraLineFragmentRect
      let y = textView.textContainerOrigin.y + extraLineFragmentRect.minY
      if y >= visibleRect.minY && y <= visibleRect.maxY {
        drawLineNumber(lineStartLocations.count, usedRect: extraLineFragmentRect)
      }
    }
  }
}

enum TextLineNumberLayout {
  // Gutter geometry is shared with the large-file viewer via `GutterMetrics`.
  static let leadingPadding = GutterMetrics.leadingPadding
  static let trailingPadding = GutterMetrics.trailingPadding
  static let maximumLineNumberedUTF16Length = 200_000

  static func shouldShowLineNumbers(
    syntax: TextDocumentSyntax,
    textUTF16Length: Int
  ) -> Bool {
    syntax.supportsLineNumbers && textUTF16Length <= maximumLineNumberedUTF16Length
  }

  static func lineStartLocations(in text: String) -> [Int] {
    let nsText = text as NSString
    guard nsText.length > 0 else {
      return [0]
    }

    var starts = [0]
    var location = 0
    while location < nsText.length {
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      nsText.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0)
      )
      guard lineEnd > location else {
        break
      }

      if contentsEnd < lineEnd {
        starts.append(lineEnd)
      }
      location = lineEnd
    }

    return starts
  }

  static func lineNumber(forCharacterLocation location: Int, in lineStartLocations: [Int]) -> Int {
    guard location > 0 else {
      return 1
    }

    var lowerBound = 0
    var upperBound = lineStartLocations.count
    while lowerBound < upperBound {
      let mid = (lowerBound + upperBound) / 2
      if lineStartLocations[mid] <= location {
        lowerBound = mid + 1
      } else {
        upperBound = mid
      }
    }

    return max(1, lowerBound)
  }

  static func isLineStart(_ location: Int, in lineStartLocations: [Int]) -> Bool {
    indexOfLineStart(location, in: lineStartLocations) != nil
  }

  static func gutterWidth(lineCount: Int, font: NSFont) -> CGFloat {
    GutterMetrics.width(lineCount: lineCount, font: font)
  }

  static func editCanChangeLineStarts(
    currentText: String,
    affectedRange: NSRange,
    replacementText: String?
  ) -> Bool {
    if replacementText?.containsLineSeparator == true {
      return true
    }

    let nsText = currentText as NSString
    let clampedRange = affectedRange.clamped(toTextLength: nsText.length)
    guard clampedRange.length > 0 else {
      return false
    }

    return nsText.substring(with: clampedRange).containsLineSeparator
  }

  private static func indexOfLineStart(_ location: Int, in lineStartLocations: [Int]) -> Int? {
    var lowerBound = 0
    var upperBound = lineStartLocations.count
    while lowerBound < upperBound {
      let mid = (lowerBound + upperBound) / 2
      if lineStartLocations[mid] == location {
        return mid
      }
      if lineStartLocations[mid] < location {
        lowerBound = mid + 1
      } else {
        upperBound = mid
      }
    }

    return nil
  }
}

final class FocusReportingTextView: NSTextView {
  var onFocusChange: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let didBecomeFirstResponder = super.becomeFirstResponder()
    if didBecomeFirstResponder {
      onFocusChange?(true)
    }

    return didBecomeFirstResponder
  }

  override func resignFirstResponder() -> Bool {
    let didResignFirstResponder = super.resignFirstResponder()
    if didResignFirstResponder {
      onFocusChange?(false)
    }

    return didResignFirstResponder
  }
}

extension TextDocumentSyntax {
  fileprivate static var lineNumberFont: NSFont {
    GutterMetrics.lineNumberFont
  }

  var supportsLineNumbers: Bool {
    switch self {
    case .markdown, .plainText, .structuredText, .code:
      return true
    }
  }
}

extension String {
  fileprivate var containsLineSeparator: Bool {
    rangeOfCharacter(from: .newlines) != nil
  }
}

extension NSRange {
  fileprivate func clamped(toTextLength textLength: Int) -> NSRange {
    guard location >= 0 else {
      return NSRange(location: 0, length: 0)
    }

    guard location <= textLength else {
      return NSRange(location: textLength, length: 0)
    }

    let maximumLength = Swift.max(0, textLength - location)
    return NSRange(location: location, length: Swift.min(length, maximumLength))
  }
}

extension [NSValue] {
  fileprivate func clamped(toTextLength textLength: Int) -> [NSValue] {
    map { value in
      let range = value.rangeValue
      guard range.location <= textLength else {
        return NSValue(range: NSRange(location: textLength, length: 0))
      }

      let maximumLength = Swift.max(0, textLength - range.location)
      return NSValue(
        range: NSRange(location: range.location, length: Swift.min(range.length, maximumLength)))
    }
  }
}
