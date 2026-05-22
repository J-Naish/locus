import XCTest
@testable import Locus

final class RecentFolderStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!
    private var temporaryDirectory: URL!
    private var temporaryDirectoryPath: String!

    override func setUpWithError() throws {
        suiteName = "RecentFolderStoreTests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "RecentFolderStoreTests-\(UUID().uuidString)")
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

    func testRecordsAndResolvesRecentFolder() throws {
        let folderURL = try makeFolder(named: "Reports")
        let store = RecentFolderStore(userDefaults: userDefaults)

        XCTAssertTrue(store.record(folderURL))

        let recentFolders = store.recentFolders()
        XCTAssertEqual(recentFolders.count, 1)
        XCTAssertEqual(recentFolders[0].id, expectedPath(named: "Reports"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFolders[0].url.path(percentEncoded: false)))
        XCTAssertEqual(recentFolders[0].displayName, "Reports")
        XCTAssertEqual(recentFolders[0].path, expectedPath(named: "Reports"))
    }

    func testRecordingExistingFolderMovesItToFront() throws {
        var now = Date(timeIntervalSince1970: 1)
        let store = RecentFolderStore(userDefaults: userDefaults, now: { now })
        let first = try makeFolder(named: "First")
        let second = try makeFolder(named: "Second")

        XCTAssertTrue(store.record(first))
        now = Date(timeIntervalSince1970: 2)
        XCTAssertTrue(store.record(second))
        now = Date(timeIntervalSince1970: 3)
        XCTAssertTrue(store.record(first))

        let recentFolders = store.recentFolders()
        XCTAssertEqual(recentFolders.map(\.path), [
            expectedPath(named: "First"),
            expectedPath(named: "Second")
        ])
        XCTAssertEqual(recentFolders[0].lastOpenedAt, Date(timeIntervalSince1970: 3))
    }

    func testLimitsRecentFolderCount() throws {
        let store = RecentFolderStore(userDefaults: userDefaults, maxCount: 2)
        let first = try makeFolder(named: "First")
        let second = try makeFolder(named: "Second")
        let third = try makeFolder(named: "Third")

        XCTAssertTrue(store.record(first))
        XCTAssertTrue(store.record(second))
        XCTAssertTrue(store.record(third))

        XCTAssertEqual(store.recentFolders().map(\.path), [
            expectedPath(named: "Third"),
            expectedPath(named: "Second")
        ])
    }

    func testReturnsEmptyWhenNoRecentFoldersHaveBeenRecorded() {
        let store = RecentFolderStore(userDefaults: userDefaults)

        XCTAssertEqual(store.recentFolders(), [])
    }

    func testRejectsFileWhenRecordingRecentFolder() throws {
        let fileURL = temporaryDirectory.appending(path: "brief.md", directoryHint: .notDirectory)
        try Data("test".utf8).write(to: fileURL)
        let store = RecentFolderStore(userDefaults: userDefaults)

        XCTAssertFalse(store.record(fileURL))
        XCTAssertEqual(store.recentFolders(), [])
    }

    func testPrunesRecentFolderThatNoLongerExists() throws {
        let folderURL = try makeFolder(named: "Reports")
        let store = RecentFolderStore(userDefaults: userDefaults)

        XCTAssertTrue(store.record(folderURL))
        try FileManager.default.removeItem(at: folderURL)

        XCTAssertEqual(store.recentFolders(), [])

        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        XCTAssertEqual(store.recentFolders(), [])
    }

    func testCorruptStoredDataReturnsEmptyAndClearsValue() {
        let key = "corrupt-recent-folders"
        userDefaults.set(Data("not a plist".utf8), forKey: key)
        let store = RecentFolderStore(userDefaults: userDefaults, key: key)

        XCTAssertEqual(store.recentFolders(), [])
        XCTAssertNil(userDefaults.data(forKey: key))
    }

    func testDefaultMaxCountMatchesMacOpenRecentConvention() {
        XCTAssertEqual(RecentFolderStore.defaultMaxCount, 10)
    }

    private func makeFolder(named name: String) throws -> URL {
        let url = temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func expectedPath(named name: String) -> String {
        "\(temporaryDirectoryPath!)/\(name)"
    }
}
