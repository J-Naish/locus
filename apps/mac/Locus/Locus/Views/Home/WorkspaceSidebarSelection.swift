import Foundation

struct WorkspaceSidebarSelectionState: Equatable {
  private(set) var activeEntryID: WorkspaceEntry.ID?
  private var visibleEntryIDs: Set<WorkspaceEntry.ID>
  private var highlightClearedForEntryID: WorkspaceEntry.ID?

  init(
    activeEntryID: WorkspaceEntry.ID?,
    visibleEntryIDs: Set<WorkspaceEntry.ID>
  ) {
    self.activeEntryID = activeEntryID
    self.visibleEntryIDs = visibleEntryIDs
  }

  var highlightedEntryID: WorkspaceEntry.ID? {
    guard let activeEntryID,
      visibleEntryIDs.contains(activeEntryID),
      highlightClearedForEntryID != activeEntryID
    else {
      return nil
    }

    return activeEntryID
  }

  mutating func selectSidebarEntry(_ entryID: WorkspaceEntry.ID) {
    activeEntryID = entryID
    highlightClearedForEntryID = nil
  }

  mutating func setActiveEntryID(_ entryID: WorkspaceEntry.ID?) {
    if activeEntryID != entryID {
      highlightClearedForEntryID = nil
    }

    activeEntryID = entryID
    if entryID == nil {
      highlightClearedForEntryID = nil
    }
  }

  mutating func setVisibleEntryIDs(_ entryIDs: Set<WorkspaceEntry.ID>) {
    visibleEntryIDs = entryIDs
  }

  mutating func clearHighlightForEmptyAreaClick() {
    highlightClearedForEntryID = activeEntryID
  }

  mutating func reset(
    activeEntryID: WorkspaceEntry.ID? = nil,
    visibleEntryIDs: Set<WorkspaceEntry.ID> = []
  ) {
    self.activeEntryID = activeEntryID
    self.visibleEntryIDs = visibleEntryIDs
    highlightClearedForEntryID = nil
  }
}
