import XCTest

@testable import Locus

final class DocumentChangeMonitorTests: XCTestCase {
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
  func testSwitchingFilesKeepsChangeHandlerForNewFile() throws {
    let directory = try makeTemporaryDirectory()
    let firstFile = directory.appending(path: "first.md")
    let secondFile = directory.appending(path: "second.md")
    try "first".write(to: firstFile, atomically: false, encoding: .utf8)
    try "second".write(to: secondFile, atomically: false, encoding: .utf8)

    let monitor = DocumentChangeMonitor(debounceDuration: Self.shortDebounce)
    let firstFileChange = expectation(description: "first file change should not be detected")
    firstFileChange.isInverted = true
    let secondFileChange = expectation(description: "second file change detected")

    monitor.startMonitoring(firstFile) {
      firstFileChange.fulfill()
    }
    monitor.startMonitoring(secondFile) {
      secondFileChange.fulfill()
    }

    try "first changed".write(to: firstFile, atomically: false, encoding: .utf8)
    try "second changed".write(to: secondFile, atomically: false, encoding: .utf8)

    wait(for: [secondFileChange], timeout: 2)
    wait(for: [firstFileChange], timeout: Self.invertedWaitTimeout)
    monitor.stopMonitoring()
  }

  @MainActor
  func testDeleteAndRecreateKeepsMonitoringSamePath() throws {
    let directory = try makeTemporaryDirectory()
    let file = directory.appending(path: "document.md")
    try "initial".write(to: file, atomically: false, encoding: .utf8)

    let monitor = DocumentChangeMonitor(debounceDuration: Self.shortDebounce)
    let firstChange = expectation(description: "delete and recreate detected")
    let secondChange = expectation(description: "recreated file change detected")

    monitor.startMonitoring(file) {
      firstChange.fulfill()
    }

    try FileManager.default.removeItem(at: file)
    try "recreated".write(to: file, atomically: false, encoding: .utf8)
    wait(for: [firstChange], timeout: 2)

    monitor.startMonitoring(file) {
      secondChange.fulfill()
    }
    try "changed again".write(to: file, atomically: false, encoding: .utf8)
    wait(for: [secondChange], timeout: 2)
    monitor.stopMonitoring()
  }

  @MainActor
  func testDebouncesRapidChangesIntoOneNotification() throws {
    let directory = try makeTemporaryDirectory()
    let file = directory.appending(path: "document.md")
    try "initial".write(to: file, atomically: false, encoding: .utf8)

    let monitor = DocumentChangeMonitor(debounceDuration: Self.shortDebounce)
    let change = expectation(description: "rapid changes coalesced")
    change.expectedFulfillmentCount = 1
    change.assertForOverFulfill = true

    monitor.startMonitoring(file) {
      change.fulfill()
    }

    try "first".write(to: file, atomically: false, encoding: .utf8)
    try "second".write(to: file, atomically: false, encoding: .utf8)
    try "third".write(to: file, atomically: false, encoding: .utf8)

    wait(for: [change], timeout: 2)
    monitor.stopMonitoring()
  }

  @MainActor
  func testStopMonitoringSuppressesLaterChanges() throws {
    let directory = try makeTemporaryDirectory()
    let file = directory.appending(path: "document.md")
    try "initial".write(to: file, atomically: false, encoding: .utf8)

    let monitor = DocumentChangeMonitor(debounceDuration: Self.shortDebounce)
    let change = expectation(description: "stopped monitor should not detect changes")
    change.isInverted = true

    monitor.startMonitoring(file) {
      change.fulfill()
    }
    monitor.stopMonitoring()

    try "changed".write(to: file, atomically: false, encoding: .utf8)
    wait(for: [change], timeout: Self.invertedWaitTimeout)
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "locus-document-monitor-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    temporaryDirectories.append(directory)
    return directory
  }
}
