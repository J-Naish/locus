import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
  private enum WorkspaceRootChange {
    case preserve
    case set(URL?)
  }

  private struct WorkspaceLoadFailureRecovery {
    let state: WorkspaceState
    let selectedEntryID: WorkspaceEntry.ID?
    let rootURL: URL?
  }

  private struct WorkspaceLoadRequest {
    let folderURL: URL
    var rootChange: WorkspaceRootChange = .preserve
    var recordRecent = false
    var showsLoading = true
    var selectedURL: URL?
    var restoreOnFailure: WorkspaceLoadFailureRecovery?
    var onSuccess: (() -> Void)?
  }

  private enum WorkspaceLoadingIndicator {
    // Folder listings that finish inside this threshold feel instant; slower
    // loads need feedback so the app does not appear stuck.
    static let delay: Duration = .milliseconds(150)
  }

  private enum InitialFolderFailure {
    static let homeUnavailableMessage =
      "Locus couldn't open the home folder. Choose another folder to browse in Locus."
  }

  @State private var workspaceState: WorkspaceState
  @State private var selectedEntryID: WorkspaceEntry.ID?
  @State private var isFolderImporterPresented = false
  @State private var didStartInitialFolderLoad = false
  @State private var workspaceRootURL: URL?
  @State private var navigationHistory = WorkspaceNavigationHistory()
  @State private var recentFiles: [RecentFile] = []
  @State private var recentFolders: [RecentFolder] = []
  // Folder loads can overlap when the directory monitor reloads or users
  // choose another folder.
  // quickly; only the latest generation is allowed to update visible state.
  @State private var workspaceLoadGeneration: UInt64 = 0
  @State private var workspaceLoadingIndicatorTask: Task<Void, Never>?

  private let coreBridge: CoreBridge
  private let textDocumentStore: any TextDocumentStoring
  private let imageDocumentStore: any ImageDocumentStoring
  private let pdfDocumentStore: any PDFDocumentStoring
  private let mediaDocumentStore: any MediaDocumentStoring
  private let quickLookDocumentStore: any QuickLookDocumentStoring
  private let clipboardService: ClipboardService
  private let workspaceDirectoryMonitor: any WorkspaceDirectoryMonitoring
  private let recentFileStore: RecentFileStore
  private let recentFolderStore: RecentFolderStore
  private let initialFolderResolution: InitialFolderResolution
  private let homeDirectoryURL: URL

  init(
    coreBridge: CoreBridge = CoreBridge(),
    textDocumentStore: any TextDocumentStoring = TextDocumentStore(),
    imageDocumentStore: any ImageDocumentStoring = ImageDocumentStore(),
    pdfDocumentStore: any PDFDocumentStoring = PDFDocumentStore(),
    mediaDocumentStore: any MediaDocumentStoring = MediaDocumentStore(),
    quickLookDocumentStore: any QuickLookDocumentStoring = QuickLookDocumentStore(),
    clipboardService: ClipboardService = ClipboardService(),
    workspaceDirectoryMonitor: any WorkspaceDirectoryMonitoring = WorkspaceDirectoryMonitor(),
    recentFileStore: RecentFileStore = RecentFileStore(),
    recentFolderStore: RecentFolderStore = RecentFolderStore(),
    initialFolderResolution: InitialFolderResolution = .empty,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.coreBridge = coreBridge
    self.textDocumentStore = textDocumentStore
    self.imageDocumentStore = imageDocumentStore
    self.pdfDocumentStore = pdfDocumentStore
    self.mediaDocumentStore = mediaDocumentStore
    self.quickLookDocumentStore = quickLookDocumentStore
    self.clipboardService = clipboardService
    self.workspaceDirectoryMonitor = workspaceDirectoryMonitor
    self.recentFileStore = recentFileStore
    self.recentFolderStore = recentFolderStore
    self.initialFolderResolution = initialFolderResolution
    self.homeDirectoryURL = homeDirectoryURL
    self._workspaceState = State(
      initialValue: Self.initialWorkspaceState(for: initialFolderResolution))
  }

  var body: some View {
    let shortcutActions = FileLocationShortcutActions(
      showRecentFile: showRecentFile,
      openRecentFolder: openRecentFolder,
      removeRecentFile: removeRecentFile,
      removeRecentFolder: removeRecentFolder,
      copyPath: copyPath
    )

    WorkspaceContentView(
      state: workspaceState,
      rootURL: workspaceRootURL,
      recentFiles: recentFiles,
      recentFolders: recentFolders,
      textDocumentStore: textDocumentStore,
      imageDocumentStore: imageDocumentStore,
      pdfDocumentStore: pdfDocumentStore,
      mediaDocumentStore: mediaDocumentStore,
      quickLookDocumentStore: quickLookDocumentStore,
      selectedEntryID: $selectedEntryID,
      emptyActions: EmptyWorkspaceActions(
        openFolder: openFolder,
        shortcuts: shortcutActions
      ),
      shortcutActions: shortcutActions,
      actions: WorkspaceActions(
        canGoBack: navigationHistory.canGoBack,
        canGoForward: navigationHistory.canGoForward,
        goBack: restorePreviousWorkspaceFolder,
        goForward: restoreNextWorkspaceFolder,
        retryCurrentFolder: retryCurrentFolder,
        copyPaths: copyPaths,
        loadFolderChildren: loadSidebarFolderChildren,
        performOpenAction: performOpenAction
      )
    )
    .frame(
      minWidth: LocusWindowMetrics.minimumWidth,
      minHeight: LocusWindowMetrics.minimumHeight
    )
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

    switch initialFolderResolution {
    case .empty, .unavailable:
      return
    case .folder(let initialFolderURL):
      // Normal launch starts in the home folder, but this path must stay a
      // non-recursive immediate-children listing. Do not add startup scans.
      // Auto-opened home is also not a recent item; only explicit user
      // folder choices should be recorded in Recents.
      startWorkspaceLoad(
        WorkspaceLoadRequest(folderURL: initialFolderURL, rootChange: .set(initialFolderURL)))
    }
  }

  @MainActor
  private func openFolder() {
    isFolderImporterPresented = true
  }

  @MainActor
  private func retryCurrentFolder() {
    guard let folderURL = workspaceState.folderURL else {
      return
    }

    startWorkspaceLoad(WorkspaceLoadRequest(folderURL: folderURL))
  }

  @MainActor
  private func handleFolderImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let folderURL = urls.first else {
        // .fileImporter reports user cancellation as .success([]) on
        // some macOS versions; leave the current workspace state alone.
        return
      }

      navigateToWorkspaceFolder(folderURL, rootChange: .set(folderURL), recordRecent: true)
    case .failure(let error):
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

  private static func initialWorkspaceState(
    for initialFolderResolution: InitialFolderResolution
  ) -> WorkspaceState {
    switch initialFolderResolution {
    case .empty:
      return .idle
    case .folder:
      return .awaitingInitialLoad
    case .unavailable:
      return .failed(
        folderURL: nil,
        message: InitialFolderFailure.homeUnavailableMessage
      )
    }
  }

  /// `request.selectedURL` is matched against loaded entries by standardized
  /// path. Use `request.rootChange: .set(nil)` for ad hoc locations that
  /// should allow normal parent navigation beyond the first containing folder.
  @MainActor
  private func startWorkspaceLoad(
    _ request: WorkspaceLoadRequest
  ) {
    if case .set(let rootURL) = request.rootChange {
      workspaceRootURL = rootURL
    }

    workspaceLoadGeneration &+= 1
    let generation = workspaceLoadGeneration

    if request.showsLoading {
      workspaceDirectoryMonitor.stopMonitoring()
      scheduleWorkspaceLoadingIndicator(for: request.folderURL, generation: generation)
    } else {
      cancelWorkspaceLoadingIndicator()
    }

    Task {
      await loadWorkspace(
        request,
        generation: generation
      )
    }
  }

  @MainActor
  private func invalidateWorkspaceLoads() {
    workspaceDirectoryMonitor.stopMonitoring()
    workspaceLoadGeneration &+= 1
    cancelWorkspaceLoadingIndicator()
  }

  @MainActor
  private func scheduleWorkspaceLoadingIndicator(for folderURL: URL, generation: UInt64) {
    workspaceLoadingIndicatorTask?.cancel()
    workspaceLoadingIndicatorTask = Task { @MainActor in
      do {
        try await Task.sleep(for: WorkspaceLoadingIndicator.delay)
      } catch {
        return
      }

      guard !Task.isCancelled, generation == workspaceLoadGeneration else {
        return
      }

      workspaceState = .loading(folderURL: folderURL)
      workspaceLoadingIndicatorTask = nil
    }
  }

  @MainActor
  private func cancelWorkspaceLoadingIndicator() {
    workspaceLoadingIndicatorTask?.cancel()
    workspaceLoadingIndicatorTask = nil
  }

  /// Triggers a user-initiated folder change and records it in browser-style
  /// history. Use `startWorkspaceLoad` directly for monitor-driven reloads and restores.
  @MainActor
  private func navigateToWorkspaceFolder(
    _ folderURL: URL,
    rootChange: WorkspaceRootChange = .preserve,
    recordRecent: Bool = false,
    selecting selectedURL: URL? = nil
  ) {
    let currentEntry = currentHistoryEntry()
    let destinationEntry = WorkspaceHistoryEntry(
      folderURL: folderURL,
      rootURL: rootURL(after: rootChange),
      selectedURL: selectedURL
    )

    let request = WorkspaceLoadRequest(
      folderURL: folderURL,
      rootChange: rootChange,
      recordRecent: recordRecent,
      selectedURL: selectedURL,
      onSuccess: {
        recordCompletedNavigation(from: currentEntry, to: destinationEntry)
      }
    )
    startWorkspaceLoad(request)
  }

  @MainActor
  private func restorePreviousWorkspaceFolder() {
    guard let currentEntry = currentHistoryEntry(),
      let previousEntry = navigationHistory.previousEntry
    else {
      return
    }

    restoreWorkspaceHistoryEntry(previousEntry) {
      navigationHistory.commitBackNavigation(from: currentEntry)
    }
  }

  @MainActor
  private func restoreNextWorkspaceFolder() {
    guard let currentEntry = currentHistoryEntry(),
      let nextEntry = navigationHistory.nextEntry
    else {
      return
    }

    restoreWorkspaceHistoryEntry(nextEntry) {
      navigationHistory.commitForwardNavigation(from: currentEntry)
    }
  }

  @MainActor
  private func restoreWorkspaceHistoryEntry(
    _ entry: WorkspaceHistoryEntry,
    onSuccess: @escaping () -> Void
  ) {
    startWorkspaceLoad(
      WorkspaceLoadRequest(
        folderURL: entry.folderURL,
        rootChange: .set(entry.rootURL),
        selectedURL: entry.selectedURL,
        restoreOnFailure: WorkspaceLoadFailureRecovery(
          state: workspaceState,
          selectedEntryID: selectedEntryID,
          rootURL: workspaceRootURL
        ),
        onSuccess: onSuccess
      )
    )
  }

  @MainActor
  private func recordCompletedNavigation(
    from current: WorkspaceHistoryEntry?,
    to destination: WorkspaceHistoryEntry
  ) {
    guard currentHistoryEntry()?.hasSameLocation(as: destination) == true else {
      return
    }

    navigationHistory.recordNavigation(from: current, to: destination)
  }

  @MainActor
  private func currentHistoryEntry() -> WorkspaceHistoryEntry? {
    guard case .ready(let folderURL, let snapshot, _) = workspaceState else {
      return nil
    }

    return WorkspaceHistoryEntry(
      folderURL: folderURL,
      rootURL: workspaceRootURL,
      selectedURL: selectedEntryURL(in: snapshot)
    )
  }

  private func selectedEntryURL(in snapshot: WorkspaceSnapshot) -> URL? {
    guard let selectedEntryID else {
      return nil
    }

    return snapshot.entries.first { $0.id == selectedEntryID }?.url
  }

  @MainActor
  private func rootURL(after rootChange: WorkspaceRootChange) -> URL? {
    switch rootChange {
    case .preserve:
      workspaceRootURL
    case .set(let rootURL):
      rootURL
    }
  }

  @MainActor
  private func loadWorkspace(
    _ request: WorkspaceLoadRequest,
    generation: UInt64
  ) async {
    guard generation == workspaceLoadGeneration else {
      return
    }

    let folderURL = request.folderURL
    let previousSelectedEntryID = selectedEntryIDForReload(of: folderURL)
    // This covers the immediate directory read. Recents will store
    // security-scoped bookmarks once sandboxing is enabled.
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
      cancelWorkspaceLoadingIndicator()
      if let selectedEntryID = entryID(in: snapshot.entries, matching: request.selectedURL) {
        self.selectedEntryID = selectedEntryID
      } else if previousSelectedEntryID == WorkspaceEntry.workspaceRoot(at: folderURL).id {
        selectedEntryID = previousSelectedEntryID
      } else if snapshot.entries.contains(where: { $0.id == previousSelectedEntryID }) {
        selectedEntryID = previousSelectedEntryID
      } else {
        selectedEntryID = nil
      }
      workspaceState = .ready(folderURL: folderURL, snapshot: snapshot, loadedAt: Date())
      startWorkspaceChangeMonitoring(for: folderURL)
      if request.recordRecent {
        recentFolderStore.record(folderURL)
        refreshRecentFolders()
      }
      request.onSuccess?()
    } catch {
      guard generation == workspaceLoadGeneration else {
        return
      }
      cancelWorkspaceLoadingIndicator()
      workspaceDirectoryMonitor.stopMonitoring()
      if let restoreOnFailure = request.restoreOnFailure {
        workspaceState = restoreOnFailure.state
        selectedEntryID = restoreOnFailure.selectedEntryID
        workspaceRootURL = restoreOnFailure.rootURL
        if let folderURL = restoreOnFailure.state.folderURL {
          startWorkspaceChangeMonitoring(for: folderURL)
        }
        return
      }
      selectedEntryID = nil
      pruneRecentFileIfSelectionLoadFailed(request.selectedURL)
      workspaceState = .failed(
        folderURL: folderURL,
        message: error.localizedDescription
      )
    }
  }

  @MainActor
  private func navigateToFile(_ url: URL) {
    let standardizedURL = url.standardizedFileURL
    let containingFolderURL = standardizedURL.deletingLastPathComponent()
    if selectURLInCurrentWorkspaceIfPossible(
      standardizedURL, containingFolderURL: containingFolderURL)
    {
      return
    }

    navigateToWorkspaceFolder(
      containingFolderURL,
      rootChange: .set(rootURLContainingFile(standardizedURL)),
      selecting: standardizedURL
    )
  }

  @MainActor
  private func showRecentFile(_ file: RecentFile) {
    navigateToFile(file.url)
  }

  @MainActor
  private func openRecentFolder(_ folder: RecentFolder) {
    navigateToWorkspaceFolder(folder.url, rootChange: .set(folder.url), recordRecent: true)
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
    refreshRecentFiles()
    refreshRecentFolders()
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
  private func loadSidebarFolderChildren(_ folderURL: URL) async throws -> WorkspaceSnapshot {
    let didStartAccess = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        folderURL.stopAccessingSecurityScopedResource()
      }
    }

    let rawSnapshot = try await coreBridge.listDirectory(at: folderURL)
    return await WorkspaceHomeVisibility.filteredSnapshotOffMainActor(
      rawSnapshot,
      folderURL: folderURL,
      homeDirectoryURL: homeDirectoryURL
    )
  }

  @MainActor
  private func performOpenAction(_ action: WorkspaceEntryOpenAction) {
    switch action {
    case .browseFolder(let url):
      navigateToWorkspaceFolder(url, recordRecent: true)
    case .openInPlace(let url):
      navigateToFile(url)
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

    startWorkspaceLoad(WorkspaceLoadRequest(folderURL: folderURL, showsLoading: false))
  }

  @MainActor
  private func selectedEntryIDForReload(of folderURL: URL) -> WorkspaceEntry.ID? {
    guard case .ready = workspaceState,
      workspaceState.folderURL == folderURL
    else {
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

  private func rootURLContainingFile(_ url: URL) -> URL? {
    guard let workspaceRootURL,
      url.locusStandardizedPath.locusHasPathPrefix(workspaceRootURL.locusStandardizedPath)
    else {
      return nil
    }

    return workspaceRootURL
  }

  @MainActor
  private func selectURLInCurrentWorkspaceIfPossible(
    _ url: URL,
    containingFolderURL: URL
  ) -> Bool {
    guard case .ready(let currentFolderURL, let snapshot, _) = workspaceState,
      currentFolderURL.locusStandardizedPath == containingFolderURL.locusStandardizedPath,
      let entryID = entryID(in: snapshot.entries, matching: url)
    else {
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
  let recentFiles: [RecentFile]
  let recentFolders: [RecentFolder]
  let textDocumentStore: any TextDocumentStoring
  let imageDocumentStore: any ImageDocumentStoring
  let pdfDocumentStore: any PDFDocumentStoring
  let mediaDocumentStore: any MediaDocumentStoring
  let quickLookDocumentStore: any QuickLookDocumentStoring
  @Binding var selectedEntryID: WorkspaceEntry.ID?
  let emptyActions: EmptyWorkspaceActions
  let shortcutActions: FileLocationShortcutActions
  let actions: WorkspaceActions

  var body: some View {
    Group {
      switch state {
      case .awaitingInitialLoad:
        Color.clear
          .accessibilityIdentifier("workspace-awaiting-initial-load")
      case .idle:
        EmptyWorkspaceView(
          recentFiles: recentFiles,
          recentFolders: recentFolders,
          actions: emptyActions
        )
      case .loading:
        LoadingWorkspaceView()
      case .ready(let folderURL, let snapshot, let loadedAt):
        WorkspaceBrowserView(
          folderURL: folderURL,
          snapshot: snapshot,
          loadedAt: loadedAt,
          rootURL: rootURL,
          recentFiles: recentFiles,
          recentFolders: recentFolders,
          textDocumentStore: textDocumentStore,
          imageDocumentStore: imageDocumentStore,
          pdfDocumentStore: pdfDocumentStore,
          mediaDocumentStore: mediaDocumentStore,
          quickLookDocumentStore: quickLookDocumentStore,
          selectedEntryID: $selectedEntryID,
          shortcutActions: shortcutActions,
          actions: actions
        )
      case .failed(let folderURL, let message):
        WorkspaceErrorView(
          folderURL: folderURL,
          message: message,
          openFolder: emptyActions.openFolder,
          retry: actions.retryCurrentFolder
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct WorkspaceActions {
  let canGoBack: Bool
  let canGoForward: Bool
  let goBack: () -> Void
  let goForward: () -> Void
  let retryCurrentFolder: () -> Void
  let copyPaths: ([WorkspaceEntry]) -> Void
  let loadFolderChildren: (URL) async throws -> WorkspaceSnapshot
  let performOpenAction: (WorkspaceEntryOpenAction) -> Void
}

private struct LoadingWorkspaceView: View {
  var body: some View {
    VStack(spacing: 12) {
      ProgressView()
      Text("Loading...")
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
  let recentFiles: [RecentFile]
  let recentFolders: [RecentFolder]
  let textDocumentStore: any TextDocumentStoring
  let imageDocumentStore: any ImageDocumentStoring
  let pdfDocumentStore: any PDFDocumentStoring
  let mediaDocumentStore: any MediaDocumentStoring
  let quickLookDocumentStore: any QuickLookDocumentStoring
  @Binding var selectedEntryID: WorkspaceEntry.ID?
  let shortcutActions: FileLocationShortcutActions
  let actions: WorkspaceActions
  @State private var searchQuery = ""
  @State private var searchResults: WorkspaceBrowserSearchResults
  @State private var sidebarVisibleEntries: [WorkspaceEntry]
  @State private var isDocumentTextInputFocused = false
  @State private var documentTabs: [WorkspaceDocumentTab] = []
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  init(
    folderURL: URL,
    snapshot: WorkspaceSnapshot,
    loadedAt: Date,
    rootURL: URL?,
    recentFiles: [RecentFile],
    recentFolders: [RecentFolder],
    textDocumentStore: any TextDocumentStoring,
    imageDocumentStore: any ImageDocumentStoring,
    pdfDocumentStore: any PDFDocumentStoring,
    mediaDocumentStore: any MediaDocumentStoring,
    quickLookDocumentStore: any QuickLookDocumentStoring,
    selectedEntryID: Binding<WorkspaceEntry.ID?>,
    shortcutActions: FileLocationShortcutActions,
    actions: WorkspaceActions
  ) {
    self.folderURL = folderURL
    self.snapshot = snapshot
    self.loadedAt = loadedAt
    self.rootURL = rootURL
    self.recentFiles = recentFiles
    self.recentFolders = recentFolders
    self.textDocumentStore = textDocumentStore
    self.imageDocumentStore = imageDocumentStore
    self.pdfDocumentStore = pdfDocumentStore
    self.mediaDocumentStore = mediaDocumentStore
    self.quickLookDocumentStore = quickLookDocumentStore
    self._selectedEntryID = selectedEntryID
    self.shortcutActions = shortcutActions
    self.actions = actions
    self._searchResults = State(
      initialValue: WorkspaceBrowserSearchResults.resolve(
        entries: snapshot.entries,
        recentFiles: recentFiles,
        recentFolders: recentFolders,
        query: ""
      )
    )
    self._sidebarVisibleEntries = State(
      initialValue: [WorkspaceEntry.workspaceRoot(at: folderURL)] + snapshot.entries)
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      WorkspaceSidebarView(
        folderURL: folderURL,
        entries: searchResults.visibleEntries,
        recentFolders: recentFolders,
        selectedEntryID: $selectedEntryID,
        shortcutActions: shortcutActions,
        actions: sidebarActions,
        onVisibleEntriesChange: updateSidebarVisibleEntries
      )
      .navigationSplitViewColumnWidth(
        min: LocusWindowMetrics.fileListSidebarMinimumWidth,
        ideal: LocusWindowMetrics.fileListSidebarIdealWidth,
        max: LocusWindowMetrics.fileListSidebarMaximumWidth
      )
    } detail: {
      workspaceDetail
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onChange(of: searchQuery) {
      refreshSearchResults()
    }
    .onChange(of: snapshot.entries) {
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
      isDocumentTextInputFocused = false
      documentTabs.removeAll()
      refreshSearchResults()
    }
    .focusedSceneValue(\.workspaceNavigationCommands, workspaceNavigationCommands)
  }

  private func refreshSearchResults() {
    // Search UI is intentionally hidden in the prototype toolbar, but the
    // filtering model stays wired so the feature can return without rebuilding
    // ranking, selection preservation, or shortcut matching.
    let refreshedResults = WorkspaceBrowserSearchResults.resolve(
      entries: snapshot.entries,
      recentFiles: recentFiles,
      recentFolders: recentFolders,
      query: searchQuery
    )
    searchResults = refreshedResults
    let rootEntry = WorkspaceEntry.workspaceRoot(at: folderURL)
    sidebarVisibleEntries = [rootEntry] + refreshedResults.visibleEntries

    if !WorkspaceEntrySearch.shouldKeepSelection(
      selectedEntryID,
      in: [rootEntry] + refreshedResults.visibleEntries)
    {
      selectedEntryID = nil
    }
  }

  private var isTextInputFocused: Bool {
    isDocumentTextInputFocused
  }

  private var workspaceNavigationCommands: WorkspaceNavigationCommands {
    let canGoBack = !isTextInputFocused && actions.canGoBack
    let canGoForward = !isTextInputFocused && actions.canGoForward

    return WorkspaceNavigationCommands(
      canGoBack: canGoBack,
      canGoForward: canGoForward,
      goBack: {
        guard canGoBack else {
          return
        }

        actions.goBack()
      },
      goForward: {
        guard canGoForward else {
          return
        }

        actions.goForward()
      }
    )
  }

  private var sidebarActions: WorkspaceActions {
    WorkspaceActions(
      canGoBack: actions.canGoBack,
      canGoForward: actions.canGoForward,
      goBack: actions.goBack,
      goForward: actions.goForward,
      retryCurrentFolder: actions.retryCurrentFolder,
      copyPaths: actions.copyPaths,
      loadFolderChildren: actions.loadFolderChildren,
      performOpenAction: performWorkspaceOpenAction
    )
  }

  private var selectedEntry: WorkspaceEntry? {
    guard let selectedEntryID else {
      return nil
    }

    return sidebarVisibleEntries.first { $0.id == selectedEntryID }
      ?? documentTabs.first { $0.id == selectedEntryID }?.entry
  }

  private func performWorkspaceOpenAction(_ openAction: WorkspaceEntryOpenAction) {
    if case .openInPlace(let url) = openAction,
      let entry = sidebarVisibleEntries.first(where: {
        $0.url.locusStandardizedPath == url.locusStandardizedPath
      })
    {
      trackDocumentTab(for: entry)
    }

    actions.performOpenAction(openAction)
  }

  private func trackDocumentTab(for entry: WorkspaceEntry) {
    guard let tab = WorkspaceDocumentTab(entry: entry),
      !documentTabs.contains(where: { $0.id == tab.id })
    else {
      return
    }

    documentTabs.append(tab)
  }

  private func selectDocumentTab(_ tab: WorkspaceDocumentTab) {
    selectedEntryID = tab.id
  }

  private func closeDocumentTab(_ tab: WorkspaceDocumentTab) {
    guard let closedIndex = documentTabs.firstIndex(where: { $0.id == tab.id }) else {
      return
    }

    let wasSelected = selectedEntryID == tab.id
    documentTabs.remove(at: closedIndex)

    guard wasSelected else {
      return
    }

    if let replacement = replacementTab(afterClosingIndex: closedIndex) {
      selectDocumentTab(replacement)
    } else {
      selectedEntryID = nil
    }
  }

  private func replacementTab(afterClosingIndex closedIndex: Int) -> WorkspaceDocumentTab? {
    if closedIndex < documentTabs.count {
      return documentTabs[closedIndex]
    }

    return documentTabs.last
  }

  private func updateSidebarVisibleEntries(_ entries: [WorkspaceEntry]) {
    sidebarVisibleEntries = entries

    guard let selectedEntryID,
      !entries.contains(where: { $0.id == selectedEntryID }),
      !documentTabs.contains(where: { $0.id == selectedEntryID })
    else {
      return
    }

    self.selectedEntryID = nil
  }

  private var workspaceDetail: some View {
    Group {
      if snapshot.entries.isEmpty {
        ContentUnavailableView(
          "This Folder Is Empty",
          systemImage: "folder",
          description: Text("Files and folders will appear here.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(spacing: 0) {
          WorkspaceDocumentTabsHeader(
            tabs: documentTabs,
            selectedTabID: selectedEntryID,
            select: selectDocumentTab,
            close: closeDocumentTab
          )
          .frame(height: documentTabs.isEmpty ? 0 : WorkspaceDocumentTabMetrics.height)
          .clipped()

          WorkspaceDocumentSurface(
            entry: selectedEntry,
            showsTopDivider: documentTabs.isEmpty,
            workspaceRefreshToken: loadedAt,
            textDocumentStore: textDocumentStore,
            imageDocumentStore: imageDocumentStore,
            pdfDocumentStore: pdfDocumentStore,
            mediaDocumentStore: mediaDocumentStore,
            quickLookDocumentStore: quickLookDocumentStore,
            onTextInputFocusChange: { isFocused in
              isDocumentTextInputFocused = isFocused
            }
          )
        }
        .navigationSplitViewColumnWidth(
          min: LocusWindowMetrics.documentSurfaceMinimumWidth,
          ideal: LocusWindowMetrics.documentSurfaceIdealWidth
        )
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      if !snapshot.partialErrors.isEmpty {
        PartialErrorsView(errors: snapshot.partialErrors)
          .padding(.horizontal, 12)
          .padding(.top, 8)
          .padding(.bottom, 4)
      }
    }
  }
}

private struct WorkspaceDocumentTab: Identifiable, Equatable {
  let entry: WorkspaceEntry

  var id: WorkspaceEntry.ID {
    entry.id
  }

  var url: URL {
    entry.url
  }

  var name: String {
    entry.name
  }

  var symbolName: String {
    entry.symbolName
  }

  var symbolColor: Color {
    entry.symbolColor
  }

  init?(entry: WorkspaceEntry) {
    guard WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry).supportsInPlaceOpen else {
      return nil
    }

    self.entry = entry
  }
}

private struct WorkspaceDocumentTabsHeader: View {
  let tabs: [WorkspaceDocumentTab]
  let selectedTabID: WorkspaceEntry.ID?
  let select: (WorkspaceDocumentTab) -> Void
  let close: (WorkspaceDocumentTab) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 0) {
            ForEach(tabs) { tab in
              WorkspaceDocumentTabItem(
                tab: tab,
                isSelected: tab.id == selectedTabID,
                select: select,
                close: close
              )
              .id(tab.id)
            }
          }
          .frame(height: WorkspaceDocumentTabMetrics.height)
        }
        .onAppear {
          scrollSelectedTab(proxy)
        }
        .onChange(of: selectedTabID) {
          scrollSelectedTab(proxy)
        }
      }

      Divider()
    }
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("document-tab-bar")
    .accessibilityHidden(tabs.isEmpty)
  }

  private func scrollSelectedTab(_ proxy: ScrollViewProxy) {
    guard let selectedTabID else {
      return
    }

    withAnimation(.easeInOut(duration: 0.15)) {
      proxy.scrollTo(selectedTabID, anchor: .center)
    }
  }
}

private struct WorkspaceDocumentTabItem: View {
  let tab: WorkspaceDocumentTab
  let isSelected: Bool
  let select: (WorkspaceDocumentTab) -> Void
  let close: (WorkspaceDocumentTab) -> Void
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      Button {
        select(tab)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: tab.symbolName)
            .foregroundStyle(tab.symbolColor)
            .accessibilityHidden(true)

          Text(tab.name)
            .lineLimit(1)
            .truncationMode(.middle)

          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(verbatim: tab.name))
      .accessibilityIdentifier("document-tab-item")

      Button {
        close(tab)
      } label: {
        Image(systemName: "xmark")
          .font(.caption2)
          .frame(
            width: WorkspaceDocumentTabMetrics.closeButtonSize,
            height: WorkspaceDocumentTabMetrics.closeButtonSize
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(.secondary)
      .accessibilityLabel(Text(verbatim: "Close \(tab.name)"))
      .accessibilityIdentifier("document-tab-close-button")
      .help(Text(verbatim: "Close \(tab.name)"))
    }
    .padding(.horizontal, 8)
    .frame(
      minWidth: WorkspaceDocumentTabMetrics.minimumWidth,
      maxWidth: WorkspaceDocumentTabMetrics.maximumWidth,
      minHeight: WorkspaceDocumentTabMetrics.height,
      maxHeight: WorkspaceDocumentTabMetrics.height
    )
    .background {
      Rectangle()
        .fill(backgroundColor)
    }
    .overlay(alignment: .trailing) {
      Divider()
    }
    .onHover { isHovered = $0 }
    .help(Text(verbatim: tab.url.locusStandardizedPath))
  }

  private var backgroundColor: Color {
    if isSelected {
      return Color.primary.opacity(0.10)
    }

    return isHovered ? Color.primary.opacity(0.06) : Color.clear
  }
}

private enum WorkspaceDocumentTabMetrics {
  static let height: CGFloat = 32
  static let minimumWidth: CGFloat = 112
  static let maximumWidth: CGFloat = 192
  static let closeButtonSize: CGFloat = 24
}

/// Search-backed browser content kept while the prototype hides search chrome.
/// With an empty query this is just the folder entries; when search returns it
/// also carries matching recent shortcuts without reworking selection logic.
struct WorkspaceBrowserSearchResults {
  let visibleEntries: [WorkspaceEntry]
  let recentFiles: [RecentFile]
  let recentFolders: [RecentFolder]

  var hasShortcutResults: Bool {
    !recentFiles.isEmpty || !recentFolders.isEmpty
  }

  static func resolve(
    entries: [WorkspaceEntry],
    recentFiles: [RecentFile],
    recentFolders: [RecentFolder],
    query: String
  ) -> WorkspaceBrowserSearchResults {
    let visibleEntries = WorkspaceEntrySearch.filteredEntries(entries, query: query)
    guard WorkspaceEntrySearch.hasSearchTerms(in: query) else {
      return WorkspaceBrowserSearchResults(
        visibleEntries: visibleEntries,
        recentFiles: [],
        recentFolders: []
      )
    }

    let visibleEntryPaths = Set(visibleEntries.map(\.url.locusStandardizedPath))
    let visibleRecentFiles = WorkspaceEntrySearch.filteredShortcuts(recentFiles, query: query)
      .filter { !visibleEntryPaths.contains($0.path) }
    let visibleRecentFolders = WorkspaceEntrySearch.filteredShortcuts(recentFolders, query: query)

    return WorkspaceBrowserSearchResults(
      visibleEntries: visibleEntries,
      recentFiles: visibleRecentFiles,
      recentFolders: visibleRecentFolders
    )
  }
}

private struct WorkspaceShortcutSearchResultsView: View {
  // This view is intentionally retained while the prototype hides the search
  // field. The branch is unreachable with an empty query, but keeping it here
  // preserves the recents shortcut surface for the later search reintroduction.
  let recentFiles: [RecentFile]
  let recentFolders: [RecentFolder]
  let actions: FileLocationShortcutActions

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
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
          copyPath: actions.copyPath
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-shortcut-search-results")
  }
}

private struct WorkspaceSidebarView: View {
  let folderURL: URL
  let entries: [WorkspaceEntry]
  let recentFolders: [RecentFolder]
  private let rootEntry: WorkspaceEntry
  @Binding var selectedEntryID: WorkspaceEntry.ID?
  let shortcutActions: FileLocationShortcutActions
  let actions: WorkspaceActions
  let onVisibleEntriesChange: ([WorkspaceEntry]) -> Void
  @State private var expandedFolderIDs: Set<WorkspaceEntry.ID> = []
  @State private var childStates: [WorkspaceEntry.ID: WorkspaceSidebarChildState] = [:]
  @State private var childLoadTasks: [WorkspaceEntry.ID: Task<Void, Never>] = [:]
  @State private var childLoadTokens: [WorkspaceEntry.ID: UUID] = [:]
  @State private var expansionGeneration: UInt64 = 0
  @State private var isRootExpanded = true
  @AppStorage(LocusPersistedDefaults.recentFoldersExpanded)
  private var isRecentFoldersExpanded = false

  init(
    folderURL: URL,
    entries: [WorkspaceEntry],
    recentFolders: [RecentFolder],
    selectedEntryID: Binding<WorkspaceEntry.ID?>,
    shortcutActions: FileLocationShortcutActions,
    actions: WorkspaceActions,
    onVisibleEntriesChange: @escaping ([WorkspaceEntry]) -> Void
  ) {
    self.folderURL = folderURL
    self.entries = entries
    self.recentFolders = recentFolders
    self.rootEntry = WorkspaceEntry.workspaceRoot(at: folderURL)
    self._selectedEntryID = selectedEntryID
    self.shortcutActions = shortcutActions
    self.actions = actions
    self.onVisibleEntriesChange = onVisibleEntriesChange
  }

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $selectedEntryID) {
        ForEach(rows) { row in
          switch row.content {
          case .entry(let entry):
            WorkspaceSidebarEntryRow(
              entry: entry,
              depth: row.depth,
              isExpanded: isExpanded(entry),
              toggleExpansion: {
                toggleExpansion(for: entry)
              }
            )
            .tag(entry.id)
          case .status(let status):
            WorkspaceSidebarStatusRow(status: status, depth: row.depth)
          }
        }
      }
      .listStyle(.sidebar)
      .contextMenu(forSelectionType: WorkspaceEntry.ID.self) { selection in
        let selectedEntries = entries(for: selection)
        let openAction = WorkspaceEntryOpenActionResolver.action(for: selectedEntries)

        Button("Open") {
          if let openAction {
            actions.performOpenAction(openAction)
          }
        }
        .disabled(openAction == nil)

        Button(WorkspaceEntryPathCopy.menuTitle(for: selectedEntries)) {
          actions.copyPaths(selectedEntries)
        }
        .disabled(selectedEntries.isEmpty)
      } primaryAction: { selection in
        // Keep row double-click, Return, and VoiceOver default actions on the
        // native List path; folder expansion belongs to the disclosure Button.
        performPrimaryAction(for: selection)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      if !recentFolders.isEmpty {
        Divider()

        WorkspaceSidebarRecentFoldersSection(
          folders: recentFolders,
          isExpanded: $isRecentFoldersExpanded,
          open: shortcutActions.openRecentFolder,
          remove: shortcutActions.removeRecentFolder,
          copyPath: shortcutActions.copyPath
        )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      publishVisibleEntries()
    }
    .onChange(of: entries) {
      pruneExpansion(for: entries)
    }
    .onChange(of: folderURL) {
      resetExpansion()
    }
  }

  private var rows: [WorkspaceSidebarRow] {
    var result = [WorkspaceSidebarRow(entry: rootEntry, depth: 0)]
    if isRootExpanded {
      result.append(contentsOf: rows(for: entries, depth: 1))
    }
    return result
  }

  private func performPrimaryAction(for selection: Set<WorkspaceEntry.ID>) {
    guard let openAction = WorkspaceEntryOpenActionResolver.action(for: entries(for: selection))
    else {
      return
    }

    if isBrowseActionForWorkspaceRoot(openAction) {
      return
    }

    actions.performOpenAction(openAction)
  }

  private func isBrowseActionForWorkspaceRoot(_ action: WorkspaceEntryOpenAction) -> Bool {
    guard case .browseFolder(let url) = action else {
      return false
    }

    return url.locusStandardizedPath == folderURL.locusStandardizedPath
  }

  private func entries(for selection: Set<WorkspaceEntry.ID>) -> [WorkspaceEntry] {
    rows.compactMap(\.entry).filter { selection.contains($0.id) }
  }

  private func isExpanded(_ entry: WorkspaceEntry) -> Bool {
    entry.id == rootEntry.id ? isRootExpanded : expandedFolderIDs.contains(entry.id)
  }

  private func rows(for entries: [WorkspaceEntry], depth: Int) -> [WorkspaceSidebarRow] {
    entries.flatMap { entry -> [WorkspaceSidebarRow] in
      var result = [WorkspaceSidebarRow(entry: entry, depth: depth)]

      guard entry.kind == .directory, expandedFolderIDs.contains(entry.id) else {
        return result
      }

      switch childStates[entry.id] {
      case .loading:
        result.append(.status(.loading(parentID: entry.id), depth: depth + 1))
      case .loaded(let snapshot):
        if snapshot.entries.isEmpty {
          result.append(.status(.empty(parentID: entry.id), depth: depth + 1))
        } else {
          result.append(contentsOf: rows(for: snapshot.entries, depth: depth + 1))
        }

        if !snapshot.partialErrors.isEmpty {
          result.append(.status(.partialErrors(parentID: entry.id), depth: depth + 1))
        }
      case .failed:
        result.append(.status(.failed(parentID: entry.id), depth: depth + 1))
      case .pending, nil:
        break
      }

      return result
    }
  }

  private func validEntryIDs(in entries: [WorkspaceEntry]) -> Set<WorkspaceEntry.ID> {
    var ids = Set<WorkspaceEntry.ID>()

    func collect(_ entries: [WorkspaceEntry]) {
      for entry in entries {
        ids.insert(entry.id)
        if case .loaded(let snapshot) = childStates[entry.id] {
          collect(snapshot.entries)
        }
      }
    }

    collect(entries)
    return ids
  }

  private func pruneExpansion(for entries: [WorkspaceEntry]) {
    let validIDs = validEntryIDs(in: entries)
    let removedExpandedIDs = expandedFolderIDs.subtracting(validIDs)
    for entryID in removedExpandedIDs {
      cancelChildLoad(for: entryID)
    }

    expandedFolderIDs.formIntersection(validIDs)
    childStates = childStates.filter { validIDs.contains($0.key) }
    publishVisibleEntries()
  }

  private func cancelChildLoad(for entryID: WorkspaceEntry.ID) {
    childLoadTasks[entryID]?.cancel()
    childLoadTasks[entryID] = nil
    childLoadTokens[entryID] = nil
  }

  private func cancelAllChildLoads() {
    for task in childLoadTasks.values {
      task.cancel()
    }

    childLoadTasks.removeAll()
    childLoadTokens.removeAll()
  }

  private func clearPendingStateIfNeeded(for entryID: WorkspaceEntry.ID) {
    switch childStates[entryID] {
    case .pending, .loading:
      childStates[entryID] = nil
    case .loaded, .failed, nil:
      break
    }
  }

  private func visibleEntries() -> [WorkspaceEntry] {
    rows.compactMap(\.entry)
  }

  private func toggleExpansion(for entry: WorkspaceEntry) {
    if entry.id == rootEntry.id {
      isRootExpanded.toggle()
      publishVisibleEntries()
      return
    }

    toggleFolderExpansion(for: entry)
  }

  private func toggleFolderExpansion(for entry: WorkspaceEntry) {
    guard entry.kind == .directory else {
      return
    }

    if expandedFolderIDs.contains(entry.id) {
      expandedFolderIDs.remove(entry.id)
      cancelChildLoad(for: entry.id)
      clearPendingStateIfNeeded(for: entry.id)
      publishVisibleEntries()
      return
    }

    expandedFolderIDs.insert(entry.id)
    loadChildrenIfNeeded(for: entry)
    publishVisibleEntries()
  }

  private func loadChildrenIfNeeded(for entry: WorkspaceEntry) {
    switch childStates[entry.id] {
    case .loaded, .pending, .loading:
      return
    case .failed, nil:
      break
    }

    childStates[entry.id] = .pending
    let generation = expansionGeneration
    let loadToken = UUID()
    childLoadTokens[entry.id] = loadToken
    childLoadTasks[entry.id] = Task { @MainActor in
      defer {
        if childLoadTokens[entry.id] == loadToken {
          childLoadTasks[entry.id] = nil
          childLoadTokens[entry.id] = nil
        }
      }

      do {
        guard !Task.isCancelled,
          generation == expansionGeneration,
          expandedFolderIDs.contains(entry.id)
        else {
          return
        }

        let loadingIndicatorTask = Task { @MainActor in
          do {
            try await Task.sleep(for: WorkspaceSidebarMetrics.loadingIndicatorDelay)
            guard !Task.isCancelled,
              childLoadTokens[entry.id] == loadToken,
              generation == expansionGeneration,
              expandedFolderIDs.contains(entry.id),
              childStates[entry.id] == .pending
            else {
              return
            }

            childStates[entry.id] = .loading
            publishVisibleEntries()
          } catch is CancellationError {
            return
          } catch {
            return
          }
        }
        defer {
          loadingIndicatorTask.cancel()
        }

        let snapshot = try await actions.loadFolderChildren(entry.url)
        guard !Task.isCancelled,
          generation == expansionGeneration,
          expandedFolderIDs.contains(entry.id)
        else {
          return
        }

        childStates[entry.id] = .loaded(snapshot)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled,
          generation == expansionGeneration,
          expandedFolderIDs.contains(entry.id)
        else {
          return
        }

        childStates[entry.id] = .failed
      }

      publishVisibleEntries()
    }
  }

  private func resetExpansion() {
    expansionGeneration &+= 1
    cancelAllChildLoads()
    isRootExpanded = true
    expandedFolderIDs.removeAll()
    childStates.removeAll()
    publishVisibleEntries()
  }

  private func publishVisibleEntries() {
    onVisibleEntriesChange(visibleEntries())
  }
}

private struct WorkspaceSidebarRecentFoldersSection: View {
  let folders: [RecentFolder]
  @Binding var isExpanded: Bool
  let open: (RecentFolder) -> Void
  let remove: (RecentFolder) -> Void
  let copyPath: (URL) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        isExpanded.toggle()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: WorkspaceSidebarMetrics.chevronColumnWidth)
            .accessibilityHidden(true)

          Text("Recent Folders")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)

          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(isExpanded ? "Collapse Recent Folders" : "Expand Recent Folders"))
      .accessibilityIdentifier("workspace-sidebar-recent-folders-disclosure")
      .padding(.horizontal, 12)
      .frame(height: WorkspaceSidebarMetrics.recentFoldersHeaderHeight)

      if isExpanded {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(folders) { folder in
              WorkspaceSidebarRecentFolderRow(
                folder: folder,
                open: open,
                remove: remove,
                copyPath: copyPath
              )
            }
          }
        }
        .frame(maxHeight: WorkspaceSidebarMetrics.recentFoldersMaximumHeight)
        .padding(.bottom, 6)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-sidebar-recent-folders")
  }
}

private struct WorkspaceSidebarRecentFolderRow: View {
  let folder: RecentFolder
  let open: (RecentFolder) -> Void
  let remove: (RecentFolder) -> Void
  let copyPath: (URL) -> Void
  @State private var isHovered = false

  var body: some View {
    Button {
      open(folder)
    } label: {
      HStack(spacing: 6) {
        Color.clear
          .frame(width: WorkspaceSidebarMetrics.chevronColumnWidth)
          .accessibilityHidden(true)

        Image(systemName: "folder")
          .foregroundStyle(.blue)
          .accessibilityHidden(true)

        Text(folder.displayName)
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .frame(height: WorkspaceSidebarMetrics.recentFolderRowHeight)
      .contentShape(Rectangle())
      .background {
        RoundedRectangle(cornerRadius: 5)
          .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .contextMenu {
      Button("Open") {
        open(folder)
      }

      Button("Copy Path") {
        copyPath(folder.url)
      }

      Button("Remove") {
        remove(folder)
      }
    }
    .accessibilityLabel(Text("Open \(folder.displayName)"))
    .accessibilityIdentifier("workspace-sidebar-recent-folder-row")
    .help(Text(verbatim: folder.path))
  }
}

private enum WorkspaceSidebarChildState: Equatable {
  case pending
  case loading
  case loaded(WorkspaceSnapshot)
  case failed
}

private enum WorkspaceSidebarMetrics {
  static let depthIndent: CGFloat = 14
  static let chevronColumnWidth: CGFloat = 10
  static let recentFoldersHeaderHeight: CGFloat = 28
  static let recentFolderRowHeight: CGFloat = 28
  static let recentFoldersMaximumHeight: CGFloat = 224

  // Fast child listings should appear directly. Show "Loading..." only when a
  // real read stays in flight long enough that silent waiting would feel stuck.
  static let loadingIndicatorDelay: Duration = .milliseconds(180)
}

private enum WorkspaceSidebarAccessibility {
  static func disclosureIdentifier(for entry: WorkspaceEntry) -> String {
    "workspace-sidebar-disclosure-\(stableHash(for: entry.id))"
  }

  private static func stableHash(for value: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in value.utf8 {
      hash ^= UInt64(byte)
      hash &*= 0x100_0000_01b3
    }
    return String(hash, radix: 16)
  }
}

private struct WorkspaceSidebarRow: Identifiable, Equatable {
  enum Content: Equatable {
    case entry(WorkspaceEntry)
    case status(WorkspaceSidebarStatus)
  }

  let content: Content
  let depth: Int

  var id: String {
    switch content {
    case .entry(let entry):
      entry.id
    case .status(let status):
      status.id
    }
  }

  var entry: WorkspaceEntry? {
    guard case .entry(let entry) = content else {
      return nil
    }

    return entry
  }

  init(entry: WorkspaceEntry, depth: Int) {
    self.content = .entry(entry)
    self.depth = depth
  }

  static func status(_ status: WorkspaceSidebarStatus, depth: Int) -> WorkspaceSidebarRow {
    WorkspaceSidebarRow(content: .status(status), depth: depth)
  }

  private init(content: Content, depth: Int) {
    self.content = content
    self.depth = depth
  }
}

private struct WorkspaceSidebarStatus: Equatable {
  let id: String
  let title: String
  let systemImage: String
  let isError: Bool

  static func loading(parentID: WorkspaceEntry.ID) -> WorkspaceSidebarStatus {
    WorkspaceSidebarStatus(
      id: "\(parentID)::loading",
      title: "Loading...",
      systemImage: "hourglass",
      isError: false
    )
  }

  static func empty(parentID: WorkspaceEntry.ID) -> WorkspaceSidebarStatus {
    WorkspaceSidebarStatus(
      id: "\(parentID)::empty",
      title: "Empty folder",
      systemImage: "folder",
      isError: false
    )
  }

  static func failed(parentID: WorkspaceEntry.ID) -> WorkspaceSidebarStatus {
    WorkspaceSidebarStatus(
      id: "\(parentID)::failed",
      title: "Couldn't read folder",
      systemImage: "exclamationmark.triangle",
      isError: true
    )
  }

  static func partialErrors(parentID: WorkspaceEntry.ID) -> WorkspaceSidebarStatus {
    WorkspaceSidebarStatus(
      id: "\(parentID)::partial-errors",
      title: "Some items could not be read",
      systemImage: "exclamationmark.triangle",
      isError: true
    )
  }
}

private struct WorkspaceSidebarEntryRow: View {
  let entry: WorkspaceEntry
  let depth: Int
  let isExpanded: Bool
  let toggleExpansion: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      if entry.kind == .directory {
        Button(action: toggleExpansion) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .frame(width: WorkspaceSidebarMetrics.chevronColumnWidth)
            // Expand the Button hit shape from the SF Symbol's drawn pixels
            // to the full chevron column so the icon stays clickable along
            // its entire bounds.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(disclosureAccessibilityLabel)
        .accessibilityIdentifier(WorkspaceSidebarAccessibility.disclosureIdentifier(for: entry))
      } else {
        Color.clear
          .frame(width: WorkspaceSidebarMetrics.chevronColumnWidth)
          .accessibilityHidden(true)
      }

      rowContent
    }
    .padding(.leading, CGFloat(depth) * WorkspaceSidebarMetrics.depthIndent)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .help(Text(verbatim: entry.name))
  }

  private var rowContent: some View {
    HStack(spacing: 6) {
      Image(systemName: entry.symbolName)
        .foregroundStyle(entry.symbolColor)

      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private var disclosureAccessibilityLabel: Text {
    let action = isExpanded ? "Collapse" : "Expand"
    return Text(verbatim: "\(action) \(entry.name)")
  }

}

private struct WorkspaceSidebarStatusRow: View {
  let status: WorkspaceSidebarStatus
  let depth: Int

  var body: some View {
    HStack(spacing: 6) {
      Color.clear
        .frame(width: WorkspaceSidebarMetrics.chevronColumnWidth)
        .accessibilityHidden(true)

      Image(systemName: status.systemImage)
        .font(.caption)
        .foregroundStyle(status.isError ? .orange : .secondary)
        .accessibilityHidden(true)

      Text(status.title)
        .lineLimit(1)
        .foregroundStyle(status.isError ? .secondary : .tertiary)

      Spacer(minLength: 0)
    }
    .font(.caption)
    .padding(.leading, CGFloat(depth) * WorkspaceSidebarMetrics.depthIndent)
    .accessibilityLabel(Text(status.title))
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
      return "An item could not be read"
    }

    return "Some items could not be read"
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
  // Placeholder for the first automatic folder load. It intentionally draws no
  // empty state while fast launches move directly to `.ready`.
  case awaitingInitialLoad
  case idle
  case loading(folderURL: URL)
  case ready(folderURL: URL, snapshot: WorkspaceSnapshot, loadedAt: Date)
  case failed(folderURL: URL?, message: String)
}

extension WorkspaceState {
  fileprivate var folderURL: URL? {
    switch self {
    case .loading(let folderURL), .ready(let folderURL, _, _), .failed(let folderURL?, _):
      return folderURL
    case .awaitingInitialLoad, .idle, .failed(nil, _):
      return nil
    }
  }
}

extension WorkspaceEntry {
  /// Synthesizes a `WorkspaceEntry` for the workspace root folder itself.
  /// The FFI lists only a folder's children, so the root row has no
  /// metadata-bearing entry to copy. Fields not directly observable from the
  /// URL are intentionally left nil, unknown, or false.
  fileprivate static func workspaceRoot(at folderURL: URL) -> WorkspaceEntry {
    let standardizedURL = folderURL.standardizedFileURL
    let folderName = standardizedURL.lastPathComponent
    return WorkspaceEntry(
      id: standardizedURL.path(percentEncoded: false),
      url: standardizedURL,
      name: folderName.isEmpty ? "Workspace" : folderName,
      kind: .directory,
      fileType: .unknown,
      sizeBytes: nil,
      modified: nil,
      isReadOnly: false
    )
  }

  fileprivate var symbolName: String {
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

  fileprivate var symbolColor: Color {
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
}

extension WorkspaceFileType {
  fileprivate var symbolName: String {
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
