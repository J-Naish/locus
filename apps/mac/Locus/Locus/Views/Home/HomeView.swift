import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    private enum WorkspaceRootChange {
        case preserve
        case set(URL?)
    }

    @State private var workspaceState: WorkspaceState = .idle
    @State private var selectedEntryID: WorkspaceEntry.ID?
    @State private var isFolderImporterPresented = false
    @State private var didStartInitialFolderLoad = false
    @State private var workspaceRootURL: URL?
    @State private var favoriteFolders: [FavoriteFolder] = []
    @State private var recentFiles: [RecentFile] = []
    @State private var recentFolders: [RecentFolder] = []
    // Folder loads can overlap when users refresh or choose another folder
    // quickly; only the latest generation is allowed to update visible state.
    @State private var workspaceLoadGeneration: UInt64 = 0

    private let coreBridge: CoreBridge
    private let quickLookPreviewService: any QuickLookPreviewing
    private let textDocumentStore: any TextDocumentStoring
    private let imageDocumentStore: any ImageDocumentStoring
    private let clipboardService: ClipboardService
    private let workspaceDirectoryMonitor: any WorkspaceDirectoryMonitoring
    private let favoriteFolderStore: FavoriteFolderStore
    private let recentFileStore: RecentFileStore
    private let recentFolderStore: RecentFolderStore
    private let initialFolderResolution: InitialFolderResolution
    private let homeDirectoryURL: URL

    init(
        coreBridge: CoreBridge = CoreBridge(),
        quickLookPreviewService: any QuickLookPreviewing = QuickLookPreviewService(),
        textDocumentStore: any TextDocumentStoring = TextDocumentStore(),
        imageDocumentStore: any ImageDocumentStoring = ImageDocumentStore(),
        clipboardService: ClipboardService = ClipboardService(),
        workspaceDirectoryMonitor: any WorkspaceDirectoryMonitoring = WorkspaceDirectoryMonitor(),
        favoriteFolderStore: FavoriteFolderStore = FavoriteFolderStore(),
        recentFileStore: RecentFileStore = RecentFileStore(),
        recentFolderStore: RecentFolderStore = RecentFolderStore(),
        initialFolderResolution: InitialFolderResolution = .empty,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.coreBridge = coreBridge
        self.quickLookPreviewService = quickLookPreviewService
        self.textDocumentStore = textDocumentStore
        self.imageDocumentStore = imageDocumentStore
        self.clipboardService = clipboardService
        self.workspaceDirectoryMonitor = workspaceDirectoryMonitor
        self.favoriteFolderStore = favoriteFolderStore
        self.recentFileStore = recentFileStore
        self.recentFolderStore = recentFolderStore
        self.initialFolderResolution = initialFolderResolution
        self.homeDirectoryURL = homeDirectoryURL
    }

    var body: some View {
        let shortcutActions = FileLocationShortcutActions(
            openFavoriteFolder: openFavoriteFolder,
            showRecentFile: showRecentFile,
            openRecentFolder: openRecentFolder,
            removeFavoriteFolder: removeFavoriteFolder,
            removeRecentFile: removeRecentFile,
            removeRecentFolder: removeRecentFolder,
            previewFile: previewFile,
            showInLocus: showURLInLocus,
            copyPath: copyPath
        )

        VStack(alignment: .leading, spacing: 16) {
            WorkspaceContentView(
                state: workspaceState,
                rootURL: workspaceRootURL,
                favoriteFolders: favoriteFolders,
                recentFiles: recentFiles,
                recentFolders: recentFolders,
                textDocumentStore: textDocumentStore,
                imageDocumentStore: imageDocumentStore,
                selectedEntryID: $selectedEntryID,
                emptyActions: EmptyWorkspaceActions(
                    openFolder: openFolder,
                    shortcuts: shortcutActions
                ),
                shortcutActions: shortcutActions,
                actions: WorkspaceActions(
                    refresh: refreshWorkspace,
                    openParentFolder: openParentFolder,
                    toggleFavoriteFolder: toggleFavoriteFolder,
                    preview: previewURLs,
                    showInLocus: showEntryInLocus,
                    copyPaths: copyPaths,
                    performOpenAction: performOpenAction
                )
            )
        }
        .padding(28)
        .frame(minWidth: 820, minHeight: 520)
        .task {
            refreshFileLocationShortcuts()
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
        .fileDialogConfirmationLabel("Choose Folder")
    }

    @MainActor
    private func loadInitialFolderIfNeeded() {
        guard !didStartInitialFolderLoad else {
            return
        }

        didStartInitialFolderLoad = true

        guard case let .folder(initialFolderURL) = initialFolderResolution else {
            if initialFolderResolution == .unavailable {
                workspaceState = .failed(
                    folderURL: nil,
                    message: "Locus couldn't open the home folder. Choose another folder to browse in Locus."
                )
            }
            return
        }

        // Normal launch starts in the home folder, but this path must stay a
        // non-recursive immediate-children listing. Do not add startup scans.
        // Auto-opened home is also not a recent item; only explicit user
        // folder choices should be recorded in Recents.
        startWorkspaceLoad(initialFolderURL, rootChange: .set(initialFolderURL))
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

            startWorkspaceLoad(folderURL, rootChange: .set(folderURL), recordRecent: true)
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

    /// `selecting` is matched against loaded entries by standardized path. Use
    /// `rootChange: .set(nil)` for ad hoc locations that should allow normal
    /// parent navigation beyond the first containing folder.
    @MainActor
    private func startWorkspaceLoad(
        _ folderURL: URL,
        rootChange: WorkspaceRootChange = .preserve,
        recordRecent: Bool = false,
        showsLoading: Bool = true,
        selecting selectedURL: URL? = nil
    ) {
        if case let .set(rootURL) = rootChange {
            workspaceRootURL = rootURL
        }

        if showsLoading {
            workspaceDirectoryMonitor.stopMonitoring()
        }
        workspaceLoadGeneration &+= 1
        let generation = workspaceLoadGeneration

        Task {
            await loadWorkspace(
                folderURL,
                generation: generation,
                recordRecent: recordRecent,
                showsLoading: showsLoading,
                selectedURL: selectedURL
            )
        }
    }

    @MainActor
    private func invalidateWorkspaceLoads() {
        workspaceDirectoryMonitor.stopMonitoring()
        workspaceLoadGeneration &+= 1
    }

    @MainActor
    private func loadWorkspace(
        _ folderURL: URL,
        generation: UInt64,
        recordRecent: Bool,
        showsLoading: Bool,
        selectedURL: URL?
    ) async {
        guard generation == workspaceLoadGeneration else {
            return
        }

        let previousSelectedEntryID = selectedEntryIDForReload(of: folderURL)
        if showsLoading {
            workspaceState = .loading(folderURL: folderURL)
        }
        // This covers the immediate directory read. Recents and Favorites will
        // store security-scoped bookmarks once sandboxing is enabled.
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let rawSnapshot = try await coreBridge.listDirectory(at: folderURL)
            let snapshot = await WorkspaceHomeVisibility.filteredSnapshotOffMainActor(
                rawSnapshot,
                folderURL: folderURL,
                homeDirectoryURL: homeDirectoryURL
            )
            guard generation == workspaceLoadGeneration else {
                return
            }
            if let selectedEntryID = entryID(in: snapshot.entries, matching: selectedURL) {
                self.selectedEntryID = selectedEntryID
            } else if snapshot.entries.contains(where: { $0.id == previousSelectedEntryID }) {
                selectedEntryID = previousSelectedEntryID
            } else {
                selectedEntryID = nil
            }
            workspaceState = .ready(folderURL: folderURL, snapshot: snapshot, loadedAt: Date())
            startWorkspaceChangeMonitoring(for: folderURL)
            if recordRecent {
                recentFolderStore.record(folderURL)
                refreshRecentFolders()
            }
        } catch {
            guard generation == workspaceLoadGeneration else {
                return
            }
            workspaceDirectoryMonitor.stopMonitoring()
            selectedEntryID = nil
            pruneRecentFileIfSelectionLoadFailed(selectedURL)
            workspaceState = .failed(
                folderURL: folderURL,
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func previewURLs(_ urls: [URL]) {
        quickLookPreviewService.preview(urls)
    }

    @MainActor
    private func previewFile(_ url: URL) {
        previewURLs([url])
    }

    @MainActor
    private func showURLInLocus(_ url: URL) {
        let standardizedURL = url.standardizedFileURL
        let containingFolderURL = standardizedURL.deletingLastPathComponent()
        if selectURLInCurrentWorkspaceIfPossible(standardizedURL, containingFolderURL: containingFolderURL) {
            return
        }

        startWorkspaceLoad(
            containingFolderURL,
            rootChange: .set(rootURLForShowingInLocus(containing: standardizedURL)),
            selecting: standardizedURL
        )
    }

    @MainActor
    private func showEntryInLocus(_ entry: WorkspaceEntry) {
        showURLInLocus(entry.url)
    }

    @MainActor
    private func openFavoriteFolder(_ folder: FavoriteFolder) {
        startWorkspaceLoad(folder.url, rootChange: .set(folder.url), recordRecent: true)
    }

    @MainActor
    private func showRecentFile(_ file: RecentFile) {
        showURLInLocus(file.url)
    }

    @MainActor
    private func openRecentFolder(_ folder: RecentFolder) {
        startWorkspaceLoad(folder.url, rootChange: .set(folder.url), recordRecent: true)
    }

    @MainActor
    private func refreshFavoriteFolders() {
        favoriteFolders = favoriteFolderStore.favoriteFolders().filter { folder in
            !WorkspaceHomeVisibility.isHiddenHomeURL(folder.url, homeDirectoryURL: homeDirectoryURL)
        }
    }

    @MainActor
    private func refreshRecentFiles() {
        recentFiles = recentFileStore.recentFiles().filter { file in
            !WorkspaceHomeVisibility.isHiddenHomeURL(file.url, homeDirectoryURL: homeDirectoryURL)
        }
    }

    @MainActor
    private func refreshRecentFolders() {
        recentFolders = recentFolderStore.recentFolders().filter { folder in
            !WorkspaceHomeVisibility.isHiddenHomeURL(folder.url, homeDirectoryURL: homeDirectoryURL)
        }
    }

    @MainActor
    private func refreshFileLocationShortcuts() {
        refreshFavoriteFolders()
        refreshRecentFiles()
        refreshRecentFolders()
    }

    @MainActor
    private func toggleFavoriteFolder() {
        guard let folderURL = workspaceState.folderURL else {
            return
        }

        if favoriteFolderStore.contains(folderURL) {
            favoriteFolderStore.remove(folderURL)
        } else {
            favoriteFolderStore.add(folderURL)
        }
        refreshFavoriteFolders()
    }

    @MainActor
    private func removeFavoriteFolder(_ folder: FavoriteFolder) {
        favoriteFolderStore.remove(folder.url)
        refreshFavoriteFolders()
    }

    @MainActor
    private func removeRecentFile(_ file: RecentFile) {
        recentFileStore.remove(file.url)
        refreshRecentFiles()
    }

    @MainActor
    private func removeRecentFolder(_ folder: RecentFolder) {
        recentFolderStore.remove(folder.url)
        refreshRecentFolders()
    }

    @MainActor
    private func copyPaths(_ entries: [WorkspaceEntry]) {
        clipboardService.copyEntryPaths(entries)
    }

    @MainActor
    private func copyPath(_ url: URL) {
        clipboardService.copyPlainText(url.locusStandardizedPath)
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
            startWorkspaceLoad(url, recordRecent: true)
        case let .openInPlace(url):
            showURLInLocus(url)
        case let .preview(url):
            previewFile(url)
        }
    }

    @MainActor
    private func startWorkspaceChangeMonitoring(for folderURL: URL) {
        workspaceDirectoryMonitor.startMonitoring(folderURL) {
            refreshWorkspaceIfStillCurrent(folderURL)
        }
    }

    @MainActor
    private func refreshWorkspaceIfStillCurrent(_ folderURL: URL) {
        guard workspaceState.folderURL?.locusStandardizedPath == folderURL.locusStandardizedPath else {
            return
        }

        startWorkspaceLoad(folderURL, showsLoading: false)
    }

    @MainActor
    private func selectedEntryIDForReload(of folderURL: URL) -> WorkspaceEntry.ID? {
        guard case .ready = workspaceState,
              workspaceState.folderURL == folderURL else {
            return nil
        }

        return selectedEntryID
    }

    private func entryID(
        in entries: [WorkspaceEntry],
        matching selectedURL: URL?
    ) -> WorkspaceEntry.ID? {
        guard let selectedPath = selectedURL?.locusStandardizedPath else {
            return nil
        }

        return entries.first { $0.url.locusStandardizedPath == selectedPath }?.id
    }

    private func rootURLForShowingInLocus(containing url: URL) -> URL? {
        guard let workspaceRootURL,
              url.locusStandardizedPath.locusHasPathPrefix(workspaceRootURL.locusStandardizedPath) else {
            return nil
        }

        return workspaceRootURL
    }

    @MainActor
    private func selectURLInCurrentWorkspaceIfPossible(
        _ url: URL,
        containingFolderURL: URL
    ) -> Bool {
        guard case let .ready(currentFolderURL, snapshot, _) = workspaceState,
              currentFolderURL.locusStandardizedPath == containingFolderURL.locusStandardizedPath,
              let entryID = entryID(in: snapshot.entries, matching: url) else {
            return false
        }

        selectedEntryID = entryID
        return true
    }

    @MainActor
    private func pruneRecentFileIfSelectionLoadFailed(_ selectedURL: URL?) {
        guard let selectedURL else {
            return
        }

        recentFileStore.remove(selectedURL)
        refreshRecentFiles()
    }
}

private struct WorkspaceContentView: View {
    let state: WorkspaceState
    let rootURL: URL?
    let favoriteFolders: [FavoriteFolder]
    let recentFiles: [RecentFile]
    let recentFolders: [RecentFolder]
    let textDocumentStore: any TextDocumentStoring
    let imageDocumentStore: any ImageDocumentStoring
    @Binding var selectedEntryID: WorkspaceEntry.ID?
    let emptyActions: EmptyWorkspaceActions
    let shortcutActions: FileLocationShortcutActions
    let actions: WorkspaceActions

    var body: some View {
        Group {
            switch state {
            case .idle:
                EmptyWorkspaceView(
                    favoriteFolders: favoriteFolders,
                    recentFiles: recentFiles,
                    recentFolders: recentFolders,
                    actions: emptyActions
                )
            case let .loading(folderURL):
                LoadingWorkspaceView(folderURL: folderURL)
            case let .ready(folderURL, snapshot, loadedAt):
                WorkspaceBrowserView(
                    folderURL: folderURL,
                    snapshot: snapshot,
                    loadedAt: loadedAt,
                    rootURL: rootURL,
                    favoriteFolders: favoriteFolders,
                    recentFiles: recentFiles,
                    recentFolders: recentFolders,
                    textDocumentStore: textDocumentStore,
                    imageDocumentStore: imageDocumentStore,
                    isFavorite: favoriteFolders.contains { $0.path == folderURL.locusStandardizedPath },
                    selectedEntryID: $selectedEntryID,
                    shortcutActions: shortcutActions,
                    actions: actions
                )
            case let .failed(folderURL, message):
                WorkspaceErrorView(
                    folderURL: folderURL,
                    message: message,
                    openFolder: emptyActions.openFolder,
                    retry: actions.refresh
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WorkspaceActions {
    let refresh: () -> Void
    let openParentFolder: () -> Void
    let toggleFavoriteFolder: () -> Void
    let preview: ([URL]) -> Void
    let showInLocus: (WorkspaceEntry) -> Void
    let copyPaths: ([WorkspaceEntry]) -> Void
    let performOpenAction: (WorkspaceEntryOpenAction) -> Void
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
    let favoriteFolders: [FavoriteFolder]
    let recentFiles: [RecentFile]
    let recentFolders: [RecentFolder]
    let textDocumentStore: any TextDocumentStoring
    let imageDocumentStore: any ImageDocumentStoring
    let isFavorite: Bool
    @Binding var selectedEntryID: WorkspaceEntry.ID?
    let shortcutActions: FileLocationShortcutActions
    let actions: WorkspaceActions
    @State private var searchQuery = ""
    @State private var searchResults: WorkspaceBrowserSearchResults
    @State private var isDocumentEditorFocused = false
    @FocusState private var isSearchFocused: Bool

    init(
        folderURL: URL,
        snapshot: WorkspaceSnapshot,
        loadedAt: Date,
        rootURL: URL?,
        favoriteFolders: [FavoriteFolder],
        recentFiles: [RecentFile],
        recentFolders: [RecentFolder],
        textDocumentStore: any TextDocumentStoring,
        imageDocumentStore: any ImageDocumentStoring,
        isFavorite: Bool,
        selectedEntryID: Binding<WorkspaceEntry.ID?>,
        shortcutActions: FileLocationShortcutActions,
        actions: WorkspaceActions
    ) {
        self.folderURL = folderURL
        self.snapshot = snapshot
        self.loadedAt = loadedAt
        self.rootURL = rootURL
        self.favoriteFolders = favoriteFolders
        self.recentFiles = recentFiles
        self.recentFolders = recentFolders
        self.textDocumentStore = textDocumentStore
        self.imageDocumentStore = imageDocumentStore
        self.isFavorite = isFavorite
        self._selectedEntryID = selectedEntryID
        self.shortcutActions = shortcutActions
        self.actions = actions
        self._searchResults = State(
            initialValue: WorkspaceBrowserSearchResults.resolve(
                entries: snapshot.entries,
                favoriteFolders: favoriteFolders,
                recentFiles: recentFiles,
                recentFolders: recentFolders,
                query: ""
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WorkspaceToolbarView(
                folderURL: folderURL,
                snapshot: snapshot,
                loadedAt: loadedAt,
                rootURL: rootURL,
                isFavorite: isFavorite,
                searchQuery: $searchQuery,
                isSearchFocused: $isSearchFocused,
                openParentFolder: actions.openParentFolder,
                toggleFavoriteFolder: actions.toggleFavoriteFolder,
                refresh: actions.refresh
            )

            if !snapshot.partialErrors.isEmpty {
                PartialErrorsView(errors: snapshot.partialErrors)
            }

            if searchResults.hasShortcutResults {
                WorkspaceShortcutSearchResultsView(
                    favoriteFolders: searchResults.favoriteFolders,
                    recentFiles: searchResults.recentFiles,
                    recentFolders: searchResults.recentFolders,
                    actions: shortcutActions
                )
            }

            if snapshot.entries.isEmpty {
                ContentUnavailableView(
                    "This Folder Is Empty",
                    systemImage: "folder",
                    description: Text("Files and folders will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: searchResults.hasShortcutResults ? 160 : .infinity)
            } else if searchResults.visibleEntries.isEmpty {
                ContentUnavailableView(
                    "No Current Folder Results",
                    systemImage: "magnifyingglass",
                    description: Text(verbatim: "No items match \"\(searchQuery)\".")
                )
                .frame(maxWidth: .infinity, maxHeight: searchResults.hasShortcutResults ? 160 : .infinity)
            } else {
                HSplitView {
                    WorkspaceEntriesTable(
                        entries: searchResults.visibleEntries,
                        selectedEntryID: $selectedEntryID,
                        isPreviewShortcutEnabled: !isSearchFocused && !isDocumentEditorFocused,
                        actions: actions
                    )
                    .frame(minWidth: 420, idealWidth: 560, maxWidth: .infinity)

                    WorkspaceDocumentSurface(
                        entry: selectedEntry,
                        textDocumentStore: textDocumentStore,
                        imageDocumentStore: imageDocumentStore,
                        preview: actions.preview,
                        onEditorFocusChange: { isFocused in
                            isDocumentEditorFocused = isFocused
                        }
                    )
                    .frame(minWidth: 340, idealWidth: 460)
                }
            }
        }
        .onChange(of: searchQuery) {
            refreshSearchResults()
        }
        .onChange(of: snapshot.entries) {
            refreshSearchResults()
        }
        .onChange(of: favoriteFolders) {
            refreshSearchResults()
        }
        .onChange(of: recentFiles) {
            refreshSearchResults()
        }
        .onChange(of: recentFolders) {
            refreshSearchResults()
        }
        .onChange(of: folderURL) {
            searchQuery = ""
            isDocumentEditorFocused = false
            refreshSearchResults()
        }
        .background(searchShortcut)
    }

    private func refreshSearchResults() {
        let refreshedResults = WorkspaceBrowserSearchResults.resolve(
            entries: snapshot.entries,
            favoriteFolders: favoriteFolders,
            recentFiles: recentFiles,
            recentFolders: recentFolders,
            query: searchQuery
        )
        searchResults = refreshedResults

        if !WorkspaceEntrySearch.shouldKeepSelection(selectedEntryID, in: refreshedResults.visibleEntries) {
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

    private var selectedEntry: WorkspaceEntry? {
        guard let selectedEntryID else {
            return nil
        }

        return searchResults.visibleEntries.first { $0.id == selectedEntryID }
    }
}

struct WorkspaceBrowserSearchResults {
    let visibleEntries: [WorkspaceEntry]
    let favoriteFolders: [FavoriteFolder]
    let recentFiles: [RecentFile]
    let recentFolders: [RecentFolder]

    var hasShortcutResults: Bool {
        !favoriteFolders.isEmpty || !recentFiles.isEmpty || !recentFolders.isEmpty
    }

    static func resolve(
        entries: [WorkspaceEntry],
        favoriteFolders: [FavoriteFolder],
        recentFiles: [RecentFile],
        recentFolders: [RecentFolder],
        query: String
    ) -> WorkspaceBrowserSearchResults {
        let visibleEntries = WorkspaceEntrySearch.filteredEntries(entries, query: query)
        guard WorkspaceEntrySearch.hasSearchTerms(in: query) else {
            return WorkspaceBrowserSearchResults(
                visibleEntries: visibleEntries,
                favoriteFolders: [],
                recentFiles: [],
                recentFolders: []
            )
        }

        let visibleEntryPaths = Set(visibleEntries.map(\.url.locusStandardizedPath))
        let visibleFavoriteFolders = WorkspaceEntrySearch.filteredShortcuts(favoriteFolders, query: query)
        let visibleRecentFiles = WorkspaceEntrySearch.filteredShortcuts(recentFiles, query: query)
            .filter { !visibleEntryPaths.contains($0.path) }
        let visibleRecentFolders = WorkspaceEntrySearch.filteredShortcuts(recentFolders, query: query)

        return WorkspaceBrowserSearchResults(
            visibleEntries: visibleEntries,
            favoriteFolders: visibleFavoriteFolders,
            recentFiles: visibleRecentFiles,
            recentFolders: visibleRecentFolders
        )
    }
}

private struct WorkspaceShortcutSearchResultsView: View {
    let favoriteFolders: [FavoriteFolder]
    let recentFiles: [RecentFile]
    let recentFolders: [RecentFolder]
    let actions: FileLocationShortcutActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !favoriteFolders.isEmpty {
                ShortcutListView(
                    title: "Favorite Folders",
                    rowAccessibilityIdentifier: "workspace-search-favorite-folder-row",
                    items: favoriteFolders,
                    systemImage: "folder",
                    symbolColor: .blue,
                    maxWidth: .infinity,
                    open: actions.openFavoriteFolder,
                    remove: actions.removeFavoriteFolder,
                    showInLocus: actions.showInLocus,
                    copyPath: actions.copyPath
                )
            }

            if !recentFiles.isEmpty {
                ShortcutListView(
                    title: "Recent Files",
                    rowAccessibilityIdentifier: "workspace-search-recent-file-row",
                    items: recentFiles,
                    systemImage: "doc",
                    symbolColor: .secondary,
                    maxWidth: .infinity,
                    open: actions.showRecentFile,
                    remove: actions.removeRecentFile,
                    preview: actions.previewFile,
                    showInLocus: actions.showInLocus,
                    copyPath: actions.copyPath
                )
            }

            if !recentFolders.isEmpty {
                ShortcutListView(
                    title: "Recent Folders",
                    rowAccessibilityIdentifier: "workspace-search-recent-folder-row",
                    items: recentFolders,
                    systemImage: "folder",
                    symbolColor: .blue,
                    maxWidth: .infinity,
                    open: actions.openRecentFolder,
                    remove: actions.removeRecentFolder,
                    showInLocus: actions.showInLocus,
                    copyPath: actions.copyPath
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-shortcut-search-results")
    }
}

private struct WorkspaceToolbarView: View {
    let folderURL: URL
    let snapshot: WorkspaceSnapshot
    let loadedAt: Date
    let rootURL: URL?
    let isFavorite: Bool
    @Binding var searchQuery: String
    let isSearchFocused: FocusState<Bool>.Binding
    let openParentFolder: () -> Void
    let toggleFavoriteFolder: () -> Void
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

            Button(action: toggleFavoriteFolder) {
                Label(favoriteButtonTitle, systemImage: isFavorite ? "star.fill" : "star")
            }
            .labelStyle(.iconOnly)
            .help(favoriteButtonTitle)
            .accessibilityIdentifier("favorite-current-folder-button")

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

    private var favoriteButtonTitle: String {
        isFavorite ? "Remove from Favorites" : "Add to Favorites"
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
    let isPreviewShortcutEnabled: Bool
    let actions: WorkspaceActions

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
            let previewURLs = WorkspaceEntryPreviewActionResolver.previewURLs(for: selectedEntries)
            let showInLocusEntry = selectedEntries.count == 1 ? selectedEntries.first : nil

            Button("Open") {
                if let openAction {
                    actions.performOpenAction(openAction)
                }
            }
            .disabled(openAction == nil)

            Button("Preview") {
                if let previewURLs {
                    actions.preview(previewURLs)
                }
            }
            .disabled(previewURLs == nil)

            Button("Show in Locus") {
                if let showInLocusEntry {
                    actions.showInLocus(showInLocusEntry)
                }
            }
            .disabled(showInLocusEntry == nil)

            Button(WorkspaceEntryPathCopy.menuTitle(for: selectedEntries)) {
                actions.copyPaths(selectedEntries)
            }
            .disabled(selectedEntries.isEmpty)
        } primaryAction: { selection in
            performPrimaryAction(for: selection)
        }
        .background(previewKeyMonitor)
    }

    private func performPrimaryAction(for selection: Set<WorkspaceEntry.ID>) {
        guard let openAction = WorkspaceEntryOpenActionResolver.action(for: entries(for: selection)) else {
            return
        }

        actions.performOpenAction(openAction)
    }

    private func entries(for selection: Set<WorkspaceEntry.ID>) -> [WorkspaceEntry] {
        entries.filter { selection.contains($0.id) }
    }

    private var previewKeyMonitor: some View {
        LocalSpaceKeyMonitor(isEnabled: isPreviewShortcutEnabled && selectedPreviewURLs != nil) {
            guard let selectedPreviewURLs else {
                return false
            }

            actions.preview(selectedPreviewURLs)
            return true
        }
        .frame(width: 0, height: 0)
    }

    private var selectedEntries: [WorkspaceEntry] {
        guard let selectedEntryID else {
            return []
        }

        return entries(for: Set([selectedEntryID]))
    }

    private var selectedPreviewURLs: [URL]? {
        WorkspaceEntryPreviewActionResolver.previewURLs(for: selectedEntries)
    }
}

private struct LocalSpaceKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onSpace: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, onSpace: onSpace)
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onSpace = onSpace
    }

    final class Coordinator {
        private static let spaceKeyCode: UInt16 = 49
        private var monitor: Any?

        var isEnabled: Bool
        var onSpace: () -> Bool

        init(isEnabled: Bool, onSpace: @escaping () -> Bool) {
            self.isEnabled = isEnabled
            self.onSpace = onSpace
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      self.isEnabled,
                      event.keyCode == Self.spaceKeyCode,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                    return event
                }

                return self.onSpace() ? nil : event
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
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
