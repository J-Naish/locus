import XCTest
@testable import Locus

final class RecentFileStoreTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!
    private var temporaryDirectory: URL!
    private var temporaryDirectoryPath: String!

    override func setUpWithError() throws {
        suiteName = "RecentFileStoreTests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "RecentFileStoreTests-\(UUID().uuidString)")
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

    func testRecordsAndResolvesRecentFile() throws {
        let fileURL = try makeFile(named: "brief.md")
        let store = RecentFileStore(userDefaults: userDefaults)

        XCTAssertTrue(store.record(fileURL))

        let recentFiles = store.recentFiles()
        XCTAssertEqual(recentFiles.count, 1)
        XCTAssertEqual(recentFiles[0].id, expectedPath(named: "brief.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recentFiles[0].url.path(percentEncoded: false)))
        XCTAssertEqual(recentFiles[0].displayName, "brief.md")
        XCTAssertEqual(recentFiles[0].path, expectedPath(named: "brief.md"))
    }

    func testRecordingExistingFileMovesItToFront() throws {
        var now = Date(timeIntervalSince1970: 1)
        let store = RecentFileStore(userDefaults: userDefaults, now: { now })
        let first = try makeFile(named: "first.md")
        let second = try makeFile(named: "second.md")

        XCTAssertTrue(store.record(first))
        now = Date(timeIntervalSince1970: 2)
        XCTAssertTrue(store.record(second))
        now = Date(timeIntervalSince1970: 3)
        XCTAssertTrue(store.record(first))

        let recentFiles = store.recentFiles()
        XCTAssertEqual(recentFiles.map(\.path), [
            expectedPath(named: "first.md"),
            expectedPath(named: "second.md")
        ])
        XCTAssertEqual(recentFiles[0].lastOpenedAt, Date(timeIntervalSince1970: 3))
    }

    func testRejectsDirectoryWhenRecordingRecentFile() throws {
        let directoryURL = temporaryDirectory.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let store = RecentFileStore(userDefaults: userDefaults)

        XCTAssertFalse(store.record(directoryURL))
        XCTAssertEqual(store.recentFiles(), [])
    }

    func testLimitsRecentFileCount() throws {
        let store = RecentFileStore(userDefaults: userDefaults, maxCount: 2)
        let first = try makeFile(named: "first.md")
        let second = try makeFile(named: "second.md")
        let third = try makeFile(named: "third.md")

        XCTAssertTrue(store.record(first))
        XCTAssertTrue(store.record(second))
        XCTAssertTrue(store.record(third))

        XCTAssertEqual(store.recentFiles().map(\.path), [
            expectedPath(named: "third.md"),
            expectedPath(named: "second.md")
        ])
    }

    func testPrunesRecentFileThatNoLongerExists() throws {
        let fileURL = try makeFile(named: "brief.md")
        let store = RecentFileStore(userDefaults: userDefaults)

        XCTAssertTrue(store.record(fileURL))
        try FileManager.default.removeItem(at: fileURL)

        XCTAssertEqual(store.recentFiles(), [])
    }

    func testReturnsEmptyWhenNoRecentFilesHaveBeenRecorded() {
        let store = RecentFileStore(userDefaults: userDefaults)

        XCTAssertEqual(store.recentFiles(), [])
    }

    func testCorruptStoredDataReturnsEmptyAndClearsValue() {
        let key = "corrupt-recent-files"
        userDefaults.set(Data("not a plist".utf8), forKey: key)
        let store = RecentFileStore(userDefaults: userDefaults, key: key)

        XCTAssertEqual(store.recentFiles(), [])
        XCTAssertNil(userDefaults.data(forKey: key))
    }

    private func makeFile(named name: String) throws -> URL {
        let url = temporaryDirectory.appending(path: name, directoryHint: .notDirectory)
        try Data("test".utf8).write(to: url)
        return url
    }

    private func expectedPath(named name: String) -> String {
        "\(temporaryDirectoryPath!)/\(name)"
    }
}
