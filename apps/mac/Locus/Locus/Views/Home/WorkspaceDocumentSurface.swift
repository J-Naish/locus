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
  let preview: ([URL]) -> Void
  let onEditorFocusChange: (Bool) -> Void

  @State private var loadState: TextDocumentLoadState = .empty
  @State private var text = ""
  @State private var savedText = ""
  @State private var encoding: String.Encoding = .utf8
  @State private var activeDocumentID: WorkspaceEntry.ID?
  @State private var drafts: [WorkspaceEntry.ID: TextDocumentDraft] = [:]
  @State private var saveErrorMessage: String?
  @State private var isEditorFocused = false

  var body: some View {
    Group {
      if let entry {
        switch WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry) {
        case .editableText:
          editableDocumentSurface(for: entry)
        case .image:
          ImageDocumentSurface(
            entry: entry,
            imageDocumentStore: imageDocumentStore,
            preview: preview
          )
        case .pdf:
          PDFDocumentSurface(
            entry: entry,
            pdfDocumentStore: pdfDocumentStore
          )
        case .video, .audio:
          MediaDocumentSurface(
            entry: entry,
            mediaDocumentStore: mediaDocumentStore
          )
        case .quickLookPreview:
          QuickLookDocumentSurface(
            entry: entry,
            quickLookDocumentStore: quickLookDocumentStore
          )
        case .folder:
          FolderDocumentSurface(entry: entry)
        case .unsupported:
          UnsupportedDocumentSurface(entry: entry, preview: preview)
        }
      } else {
        EmptyDocumentSurface()
      }
    }
    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .task(id: entry?.id) {
      await loadSelectedDocumentIfNeeded()
    }
    .onChange(of: entry?.id) {
      isEditorFocused = false
      onEditorFocusChange(false)
    }
    .onChange(of: isEditorFocused) {
      onEditorFocusChange(isEditorFocused)
    }
    .onDisappear {
      onEditorFocusChange(false)
    }
  }

  private func editableDocumentSurface(for entry: WorkspaceEntry) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      DocumentHeaderView(
        entry: entry,
        isDirty: text != savedText,
        isReadOnly: entry.isReadOnly,
        isSaveDisabled: isSaveDisabled,
        save: saveSelectedDocument
      )

      if let saveErrorMessage {
        Label(saveErrorMessage, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("document-save-error")
      }

      switch loadState {
      case .empty, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("document-loading-indicator")
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
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
      }
    }
    .padding(12)
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
      activeDocumentID = nil
      loadState = .empty
      text = ""
      savedText = ""
      encoding = .utf8
      saveErrorMessage = nil
      return
    }

    activeDocumentID = entry.id
    if let draft = drafts[entry.id] {
      text = draft.text
      savedText = draft.savedText
      encoding = draft.encoding
      loadState = .loaded
      return
    }

    loadState = .loading
    text = ""
    savedText = ""
    encoding = .utf8

    do {
      let document = try await textDocumentStore.loadText(at: entry.url)
      guard self.entry?.id == entry.id else {
        return
      }

      text = document.text
      savedText = document.text
      encoding = document.encoding
      loadState = .loaded
    } catch {
      guard self.entry?.id == entry.id else {
        return
      }

      loadState = .failed(error.localizedDescription)
    }
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

        savedText = textToSave
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
        encoding: encoding
      )
    }
  }
}

private enum TextDocumentLoadState: Equatable {
  case empty
  case loading
  case loaded
  case failed(String)
}

private struct TextDocumentDraft: Equatable {
  let text: String
  let savedText: String
  let encoding: String.Encoding
}

private struct DocumentHeaderView: View {
  let entry: WorkspaceEntry
  let isDirty: Bool
  let isReadOnly: Bool
  let isSaveDisabled: Bool
  let save: () -> Void

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.name)
          .font(.headline)
          .lineLimit(1)
          .accessibilityIdentifier("document-title")

        Text(WorkspaceFileTypeLabel.displayLabel(for: entry))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if isReadOnly {
        Text("Read-only")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if isDirty {
        Text("Unsaved")
          .font(.caption)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("document-unsaved-indicator")
      }

      Button("Save", action: save)
        .disabled(isSaveDisabled)
        .keyboardShortcut("s", modifiers: [.command])
        .accessibilityIdentifier("document-save-button")
    }
  }
}

private struct DocumentPreviewHeaderView: View {
  let entry: WorkspaceEntry
  let detail: String

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text(entry.name)
          .font(.headline)
          .lineLimit(1)
          .accessibilityIdentifier("document-title")

        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
  }
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
  let preview: ([URL]) -> Void

  @State private var loadState: ImageDocumentLoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DocumentPreviewHeaderView(entry: entry, detail: "Image")

      switch loadState {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("document-image-loading-indicator")
      case .loaded(let image):
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
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

          Button("Preview") {
            preview([entry.url])
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("document-image-error-surface")
      }
    }
    .padding(12)
    .task(id: entry.id) {
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

  @State private var loadState: PDFDocumentLoadState = .loading
  @StateObject private var controller = PDFDocumentController()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DocumentPreviewHeaderView(entry: entry, detail: "PDF")

      switch loadState {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("document-pdf-loading-indicator")
      case .loaded(let document):
        VStack(spacing: 8) {
          PDFDocumentControlsView(controller: controller)

          PDFDocumentView(
            document: document,
            controller: controller
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
          .accessibilityElement(children: .contain)
          .accessibilityLabel("\(entry.name) PDF")
          .accessibilityIdentifier("document-pdf-surface")
        }
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
    .padding(12)
    .task(id: entry.id) {
      await loadPDF()
    }
  }

  @MainActor
  private func loadPDF() async {
    loadState = .loading
    controller.reset()

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

private struct PDFDocumentControlsView: View {
  @ObservedObject var controller: PDFDocumentController

  var body: some View {
    HStack(spacing: 8) {
      Button {
        controller.goToPreviousPage()
      } label: {
        Image(systemName: "chevron.up")
      }
      .help("Previous Page")
      .disabled(!controller.canGoToPreviousPage)
      .accessibilityLabel("Previous Page")
      .accessibilityIdentifier("document-pdf-previous-page-button")

      Button {
        controller.goToNextPage()
      } label: {
        Image(systemName: "chevron.down")
      }
      .help("Next Page")
      .disabled(!controller.canGoToNextPage)
      .accessibilityLabel("Next Page")
      .accessibilityIdentifier("document-pdf-next-page-button")

      Text(controller.pageSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityIdentifier("document-pdf-page-summary")

      Spacer()

      Button {
        controller.zoomOut()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .help("Zoom Out")
      .disabled(!controller.canZoomOut)
      .accessibilityLabel("Zoom Out")
      .accessibilityIdentifier("document-pdf-zoom-out-button")

      Button {
        controller.fitToWindow()
      } label: {
        Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
      }
      .help("Fit")
      .accessibilityLabel("Fit")
      .accessibilityIdentifier("document-pdf-fit-button")

      Button {
        controller.zoomIn()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .help("Zoom In")
      .disabled(!controller.canZoomIn)
      .accessibilityLabel("Zoom In")
      .accessibilityIdentifier("document-pdf-zoom-in-button")

      Text(controller.zoomSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(minWidth: 44, alignment: .trailing)
        .accessibilityIdentifier("document-pdf-zoom-summary")
    }
    .controlSize(.small)
  }
}

@MainActor
private final class PDFDocumentController: ObservableObject {
  @Published private(set) var currentPageNumber = 0
  @Published private(set) var pageCount = 0
  @Published private(set) var zoomPercent: Int?
  @Published private(set) var canGoToPreviousPage = false
  @Published private(set) var canGoToNextPage = false
  @Published private(set) var canZoomIn = false
  @Published private(set) var canZoomOut = false

  private static let zoomLevels: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]
  private static let zoomComparisonEpsilon: CGFloat = 0.001

  private weak var pdfView: PDFView?
  private var isFitToWindow = true

  var pageSummary: String {
    guard pageCount > 0 else {
      return "No pages"
    }

    guard currentPageNumber > 0 else {
      return "Loading..."
    }

    return "Page \(currentPageNumber) of \(pageCount)"
  }

  var zoomSummary: String {
    guard let zoomPercent else {
      return "Fit"
    }

    return isFitToWindow ? "Fit" : "\(zoomPercent)%"
  }

  func reset() {
    pdfView = nil
    setIfChanged(&currentPageNumber, 0)
    setIfChanged(&pageCount, 0)
    setIfChanged(&zoomPercent, nil)
    setIfChanged(&canGoToPreviousPage, false)
    setIfChanged(&canGoToNextPage, false)
    setIfChanged(&canZoomIn, false)
    setIfChanged(&canZoomOut, false)
    isFitToWindow = true
  }

  func attach(_ pdfView: PDFView) {
    self.pdfView = pdfView
  }

  func refresh(from pdfView: PDFView) {
    self.pdfView = pdfView

    let document = pdfView.document
    let nextPageCount = document?.pageCount ?? 0

    let nextCurrentPageNumber: Int
    if let document, let currentPage = pdfView.currentPage {
      nextCurrentPageNumber = document.index(for: currentPage) + 1
    } else {
      nextCurrentPageNumber = 0
    }

    let scaleFactor = pdfView.scaleFactor
    setIfChanged(&pageCount, nextPageCount)
    setIfChanged(&currentPageNumber, nextCurrentPageNumber)
    setIfChanged(&zoomPercent, Int((scaleFactor * 100).rounded()))
    setIfChanged(&canGoToPreviousPage, nextCurrentPageNumber > 1)
    setIfChanged(&canGoToNextPage, nextPageCount > 0 && nextCurrentPageNumber < nextPageCount)
    setIfChanged(&canZoomIn, nextZoomLevel(after: scaleFactor, in: pdfView) != nil)
    setIfChanged(&canZoomOut, previousZoomLevel(before: scaleFactor, in: pdfView) != nil)
  }

  func goToPreviousPage() {
    guard let pdfView else {
      return
    }

    pdfView.goToPreviousPage(nil)
    refresh(from: pdfView)
  }

  func goToNextPage() {
    guard let pdfView else {
      return
    }

    pdfView.goToNextPage(nil)
    refresh(from: pdfView)
  }

  func zoomIn() {
    guard let pdfView, let zoomLevel = nextZoomLevel(after: pdfView.scaleFactor, in: pdfView) else {
      return
    }

    setManualZoom(zoomLevel, in: pdfView)
  }

  func zoomOut() {
    guard let pdfView, let zoomLevel = previousZoomLevel(before: pdfView.scaleFactor, in: pdfView)
    else {
      return
    }

    setManualZoom(zoomLevel, in: pdfView)
  }

  func fitToWindow() {
    guard let pdfView else {
      return
    }

    isFitToWindow = true
    pdfView.autoScales = true
    refresh(from: pdfView)
  }

  private func setManualZoom(_ scaleFactor: CGFloat, in pdfView: PDFView) {
    isFitToWindow = false
    pdfView.autoScales = false
    pdfView.scaleFactor = scaleFactor
    refresh(from: pdfView)
  }

  private func nextZoomLevel(after scaleFactor: CGFloat, in pdfView: PDFView) -> CGFloat? {
    let maximumZoom = min(Self.zoomLevels.last ?? pdfView.maxScaleFactor, pdfView.maxScaleFactor)
    return Self.zoomLevels.first {
      $0 > scaleFactor + Self.zoomComparisonEpsilon
        && $0 <= maximumZoom + Self.zoomComparisonEpsilon
    }
  }

  private func previousZoomLevel(before scaleFactor: CGFloat, in pdfView: PDFView) -> CGFloat? {
    let minimumZoom = max(Self.zoomLevels.first ?? pdfView.minScaleFactor, pdfView.minScaleFactor)
    return Self.zoomLevels.reversed().first {
      $0 < scaleFactor - Self.zoomComparisonEpsilon
        && $0 >= minimumZoom - Self.zoomComparisonEpsilon
    }
  }

  private func setIfChanged<Value: Equatable>(_ value: inout Value, _ nextValue: Value) {
    if value != nextValue {
      value = nextValue
    }
  }
}

@MainActor
private struct PDFDocumentView: NSViewRepresentable {
  let document: PDFDocument
  @ObservedObject var controller: PDFDocumentController

  func makeNSView(context: Context) -> PDFView {
    let pdfView = PDFView()
    pdfView.autoScales = true
    pdfView.displayMode = .singlePageContinuous
    pdfView.displayDirection = .vertical
    pdfView.backgroundColor = .clear
    pdfView.setAccessibilityIdentifier("document-pdf-view")
    context.coordinator.observe(pdfView, controller: controller)
    return pdfView
  }

  func updateNSView(_ pdfView: PDFView, context: Context) {
    context.coordinator.observe(pdfView, controller: controller)
    controller.attach(pdfView)

    if pdfView.document !== document {
      pdfView.document = document
      // Re-apply fit-to-window scaling after document swaps.
      pdfView.autoScales = true
    }

    context.coordinator.scheduleRefresh(from: pdfView)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class Coordinator: NSObject {
    private weak var observedPDFView: PDFView?
    private weak var controller: PDFDocumentController?

    func observe(_ pdfView: PDFView, controller: PDFDocumentController) {
      self.controller = controller

      guard observedPDFView !== pdfView else {
        return
      }

      if let observedPDFView {
        NotificationCenter.default.removeObserver(
          self,
          name: Notification.Name.PDFViewPageChanged,
          object: observedPDFView
        )
        NotificationCenter.default.removeObserver(
          self,
          name: Notification.Name.PDFViewScaleChanged,
          object: observedPDFView
        )
      }

      observedPDFView = pdfView
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(pdfViewPageChanged(_:)),
        name: Notification.Name.PDFViewPageChanged,
        object: pdfView
      )
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(pdfViewScaleChanged(_:)),
        name: Notification.Name.PDFViewScaleChanged,
        object: pdfView
      )
    }

    func scheduleRefresh(from pdfView: PDFView) {
      let controller = controller
      Task { @MainActor [weak controller, weak pdfView] in
        guard let controller, let pdfView else {
          return
        }

        controller.refresh(from: pdfView)
      }
    }

    @objc private func pdfViewPageChanged(_ notification: Notification) {
      guard let pdfView = notification.object as? PDFView else {
        return
      }

      scheduleRefresh(from: pdfView)
    }

    @objc private func pdfViewScaleChanged(_ notification: Notification) {
      guard let pdfView = notification.object as? PDFView else {
        return
      }

      scheduleRefresh(from: pdfView)
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }
  }
}

private struct MediaDocumentSurface: View {
  let entry: WorkspaceEntry
  let mediaDocumentStore: any MediaDocumentStoring

  @State private var loadState: MediaDocumentLoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DocumentPreviewHeaderView(
        entry: entry,
        detail: WorkspaceFileTypeLabel.displayLabel(for: entry)
      )

      switch loadState {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("document-media-loading-indicator")
      case .loaded(let document):
        MediaPlayerView(player: document.player)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
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
    .padding(12)
    .task(id: entry.id) {
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

  @State private var loadState: QuickLookDocumentLoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DocumentPreviewHeaderView(
        entry: entry,
        detail: WorkspaceFileTypeLabel.displayLabel(for: entry)
      )

      switch loadState {
      case .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .accessibilityIdentifier("document-quicklook-loading-indicator")
      case .loaded(let document):
        QuickLookDocumentView(url: document.url)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
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
    .padding(12)
    .task(id: entry.id) {
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
  let preview: ([URL]) -> Void

  var body: some View {
    ContentUnavailableView {
      Label("No Built-In Preview", systemImage: "doc")
    } description: {
      Text(
        "Use Preview to inspect this \(WorkspaceFileTypeLabel.displayLabel(for: entry).lowercased())."
      )
    } actions: {
      Button("Preview") {
        preview([entry.url])
      }
      .disabled(entry.kind != .file && entry.kind != .symlink)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("document-unsupported-surface")
  }
}
