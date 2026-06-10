import Foundation
import OSLog

struct StoredFileLocationBookmark: Codable, Equatable, Sendable {
  let bookmarkData: Data
  let displayName: String
  let path: String
  let timestamp: Date
}

struct ResolvedFileLocationBookmark: Equatable, Sendable {
  let url: URL
  let displayName: String
  let path: String
  let timestamp: Date
}

/// Main-actor isolated: every mutation is a read-modify-write of the same
/// UserDefaults key, so two concurrent writers could lose entries. All callers
/// are UI-driven today; the isolation turns that assumption into a
/// compiler-checked invariant. The init stays `nonisolated` (it only stores
/// Sendable configuration) so stores can be built anywhere.
@MainActor
struct FileLocationBookmarkStore {
  enum RequiredResource {
    case directory
    case regularFile
  }

  // UserDefaults is documented thread-safe per call but the SDK does not mark
  // it Sendable, which would forbid the `nonisolated init` from storing it.
  // The opt-out is sound: the reference is immutable, each raw access is
  // thread-safe, and the read-modify-write sequences around it run on the main
  // actor — which is the invariant this type's isolation exists to protect.
  nonisolated(unsafe) private let userDefaults: UserDefaults
  private let key: String
  private let maxCount: Int?
  private let requiredResource: RequiredResource
  private let logger: Logger

  nonisolated init(
    userDefaults: UserDefaults = .standard,
    key: String,
    maxCount: Int? = nil,
    requiredResource: RequiredResource,
    logCategory: String
  ) {
    self.userDefaults = userDefaults
    self.key = key
    self.maxCount = maxCount.map { max(1, $0) }
    self.requiredResource = requiredResource
    self.logger = Logger(subsystem: "Locus", category: logCategory)
  }

  // Resolves bookmarks and reconciles persisted state by pruning missing
  // locations and refreshing stale bookmark data.
  func resolvedLocations() -> [ResolvedFileLocationBookmark] {
    var shouldSave = false
    let resolved = records().compactMap {
      record -> (StoredFileLocationBookmark, ResolvedFileLocationBookmark)? in
      var isStale = false
      guard
        let url = try? URL(
          resolvingBookmarkData: record.bookmarkData,
          options: [],
          relativeTo: nil,
          bookmarkDataIsStale: &isStale
        )
      else {
        shouldSave = true
        return nil
      }

      guard isExistingRequiredResource(url) else {
        shouldSave = true
        return nil
      }

      let resolvedRecord: StoredFileLocationBookmark
      if isStale, let refreshedRecord = makeRecord(for: url, timestamp: record.timestamp) {
        resolvedRecord = refreshedRecord
        shouldSave = true
      } else {
        resolvedRecord = record
      }

      return (
        resolvedRecord,
        ResolvedFileLocationBookmark(
          url: url,
          displayName: url.locusDisplayName,
          path: resolvedRecord.path,
          timestamp: resolvedRecord.timestamp
        )
      )
    }

    if shouldSave {
      save(resolved.map(\.0))
    }

    return resolved.map(\.1)
  }

  func contains(_ url: URL) -> Bool {
    let path = url.locusStandardizedPath
    return records().contains { $0.path == path }
  }

  /// Inserts (or refreshes) a bookmark at the front of the list. A URL already
  /// present is moved to the front so the most recently used location leads.
  @discardableResult
  func insert(_ url: URL, timestamp: Date) -> Bool {
    let standardizedURL = url.standardizedFileURL
    guard isExistingRequiredResource(standardizedURL) else {
      return false
    }

    let path = standardizedURL.locusStandardizedPath
    var existingRecords = records()
    let existingIndex = existingRecords.firstIndex { $0.path == path }

    guard let record = makeRecord(for: standardizedURL, timestamp: timestamp) else {
      return false
    }

    if let existingIndex {
      existingRecords.remove(at: existingIndex)
    }
    existingRecords.insert(record, at: 0)

    if let maxCount {
      save(Array(existingRecords.prefix(maxCount)))
    } else {
      save(existingRecords)
    }

    return true
  }

  func remove(_ url: URL) {
    let path = url.locusStandardizedPath
    save(records().filter { $0.path != path })
  }

  private func records() -> [StoredFileLocationBookmark] {
    guard let data = userDefaults.data(forKey: key) else {
      return []
    }

    do {
      return try PropertyListDecoder().decode([StoredFileLocationBookmark].self, from: data)
    } catch {
      logger.error(
        "Failed to decode file location bookmarks for \(key): \(error.localizedDescription)")
      userDefaults.removeObject(forKey: key)
      return []
    }
  }

  private func save(_ records: [StoredFileLocationBookmark]) {
    do {
      userDefaults.set(try PropertyListEncoder().encode(records), forKey: key)
    } catch {
      logger.error(
        "Failed to encode file location bookmarks for \(key): \(error.localizedDescription)")
    }
  }

  private func makeRecord(for url: URL, timestamp: Date) -> StoredFileLocationBookmark? {
    let standardizedURL = url.standardizedFileURL
    let path = standardizedURL.locusStandardizedPath

    do {
      // Locus is not sandboxed yet. Store plain bookmarks now and switch
      // to security-scoped bookmarks with entitlements in the sandboxing
      // milestone.
      return StoredFileLocationBookmark(
        bookmarkData: try standardizedURL.bookmarkData(
          options: [],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        ),
        displayName: standardizedURL.locusDisplayName,
        path: path,
        timestamp: timestamp
      )
    } catch {
      logger.error("Failed to bookmark file location \(path): \(error.localizedDescription)")
      return nil
    }
  }

  private func isExistingRequiredResource(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(
      atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
    guard exists else {
      return false
    }

    switch requiredResource {
    case .directory:
      return isDirectory.boolValue
    case .regularFile:
      return !isDirectory.boolValue
    }
  }
}
