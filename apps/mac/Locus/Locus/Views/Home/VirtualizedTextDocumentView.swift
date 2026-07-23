import AppKit
import SwiftUI

/// Hosts the virtualized text view for SwiftUI. The scroll view is returned
/// directly — its sole child is the document view, which composites reliably in
/// the layer-backed host. The document view draws its own pinned line-number
/// gutter, so nothing is overlaid on (or placed beside) the scroll view.
/// Which backend a ``LargeTextViewport`` renders: an editable buffer (its save
/// wiring applies) or a read-only large file (editing and saving stay inert).
enum TextViewportBackend {
  case editable(TextBuffer)
  case readOnly(LargeFile)
}

enum MarkdownViewMode: Equatable {
  case rendered
  case source

  var toggled: MarkdownViewMode {
    switch self {
    case .rendered:
      return .source
    case .source:
      return .rendered
    }
  }

  var toggleSystemImageName: String {
    switch self {
    case .rendered:
      return "chevron.left.forwardslash.chevron.right"
    case .source:
      return "text.alignleft"
    }
  }

  var toggleAccessibilityLabel: String {
    switch self {
    case .rendered:
      return "Show Markdown Source"
    case .source:
      return "Show Rendered View"
    }
  }
}

enum MarkdownViewModeToggleMetrics {
  static let size: CGFloat = 28
  static let topPadding: CGFloat = 10
  static let trailingPadding: CGFloat = 12
}

enum TextViewportPresentation {
  static func displaySyntax(
    for syntax: TextDocumentSyntax,
    markdownViewMode: MarkdownViewMode
  ) -> TextDocumentSyntax {
    syntax == .markdown && markdownViewMode == .source ? .plainText : syntax
  }

  static func usesClassicLineNumberGutter(
    for syntax: TextDocumentSyntax,
    markdownViewMode: MarkdownViewMode,
    backendIsReadOnly: Bool
  ) -> Bool {
    if displaySyntax(for: syntax, markdownViewMode: markdownViewMode).supportsLineNumbers {
      return true
    }
    return syntax == .markdown && backendIsReadOnly
  }
}

enum LargeTextViewportMetrics {
  /// Breathing room between the viewport's top edge and the first text line,
  /// applied as a scroll-view content inset so scrolled content still clips
  /// at the frame. Top only: a bottom inset would extend the scrollable range
  /// past the scroll-past-end frame and push the last line out of view at
  /// maximum scroll.
  static let topContentInset: CGFloat = 10
  static let markdownTopContentInset: CGFloat = topContentInset + 12

  static func topContentInset(
    for syntax: TextDocumentSyntax,
    markdownViewMode: MarkdownViewMode = .rendered
  ) -> CGFloat {
    TextViewportPresentation.displaySyntax(for: syntax, markdownViewMode: markdownViewMode)
      == .markdown ? markdownTopContentInset : topContentInset
  }
}

struct LargeTextViewport: NSViewRepresentable {
  let backend: TextViewportBackend
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax
  var markdownViewMode: MarkdownViewMode = .rendered
  var showsMarkdownViewModeToggleCursorRect = false
  /// Whether long lines soft-wrap to the viewport (prose) or scroll horizontally
  /// (structured/code/data). Decided per document by the host.
  let wrapsLines: Bool
  /// The editing/saving parameters below apply only to an `.editable` backend; a
  /// read-only large file ignores them (it is never editable and never saves), so
  /// they default to inert values and the read-only caller omits them.
  var isEditable: Bool = false
  var saveURL: URL?
  var saveEncoding: String.Encoding = .utf8
  /// A monotonic counter the host bumps to request a save (the viewer owns the
  /// off-main write). A change since the last seen value triggers `requestSave`.
  var saveRequest: Int = 0
  var onSaveCompletion: (Result<DocumentFileFingerprint?, Error>) -> Void = { _ in }
  var onDirtyChange: (Bool) -> Void = { _ in }
  var onFocusChange: (Bool) -> Void = { _ in }
  var onOpenLinkedFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
  var onViewReady: (LineRenderingTextView) -> Void = { _ in }
  var onFindRequested: () -> Void = {}
  var onDocumentContentChanged: () -> Void = {}

  /// A read-only backend is never editable, regardless of the host's `isEditable`.
  private var resolvedIsEditable: Bool {
    if case .editable = backend { return isEditable }
    return false
  }

  private var usesClassicLineNumberGutter: Bool {
    let backendIsReadOnly: Bool
    if case .readOnly = backend {
      backendIsReadOnly = true
    } else {
      backendIsReadOnly = false
    }
    return TextViewportPresentation.usesClassicLineNumberGutter(
      for: syntax,
      markdownViewMode: markdownViewMode,
      backendIsReadOnly: backendIsReadOnly)
  }

  /// Distinct accessibility identifiers so automation can tell the editable viewer
  /// from the read-only large-file viewer.
  private var backendAccessibilityIdentifier: String {
    if case .readOnly = backend { return "document-readonly-large-text-viewer" }
    return "document-large-text-viewer"
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    // Matches the document card (white in light, the fixed near-black in dark)
    // so the editor surface and the card never seam.
    scrollView.backgroundColor = LocusChromeColors.documentCard
    // Breathing room above the first line inside the scroll viewport: at rest
    // the first line sits inset from the card's top edge, while scrolled
    // content draws all the way to the frame and clips at the card border
    // (outer padding would clip at the inset line instead).
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets(
      top: LargeTextViewportMetrics.topContentInset(
        for: syntax, markdownViewMode: markdownViewMode),
      left: 0,
      bottom: 0,
      right: 0
    )

    let documentView = LineRenderingTextView()
    // Share the in-flight-save guard across editor views so a save started by a
    // torn-down view still pauses edits in a freshly created one for the same
    // cached buffer (keyed by buffer identity), preventing an edit from racing the
    // background write.
    documentView.saveTracker = .shared
    documentView.setAccessibilityIdentifier(backendAccessibilityIdentifier)
    documentView.setAccessibilityLabel(accessibilityLabel)
    scrollView.contentInsets.top = LargeTextViewportMetrics.topContentInset(
      for: syntax, markdownViewMode: markdownViewMode)
    documentView.syntax = syntax
    documentView.markdownViewMode = markdownViewMode
    documentView.showsMarkdownViewModeToggleCursorRect = showsMarkdownViewModeToggleCursorRect
    documentView.showsLineNumbers = usesClassicLineNumberGutter
    // Set before the document so the first wrap-index build uses the right mode.
    documentView.wrapsLines = wrapsLines
    documentView.isEditable = resolvedIsEditable
    documentView.saveURL = saveURL
    documentView.saveEncoding = saveEncoding
    documentView.onSaveCompletion = onSaveCompletion
    documentView.onDirtyChange = onDirtyChange
    documentView.onFocusChange = onFocusChange
    documentView.onOpenLinkedFile = onOpenLinkedFile
    documentView.onFindRequested = onFindRequested
    documentView.onDocumentContentChanged = onDocumentContentChanged
    scrollView.documentView = documentView

    switch backend {
    case .editable(let buffer):
      documentView.setBuffer(buffer)
    case .readOnly(let file):
      documentView.setReadOnlyDocument(file)
    }

    let clipView = scrollView.contentView
    // This view draws viewport-relative chrome (pinned gutter, caret, selection)
    // and rounds the visible band to whole rows, so it redraws the whole visible
    // band on each scroll (see `viewportDidScroll`) instead of letting the clip
    // view repaint only the newly exposed strip — which tore rows (content
    // appeared to jump a line) and left the gutter stale. (`copiesOnScroll` is a
    // no-op on macOS 11+, so the redraw is driven explicitly.)
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
    onViewReady(documentView)
    // Adopt the initial request value so the first `updateNSView` does not mistake
    // it for a save request.
    context.coordinator.lastSaveRequest = saveRequest

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let documentView = scrollView.documentView as? LineRenderingTextView else {
      return
    }
    let previousScrollOrigin = scrollView.contentView.bounds.origin
    let preservesScrollPosition =
      documentView.saveURL == saveURL
      && documentView.syntax == syntax
      && documentView.markdownViewMode == markdownViewMode
      && documentView.accessibilityLabel() == accessibilityLabel
    var didSwapDocument = false
    // Keep the identifier consistent with the backend in case a swap reuses this
    // view (makeNSView sets it once; updateNSView handles a backend change).
    documentView.setAccessibilityIdentifier(backendAccessibilityIdentifier)
    documentView.setAccessibilityLabel(accessibilityLabel)
    scrollView.contentInsets.top = LargeTextViewportMetrics.topContentInset(
      for: syntax, markdownViewMode: markdownViewMode)
    documentView.syntax = syntax
    documentView.markdownViewMode = markdownViewMode
    documentView.showsMarkdownViewModeToggleCursorRect = showsMarkdownViewModeToggleCursorRect
    documentView.showsLineNumbers = usesClassicLineNumberGutter
    // Set before any document swap so the rebuilt wrap index uses the right mode.
    documentView.wrapsLines = wrapsLines
    documentView.isEditable = resolvedIsEditable
    documentView.saveURL = saveURL
    documentView.saveEncoding = saveEncoding
    documentView.onSaveCompletion = onSaveCompletion
    documentView.onDirtyChange = onDirtyChange
    documentView.onFocusChange = onFocusChange
    documentView.onOpenLinkedFile = onOpenLinkedFile
    documentView.onFindRequested = onFindRequested
    documentView.onDocumentContentChanged = onDocumentContentChanged
    onViewReady(documentView)
    switch backend {
    case .editable(let buffer):
      if documentView.editableBuffer !== buffer {
        documentView.setBuffer(buffer)
        didSwapDocument = true
      }
    case .readOnly(let file):
      if !documentView.isShowingReadOnlyDocument(file) {
        documentView.setReadOnlyDocument(file)
        didSwapDocument = true
      }
    }
    if didSwapDocument, preservesScrollPosition {
      restore(scrollView: scrollView, to: previousScrollOrigin)
    }
    // A bumped save request (from the menu/Cmd+S command) asks the viewer to save.
    if context.coordinator.lastSaveRequest != saveRequest {
      context.coordinator.lastSaveRequest = saveRequest
      documentView.requestSave()
    }
  }

  private func restore(scrollView: NSScrollView, to origin: NSPoint) {
    guard let documentView = scrollView.documentView else { return }
    let visible = scrollView.contentView.bounds
    let insets = scrollView.contentInsets
    let minX = -insets.left
    let minY = -insets.top
    let maxX = max(minX, documentView.frame.width - visible.width)
    let maxY = max(minY, documentView.frame.height - visible.height)
    scrollView.contentView.scroll(
      to: NSPoint(
        x: min(max(origin.x, minX), maxX),
        y: min(max(origin.y, minY), maxY)))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class Coordinator: NSObject {
    weak var documentView: LineRenderingTextView?
    /// Last save-request value handled, so only an increment triggers a new save.
    var lastSaveRequest = 0

    @objc func viewportScrolled(_ notification: Notification) {
      documentView?.viewportDidScroll()
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

enum DocumentFindMetrics {
  static let findDebounce: Duration = .milliseconds(250)
  static let findFieldWidth: CGFloat = 180
}

enum DocumentFindDirection {
  case previous
  case next
}

@MainActor
final class DocumentFindState: ObservableObject {
  private enum SearchMode: Equatable {
    case interactive
    case passive
  }

  private struct PendingSearch {
    let query: String
    let mode: SearchMode
  }

  @Published private(set) var isFindBarVisible = false
  @Published private(set) var query = ""
  @Published private(set) var matches: [DocumentFindMatch] = []
  @Published private(set) var currentMatchIndex: Int?
  @Published private(set) var capped = false
  @Published private(set) var findFocusRequest = 0

  private weak var documentView: LineRenderingTextView?
  private var findTask: Task<Void, Never>?
  private var pendingSearch: PendingSearch?

  deinit {
    MainActor.assumeIsolated {
      findTask?.cancel()
      documentView?.clearDocumentFindHighlights()
    }
  }

  func registerDocumentView(_ view: LineRenderingTextView) {
    let didSwapView = documentView !== view
    documentView = view
    if didSwapView, isFindBarVisible {
      Task { @MainActor [weak self, weak view] in
        guard let self, let view, self.documentView === view else { return }
        self.scheduleSearch(for: self.query, mode: .passive)
      }
    }
  }

  func showFindBar() {
    guard documentView != nil else { return }
    if let selectedText = documentView?.selectedDisplayTextForFind(), !selectedText.isEmpty {
      query = selectedText
    }
    isFindBarVisible = true
    findFocusRequest += 1
    scheduleSearch(for: query, mode: .interactive)
  }

  func updateFindQuery(_ query: String) {
    guard self.query != query else { return }
    self.query = query
    scheduleSearch(for: query, mode: .interactive)
  }

  func selectSearch(_ direction: DocumentFindDirection) {
    guard !query.isEmpty else { return }
    if pendingSearch != nil {
      runSearch(for: query, mode: .interactive)
      if currentMatchIndex != nil {
        return
      }
    }
    guard !matches.isEmpty else { return }
    let nextIndex =
      switch direction {
      case .next:
        DocumentFindEngine.nextIndex(after: currentMatchIndex, matchCount: matches.count)
      case .previous:
        DocumentFindEngine.previousIndex(before: currentMatchIndex, matchCount: matches.count)
      }
    setCurrentMatchIndex(nextIndex)
  }

  func closeFindBar() {
    endFind(clearQuery: false)
    focusDocument()
  }

  func resetForDocumentSwitch() {
    endFind(clearQuery: true)
  }

  func documentDidChange() {
    guard isFindBarVisible else { return }
    scheduleSearch(for: query, mode: .passive)
  }

  func flushPendingSearchForTesting() {
    guard let pendingSearch else { return }
    runSearch(for: pendingSearch.query, mode: pendingSearch.mode)
  }

  private func scheduleSearch(for query: String, mode: SearchMode) {
    findTask?.cancel()
    findTask = nil
    guard isFindBarVisible, !query.isEmpty else {
      pendingSearch = nil
      clearSearchResults()
      return
    }
    let resolvedMode: SearchMode =
      if pendingSearch?.query == query, pendingSearch?.mode == .interactive {
        .interactive
      } else {
        mode
      }
    pendingSearch = PendingSearch(query: query, mode: resolvedMode)
    findTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: DocumentFindMetrics.findDebounce)
      } catch {
        return
      }
      guard let self, self.isFindBarVisible, self.query == query else { return }
      guard let pendingSearch = self.pendingSearch, pendingSearch.query == query else { return }
      self.runSearch(for: query, mode: pendingSearch.mode)
    }
  }

  private func runSearch(for query: String, mode: SearchMode) {
    findTask?.cancel()
    findTask = nil
    pendingSearch = nil
    guard isFindBarVisible, !query.isEmpty, let documentView else {
      clearSearchResults()
      return
    }
    let previousMatchPosition = currentMatchIndex.flatMap { index -> DocumentFindPosition? in
      guard matches.indices.contains(index) else { return nil }
      let match = matches[index]
      return DocumentFindPosition(line: match.line, columnUTF16: match.range.location)
    }
    let start =
      mode == .passive
      ? previousMatchPosition ?? documentView.documentFindStartPosition()
      : documentView.documentFindStartPosition()
    let result = documentView.documentFindResult(for: query)
    matches = result.matches
    capped = result.capped
    currentMatchIndex = DocumentFindEngine.firstMatchIndex(atOrAfter: start, in: matches)
    applyCurrentMatch(selectInDocument: mode == .interactive)
  }

  private func setCurrentMatchIndex(_ index: Int?) {
    currentMatchIndex = index
    applyCurrentMatch(selectInDocument: true)
  }

  private func applyCurrentMatch(selectInDocument: Bool) {
    documentView?.setDocumentFindHighlights(matches: matches, currentIndex: currentMatchIndex)
    guard selectInDocument else { return }
    guard let currentMatchIndex, matches.indices.contains(currentMatchIndex) else { return }
    documentView?.selectFindMatch(matches[currentMatchIndex])
  }

  private func clearSearchResults() {
    matches = []
    currentMatchIndex = nil
    capped = false
    documentView?.clearDocumentFindHighlights()
  }

  private func endFind(clearQuery: Bool) {
    findTask?.cancel()
    findTask = nil
    pendingSearch = nil
    isFindBarVisible = false
    if clearQuery {
      query = ""
    }
    clearSearchResults()
  }

  private func focusDocument() {
    guard let documentView, let window = documentView.window else { return }
    window.makeFirstResponder(documentView)
  }
}

enum DocumentFindPresentation {
  static func findCountLabel(
    query: String,
    matches: [DocumentFindMatch],
    currentMatchIndex: Int?,
    capped: Bool
  ) -> String {
    guard !query.isEmpty else { return "" }
    guard !matches.isEmpty else { return "0/0" }
    let selected = min(max((currentMatchIndex ?? 0) + 1, 1), matches.count)
    let total = capped ? "\(matches.count)+" : "\(matches.count)"
    return "\(selected)/\(total)"
  }
}

private struct DocumentFindTextField: NSViewRepresentable {
  @Binding var text: String
  let focusRequest: Int
  let onNext: () -> Void
  let onPrevious: () -> Void
  let onClose: () -> Void

  func makeNSView(context: Context) -> FindTextField {
    let field = FindTextField()
    field.placeholderString = "Find"
    field.isBordered = false
    field.isBezeled = false
    field.drawsBackground = false
    field.isEditable = true
    field.isSelectable = true
    field.isEnabled = true
    field.refusesFirstResponder = false
    field.focusRingType = .none
    field.usesSingleLineMode = true
    field.lineBreakMode = .byTruncatingTail
    field.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    field.delegate = context.coordinator
    field.onNext = onNext
    field.onPrevious = onPrevious
    field.onClose = onClose
    context.coordinator.onNext = onNext
    context.coordinator.onPrevious = onPrevious
    context.coordinator.onClose = onClose
    field.setAccessibilityIdentifier("document-find-field")
    if focusRequest > 0 {
      context.coordinator.lastFocusRequest = focusRequest
      field.requestFocusAndSelect()
    }
    return field
  }

  func updateNSView(_ field: FindTextField, context: Context) {
    context.coordinator.text = $text
    field.onNext = onNext
    field.onPrevious = onPrevious
    field.onClose = onClose
    context.coordinator.onNext = onNext
    context.coordinator.onPrevious = onPrevious
    context.coordinator.onClose = onClose
    if field.stringValue != text {
      field.stringValue = text
    }
    guard context.coordinator.lastFocusRequest != focusRequest else { return }
    context.coordinator.lastFocusRequest = focusRequest
    field.requestFocusAndSelect()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    var lastFocusRequest = 0
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    init(text: Binding<String>) {
      self.text = text
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      updateText(field.stringValue)
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)),
        #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
          onPrevious?()
        } else {
          onNext?()
        }
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        onClose?()
        return true
      default:
        return false
      }
    }

    func updateText(_ value: String) {
      guard text.wrappedValue != value else { return }
      text.wrappedValue = value
    }
  }

  final class FindTextField: NSTextField {
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?
    private var pendingFocusRequest = false
    private var focusAttemptCount = 0

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
      let modifiers = event.modifierFlags.intersection([
        .command, .control, .option, .shift,
      ])
      if modifiers == .command,
        event.charactersIgnoringModifiers?.lowercased() == "f"
      {
        selectText(nil)
        return true
      }
      return super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      focusIfNeeded()
    }

    func requestFocusAndSelect() {
      pendingFocusRequest = true
      focusAttemptCount = 0
      scheduleFocusAttempt()
    }

    private func focusIfNeeded() {
      guard pendingFocusRequest else { return }
      guard let window else {
        scheduleFocusAttempt()
        return
      }
      window.makeKey()
      window.makeFirstResponder(self)
      selectText(nil)
      let firstResponder = window.firstResponder
      if firstResponder === self || firstResponder === currentEditor() {
        pendingFocusRequest = false
        return
      }
      scheduleFocusAttempt()
    }

    private func scheduleFocusAttempt() {
      guard pendingFocusRequest, focusAttemptCount < 10 else { return }
      focusAttemptCount += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
        self?.focusIfNeeded()
      }
    }

    override func keyDown(with event: NSEvent) {
      let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      switch event.keyCode {
      case 36, 76:
        if modifiers.contains(.shift) {
          onPrevious?()
        } else {
          onNext?()
        }
      case 53:
        onClose?()
      default:
        super.keyDown(with: event)
      }
    }

    override func cancelOperation(_ sender: Any?) {
      onClose?()
    }
  }
}

private struct DocumentFindBar: View {
  @ObservedObject var state: DocumentFindState

  var body: some View {
    HStack(spacing: 4) {
      DocumentFindTextField(
        text: Binding(
          get: { state.query },
          set: { query in
            state.updateFindQuery(query)
          }
        ),
        focusRequest: state.findFocusRequest,
        onNext: {
          state.selectSearch(.next)
        },
        onPrevious: {
          state.selectSearch(.previous)
        },
        onClose: state.closeFindBar
      )
      .frame(width: DocumentFindMetrics.findFieldWidth)

      Text(findCountLabel)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 34, alignment: .trailing)
        .accessibilityLabel(findCountLabel)
        .accessibilityValue(findCountLabel)
        .accessibilityIdentifier("document-find-count")

      findButton(
        systemName: "chevron.up",
        label: "Previous Match",
        identifier: "document-find-previous"
      ) {
        state.selectSearch(.previous)
      }
      findButton(
        systemName: "chevron.down",
        label: "Next Match",
        identifier: "document-find-next"
      ) {
        state.selectSearch(.next)
      }
      findButton(
        systemName: "xmark",
        label: "Close Find",
        identifier: "document-find-close",
        action: state.closeFindBar
      )
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
    }
  }

  private var findCountLabel: String {
    DocumentFindPresentation.findCountLabel(
      query: state.query,
      matches: state.matches,
      currentMatchIndex: state.currentMatchIndex,
      capped: state.capped)
  }

  private func findButton(
    systemName: String,
    label: String,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }
}

/// The text document view for every recognized text file. It opens the file off
/// the main thread and chooses the backend by size (see
/// `WorkspaceDocumentSurfaceSupport.textBackend`): an editable in-memory
/// [`TextBuffer`] (retained across switches for its unsaved edits), or a read-only
/// windowed [`LargeFile`] when the file is too large to load. Either renders
/// through [`LargeTextViewport`]; editing — only with an editable buffer and
/// `isEditable` — is routed to the buffer, and Cmd+S saves it off the main thread.
struct VirtualizedTextDocumentView: View {
  let url: URL
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax
  var markdownViewMode: MarkdownViewMode = .rendered
  var showsMarkdownViewModeToggleCursorRect = false
  /// Whether long lines soft-wrap to the viewport (prose) or scroll horizontally
  /// (structured/code/data). Decided per document by the host.
  let wrapsLines: Bool
  /// Whether the viewer accepts edits (false for read-only entries).
  let isEditable: Bool
  /// Whether the file is a recognized text type, hence eligible for the windowed
  /// read-only backend when too large to edit in memory. An unrecognized (possibly
  /// binary) type is never opened read-only — that would scan it into mojibake — so
  /// it stays on the editable path, which refuses a too-large file instead.
  let recognizedTextType: Bool
  /// Changing this (e.g. on external file change) re-opens the buffer.
  let reloadToken: Int
  /// A monotonic counter the host bumps to request a save (e.g. from the Save menu
  /// command), since the viewer — not the host — owns the buffer and its write.
  var saveRequest: Int = 0
  /// Reports a save outcome to the host: on success the new file fingerprint
  /// (read synchronously right after the write) so the host can record it before
  /// the change monitor reacts; on failure the error to surface.
  var onSaveCompletion: (Result<DocumentFileFingerprint?, Error>) -> Void = { _ in }
  /// Reports the buffer's dirty state so the host can decide whether an external
  /// change may safely reload or conflicts with unsaved edits.
  var onDirtyChange: (Bool) -> Void = { _ in }
  /// Reports focus changes so the host can pause navigation shortcuts while the
  /// editor has the keyboard.
  var onFocusChange: (Bool) -> Void = { _ in }
  /// Opens a rendered Markdown file link. The host can route workspace files
  /// inside Locus; the default falls back to the system opener.
  var onOpenLinkedFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
  /// Holds opened buffers across file switches so unsaved edits survive navigating
  /// away and back; the view reads from and populates it instead of always opening
  /// a fresh buffer.
  let documentCache: OpenDocumentCache

  @State private var phase: Phase = .loading
  @StateObject private var findState = DocumentFindState()
  private let bufferStore = TextBufferStore()

  private enum Phase {
    case loading
    case editable(TextBuffer, encoding: String.Encoding)
    case readOnly(LargeFile)
    case failed(String)
  }

  var body: some View {
    Group {
      switch phase {
      case .loading:
        // Show feedback only if the open actually takes a moment (a large file's
        // index scan or a big read). A fast open — nearly always — finishes
        // within the grace period, so no spinner ever flashes.
        DelayedProgressView()
      case .editable(let buffer, let encoding):
        LargeTextViewport(
          backend: .editable(buffer),
          accessibilityLabel: accessibilityLabel,
          syntax: syntax,
          markdownViewMode: markdownViewMode,
          showsMarkdownViewModeToggleCursorRect: showsMarkdownViewModeToggleCursorRect,
          wrapsLines: wrapsLines,
          isEditable: isEditable,
          saveURL: url,
          saveEncoding: encoding,
          saveRequest: saveRequest,
          onSaveCompletion: onSaveCompletion,
          onDirtyChange: onDirtyChange,
          onFocusChange: onFocusChange,
          onOpenLinkedFile: onOpenLinkedFile,
          onViewReady: findState.registerDocumentView,
          onFindRequested: findState.showFindBar,
          onDocumentContentChanged: findState.documentDidChange
        )
        .overlay(alignment: .topTrailing) {
          documentFindOverlay
        }
      case .readOnly(let file):
        LargeTextViewport(
          backend: .readOnly(file),
          accessibilityLabel: accessibilityLabel,
          syntax: syntax,
          markdownViewMode: markdownViewMode,
          showsMarkdownViewModeToggleCursorRect: showsMarkdownViewModeToggleCursorRect,
          wrapsLines: wrapsLines,
          onFocusChange: onFocusChange,
          onOpenLinkedFile: onOpenLinkedFile,
          onViewReady: findState.registerDocumentView,
          onFindRequested: findState.showFindBar,
          onDocumentContentChanged: findState.documentDidChange
        )
        .overlay(alignment: .topTrailing) {
          documentFindOverlay
        }
      case .failed(let message):
        ContentUnavailableView {
          Label("Document Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: url) { _, _ in
      findState.resetForDocumentSwitch()
    }
    .task(id: TextViewportLoad(url: url, token: reloadToken)) {
      await open()
    }
  }

  @ViewBuilder
  private var documentFindOverlay: some View {
    if findState.isFindBarVisible {
      DocumentFindBar(state: findState)
        .padding(.top, 8)
        .padding(.trailing, 12)
    }
  }

  /// Loads the document, choosing the backend by size: a file within the editable
  /// limit opens as an in-memory editable buffer (retained across switches for its
  /// unsaved edits); a larger one opens read-only through the windowed `LargeFile`
  /// (never cached — it is immutable and read on demand). The size check honors the
  /// UI-test threshold override.
  private func open() async {
    let key = url.locusStandardizedPath
    // Reuse a retained editable buffer (with any unsaved edits) when switching back
    // to a file that is still open.
    if let cached = documentCache.cached(forKey: key) {
      phase = .editable(cached.buffer, encoding: cached.encoding)
      onDirtyChange(cached.buffer.isDirty)
      return
    }
    phase = .loading
    let target = url
    let store = bufferStore
    // Only a recognized text type uses the windowed read-only backend; an
    // unrecognized (maybe binary) file stays on the editable path.
    let allowsReadOnly = recognizedTextType
    do {
      let loaded = try await Task.detached(priority: .userInitiated) {
        // Decide the backend off the main thread (see `textBackend`): a recognized
        // file over the editable limit opens read-only; everything else opens
        // editable, which refuses a too-large file rather than scanning a binary.
        switch WorkspaceDocumentSurfaceSupport.textBackend(
          byteCount: WorkspaceDocumentSurfaceSupport.fileByteCount(at: target),
          recognizedTextType: allowsReadOnly)
        {
        case .readOnlyWindowed:
          return LoadedDocument.readOnly(try LargeFile.open(at: target))
        case .editable:
          let opened = try store.open(at: target)
          // Read the fingerprint alongside the open so the cache records the exact
          // disk state this buffer matches.
          let fingerprint = DocumentFileFingerprint.read(at: target)
          return LoadedDocument.editable(
            opened.buffer, encoding: opened.encoding, fingerprint: fingerprint)
        }
      }.value
      guard !Task.isCancelled else {
        return
      }
      switch loaded {
      case .readOnly(let file):
        onDirtyChange(false)  // read-only is never dirty; keep the host's Save off
        phase = .readOnly(file)
      case .editable(let buffer, let encoding, let fingerprint):
        documentCache.store(
          buffer: buffer, encoding: encoding, fingerprint: fingerprint, forKey: key)
        phase = .editable(buffer, encoding: encoding)
        onDirtyChange(buffer.isDirty)  // a freshly opened buffer is clean
      }
    } catch {
      guard !Task.isCancelled else {
        return
      }
      phase = .failed(Self.failureMessage(for: error))
    }
  }

  /// Maps an open failure to a user-facing message. A large non-UTF-8 file is
  /// called out explicitly: legacy encodings are decoded in memory (so they are
  /// bounded), and above that bound only UTF-8 (memory-mapped) is supported, so
  /// the narrowing is not silent.
  static func failureMessage(for error: Error) -> String {
    if let storeError = error as? TextBufferStoreError, case .tooLargeForEncoding = storeError {
      return storeError.errorDescription ?? error.localizedDescription
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

/// Carries a freshly opened document from the loader task to the main actor: a
/// non-`Sendable` editable `TextBuffer` (with its encoding and disk fingerprint),
/// or a read-only `LargeFile`. Handed across once and then used only on the main
/// actor, so the unchecked conformance is sound.
private enum LoadedDocument: @unchecked Sendable {
  case editable(TextBuffer, encoding: String.Encoding, fingerprint: DocumentFileFingerprint?)
  case readOnly(LargeFile)
}

/// A progress spinner that only appears after a short grace period, so a load
/// that finishes quickly never flashes a spinner. If the load completes first,
/// this view leaves the tree and its `.task` is cancelled before the sleep
/// returns, so the spinner stays hidden. Shared by the text editor and every
/// document preview surface (image, PDF, media, Quick Look) so loading feel is
/// consistent and mirrors the sidebar's delayed indicator.
struct DelayedProgressView: View {
  /// Matches `WorkspaceSidebarMetrics.loadingIndicatorDelay`.
  var delay: Duration = .milliseconds(180)
  @State private var isVisible = false

  var body: some View {
    ZStack {
      if isVisible {
        ProgressView()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task {
      guard (try? await Task.sleep(for: delay)) != nil else { return }
      isVisible = true
    }
  }
}

/// Tracks which editable text buffers have a background save in flight, so the
/// editor never starts a second, overlapping write of the same buffer (two
/// concurrent atomic writes to one file would race). It does *not* pause edits:
/// the writer streams an immutable `TextBufferSnapshot`, so the live buffer keeps
/// being edited during the write.
///
/// The guard must outlive a document swap: the open-document cache reuses the same
/// `TextBuffer` instance when the user switches away from a file and back, and the
/// view can be torn down and recreated mid-write. Keying by globally-unique buffer
/// identity (rather than a per-view flag that resets on swap) keeps the in-flight
/// mark correct across both, and `finish` always runs on completion, so no stale
/// "saving" entry outlives a write. Tests use their own instances for isolation.
@MainActor
final class DocumentSaveTracker {
  /// Process-wide shared tracker the editor uses in production.
  static let shared = DocumentSaveTracker()

  private var saving: Set<ObjectIdentifier> = []

  /// Whether `buffer` currently has a save in flight.
  func isSaving(_ buffer: TextBuffer) -> Bool {
    saving.contains(ObjectIdentifier(buffer))
  }

  /// Marks `buffer` as saving. Returns `false` if a save is already in flight for
  /// it, so the caller skips starting a second, overlapping write.
  @discardableResult
  func begin(_ buffer: TextBuffer) -> Bool {
    saving.insert(ObjectIdentifier(buffer)).inserted
  }

  /// Clears the in-flight mark for `buffer` (a no-op if none was set).
  func finish(_ buffer: TextBuffer) {
    saving.remove(ObjectIdentifier(buffer))
  }
}
