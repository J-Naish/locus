import Foundation
import OSLog

struct RecentFolder: Identifiable, Equatable, Sendable {
    let id: String
    let url: URL
    let displayName: String
    let path: String
    let lastOpenedAt: Date
}

struct RecentFolderStore {
    static let defaultMaxCount = 10

    private struct Record: Codable, Equatable {
        let bookmarkData: Data
        let displayName: String
        let path: String
        let lastOpenedAt: Date
    }

    private static let logger = Logger(subsystem: "Locus", category: "RecentFolderStore")

    private let userDefaults: UserDefaults
    private let key: String
    private let maxCount: Int
    private let now: () -> Date

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "recentFolders.v1",
        maxCount: Int = Self.defaultMaxCount,
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.key = key
        self.maxCount = max(1, maxCount)
        self.now = now
    }

    func recentFolders() -> [RecentFolder] {
        var shouldSave = false
        let resolved = records().compactMap { record -> (Record, RecentFolder)? in
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

            let resolvedRecord: Record
            if isStale, let refreshedRecord = makeRecord(for: url, openedAt: record.lastOpenedAt) {
                resolvedRecord = refreshedRecord
                shouldSave = true
            } else {
                resolvedRecord = record
            }

            return (
                resolvedRecord,
                RecentFolder(
                    id: resolvedRecord.path,
                    url: url,
                    displayName: resolvedRecord.displayName,
                    path: resolvedRecord.path,
                    lastOpenedAt: resolvedRecord.lastOpenedAt
                )
            )
        }

        if shouldSave {
            save(resolved.map(\.0))
        }

        return resolved.map(\.1)
    }

    @discardableResult
    func record(_ folderURL: URL) -> Bool {
        let standardizedURL = folderURL.standardizedFileURL
        guard let record = makeRecord(for: standardizedURL, openedAt: now()) else {
            return false
        }

        var updatedRecords = records().filter { $0.path != record.path }
        updatedRecords.insert(record, at: 0)
        save(Array(updatedRecords.prefix(maxCount)))
        return true
    }

    private func records() -> [Record] {
        guard let data = userDefaults.data(forKey: key) else {
            return []
        }

        do {
            return try PropertyListDecoder().decode([Record].self, from: data)
        } catch {
            Self.logger.error("Failed to decode recent folders: \(error.localizedDescription)")
            userDefaults.removeObject(forKey: key)
            return []
        }
    }

    private func save(_ records: [Record]) {
        do {
            userDefaults.set(try PropertyListEncoder().encode(records), forKey: key)
        } catch {
            Self.logger.error("Failed to encode recent folders: \(error.localizedDescription)")
        }
    }

    private func makeRecord(for url: URL, openedAt: Date) -> Record? {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.locusStandardizedPath

        do {
            // Locus is not sandboxed yet. Store plain bookmarks now and switch
            // to security-scoped bookmarks with entitlements in the sandboxing
            // milestone.
            return Record(
                bookmarkData: try standardizedURL.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ),
                displayName: standardizedURL.locusDisplayName,
                path: path,
                lastOpenedAt: openedAt
            )
        } catch {
            Self.logger.error("Failed to bookmark recent folder \(path): \(error.localizedDescription)")
            return nil
        }
    }

    private static func isExistingDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
