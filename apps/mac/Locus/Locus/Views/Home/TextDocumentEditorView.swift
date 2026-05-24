import AppKit
import SwiftUI

struct TextDocumentEditorView: NSViewRepresentable {
  @Binding var text: String
  let syntax: TextDocumentSyntax
  let isReadOnly: Bool
  let accessibilityLabel: String
  let onFocusChange: (Bool) -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let textView = FocusReportingTextView()
    textView.delegate = context.coordinator
    textView.textStorage?.delegate = context.coordinator
    textView.isRichText = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.allowsUndo = true
    textView.drawsBackground = false
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.textContainer?.lineFragmentPadding = 0
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.autoresizingMask = [.width]
    textView.setAccessibilityIdentifier("document-text-editor")
    textView.setAccessibilityLabel(accessibilityLabel)
    textView.onFocusChange = context.coordinator.reportFocus

    let scrollView = NSScrollView()
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.documentView = textView
    scrollView.contentView.postsBoundsChangedNotifications = true

    context.coordinator.configure(textView, text: text, syntax: syntax, isReadOnly: isReadOnly)
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    let textView = scrollView.documentView as? FocusReportingTextView
    if textView?.accessibilityLabel() != accessibilityLabel {
      textView?.setAccessibilityLabel(accessibilityLabel)
    }
    context.coordinator.configure(textView, text: text, syntax: syntax, isReadOnly: isReadOnly)
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

    init(text: Binding<String>, onFocusChange: @escaping (Bool) -> Void) {
      self.text = text
      self.onFocusChange = onFocusChange
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

      let needsSyntaxUpdate = currentSyntax != syntax
      guard textView.string != text || needsSyntaxUpdate else {
        return
      }

      let selectedRanges = textView.selectedRanges
      isUpdatingTextView = true
      if textView.string != text {
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.textStorage?.replaceCharacters(in: fullRange, with: text)
      }
      applyHighlight(to: textView, syntax: syntax)
      textView.selectedRanges = selectedRanges.clamped(
        toTextLength: (textView.string as NSString).length)
      currentSyntax = syntax
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
  }
}

private final class FocusReportingTextView: NSTextView {
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
