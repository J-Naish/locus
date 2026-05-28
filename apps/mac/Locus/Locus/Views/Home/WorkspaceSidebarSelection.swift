import Foundation

/// Keeps the document surface selection independent from the sidebar's visual
/// row highlight. Folder rows can be highlighted without replacing the open
/// document, matching file-browser behavior in apps like VS Code.
struct WorkspaceSidebarSelectionState: Equatable {
  private(set) var activeEntryID: WorkspaceEntry.ID?
  private var visibleEntryIDs: Set<WorkspaceEntry.ID>
  private var selectedSidebarEntryID: WorkspaceEntry.ID?
  private var highlightClearedForEntryID: WorkspaceEntry.ID?

  init(
    activeEntryID: WorkspaceEntry.ID?,
    visibleEntryIDs: Set<WorkspaceEntry.ID>
  ) {
    self.activeEntryID = activeEntryID
    self.visibleEntryIDs = visibleEntryIDs
  }

  var highlightedEntryID: WorkspaceEntry.ID? {
    // Explicit sidebar focus wins while that row is visible.
    if let selectedSidebarEntryID,
      visibleEntryIDs.contains(selectedSidebarEntryID)
    {
      return selectedSidebarEntryID
    }

    // Otherwise fall back to the open document unless an empty-area click
    // intentionally cleared the visual highlight.
    guard let activeEntryID,
      visibleEntryIDs.contains(activeEntryID),
      highlightClearedForEntryID != activeEntryID
    else {
      return nil
    }

    return activeEntryID
  }

  mutating func highlightSidebarEntry(_ entryID: WorkspaceEntry.ID) {
    selectedSidebarEntryID = entryID
    highlightClearedForEntryID = nil
  }

  mutating func setActiveEntryID(_ entryID: WorkspaceEntry.ID?) {
    if activeEntryID != entryID {
      highlightClearedForEntryID = nil
    }

    activeEntryID = entryID
    selectedSidebarEntryID = entryID
    if entryID == nil {
      highlightClearedForEntryID = nil
    }
  }

  mutating func setVisibleEntryIDs(_ entryIDs: Set<WorkspaceEntry.ID>) {
    visibleEntryIDs = entryIDs
    if let selectedSidebarEntryID, !entryIDs.contains(selectedSidebarEntryID) {
      self.selectedSidebarEntryID = nil
    }
  }

  mutating func clearHighlightForEmptyAreaClick() {
    highlightClearedForEntryID = activeEntryID
    selectedSidebarEntryID = nil
  }

  mutating func reset(
    activeEntryID: WorkspaceEntry.ID? = nil,
    visibleEntryIDs: Set<WorkspaceEntry.ID> = []
  ) {
    self.activeEntryID = activeEntryID
    self.visibleEntryIDs = visibleEntryIDs
    selectedSidebarEntryID = activeEntryID
    highlightClearedForEntryID = nil
  }
}
