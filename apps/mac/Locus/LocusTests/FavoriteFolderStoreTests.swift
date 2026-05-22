import XCTest
@testable import Locus

final class FavoriteFolderStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!
    private var temporaryDirectory: URL!
    private var temporaryDirectoryPath: String!

    override func setUpWithError() throws {
        suiteName = "FavoriteFolderStoreTests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "FavoriteFolderStoreTests-\(UUID().uuidString)")
        temporaryDirectoryPath = temporaryDirectory.path(percentEncoded: false)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        userDefaults = nil
        suiteName = nil
        temporaryDirectory = nil
        temporaryDirectoryPath = nil
    }

    func testAddsAndResolvesFavoriteFolder() throws {
        let folderURL = try makeFolder(named: "Reports")
        let store = FavoriteFolderStore(userDefaults: userDefaults)

        XCTAssertTrue(store.add(folderURL))

        let favoriteFolders = store.favoriteFolders()
        XCTAssertEqual(favoriteFolders.count, 1)
        XCTAssertEqual(favoriteFolders[0].id, expectedPath(named: "Reports"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: favoriteFolders[0].url.path(percentEncoded: false)))
        XCTAssertEqual(favoriteFolders[0].displayName, "Reports")
        XCTAssertEqual(favoriteFolders[0].path, expectedPath(named: "Reports"))
    }

    func testAddingExistingFolderKeepsOriginalPosition() throws {
        var now = Date(timeIntervalSince1970: 1)
        let store = FavoriteFolderStore(userDefaults: userDefaults, now: { now })
        let first = try makeFolder(named: "First")
        let second = try makeFolder(named: "Second")

        XCTAssertTrue(store.add(first))
        now = Date(timeIntervalSince1970: 2)
        XCTAssertTrue(store.add(second))
        now = Date(timeIntervalSince1970: 3)
        XCTAssertTrue(store.add(first))

        let favoriteFolders = store.favoriteFolders()
        XCTAssertEqual(favoriteFolders.map(\.path), [
            expectedPath(named: "Second"),
            expectedPath(named: "First")
        ])
        XCTAssertEqual(favoriteFolders[1].addedAt, Date(timeIntervalSince1970: 1))
    }

    func testRemovesFavoriteFolder() throws {
        let store = FavoriteFolderStore(userDefaults: userDefaults)
        let first = try makeFolder(named: "First")
        let second = try makeFolder(named: "Second")

        XCTAssertTrue(store.add(first))
        XCTAssertTrue(store.add(second))
        store.remove(first)

        XCTAssertEqual(store.favoriteFolders().map(\.path), [
            expectedPath(named: "Second")
        ])
        XCTAssertFalse(store.contains(first))
        XCTAssertTrue(store.contains(second))
    }

    func testReturnsEmptyWhenNoFavoriteFoldersHaveBeenAdded() {
        let store = FavoriteFolderStore(userDefaults: userDefaults)

        XCTAssertEqual(store.favoriteFolders(), [])
    }

    func testPrunesFavoriteFolderThatNoLongerExists() throws {
        let folderURL = try makeFolder(named: "Reports")
        let key = "favorite-folders-to-prune"
        let store = FavoriteFolderStore(userDefaults: userDefaults, key: key)

        XCTAssertTrue(store.add(folderURL))
        try FileManager.default.removeItem(at: folderURL)

        XCTAssertEqual(store.favoriteFolders(), [])
        XCTAssertEqual(storedBookmarkCount(forKey: key), 0)

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        XCTAssertEqual(store.favoriteFolders(), [])
    }

    func testCorruptStoredDataReturnsEmptyAndClearsValue() {
        let key = "corrupt-favorite-folders"
        userDefaults.set(Data("not a plist".utf8), forKey: key)
        let store = FavoriteFolderStore(userDefaults: userDefaults, key: key)

        XCTAssertEqual(store.favoriteFolders(), [])
        XCTAssertNil(userDefaults.data(forKey: key))
    }

    private func makeFolder(named name: String) throws -> URL {
        let url = temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func expectedPath(named name: String) -> String {
        "\(temporaryDirectoryPath!)/\(name)"
    }

    private func storedBookmarkCount(forKey key: String) -> Int? {
        guard let data = userDefaults.data(forKey: key) else {
            return nil
        }

        return try? PropertyListDecoder().decode([StoredFolderBookmark].self, from: data).count
    }
}
