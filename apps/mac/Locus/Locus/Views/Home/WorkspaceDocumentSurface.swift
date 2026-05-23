import AppKit
import AVKit
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
    @FocusState private var isEditorFocused: Bool

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
            case let .failed(message):
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
                TextEditor(text: $text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused($isEditorFocused)
                    .disabled(entry.isReadOnly)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("\(entry.name) text")
                    .accessibilityIdentifier("document-text-editor")
            }
        }
        .padding(12)
    }

    private var isSaveDisabled: Bool {
        guard case .loaded = loadState,
              let entry,
              !entry.isReadOnly else {
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
              !isSaveDisabled else {
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
            case let .loaded(image):
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
                    .accessibilityLabel("\(entry.name) image")
                    .accessibilityIdentifier("document-image-view")
            case let .failed(message):
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DocumentPreviewHeaderView(entry: entry, detail: "PDF")

            switch loadState {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("document-pdf-loading-indicator")
            case let .loaded(document):
                PDFDocumentView(document: document)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(entry.name) PDF")
                    .accessibilityIdentifier("document-pdf-surface")
            case let .failed(message):
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
            // Re-apply fit-to-window scaling after document swaps.
            pdfView.autoScales = true
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
            case let .loaded(document):
                MediaPlayerView(player: document.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(entry.name) media player")
                    .accessibilityIdentifier(surfaceAccessibilityIdentifier)
            case let .failed(message):
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
        guard case let .loaded(document) = loadState else {
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
            case let .loaded(document):
                QuickLookDocumentView(url: document.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(entry.name) preview")
                    .accessibilityIdentifier("document-quicklook-surface")
            case let .failed(message):
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
        let previewView: QLPreviewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView(frame: .zero)
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
            Text("Use Preview to inspect this \(WorkspaceFileTypeLabel.displayLabel(for: entry).lowercased()).")
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
