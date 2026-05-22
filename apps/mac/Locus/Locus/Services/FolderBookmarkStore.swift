import Foundation
import OSLog

struct StoredFolderBookmark: Codable, Equatable, Sendable {
    let bookmarkData: Data
    let displayName: String
    let path: String
    let timestamp: Date
}

struct ResolvedFolderBookmark: Equatable, Sendable {
    let url: URL
    let displayName: String
    let path: String
    let timestamp: Date
}

struct FolderBookmarkStore {
    enum DuplicatePolicy {
        case keepOriginalPosition
        case moveToFront
    }

    private let userDefaults: UserDefaults
    private let key: String
    private let maxCount: Int?
    private let logger: Logger

    init(
        userDefaults: UserDefaults = .standard,
        key: String,
        maxCount: Int? = nil,
        logCategory: String
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.maxCount = maxCount.map { max(1, $0) }
        self.logger = Logger(subsystem: "Locus", category: logCategory)
    }

    // Resolves bookmarks and reconciles persisted state by pruning missing
    // folders and refreshing stale bookmark data.
    func resolvedFolders() -> [ResolvedFolderBookmark] {
        var shouldSave = false
        let resolved = records().compactMap { record -> (StoredFolderBookmark, ResolvedFolderBookmark)? in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: record.bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                shouldSave = true
                return nil
            }

            guard Self.isExistingDirectory(url) else {
                shouldSave = true
                return nil
            }

            let resolvedRecord: StoredFolderBookmark
            if isStale, let refreshedRecord = makeRecord(for: url, timestamp: record.timestamp) {
                resolvedRecord = refreshedRecord
                shouldSave = true
            } else {
                resolvedRecord = record
            }

            return (
                resolvedRecord,
                ResolvedFolderBookmark(
                    url: url,
                    displayName: resolvedRecord.displayName,
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

    func contains(_ folderURL: URL) -> Bool {
        let path = folderURL.locusStandardizedPath
        return records().contains { $0.path == path }
    }

    @discardableResult
    func insert(_ folderURL: URL, timestamp: Date, duplicatePolicy: DuplicatePolicy) -> Bool {
        let standardizedURL = folderURL.standardizedFileURL
        let path = standardizedURL.locusStandardizedPath
        var existingRecords = records()
        let existingIndex = existingRecords.firstIndex { $0.path == path }

        if duplicatePolicy == .keepOriginalPosition, existingIndex != nil {
            return true
        }

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

    func remove(_ folderURL: URL) {
        let path = folderURL.locusStandardizedPath
        save(records().filter { $0.path != path })
    }

    private func records() -> [StoredFolderBookmark] {
        guard let data = userDefaults.data(forKey: key) else {
            return []
        }

        do {
            return try PropertyListDecoder().decode([StoredFolderBookmark].self, from: data)
        } catch {
            logger.error("Failed to decode folder bookmarks for \(key): \(error.localizedDescription)")
            userDefaults.removeObject(forKey: key)
            return []
        }
    }

    private func save(_ records: [StoredFolderBookmark]) {
        do {
            userDefaults.set(try PropertyListEncoder().encode(records), forKey: key)
        } catch {
            logger.error("Failed to encode folder bookmarks for \(key): \(error.localizedDescription)")
        }
    }

    private func makeRecord(for url: URL, timestamp: Date) -> StoredFolderBookmark? {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.locusStandardizedPath

        do {
            // Locus is not sandboxed yet. Store plain bookmarks now and switch
            // to security-scoped bookmarks with entitlements in the sandboxing
            // milestone.
            return StoredFolderBookmark(
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
            logger.error("Failed to bookmark folder \(path): \(error.localizedDescription)")
            return nil
        }
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
