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

enum LargeTextViewportMetrics {
  /// Breathing room between the viewport's top edge and the first text line,
  /// applied as a scroll-view content inset so scrolled content still clips
  /// at the frame. Top only: a bottom inset would extend the scrollable range
  /// past the scroll-past-end frame and push the last line out of view at
  /// maximum scroll.
  static let topContentInset: CGFloat = 10
}

struct LargeTextViewport: NSViewRepresentable {
  let backend: TextViewportBackend
  let accessibilityLabel: String
  let syntax: TextDocumentSyntax
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

  /// A read-only backend is never editable, regardless of the host's `isEditable`.
  private var resolvedIsEditable: Bool {
    if case .editable = backend { return isEditable }
    return false
  }

  private var usesClassicLineNumberGutter: Bool {
    if syntax.supportsLineNumbers { return true }
    if syntax == .markdown, case .readOnly = backend { return true }
    return false
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
      top: LargeTextViewportMetrics.topContentInset,
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
    documentView.syntax = syntax
    documentView.showsLineNumbers = usesClassicLineNumberGutter
    // Set before the document so the first wrap-index build uses the right mode.
    documentView.wrapsLines = wrapsLines
    documentView.isEditable = resolvedIsEditable
    documentView.saveURL = saveURL
    documentView.saveEncoding = saveEncoding
    documentView.onSaveCompletion = onSaveCompletion
    documentView.onDirtyChange = onDirtyChange
    documentView.onFocusChange = onFocusChange
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
    // Adopt the initial request value so the first `updateNSView` does not mistake
    // it for a save request.
    context.coordinator.lastSaveRequest = saveRequest

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let documentView = scrollView.documentView as? LineRenderingTextView else {
      return
    }
    // Keep the identifier consistent with the backend in case a swap reuses this
    // view (makeNSView sets it once; updateNSView handles a backend change).
    documentView.setAccessibilityIdentifier(backendAccessibilityIdentifier)
    documentView.setAccessibilityLabel(accessibilityLabel)
    documentView.syntax = syntax
    documentView.showsLineNumbers = usesClassicLineNumberGutter
    // Set before any document swap so the rebuilt wrap index uses the right mode.
    documentView.wrapsLines = wrapsLines
    documentView.isEditable = resolvedIsEditable
    documentView.saveURL = saveURL
    documentView.saveEncoding = saveEncoding
    documentView.onSaveCompletion = onSaveCompletion
    documentView.onDirtyChange = onDirtyChange
    documentView.onFocusChange = onFocusChange
    switch backend {
    case .editable(let buffer):
      if documentView.editableBuffer !== buffer {
        documentView.setBuffer(buffer)
      }
    case .readOnly(let file):
      if !documentView.isShowingReadOnlyDocument(file) {
        documentView.setReadOnlyDocument(file)
      }
    }
    // A bumped save request (from the menu/Cmd+S command) asks the viewer to save.
    if context.coordinator.lastSaveRequest != saveRequest {
      context.coordinator.lastSaveRequest = saveRequest
      documentView.requestSave()
    }
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
  /// Holds opened buffers across file switches so unsaved edits survive navigating
  /// away and back; the view reads from and populates it instead of always opening
  /// a fresh buffer.
  let documentCache: OpenDocumentCache

  @State private var phase: Phase = .loading
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
          wrapsLines: wrapsLines,
          isEditable: isEditable,
          saveURL: url,
          saveEncoding: encoding,
          saveRequest: saveRequest,
          onSaveCompletion: onSaveCompletion,
          onDirtyChange: onDirtyChange,
          onFocusChange: onFocusChange
        )
      case .readOnly(let file):
        LargeTextViewport(
          backend: .readOnly(file),
          accessibilityLabel: accessibilityLabel,
          syntax: syntax,
          wrapsLines: wrapsLines,
          onFocusChange: onFocusChange
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
