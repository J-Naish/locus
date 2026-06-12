import Foundation

struct DocumentTab: Equatable, Identifiable, Sendable {
  let entry: WorkspaceEntry

  var id: WorkspaceEntry.ID { entry.id }
  var name: String { entry.name }
}

enum DocumentTabCloseOutcome: Equatable, Sendable {
  case keepCurrent
  case activate(DocumentTab)
  case showEmpty
}

struct DocumentTabsState: Equatable, Sendable {
  private(set) var folderURL: URL?
  private(set) var tabs: [DocumentTab] = []

  mutating func prepareForWorkspace(_ folderURL: URL) {
    if self.folderURL?.locusStandardizedPath != folderURL.locusStandardizedPath {
      tabs = []
    }
    self.folderURL = folderURL
  }

  mutating func recordOpen(of entry: WorkspaceEntry) {
    if let index = tabs.firstIndex(where: { $0.id == entry.id }) {
      tabs[index] = DocumentTab(entry: entry)
    } else {
      tabs.append(DocumentTab(entry: entry))
    }
  }

  mutating func closeTab(
    withID id: WorkspaceEntry.ID,
    activeTabID: WorkspaceEntry.ID?
  ) -> DocumentTabCloseOutcome {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else {
      return .keepCurrent
    }

    tabs.remove(at: index)
    guard id == activeTabID else {
      return .keepCurrent
    }
    guard !tabs.isEmpty else {
      return .showEmpty
    }

    return .activate(tabs[min(index, tabs.count - 1)])
  }

  mutating func closeTabs(underPath path: String) {
    tabs.removeAll { tab in
      tab.id.locusHasPathPrefix(path)
    }
  }

  /// Reorders an open tab: reinserts it before `targetID`, or at the trailing
  /// edge when `targetID` is nil. Unknown dragged or target ids are ignored.
  mutating func moveTab(withID id: WorkspaceEntry.ID, before targetID: WorkspaceEntry.ID?) {
    guard id != targetID,
      let sourceIndex = tabs.firstIndex(where: { $0.id == id })
    else { return }
    if targetID != nil, !tabs.contains(where: { $0.id == targetID }) {
      return
    }

    let moved = tabs.remove(at: sourceIndex)
    if let targetID, let targetIndex = tabs.firstIndex(where: { $0.id == targetID }) {
      tabs.insert(moved, at: targetIndex)
    } else {
      tabs.append(moved)
    }
  }
}

/// Pure geometry for the live tab reorder gesture: decides when the dragged
/// chip has been pulled far enough from its settled slot to trade places with
/// a neighbor.
enum DocumentTabReorder {
  /// Returns the swap direction (+1 = with the next chip, -1 = with the
  /// previous one) once the dragged chip's displacement crosses the midpoint
  /// of that neighbor, or nil while it should stay in its slot. Unmeasured
  /// neighbors (width 0) never trigger a swap.
  static func swapStep(
    widths: [CGFloat],
    draggedIndex: Int,
    displacement: CGFloat,
    spacing: CGFloat
  ) -> Int? {
    if displacement > 0, draggedIndex + 1 < widths.count {
      let nextWidth = widths[draggedIndex + 1]
      if nextWidth > 0, displacement > (nextWidth + spacing) / 2 {
        return 1
      }
    }
    if displacement < 0, draggedIndex > 0 {
      let previousWidth = widths[draggedIndex - 1]
      if previousWidth > 0, -displacement > (previousWidth + spacing) / 2 {
        return -1
      }
    }
    return nil
  }
}
