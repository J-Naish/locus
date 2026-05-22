import SwiftUI

@main
struct LocusApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView(
                finderService: Self.finderService,
                quickLookPreviewService: Self.quickLookPreviewService,
                favoriteFolderStore: Self.favoriteFolderStore,
                recentFileStore: Self.recentFileStore,
                recentFolderStore: Self.recentFolderStore,
                initialFolderURL: Self.initialFolderURL
            )
        }
        .windowResizability(.contentMinSize)
    }

    private static let finderService: any FinderServicing = {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
            return FinderService()
        }

        return UITestFinderService(
            revealInvocationsKey: uiTestRevealInvocationsKey,
            revealInvocationsFileURL: uiTestRevealInvocationsFileURL
        )
        #else
        return FinderService()
        #endif
    }()

    private static let quickLookPreviewService: any QuickLookPreviewing = {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
            return QuickLookPreviewService()
        }

        return UITestQuickLookPreviewService(
            key: uiTestPreviewInvocationsKey,
            fileURL: uiTestPreviewInvocationsFileURL
        )
        #else
        return QuickLookPreviewService()
        #endif
    }()

    private static let favoriteFolderStore: FavoriteFolderStore = {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
            return FavoriteFolderStore()
        }

        let store = FavoriteFolderStore(key: uiTestFavoriteFoldersKey)
        for path in argumentValues(named: "--ui-test-favorite-folder", in: ProcessInfo.processInfo.arguments) {
            guard !path.isEmpty else {
                continue
            }

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                store.add(URL(filePath: path, directoryHint: .isDirectory))
            }
        }
        return store
        #else
        return FavoriteFolderStore()
        #endif
    }()

    private static let recentFolderStore: RecentFolderStore = {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
            return RecentFolderStore()
        }

        let store = RecentFolderStore(key: uiTestRecentFoldersKey)
        for path in argumentValues(named: "--ui-test-recent-folder", in: ProcessInfo.processInfo.arguments) {
            guard !path.isEmpty else {
                continue
            }

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                store.record(URL(filePath: path, directoryHint: .isDirectory))
            }
        }
        return store
        #else
        return RecentFolderStore()
        #endif
    }()

    private static let recentFileStore: RecentFileStore = {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
            return RecentFileStore()
        }

        let store = RecentFileStore(key: uiTestRecentFilesKey)
        for path in argumentValues(named: "--ui-test-recent-file", in: ProcessInfo.processInfo.arguments) {
            guard !path.isEmpty else {
                continue
            }

            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                store.record(URL(filePath: path, directoryHint: .notDirectory))
            }
        }
        return store
        #else
        return RecentFileStore()
        #endif
    }()

    private static var initialFolderURL: URL? {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
            return nil
        }

        let arguments = ProcessInfo.processInfo.arguments
        guard let path = uiTestWorkspacePath(in: arguments), !path.isEmpty else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        return URL(filePath: path, directoryHint: .isDirectory)
        #else
        return nil
        #endif
    }

    private static var uiTestFavoriteFoldersKey: String {
        argumentValue(named: "--ui-test-favorite-folders-key", in: ProcessInfo.processInfo.arguments)
            ?? "favoriteFolders.uiTests"
    }

    private static var uiTestRecentFoldersKey: String {
        argumentValue(named: "--ui-test-recent-folders-key", in: ProcessInfo.processInfo.arguments)
            ?? "recentFolders.uiTests"
    }

    private static var uiTestRecentFilesKey: String {
        argumentValue(named: "--ui-test-recent-files-key", in: ProcessInfo.processInfo.arguments)
            ?? "recentFiles.uiTests"
    }

    private static var uiTestPreviewInvocationsKey: String {
        argumentValue(named: "--ui-test-preview-invocations-key", in: ProcessInfo.processInfo.arguments)
            ?? "previewInvocations.uiTests"
    }

    private static var uiTestPreviewInvocationsFileURL: URL? {
        guard let path = argumentValue(named: "--ui-test-preview-invocations-file", in: ProcessInfo.processInfo.arguments),
              !path.isEmpty else {
            return nil
        }

        return URL(filePath: path, directoryHint: .notDirectory)
    }

    private static var uiTestRevealInvocationsKey: String {
        argumentValue(named: "--ui-test-reveal-invocations-key", in: ProcessInfo.processInfo.arguments)
            ?? "revealInvocations.uiTests"
    }

    private static var uiTestRevealInvocationsFileURL: URL? {
        guard let path = argumentValue(named: "--ui-test-reveal-invocations-file", in: ProcessInfo.processInfo.arguments),
              !path.isEmpty else {
            return nil
        }

        return URL(filePath: path, directoryHint: .notDirectory)
    }

    private static func uiTestWorkspacePath(in arguments: [String]) -> String? {
        argumentValue(named: "--ui-test-workspace", in: arguments)
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        argumentValues(named: name, in: arguments).first
    }

    private static func argumentValues(named name: String, in arguments: [String]) -> [String] {
        var values: [String] = []
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("\(name)=") {
                values.append(String(argument.dropFirst("\(name)=".count)))
                continue
            }

            guard argument == name else {
                continue
            }

            let pathIndex = arguments.index(after: index)
            guard arguments.indices.contains(pathIndex) else {
                continue
            }

            values.append(arguments[pathIndex])
        }

        return values
    }
}
