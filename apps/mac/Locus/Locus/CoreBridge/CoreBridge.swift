import Foundation
import OSLog

struct CoreRuntimeSummary: Equatable, Sendable {
  let abiVersion: UInt32
  let coreVersion: String
}

struct WorkspaceSnapshot: Equatable, Sendable {
  let entries: [WorkspaceEntry]
  let partialErrors: [WorkspacePartialError]
}

struct WorkspaceEntry: Equatable, Identifiable, Sendable {
  let id: String
  let url: URL
  let name: String
  let kind: WorkspaceEntryKind
  let fileType: WorkspaceFileType
  let sizeBytes: UInt64?
  let modified: Date?
  let isReadOnly: Bool
}

enum WorkspaceEntryKind: Equatable, Sendable {
  case directory
  case file
  case symlink
  case symlinkToDirectory
  case symlinkToFile
  case other

  var isDirectoryLike: Bool {
    self == .directory || self == .symlinkToDirectory
  }

  var isFileLike: Bool {
    self == .file || self == .symlinkToFile
  }

  var isSymlink: Bool {
    switch self {
    case .symlink, .symlinkToDirectory, .symlinkToFile:
      return true
    case .directory, .file, .other:
      return false
    }
  }
}

enum WorkspaceFileType: Equatable, Sendable {
  case markdown
  case structuredText
  case pdf
  case office
  case image
  case audio
  case video
  case plainText
  case code
  case unknown
}

enum WorkspaceErrorKind: Equatable, Sendable {
  case invalidArgument
  case notFound
  case notDirectory
  case readDirectory
  case readEntry
  case readMetadata
  case unknown(UInt32)

  var statusCode: UInt32 {
    switch self {
    case .invalidArgument:
      return LOCUS_STATUS_INVALID_ARGUMENT
    case .notFound:
      return LOCUS_STATUS_NOT_FOUND
    case .notDirectory:
      return LOCUS_STATUS_NOT_DIRECTORY
    case .readDirectory:
      return LOCUS_STATUS_READ_DIRECTORY
    case .readEntry:
      return LOCUS_STATUS_READ_ENTRY
    case .readMetadata:
      return LOCUS_STATUS_READ_METADATA
    case .unknown(let status):
      return status
    }
  }
}

struct WorkspacePartialError: Equatable, Identifiable, Sendable {
  let id: String
  let kind: WorkspaceErrorKind
  let message: String
}

struct CoreBridge: Sendable {
  static let expectedABIVersion: UInt32 = 2
  private static let logger = Logger(subsystem: "Locus", category: "CoreBridge")

  func runtimeSummary() async throws -> CoreRuntimeSummary {
    try await Task.detached(priority: .userInitiated) {
      try Self.runtimeSummarySync()
    }.value
  }

  func listDirectory(
    at folderURL: URL,
    includeIgnored: Bool = false,
    includeExtendedMetadata: Bool = false
  ) async throws -> WorkspaceSnapshot {
    try await Task.detached(priority: .userInitiated) {
      try Self.listDirectorySync(
        at: folderURL,
        includeIgnored: includeIgnored,
        includeExtendedMetadata: includeExtendedMetadata
      )
    }.value
  }

  private static func runtimeSummarySync() throws -> CoreRuntimeSummary {
    try validateABI()

    return CoreRuntimeSummary(
      abiVersion: locus_core_abi_version(),
      coreVersion: try coreVersion()
    )
  }

  private static func listDirectorySync(
    at folderURL: URL,
    includeIgnored: Bool,
    includeExtendedMetadata: Bool
  ) throws -> WorkspaceSnapshot {
    try validateABI()

    var rawSnapshot: OpaquePointer?
    // Keep this synchronous: lastErrorMessage() is thread-local and must be
    // read on the same thread immediately after the FFI call.
    let status = folderURL.path(percentEncoded: false).withCString { path in
      locus_core_list_directory_with_options(
        path,
        includeIgnored,
        includeExtendedMetadata,
        &rawSnapshot
      )
    }

    guard status == LOCUS_STATUS_OK else {
      throw CoreBridgeError.workspaceListFailed(
        kind: workspaceErrorKind(status),
        message: lastErrorMessage()
      )
    }

    guard let rawSnapshot else {
      throw CoreBridgeError.missingWorkspaceSnapshot
    }

    defer {
      locus_workspace_snapshot_free(rawSnapshot)
    }

    // The C strings and arrays are borrowed from rawSnapshot, so every
    // value crossing this boundary must be copied into Swift types before
    // the defer above releases the Rust-owned snapshot.
    return WorkspaceSnapshot(
      entries: workspaceEntries(from: rawSnapshot),
      partialErrors: workspacePartialErrors(from: rawSnapshot)
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

  private static func workspaceEntries(
    from snapshot: OpaquePointer
  ) -> [WorkspaceEntry] {
    let count = locus_workspace_snapshot_entry_count(snapshot)
    guard count > 0, let entries = locus_workspace_snapshot_entries(snapshot) else {
      return []
    }

    return UnsafeBufferPointer(start: entries, count: count).map { entry in
      let kind = workspaceEntryKind(entry.kind)
      let path = String(cString: entry.path)

      return WorkspaceEntry(
        id: path,
        url: URL(
          filePath: path,
          directoryHint: kind.isDirectoryLike ? .isDirectory : .notDirectory
        ),
        name: String(cString: entry.name),
        kind: kind,
        fileType: workspaceFileType(entry.file_type),
        sizeBytes: entry.has_size_bytes ? entry.size_bytes : nil,
        modified: entry.has_modified_unix_seconds
          ? Date(timeIntervalSince1970: TimeInterval(entry.modified_unix_seconds))
          : nil,
        isReadOnly: isReadOnlyFile(at: path, fallback: entry.readonly)
      )
    }
  }

  private static func workspacePartialErrors(
    from snapshot: OpaquePointer
  ) -> [WorkspacePartialError] {
    let count = locus_workspace_snapshot_partial_error_count(snapshot)
    guard count > 0, let partialErrors = locus_workspace_snapshot_partial_errors(snapshot) else {
      return []
    }

    let partialErrorBuffer = UnsafeBufferPointer(start: partialErrors, count: count)
    var errors: [WorkspacePartialError] = []
    errors.reserveCapacity(count)
    for (index, partialError) in partialErrorBuffer.enumerated() {
      let kind = workspaceErrorKind(partialError.status)
      let message = String(cString: partialError.message)

      errors.append(
        WorkspacePartialError(
          id: "\(index):\(partialError.status):\(message)",
          kind: kind,
          message: message
        )
      )
    }
    return errors
  }

  private static func workspaceEntryKind(_ value: LocusWorkspaceEntryKind) -> WorkspaceEntryKind {
    switch value {
    case LOCUS_WORKSPACE_ENTRY_DIRECTORY:
      return .directory
    case LOCUS_WORKSPACE_ENTRY_FILE:
      return .file
    case LOCUS_WORKSPACE_ENTRY_SYMLINK:
      return .symlink
    case LOCUS_WORKSPACE_ENTRY_SYMLINK_DIRECTORY:
      return .symlinkToDirectory
    case LOCUS_WORKSPACE_ENTRY_SYMLINK_FILE:
      return .symlinkToFile
    case LOCUS_WORKSPACE_ENTRY_OTHER:
      return .other
    default:
      logger.error("Unknown workspace entry kind from Rust core: \(value)")
      assertionFailure("Unknown workspace entry kind: \(value)")
      return .other
    }
  }

  // FFI code mapping is intentionally a full switch over the C constants.
  // swiftlint:disable:next cyclomatic_complexity
  private static func workspaceFileType(_ value: LocusFileType) -> WorkspaceFileType {
    switch value {
    case LOCUS_FILE_TYPE_MARKDOWN:
      return .markdown
    case LOCUS_FILE_TYPE_STRUCTURED_TEXT:
      return .structuredText
    case LOCUS_FILE_TYPE_PDF:
      return .pdf
    case LOCUS_FILE_TYPE_OFFICE:
      return .office
    case LOCUS_FILE_TYPE_IMAGE:
      return .image
    case LOCUS_FILE_TYPE_AUDIO:
      return .audio
    case LOCUS_FILE_TYPE_VIDEO:
      return .video
    case LOCUS_FILE_TYPE_PLAIN_TEXT:
      return .plainText
    case LOCUS_FILE_TYPE_CODE:
      return .code
    case LOCUS_FILE_TYPE_UNKNOWN:
      return .unknown
    default:
      logger.error("Unknown workspace file type from Rust core: \(value)")
      assertionFailure("Unknown workspace file type: \(value)")
      return .unknown
    }
  }

  private static func workspaceErrorKind(_ value: LocusStatus) -> WorkspaceErrorKind {
    switch value {
    case LOCUS_STATUS_INVALID_ARGUMENT:
      return .invalidArgument
    case LOCUS_STATUS_NOT_FOUND:
      return .notFound
    case LOCUS_STATUS_NOT_DIRECTORY:
      return .notDirectory
    case LOCUS_STATUS_READ_DIRECTORY:
      return .readDirectory
    case LOCUS_STATUS_READ_ENTRY:
      return .readEntry
    case LOCUS_STATUS_READ_METADATA:
      return .readMetadata
    default:
      logger.error("Unknown workspace error status from Rust core: \(value)")
      assertionFailure("Unknown workspace error status: \(value)")
      return .unknown(value)
    }
  }

  private static func lastErrorMessage() -> String {
    guard let message = locus_last_error_message() else {
      return "Rust core error details are unavailable."
    }

    let text = String(cString: message)
    return text.isEmpty ? "Rust core error details are unavailable." : text
  }

  private static func isReadOnlyFile(at path: String, fallback: Bool) -> Bool {
    let url = URL(filePath: path)
    guard
      let resourceValues = try? url.resourceValues(
        forKeys: [.isWritableKey, .isUserImmutableKey, .isSystemImmutableKey]
      )
    else {
      return fallback
    }

    if resourceValues.isUserImmutable == true || resourceValues.isSystemImmutable == true {
      return true
    }

    return resourceValues.isWritable.map { !$0 } ?? fallback
  }
}

enum CoreBridgeError: LocalizedError, Equatable, Sendable {
  case incompatibleABI(expected: UInt32, actual: UInt32)
  case missingVersionString
  case missingWorkspaceSnapshot
  case workspaceListFailed(kind: WorkspaceErrorKind, message: String)

  var errorDescription: String? {
    switch self {
    case .incompatibleABI(let expected, let actual):
      return "Rust core ABI mismatch. Expected \(expected), got \(actual)."
    case .missingVersionString:
      return "Rust core version is unavailable."
    case .missingWorkspaceSnapshot:
      return "Rust core did not return a workspace snapshot."
    case .workspaceListFailed(_, let message):
      return message
    }
  }

  var failureReason: String? {
    switch self {
    case .workspaceListFailed(let kind, _):
      return "Rust core status: \(kind.statusCode)"
    default:
      return nil
    }
  }
}
