import Foundation

struct FavoriteFolder: Identifiable, Equatable, Sendable {
  let id: String
  let url: URL
  let displayName: String
  let path: String
  let addedAt: Date
}

struct FavoriteFolderStore {
  private let bookmarkStore: FileLocationBookmarkStore
  private let now: () -> Date

  init(
    userDefaults: UserDefaults = .standard,
    key: String = "favoriteFolders.v1",
    now: @escaping () -> Date = Date.init
  ) {
    self.bookmarkStore = FileLocationBookmarkStore(
      userDefaults: userDefaults,
      key: key,
      requiredResource: .directory,
      logCategory: "FavoriteFolderStore"
    )
    self.now = now
  }

  func favoriteFolders() -> [FavoriteFolder] {
    bookmarkStore.resolvedLocations().map {
      FavoriteFolder(
        id: $0.path,
        url: $0.url,
        displayName: $0.displayName,
        path: $0.path,
        addedAt: $0.timestamp
      )
    }
  }

  func contains(_ folderURL: URL) -> Bool {
    bookmarkStore.contains(folderURL)
  }

  @discardableResult
  func add(_ folderURL: URL) -> Bool {
    bookmarkStore.insert(folderURL, timestamp: now(), duplicatePolicy: .keepOriginalPosition)
  }

  func remove(_ folderURL: URL) {
    bookmarkStore.remove(folderURL)
  }
}
