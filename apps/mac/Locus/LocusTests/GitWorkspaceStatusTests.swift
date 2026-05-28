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
      GitSidebarStatusAggregator.statuses(for: changes, workspaceURL: workspaceURL),
      [
        "/tmp/locus/docs": .modified,
        "/tmp/locus/docs/specs": .modified,
        "/tmp/locus/docs/specs/brief.md": .modified,
      ]
    )
  }

  func testAddedStatusWinsForContainingFolder() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let changes = [
      GitStatusChange(path: "docs/edited.md", kind: .modified),
      GitStatusChange(path: "docs/new.md", kind: .added),
    ]

    XCTAssertEqual(
      GitSidebarStatusAggregator.statuses(for: changes, workspaceURL: workspaceURL)[
        "/tmp/locus/docs"],
      .added
    )
  }

  func testAddedStatusStillWinsWhenItArrivesBeforeModifiedStatus() {
    let workspaceURL = URL(filePath: "/tmp/locus")
    let changes = [
      GitStatusChange(path: "docs/new.md", kind: .added),
      GitStatusChange(path: "docs/edited.md", kind: .modified),
    ]

    XCTAssertEqual(
      GitSidebarStatusAggregator.statuses(for: changes, workspaceURL: workspaceURL)[
        "/tmp/locus/docs"],
      .added
    )
  }

  func testSkipsChangesOutsideWorkspaceScope() {
    let workspaceURL = URL(filePath: "/tmp/locus/docs")
    let changes = [
      GitStatusChange(path: "../README.md", kind: .modified),
      GitStatusChange(path: "local.md", kind: .modified),
    ]

    XCTAssertEqual(
      GitSidebarStatusAggregator.statuses(for: changes, workspaceURL: workspaceURL),
      [
        "/tmp/locus/docs/local.md": .modified
      ]
    )
  }

  func testProviderReturnsParsedStatusesFromGitExecutable() async throws {
    let scriptURL = try makeExecutableScript(
      """
      printf '?? Notes/new.md\\0 M README.md\\0'
      """
    )
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 1)

    let statuses = await provider.sidebarStatuses(for: URL(filePath: "/tmp/locus"))

    XCTAssertEqual(statuses["/tmp/locus/Notes"], .added)
    XCTAssertEqual(statuses["/tmp/locus/Notes/new.md"], .added)
    XCTAssertEqual(statuses["/tmp/locus/README.md"], .modified)
  }

  func testProviderReadsLargeStatusOutputWithoutPipeDeadlock() async throws {
    let scriptURL = try makeExecutableScript(
      """
      i=0
      while [ "$i" -lt 5000 ]; do
        printf '?? file-%04d.txt\\0' "$i"
        i=$((i + 1))
      done
      """
    )
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 2)

    let statuses = await provider.sidebarStatuses(for: URL(filePath: "/tmp/locus"))

    XCTAssertEqual(statuses["/tmp/locus/file-0000.txt"], .added)
    XCTAssertEqual(statuses["/tmp/locus/file-4999.txt"], .added)
  }

  func testProviderReturnsEmptyStatusesWhenGitCommandTimesOut() async throws {
    let scriptURL = try makeExecutableScript("sleep 1")
    let provider = GitWorkspaceStatusProvider(gitExecutableURL: scriptURL, statusTimeout: 0.05)

    let start = Date()
    let statuses = await provider.sidebarStatuses(for: URL(filePath: "/tmp/locus"))

    XCTAssertTrue(statuses.isEmpty)
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
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
