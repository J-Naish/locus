import AppKit
import XCTest

@testable import Locus

@MainActor
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
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: true)
    _ = WorkspaceFolderOpenRequestCenter.shared.consumePendingRequests()
  }

  override func tearDownWithError() throws {
    _ = WorkspaceFolderOpenRequestCenter.shared.consumePendingRequests()
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
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: recentFolders[0].url.path(percentEncoded: false)))
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
    XCTAssertEqual(
      recentFolders.map(\.path),
      [
        expectedPath(named: "First"),
        expectedPath(named: "Second"),
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

    XCTAssertEqual(
      store.recentFolders().map(\.path),
      [
        expectedPath(named: "Third"),
        expectedPath(named: "Second"),
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

  func testRecordPolicyNeverAllowsTheHomeFolderItself() {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    XCTAssertFalse(
      RecentFolderRecordPolicy.allowsRecording(
        URL(filePath: "/Users/tester", directoryHint: .isDirectory),
        homeDirectoryURL: home
      ))
    XCTAssertFalse(
      RecentFolderRecordPolicy.allowsRecording(
        URL(filePath: "/Users/tester/", directoryHint: .isDirectory),
        homeDirectoryURL: home
      ))
    XCTAssertFalse(
      RecentFolderRecordPolicy.allowsRecording(
        URL(filePath: "/Users/tester/Reports/..", directoryHint: .isDirectory),
        homeDirectoryURL: home
      ))
  }

  func testRecordPolicyAllowsSubfoldersOfHomeAndFoldersOutsideHome() {
    let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    XCTAssertTrue(
      RecentFolderRecordPolicy.allowsRecording(
        URL(filePath: "/Users/tester/Reports", directoryHint: .isDirectory),
        homeDirectoryURL: home
      ))
    XCTAssertTrue(
      RecentFolderRecordPolicy.allowsRecording(
        URL(filePath: "/Volumes/Shared/Projects", directoryHint: .isDirectory),
        homeDirectoryURL: home
      ))
  }

  func testRecentDocumentRegistrationReplaysOldestFolderFirst() throws {
    let newestURL = try makeFolder(named: "Newest")
    let oldestURL = try makeFolder(named: "Oldest")

    XCTAssertEqual(
      WorkspaceRecentDocumentRegistration.registrationOrder(for: [
        recentFolder(for: newestURL, displayName: "Newest"),
        recentFolder(for: oldestURL, displayName: "Oldest"),
      ]),
      [oldestURL, newestURL]
    )
  }

  func testWorkspaceFolderOpenRequestCenterQueuesRequestsUntilConsumed() throws {
    let folderURL = try makeFolder(named: "Queued")

    WorkspaceFolderOpenRequestCenter.shared.requestOpen(folderURL, postsNotification: false)

    let pending = WorkspaceFolderOpenRequestCenter.shared.consumePendingRequests()
    XCTAssertEqual(pending.count, 1)
    XCTAssertEqual(pending[0].folderURL, folderURL.standardizedFileURL)
    XCTAssertEqual(WorkspaceFolderOpenRequestCenter.shared.consumePendingRequests(), [])
  }

  func testApplicationDelegateQueuesFolderOpenFileRequests() throws {
    let folderURL = try makeFolder(named: "DockRecent")
    let delegate = LocusApplicationDelegate()

    XCTAssertTrue(
      delegate.application(
        NSApplication.shared,
        openFile: folderURL.path(percentEncoded: false)
      ))

    _ = WorkspaceFolderOpenRequestCenter.shared.consumePendingRequests()
  }

  func testApplicationDelegateRejectsNonFolderOpenFileRequests() throws {
    let fileURL = temporaryDirectory.appending(path: "Notes.md", directoryHint: .notDirectory)
    try Data("notes".utf8).write(to: fileURL)
    let delegate = LocusApplicationDelegate()

    XCTAssertFalse(
      delegate.application(
        NSApplication.shared,
        openFile: fileURL.path(percentEncoded: false)
      ))
    XCTAssertEqual(WorkspaceFolderOpenRequestCenter.shared.consumePendingRequests(), [])
  }

  func testOpenFileResolutionChoosesFirstExistingFolderOnly() throws {
    let fileURL = temporaryDirectory.appending(path: "Notes.md", directoryHint: .notDirectory)
    try Data("notes".utf8).write(to: fileURL)
    let missingURL = temporaryDirectory.appending(path: "Missing", directoryHint: .isDirectory)
    let firstFolderURL = try makeFolder(named: "First")
    let secondFolderURL = try makeFolder(named: "Second")

    XCTAssertEqual(
      WorkspaceOpenFileResolution.firstFolderURL(in: [
        fileURL.path(percentEncoded: false),
        missingURL.path(percentEncoded: false),
        firstFolderURL.path(percentEncoded: false),
        secondFolderURL.path(percentEncoded: false),
      ]),
      firstFolderURL.standardizedFileURL
    )
  }

  func testOpenFileResolutionReturnsNilWhenNoFoldersExist() throws {
    let fileURL = temporaryDirectory.appending(path: "Notes.md", directoryHint: .notDirectory)
    try Data("notes".utf8).write(to: fileURL)

    XCTAssertNil(
      WorkspaceOpenFileResolution.firstFolderURL(in: [
        fileURL.path(percentEncoded: false),
        temporaryDirectory.appending(path: "Missing", directoryHint: .isDirectory)
          .path(percentEncoded: false),
      ]))
  }

  private func makeFolder(named name: String) throws -> URL {
    let url = temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func recentFolder(for url: URL, displayName: String) -> RecentFolder {
    let path = url.path(percentEncoded: false)
    return RecentFolder(
      id: path,
      url: url,
      displayName: displayName,
      path: path,
      lastOpenedAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func expectedPath(named name: String) -> String {
    "\(temporaryDirectoryPath!)/\(name)"
  }
}
