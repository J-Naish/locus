import XCTest

@testable import Locus

final class CoreBridgeTests: XCTestCase {
  func testRuntimeSummaryReturnsCompatibleRustCore() async throws {
    let summary = try await CoreBridge().runtimeSummary()

    XCTAssertEqual(summary.abiVersion, CoreBridge.expectedABIVersion)
    XCTAssertFalse(summary.coreVersion.isEmpty)
  }

  func testExpectedABIVersionMatchesRustCore() {
    XCTAssertEqual(locus_core_abi_version(), CoreBridge.expectedABIVersion)
  }

  func testRawCompatibilityCheckRejectsUnexpectedABI() {
    XCTAssertFalse(locus_core_is_abi_compatible(CoreBridge.expectedABIVersion + 1))
  }

  func testWorkspaceFFILayoutMatchesCurrentABI() {
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.size, 64)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.stride, 64)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.path), 0)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.name), 8)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.kind), 16)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.file_type), 20)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.has_size_bytes), 24)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.size_bytes), 32)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.has_modified_unix_seconds), 40)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.modified_unix_seconds), 48)
    XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.offset(of: \.readonly), 56)
    XCTAssertEqual(MemoryLayout<LocusWorkspacePartialError>.size, 16)
    XCTAssertEqual(MemoryLayout<LocusWorkspacePartialError>.stride, 16)
    XCTAssertEqual(MemoryLayout<LocusWorkspacePartialError>.offset(of: \.status), 0)
    XCTAssertEqual(MemoryLayout<LocusWorkspacePartialError>.offset(of: \.message), 8)
  }

  func testHeaderStatusConstantsMatchRustResponses() {
    var rawSnapshot: OpaquePointer?

    let status = locus_core_list_directory(nil, false, &rawSnapshot)

    XCTAssertEqual(status, LOCUS_STATUS_INVALID_ARGUMENT)
    XCTAssertNil(rawSnapshot)
  }

  func testListDirectoryReturnsSwiftWorkspaceSnapshot() async throws {
    let workspace = try TestWorkspace()
    try workspace.createDirectory(named: "Drafts")
    try workspace.createFile(named: "notes.md", contents: "hello")

    let snapshot = try await CoreBridge().listDirectory(at: workspace.url)

    XCTAssertEqual(snapshot.partialErrors, [])
    XCTAssertEqual(snapshot.entries.map(\.name), ["Drafts", "notes.md"])
    XCTAssertEqual(snapshot.entries[0].kind, .directory)
    XCTAssertEqual(snapshot.entries[1].kind, .file)
    XCTAssertEqual(snapshot.entries[1].fileType, .markdown)
    XCTAssertNil(snapshot.entries[1].sizeBytes)
    XCTAssertNil(snapshot.entries[1].modified)
    XCTAssertEqual(
      snapshot.entries[1].id,
      snapshot.entries[1].url.path(percentEncoded: false)
    )
  }

  func testListDirectoryCanIncludeExtendedMetadata() async throws {
    let workspace = try TestWorkspace()
    try workspace.createFile(named: "notes.md", contents: "hello")

    let snapshot = try await CoreBridge().listDirectory(
      at: workspace.url,
      includeExtendedMetadata: true
    )

    XCTAssertEqual(snapshot.entries[0].sizeBytes, 5)
    XCTAssertNotNil(snapshot.entries[0].modified)
  }

  func testListDirectoryReportsDirectorySymlinkTargetKind() async throws {
    let workspace = try TestWorkspace()
    let targetURL = try workspace.createDirectory(named: "Hooks")
    try workspace.createSymbolicLink(named: "hooks-link", destination: targetURL)

    let snapshot = try await CoreBridge().listDirectory(at: workspace.url)
    let linkEntry = try XCTUnwrap(snapshot.entries.first { $0.name == "hooks-link" })

    XCTAssertEqual(linkEntry.kind, .symlinkToDirectory)
    XCTAssertEqual(linkEntry.fileType, .unknown)
  }

  func testListDirectoryReportsFileSymlinkTargetType() async throws {
    let workspace = try TestWorkspace()
    let targetURL = try workspace.createFile(named: "notes.md", contents: "# Notes")
    try workspace.createSymbolicLink(named: "latest", destination: targetURL)

    let snapshot = try await CoreBridge().listDirectory(at: workspace.url)
    let linkEntry = try XCTUnwrap(snapshot.entries.first { $0.name == "latest" })

    XCTAssertEqual(linkEntry.kind, .symlinkToFile)
    XCTAssertEqual(linkEntry.fileType, .markdown)
  }

  func testListDirectoryKeepsBrokenSymlinkUnknown() async throws {
    let workspace = try TestWorkspace()
    try workspace.createSymbolicLink(
      named: "broken-link",
      destination: workspace.url.appendingPathComponent("missing")
    )

    let snapshot = try await CoreBridge().listDirectory(at: workspace.url)
    let linkEntry = try XCTUnwrap(snapshot.entries.first { $0.name == "broken-link" })

    XCTAssertEqual(linkEntry.kind, .symlink)
    XCTAssertEqual(linkEntry.fileType, .unknown)
  }

  func testListDirectoryKeepsUsefulDotfilesAndSkipsNoiseByDefault() async throws {
    let workspace = try TestWorkspace()
    try workspace.createDirectory(named: ".agents")
    try workspace.createDirectory(named: ".git")
    try workspace.createFile(named: ".env")
    try workspace.createFile(named: ".DS_Store")
    try workspace.createFile(named: "project-brief.md")

    let snapshot = try await CoreBridge().listDirectory(at: workspace.url)

    XCTAssertEqual(snapshot.entries.map(\.name), [".agents", ".env", "project-brief.md"])
  }

  func testListDirectoryCanIncludeIgnoredEntries() async throws {
    let workspace = try TestWorkspace()
    try workspace.createDirectory(named: ".git")
    try workspace.createFile(named: ".DS_Store")
    try workspace.createFile(named: "project-brief.md")

    let snapshot = try await CoreBridge().listDirectory(at: workspace.url, includeIgnored: true)

    XCTAssertEqual(snapshot.entries.map(\.name), [".git", ".DS_Store", "project-brief.md"])
  }

  func testListDirectoryReportsTopLevelFailureMessage() async throws {
    let workspace = try TestWorkspace()
    let fileURL = try workspace.createFile(named: "notes.md")

    do {
      _ = try await CoreBridge().listDirectory(at: fileURL)
      XCTFail("Expected file path listing to fail")
    } catch CoreBridgeError.workspaceListFailed(let kind, let message) {
      XCTAssertEqual(kind, .notDirectory)
      XCTAssertFalse(message.isEmpty)
    }
  }

  // MARK: - URL.locusIsReadOnly

  // The folder listing trusts the core's cheap mode-bit `readonly`; this precise
  // check runs once when a document is opened, so it must override the fallback.

  func testLocusIsReadOnlyReportsWritableFileAsWritable() throws {
    let directory = try temporaryDirectory()
    let fileURL = directory.appending(path: "writable.txt")
    try "content".write(to: fileURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(fileURL.locusIsReadOnly(fallback: true))
  }

  func testLocusIsReadOnlyReportsReadOnlyFileAsReadOnly() throws {
    let directory = try temporaryDirectory()
    let fileURL = directory.appending(path: "locked.txt")
    try "content".write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o444], ofItemAtPath: fileURL.path(percentEncoded: false))

    XCTAssertTrue(fileURL.locusIsReadOnly(fallback: false))
  }

  func testLocusIsReadOnlyReturnsFallbackWhenMetadataIsUnreadable() {
    let missingURL = FileManager.default.temporaryDirectory.appending(
      path: "locus-missing-\(UUID().uuidString).txt")

    XCTAssertTrue(missingURL.locusIsReadOnly(fallback: true))
    XCTAssertFalse(missingURL.locusIsReadOnly(fallback: false))
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
      path: "locus-corebridge-tests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }
}

private final class TestWorkspace {
  let url: URL

  init() throws {
    let baseURL = FileManager.default.temporaryDirectory
    url = baseURL.appendingPathComponent(
      "locus-core-bridge-test-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  @discardableResult
  func createDirectory(named name: String) throws -> URL {
    let directoryURL = url.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: false
    )
    return directoryURL
  }

  @discardableResult
  func createFile(named name: String, contents: String = "") throws -> URL {
    let fileURL = url.appendingPathComponent(name, isDirectory: false)
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
  }

  func createSymbolicLink(named name: String, destination: URL) throws {
    try FileManager.default.createSymbolicLink(
      at: url.appendingPathComponent(name),
      withDestinationURL: destination
    )
  }
}
