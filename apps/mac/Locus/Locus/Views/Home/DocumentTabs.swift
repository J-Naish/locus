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
}
