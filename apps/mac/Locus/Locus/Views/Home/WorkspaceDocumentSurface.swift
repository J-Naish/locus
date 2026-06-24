import AVKit
import AppKit
import PDFKit
import QuickLookUI
import SwiftUI

struct WorkspaceDocumentSurface: View {
  let entry: WorkspaceEntry?
  let imageDocumentStore: any ImageDocumentStoring
  let pdfDocumentStore: any PDFDocumentStoring
  let mediaDocumentStore: any MediaDocumentStoring
  let quickLookDocumentStore: any QuickLookDocumentStoring
  let onTextInputFocusChange: (Bool) -> Void
  /// Called after the open document is saved to disk so the host can refresh
  /// dependent UI — notably Git status, which should turn a tracked file
  /// "modified" once an edit lands rather than waiting for another trigger.
  let onDocumentSaved: () -> Void

  @State private var saveErrorMessage: String?
  @State private var knownDocumentFingerprint: DocumentFileFingerprint?
  @State private var documentReloadGeneration = 0
  @State private var isEditorFocused = false
  /// Whether the text editor has unsaved edits, mirrored from it so an external
  /// change can be reconciled without losing edits.
  @State private var documentDirty = false
  /// Set when an external change arrives while the editor is dirty: the buffer is
  /// kept (not reloaded) and a conflict banner is shown.
  @State private var documentConflict = false
  /// Bumped to ask the editor to save. The editor owns the buffer and its off-main
  /// write, so the menu/Cmd+S command routes through this token rather than saving
  /// here.
  @State private var documentSaveRequest = 0
  @State private var autoSaveTask: Task<Void, Never>?
  /// Effective read-only state of the selected document, resolved once per
  /// selection (URL.locusIsReadOnly) rather than for every entry during listing.
  /// Seeded from the core's mode-bit `readonly` so the common case is correct
  /// immediately, then refined for read-only volumes, ACLs, and immutable flags.
  @State private var selectedDocumentReadOnly = false
  @AppStorage(LocusPersistedDefaults.textEditingAutoSaveEnabled)
  private var isAutoSaveEnabled = true
  @StateObject private var documentChangeMonitor = DocumentChangeMonitor()
  /// Retains opened buffers across file switches so unsaved edits survive
  /// navigating away and back (persists for the surface's lifetime).
  @StateObject private var openDocuments = OpenDocumentCache()

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if let entry {
          switch WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry) {
          case .editableText:
            textDocumentSurface(for: entry)
          case .image:
            ImageDocumentSurface(
              entry: entry,
              imageDocumentStore: imageDocumentStore,
              reloadTrigger: documentReloadTrigger(for: entry)
            )
          case .pdf:
            PDFDocumentSurface(
              entry: entry,
              pdfDocumentStore: pdfDocumentStore,
              reloadTrigger: documentReloadTrigger(for: entry)
            )
          case .video, .audio:
            MediaDocumentSurface(
              entry: entry,
              mediaDocumentStore: mediaDocumentStore,
              reloadTrigger: documentReloadTrigger(for: entry)
            )
          case .quickLookPreview:
            QuickLookDocumentSurface(
              entry: entry,
              quickLookDocumentStore: quickLookDocumentStore,
              reloadTrigger: documentReloadTrigger(for: entry)
            )
          case .folder:
            FolderDocumentSurface(entry: entry)
          case .unsupported:
            UnsupportedDocumentSurface(entry: entry)
          }
        } else {
          EmptyDocumentSurface()
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(
      minWidth: LocusWindowMetrics.documentSurfaceMinimumWidth
        - 2 * DocumentCardMetrics.horizontalInset,
      maxWidth: .infinity,
      maxHeight: .infinity
    )
    .focusedSceneValue(
      \.documentSaveCommand,
      DocumentSaveCommand(canSave: !isSaveDisabled, save: saveSelectedDocument)
    )
    .background(
      WindowUnsavedChangesGuard(hasUnsavedChanges: hasUnsavedDocuments)
        .frame(width: 0, height: 0)
    )
    .task(id: entry?.id) {
      // Start before and after preparing so external writes during the prepare
      // path still trigger a sync without relying on the later refresh token.
      startDocumentMonitoringIfNeeded(for: entry)
      await prepareSelectedDocument()
      guard !Task.isCancelled else {
        return
      }
      startDocumentMonitoringIfNeeded(for: entry)
    }
    .onChange(of: entry?.id) {
      cancelAutoSave()
      isEditorFocused = false
      knownDocumentFingerprint = nil
      documentDirty = false
      documentConflict = false
      saveErrorMessage = nil
      // Seed from the core's mode-bit readonly so editability is right immediately;
      // prepareSelectedDocument refines it for volume/ACL/immutable cases.
      selectedDocumentReadOnly = entry?.isReadOnly ?? false
      onTextInputFocusChange(false)
    }
    .onChange(of: isEditorFocused) {
      onTextInputFocusChange(isEditorFocused)
    }
    .onChange(of: isAutoSaveEnabled) {
      if isAutoSaveEnabled {
        scheduleAutoSaveIfNeeded()
      } else {
        cancelAutoSave()
      }
    }
    .onDisappear {
      cancelAutoSave()
      documentChangeMonitor.stopMonitoring()
      onTextInputFocusChange(false)
    }
  }

  /// The text-document surface. Every recognized text file opens in the
  /// virtualized engine, which picks its own backend by size — an editable
  /// in-memory buffer, or the read-only windowed `LargeFile` for a file too big to
  /// load — and owns loading, failure UI, editing, save, and dirty reporting. The
  /// surface (not the engine) owns external-change detection and the
  /// conflict/reload decision, driving a reload through `reloadToken`.
  private func textDocumentSurface(for entry: WorkspaceEntry) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let saveErrorMessage {
        Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .padding(12)
          .accessibilityIdentifier("document-save-error")
      }

      if documentConflict {
        HStack(spacing: 12) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text("This file changed on disk.")
              // Spell out the consequence of keeping edits so the choice isn't
              // ambiguous: the in-memory version wins on the next save.
              Text("Keeping your edits will overwrite that change on the next save.")
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .font(.caption)
          Spacer(minLength: 0)
          // Dismiss the warning and keep editing the in-memory version; the
          // divergence from disk is resolved (by overwriting it) on the next save.
          Button("Keep Editing") { keepEditingAfterExternalConflict() }
          Button("Reload from Disk") { reloadDocumentDiscardingEdits() }
        }
        .padding(12)
        .background(.thinMaterial)
        .accessibilityIdentifier("document-conflict-banner")
      }

      VirtualizedTextDocumentView(
        url: entry.url,
        accessibilityLabel: "\(entry.name) text",
        syntax: WorkspaceTextDocumentSupport.syntax(for: entry) ?? .plainText,
        wrapsLines: WorkspaceTextDocumentSupport.wrapsLines(for: entry),
        isEditable: !selectedDocumentReadOnly,
        recognizedTextType: WorkspaceTextDocumentSupport.isRecognizedTextType(entry),
        reloadToken: documentReloadGeneration,
        saveRequest: documentSaveRequest,
        onSaveCompletion: { result in handleDocumentSaveResult(result, for: entry) },
        onDirtyChange: { isDirty in handleDocumentDirtyChange(isDirty) },
        onFocusChange: { isFocused in isEditorFocused = isFocused },
        documentCache: openDocuments
      )
    }
  }

  private func documentReloadTrigger(for entry: WorkspaceEntry) -> DocumentReloadTrigger {
    DocumentReloadTrigger(entryID: entry.id, generation: documentReloadGeneration)
  }

  private var isSaveDisabled: Bool {
    // The editor owns its dirty state; Save is enabled only for a writable text
    // document with unsaved edits.
    guard let entry, !selectedDocumentReadOnly, WorkspaceTextDocumentSupport.canEdit(entry) else {
      return true
    }
    return !documentDirty
  }

  private var hasUnsavedDocuments: Bool {
    documentDirty || openDocuments.hasDirtyDocuments
  }

  /// Establishes the external-change baseline for a freshly selected text
  /// document. For a document already open in the cache (switching back to it),
  /// the baseline is the disk state it was last in sync with, so a change made
  /// while it was inactive — and therefore unmonitored — is detected now
  /// (reload if clean, conflict if it has unsaved edits). Otherwise the current
  /// disk state is the baseline.
  @MainActor
  private func prepareSelectedDocument() async {
    saveErrorMessage = nil

    guard let entry, WorkspaceTextDocumentSupport.canOpenInTextSurface(entry) else {
      knownDocumentFingerprint = nil
      return
    }

    // Resolve effective read-only state once for the opened document (read-only
    // volume, ACL, ownership, immutable flags) rather than per entry at listing. A
    // file too large to edit in memory opens read-only regardless (the viewer picks
    // the windowed backend); its fingerprint baseline below is cheap (size + mtime)
    // and lets an external change reload it.
    selectedDocumentReadOnly = entry.url.locusIsReadOnly(fallback: entry.isReadOnly)

    let key = entry.url.locusStandardizedPath
    let baseline =
      openDocuments.contains(forKey: key) ? openDocuments.fingerprint(forKey: key) : nil
    let current = await DocumentFileFingerprint.load(at: entry.url)
    guard self.entry?.id == entry.id else {
      return
    }
    knownDocumentFingerprint = current

    // Switching back to a still-open document: it was unmonitored while inactive,
    // so reconcile any external change now, using the cached buffer's own dirty
    // state (not the lagging surface mirror, which the editor has not re-reported
    // yet).
    let reconciliation = WorkspaceDocumentSurfaceSupport.reconciliation(
      isCached: openDocuments.contains(forKey: key),
      baselineFingerprint: baseline,
      currentFingerprint: current,
      hasPendingConflict: openDocuments.hasPendingConflict(forKey: key),
      hasUnsavedEdits: openDocuments.isDirty(forKey: key)
    )
    switch reconciliation {
    case .keepBuffer:
      return
    case .conflict:
      openDocuments.setFingerprint(current, forKey: key)
      openDocuments.setPendingConflict(true, forKey: key)
      documentConflict = true  // keep the unsaved edits; warn about the divergence
    case .reloadFromDisk:
      openDocuments.setFingerprint(current, forKey: key)
      openDocuments.setPendingConflict(false, forKey: key)
      documentConflict = false
      openDocuments.drop(forKey: key)  // clean → reopen to show the new disk content
      documentReloadGeneration &+= 1
    }
  }

  @MainActor
  private func startDocumentMonitoringIfNeeded(for entry: WorkspaceEntry?) {
    guard let entry, WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry).isAutoSynced else {
      documentChangeMonitor.stopMonitoring()
      return
    }

    documentChangeMonitor.startMonitoring(entry.url) {
      Task {
        await syncDisplayedDocumentIfChanged()
      }
    }
  }

  /// Asks the editor to save (it owns the buffer and writes off the main thread)
  /// by bumping a token it observes.
  @MainActor
  private func saveSelectedDocument() {
    cancelAutoSave()
    guard !isSaveDisabled else {
      return
    }
    documentSaveRequest &+= 1
  }

  /// Reconciles a save. On success the file fingerprint is recorded synchronously
  /// from the save result (the editor read it right after writing), so the change
  /// monitor never treats our own write as an external change — no async window to
  /// race. A save also resolves any pending conflict, since the file now holds our
  /// content. On failure the error is surfaced.
  @MainActor
  private func handleDocumentSaveResult(
    _ result: Result<DocumentFileFingerprint?, Error>, for entry: WorkspaceEntry
  ) {
    guard self.entry?.id == entry.id else {
      return
    }
    switch result {
    case .success(let fingerprint):
      saveErrorMessage = nil
      documentConflict = false
      knownDocumentFingerprint = fingerprint
      // Keep the retained buffer's baseline current so switching back later does
      // not mistake our own save for an external change.
      openDocuments.setFingerprint(fingerprint, forKey: entry.url.locusStandardizedPath)
      openDocuments.setPendingConflict(false, forKey: entry.url.locusStandardizedPath)
      // An edit just landed on disk; let the host refresh Git status so the
      // sidebar reflects the new "modified" state without another trigger.
      onDocumentSaved()
      // If the user kept typing while the write was in flight, the buffer can
      // still be dirty. Re-arm Auto Save for that newer content.
      scheduleAutoSaveIfNeeded()
    case .failure(let error):
      saveErrorMessage = error.localizedDescription
    }
  }

  /// Mirrors the editor's dirty state. A pending conflict is *not* cleared just
  /// because the buffer became clean (e.g. undoing edits): the external change is
  /// still unreconciled, so the banner stays until the user reloads/keeps or a
  /// reload/save resolves it.
  @MainActor
  private func handleDocumentDirtyChange(_ isDirty: Bool) {
    documentDirty = isDirty
    if isDirty {
      scheduleAutoSaveIfNeeded()
    } else {
      cancelAutoSave()
    }
  }

  /// Resolves an external-change conflict by discarding in-memory edits and
  /// reopening the file from disk. The fingerprint was already updated when the
  /// conflict was detected, so the reopen does not immediately re-conflict.
  @MainActor
  private func reloadDocumentDiscardingEdits() {
    cancelAutoSave()
    documentConflict = false
    documentDirty = false
    // Drop the retained (edited) buffer so the reopen reads fresh disk content.
    if let entry {
      openDocuments.setPendingConflict(false, forKey: entry.url.locusStandardizedPath)
      openDocuments.drop(forKey: entry.url.locusStandardizedPath)
    }
    documentReloadGeneration &+= 1
  }

  @MainActor
  private func keepEditingAfterExternalConflict() {
    documentConflict = false
    if let entry {
      openDocuments.setPendingConflict(false, forKey: entry.url.locusStandardizedPath)
    }
  }

  @MainActor
  private func scheduleAutoSaveIfNeeded() {
    guard
      DocumentAutoSavePolicy.shouldRequestAutoSave(
        isEnabled: isAutoSaveEnabled,
        canSave: !isSaveDisabled,
        hasConflict: documentConflict)
    else {
      cancelAutoSave()
      return
    }

    autoSaveTask?.cancel()
    autoSaveTask = Task { @MainActor in
      guard (try? await Task.sleep(for: DocumentAutoSavePolicy.debounceDelay)) != nil else {
        return
      }
      guard !Task.isCancelled else {
        return
      }
      autoSaveTask = nil
      await autoSaveSelectedDocumentIfDiskIsCurrent()
    }
  }

  @MainActor
  private func cancelAutoSave() {
    autoSaveTask?.cancel()
    autoSaveTask = nil
  }

  @MainActor
  private func autoSaveSelectedDocumentIfDiskIsCurrent() async {
    guard let entry else {
      return
    }

    let key = entry.url.locusStandardizedPath
    let expectedFingerprint = knownDocumentFingerprint ?? openDocuments.fingerprint(forKey: key)
    let currentFingerprint = await DocumentFileFingerprint.load(at: entry.url)
    guard self.entry?.id == entry.id else {
      return
    }

    guard
      DocumentAutoSavePolicy.shouldRequestAutoSave(
        isEnabled: isAutoSaveEnabled,
        canSave: !isSaveDisabled,
        hasConflict: documentConflict,
        diskMatchesKnownState: currentFingerprint == expectedFingerprint)
    else {
      if currentFingerprint != expectedFingerprint {
        reconcileExternalChangeDiscoveredBeforeAutoSave(currentFingerprint, for: entry)
      } else {
        cancelAutoSave()
      }
      return
    }

    saveSelectedDocument()
  }

  @MainActor
  private func reconcileExternalChangeDiscoveredBeforeAutoSave(
    _ fingerprint: DocumentFileFingerprint?, for entry: WorkspaceEntry
  ) {
    knownDocumentFingerprint = fingerprint
    openDocuments.setFingerprint(fingerprint, forKey: entry.url.locusStandardizedPath)

    if WorkspaceTextDocumentSupport.canEdit(entry), documentDirty {
      openDocuments.setPendingConflict(true, forKey: entry.url.locusStandardizedPath)
      documentConflict = true
      cancelAutoSave()
    } else {
      documentConflict = false
      openDocuments.setPendingConflict(false, forKey: entry.url.locusStandardizedPath)
      openDocuments.drop(forKey: entry.url.locusStandardizedPath)
      documentReloadGeneration &+= 1
    }
  }

}

extension WorkspaceDocumentSurface {
  @MainActor
  fileprivate func syncDisplayedDocumentIfChanged() async {
    guard let entry,
      WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry).isAutoSynced
    else {
      return
    }

    let fingerprint = await DocumentFileFingerprint.load(at: entry.url)
    guard self.entry?.id == entry.id else {
      return
    }

    if let knownDocumentFingerprint, fingerprint == knownDocumentFingerprint {
      return
    }

    // Accept this disk state as known either way, so the same external change is
    // not re-detected on every later sync — including after switching away and
    // back to a still-open document.
    knownDocumentFingerprint = fingerprint
    openDocuments.setFingerprint(fingerprint, forKey: entry.url.locusStandardizedPath)

    if WorkspaceTextDocumentSupport.canEdit(entry), documentDirty {
      // Editable text with unsaved edits: do not reopen (that would discard them).
      // Surface a conflict so the user chooses to reload or keep their changes.
      openDocuments.setPendingConflict(true, forKey: entry.url.locusStandardizedPath)
      documentConflict = true
      cancelAutoSave()
    } else {
      // Clean text, or a non-editable preview (image/PDF/media): reopen to show the
      // new content. This also reconciles to disk, resolving any earlier conflict
      // (e.g. one made clean by undo). Drop the retained buffer first so the reopen
      // reads fresh disk content (a no-op for non-text entries).
      documentConflict = false
      openDocuments.setPendingConflict(false, forKey: entry.url.locusStandardizedPath)
      openDocuments.drop(forKey: entry.url.locusStandardizedPath)
      documentReloadGeneration &+= 1
    }
  }
}

private struct DocumentReloadTrigger: Equatable {
  let entryID: String
  let generation: Int
}

private struct EmptyDocumentSurface: View {
  var body: some View {
    ContentUnavailableView {
      Label("Select a File", systemImage: "doc.text.magnifyingglass")
    } description: {
      Text("Supported documents can be read, viewed, or edited here.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("document-empty-surface")
  }
}

private struct ImageDocumentSurface: View {
  let entry: WorkspaceEntry
  let imageDocumentStore: any ImageDocumentStoring
  let reloadTrigger: DocumentReloadTrigger

  @State private var loadState: ImageDocumentLoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch loadState {
      case .loading:
        DelayedProgressView()
      case .loaded(let image):
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityLabel("\(entry.name) image")
          .accessibilityIdentifier("document-image-view")
      case .failed(let message):
        ContentUnavailableView {
          Label("Image Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") {
            Task {
              await loadImage()
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("document-image-error-surface")
      }
    }
    .task(id: reloadTrigger) {
      await loadImage()
    }
  }

  @MainActor
  private func loadImage() async {
    loadState = .loading

    do {
      let document = try await imageDocumentStore.loadImage(at: entry.url)
      guard !Task.isCancelled else {
        return
      }

      loadState = .loaded(document.image)
    } catch {
      guard !Task.isCancelled else {
        return
      }

      loadState = .failed(error.localizedDescription)
    }
  }
}

private enum ImageDocumentLoadState {
  case loading
  case loaded(NSImage)
  case failed(String)
}

private struct PDFDocumentSurface: View {
  let entry: WorkspaceEntry
  let pdfDocumentStore: any PDFDocumentStoring
  let reloadTrigger: DocumentReloadTrigger

  @State private var loadState: PDFDocumentLoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch loadState {
      case .loading:
        DelayedProgressView()
      case .loaded(let document):
        PDFDocumentView(document: document)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("\(entry.name) PDF")
          .accessibilityIdentifier("document-pdf-surface")
      case .failed(let message):
        ContentUnavailableView {
          Label("PDF Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") {
            Task {
              await loadPDF()
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("document-pdf-error-surface")
      }
    }
    .task(id: reloadTrigger) {
      await loadPDF()
    }
  }

  @MainActor
  private func loadPDF() async {
    loadState = .loading

    do {
      let document = try await pdfDocumentStore.loadPDF(at: entry.url)
      guard !Task.isCancelled else {
        return
      }

      loadState = .loaded(document.document)
    } catch {
      guard !Task.isCancelled else {
        return
      }

      loadState = .failed(error.localizedDescription)
    }
  }
}

private enum PDFDocumentLoadState {
  case loading
  case loaded(PDFDocument)
  case failed(String)
}

@MainActor
private struct PDFDocumentView: NSViewRepresentable {
  let document: PDFDocument

  func makeNSView(context: Context) -> PDFView {
    let pdfView = PDFView()
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.backgroundColor = .clear
    pdfView.setAccessibilityIdentifier("document-pdf-view")
    return pdfView
  }

  func updateNSView(_ pdfView: PDFView, context: Context) {
    if pdfView.document !== document {
      pdfView.document = document
      // PDFView can drop fit-to-window scaling on document assignment.
      pdfView.autoScales = true
    }
  }
}

private struct MediaDocumentSurface: View {
  let entry: WorkspaceEntry
  let mediaDocumentStore: any MediaDocumentStoring
  let reloadTrigger: DocumentReloadTrigger

  @State private var loadState: MediaDocumentLoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch loadState {
      case .loading:
        DelayedProgressView()
      case .loaded(let document):
        MediaPlayerView(player: document.player)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("\(entry.name) media player")
          .accessibilityIdentifier(surfaceAccessibilityIdentifier)
      case .failed(let message):
        ContentUnavailableView {
          Label("Media Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") {
            Task {
              await loadMedia()
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("document-media-error-surface")
      }
    }
    .task(id: reloadTrigger) {
      await loadMedia()
    }
    .onDisappear {
      pauseLoadedPlayer()
    }
  }

  @MainActor
  private func loadMedia() async {
    pauseLoadedPlayer()
    loadState = .loading

    do {
      let document = try await mediaDocumentStore.loadMedia(at: entry.url)
      guard !Task.isCancelled else {
        return
      }

      loadState = .loaded(document)
    } catch {
      guard !Task.isCancelled else {
        return
      }

      loadState = .failed(error.localizedDescription)
    }
  }

  private func pauseLoadedPlayer() {
    guard case .loaded(let document) = loadState else {
      return
    }

    document.player.pause()
  }

  private var surfaceAccessibilityIdentifier: String {
    switch entry.fileType {
    case .audio:
      return "document-audio-surface"
    case .video:
      return "document-video-surface"
    case .markdown, .structuredText, .plainText, .code, .pdf, .office, .image, .unknown:
      return "document-media-surface"
    }
  }
}

private enum MediaDocumentLoadState {
  case loading
  case loaded(MediaDocument)
  case failed(String)
}

private struct MediaPlayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let playerView = AVPlayerView()
    playerView.controlsStyle = .inline
    playerView.setAccessibilityIdentifier("document-media-view")
    return playerView
  }

  func updateNSView(_ playerView: AVPlayerView, context: Context) {
    if playerView.player !== player {
      playerView.player = player
    }
  }

  static func dismantleNSView(_ playerView: AVPlayerView, coordinator: ()) {
    playerView.player?.pause()
    playerView.player = nil
  }
}

private struct QuickLookDocumentSurface: View {
  let entry: WorkspaceEntry
  let quickLookDocumentStore: any QuickLookDocumentStoring
  let reloadTrigger: DocumentReloadTrigger

  @State private var loadState: QuickLookDocumentLoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch loadState {
      case .loading:
        DelayedProgressView()
      case .loaded(let document):
        QuickLookDocumentView(url: document.url)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityElement(children: .contain)
          .accessibilityLabel("\(entry.name) preview")
          .accessibilityIdentifier("document-quicklook-surface")
      case .failed(let message):
        ContentUnavailableView {
          Label("Preview Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") {
            Task {
              await loadQuickLookDocument()
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("document-quicklook-error-surface")
      }
    }
    .task(id: reloadTrigger) {
      await loadQuickLookDocument()
    }
  }

  @MainActor
  private func loadQuickLookDocument() async {
    loadState = .loading

    do {
      let document = try await quickLookDocumentStore.loadQuickLookDocument(at: entry.url)
      guard !Task.isCancelled else {
        return
      }

      loadState = .loaded(document)
    } catch {
      guard !Task.isCancelled else {
        return
      }

      loadState = .failed(error.localizedDescription)
    }
  }
}

private enum QuickLookDocumentLoadState {
  case loading
  case loaded(QuickLookDocument)
  case failed(String)
}

private struct QuickLookDocumentView: NSViewRepresentable {
  let url: URL

  func makeNSView(context: Context) -> QLPreviewView {
    let previewView: QLPreviewView =
      QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView(frame: .zero)
    previewView.autostarts = false
    previewView.setAccessibilityIdentifier("document-quicklook-view")
    return previewView
  }

  func updateNSView(_ previewView: QLPreviewView, context: Context) {
    guard previewView.previewItem?.previewItemURL != url else {
      return
    }

    previewView.previewItem = url as NSURL
  }

  static func dismantleNSView(_ previewView: QLPreviewView, coordinator: ()) {
    previewView.close()
  }
}

private struct FolderDocumentSurface: View {
  let entry: WorkspaceEntry

  var body: some View {
    ContentUnavailableView {
      Label("Folder Selected", systemImage: "folder")
    } description: {
      Text("\(entry.name) is open in the file list.")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("document-folder-surface")
  }
}

private struct UnsupportedDocumentSurface: View {
  let entry: WorkspaceEntry

  var body: some View {
    ContentUnavailableView {
      Label("No Built-In Preview", systemImage: "doc")
    } description: {
      Text(
        "No preview is available for this \(WorkspaceFileTypeLabel.displayLabel(for: entry).lowercased())."
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("document-unsupported-surface")
  }
}
