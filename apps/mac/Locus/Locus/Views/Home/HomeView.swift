import SwiftUI

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
    // When the load was made to open `selectedURL` as a document, engagement
    // must be recorded here in `loadWorkspace`: a load slow enough to pass
    // through `.loading` recreates `WorkspaceBrowserView`, whose open-document
    // `onChange` never fires for a seeded initial value.
    var recordsEngagementWhenSelectionOpens = false
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

  private enum WorkspaceUndoFileOperationError: LocalizedError {
    case noActiveWorkspace
    case outsideWorkspace

    var errorDescription: String? {
      switch self {
      case .noActiveWorkspace:
        return "No folder is open."
      case .outsideWorkspace:
        return "The item is outside the open folder."
      }
    }
  }

  @State private var workspaceState: WorkspaceState
  @State private var selectedEntryID: WorkspaceEntry.ID?
  @State private var isFolderImporterPresented = false
  @State private var didStartInitialFolderLoad = false
  @State private var workspaceRootURL: URL?
  @State private var navigationHistory = WorkspaceNavigationHistory()
  @State private var recentFiles: [RecentFile] = []
  @State private var recentFolders: [RecentFolder] = []
  @State private var documentTabs = DocumentTabsState()
  @StateObject private var terminalPanelState = TerminalPanelState()
  @State private var lastExternalWorkspaceOpen: ExternalWorkspaceOpen?
  // Folder loads can overlap when the directory monitor reloads or users
  // choose another folder.
  // quickly; only the latest generation is allowed to update visible state.
  @State private var workspaceLoadGeneration: UInt64 = 0
  @State private var workspaceLoadingIndicatorTask: Task<Void, Never>?
  @State private var workspaceDeletionErrorMessage: String?
  @State private var isWorkspaceDeletionErrorPresented = false

  private let coreBridge: CoreBridge
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

  private struct ExternalWorkspaceOpen {
    static let duplicateWindow: TimeInterval = 1

    let path: String
    let requestedAt: Date

    func matches(_ folderURL: URL, now: Date) -> Bool {
      path == folderURL.locusStandardizedPath
        && now.timeIntervalSince(requestedAt) < Self.duplicateWindow
    }
  }

  init(
    coreBridge: CoreBridge = CoreBridge(),
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
      imageDocumentStore: imageDocumentStore,
      pdfDocumentStore: pdfDocumentStore,
      mediaDocumentStore: mediaDocumentStore,
      quickLookDocumentStore: quickLookDocumentStore,
      gitWorkspaceStatusProvider: gitWorkspaceStatusProvider,
      terminalPanelState: terminalPanelState,
      selectedEntryID: $selectedEntryID,
      documentTabs: $documentTabs,
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
        deleteItems: deleteWorkspaceItems,
        trashCreatedItem: trashCreatedWorkspaceItem,
        trashItemsAtURLs: trashWorkspaceItems,
        restoreDeletedItems: restoreWorkspaceDeletedItems,
        moveItems: moveWorkspaceItems,
        importItems: importWorkspaceItems,
        loadFolderChildren: loadSidebarFolderChildren,
        performOpenAction: performOpenAction,
        recordWorkspaceEngagement: recordWorkspaceEngagement(in:)
      )
    )
    .frame(
      minWidth: LocusWindowMetrics.minimumWidth,
      minHeight: LocusWindowMetrics.minimumHeight
    )
    .task {
      terminalPanelState.currentWorkspaceFolder = workspaceState.folderURL
      refreshFileLocationShortcuts()
      loadInitialFolderIfNeeded()
      openPendingWorkspaceFolderRequests()
    }
    .onChange(of: workspaceState.folderURL) { _, folderURL in
      terminalPanelState.currentWorkspaceFolder = folderURL
    }
    .onOpenURL { url in
      openWorkspaceFolderURL(url)
    }
    .onReceive(
      NotificationCenter.default.publisher(for: WorkspaceFolderOpenRequestNotification.name)
    ) { notification in
      guard
        let requestID = notification.userInfo?[WorkspaceFolderOpenRequestNotification.requestIDKey]
          as? UUID,
        let request = WorkspaceFolderOpenRequestCenter.shared.consumeRequest(id: requestID)
      else {
        return
      }

      openWorkspaceFolderRequest(request)
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
    .alert("Couldn't Delete Item", isPresented: $isWorkspaceDeletionErrorPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(workspaceDeletionErrorMessage ?? "Locus couldn't move the item to the Trash.")
    }
    .onDisappear {
      terminalPanelState.shutdown()
    }
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
      // Home is never a recent item (RecentFolderRecordPolicy); Recents fill
      // from explicitly opened locations and folders where real work happened.
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

      navigateToWorkspaceFolder(folderURL, rootChange: .set(folderURL), intent: .openLocation)
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
  /// history. `.openLocation` additionally records the folder in Recents;
  /// `.browse` never does. Use `startWorkspaceLoad` directly for monitor-driven
  /// reloads and restores.
  @MainActor
  private func navigateToWorkspaceFolder(
    _ folderURL: URL,
    rootChange: WorkspaceRootChange = .preserve,
    intent: WorkspaceNavigationIntent = .browse,
    selecting selectedURL: URL? = nil,
    recordsEngagementWhenSelectionOpens: Bool = false
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
      recordRecent: intent.recordsRecent,
      selectedURL: selectedURL,
      recordsEngagementWhenSelectionOpens: recordsEngagementWhenSelectionOpens,
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
      documentTabs.prepareForWorkspace(folderURL)
      startWorkspaceChangeMonitoring(for: folderURL)
      if request.recordRecent,
        RecentFolderRecordPolicy.allowsRecording(folderURL, homeDirectoryURL: homeDirectoryURL)
      {
        recordRecentFolder(folderURL)
      }
      if let openedEntryID = entryID(in: snapshot.entries, matching: request.selectedURL),
        let openedEntry = snapshot.entries.first(where: { $0.id == openedEntryID }),
        case .openInPlace = WorkspaceEntryOpenActionResolver.action(for: [openedEntry])
      {
        documentTabs.recordOpen(of: openedEntry)
        if request.recordsEngagementWhenSelectionOpens {
          recordWorkspaceEngagement(in: folderURL)
        }
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
      selecting: standardizedURL,
      recordsEngagementWhenSelectionOpens: true
    )
  }

  @MainActor
  private func showRecentFile(_ file: RecentFile) {
    navigateToFile(file.url)
  }

  /// Real work observed in a loaded folder — opening a document, saving,
  /// or changing files — promotes it into Recents; merely browsing through
  /// folders never does. This is what keeps pass-through folders out while
  /// letting purely in-app navigation still build up Recent Folders.
  /// Callers pass the folder captured when the work was requested, so a
  /// completion that arrives after the user navigated away (an import copy,
  /// a slow save) still credits the folder the work actually happened in
  /// rather than wherever the user browsed to since.
  @MainActor
  private func recordWorkspaceEngagement(in folderURL: URL) {
    guard RecentFolderRecordPolicy.allowsRecording(folderURL, homeDirectoryURL: homeDirectoryURL)
    else {
      return
    }

    recordRecentFolder(folderURL)
  }

  @MainActor
  private func openRecentFolder(_ folder: RecentFolder) {
    navigateToWorkspaceFolder(folder.url, rootChange: .set(folder.url), intent: .openLocation)
  }

  @MainActor
  private func openPendingWorkspaceFolderRequests() {
    for request in WorkspaceFolderOpenRequestCenter.shared.consumePendingRequests() {
      openWorkspaceFolderRequest(request)
    }
  }

  @MainActor
  private func openWorkspaceFolderURL(_ url: URL) {
    guard let folderURL = WorkspaceOpenFileResolution.firstFolderURL(in: [url]) else {
      return
    }

    openExternalWorkspaceFolder(folderURL)
  }

  @MainActor
  private func openWorkspaceFolderRequest(_ request: WorkspaceFolderOpenRequest) {
    openExternalWorkspaceFolder(request.folderURL)
  }

  @MainActor
  private func openExternalWorkspaceFolder(_ folderURL: URL) {
    let now = Date()
    guard lastExternalWorkspaceOpen?.matches(folderURL, now: now) != true else {
      return
    }

    lastExternalWorkspaceOpen = ExternalWorkspaceOpen(
      path: folderURL.locusStandardizedPath,
      requestedAt: now
    )
    didStartInitialFolderLoad = true
    navigateToWorkspaceFolder(
      folderURL,
      rootChange: .set(folderURL),
      intent: .openLocation
    )
  }

  @MainActor
  private func recordRecentFolder(_ folderURL: URL) {
    guard recentFolderStore.record(folderURL) else {
      return
    }

    WorkspaceRecentDocumentRegistration.register(folderURL)
    refreshRecentFolders()
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

    // Resolve symlinks so a symlinked target folder cannot create the item
    // outside the workspace while looking lexically internal (see
    // WorkspaceItemMove.plannedMoves).
    guard targetFolderURL.locusResolvedPath.locusHasPathPrefix(folderURL.locusResolvedPath)
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
    recordWorkspaceEngagement(in: folderURL)
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
  private func deleteWorkspaceItems(_ entries: [WorkspaceEntry]) -> [WorkspaceDeletedItem] {
    do {
      return try deleteWorkspaceItemsNow(entries)
    } catch let error as WorkspaceItemDeletionError {
      if case .partiallyDeleted(let succeededItems, _, _) = error {
        finishWorkspaceItemDeletion(succeededItems, attemptedEntries: entries)
        workspaceDeletionErrorMessage = error.localizedDescription
        isWorkspaceDeletionErrorPresented = true
        return succeededItems
      }

      workspaceDeletionErrorMessage = error.localizedDescription
      isWorkspaceDeletionErrorPresented = true
      return []
    } catch {
      workspaceDeletionErrorMessage = error.localizedDescription
      isWorkspaceDeletionErrorPresented = true
      return []
    }
  }

  @MainActor
  private func deleteWorkspaceItemsNow(
    _ entries: [WorkspaceEntry]
  ) throws -> [WorkspaceDeletedItem] {
    guard let folderURL = workspaceState.folderURL else {
      throw WorkspaceItemDeletionError.noActiveWorkspace
    }

    let didStartAccess = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        folderURL.stopAccessingSecurityScopedResource()
      }
    }

    let deletedItems = try WorkspaceItemDeletion.delete(entries, in: folderURL)
    finishWorkspaceItemDeletion(deletedItems, attemptedEntries: entries)
    return deletedItems
  }

  @MainActor
  private func finishWorkspaceItemDeletion(
    _ deletedItems: [WorkspaceDeletedItem],
    attemptedEntries entries: [WorkspaceEntry]
  ) {
    guard let folderURL = workspaceState.folderURL else {
      return
    }

    if !deletedItems.isEmpty {
      recordWorkspaceEngagement(in: folderURL)
    }

    let deletedPaths = Set(deletedItems.map(\.originalURL.locusStandardizedPath))
    for path in deletedPaths {
      documentTabs.closeTabs(underPath: path)
    }
    if let selectedEntryID,
      entries.contains(where: {
        $0.id == selectedEntryID && deletedPaths.contains($0.url.locusStandardizedPath)
      })
    {
      self.selectedEntryID = nil
    }

    startWorkspaceLoad(
      WorkspaceLoadRequest(
        folderURL: folderURL,
        showsLoading: false
      )
    )
  }

  @MainActor
  private func trashCreatedWorkspaceItem(_ url: URL) throws -> WorkspaceDeletedItem {
    guard let deletedItem = try trashWorkspaceItems([url]).first else {
      throw WorkspaceUndoFileOperationError.outsideWorkspace
    }
    return deletedItem
  }

  @MainActor
  private func trashWorkspaceItems(_ urls: [URL]) throws -> [WorkspaceDeletedItem] {
    guard let folderURL = workspaceState.folderURL else {
      throw WorkspaceUndoFileOperationError.noActiveWorkspace
    }

    let didStartAccess = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        folderURL.stopAccessingSecurityScopedResource()
      }
    }

    let deletedItems = try WorkspaceItemDeletion.deleteURLs(urls, in: folderURL)
    if !deletedItems.isEmpty {
      recordWorkspaceEngagement(in: folderURL)
    }
    let deletedPaths = Set(deletedItems.map(\.originalURL.locusStandardizedPath))
    for path in deletedPaths {
      documentTabs.closeTabs(underPath: path)
    }
    if let selectedEntryID, deletedPaths.contains(selectedEntryID) {
      self.selectedEntryID = nil
    }
    startWorkspaceLoad(
      WorkspaceLoadRequest(
        folderURL: folderURL,
        showsLoading: false
      )
    )
    return deletedItems
  }

  @MainActor
  private func restoreWorkspaceDeletedItems(
    _ deletedItems: [WorkspaceDeletedItem]
  ) throws -> [URL] {
    guard let folderURL = workspaceState.folderURL else {
      throw WorkspaceUndoFileOperationError.noActiveWorkspace
    }

    let didStartAccess = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        folderURL.stopAccessingSecurityScopedResource()
      }
    }

    let restoredURLs = try WorkspaceItemRestoration.restore(deletedItems)
    if !restoredURLs.isEmpty {
      recordWorkspaceEngagement(in: folderURL)
    }
    startWorkspaceLoad(
      WorkspaceLoadRequest(
        folderURL: folderURL,
        showsLoading: false,
        selectedURL: restoredURLs.first
      )
    )
    return restoredURLs
  }

  @MainActor
  private func moveWorkspaceItems(
    _ planned: [WorkspacePlannedMove]
  ) -> WorkspaceMoveExecution {
    guard let folderURL = workspaceState.folderURL else {
      return WorkspaceMoveExecution(failure: .noActiveWorkspace)
    }

    let didStartAccess = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        folderURL.stopAccessingSecurityScopedResource()
      }
    }

    let execution = WorkspaceItemMove.move(planned)
    finishWorkspaceItemMove(execution.moved, folderURL: folderURL)
    return execution
  }

  @MainActor
  private func importWorkspaceItems(
    _ planned: [WorkspacePlannedMove]
  ) async -> WorkspaceMoveExecution {
    guard let folderURL = workspaceState.folderURL else {
      return WorkspaceMoveExecution(failure: .noActiveWorkspace)
    }

    let didStartAccess = folderURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        folderURL.stopAccessingSecurityScopedResource()
      }
    }

    // Import copies bytes, so a large external file or folder would freeze the UI
    // if copied on the main actor (unlike move/trash/restore, which are
    // same-volume metadata renames). Run the copy off-main; security-scoped access
    // is process-wide and stays open across the await. State updates resume on the
    // main actor once the copy returns.
    let execution = await Task.detached {
      WorkspaceItemMove.copy(planned)
    }.value
    finishWorkspaceItemMove(execution.moved, folderURL: folderURL)
    return execution
  }

  @MainActor
  private func finishWorkspaceItemMove(_ moved: [WorkspaceMovedItem], folderURL: URL) {
    // `folderURL` was captured when the operation started; an import copy
    // suspends across an await, so the user may have browsed elsewhere by now.
    if !moved.isEmpty {
      recordWorkspaceEngagement(in: folderURL)
    }

    let movedSourcePaths = Set(moved.map(\.originalURL.locusStandardizedPath))
    if let selectedEntryID, movedSourcePaths.contains(selectedEntryID) {
      self.selectedEntryID = nil
    }

    startWorkspaceLoad(
      WorkspaceLoadRequest(
        folderURL: folderURL,
        showsLoading: false
      )
    )
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
      navigateToWorkspaceFolder(url)
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
  let imageDocumentStore: any ImageDocumentStoring
  let pdfDocumentStore: any PDFDocumentStoring
  let mediaDocumentStore: any MediaDocumentStoring
  let quickLookDocumentStore: any QuickLookDocumentStoring
  let gitWorkspaceStatusProvider: any GitWorkspaceStatusProviding
  @ObservedObject var terminalPanelState: TerminalPanelState
  @Binding var selectedEntryID: WorkspaceEntry.ID?
  @Binding var documentTabs: DocumentTabsState
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
          imageDocumentStore: imageDocumentStore,
          pdfDocumentStore: pdfDocumentStore,
          mediaDocumentStore: mediaDocumentStore,
          quickLookDocumentStore: quickLookDocumentStore,
          gitWorkspaceStatusProvider: gitWorkspaceStatusProvider,
          terminalPanelState: terminalPanelState,
          selectedEntryID: $selectedEntryID,
          documentTabs: $documentTabs,
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
  let deleteItems: ([WorkspaceEntry]) -> [WorkspaceDeletedItem]
  let trashCreatedItem: (URL) throws -> WorkspaceDeletedItem
  let trashItemsAtURLs: ([URL]) throws -> [WorkspaceDeletedItem]
  let restoreDeletedItems: ([WorkspaceDeletedItem]) throws -> [URL]
  let moveItems: ([WorkspacePlannedMove]) -> WorkspaceMoveExecution
  // Async because importing copies bytes (a large external file/folder), unlike
  // the same-volume rename that backs move/trash/restore.
  let importItems: ([WorkspacePlannedMove]) async -> WorkspaceMoveExecution
  let loadFolderChildren: (URL) async throws -> WorkspaceSnapshot
  let performOpenAction: (WorkspaceEntryOpenAction) -> Void
  // Real work in a loaded folder (opening a document, saving) promotes it
  // into Recent Folders; browsing alone never records. Callers pass the folder
  // they were built for, so late completions credit the right place. File
  // operations report engagement inside their HomeView implementations.
  let recordWorkspaceEngagement: (URL) -> Void
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
