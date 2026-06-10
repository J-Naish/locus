import XCTest

@testable import Locus

@MainActor
final class FileLocationBookmarkStoreTests: XCTestCase {
  private var userDefaults: UserDefaults!
  private var suiteName: String!
  private var temporaryDirectory: URL!

  override func setUpWithError() throws {
    suiteName = "FileLocationBookmarkStoreTests.\(UUID().uuidString)"
    userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let directory = FileManager.default.temporaryDirectory
      .appending(
        path: "FileLocationBookmarkStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Canonicalize (e.g. /var -> /private/var) so paths derived from input URLs
    // and paths derived from resolved bookmarks compare equal.
    temporaryDirectory = directory.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    userDefaults.removePersistentDomain(forName: suiteName)
    try? FileManager.default.removeItem(at: temporaryDirectory)
    userDefaults = nil
    suiteName = nil
    temporaryDirectory = nil
  }

  func testInsertAddsResolvableBookmark() throws {
    let store = makeStore()
    let fileURL = try makeFile(named: "a.txt")

    XCTAssertTrue(store.insert(fileURL, timestamp: Date(timeIntervalSince1970: 1)))

    let resolved = store.resolvedLocations()
    XCTAssertEqual(resolved.count, 1)
    XCTAssertEqual(resolved[0].path, fileURL.locusStandardizedPath)
    XCTAssertEqual(resolved[0].timestamp, Date(timeIntervalSince1970: 1))
    XCTAssertTrue(store.contains(fileURL))
  }

  func testInsertMovesExistingURLToFrontAndRefreshesTimestamp() throws {
    let store = makeStore()
    let first = try makeFile(named: "first.txt")
    let second = try makeFile(named: "second.txt")

    store.insert(first, timestamp: Date(timeIntervalSince1970: 1))
    store.insert(second, timestamp: Date(timeIntervalSince1970: 2))
    store.insert(first, timestamp: Date(timeIntervalSince1970: 3))

    let resolved = store.resolvedLocations()
    XCTAssertEqual(
      resolved.map(\.path),
      [first.locusStandardizedPath, second.locusStandardizedPath])
    XCTAssertEqual(resolved[0].timestamp, Date(timeIntervalSince1970: 3))
  }

  func testInsertEnforcesMaxCount() throws {
    let store = makeStore(maxCount: 2)
    let first = try makeFile(named: "1.txt")
    let second = try makeFile(named: "2.txt")
    let third = try makeFile(named: "3.txt")

    store.insert(first, timestamp: Date(timeIntervalSince1970: 1))
    store.insert(second, timestamp: Date(timeIntervalSince1970: 2))
    store.insert(third, timestamp: Date(timeIntervalSince1970: 3))

    XCTAssertEqual(
      store.resolvedLocations().map(\.path),
      [third.locusStandardizedPath, second.locusStandardizedPath])
  }

  func testInsertRejectsResourceOfTheWrongType() throws {
    let fileStore = makeStore(requiredResource: .regularFile, key: "files")
    let folderURL = try makeFolder(named: "Folder")
    XCTAssertFalse(fileStore.insert(folderURL, timestamp: Date(timeIntervalSince1970: 1)))
    XCTAssertTrue(fileStore.resolvedLocations().isEmpty)

    let folderStore = makeStore(requiredResource: .directory, key: "folders")
    let fileURL = try makeFile(named: "a.txt")
    XCTAssertFalse(folderStore.insert(fileURL, timestamp: Date(timeIntervalSince1970: 1)))
    XCTAssertTrue(folderStore.resolvedLocations().isEmpty)
  }

  func testRemoveDeletesBookmark() throws {
    let store = makeStore()
    let fileURL = try makeFile(named: "a.txt")
    store.insert(fileURL, timestamp: Date(timeIntervalSince1970: 1))

    store.remove(fileURL)

    XCTAssertFalse(store.contains(fileURL))
    XCTAssertTrue(store.resolvedLocations().isEmpty)
  }

  func testResolvedLocationsPrunesMissingFilesAndPersistsTheChange() throws {
    let store = makeStore()
    let fileURL = try makeFile(named: "a.txt")
    store.insert(fileURL, timestamp: Date(timeIntervalSince1970: 1))

    try FileManager.default.removeItem(at: fileURL)
    XCTAssertTrue(store.resolvedLocations().isEmpty)

    // The pruned record was persisted, so the entry stays gone even if a file
    // reappears later at the same path.
    try Data("x".utf8).write(to: fileURL)
    XCTAssertTrue(store.resolvedLocations().isEmpty)
  }

  func testResolvedLocationsKeepsUnresolvableBookmarkDataForFutureMigration() throws {
    let key = "invalid-bookmark-record"
    let fileURL = try makeFile(named: "still-present.txt")
    let record = StoredFileLocationBookmark(
      bookmarkData: Data("not a bookmark".utf8),
      displayName: "Missing",
      path: fileURL.locusStandardizedPath,
      timestamp: Date(timeIntervalSince1970: 1)
    )
    userDefaults.set(try PropertyListEncoder().encode([record]), forKey: key)
    let store = makeStore(key: key)

    XCTAssertTrue(store.resolvedLocations().isEmpty)
    let storedData = try XCTUnwrap(userDefaults.data(forKey: key))
    let stored = try PropertyListDecoder().decode(
      [StoredFileLocationBookmark].self, from: storedData)
    XCTAssertEqual(stored, [record])
  }

  func testResolvedLocationsRefreshesStaleBookmarkAfterRename() throws {
    let store = makeStore()
    let originalURL = try makeFile(named: "original.txt")
    store.insert(originalURL, timestamp: Date(timeIntervalSince1970: 1))

    let renamedURL = temporaryDirectory.appending(
      path: "renamed.txt", directoryHint: .notDirectory)
    try FileManager.default.moveItem(at: originalURL, to: renamedURL)

    let resolved = store.resolvedLocations()
    XCTAssertEqual(resolved.count, 1)
    XCTAssertEqual(resolved[0].url.lastPathComponent, "renamed.txt")
    XCTAssertEqual(resolved[0].path, renamedURL.locusStandardizedPath)
    XCTAssertEqual(resolved[0].timestamp, Date(timeIntervalSince1970: 1))
    // The reconciled record is persisted under the new path.
    XCTAssertTrue(store.contains(renamedURL))
    XCTAssertFalse(store.contains(originalURL))
  }

  func testCorruptStoredDataIsClearedAndReturnsEmpty() {
    let key = "corrupt-bookmarks"
    userDefaults.set(Data("not a plist".utf8), forKey: key)
    let store = makeStore(key: key)

    XCTAssertTrue(store.resolvedLocations().isEmpty)
    XCTAssertNil(userDefaults.data(forKey: key))
  }

  // MARK: - Helpers

  private func makeStore(
    maxCount: Int? = nil,
    requiredResource: FileLocationBookmarkStore.RequiredResource = .regularFile,
    key: String = "bookmarks"
  ) -> FileLocationBookmarkStore {
    FileLocationBookmarkStore(
      userDefaults: userDefaults,
      key: key,
      maxCount: maxCount,
      requiredResource: requiredResource,
      logCategory: "Tests")
  }

  private func makeFile(named name: String) throws -> URL {
    let url = temporaryDirectory.appending(path: name, directoryHint: .notDirectory)
    try Data("x".utf8).write(to: url)
    return url
  }

  private func makeFolder(named name: String) throws -> URL {
    let url = temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
