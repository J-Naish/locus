import Foundation

struct RecentFolder: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let path: String
    let lastOpenedAt: Date
}

struct RecentFolderStore {
    static let defaultMaxCount = 10

    private let bookmarkStore: FileLocationBookmarkStore
    private let now: () -> Date

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "recentFolders.v1",
        maxCount: Int = Self.defaultMaxCount,
        now: @escaping () -> Date = Date.init
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
        bookmarkStore.insert(folderURL, timestamp: now(), duplicatePolicy: .moveToFront)
    }

    func remove(_ folderURL: URL) {
        bookmarkStore.remove(folderURL)
    }
}
