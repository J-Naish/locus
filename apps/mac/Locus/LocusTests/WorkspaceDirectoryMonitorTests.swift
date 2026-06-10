import XCTest

@testable import Locus

final class WorkspaceDirectoryMonitorTests: XCTestCase {
  private static let shortDebounce: Duration = .milliseconds(50)
  private static let invertedWaitTimeout: TimeInterval = 0.3
  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryDirectories.removeAll()
    try super.tearDownWithError()
  }

  @MainActor
  func testCallsChangeHandlerWhenDirectoryContentsChange() throws {
    let directory = try makeTemporaryDirectory()
    let monitor = WorkspaceDirectoryMonitor(debounceDuration: Self.shortDebounce)
    let changeDetected = expectation(description: "directory change detected")

    monitor.startMonitoring(directory) {
      changeDetected.fulfill()
    }

    try "updated".write(
      to: directory.appending(path: "created.txt"),
      atomically: true,
      encoding: .utf8
    )

    wait(for: [changeDetected], timeout: 2)
    monitor.stopMonitoring()
  }

  @MainActor
  func testStopMonitoringPreventsLaterChangeCallbacks() throws {
    let directory = try makeTemporaryDirectory()
    let monitor = WorkspaceDirectoryMonitor(debounceDuration: Self.shortDebounce)
    let unexpectedChange = expectation(description: "directory change should not be detected")
    unexpectedChange.isInverted = true

    monitor.startMonitoring(directory) {
      unexpectedChange.fulfill()
    }
    monitor.stopMonitoring()

    try "updated".write(
      to: directory.appending(path: "created-after-stop.txt"),
      atomically: true,
      encoding: .utf8
    )

    wait(for: [unexpectedChange], timeout: Self.invertedWaitTimeout)
  }

  @MainActor
  func testSwitchingDirectoriesIgnoresPreviousDirectoryChanges() throws {
    let firstDirectory = try makeTemporaryDirectory()
    let secondDirectory = try makeTemporaryDirectory()
    let monitor = WorkspaceDirectoryMonitor(debounceDuration: Self.shortDebounce)
    let firstDirectoryChange = expectation(
      description: "first directory change should not be detected")
    firstDirectoryChange.isInverted = true
    let secondDirectoryChange = expectation(description: "second directory change detected")

    monitor.startMonitoring(firstDirectory) {
      firstDirectoryChange.fulfill()
    }
    monitor.startMonitoring(secondDirectory) {
      secondDirectoryChange.fulfill()
    }

    try "first".write(
      to: firstDirectory.appending(path: "ignored.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "second".write(
      to: secondDirectory.appending(path: "detected.txt"),
      atomically: true,
      encoding: .utf8
    )

    wait(for: [secondDirectoryChange], timeout: 2)
    wait(for: [firstDirectoryChange], timeout: Self.invertedWaitTimeout)
    monitor.stopMonitoring()
  }

  @MainActor
  func testDebouncesRapidDirectoryChangesIntoOneCallback() throws {
    let directory = try makeTemporaryDirectory()
    let monitor = WorkspaceDirectoryMonitor(debounceDuration: Self.shortDebounce)
    let changeDetected = expectation(description: "directory change detected once")
    changeDetected.expectedFulfillmentCount = 1

    monitor.startMonitoring(directory) {
      changeDetected.fulfill()
    }

    try "first".write(
      to: directory.appending(path: "first.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "second".write(
      to: directory.appending(path: "second.txt"),
      atomically: true,
      encoding: .utf8
    )
    try "third".write(
      to: directory.appending(path: "third.txt"),
      atomically: true,
      encoding: .utf8
    )

    wait(for: [changeDetected], timeout: 2)
    monitor.stopMonitoring()
  }

  @MainActor
  func testFailedStartOnMissingDirectoryLeavesMonitorReusable() throws {
    // `open()` fails for a directory that does not exist; the monitor must
    // swallow that and still be restartable against a real directory.
    let monitor = WorkspaceDirectoryMonitor(debounceDuration: Self.shortDebounce)
    let missing = FileManager.default.temporaryDirectory
      .appending(path: "locus-monitor-missing-\(UUID().uuidString)", directoryHint: .isDirectory)
    monitor.startMonitoring(missing) {
      XCTFail("a directory that failed to open must never report changes")
    }
    monitor.stopMonitoring()

    let directory = try makeTemporaryDirectory()
    let changeDetected = expectation(description: "directory change detected after failed start")
    changeDetected.assertForOverFulfill = false
    monitor.startMonitoring(directory) {
      changeDetected.fulfill()
    }
    try "recovered".write(
      to: directory.appending(path: "recovered.txt"),
      atomically: true,
      encoding: .utf8
    )

    wait(for: [changeDetected], timeout: 2)
    monitor.stopMonitoring()
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "locus-directory-monitor-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    temporaryDirectories.append(directory)
    return directory
  }
}

final class WorkspaceTreeMonitorTests: XCTestCase {
  private static let shortDebounce: Duration = .milliseconds(50)
  /// FSEvents delivery is bounded by the monitor's coalescing latency (0.2 s)
  /// plus debounce and main-actor hops; a generous timeout absorbs a loaded
  /// parallel test runner without slowing the success path.
  private static let deliveryTimeout: TimeInterval = 5
  /// An inverted "stays silent" window must comfortably cover latency plus
  /// debounce, or a late unwanted callback would slip past the assertion.
  private static let invertedWaitTimeout: TimeInterval = 1.0
  private var temporaryDirectories: [URL] = []

  override func tearDownWithError() throws {
    for directory in temporaryDirectories {
      try? FileManager.default.removeItem(at: directory)
    }
    temporaryDirectories.removeAll()
    try super.tearDownWithError()
  }

  // MARK: Churn-path exclusion (pure)

  func testExcludedChurnPathMatchesWholeComponentsOnly() {
    XCTAssertTrue(WorkspaceTreeMonitor.isExcludedChurnPath("/w/.git/objects/ab"))
    XCTAssertTrue(WorkspaceTreeMonitor.isExcludedChurnPath("/w/node_modules/pkg/index.js"))
    XCTAssertTrue(WorkspaceTreeMonitor.isExcludedChurnPath("/w/app/DerivedData/Build"))
    XCTAssertTrue(WorkspaceTreeMonitor.isExcludedChurnPath(".git"))

    // Whole-component matching, never substrings: user paths that merely
    // contain an excluded name keep refreshing the sidebar.
    XCTAssertFalse(WorkspaceTreeMonitor.isExcludedChurnPath("/w/.github/workflows/ci.yml"))
    XCTAssertFalse(WorkspaceTreeMonitor.isExcludedChurnPath("/w/my.git/file.txt"))
    XCTAssertFalse(WorkspaceTreeMonitor.isExcludedChurnPath("/w/notes/git/readme.md"))
    XCTAssertFalse(WorkspaceTreeMonitor.isExcludedChurnPath("/w/docs/file.md"))
    XCTAssertFalse(WorkspaceTreeMonitor.isExcludedChurnPath(""))
  }

  // MARK: FSEvents lifecycle (integration)

  @MainActor
  func testReportsExternalChangeInANestedSubdirectory() throws {
    let root = try makeTemporaryDirectory()
    let nested = root.appending(path: "a/b", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let monitor = WorkspaceTreeMonitor(debounceDuration: Self.shortDebounce)
    let changeDetected = expectation(description: "nested external change detected")
    changeDetected.assertForOverFulfill = false
    monitor.startMonitoring(root) {
      changeDetected.fulfill()
    }

    try touchExternally(nested.appending(path: "created.txt"))

    wait(for: [changeDetected], timeout: Self.deliveryTimeout)
    monitor.stopMonitoring()
  }

  @MainActor
  func testIgnoresChangesConfinedToChurnDirectories() throws {
    let root = try makeTemporaryDirectory()
    let gitDirectory = root.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    let monitor = WorkspaceTreeMonitor(debounceDuration: Self.shortDebounce)
    let unexpectedChange = expectation(description: "churn-only batch should not refresh")
    unexpectedChange.isInverted = true
    monitor.startMonitoring(root) {
      unexpectedChange.fulfill()
    }

    try touchExternally(gitDirectory.appending(path: "index.lock"))

    wait(for: [unexpectedChange], timeout: Self.invertedWaitTimeout)
    monitor.stopMonitoring()
  }

  @MainActor
  func testStopMonitoringPreventsLaterCallbacks() throws {
    let root = try makeTemporaryDirectory()
    let monitor = WorkspaceTreeMonitor(debounceDuration: Self.shortDebounce)
    let unexpectedChange = expectation(description: "change after stop should not be reported")
    unexpectedChange.isInverted = true
    monitor.startMonitoring(root) {
      unexpectedChange.fulfill()
    }
    monitor.stopMonitoring()

    try touchExternally(root.appending(path: "after-stop.txt"))

    wait(for: [unexpectedChange], timeout: Self.invertedWaitTimeout)
  }

  @MainActor
  func testRestartAfterStopKeepsDelivering() throws {
    let root = try makeTemporaryDirectory()
    let monitor = WorkspaceTreeMonitor(debounceDuration: Self.shortDebounce)
    monitor.startMonitoring(root) {
      XCTFail("the first start was stopped before any change was made")
    }
    monitor.stopMonitoring()

    let changeDetected = expectation(description: "change detected after restart")
    changeDetected.assertForOverFulfill = false
    monitor.startMonitoring(root) {
      changeDetected.fulfill()
    }
    try touchExternally(root.appending(path: "after-restart.txt"))

    wait(for: [changeDetected], timeout: Self.deliveryTimeout)
    monitor.stopMonitoring()
  }

  @MainActor
  func testStoppingRightAfterAnExternalChangeDoesNotCrash() throws {
    // Teardown-drain stress (the passUnretained FSEvents callback must finish
    // against a live monitor before the stream is released — see
    // `stopMonitoring`). The stop delay sweeps the event-delivery window
    // around the 0.2 s FSEvents latency, so some iterations stop exactly as
    // the callback lands on the monitor queue. Sleeping on the main thread is
    // safe here: the callback never blocks on main. Absence of a crash is the
    // assertion.
    let root = try makeTemporaryDirectory()
    let monitor = WorkspaceTreeMonitor(debounceDuration: Self.shortDebounce)
    let stopDelays: [TimeInterval] = [0, 0.05, 0.15, 0.2, 0.25, 0.3]
    for (iteration, stopDelay) in stopDelays.enumerated() {
      monitor.startMonitoring(root) {}
      try touchExternally(root.appending(path: "stress-\(iteration).txt"))
      if stopDelay > 0 {
        Thread.sleep(forTimeInterval: stopDelay)
      }
      monitor.stopMonitoring()
    }
  }

  // MARK: Helpers

  /// Touches `url` from a child process. The monitor ignores events caused by
  /// this process itself (`kFSEventStreamCreateFlagIgnoreSelf`), so the change
  /// must come from another pid to be observed — exactly like the external
  /// agent/tool writes the monitor exists to catch.
  private func touchExternally(_ url: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/touch")
    process.arguments = [url.path(percentEncoded: false)]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "touch must succeed for the test to be valid")
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "locus-tree-monitor-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    temporaryDirectories.append(directory)
    return directory
  }
}
