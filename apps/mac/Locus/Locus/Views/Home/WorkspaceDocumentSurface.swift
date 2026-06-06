import AVKit
import AppKit
import PDFKit
import QuickLookUI
import SwiftUI

struct WorkspaceDocumentSurface: View {
  let entry: WorkspaceEntry?
  let textDocumentStore: any TextDocumentStoring
  let imageDocumentStore: any ImageDocumentStoring
  let pdfDocumentStore: any PDFDocumentStoring
  let mediaDocumentStore: any MediaDocumentStoring
  let quickLookDocumentStore: any QuickLookDocumentStoring
  let onTextInputFocusChange: (Bool) -> Void

  @State private var loadState: TextDocumentLoadState = .empty
  @State private var text = ""
  @State private var savedText = ""
  @State private var encoding: String.Encoding = .utf8
  @State private var activeDocumentID: WorkspaceEntry.ID?
  @State private var drafts: [WorkspaceEntry.ID: TextDocumentDraft] = [:]
  @State private var saveErrorMessage: String?
  @State private var knownDocumentFingerprint: DocumentFileFingerprint?
  @State private var documentReloadGeneration = 0
  @State private var isEditorFocused = false
  @StateObject private var documentChangeMonitor = DocumentChangeMonitor()

  var body: some View {
    VStack(spacing: 0) {
      Divider()

      Group {
        if let entry {
          switch WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry) {
          case .editableText:
            editableDocumentSurface(for: entry)
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
    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .focusedSceneValue(
      \.documentSaveCommand,
      DocumentSaveCommand(canSave: !isSaveDisabled, save: saveSelectedDocument)
    )
    .task(id: entry?.id) {
      // Start before and after loading so external writes during the load path
      // still trigger a sync without relying on the later refresh token.
      startDocumentMonitoringIfNeeded(for: entry)
      await loadSelectedDocumentIfNeeded()
      guard !Task.isCancelled else {
        return
      }
      startDocumentMonitoringIfNeeded(for: entry)
    }
    .onChange(of: entry?.id) {
      persistActiveDraftIfNeeded()
      isEditorFocused = false
      knownDocumentFingerprint = nil
      onTextInputFocusChange(false)
    }
    .onChange(of: isEditorFocused) {
      onTextInputFocusChange(isEditorFocused)
    }
    .onChange(of: text) {
      persistActiveDraftIfNeeded()
    }
    .onDisappear {
      documentChangeMonitor.stopMonitoring()
      onTextInputFocusChange(false)
    }
  }

  private func editableDocumentSurface(for entry: WorkspaceEntry) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if let saveErrorMessage {
        Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .padding(12)
          .accessibilityIdentifier("document-save-error")
      }

      switch loadState {
      case .empty, .loading:
        // No loading indicator: documents load fast enough that a spinner would
        // only flash. Keep the surface blank until the content is ready.
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ContentUnavailableView {
          Label("Document Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
          Text(message)
        } actions: {
          Button("Try Again") {
            Task {
              await loadSelectedDocumentIfNeeded()
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        TextDocumentEditorView(
          text: $text,
          syntax: WorkspaceTextDocumentSupport.syntax(for: entry) ?? .plainText,
          isReadOnly: entry.isReadOnly,
          accessibilityLabel: "\(entry.name) text",
          onFocusChange: { isFocused in
            isEditorFocused = isFocused
          }
        )
      case .tooLargeForEditing(let url):
        VirtualizedTextDocumentView(
          url: url,
          accessibilityLabel: "\(entry.name) text",
          syntax: WorkspaceTextDocumentSupport.syntax(for: entry) ?? .plainText,
          isEditable: Self.largeFileEditingEnabled && !entry.isReadOnly,
          reloadToken: documentReloadGeneration
        )
      }
    }
  }

  private func documentReloadTrigger(for entry: WorkspaceEntry) -> DocumentReloadTrigger {
    DocumentReloadTrigger(entryID: entry.id, generation: documentReloadGeneration)
  }

  /// Whether the large-file viewer accepts edits. It has no save path yet
  /// (saving, dirty tracking, and external-change conflict handling are a later
  /// slice), so editing is limited to Debug builds for on-device validation;
  /// shipped (Release) builds keep large files read-only until those exist, so
  /// no editable-but-unsaveable surface can reach users.
  private static var largeFileEditingEnabled: Bool {
    #if DEBUG
      return true
    #else
      return false
    #endif
  }

  private var isSaveDisabled: Bool {
    guard case .loaded = loadState,
      let entry,
      !entry.isReadOnly
    else {
      return true
    }

    return text == savedText
  }

  @MainActor
  private func loadSelectedDocumentIfNeeded() async {
    persistActiveDraftIfNeeded()
    saveErrorMessage = nil

    guard let entry, WorkspaceTextDocumentSupport.canEdit(entry) else {
      resetInactiveTextDocument()
      return
    }

    activeDocumentID = entry.id

    if let draft = drafts[entry.id] {
      restoreDraft(draft, for: entry)
      return
    }

    prepareTextDocumentLoad()

    do {
      let document = try await textDocumentStore.loadText(at: entry.url)
      let fingerprint = await DocumentFileFingerprint.load(at: entry.url)
      guard self.entry?.id == entry.id else {
        return
      }

      applyLoadedTextDocument(document, fingerprint: fingerprint)
    } catch TextDocumentStoreError.fileTooLarge {
      guard self.entry?.id == entry.id else {
        return
      }
      // Too large to edit as a string: open it in the virtualized viewer, which
      // streams the visible band from the Rust buffer. In Debug it also edits in
      // place for on-device validation; Release stays read-only until the save /
      // dirty / external-change-conflict slice (see `largeFileEditingEnabled`).
      knownDocumentFingerprint = await DocumentFileFingerprint.load(at: entry.url)
      loadState = .tooLargeForEditing(entry.url)
    } catch {
      guard self.entry?.id == entry.id else {
        return
      }

      loadState = .failed(error.localizedDescription)
    }
  }

  @MainActor
  private func resetInactiveTextDocument() {
    activeDocumentID = nil
    loadState = .empty
    text = ""
    savedText = ""
    encoding = .utf8
    saveErrorMessage = nil
    knownDocumentFingerprint = nil
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

  @MainActor
  private func restoreDraft(_ draft: TextDocumentDraft, for entry: WorkspaceEntry) {
    savedText = draft.savedText
    text = draft.text
    encoding = draft.encoding
    loadState = .loaded
    knownDocumentFingerprint = draft.knownDocumentFingerprint
    Task {
      await syncDisplayedDocumentIfChanged()
    }
  }

  @MainActor
  private func prepareTextDocumentLoad() {
    loadState = .loading
    text = ""
    savedText = ""
    encoding = .utf8
    knownDocumentFingerprint = nil
  }

  @MainActor
  private func applyLoadedTextDocument(
    _ document: TextDocument,
    fingerprint: DocumentFileFingerprint?
  ) {
    savedText = document.text
    text = document.text
    encoding = document.encoding
    knownDocumentFingerprint = fingerprint
    loadState = .loaded
  }

  @MainActor
  private func saveSelectedDocument() {
    guard let entry,
      !isSaveDisabled
    else {
      return
    }

    let textToSave = text
    let encodingToSave = encoding
    Task {
      do {
        try await textDocumentStore.saveText(textToSave, to: entry.url, encoding: encodingToSave)
        guard self.entry?.id == entry.id else {
          return
        }

        let fingerprint = await DocumentFileFingerprint.load(at: entry.url)
        savedText = textToSave
        knownDocumentFingerprint = fingerprint
        drafts.removeValue(forKey: entry.id)
        saveErrorMessage = nil
        loadState = .loaded
      } catch {
        guard self.entry?.id == entry.id else {
          return
        }

        saveErrorMessage = error.localizedDescription
        loadState = .loaded
      }
    }
  }

  @MainActor
  private func persistActiveDraftIfNeeded() {
    guard let activeDocumentID else {
      return
    }

    if text == savedText {
      drafts.removeValue(forKey: activeDocumentID)
    } else {
      drafts[activeDocumentID] = TextDocumentDraft(
        text: text,
        savedText: savedText,
        encoding: encoding,
        knownDocumentFingerprint: knownDocumentFingerprint
          ?? drafts[activeDocumentID]?.knownDocumentFingerprint
      )
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

    if case .tooLargeForEditing = loadState {
      // Read-only large viewer: reopen it on a fresh memory map rather than
      // running the editable string load (which would just fail as too large).
      knownDocumentFingerprint = fingerprint
      documentReloadGeneration &+= 1
    } else if WorkspaceTextDocumentSupport.canEdit(entry) {
      await syncTextDocumentFromDisk(entry, fingerprint: fingerprint)
    } else {
      knownDocumentFingerprint = fingerprint
      documentReloadGeneration &+= 1
    }
  }

  @MainActor
  fileprivate func syncTextDocumentFromDisk(
    _ entry: WorkspaceEntry,
    fingerprint: DocumentFileFingerprint?
  ) async {
    guard activeDocumentID == entry.id else {
      return
    }

    do {
      let document = try await textDocumentStore.loadText(at: entry.url)
      guard self.entry?.id == entry.id, activeDocumentID == entry.id else {
        return
      }

      if text != savedText, document.text == savedText {
        knownDocumentFingerprint = fingerprint
        saveErrorMessage = nil
        return
      }

      applyLoadedTextDocument(document, fingerprint: fingerprint)
      saveErrorMessage = nil
      drafts.removeValue(forKey: entry.id)
    } catch {
      guard self.entry?.id == entry.id, activeDocumentID == entry.id else {
        return
      }

      saveErrorMessage = error.localizedDescription
    }
  }
}

private enum TextDocumentLoadState: Equatable {
  case empty
  case loading
  case loaded
  /// The file exceeds the editable-string size limit; it is shown read-only in
  /// the virtualized viewer instead, opened by URL.
  case tooLargeForEditing(URL)
  case failed(String)
}

private struct DocumentReloadTrigger: Equatable {
  let entryID: String
  let generation: Int
}

private struct TextDocumentDraft: Equatable {
  let text: String
  let savedText: String
  let encoding: String.Encoding
  let knownDocumentFingerprint: DocumentFileFingerprint?
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
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Color.clear
          .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        "This \(WorkspaceFileTypeLabel.displayLabel(for: entry).lowercased()) is not supported yet."
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("document-unsupported-surface")
  }
}
