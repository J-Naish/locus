import SwiftUI

@MainActor
private final class WorkspaceUndoRegistrar: NSObject {
  private var handlers: [UUID: @MainActor () -> Void] = [:]

  func store(_ handler: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    handlers[id] = handler
    return id
  }

  nonisolated func perform(_ id: UUID) {
    MainActor.assumeIsolated {
      guard let handler = handlers.removeValue(forKey: id) else {
        return
      }

      handler()
    }
  }

  func removeAll() {
    handlers.removeAll()
  }
}

struct WorkspaceBrowserView: View {
  private struct GitStatusRefreshKey: Hashable {
    let folderPath: String
    let loadedAt: Date
    let generation: UInt64
  }

  private struct GitMetadataMonitorKey: Hashable {
    let folderPath: String
    let generation: UInt64
  }

  private enum GitStatusRefresh {
    static let debounceDuration: Duration = .milliseconds(250)
  }

  private enum WorkspaceDropOperation: Equatable {
    case move
    case copy
  }

  private struct PlannedDropItem: Equatable {
    let operation: WorkspaceDropOperation
    let plan: WorkspacePlannedMove
  }

  private enum DropCollisionChoice {
    case replace
    case keepBoth
  }

  private struct PendingDropResolution: Equatable {
    var unresolved: [PlannedDropItem] = []
    var moveResolved: [WorkspacePlannedMove] = []
    var copyResolved: [WorkspacePlannedMove] = []
    // Destinations already claimed by this drop, so two dropped items that
    // would land on the same name are treated as collisions too.
    var reservedDestinations: Set<String> = []

    var currentCollision: PlannedDropItem? {
      unresolved.first
    }
  }

  /// A completed drop that can be undone and redone. `moved` are internal moves
  /// (reversed by moving back), `importedCopies` are copy destinations (undone
  /// by trashing, redone by restoring), and `replacedTrashed` are items trashed
  /// because the user chose Replace (undone by restoring, redone by trashing).
  private struct ReversibleDrop {
    var moved: [WorkspaceMovedItem] = []
    var importedCopies: [URL] = []
    var replacedTrashed: [WorkspaceDeletedItem] = []

    var isEmpty: Bool {
      moved.isEmpty && importedCopies.isEmpty && replacedTrashed.isEmpty
    }
  }

  let folderURL: URL
  let snapshot: WorkspaceSnapshot
  let loadedAt: Date
  let rootURL: URL?
  let recentFiles: [RecentFile]
  let recentFolders: [RecentFolder]
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
  @State private var openDocumentEntry: WorkspaceEntry?
  @State private var isDocumentTextInputFocused = false
  @State private var columnVisibility: NavigationSplitViewVisibility = .all
  @State private var gitStatusesByPath: [String: GitWorkspaceChangeKind] = [:]
  @State private var gitStatusRefreshGeneration: UInt64 = 0
  @State private var gitMetadataMonitor = GitRepositoryMetadataMonitor()
  @State private var gitMetadataMonitorGeneration: UInt64 = 0
  // Recursively watches the workspace tree so an external change inside a
  // subfolder (any depth, even while Locus is frontmost) refreshes the sidebar.
  @State private var workspaceTreeMonitor = WorkspaceTreeMonitor()
  @State private var gitRepositoryRootURL: URL?
  @State private var workspaceUndoErrorMessage: String?
  @State private var isWorkspaceUndoErrorPresented = false
  @State private var workspaceMoveErrorMessage: String?
  @State private var isWorkspaceMoveErrorPresented = false
  @State private var pendingDrop: PendingDropResolution?
  @State private var sidebarChildReloadToken = 0
  @State private var undoRegistrar = WorkspaceUndoRegistrar()
  @Environment(\.undoManager) private var undoManager
  @Environment(\.scenePhase) private var scenePhase

  init(
    folderURL: URL,
    snapshot: WorkspaceSnapshot,
    loadedAt: Date,
    rootURL: URL?,
    recentFiles: [RecentFile],
    recentFolders: [RecentFolder],
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
    self._openDocumentEntry = State(
      initialValue: Self.documentSurfaceEntry(
        for: selectedEntryID.wrappedValue,
        in: [WorkspaceEntry.workspaceRoot(at: folderURL)] + snapshot.entries
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
        // Creation reloads its target subfolder locally (the sidebar's
        // refreshCreationParentIfNeeded); only Git status needs a nudge here.
        // A global child reload would redundantly re-list every expanded folder.
        onItemCreated: requestGitStatusRefresh,
        dropItems: handleSidebarDrop,
        childReloadToken: sidebarChildReloadToken,
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
      clearWorkspaceUndoActions()
      searchQuery = ""
      isDocumentTextInputFocused = false
      openDocumentEntry = nil
      gitStatusesByPath = [:]
      gitRepositoryRootURL = nil
      gitStatusRefreshGeneration &+= 1
      gitMetadataMonitorGeneration &+= 1
      sidebarSelectionState.reset()
      refreshSearchResults()
    }
    .onChange(of: selectedEntryID) { _, newSelection in
      sidebarSelectionState.setActiveEntryID(newSelection)
      updateOpenDocumentEntry(for: newSelection, from: sidebarVisibleEntries)
    }
    .task(id: gitStatusRefreshKey) {
      await refreshGitStatuses()
    }
    .task(id: gitMetadataMonitorKey) {
      await refreshGitMetadataMonitoring()
    }
    .task(id: folderURL.locusStandardizedPath) {
      startWorkspaceTreeMonitoring()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active else {
        return
      }

      requestGitStatusRefresh()
      requestGitMetadataMonitorRefresh()
      // The directory monitor only watches the current folder, so a change an
      // agent made inside an expanded subfolder while Locus was in the background
      // would stay stale. Reload the expanded subtree on reactivation to catch up.
      requestSidebarChildReload()
    }
    .onDisappear {
      gitMetadataMonitor.stopMonitoring()
      workspaceTreeMonitor.stopMonitoring()
      clearWorkspaceUndoActions()
    }
    .focusedSceneValue(\.workspaceNavigationCommands, workspaceNavigationCommands)
    .focusedSceneValue(\.workspaceDeletionCommand, workspaceDeletionCommand)
    .focusedSceneValue(\.workspaceSidebarVisibilityCommand, workspaceSidebarVisibilityCommand)
    .alert("Couldn't Undo Change", isPresented: $isWorkspaceUndoErrorPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(workspaceUndoErrorMessage ?? "Locus couldn't undo the last workspace change.")
    }
    .alert(
      dropCollisionTitle,
      isPresented: dropCollisionPresentedBinding,
      presenting: pendingDrop?.currentCollision
    ) { collision in
      Button("Replace") {
        resolveCurrentDropCollision(.replace)
      }
      Button("Keep Both") {
        resolveCurrentDropCollision(.keepBoth)
      }
      Button("Cancel", role: .cancel) {
        cancelPendingDrop()
      }
    } message: { collision in
      Text("'\(collision.plan.destinationURL.lastPathComponent)' already exists in this folder.")
    }
    .alert("Couldn't Move Item", isPresented: $isWorkspaceMoveErrorPresented) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(workspaceMoveErrorMessage ?? "Locus couldn't complete the move.")
    }
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
    updateOpenDocumentEntry(for: selectedEntryID, from: sidebarVisibleEntries)

    if !WorkspaceEntrySearch.shouldKeepSelection(
      selectedEntryID,
      in: [rootEntry] + refreshedResults.visibleEntries)
    {
      selectedEntryID = nil
    }
  }

  private var workspaceNavigationCommands: WorkspaceNavigationCommands {
    let canGoBack = !isDocumentTextInputFocused && actions.canGoBack
    let canGoForward = !isDocumentTextInputFocused && actions.canGoForward

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

  private var workspaceDeletionCommand: WorkspaceDeletionCommand {
    let entries = deletableHighlightedEntries
    return WorkspaceDeletionCommand(
      canDelete: !isDocumentTextInputFocused && !entries.isEmpty,
      delete: {
        guard !entries.isEmpty else {
          return
        }

        _ = deleteEntries(entries)
      }
    )
  }

  private var workspaceSidebarVisibilityCommand: WorkspaceSidebarVisibilityCommand {
    WorkspaceSidebarVisibilityCommand(
      toggle: toggleSidebarVisibility
    )
  }

  private func toggleSidebarVisibility() {
    NativeSidebarToggle.toggle()
  }

  private var deletableHighlightedEntries: [WorkspaceEntry] {
    guard let highlightedEntryID = sidebarSelectionState.highlightedEntryID else {
      return []
    }

    guard let entry = sidebarVisibleEntries.first(where: { $0.id == highlightedEntryID }),
      isDeletable(entry)
    else {
      return []
    }

    return [entry]
  }

  private var sidebarActions: WorkspaceActions {
    WorkspaceActions(
      canGoBack: actions.canGoBack,
      canGoForward: actions.canGoForward,
      goBack: actions.goBack,
      goForward: actions.goForward,
      retryCurrentFolder: actions.retryCurrentFolder,
      copyPaths: actions.copyPaths,
      createItem: createItem,
      deleteItems: deleteEntries,
      trashCreatedItem: actions.trashCreatedItem,
      trashItemsAtURLs: actions.trashItemsAtURLs,
      restoreDeletedItems: actions.restoreDeletedItems,
      moveItems: actions.moveItems,
      importItems: actions.importItems,
      loadFolderChildren: actions.loadFolderChildren,
      performOpenAction: actions.performOpenAction
    )
  }

  private func isDeletable(_ entry: WorkspaceEntry) -> Bool {
    entry.id != folderURL.locusStandardizedPath
  }

  private func createItem(
    _ kind: WorkspaceItemCreationKind,
    named name: String,
    in targetFolderURL: URL
  ) async throws -> URL {
    let createdURL = try await actions.createItem(kind, name, targetFolderURL)
    registerCreatedItemUndo(kind: kind, url: createdURL)
    return createdURL
  }

  private func deleteEntries(_ entries: [WorkspaceEntry]) -> [WorkspaceDeletedItem] {
    let deletableEntries = entries.filter(isDeletable)
    guard !deletableEntries.isEmpty else {
      return []
    }

    let deletedItems = actions.deleteItems(deletableEntries)
    let deletedPaths = Set(deletedItems.map(\.originalURL.locusStandardizedPath))
    guard !deletedPaths.isEmpty else {
      return []
    }

    if let selectedEntryID,
      deletableEntries.contains(where: {
        $0.id == selectedEntryID && deletedPaths.contains($0.url.locusStandardizedPath)
      })
    {
      self.selectedEntryID = nil
      sidebarSelectionState.setActiveEntryID(nil)
    }
    registerDeletedItemsUndo(deletedItems)
    requestGitStatusRefresh()
    // The deleted item may live inside an expanded subfolder, which the root-only
    // directory monitor never sees; reload expanded children so it disappears.
    requestSidebarChildReload()
    return deletedItems
  }

  private func registerCreatedItemUndo(kind: WorkspaceItemCreationKind, url: URL) {
    registerUndoAction(named: kind.undoActionName) {
      undoCreatedItem(kind: kind, url: url)
    }
  }

  private func registerDeletedItemsUndo(_ deletedItems: [WorkspaceDeletedItem]) {
    registerUndoAction(named: WorkspaceItemDeletion.undoActionName(for: deletedItems)) {
      undoDeletedItems(deletedItems)
    }
  }

  private func registerUndoAction(
    named actionName: String,
    handler: @escaping @MainActor () -> Void
  ) {
    guard let undoManager else {
      return
    }

    let undoID = undoRegistrar.store(handler)
    undoManager.registerUndo(withTarget: undoRegistrar) { registrar in
      registrar.perform(undoID)
    }
    undoManager.setActionName(actionName)
  }

  private func clearWorkspaceUndoActions() {
    undoManager?.removeAllActions(withTarget: undoRegistrar)
    undoRegistrar.removeAll()
  }

  /// Shared refresh after an undone/redone file operation: git status plus the
  /// expanded-subfolder reloads — an undone/redone create or delete can land
  /// inside a subfolder the root monitor does not watch.
  private func refreshAfterUndoRedo() {
    requestGitStatusRefresh()
    requestSidebarChildReload()
  }

  private func presentWorkspaceUndoError(_ error: Error) {
    workspaceUndoErrorMessage = error.localizedDescription
    isWorkspaceUndoErrorPresented = true
  }

  private func undoCreatedItem(kind: WorkspaceItemCreationKind, url: URL) {
    do {
      let deletedItem = try actions.trashCreatedItem(url)
      if openDocumentEntry?.url.locusStandardizedPath == url.locusStandardizedPath {
        openDocumentEntry = nil
        selectedEntryID = nil
        sidebarSelectionState.setActiveEntryID(nil)
      }
      registerUndoAction(named: kind.undoActionName) {
        redoCreatedItem(kind: kind, deletedItem: deletedItem)
      }
      refreshAfterUndoRedo()
    } catch {
      presentWorkspaceUndoError(error)
    }
  }

  private func redoCreatedItem(kind: WorkspaceItemCreationKind, deletedItem: WorkspaceDeletedItem) {
    do {
      let restoredURLs = try actions.restoreDeletedItems([deletedItem])
      guard let restoredURL = restoredURLs.first else {
        return
      }

      registerCreatedItemUndo(kind: kind, url: restoredURL)
      refreshAfterUndoRedo()
    } catch {
      presentWorkspaceUndoError(error)
    }
  }

  private func undoDeletedItems(_ deletedItems: [WorkspaceDeletedItem]) {
    do {
      let restoredURLs = try actions.restoreDeletedItems(deletedItems)
      registerUndoAction(named: WorkspaceItemDeletion.undoActionName(for: deletedItems)) {
        redoDeletedItems(restoredURLs)
      }
      refreshAfterUndoRedo()
    } catch {
      presentWorkspaceUndoError(error)
    }
  }

  private func redoDeletedItems(_ urls: [URL]) {
    do {
      let deletedItems = try actions.trashItemsAtURLs(urls)
      guard !deletedItems.isEmpty else {
        return
      }

      registerDeletedItemsUndo(deletedItems)
      if let selectedEntryID,
        deletedItems.contains(where: { $0.originalURL.locusStandardizedPath == selectedEntryID })
      {
        self.selectedEntryID = nil
        sidebarSelectionState.setActiveEntryID(nil)
      }
      refreshAfterUndoRedo()
    } catch {
      presentWorkspaceUndoError(error)
    }
  }

  // MARK: - Drag-and-drop move/import

  private var dropCollisionTitle: String {
    "An Item With This Name Already Exists"
  }

  private var dropCollisionPresentedBinding: Binding<Bool> {
    Binding(
      get: { pendingDrop?.currentCollision != nil },
      set: { isPresented in
        if !isPresented {
          pendingDrop = nil
        }
      }
    )
  }

  private func handleSidebarDrop(_ urls: [URL], onto targetFolderURL: URL) {
    let (internalURLs, externalURLs) = WorkspaceItemMove.partitionByWorkspace(
      urls, workspaceURL: folderURL)

    do {
      var plannedItems: [PlannedDropItem] = []
      if !internalURLs.isEmpty {
        let moves = try WorkspaceItemMove.plannedMoves(
          for: internalURLs, into: targetFolderURL, workspaceURL: folderURL)
        plannedItems += moves.map { PlannedDropItem(operation: .move, plan: $0) }
      }
      if !externalURLs.isEmpty {
        let imports = try WorkspaceItemMove.plannedImports(
          for: externalURLs, into: targetFolderURL, workspaceURL: folderURL)
        plannedItems += imports.map { PlannedDropItem(operation: .copy, plan: $0) }
      }

      guard !plannedItems.isEmpty else {
        return
      }

      var resolution = PendingDropResolution()
      for item in plannedItems {
        let destinationPath = item.plan.destinationURL.locusStandardizedPath
        // Collide on either an existing on-disk item or another item from this
        // same drop that already claimed the destination name.
        if dropDestinationExists(item.plan.destinationURL)
          || resolution.reservedDestinations.contains(destinationPath)
        {
          resolution.unresolved.append(item)
        } else {
          resolution.reservedDestinations.insert(destinationPath)
          appendResolvedDropItem(item, to: &resolution)
        }
      }

      if resolution.unresolved.isEmpty {
        Task { await executeResolvedDrop(resolution) }
      } else {
        pendingDrop = resolution
      }
    } catch {
      presentMoveError(error)
    }
  }

  private func resolveCurrentDropCollision(_ choice: DropCollisionChoice) {
    guard var resolution = pendingDrop, !resolution.unresolved.isEmpty else {
      return
    }

    let collision = resolution.unresolved.removeFirst()
    switch choice {
    case .replace:
      let replacingPlan = WorkspacePlannedMove(
        sourceURL: collision.plan.sourceURL,
        destinationURL: collision.plan.destinationURL,
        replacesExisting: true
      )
      resolution.reservedDestinations.insert(collision.plan.destinationURL.locusStandardizedPath)
      appendResolvedDropItem(
        PlannedDropItem(operation: collision.operation, plan: replacingPlan), to: &resolution)
    case .keepBoth:
      let resolvedDestination = WorkspaceItemMove.disambiguatedURL(
        for: collision.plan.destinationURL
      ) { candidate in
        dropDestinationExists(candidate)
          || resolution.reservedDestinations.contains(candidate.locusStandardizedPath)
      }
      resolution.reservedDestinations.insert(resolvedDestination.locusStandardizedPath)
      let resolvedItem = PlannedDropItem(
        operation: collision.operation,
        plan: WorkspacePlannedMove(
          sourceURL: collision.plan.sourceURL, destinationURL: resolvedDestination)
      )
      appendResolvedDropItem(resolvedItem, to: &resolution)
    }

    if resolution.unresolved.isEmpty {
      pendingDrop = nil
      Task { await executeResolvedDrop(resolution) }
    } else {
      pendingDrop = resolution
    }
  }

  private func cancelPendingDrop() {
    pendingDrop = nil
  }

  private func appendResolvedDropItem(
    _ item: PlannedDropItem,
    to resolution: inout PendingDropResolution
  ) {
    switch item.operation {
    case .move:
      resolution.moveResolved.append(item.plan)
    case .copy:
      resolution.copyResolved.append(item.plan)
    }
  }

  private func dropDestinationExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
  }

  private func executeResolvedDrop(_ resolution: PendingDropResolution) async {
    let moveExecution =
      resolution.moveResolved.isEmpty ? nil : actions.moveItems(resolution.moveResolved)
    let importExecution =
      resolution.copyResolved.isEmpty ? nil : await actions.importItems(resolution.copyResolved)

    // Register undo for whatever actually landed, even if a later item failed,
    // so a partially-successful drop is still reversible.
    let record = ReversibleDrop(
      moved: moveExecution?.moved ?? [],
      importedCopies: importExecution?.moved.map(\.newURL) ?? [],
      replacedTrashed: (moveExecution?.replacedTrashed ?? [])
        + (importExecution?.replacedTrashed ?? [])
    )
    registerDropUndo(record, includesImport: importExecution != nil)
    requestGitStatusRefresh()
    requestSidebarChildReload()

    if let failure = moveExecution?.failure ?? importExecution?.failure {
      presentMoveError(failure)
    }
  }

  private func registerDropUndo(_ record: ReversibleDrop, includesImport: Bool) {
    guard !record.isEmpty else {
      return
    }

    registerUndoAction(named: dropActionName(for: record, includesImport: includesImport)) {
      undoDrop(record, includesImport: includesImport)
    }
  }

  private func dropActionName(for record: ReversibleDrop, includesImport: Bool) -> String {
    if record.moved.isEmpty && includesImport {
      let placeholders = record.importedCopies.map {
        WorkspaceMovedItem(originalURL: $0, newURL: $0)
      }
      return WorkspaceItemMove.importActionName(for: placeholders)
    }
    return WorkspaceItemMove.undoActionName(for: record.moved)
  }

  private func undoDrop(_ record: ReversibleDrop, includesImport: Bool) {
    // Build the redo from operations that actually completed and register it on
    // every exit path, so a step that fails partway leaves the undo stack
    // consistent with what really landed on disk rather than with the requested
    // set.
    var redoMoved: [WorkspaceMovedItem] = []
    var redoTrashedCopies: [WorkspaceDeletedItem] = []
    var redoReplacedOriginalURLs: [URL] = []
    defer {
      registerDropRedo(
        moved: redoMoved,
        trashedCopies: redoTrashedCopies,
        replacedOriginalURLs: redoReplacedOriginalURLs,
        includesImport: includesImport
      )
      requestGitStatusRefresh()
      requestSidebarChildReload()
    }

    // Reverse internal moves, vacating their destinations. Derive the redo set
    // from the moves that actually reversed and stop if any reverse move failed,
    // so we never trash/restore further items on top of an inconsistent state.
    if !record.moved.isEmpty {
      let reverse = record.moved.map {
        WorkspacePlannedMove(sourceURL: $0.newURL, destinationURL: $0.originalURL)
      }
      let execution = moveWorkspaceItemsForUndo(reverse)
      redoMoved = execution.moved.map {
        WorkspaceMovedItem(originalURL: $0.newURL, newURL: $0.originalURL)
      }
      if execution.failure != nil {
        return
      }
    }

    // Trash imported copies; keep the trashed items so redo can restore the
    // exact bytes rather than re-copying a possibly-changed external source.
    if !record.importedCopies.isEmpty {
      do {
        redoTrashedCopies = try actions.trashItemsAtURLs(record.importedCopies)
      } catch {
        // Preserve copies trashed before the failure so redo can still restore
        // them instead of orphaning them in the Trash.
        redoTrashedCopies = succeededTrashedItems(in: error)
        presentMoveError(error)
        return
      }
    }
    // Restore items that were replaced, now that their destinations are free.
    if !record.replacedTrashed.isEmpty {
      do {
        redoReplacedOriginalURLs = try actions.restoreDeletedItems(record.replacedTrashed)
      } catch {
        redoReplacedOriginalURLs = succeededRestoredURLs(in: error)
        presentMoveError(error)
        return
      }
    }
  }

  private func registerDropRedo(
    moved: [WorkspaceMovedItem],
    trashedCopies: [WorkspaceDeletedItem],
    replacedOriginalURLs: [URL],
    includesImport: Bool
  ) {
    guard !moved.isEmpty || !trashedCopies.isEmpty || !replacedOriginalURLs.isEmpty else {
      return
    }

    let actionName =
      moved.isEmpty
      ? WorkspaceItemMove.importActionName(
        for: trashedCopies.map {
          WorkspaceMovedItem(originalURL: $0.originalURL, newURL: $0.originalURL)
        })
      : WorkspaceItemMove.undoActionName(for: moved)

    registerUndoAction(named: actionName) {
      redoDrop(
        moved: moved,
        trashedCopies: trashedCopies,
        replacedOriginalURLs: replacedOriginalURLs,
        includesImport: includesImport
      )
    }
  }

  private func redoDrop(
    moved: [WorkspaceMovedItem],
    trashedCopies: [WorkspaceDeletedItem],
    replacedOriginalURLs: [URL],
    includesImport: Bool
  ) {
    // Build the undo from operations that actually completed and register it on
    // every exit path (mirrors undoDrop) so a failed forward move cannot leave
    // the undo stack describing items that never moved.
    var undoMoved: [WorkspaceMovedItem] = []
    var undoImportedCopies: [URL] = []
    var undoReplacedTrashed: [WorkspaceDeletedItem] = []
    defer {
      let record = ReversibleDrop(
        moved: undoMoved,
        importedCopies: undoImportedCopies,
        replacedTrashed: undoReplacedTrashed
      )
      registerDropUndo(record, includesImport: includesImport)
      requestGitStatusRefresh()
      requestSidebarChildReload()
    }

    // Re-trash the items that the drop originally replaced, freeing their
    // destinations before the moves/copies land again.
    do {
      if !replacedOriginalURLs.isEmpty {
        undoReplacedTrashed = try actions.trashItemsAtURLs(replacedOriginalURLs)
      }
    } catch {
      // Preserve items trashed before the failure so the registered undo can
      // restore them instead of orphaning them in the Trash.
      undoReplacedTrashed = succeededTrashedItems(in: error)
      presentMoveError(error)
      return
    }

    // Re-apply internal moves forward, recording only the moves that landed and
    // stopping if any forward move failed before restoring imported copies.
    if !moved.isEmpty {
      let forward = moved.map {
        WorkspacePlannedMove(sourceURL: $0.originalURL, destinationURL: $0.newURL)
      }
      let execution = moveWorkspaceItemsForUndo(forward)
      undoMoved = execution.moved
      if execution.failure != nil {
        return
      }
    }

    // Restore the imported copies to their destinations.
    do {
      if !trashedCopies.isEmpty {
        undoImportedCopies = try actions.restoreDeletedItems(trashedCopies)
      }
    } catch {
      undoImportedCopies = succeededRestoredURLs(in: error)
      presentMoveError(error)
    }
  }

  /// Items moved to the Trash before a partial-failure error. Trash and restore
  /// can fail partway, carrying the work that did complete in the thrown error;
  /// undo/redo recover it so those items stay reversible instead of orphaned.
  private func succeededTrashedItems(in error: Error) -> [WorkspaceDeletedItem] {
    if case WorkspaceItemDeletionError.partiallyDeleted(let succeededItems, _, _) = error {
      return succeededItems
    }
    return []
  }

  /// URLs restored from the Trash before a partial-failure error.
  private func succeededRestoredURLs(in error: Error) -> [URL] {
    if case WorkspaceItemRestorationError.partiallyRestored(let succeededURLs, _, _) = error {
      return succeededURLs
    }
    return []
  }

  /// Runs a reverse/forward move during undo/redo and surfaces any failure.
  private func moveWorkspaceItemsForUndo(_ planned: [WorkspacePlannedMove])
    -> WorkspaceMoveExecution
  {
    let execution = actions.moveItems(planned)
    if let failure = execution.failure {
      presentMoveError(failure)
    }
    return execution
  }

  private func requestSidebarChildReload() {
    sidebarChildReloadToken &+= 1
  }

  private func presentMoveError(_ error: Error) {
    workspaceMoveErrorMessage = error.localizedDescription
    isWorkspaceMoveErrorPresented = true
  }

  private var gitStatusRefreshKey: GitStatusRefreshKey {
    GitStatusRefreshKey(
      folderPath: folderURL.locusStandardizedPath,
      loadedAt: loadedAt,
      generation: gitStatusRefreshGeneration
    )
  }

  private var gitMetadataMonitorKey: GitMetadataMonitorKey {
    GitMetadataMonitorKey(
      folderPath: folderURL.locusStandardizedPath,
      generation: gitMetadataMonitorGeneration
    )
  }

  @MainActor
  private func refreshGitStatuses() async {
    do {
      try await Task.sleep(for: GitStatusRefresh.debounceDuration)
    } catch {
      return
    }

    guard !Task.isCancelled else {
      return
    }

    let repositoryRootURL = gitRepositoryRootURL
    let statuses = await gitWorkspaceStatusProvider.sidebarStatuses(
      for: folderURL,
      repositoryRootURL: repositoryRootURL
    )
    guard !Task.isCancelled else {
      return
    }

    gitStatusesByPath = statuses
  }

  @MainActor
  private func refreshGitMetadataMonitoring() async {
    guard let metadata = await gitWorkspaceStatusProvider.repositoryMetadata(for: folderURL) else {
      gitRepositoryRootURL = nil
      gitMetadataMonitor.stopMonitoring()
      return
    }

    guard !Task.isCancelled else {
      return
    }

    let previousRepositoryRootURL = gitRepositoryRootURL
    gitRepositoryRootURL = metadata.workTreeURL
    // Compare normalized path keys, not URL identity, so directory hints and
    // trailing slash differences do not trigger redundant refreshes.
    if previousRepositoryRootURL?.locusStandardizedPath
      != metadata.workTreeURL.locusStandardizedPath
    {
      requestGitStatusRefresh()
    }
    gitMetadataMonitor.startMonitoring(metadata) { change in
      requestGitStatusRefresh()
      if change == .metadataChanged {
        requestGitMetadataMonitorRefresh()
      }
    }
  }

  private func requestGitStatusRefresh() {
    gitStatusRefreshGeneration &+= 1
  }

  private func requestGitMetadataMonitorRefresh() {
    gitMetadataMonitorGeneration &+= 1
  }

  private func startWorkspaceTreeMonitoring() {
    workspaceTreeMonitor.startMonitoring(folderURL) {
      // An external change anywhere in the tree (any depth, even while Locus is
      // frontmost) reloads the expanded subfolders the root monitor doesn't watch
      // and refreshes Git status. The stream ignores the app's own edits, which
      // already refresh directly.
      requestSidebarChildReload()
      requestGitStatusRefresh()
    }
  }

  private var sidebarHighlight: Binding<WorkspaceEntry.ID?> {
    // The sidebar highlight is visual focus, while selectedEntryID is the
    // open document. Folder clicks move only the highlight so the current
    // preview/editor stays visible.
    Binding(
      get: {
        sidebarSelectionState.highlightedEntryID
      },
      set: { newHighlight in
        if let newHighlight {
          sidebarSelectionState.highlightSidebarEntry(newHighlight)
          if let entry = documentSurfaceEntry(for: newHighlight) {
            openDocumentEntry = entry
            selectedEntryID = newHighlight
          }
        } else {
          sidebarSelectionState.clearHighlightForEmptyAreaClick()
        }
      }
    )
  }

  private func documentSurfaceEntry(for entryID: WorkspaceEntry.ID) -> WorkspaceEntry? {
    Self.documentSurfaceEntry(for: entryID, in: sidebarVisibleEntries)
  }

  private static func documentSurfaceEntry(
    for entryID: WorkspaceEntry.ID?,
    in entries: [WorkspaceEntry]
  ) -> WorkspaceEntry? {
    guard let entryID,
      let entry = entries.first(where: { $0.id == entryID })
    else {
      return nil
    }

    // Use the open action as the source of truth for whether the document
    // surface should change. Folders browse; only in-place entries open here.
    guard case .openInPlace = WorkspaceEntryOpenActionResolver.action(for: [entry]) else {
      return nil
    }

    return entry
  }

  private func updateOpenDocumentEntry(
    for entryID: WorkspaceEntry.ID?,
    from entries: [WorkspaceEntry]
  ) {
    guard let entryID else {
      openDocumentEntry = nil
      return
    }

    if let entry = Self.documentSurfaceEntry(for: entryID, in: entries) {
      openDocumentEntry = entry
    }
  }

  private func updateSidebarVisibleEntries(_ entries: [WorkspaceEntry]) {
    sidebarVisibleEntries = entries
    sidebarSelectionState.setVisibleEntryIDs(Set(entries.map(\.id)))
    updateOpenDocumentEntry(for: selectedEntryID, from: entries)
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
          entry: openDocumentEntry,
          imageDocumentStore: imageDocumentStore,
          pdfDocumentStore: pdfDocumentStore,
          mediaDocumentStore: mediaDocumentStore,
          quickLookDocumentStore: quickLookDocumentStore,
          onTextInputFocusChange: { isFocused in
            isDocumentTextInputFocused = isFocused
          },
          onDocumentSaved: requestGitStatusRefresh
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
