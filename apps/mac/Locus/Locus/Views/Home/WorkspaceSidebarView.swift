import SwiftUI

extension GitWorkspaceChangeKind {
  fileprivate var sidebarTextColor: Color {
    switch self {
    case .modified:
      return Color(nsColor: .systemYellow)
    case .added:
      return Color(nsColor: .systemGreen)
    case .ignored:
      return .secondary
    }
  }

  fileprivate var dimsSidebarSymbol: Bool {
    self == .ignored
  }

  fileprivate var accessibilityDescription: String {
    switch self {
    case .modified:
      return "modified"
    case .added:
      return "added"
    case .ignored:
      return "ignored"
    }
  }

  /// A compact, color-independent status letter (Xcode-style "M"/"A") so the
  /// change state reads without relying on text color alone — important for
  /// contrast and color-vision differences. `ignored` has no letter; it is
  /// conveyed by dimming the row instead.
  fileprivate var sidebarStatusLetter: String? {
    switch self {
    case .modified:
      return "M"
    case .added:
      return "A"
    case .ignored:
      return nil
    }
  }
}

/// Trailing status glyph for a sidebar row. Pairs the Git text color with a
/// distinct letter shape so modified vs. added is distinguishable without color.
private struct WorkspaceSidebarGitStatusBadge: View {
  let gitStatus: GitWorkspaceChangeKind?

  var body: some View {
    if let gitStatus, let letter = gitStatus.sidebarStatusLetter {
      Text(letter)
        .font(.caption2.weight(.semibold))
        .monospaced()
        .foregroundStyle(gitStatus.sidebarTextColor)
        // The row's merged accessibility label already states the change kind.
        .accessibilityHidden(true)
    }
  }
}

struct WorkspaceSidebarView: View {
  let folderURL: URL
  let entries: [WorkspaceEntry]
  let recentFolders: [RecentFolder]
  private let gitStatusLookup: GitSidebarStatusLookup
  private let rootEntry: WorkspaceEntry
  @Binding var highlightedEntryID: WorkspaceEntry.ID?
  let shortcutActions: FileLocationShortcutActions
  let actions: WorkspaceActions
  let onItemCreated: () -> Void
  let dropItems: ([URL], URL) -> Void
  // Bumped by the parent after a move/import so the sidebar reloads cached
  // children of expanded folders, whose contents the root reload doesn't touch.
  let childReloadToken: Int
  let onVisibleEntriesChange: ([WorkspaceEntry]) -> Void
  @State private var expandedFolderIDs: Set<WorkspaceEntry.ID> = []
  @State private var childStates: [WorkspaceEntry.ID: WorkspaceSidebarChildState] = [:]
  @State private var childLoadTasks: [WorkspaceEntry.ID: Task<Void, Never>] = [:]
  @State private var childLoadTokens: [WorkspaceEntry.ID: UUID] = [:]
  @State private var expansionGeneration: UInt64 = 0
  @State private var isRootExpanded = true
  @State private var visibleRows: [WorkspaceSidebarRow] = []
  // True while a drag targets the workspace root (the empty area / no folder row),
  // driving the root drop affordance. Folder rows show their own row highlight.
  @State private var isRootDropTargeted = false
  @State private var creationKind: WorkspaceItemCreationKind?
  @State private var creationParent: WorkspaceEntry?
  @State private var creationName = ""
  @State private var creationErrorMessage: String?
  @State private var isCreatingItem = false
  @State private var creationTask: Task<Void, Never>?
  @AppStorage(LocusPersistedDefaults.recentFoldersExpanded)
  private var isRecentFoldersExpanded = false
  // Drives keyboard focus onto the sidebar List. A row's `.draggable` swallows
  // the mouse-down that would normally make the underlying table the first
  // responder, so selecting via the tap gesture leaves the List unfocused and
  // the native source-list highlight renders gray. Focusing the List on select
  // keeps the selected row drawn in the focused (accent) color.
  @FocusState private var isListFocused: Bool

  init(
    folderURL: URL,
    entries: [WorkspaceEntry],
    recentFolders: [RecentFolder],
    gitStatusesByPath: [String: GitWorkspaceChangeKind],
    highlightedEntryID: Binding<WorkspaceEntry.ID?>,
    shortcutActions: FileLocationShortcutActions,
    actions: WorkspaceActions,
    onItemCreated: @escaping () -> Void,
    dropItems: @escaping ([URL], URL) -> Void,
    childReloadToken: Int,
    onVisibleEntriesChange: @escaping ([WorkspaceEntry]) -> Void
  ) {
    self.folderURL = folderURL
    self.entries = entries
    self.recentFolders = recentFolders
    self.gitStatusLookup = GitSidebarStatusLookup(
      gitStatusesByPath,
      walkLimitPath: folderURL.locusStandardizedPath
    )
    self.rootEntry = WorkspaceEntry.workspaceRoot(at: folderURL)
    self._highlightedEntryID = highlightedEntryID
    self.shortcutActions = shortcutActions
    self.actions = actions
    self.onItemCreated = onItemCreated
    self.dropItems = dropItems
    self.childReloadToken = childReloadToken
    self.onVisibleEntriesChange = onVisibleEntriesChange
  }

  var body: some View {
    VStack(spacing: 0) {
      List(selection: $highlightedEntryID) {
        ForEach(visibleRows) { row in
          switch row.content {
          case .entry(let entry):
            WorkspaceSidebarEntryRow(
              entry: entry,
              depth: row.depth,
              gitStatus: gitStatus(for: entry),
              isExpanded: isExpanded(entry),
              isSelected: highlightedEntryID == entry.id,
              toggleExpansion: {
                toggleExpansion(for: entry)
              },
              onSelect: {
                highlightedEntryID = entry.id
                // Move first responder to the List so the selection renders in
                // the focused (accent) color rather than the unfocused gray.
                isListFocused = true
              },
              onActivate: {
                performPrimaryAction(for: [entry.id])
              },
              onDropURLs: { urls in
                handleDrop(urls, onto: entry)
              }
            )
            .tag(entry.id)
          case .creation(let kind):
            WorkspaceSidebarCreationRow(
              kind: kind,
              name: $creationName,
              errorMessage: creationErrorMessage,
              isCreating: isCreatingItem,
              submit: createPendingItem,
              cancel: cancelCreation,
              focusLost: cancelCreation
            )
            .padding(.leading, CGFloat(row.depth) * WorkspaceSidebarMetrics.depthIndent)
          case .status(let status):
            WorkspaceSidebarStatusRow(status: status, depth: row.depth)
          }
        }
      }
      .listStyle(.sidebar)
      .scrollContentBackground(.hidden)
      .focused($isListFocused)
      .contextMenu(forSelectionType: WorkspaceEntry.ID.self) { selection in
        let selectedEntries = entries(for: selection)
        let creationParent = creationParent(for: selectedEntries)
        let deletableEntries = selectedEntries.filter(isDeletable)

        Button {
          beginCreation(.file, in: creationParent)
        } label: {
          Label("New File", systemImage: "doc")
        }

        Button {
          beginCreation(.folder, in: creationParent)
        } label: {
          Label("New Folder", systemImage: "folder")
        }

        Divider()

        Button(role: .destructive) {
          deleteEntries(deletableEntries)
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .disabled(deletableEntries.isEmpty)

        Divider()

        Button(WorkspaceEntryPathCopy.menuTitle(for: selectedEntries)) {
          actions.copyPaths(selectedEntries)
        }
        .disabled(selectedEntries.isEmpty)
      } primaryAction: { selection in
        // Keep row double-click, Return, and VoiceOver default actions on the
        // native List path; folder expansion belongs to the disclosure Button.
        performPrimaryAction(for: selection)
      }
      .accessibilityIdentifier("workspace-sidebar-list")
      .overlay {
        WorkspaceSidebarEmptyAreaClickHandler(
          clearSelection: {
            highlightedEntryID = nil
          },
          beginNewFile: {
            // Empty-area creation is not associated with a specific row, so it
            // always starts at the workspace root.
            beginCreation(.file, in: rootEntry)
          }
        )
      }
      // A drop that is not on a folder row — the empty area below the rows, or a
      // file/status row — imports into the workspace root. Folder rows keep their
      // own `.dropDestination` deeper in the view tree, so SwiftUI routes a
      // folder-row drop there and this handles only the remaining area. Being the
      // same SwiftUI drop system as the rows, it composes instead of stealing row
      // drops the way the former AppKit overlay did.
      .dropDestination(for: URL.self) { urls, _ in
        handleDrop(urls, onto: rootEntry)
        return true
      } isTargeted: { targeted in
        isRootDropTargeted = targeted
      }
      // Root drop affordance: a drag over the empty area (no folder row claims it,
      // so this List-level destination is the target) washes the whole sidebar in
      // the accent color, mirroring how a folder row highlights. Driven by this
      // destination's own `isTargeted`, so it stays off while a folder row is the
      // target and never competes with the per-row highlight.
      .overlay {
        if isRootDropTargeted {
          RoundedRectangle(
            cornerRadius: WorkspaceSidebarMetrics.dropHighlightCornerRadius, style: .continuous
          )
          .strokeBorder(
            Color.accentColor, lineWidth: WorkspaceSidebarMetrics.rootDropHighlightBorderWidth
          )
          .background(
            RoundedRectangle(
              cornerRadius: WorkspaceSidebarMetrics.dropHighlightCornerRadius, style: .continuous
            )
            .fill(Color.accentColor.opacity(WorkspaceSidebarMetrics.rootDropHighlightFillOpacity))
          )
          .padding(WorkspaceSidebarMetrics.rootDropHighlightInset)
          .allowsHitTesting(false)
        }
      }
      .animation(.easeOut(duration: 0.12), value: isRootDropTargeted)
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
    // Let the single window-level field background show through so the sidebar
    // and document area stay on one continuous glass surface.
    .background(Color.clear)
    .onAppear {
      publishVisibleEntries()
    }
    .onDisappear {
      cancelCreationTask()
      cancelAllChildLoads()
    }
    .onChange(of: entries) {
      pruneExpansion(for: entries)
    }
    .onChange(of: childReloadToken) {
      reloadExpandedChildren()
    }
    .onChange(of: folderURL) {
      cancelCreation()
      resetExpansion()
    }
  }

  private func currentRows() -> [WorkspaceSidebarRow] {
    var result = [WorkspaceSidebarRow(entry: rootEntry, depth: 0)]
    if isRootExpanded {
      result.append(
        contentsOf: rows(
          for: entries,
          depth: 1,
          pendingCreationKind: creationParent?.id == rootEntry.id ? creationKind : nil
        )
      )
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
    visibleRows.compactMap(\.entry).filter { selection.contains($0.id) }
  }

  private func creationParent(for selectedEntries: [WorkspaceEntry]) -> WorkspaceEntry {
    guard selectedEntries.count == 1, let selectedEntry = selectedEntries.first,
      selectedEntry.kind.isDirectoryLike
    else {
      return rootEntry
    }

    return selectedEntry
  }

  private func isDeletable(_ entry: WorkspaceEntry) -> Bool {
    entry.id != rootEntry.id
  }

  private func deleteEntries(_ entries: [WorkspaceEntry]) {
    let deletableEntries = entries.filter(isDeletable)
    guard !deletableEntries.isEmpty else {
      return
    }

    cancelCreation()
    _ = actions.deleteItems(deletableEntries)
  }

  private func isExpanded(_ entry: WorkspaceEntry) -> Bool {
    entry.id == rootEntry.id ? isRootExpanded : expandedFolderIDs.contains(entry.id)
  }

  private func gitStatus(for entry: WorkspaceEntry) -> GitWorkspaceChangeKind? {
    gitStatusLookup.status(for: entry.id)
  }

  private func handleDrop(_ urls: [URL], onto entry: WorkspaceEntry) {
    guard entry.kind.isDirectoryLike, !urls.isEmpty else {
      return
    }

    dropItems(urls, entry.url)
  }

  private func rows(
    for entries: [WorkspaceEntry],
    depth: Int,
    pendingCreationKind: WorkspaceItemCreationKind? = nil
  ) -> [WorkspaceSidebarRow] {
    var result: [WorkspaceSidebarRow] = []
    let pendingCreationInsertionIndex = pendingCreationKind.map {
      WorkspaceItemCreationPlacement.insertionIndex(for: $0, in: entries)
    }

    func insertCreationIfNeeded(at index: Int) {
      guard let pendingCreationKind, pendingCreationInsertionIndex == index else {
        return
      }

      result.append(.creation(pendingCreationKind, depth: depth))
    }

    func appendChildCreation(_ kind: WorkspaceItemCreationKind?) {
      guard let kind else {
        return
      }

      result.append(.creation(kind, depth: depth + 1))
    }

    for (index, entry) in entries.enumerated() {
      insertCreationIfNeeded(at: index)

      result.append(WorkspaceSidebarRow(entry: entry, depth: depth))

      guard entry.kind.isDirectoryLike, expandedFolderIDs.contains(entry.id) else {
        continue
      }

      let childCreationKind = creationParent?.id == entry.id ? self.creationKind : nil

      switch childStates[entry.id] {
      case .loading:
        appendChildCreation(childCreationKind)
        result.append(.status(.loading(parentID: entry.id), depth: depth + 1))
      case .loaded(let snapshot):
        if snapshot.entries.isEmpty {
          appendChildCreation(childCreationKind)
        } else {
          result.append(
            contentsOf: rows(
              for: snapshot.entries,
              depth: depth + 1,
              pendingCreationKind: childCreationKind
            )
          )
        }

        if !snapshot.partialErrors.isEmpty {
          result.append(.status(.partialErrors(parentID: entry.id), depth: depth + 1))
        }
      case .failed:
        appendChildCreation(childCreationKind)
        result.append(.status(.failed(parentID: entry.id), depth: depth + 1))
      case .pending, nil:
        appendChildCreation(childCreationKind)
        break
      }
    }

    insertCreationIfNeeded(at: entries.endIndex)
    return result
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
    visibleRows.compactMap(\.entry)
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
    guard entry.kind.isDirectoryLike else {
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

  /// Refreshes the children of every currently-expanded folder after an external
  /// change, a move/import, or app reactivation (the root reload doesn't touch
  /// subfolder caches). Visible folders refresh *in place* — their current
  /// children stay on screen until the new listing arrives — so the subtree never
  /// flashes empty, which matters because reactivation can fire on every app
  /// switch. Collapsed (non-visible) folders drop their stale cache and reload
  /// fresh the next time they are expanded.
  private func reloadExpandedChildren() {
    // Capture the visible expanded folders before mutating state; the recursion
    // reads the existing child snapshots.
    let entriesToReload = expandedDirectoryEntries()
    let visibleExpandedIDs = Set(entriesToReload.map(\.id))

    expansionGeneration &+= 1
    cancelAllChildLoads()
    // Keep the visible expanded folders' children on screen; drop everything else
    // so a re-expanded folder reloads fresh rather than showing a stale cache.
    childStates = childStates.filter { visibleExpandedIDs.contains($0.key) }
    publishVisibleEntries()

    for entry in entriesToReload {
      refreshLoadedChild(for: entry)
    }
  }

  /// Re-lists an expanded folder while leaving its current children on screen,
  /// swapping in the new listing only once it arrives and only if it differs.
  /// Unlike `loadChildrenIfNeeded`, it refreshes a folder that is already
  /// `.loaded` without first clearing it, so a reload never flashes empty.
  /// True while a child-load task's result is still wanted: the task is not
  /// cancelled, no newer expansion pass started, and the folder is still
  /// expanded. Shared by every load/refresh guard so the currency rule lives
  /// (and changes) in one place.
  private func childLoadIsCurrent(for entry: WorkspaceEntry, generation: UInt64) -> Bool {
    !Task.isCancelled && generation == expansionGeneration
      && expandedFolderIDs.contains(entry.id)
  }

  /// Clears an entry's load bookkeeping if `token` still identifies its current
  /// task (otherwise a newer task owns the entries and is left alone).
  private func finishChildLoadTask(for entry: WorkspaceEntry, token: UUID) {
    if childLoadTokens[entry.id] == token {
      childLoadTasks[entry.id] = nil
      childLoadTokens[entry.id] = nil
    }
  }

  private func refreshLoadedChild(for entry: WorkspaceEntry) {
    let generation = expansionGeneration
    let loadToken = UUID()
    childLoadTokens[entry.id] = loadToken
    childLoadTasks[entry.id] = Task { @MainActor in
      defer { finishChildLoadTask(for: entry, token: loadToken) }

      do {
        let snapshot = try await actions.loadFolderChildren(entry.url)
        guard childLoadIsCurrent(for: entry, generation: generation),
          childLoadTokens[entry.id] == loadToken,
          childStates[entry.id] != .loaded(snapshot)
        else {
          return
        }

        childStates[entry.id] = .loaded(snapshot)
        publishVisibleEntries()
      } catch {
        // Keep the existing children on a refresh failure; the next trigger retries.
        return
      }
    }
  }

  private func expandedDirectoryEntries() -> [WorkspaceEntry] {
    var result: [WorkspaceEntry] = []

    func collect(_ entries: [WorkspaceEntry]) {
      for entry in entries
      where entry.kind.isDirectoryLike && expandedFolderIDs.contains(entry.id) {
        result.append(entry)
        if case .loaded(let snapshot) = childStates[entry.id] {
          collect(snapshot.entries)
        }
      }
    }

    collect(entries)
    return result
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
      defer { finishChildLoadTask(for: entry, token: loadToken) }

      do {
        guard childLoadIsCurrent(for: entry, generation: generation) else {
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
        guard childLoadIsCurrent(for: entry, generation: generation) else {
          return
        }

        childStates[entry.id] = .loaded(snapshot)
      } catch is CancellationError {
        return
      } catch {
        guard childLoadIsCurrent(for: entry, generation: generation) else {
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
    visibleRows = currentRows()
    onVisibleEntriesChange(visibleEntries())
  }

  private func beginCreation(_ kind: WorkspaceItemCreationKind, in parent: WorkspaceEntry) {
    cancelCreationTask()
    if parent.id == rootEntry.id {
      isRootExpanded = true
    } else {
      expandedFolderIDs.insert(parent.id)
    }

    creationKind = kind
    creationParent = parent
    creationName = ""
    creationErrorMessage = nil
    isCreatingItem = false
    highlightedEntryID = nil
    publishVisibleEntries()
  }

  private func createPendingItem() {
    guard let creationKind, let creationParent, !isCreatingItem else {
      return
    }

    cancelCreationTask()
    creationErrorMessage = nil
    isCreatingItem = true
    let name = creationName
    creationTask = Task { @MainActor in
      defer {
        creationTask = nil
        isCreatingItem = false
      }

      do {
        _ = try await actions.createItem(creationKind, name, creationParent.url)
        onItemCreated()
        refreshCreationParentIfNeeded(creationParent)
        clearCreationState()
      } catch {
        guard !Task.isCancelled else {
          return
        }

        creationErrorMessage = error.localizedDescription
      }
    }
  }

  private func cancelCreation() {
    cancelCreationTask()
    clearCreationState()
  }

  private func clearCreationState() {
    creationKind = nil
    creationParent = nil
    creationName = ""
    creationErrorMessage = nil
    isCreatingItem = false
    publishVisibleEntries()
  }

  private func refreshCreationParentIfNeeded(_ parent: WorkspaceEntry) {
    guard parent.id != rootEntry.id else {
      return
    }

    cancelChildLoad(for: parent.id)
    childStates[parent.id] = nil
    expandedFolderIDs.insert(parent.id)
    loadChildrenIfNeeded(for: parent)
  }

  private func cancelCreationTask() {
    creationTask?.cancel()
    creationTask = nil
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
        .padding(.bottom, WorkspaceSidebarMetrics.recentFoldersExpandedBottomPadding)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, WorkspaceSidebarMetrics.recentFoldersBottomPadding)
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
        // Inset only the highlight pill so it stays within the sidebar panel
        // instead of spanning the full column width and overflowing its rounded
        // edge. `.contentShape` above keeps the row's full-width hit target.
        RoundedRectangle(cornerRadius: 5)
          .fill(
            isHovered
              ? Color.primary.opacity(WorkspaceSidebarMetrics.rowHoverHighlightOpacity)
              : Color.clear
          )
          .padding(.horizontal, 12)
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
  }
}

private struct WorkspaceSidebarEmptyAreaClickHandler: NSViewRepresentable {
  let clearSelection: () -> Void
  let beginNewFile: () -> Void

  func makeNSView(context: Context) -> WorkspaceSidebarEmptyAreaClickHandlerView {
    let view = WorkspaceSidebarEmptyAreaClickHandlerView()
    view.clearSelection = clearSelection
    view.beginNewFile = beginNewFile
    return view
  }

  func updateNSView(
    _ nsView: WorkspaceSidebarEmptyAreaClickHandlerView,
    context: Context
  ) {
    nsView.clearSelection = clearSelection
    nsView.beginNewFile = beginNewFile
    nsView.resolveTableViewSoon()
  }

  static func dismantleNSView(
    _ nsView: WorkspaceSidebarEmptyAreaClickHandlerView,
    coordinator: ()
  ) {
    nsView.invalidate()
  }
}

private final class WorkspaceSidebarEmptyAreaClickHandlerView: NSView {
  var clearSelection: () -> Void = {}
  var beginNewFile: () -> Void = {}
  private weak var tableView: NSTableView?
  private var eventMonitor: Any?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()

    if window == nil {
      removeEventMonitor()
    } else {
      installEventMonitorIfNeeded()
      resolveTableViewSoon()
    }
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    resolveTableViewSoon()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  func invalidate() {
    removeEventMonitor()
    tableView = nil
  }

  func resolveTableViewSoon() {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        return
      }

      tableView = findSidebarTableView()
    }
  }

  private func installEventMonitorIfNeeded() {
    guard eventMonitor == nil else {
      return
    }

    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
      [weak self] event in
      self?.handleClickIfInEmptyListArea(event)
      return event
    }
  }

  private func removeEventMonitor() {
    guard let eventMonitor else {
      return
    }

    NSEvent.removeMonitor(eventMonitor)
    self.eventMonitor = nil
  }

  private func handleClickIfInEmptyListArea(_ event: NSEvent) {
    guard let window, event.window === window else {
      return
    }

    let pointInSelf = convert(event.locationInWindow, from: nil)
    guard bounds.contains(pointInSelf) else {
      return
    }

    guard let tableView = tableView ?? findSidebarTableView() else {
      return
    }

    self.tableView = tableView
    let pointInTable = tableView.convert(event.locationInWindow, from: nil)
    guard tableView.bounds.contains(pointInTable) else {
      return
    }

    guard tableView.row(at: pointInTable) == -1 else {
      return
    }

    guard event.clickCount == 2 else {
      if event.clickCount == 1 {
        clearSelection()
      }
      return
    }

    beginNewFile()
  }

  private func findSidebarTableView() -> NSTableView? {
    locusNearbySidebarTableView()
  }
}

extension NSView {
  fileprivate func descendantTableViews() -> [NSTableView] {
    var result: [NSTableView] = []
    var stack = subviews

    while let view = stack.popLast() {
      if let tableView = view as? NSTableView {
        result.append(tableView)
      }

      stack.append(contentsOf: view.subviews)
    }

    return result
  }

  /// The sidebar's backing `NSTableView` nearest this marker view: the smallest
  /// table whose frame overlaps the marker, in the same window. Used by the
  /// empty-area click overlay, which sits over the List but needs the table to
  /// tell the empty area from the rows.
  fileprivate func locusNearbySidebarTableView() -> NSTableView? {
    guard let window, let contentView = window.contentView else {
      return nil
    }

    let markerFrame = convert(bounds, to: nil)
    return contentView.descendantTableViews()
      .filter { tableView in
        guard tableView.window === window else {
          return false
        }

        let tableFrame =
          tableView.enclosingScrollView?.convert(
            tableView.enclosingScrollView?.bounds ?? tableView.bounds,
            to: nil
          ) ?? tableView.convert(tableView.bounds, to: nil)

        return tableFrame.intersects(markerFrame)
      }
      .min { lhs, rhs in
        lhs.convert(lhs.bounds, to: nil).area < rhs.convert(rhs.bounds, to: nil).area
      }
  }
}

extension NSRect {
  fileprivate var area: CGFloat {
    width * height
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
  static let iconColumnWidth: CGFloat = 18
  static let systemIconFontSize: CGFloat = 15
  static let recentFoldersHeaderHeight: CGFloat = 28
  static let recentFolderRowHeight: CGFloat = 28
  static let recentFoldersMaximumHeight: CGFloat = 224
  // Small bottom margin kept in both states so even a collapsed section isn't
  // flush against the sidebar bottom.
  static let recentFoldersBottomPadding: CGFloat = 2
  // Extra breathing room below the last folder row while expanded, added on top
  // of the base margin above (so the expanded section shows their sum).
  static let recentFoldersExpandedBottomPadding: CGFloat = 10
  static let symlinkBadgeSize: CGFloat = 7
  static let symlinkBadgeOffset = CGSize(width: 4, height: 3)

  // Row highlight shape, shared by the drop-target highlight (dragging onto a
  // folder) and the hover highlight.
  static let dropHighlightCornerRadius: CGFloat = 10
  static let dropHighlightOpacity: Double = 0.2
  // Faint gray shown while hovering an unselected row (matches the recent
  // folders hover).
  static let rowHoverHighlightOpacity: Double = 0.08
  // Bleed so the highlight reaches the edges of the sidebar row cell rather than
  // only covering the row content, matching the selection band on all sides. The
  // `.sidebar` row insets that create these gaps have no public API, so these are
  // tuned by eye; adjust if the highlight leaves a gap or overflows the row.
  static let dropHighlightVerticalExpansion: CGFloat = 8
  static let dropHighlightHorizontalExpansion: CGFloat = 5

  // Accent wash + border shown over the whole sidebar while a drag targets the
  // workspace root (the empty area), so dropping there reads as adding to the root.
  static let rootDropHighlightInset: CGFloat = 4
  static let rootDropHighlightFillOpacity: Double = 0.1
  static let rootDropHighlightBorderWidth: CGFloat = 2

  // Drag preview pill shown while an entry is being dragged.
  static let dragPreviewSpacing: CGFloat = 6
  static let dragPreviewHorizontalPadding: CGFloat = 12
  static let dragPreviewVerticalPadding: CGFloat = 7
  static let dragPreviewCornerRadius: CGFloat = 8
  static let dragPreviewShadowRadius: CGFloat = 8
  static let dragPreviewShadowOffsetY: CGFloat = 2
  static let dragPreviewShadowOpacity: Double = 0.25

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
    case creation(WorkspaceItemCreationKind)
    case status(WorkspaceSidebarStatus)
  }

  let content: Content
  let depth: Int

  var id: String {
    switch content {
    case .entry(let entry):
      entry.id
    case .creation(let kind):
      "workspace-sidebar-creation-\(kind.idComponent)"
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

  static func creation(
    _ kind: WorkspaceItemCreationKind,
    depth: Int
  ) -> WorkspaceSidebarRow {
    WorkspaceSidebarRow(content: .creation(kind), depth: depth)
  }

  private init(content: Content, depth: Int) {
    self.content = content
    self.depth = depth
  }
}

extension WorkspaceItemCreationKind {
  fileprivate var idComponent: String {
    switch self {
    case .file:
      return "file"
    case .folder:
      return "folder"
    }
  }

  fileprivate var sidebarSymbolName: String {
    switch self {
    case .file:
      return "doc"
    case .folder:
      return "folder"
    }
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

private struct WorkspaceSidebarCreationRow: View {
  let kind: WorkspaceItemCreationKind
  @Binding var name: String
  let errorMessage: String?
  let isCreating: Bool
  let submit: () -> Void
  let cancel: () -> Void
  let focusLost: () -> Void
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 6) {
      Color.clear
        .frame(width: WorkspaceSidebarMetrics.chevronColumnWidth)
        .accessibilityHidden(true)

      Image(systemName: kind.sidebarSymbolName)
        .foregroundStyle(kind == .folder ? .blue : .secondary)
        .padding(.top, 3)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          TextField("Name", text: $name)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .disabled(isCreating)
            .onSubmit(submit)
            .onExitCommand(perform: cancel)
            .accessibilityIdentifier("workspace-sidebar-creation-name-field")

          if isCreating {
            ProgressView()
              .controlSize(.small)
              .accessibilityLabel(Text("Creating"))
          }
        }
        .overlay {
          if errorMessage != nil {
            RoundedRectangle(cornerRadius: 5)
              .stroke(Color.red.opacity(0.7), lineWidth: 1)
          }
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("workspace-sidebar-creation-error")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task {
      isFocused = true
    }
    .onChange(of: isFocused) { _, isFocused in
      guard !isFocused, !isCreating else {
        return
      }
      guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return
      }

      focusLost()
    }
  }
}

/// Attaches a file-URL drop destination only to folder-like rows so files and
/// status rows never appear as drop targets.
private struct WorkspaceSidebarDropTarget: ViewModifier {
  let isEnabled: Bool
  @Binding var isTargeted: Bool
  let onDrop: ([URL]) -> Void

  func body(content: Content) -> some View {
    if isEnabled {
      content.dropDestination(for: URL.self) { urls, _ in
        onDrop(urls)
        return true
      } isTargeted: { targeted in
        isTargeted = targeted
      }
    } else {
      content
    }
  }
}

private struct WorkspaceSidebarEntryRow: View {
  let entry: WorkspaceEntry
  let depth: Int
  let gitStatus: GitWorkspaceChangeKind?
  let isExpanded: Bool
  let isSelected: Bool
  let toggleExpansion: () -> Void
  let onSelect: () -> Void
  /// Primary action for a row double-click: browse into a folder or open a file.
  /// The List's native `primaryAction` does not fire for these rows — the
  /// `.draggable` (and the selection tap that works around it) consume the second
  /// click before the Outline sees it — so the row drives it explicitly.
  let onActivate: () -> Void
  let onDropURLs: ([URL]) -> Void
  @State private var isDropTargeted = false
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 6) {
      if entry.kind.isDirectoryLike {
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
        // Mirror the disclosure button's layout (hidden) so file rows match the
        // height of folder rows. The Button's intrinsic height otherwise makes
        // folder rows taller, and a single hover/selection highlight inset can't
        // fill both heights without clipping one.
        Button(action: {}) {
          Image(systemName: "chevron.right")
            .font(.caption2)
            .frame(width: WorkspaceSidebarMetrics.chevronColumnWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hidden()
        // Belt-and-suspenders: a hidden view is already non-interactive, but
        // make sure this height-matching placeholder never swallows clicks or
        // drags in the disclosure column.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }

      rowContent
    }
    .padding(.leading, CGFloat(depth) * WorkspaceSidebarMetrics.depthIndent)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background {
      // The shape bleeds past the row content into the cell's insets so it fills
      // the full row height/width, matching the native selection band. The accent
      // drop-target highlight takes precedence; the hover gray is suppressed for a
      // selected row so it never paints over the selection color.
      if let fill = rowHighlightFill {
        // Continuous (squircle) corners to match the native source-list
        // selection band; the default circular corners read as a different,
        // "cut off" rounding next to the selection.
        RoundedRectangle(
          cornerRadius: WorkspaceSidebarMetrics.dropHighlightCornerRadius, style: .continuous
        )
        .fill(fill)
        .padding(.vertical, -WorkspaceSidebarMetrics.dropHighlightVerticalExpansion)
        .padding(.horizontal, -WorkspaceSidebarMetrics.dropHighlightHorizontalExpansion)
      }
    }
    .modifier(
      WorkspaceSidebarDropTarget(
        isEnabled: entry.kind.isDirectoryLike,
        isTargeted: $isDropTargeted,
        onDrop: onDropURLs
      )
    )
    .onHover { isHovered = $0 }
  }

  private var rowHighlightFill: Color? {
    if isDropTargeted {
      return Color.accentColor.opacity(WorkspaceSidebarMetrics.dropHighlightOpacity)
    }
    if isHovered && !isSelected {
      return Color.primary.opacity(WorkspaceSidebarMetrics.rowHoverHighlightOpacity)
    }
    return nil
  }

  private var rowContent: some View {
    HStack(spacing: 6) {
      entryIcon

      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(gitStatus?.sidebarTextColor ?? .primary)

      Spacer(minLength: 0)

      WorkspaceSidebarGitStatusBadge(gitStatus: gitStatus)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .draggable(entry.url) {
      WorkspaceSidebarDragPreview(entry: entry, gitStatus: gitStatus)
    }
    // `.draggable` competes with the List's built-in selection click and can
    // swallow clicks that include any pointer movement, so drive selection
    // explicitly with a simultaneous tap that survives the drag gesture.
    .simultaneousGesture(TapGesture().onEnded(onSelect))
    // The List's built-in double-click `primaryAction` never reaches these rows
    // (the `.draggable` above swallows the second click), so drive the primary
    // action — browse into a folder / open a file — from an explicit double tap.
    .simultaneousGesture(TapGesture(count: 2).onEnded(onActivate))
    // Merge the icon + name + badge into one labeled element for VoiceOver, and
    // publish it as static text so it resolves as `app.staticTexts[name]` (not a
    // generic group) for accessibility tooling and UI tests alike.
    .accessibilityElement(children: .ignore)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityLabel(Text(verbatim: rowAccessibilityLabel))
  }

  private var entryIcon: some View {
    WorkspaceSidebarEntryIcon(entry: entry, gitStatus: gitStatus)
  }

  private var disclosureAccessibilityLabel: Text {
    let action = isExpanded ? "Collapse" : "Expand"
    return Text(verbatim: "\(action) \(entry.name)")
  }

  private var rowAccessibilityLabel: String {
    var components = [entry.name]
    if entry.kind.isSymlink {
      components.append("alias")
    }
    if let gitStatus {
      components.append(gitStatus.accessibilityDescription)
    }
    return components.joined(separator: ", ")
  }
}

/// Shared icon rendering for a workspace entry: the base symbol with ignored
/// dimming plus the symlink badge. Used by both the sidebar row and the drag
/// preview so they stay visually consistent.
private struct WorkspaceSidebarEntryIcon: View {
  let entry: WorkspaceEntry
  let gitStatus: GitWorkspaceChangeKind?

  var body: some View {
    WorkspaceEntryIconImage(
      entry: entry,
      dimension: WorkspaceSidebarMetrics.iconColumnWidth,
      systemFontSize: WorkspaceSidebarMetrics.systemIconFontSize,
      symlinkBadgeSize: WorkspaceSidebarMetrics.symlinkBadgeSize,
      symlinkBadgeOffset: WorkspaceSidebarMetrics.symlinkBadgeOffset,
      isDimmed: gitStatus?.dimsSidebarSymbol == true
    )
    // Reserve a square so every row has the same icon height regardless of the
    // symbol (e.g. a tall `doc` vs a short `folder`); otherwise rows differ in
    // height and the hover/selection highlight rounds inconsistently between
    // files and folders.
    .frame(
      width: WorkspaceSidebarMetrics.iconColumnWidth,
      height: WorkspaceSidebarMetrics.iconColumnWidth,
      alignment: .center
    )
  }
}

/// Drag image shown while a sidebar entry is being dragged. A compact icon +
/// name pill so the user can see what they are moving instead of a bare label.
/// Carries the entry's row styling (ignored dimming, Git text color, symlink
/// badge) so the dragged item reads the same as its row. The drag image is
/// rendered as a flat snapshot over a transparent backdrop, so it uses an opaque
/// fill, border, and shadow (materials and Liquid Glass render as nearly
/// invisible here because there is no content behind them to blur or refract).
private struct WorkspaceSidebarDragPreview: View {
  let entry: WorkspaceEntry
  let gitStatus: GitWorkspaceChangeKind?

  private var shape: RoundedRectangle {
    RoundedRectangle(
      cornerRadius: WorkspaceSidebarMetrics.dragPreviewCornerRadius, style: .continuous)
  }

  var body: some View {
    HStack(spacing: WorkspaceSidebarMetrics.dragPreviewSpacing) {
      WorkspaceSidebarEntryIcon(entry: entry, gitStatus: gitStatus)

      Text(entry.name)
        .lineLimit(1)
        .foregroundStyle(gitStatus?.sidebarTextColor ?? .primary)

      WorkspaceSidebarGitStatusBadge(gitStatus: gitStatus)
    }
    .padding(.horizontal, WorkspaceSidebarMetrics.dragPreviewHorizontalPadding)
    .padding(.vertical, WorkspaceSidebarMetrics.dragPreviewVerticalPadding)
    .background(Color(nsColor: .windowBackgroundColor), in: shape)
    .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
    .shadow(
      color: .black.opacity(WorkspaceSidebarMetrics.dragPreviewShadowOpacity),
      radius: WorkspaceSidebarMetrics.dragPreviewShadowRadius,
      y: WorkspaceSidebarMetrics.dragPreviewShadowOffsetY
    )
    // Size the pill to hug its icon + name rather than stretch to a container.
    .fixedSize()
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
