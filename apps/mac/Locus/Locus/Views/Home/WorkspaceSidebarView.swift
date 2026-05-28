import SwiftUI

extension GitWorkspaceChangeKind {
  fileprivate var sidebarTextColor: Color {
    switch self {
    case .modified:
      return Color(nsColor: .systemYellow)
    case .added:
      return Color(nsColor: .systemGreen)
    }
  }

  fileprivate var accessibilityDescription: String {
    switch self {
    case .modified:
      return "modified"
    case .added:
      return "added"
    }
  }
}

struct WorkspaceSidebarView: View {
  let folderURL: URL
  let entries: [WorkspaceEntry]
  let recentFolders: [RecentFolder]
  let gitStatusesByPath: [String: GitWorkspaceChangeKind]
  private let rootEntry: WorkspaceEntry
  @Binding var highlightedEntryID: WorkspaceEntry.ID?
  let shortcutActions: FileLocationShortcutActions
  let actions: WorkspaceActions
  let onItemCreated: () -> Void
  let onVisibleEntriesChange: ([WorkspaceEntry]) -> Void
  @State private var expandedFolderIDs: Set<WorkspaceEntry.ID> = []
  @State private var childStates: [WorkspaceEntry.ID: WorkspaceSidebarChildState] = [:]
  @State private var childLoadTasks: [WorkspaceEntry.ID: Task<Void, Never>] = [:]
  @State private var childLoadTokens: [WorkspaceEntry.ID: UUID] = [:]
  @State private var expansionGeneration: UInt64 = 0
  @State private var isRootExpanded = true
  @State private var visibleRows: [WorkspaceSidebarRow] = []
  @State private var creationKind: WorkspaceItemCreationKind?
  @State private var creationParent: WorkspaceEntry?
  @State private var creationName = ""
  @State private var creationErrorMessage: String?
  @State private var isCreatingItem = false
  @State private var creationTask: Task<Void, Never>?
  @AppStorage(LocusPersistedDefaults.recentFoldersExpanded)
  private var isRecentFoldersExpanded = false

  init(
    folderURL: URL,
    entries: [WorkspaceEntry],
    recentFolders: [RecentFolder],
    gitStatusesByPath: [String: GitWorkspaceChangeKind],
    highlightedEntryID: Binding<WorkspaceEntry.ID?>,
    shortcutActions: FileLocationShortcutActions,
    actions: WorkspaceActions,
    onItemCreated: @escaping () -> Void,
    onVisibleEntriesChange: @escaping ([WorkspaceEntry]) -> Void
  ) {
    self.folderURL = folderURL
    self.entries = entries
    self.recentFolders = recentFolders
    self.gitStatusesByPath = gitStatusesByPath
    self.rootEntry = WorkspaceEntry.workspaceRoot(at: folderURL)
    self._highlightedEntryID = highlightedEntryID
    self.shortcutActions = shortcutActions
    self.actions = actions
    self.onItemCreated = onItemCreated
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
              toggleExpansion: {
                toggleExpansion(for: entry)
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
        WorkspaceSidebarEmptyAreaSelectionClearer {
          highlightedEntryID = nil
        }
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
    .onDisappear {
      cancelCreationTask()
      cancelAllChildLoads()
    }
    .onChange(of: entries) {
      pruneExpansion(for: entries)
    }
    .onChange(of: folderURL) {
      cancelCreation()
      resetExpansion()
    }
  }

  private func currentRows() -> [WorkspaceSidebarRow] {
    var result = [WorkspaceSidebarRow(entry: rootEntry, depth: 0)]
    if isRootExpanded {
      if let creationKind, creationParent?.id == rootEntry.id {
        result.append(.creation(creationKind, depth: 1))
      }
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
    visibleRows.compactMap(\.entry).filter { selection.contains($0.id) }
  }

  private func creationParent(for selectedEntries: [WorkspaceEntry]) -> WorkspaceEntry {
    guard selectedEntries.count == 1, let selectedEntry = selectedEntries.first,
      selectedEntry.kind == .directory
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
    gitStatusesByPath[entry.id]
  }

  private func rows(for entries: [WorkspaceEntry], depth: Int) -> [WorkspaceSidebarRow] {
    entries.flatMap { entry -> [WorkspaceSidebarRow] in
      var result = [WorkspaceSidebarRow(entry: entry, depth: depth)]

      guard entry.kind == .directory, expandedFolderIDs.contains(entry.id) else {
        return result
      }

      if let creationKind, creationParent?.id == entry.id {
        result.append(.creation(creationKind, depth: depth + 1))
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

private struct WorkspaceSidebarEmptyAreaSelectionClearer: NSViewRepresentable {
  let clearSelection: () -> Void

  func makeNSView(context: Context) -> WorkspaceSidebarEmptyAreaSelectionClearerView {
    let view = WorkspaceSidebarEmptyAreaSelectionClearerView()
    view.clearSelection = clearSelection
    return view
  }

  func updateNSView(
    _ nsView: WorkspaceSidebarEmptyAreaSelectionClearerView,
    context: Context
  ) {
    nsView.clearSelection = clearSelection
    nsView.resolveTableViewSoon()
  }

  static func dismantleNSView(
    _ nsView: WorkspaceSidebarEmptyAreaSelectionClearerView,
    coordinator: ()
  ) {
    nsView.invalidate()
  }
}

private final class WorkspaceSidebarEmptyAreaSelectionClearerView: NSView {
  var clearSelection: () -> Void = {}
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
      self?.clearSelectionIfClickIsInEmptyListArea(event)
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

  private func clearSelectionIfClickIsInEmptyListArea(_ event: NSEvent) {
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
    if tableView.bounds.contains(pointInTable), tableView.row(at: pointInTable) != -1 {
      return
    }

    clearSelection()
  }

  private func findSidebarTableView() -> NSTableView? {
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

      focusLost()
    }
  }
}

private struct WorkspaceSidebarEntryRow: View {
  let entry: WorkspaceEntry
  let depth: Int
  let gitStatus: GitWorkspaceChangeKind?
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
    .help(Text(verbatim: rowHelpText))
  }

  private var rowContent: some View {
    HStack(spacing: 6) {
      Image(systemName: entry.symbolName)
        .foregroundStyle(entry.symbolColor)

      Text(entry.name)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(gitStatus?.sidebarTextColor ?? .primary)

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(verbatim: rowAccessibilityLabel))
  }

  private var disclosureAccessibilityLabel: Text {
    let action = isExpanded ? "Collapse" : "Expand"
    return Text(verbatim: "\(action) \(entry.name)")
  }

  private var rowAccessibilityLabel: String {
    guard let gitStatus else {
      return entry.name
    }

    return "\(entry.name), \(gitStatus.accessibilityDescription)"
  }

  private var rowHelpText: String {
    guard let gitStatus else {
      return entry.name
    }

    return "\(entry.name) (\(gitStatus.accessibilityDescription))"
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
