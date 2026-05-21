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

    func testWorkspaceFFILayoutMatchesABIv1() {
        XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.size, 64)
        XCTAssertEqual(MemoryLayout<LocusWorkspaceEntry>.stride, 64)
        XCTAssertEqual(MemoryLayout<LocusWorkspacePartialError>.size, 16)
        XCTAssertEqual(MemoryLayout<LocusWorkspacePartialError>.stride, 16)
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
        XCTAssertEqual(snapshot.entries[1].sizeBytes, 5)
        XCTAssertEqual(
            snapshot.entries[1].id,
            snapshot.entries[1].url.path(percentEncoded: false)
        )
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

    func createDirectory(named name: String) throws {
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: false
        )
    }

    @discardableResult
    func createFile(named name: String, contents: String = "") throws -> URL {
        let fileURL = url.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
