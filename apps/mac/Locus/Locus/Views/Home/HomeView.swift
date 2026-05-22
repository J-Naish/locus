import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @State private var runtimeStatus: RuntimeStatus = .checking
    @State private var workspaceState: WorkspaceState = .idle
    @State private var selectedEntryID: WorkspaceEntry.ID?
    @State private var isFolderImporterPresented = false
    @State private var didStartInitialFolderLoad = false
    @State private var workspaceRootURL: URL?
    // Folder loads can overlap when users refresh or choose another folder
    // quickly; only the latest generation is allowed to update visible state.
    @State private var workspaceLoadGeneration: UInt64 = 0

    private let coreBridge: CoreBridge
    private let finderService: FinderService
    private let initialFolderURL: URL?

    init(
        coreBridge: CoreBridge = CoreBridge(),
        finderService: FinderService = FinderService(),
        initialFolderURL: URL? = nil
    ) {
        self.coreBridge = coreBridge
        self.finderService = finderService
        self.initialFolderURL = initialFolderURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HeaderView(openFolder: openFolder)
            RuntimeStatusView(status: runtimeStatus)
            WorkspaceContentView(
                state: workspaceState,
                rootURL: workspaceRootURL,
                selectedEntryID: $selectedEntryID,
                openFolder: openFolder,
                refresh: refreshWorkspace,
                openParentFolder: openParentFolder,
                reveal: revealInFinder,
                performOpenAction: performOpenAction
            )
        }
        .padding(28)
        .frame(minWidth: 820, minHeight: 520)
        .task {
            await loadRuntimeStatus()
            loadInitialFolderIfNeeded()
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderImport(result)
        }
        .fileDialogMessage("Choose a folder to browse in Locus.")
        .fileDialogConfirmationLabel("Open Folder")
    }

    @MainActor
    private func loadRuntimeStatus() async {
        do {
            runtimeStatus = .ready(try await coreBridge.runtimeSummary())
        } catch {
            runtimeStatus = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func loadInitialFolderIfNeeded() {
        guard !didStartInitialFolderLoad, let initialFolderURL else {
            return
        }

        didStartInitialFolderLoad = true
        startWorkspaceLoad(initialFolderURL, rootURL: initialFolderURL)
    }

    @MainActor
    private func openFolder() {
        isFolderImporterPresented = true
    }

    @MainActor
    private func refreshWorkspace() {
        guard let folderURL = workspaceState.folderURL else {
            return
        }

        startWorkspaceLoad(folderURL)
    }

    @MainActor
    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let folderURL = urls.first else {
                // .fileImporter reports user cancellation as .success([]) on
                // some macOS versions; leave the current workspace state alone.
                return
            }

            startWorkspaceLoad(folderURL, rootURL: folderURL)
        case let .failure(error):
            // SwiftUI's .fileImporter delivers user cancellation as a Cocoa
            // user-cancelled error or as Swift's CancellationError. Treat both
            // as no-ops so the current state survives a dismissed dialog.
            if Self.isUserCancellationError(error) {
                return
            }

            invalidateWorkspaceLoads()
            selectedEntryID = nil
            workspaceState = .failed(
                folderURL: nil,
                message: error.localizedDescription
            )
        }
    }

    private static func isUserCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        return false
    }

    @MainActor
    private func startWorkspaceLoad(_ folderURL: URL, rootURL: URL? = nil) {
        if let rootURL {
            workspaceRootURL = rootURL
        }

        workspaceLoadGeneration &+= 1
        let generation = workspaceLoadGeneration

        Task {
            await loadWorkspace(folderURL, generation: generation)
        }
    }

    @MainActor
    private func invalidateWorkspaceLoads() {
        workspaceLoadGeneration &+= 1
    }

    @MainActor
    private func loadWorkspace(_ folderURL: URL, generation: UInt64) async {
        guard generation == workspaceLoadGeneration else {
            return
        }

        let previousSelectedEntryID = selectedEntryIDForReload(of: folderURL)
        workspaceState = .loading(folderURL: folderURL)
        // This covers the immediate directory read. Recents and Favorites will
        // store security-scoped bookmarks once sandboxing is enabled.
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let snapshot = try await coreBridge.listDirectory(at: folderURL)
            guard generation == workspaceLoadGeneration else {
                return
            }
            selectedEntryID = snapshot.entries.contains { $0.id == previousSelectedEntryID }
                ? previousSelectedEntryID
                : nil
            workspaceState = .ready(folderURL: folderURL, snapshot: snapshot, loadedAt: Date())
        } catch {
            guard generation == workspaceLoadGeneration else {
                return
            }
            selectedEntryID = nil
            workspaceState = .failed(
                folderURL: folderURL,
                message: error.localizedDescription
            )
        }
    }

    private func revealInFinder(_ entry: WorkspaceEntry) {
        finderService.reveal(entry.url)
    }

    @MainActor
    private func openParentFolder() {
        guard let folderURL = workspaceState.folderURL,
              let parentFolderURL = WorkspaceNavigation.parentFolderURL(
                for: folderURL,
                within: workspaceRootURL
              ) else {
            return
        }

        startWorkspaceLoad(parentFolderURL)
    }

    @MainActor
    private func performOpenAction(_ action: WorkspaceEntryOpenAction) {
        switch action {
        case let .browseFolder(url):
            startWorkspaceLoad(url)
        case let .openExternally(url):
            finderService.openExternally(url)
        }
    }

    @MainActor
    private func selectedEntryIDForReload(of folderURL: URL) -> WorkspaceEntry.ID? {
        guard case .ready = workspaceState,
              workspaceState.folderURL == folderURL else {
            return nil
        }

        return selectedEntryID
    }
}

private struct HeaderView: View {
    let openFolder: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Locus")
                    .font(.title)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)

                Text("Local document workspace")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: openFolder) {
                Label("Open Folder", systemImage: "folder")
            }
            .keyboardShortcut("o", modifiers: [.command])
            .controlSize(.large)
        }
    }
}

private struct RuntimeStatusView: View {
    let status: RuntimeStatus

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .foregroundStyle(status.symbolColor)
                .frame(width: 18)
                .accessibilityHidden(true)

            Text(status.message)
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.message)
    }
}

private struct WorkspaceContentView: View {
    let state: WorkspaceState
    let rootURL: URL?
    @Binding var selectedEntryID: WorkspaceEntry.ID?
    let openFolder: () -> Void
    let refresh: () -> Void
    let openParentFolder: () -> Void
    let reveal: (WorkspaceEntry) -> Void
    let performOpenAction: (WorkspaceEntryOpenAction) -> Void

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyWorkspaceView(openFolder: openFolder)
            case let .loading(folderURL):
                LoadingWorkspaceView(folderURL: folderURL)
            case let .ready(folderURL, snapshot, loadedAt):
                WorkspaceBrowserView(
                    folderURL: folderURL,
                    snapshot: snapshot,
                    loadedAt: loadedAt,
                    rootURL: rootURL,
                    selectedEntryID: $selectedEntryID,
                    refresh: refresh,
                    openParentFolder: openParentFolder,
                    reveal: reveal,
                    performOpenAction: performOpenAction
                )
            case let .failed(folderURL, message):
                WorkspaceErrorView(
                    folderURL: folderURL,
                    message: message,
                    openFolder: openFolder,
                    retry: refresh
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyWorkspaceView: View {
    let openFolder: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Folder Open", systemImage: "folder")
        } description: {
            Text("Choose a folder to browse its immediate contents.")
        } actions: {
            Button(action: openFolder) {
                Label("Open Folder", systemImage: "folder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LoadingWorkspaceView: View {
    let folderURL: URL

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading \(folderURL.lastPathComponent)")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct WorkspaceBrowserView: View {
    let folderURL: URL
    let snapshot: WorkspaceSnapshot
    let loadedAt: Date
    let rootURL: URL?
    @Binding var selectedEntryID: WorkspaceEntry.ID?
    let refresh: () -> Void
    let openParentFolder: () -> Void
    let reveal: (WorkspaceEntry) -> Void
    let performOpenAction: (WorkspaceEntryOpenAction) -> Void
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceToolbarView(
                folderURL: folderURL,
                snapshot: snapshot,
                loadedAt: loadedAt,
                rootURL: rootURL,
                searchQuery: $searchQuery,
                isSearchFocused: $isSearchFocused,
                openParentFolder: openParentFolder,
                refresh: refresh
            )

            if !snapshot.partialErrors.isEmpty {
                PartialErrorsView(errors: snapshot.partialErrors)
            }

            if snapshot.entries.isEmpty {
                ContentUnavailableView(
                    "This Folder Is Empty",
                    systemImage: "folder",
                    description: Text("Files and folders will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleEntries.isEmpty {
                ContentUnavailableView(
                    "No Results",
                    systemImage: "magnifyingglass",
                    description: Text(verbatim: "No items match \"\(searchQuery)\".")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                WorkspaceEntriesTable(
                    entries: visibleEntries,
                    selectedEntryID: $selectedEntryID,
                    reveal: reveal,
                    performOpenAction: performOpenAction
                )
            }
        }
        .onChange(of: searchQuery) {
            clearSelectionIfNeeded()
        }
        .onChange(of: snapshot.entries) {
            clearSelectionIfNeeded()
        }
        .onChange(of: folderURL) {
            searchQuery = ""
        }
        .background(searchShortcut)
    }

    private var visibleEntries: [WorkspaceEntry] {
        WorkspaceEntrySearch.filteredEntries(snapshot.entries, query: searchQuery)
    }

    private func clearSelectionIfNeeded() {
        if !WorkspaceEntrySearch.shouldKeepSelection(selectedEntryID, in: visibleEntries) {
            selectedEntryID = nil
        }
    }

    private var searchShortcut: some View {
        // Keep Command-F local to the mounted browser until Locus has a
        // broader menu command surface.
        Button("Focus Search Field") {
            focusSearchField()
        }
        .keyboardShortcut("f", modifiers: [.command])
        .hidden()
        .accessibilityHidden(true)
    }

    private func focusSearchField() {
        isSearchFocused = true
        DispatchQueue.main.async {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }
}

private struct WorkspaceToolbarView: View {
    let folderURL: URL
    let snapshot: WorkspaceSnapshot
    let loadedAt: Date
    let rootURL: URL?
    @Binding var searchQuery: String
    let isSearchFocused: FocusState<Bool>.Binding
    let openParentFolder: () -> Void
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(folderURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)

                Text(folderURL.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text("\(snapshot.entries.count) items")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(loadedAt, style: .time)
                .font(.callout)
                .foregroundStyle(.secondary)

            Button(action: openParentFolder) {
                Label("Parent Folder", systemImage: "arrow.up")
            }
            .labelStyle(.iconOnly)
            .disabled(parentFolderURL == nil)
            .help(parentFolderHelp)

            TextField("Search", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .focused(isSearchFocused)
                .frame(width: 180)
                .accessibilityLabel("Search files and folders")
                .accessibilityIdentifier("workspace-search-field")

            Button(action: refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .keyboardShortcut("r", modifiers: [.command])
            .help("Refresh")
        }
    }

    private var parentFolderURL: URL? {
        WorkspaceNavigation.parentFolderURL(for: folderURL, within: rootURL)
    }

    private var parentFolderHelp: String {
        guard let parentFolderURL else {
            return "No parent folder"
        }

        let displayName = parentFolderURL.lastPathComponent.isEmpty
            ? parentFolderURL.path(percentEncoded: false)
            : parentFolderURL.lastPathComponent

        return "Open \(displayName)"
    }
}

private struct WorkspaceEntriesTable: View {
    let entries: [WorkspaceEntry]
    @Binding var selectedEntryID: WorkspaceEntry.ID?
    let reveal: (WorkspaceEntry) -> Void
    let performOpenAction: (WorkspaceEntryOpenAction) -> Void

    var body: some View {
        Table(entries, selection: $selectedEntryID) {
            TableColumn("Name") { entry in
                Label {
                    Text(entry.name)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: entry.symbolName)
                        .foregroundStyle(entry.symbolColor)
                }
            }

            TableColumn("Type") { entry in
                Text(entry.typeLabel)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 140)

            TableColumn("Size") { entry in
                Text(entry.sizeLabel)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 80, ideal: 100)

            TableColumn("Modified") { entry in
                Text(entry.modifiedLabel)
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 160)
        }
        .contextMenu(forSelectionType: WorkspaceEntry.ID.self) { selection in
            let selectedEntries = entries(for: selection)
            let openAction = WorkspaceEntryOpenActionResolver.action(for: selectedEntries)

            Button("Open") {
                if let openAction {
                    performOpenAction(openAction)
                }
            }
            .disabled(openAction == nil)

            Button("Reveal in Finder") {
                selectedEntries.forEach(reveal)
            }
            .disabled(selectedEntries.isEmpty)
        } primaryAction: { selection in
            performPrimaryAction(for: selection)
        }
    }

    private func performPrimaryAction(for selection: Set<WorkspaceEntry.ID>) {
        guard let openAction = WorkspaceEntryOpenActionResolver.action(for: entries(for: selection)) else {
            return
        }

        performOpenAction(openAction)
    }

    private func entries(for selection: Set<WorkspaceEntry.ID>) -> [WorkspaceEntry] {
        entries.filter { selection.contains($0.id) }
    }
}

private struct PartialErrorsView: View {
    let errors: [WorkspacePartialError]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary

            if errors.count == 1, let message = errors.first?.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                DisclosureGroup("Show details") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(errors) { error in
                            Text(error.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.08), in: .rect(cornerRadius: 8))
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(summaryTitle)
                .font(.callout)
                .fontWeight(.medium)

            Spacer()
        }
    }

    private var summaryTitle: String {
        if errors.count == 1 {
            return "1 item could not be read"
        }

        return "\(errors.count) items could not be read"
    }
}

private struct WorkspaceErrorView: View {
    let folderURL: URL?
    let message: String
    let openFolder: () -> Void
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Folder Could Not Be Opened", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            HStack {
                if folderURL != nil {
                    Button("Try Again", action: retry)
                }

                Button("Choose Folder", action: openFolder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum RuntimeStatus: Equatable, Sendable {
    case checking
    case ready(CoreRuntimeSummary)
    case failed(String)

    var symbolName: String {
        switch self {
        case .checking:
            return "circle.dotted"
        case .ready:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        }
    }

    var symbolColor: Color {
        switch self {
        case .checking:
            return .secondary
        case .ready:
            return .green
        case .failed:
            return .orange
        }
    }

    var message: String {
        switch self {
        case .checking:
            return "Checking Rust core"
        case let .ready(summary):
            return "Rust core \(summary.coreVersion), ABI \(summary.abiVersion)"
        case let .failed(message):
            return message
        }
    }
}

private enum WorkspaceState: Equatable, Sendable {
    case idle
    case loading(folderURL: URL)
    case ready(folderURL: URL, snapshot: WorkspaceSnapshot, loadedAt: Date)
    case failed(folderURL: URL?, message: String)
}

private extension WorkspaceState {
    var folderURL: URL? {
        switch self {
        case let .loading(folderURL), let .ready(folderURL, _, _), let .failed(folderURL?, _):
            return folderURL
        case .idle, .failed(nil, _):
            return nil
        }
    }
}

private extension WorkspaceEntry {
    static let modifiedDateFormatStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)

    var symbolName: String {
        switch kind {
        case .directory:
            return "folder"
        case .file:
            return fileType.symbolName
        case .symlink:
            return "arrowshape.turn.up.right"
        case .other:
            return "doc"
        }
    }

    var symbolColor: Color {
        switch kind {
        case .directory:
            return .blue
        case .file:
            return .secondary
        case .symlink:
            return .purple
        case .other:
            return .secondary
        }
    }

    var typeLabel: String {
        switch kind {
        case .directory:
            return "Folder"
        case .file:
            return fileType.label
        case .symlink:
            return "Alias"
        case .other:
            return "Other"
        }
    }

    var sizeLabel: String {
        guard let sizeBytes else {
            return "-"
        }

        return Int64(sizeBytes).formatted(.byteCount(style: .file))
    }

    var modifiedLabel: String {
        guard let modified else {
            return "-"
        }

        return modified.formatted(Self.modifiedDateFormatStyle)
    }
}

private extension WorkspaceFileType {
    var label: String {
        switch self {
        case .markdown:
            return "Markdown"
        case .structuredText:
            return "Structured Text"
        case .pdf:
            return "PDF"
        case .office:
            return "Office"
        case .image:
            return "Image"
        case .audio:
            return "Audio"
        case .video:
            return "Video"
        case .plainText:
            return "Text"
        case .code:
            return "Code"
        case .unknown:
            return "File"
        }
    }

    var symbolName: String {
        switch self {
        case .markdown, .structuredText, .plainText:
            return "doc.text"
        case .pdf:
            return "doc.richtext"
        case .office:
            return "doc"
        case .image:
            return "photo"
        case .audio:
            return "waveform"
        case .video:
            return "film"
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .unknown:
            return "doc"
        }
    }
}
