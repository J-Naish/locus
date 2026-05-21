import Foundation

struct CoreRuntimeSummary: Equatable, Sendable {
    let abiVersion: UInt32
    let coreVersion: String
}

struct CoreBridge: Sendable {
    static let expectedABIVersion: UInt32 = 1

    func runtimeSummary() async throws -> CoreRuntimeSummary {
        try await Task.detached(priority: .userInitiated) {
            try Self.runtimeSummarySync()
        }.value
    }

    private static func runtimeSummarySync() throws -> CoreRuntimeSummary {
        try validateABI()

        return CoreRuntimeSummary(
            abiVersion: locus_core_abi_version(),
            coreVersion: try coreVersion()
        )
    }

    private static func validateABI() throws {
        guard locus_core_is_abi_compatible(Self.expectedABIVersion) else {
            throw CoreBridgeError.incompatibleABI(
                expected: Self.expectedABIVersion,
                actual: locus_core_abi_version()
            )
        }
    }

    private static func coreVersion() throws -> String {
        guard let version = locus_core_version() else {
            throw CoreBridgeError.missingVersionString
        }

        return String(cString: version)
    }
}

enum CoreBridgeError: LocalizedError, Equatable, Sendable {
    case incompatibleABI(expected: UInt32, actual: UInt32)
    case missingVersionString

    var errorDescription: String? {
        switch self {
        case let .incompatibleABI(expected, actual):
            return "Rust core ABI mismatch. Expected \(expected), got \(actual)."
        case .missingVersionString:
            return "Rust core version is unavailable."
        }
    }
}
