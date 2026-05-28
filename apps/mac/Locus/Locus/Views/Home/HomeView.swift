import SwiftUI

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
  private let gitWorkspaceStatusProvider: any GitWorkspaceStatusProviding
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
    gitWorkspaceStatusProvider: any GitWorkspaceStatusProviding = GitWorkspaceStatusProvider(),
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
    self.gitWorkspaceStatusProvider = gitWorkspaceStatusProvider
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
      gitWorkspaceStatusProvider: gitWorkspaceStatusProvider,
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
        createItem: createWorkspaceItem,
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
  private func createWorkspaceItem(
    _ kind: WorkspaceItemCreationKind,
    named name: String,
    in targetFolderURL: URL
  ) async throws -> URL {
    guard let folderURL = workspaceState.folderURL else {
      assertionFailure("createWorkspaceItem invoked without an active workspace")
      throw WorkspaceItemCreationError.noActiveWorkspace
    }

    guard targetFolderURL.locusStandardizedPath.locusHasPathPrefix(folderURL.locusStandardizedPath)
    else {
      assertionFailure("createWorkspaceItem invoked outside the active workspace")
      throw WorkspaceItemCreationError.noActiveWorkspace
    }

    let didStartAccess = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        folderURL.stopAccessingSecurityScopedResource()
      }
    }

    let createdURL = try WorkspaceItemCreation.create(kind, named: name, in: targetFolderURL)
    if targetFolderURL.locusStandardizedPath == folderURL.locusStandardizedPath {
      startWorkspaceLoad(
        WorkspaceLoadRequest(
          folderURL: folderURL,
          showsLoading: false,
          selectedURL: createdURL
        )
      )
    }

    return createdURL
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
  let gitWorkspaceStatusProvider: any GitWorkspaceStatusProviding
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
          gitWorkspaceStatusProvider: gitWorkspaceStatusProvider,
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

struct WorkspaceActions {
  let canGoBack: Bool
  let canGoForward: Bool
  let goBack: () -> Void
  let goForward: () -> Void
  let retryCurrentFolder: () -> Void
  let copyPaths: ([WorkspaceEntry]) -> Void
  let createItem: (WorkspaceItemCreationKind, String, URL) async throws -> URL
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
  private struct GitStatusRefreshKey: Hashable {
    let folderPath: String
    let loadedAt: Date
    let generation: UInt64
  }

  private enum GitStatusRefresh {
    static let debounceDuration: Duration = .milliseconds(250)
  }

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
  let gitWorkspaceStatusProvider: any GitWorkspaceStatusProviding
  @Binding var selectedEntryID: WorkspaceEntry.ID?
  let shortcutActions: FileLocationShortcutActions
  let actions: WorkspaceActions
  @State private var searchQuery = ""
  @State private var searchResults: WorkspaceBrowserSearchResults
  @State private var sidebarVisibleEntries: [WorkspaceEntry]
  @State private var sidebarSelectionState: WorkspaceSidebarSelectionState
  @State private var isDocumentTextInputFocused = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var gitStatusesByPath: [String: GitWorkspaceChangeKind] = [:]
  @State private var gitStatusRefreshGeneration: UInt64 = 0

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
    gitWorkspaceStatusProvider: any GitWorkspaceStatusProviding,
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
    self.gitWorkspaceStatusProvider = gitWorkspaceStatusProvider
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
    let initialVisibleEntryIDs =
      ([WorkspaceEntry.workspaceRoot(at: folderURL)] + snapshot.entries).map(\.id)
    self._sidebarSelectionState = State(
      initialValue: WorkspaceSidebarSelectionState(
        activeEntryID: selectedEntryID.wrappedValue,
        visibleEntryIDs: Set(initialVisibleEntryIDs)
      )
    )
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      WorkspaceSidebarView(
        folderURL: folderURL,
        entries: searchResults.visibleEntries,
        recentFolders: recentFolders,
        gitStatusesByPath: gitStatusesByPath,
        highlightedEntryID: sidebarHighlight,
        shortcutActions: shortcutActions,
        actions: sidebarActions,
        onItemCreated: requestGitStatusRefresh,
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
      gitStatusesByPath = [:]
      gitStatusRefreshGeneration &+= 1
      sidebarSelectionState.reset()
      refreshSearchResults()
    }
    .onChange(of: selectedEntryID) { _, newSelection in
      sidebarSelectionState.setActiveEntryID(newSelection)
    }
    .task(id: gitStatusRefreshKey) {
      await refreshGitStatuses()
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
      createItem: actions.createItem,
      loadFolderChildren: actions.loadFolderChildren,
      performOpenAction: performWorkspaceOpenAction
    )
  }

  private var gitStatusRefreshKey: GitStatusRefreshKey {
    GitStatusRefreshKey(
      folderPath: folderURL.locusStandardizedPath,
      loadedAt: loadedAt,
      generation: gitStatusRefreshGeneration
    )
  }

  private func refreshGitStatuses() async {
    do {
      try await Task.sleep(for: GitStatusRefresh.debounceDuration)
    } catch {
      return
    }

    guard !Task.isCancelled else {
      return
    }

    let statuses = await gitWorkspaceStatusProvider.sidebarStatuses(for: folderURL)
    guard !Task.isCancelled else {
      return
    }

    gitStatusesByPath = statuses
  }

  private func requestGitStatusRefresh() {
    gitStatusRefreshGeneration &+= 1
  }

  private var sidebarHighlight: Binding<WorkspaceEntry.ID?> {
    // The sidebar highlight is visual focus, while selectedEntryID is the
    // active document/folder. Empty sidebar clicks clear only the highlight.
    Binding(
      get: {
        sidebarSelectionState.highlightedEntryID
      },
      set: { newHighlight in
        if let newHighlight {
          sidebarSelectionState.selectSidebarEntry(newHighlight)
          selectedEntryID = newHighlight
        } else {
          sidebarSelectionState.clearHighlightForEmptyAreaClick()
        }
      }
    )
  }

  private var selectedEntry: WorkspaceEntry? {
    guard let selectedEntryID else {
      return nil
    }

    return sidebarVisibleEntries.first { $0.id == selectedEntryID }
  }

  private func performWorkspaceOpenAction(_ openAction: WorkspaceEntryOpenAction) {
    actions.performOpenAction(openAction)
  }

  private func updateSidebarVisibleEntries(_ entries: [WorkspaceEntry]) {
    sidebarVisibleEntries = entries
    sidebarSelectionState.setVisibleEntryIDs(Set(entries.map(\.id)))

    guard let selectedEntryID,
      !entries.contains(where: { $0.id == selectedEntryID })
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
        WorkspaceDocumentSurface(
          entry: selectedEntry,
          textDocumentStore: textDocumentStore,
          imageDocumentStore: imageDocumentStore,
          pdfDocumentStore: pdfDocumentStore,
          mediaDocumentStore: mediaDocumentStore,
          quickLookDocumentStore: quickLookDocumentStore,
          onTextInputFocusChange: { isFocused in
            isDocumentTextInputFocused = isFocused
          }
        )
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
