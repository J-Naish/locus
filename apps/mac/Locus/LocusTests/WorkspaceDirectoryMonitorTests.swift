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

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "locus-directory-monitor-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    temporaryDirectories.append(directory)
    return directory
  }
}
