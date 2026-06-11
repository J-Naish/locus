import Foundation

/// Why the user is moving to a folder. Opening a location is a deliberate
/// "this is a place I chose" action (folder picker, Recent Folders row);
/// browsing is movement within or through places and must not create Recent
/// Folders entries on its own — pass-through folders would crowd out real
/// locations. Browsed folders still reach Recents through
/// `recordWorkspaceEngagement` once real work happens in them.
enum WorkspaceNavigationIntent {
  case openLocation
  case browse

  var recordsRecent: Bool {
    self == .openLocation
  }
}

struct WorkspaceHistoryEntry: Equatable {
  let folderURL: URL
  let rootURL: URL?
  let selectedURL: URL?

  init(folderURL: URL, rootURL: URL?, selectedURL: URL? = nil) {
    self.folderURL = folderURL.standardizedFileURL
    self.rootURL = rootURL?.standardizedFileURL
    self.selectedURL = selectedURL?.standardizedFileURL
  }

  func hasSameLocation(as other: WorkspaceHistoryEntry) -> Bool {
    // Selection changes inside the same folder should not create browser-style
    // history entries; only folder/root location changes do.
    folderURL.locusStandardizedPath == other.folderURL.locusStandardizedPath
      && rootURL?.locusStandardizedPath == other.rootURL?.locusStandardizedPath
  }
}

struct WorkspaceNavigationHistory: Equatable {
  private(set) var backStack: [WorkspaceHistoryEntry] = []
  private(set) var forwardStack: [WorkspaceHistoryEntry] = []

  var canGoBack: Bool {
    previousEntry != nil
  }

  var canGoForward: Bool {
    nextEntry != nil
  }

  var previousEntry: WorkspaceHistoryEntry? {
    backStack.last
  }

  var nextEntry: WorkspaceHistoryEntry? {
    forwardStack.last
  }

  mutating func recordNavigation(
    from current: WorkspaceHistoryEntry?,
    to destination: WorkspaceHistoryEntry
  ) {
    guard let current, !current.hasSameLocation(as: destination) else {
      return
    }

    backStack.append(current)
    forwardStack.removeAll()
  }

  mutating func commitBackNavigation(from current: WorkspaceHistoryEntry) {
    guard let previous = backStack.popLast() else {
      return
    }

    if !current.hasSameLocation(as: previous) {
      forwardStack.append(current)
    }
  }

  mutating func commitForwardNavigation(from current: WorkspaceHistoryEntry) {
    guard let next = forwardStack.popLast() else {
      return
    }

    if !current.hasSameLocation(as: next) {
      backStack.append(current)
    }
  }
}

extension String {
  func locusHasPathPrefix(_ prefix: String) -> Bool {
    var normalizedPrefix = prefix
    while normalizedPrefix.count > 1, normalizedPrefix.hasSuffix("/") {
      normalizedPrefix.removeLast()
    }
    guard normalizedPrefix != "/" else {
      return hasPrefix(normalizedPrefix)
    }

    return self == normalizedPrefix || hasPrefix(normalizedPrefix + "/")
  }
}
