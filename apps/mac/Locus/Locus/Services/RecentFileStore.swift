import Foundation

struct RecentFile: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let path: String
    let lastOpenedAt: Date
}

struct RecentFileStore {
    static let defaultMaxCount = 10

    private let bookmarkStore: FileLocationBookmarkStore
    private let now: () -> Date

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "recentFiles.v1",
        maxCount: Int = Self.defaultMaxCount,
        now: @escaping () -> Date = Date.init
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
        bookmarkStore.insert(fileURL, timestamp: now(), duplicatePolicy: .moveToFront)
    }

    func remove(_ fileURL: URL) {
        bookmarkStore.remove(fileURL)
    }
}
