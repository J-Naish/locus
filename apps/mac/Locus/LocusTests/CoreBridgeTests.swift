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
}
