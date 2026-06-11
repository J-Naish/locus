import Foundation

/// Gate for every Recent Folders write. The home folder is the app's launch
/// landing spot and always one step away, so a Recents row for it would be
/// redundant noise.
enum RecentFolderRecordPolicy {
  static func allowsRecording(_ folderURL: URL, homeDirectoryURL: URL) -> Bool {
    folderURL.locusStandardizedPath != homeDirectoryURL.locusStandardizedPath
  }
}

struct RecentFolder: Identifiable, Equatable, Sendable {
  let id: String
  let url: URL
  let displayName: String
  let path: String
  let lastOpenedAt: Date
}

/// Main-actor isolated alongside `FileLocationBookmarkStore` (whose
/// read-modify-write persistence it wraps); the `nonisolated` init keeps
/// construction free of isolation, e.g. in default arguments.
@MainActor
struct RecentFolderStore {
  nonisolated static let defaultMaxCount = 10

  private let bookmarkStore: FileLocationBookmarkStore
  // Main-actor isolated (not @Sendable): the clock is only consulted from this
  // type's isolated methods, and tests advance a captured local between calls.
  private let now: @MainActor () -> Date

  nonisolated init(
    userDefaults: UserDefaults = .standard,
    key: String = "recentFolders.v1",
    maxCount: Int = Self.defaultMaxCount,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.bookmarkStore = FileLocationBookmarkStore(
      userDefaults: userDefaults,
      key: key,
      maxCount: maxCount,
      requiredResource: .directory,
      logCategory: "RecentFolderStore"
    )
    self.now = now
  }

  func recentFolders() -> [RecentFolder] {
    bookmarkStore.resolvedLocations().map {
      RecentFolder(
        id: $0.path,
        url: $0.url,
        displayName: $0.displayName,
        path: $0.path,
        lastOpenedAt: $0.timestamp
      )
    }
  }

  @discardableResult
  func record(_ folderURL: URL) -> Bool {
    bookmarkStore.insert(folderURL, timestamp: now())
  }

  func remove(_ folderURL: URL) {
    bookmarkStore.remove(folderURL)
  }
}
