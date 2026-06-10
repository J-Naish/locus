import Foundation

struct RecentFile: Identifiable, Equatable, Sendable {
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
struct RecentFileStore {
  nonisolated static let defaultMaxCount = 10

  private let bookmarkStore: FileLocationBookmarkStore
  // Main-actor isolated (not @Sendable): the clock is only consulted from this
  // type's isolated methods, and tests advance a captured local between calls.
  private let now: @MainActor () -> Date

  nonisolated init(
    userDefaults: UserDefaults = .standard,
    key: String = "recentFiles.v1",
    maxCount: Int = Self.defaultMaxCount,
    now: @escaping @MainActor () -> Date = { Date() }
  ) {
    self.bookmarkStore = FileLocationBookmarkStore(
      userDefaults: userDefaults,
      key: key,
      maxCount: maxCount,
      requiredResource: .regularFile,
      logCategory: "RecentFileStore"
    )
    self.now = now
  }

  func recentFiles() -> [RecentFile] {
    bookmarkStore.resolvedLocations().map {
      RecentFile(
        id: $0.path,
        url: $0.url,
        displayName: $0.displayName,
        path: $0.path,
        lastOpenedAt: $0.timestamp
      )
    }
  }

  @discardableResult
  func record(_ fileURL: URL) -> Bool {
    bookmarkStore.insert(fileURL, timestamp: now())
  }

  func remove(_ fileURL: URL) {
    bookmarkStore.remove(fileURL)
  }
}
