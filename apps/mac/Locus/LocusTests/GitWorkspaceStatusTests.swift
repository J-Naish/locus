import Darwin
import Foundation
import XCTest

@testable import Locus

final class GitWorkspaceStatusTests: XCTestCase {
  func testParsesModifiedAndUntrackedPorcelainRecords() {
    let data = Data(" M README.md\u{0}?? Notes/new.md\u{0}".utf8)

    XCTAssertEqual(
      GitStatusParser.parsePorcelainZ(data),
      [
        GitStatusChange(path: "README.md", kind: .modified),
        GitStatusChange(path: "Notes/new.md", kind: .added),
      ]
    )
  }

  func testTreatsStagedAddedFilesAsAdded() {
    let data = Data("A  Drafts/report.md\u{0}AM Drafts/edited-new.md\u{0}".utf8)

    XCTAssertEqual(
      GitStatusParser.parsePorcelainZ(data),
      [
        GitStatusChange(path: "Drafts/report.md", kind: .added),
        GitStatusChange(path: "Drafts/edited-new.md", kind: .added),
      ]
    )
  }

  func testParsesRenameDestinationAndSkipsOriginalPath() {
    let data = Data("R  Current.md\u{0}Previous.md\u{0} M Other.md\u{0}".utf8)

    XCTAssertEqual(
      GitStatusParser.parsePorcelainZ(data),
      [
        GitStatusChange(path: "Current.md", kind: .modified),
        GitStatusChange(path: "Other.md", kind: .modified),
      ]
    )
  }

  func testAggregatesFileStatusToContainingFolders() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let changes = [
      GitStatusChange(path: "docs/specs/brief.md", kind: .modified)
    ]

    XCTAssertEqual(
      GitSidebarStatusAggregator.statuses(
        for: changes,
        workspaceURL: workspaceURL,
        repositoryRootURL: workspaceURL
      ),
      [
        "/tmp/locus/docs": .modified,
        "/tmp/locus/docs/specs": .modified,
        "/tmp/locus/docs/specs/brief.md": .modified,
      ]
    )
  }

  func testAggregatesRepositoryRelativePathsInsideChildWorkspace() {
    let repositoryRootURL = URL(filePath: "/tmp/locus")
    let workspaceURL = URL(filePath: "/tmp/locus/apps/mac")
    let changes = [
      GitStatusChange(path: "apps/mac/Locus/App.swift", kind: .modified),
      GitStatusChange(path: "apps/mac/New.md", kind: .added),
      GitStatusChange(path: "README.md", kind: .modified),
    ]

    let statuses = GitSidebarStatusAggregator.statuses(
      for: changes,
      workspaceURL: workspaceURL,
      repositoryRootURL: repositoryRootURL
    )

    XCTAssertEqual(statuses["/tmp/locus/apps/mac/Locus"], .modified)
    XCTAssertEqual(statuses["/tmp/locus/apps/mac/Locus/App.swift"], .modified)
    XCTAssertEqual(statuses["/tmp/locus/apps/mac/New.md"], .added)
    XCTAssertEqual(statuses["/tmp/locus/apps/mac"], .modified)
    XCTAssertNil(statuses["/tmp/locus/README.md"])
  }

  func testRepositoryRootWorkspaceDoesNotMarkRootItself() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let changes = [
      GitStatusChange(path: "docs/edited.md", kind: .modified)
    ]

    let statuses = GitSidebarStatusAggregator.statuses(
      for: changes,
      workspaceURL: workspaceURL,
      repositoryRootURL: workspaceURL
    )

    XCTAssertNil(statuses["/tmp/locus"])
    XCTAssertEqual(statuses["/tmp/locus/docs"], .modified)
    XCTAssertEqual(statuses["/tmp/locus/docs/edited.md"], .modified)
  }

  func testModifiedStatusWinsForContainingFolder() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let changes = [
      GitStatusChange(path: "docs/edited.md", kind: .modified),
      GitStatusChange(path: "docs/new.md", kind: .added),
    ]

    XCTAssertEqual(
      GitSidebarStatusAggregator.statuses(
        for: changes,
        workspaceURL: workspaceURL,
        repositoryRootURL: workspaceURL
      )["/tmp/locus/docs"],
      .modified
    )
  }

  func testModifiedStatusStillWinsWhenItArrivesAfterAddedStatus() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let changes = [
      GitStatusChange(path: "docs/new.md", kind: .added),
      GitStatusChange(path: "docs/edited.md", kind: .modified),
    ]

    XCTAssertEqual(
      GitSidebarStatusAggregator.statuses(
        for: changes,
        workspaceURL: workspaceURL,
        repositoryRootURL: workspaceURL
      )["/tmp/locus/docs"],
      .modified
    )
  }

  func testSkipsChangesOutsideWorkspaceScope() {
    let workspaceURL = URL(filePath: "/tmp/locus/docs")
    let changes = [
      GitStatusChange(path: "../README.md", kind: .modified),
      GitStatusChange(path: "local.md", kind: .modified),
    ]

    XCTAssertEqual(
      GitSidebarStatusAggregator.statuses(
        for: changes,
        workspaceURL: workspaceURL,
        repositoryRootURL: workspaceURL
      ),
      [
        "/tmp/locus/docs/local.md": .modified
      ]
    )
  }

  func testProviderReturnsParsedStatusesFromGitExecutable() async throws {
    let scriptURL = try makeExecutableScript(
      """
      case "$*" in
        *rev-parse*) printf '/tmp/locus/.git\\n.git\\n/tmp/locus\\n' ;;
        *) printf '?? Notes/new.md\\0 M README.md\\0' ;;
      esac
      """
    )
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 1)

    let statuses = await provider.sidebarStatuses(
      for: URL(filePath: "/tmp/locus"),
      repositoryRootURL: URL(filePath: "/tmp/locus")
    )

    XCTAssertEqual(statuses["/tmp/locus/Notes"], .added)
    XCTAssertEqual(statuses["/tmp/locus/Notes/new.md"], .added)
    XCTAssertEqual(statuses["/tmp/locus/README.md"], .modified)
  }

  func testProviderMapsRepositoryRelativeStatusesIntoChildWorkspace() async throws {
    let scriptURL = try makeExecutableScript(
      """
      case "$*" in
        *rev-parse*) printf '/tmp/locus/.git\\n.git\\n/tmp/locus\\n' ;;
        *) printf ' M apps/mac/README.md\\0?? apps/mac/New.md\\0 M README.md\\0' ;;
      esac
      """
    )
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 1)

    let statuses = await provider.sidebarStatuses(
      for: URL(filePath: "/tmp/locus/apps/mac"),
      repositoryRootURL: URL(filePath: "/tmp/locus")
    )

    XCTAssertEqual(statuses["/tmp/locus/apps/mac/README.md"], .modified)
    XCTAssertEqual(statuses["/tmp/locus/apps/mac/New.md"], .added)
    XCTAssertEqual(statuses["/tmp/locus/apps/mac"], .modified)
    XCTAssertNil(statuses["/tmp/locus/README.md"])
  }

  func testProviderFallsBackToWorkspaceRootWhenRepositoryRootIsUnavailable() async throws {
    let scriptURL = try makeExecutableScript(
      """
      case "$*" in
        *rev-parse*) exit 128 ;;
        *) printf ' M README.md\\0' ;;
      esac
      """
    )
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 1)

    let statuses = await provider.sidebarStatuses(
      for: URL(filePath: "/tmp/locus"),
      repositoryRootURL: nil
    )

    XCTAssertEqual(statuses["/tmp/locus/README.md"], .modified)
  }

  func testProviderReadsLargeStatusOutputWithoutPipeDeadlock() async throws {
    let scriptURL = try makeExecutableScript(
      """
      case "$*" in
        *rev-parse*)
          printf '/tmp/locus/.git\\n.git\\n/tmp/locus\\n'
          ;;
        *)
          i=0
          while [ "$i" -lt 5000 ]; do
            printf '?? file-%04d.txt\\0' "$i"
            i=$((i + 1))
          done
          ;;
      esac
      """
    )
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 2)

    let statuses = await provider.sidebarStatuses(
      for: URL(filePath: "/tmp/locus"),
      repositoryRootURL: URL(filePath: "/tmp/locus")
    )

    XCTAssertEqual(statuses["/tmp/locus/file-0000.txt"], .added)
    XCTAssertEqual(statuses["/tmp/locus/file-4999.txt"], .added)
  }

  func testProviderReturnsEmptyStatusesWhenGitCommandTimesOut() async throws {
    let scriptURL = try makeExecutableScript("sleep 1")
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 0.05)

    let start = Date()
    let statuses = await provider.sidebarStatuses(
      for: URL(filePath: "/tmp/locus"),
      repositoryRootURL: URL(filePath: "/tmp/locus")
    )

    XCTAssertTrue(statuses.isEmpty)
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
  }

  func testRepositoryMetadataParserResolvesRelativeCommonDirectoryFromWorkspace() {
    let workspaceURL = URL(filePath: "/tmp/locus/apps/mac")
    let data = Data("/tmp/locus/.git\n../../.git\n../..\n".utf8)

    XCTAssertEqual(
      GitRepositoryMetadataParser.parse(data, workspaceURL: workspaceURL),
      GitRepositoryMetadata(
        gitDirectoryURL: URL(filePath: "/tmp/locus/.git"),
        commonDirectoryURL: URL(filePath: "/tmp/locus/.git"),
        workTreeURL: URL(filePath: "/tmp/locus", directoryHint: .isDirectory)
      )
    )
  }

  func testProviderReturnsRepositoryMetadataFromGitExecutable() async throws {
    let scriptURL = try makeExecutableScript(
      """
      printf '/tmp/locus/.git\\n.git\\n/tmp/locus\\n'
      """
    )
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 1)

    let metadata = await provider.repositoryMetadata(for: URL(filePath: "/tmp/locus"))

    XCTAssertEqual(
      metadata,
      GitRepositoryMetadata(
        gitDirectoryURL: URL(filePath: "/tmp/locus/.git"),
        commonDirectoryURL: URL(filePath: "/tmp/locus/.git"),
        workTreeURL: URL(filePath: "/tmp/locus")
      )
    )
  }

  @MainActor
  func testRepositoryMetadataMonitorNotifiesWhenHeadChanges() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appending(
        path: "GitRepositoryMetadataMonitorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let gitDirectoryURL = directoryURL.appending(path: ".git", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: gitDirectoryURL, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directoryURL)
    }

    let headURL = gitDirectoryURL.appending(path: "HEAD")
    try Data("ref: refs/heads/main\n".utf8).write(to: headURL, options: .withoutOverwriting)

    let expectation = expectation(description: "Git metadata change is observed")
    let monitor = GitRepositoryMetadataMonitor(debounceDuration: .milliseconds(20))
    monitor.startMonitoring(
      GitRepositoryMetadata(
        gitDirectoryURL: gitDirectoryURL,
        commonDirectoryURL: gitDirectoryURL,
        workTreeURL: directoryURL
      )
    ) { change in
      XCTAssertEqual(change, .metadataChanged)
      expectation.fulfill()
    }

    try await Task.sleep(for: .milliseconds(50))
    try Data("ref: refs/heads/main-updated\n".utf8).write(to: headURL)

    await fulfillment(of: [expectation], timeout: 1)
    monitor.stopMonitoring()
  }

  @MainActor
  func testRepositoryMetadataMonitorNotifiesWhenCurrentHeadReferenceChanges() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appending(
        path: "GitRepositoryMetadataMonitorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let gitDirectoryURL = directoryURL.appending(path: ".git", directoryHint: .isDirectory)
    let headsURL = gitDirectoryURL.appending(path: "refs/heads", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: headsURL, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directoryURL)
    }

    let headURL = gitDirectoryURL.appending(path: "HEAD")
    let mainRefURL = headsURL.appending(path: "main")
    try Data("ref: refs/heads/main\n".utf8).write(to: headURL, options: .withoutOverwriting)
    try Data("0000000000000000000000000000000000000000\n".utf8)
      .write(to: mainRefURL, options: .withoutOverwriting)

    let expectation = expectation(description: "Current Git branch ref change is observed")
    let monitor = GitRepositoryMetadataMonitor(debounceDuration: .milliseconds(20))
    monitor.startMonitoring(
      GitRepositoryMetadata(
        gitDirectoryURL: gitDirectoryURL,
        commonDirectoryURL: gitDirectoryURL,
        workTreeURL: directoryURL
      )
    ) { change in
      XCTAssertEqual(change, .statusOnly)
      expectation.fulfill()
    }

    try await Task.sleep(for: .milliseconds(50))
    try Data("1111111111111111111111111111111111111111\n".utf8).write(to: mainRefURL)

    await fulfillment(of: [expectation], timeout: 1)
    monitor.stopMonitoring()
  }

  private func makeExecutableScript(_ body: String) throws -> URL {
    let directoryURL = FileManager.default.temporaryDirectory
      .appending(path: "GitWorkspaceStatusTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directoryURL)
    }

    let scriptURL = directoryURL.appending(path: "git")
    let scriptData = Data("#!/bin/sh\n\(body)\n".utf8)
    try scriptData.write(to: scriptURL, options: .withoutOverwriting)
    _ = chmod(scriptURL.path(percentEncoded: false), 0o755)
    return scriptURL
  }
}
