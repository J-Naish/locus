import SwiftUI

@main
struct LocusApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView(initialFolderURL: Self.initialFolderURL)
        }
        .windowResizability(.contentMinSize)
    }

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

    private static func uiTestWorkspacePath(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--ui-test-workspace=") {
                return String(argument.dropFirst("--ui-test-workspace=".count))
            }

            guard argument == "--ui-test-workspace" else {
                continue
            }

            let pathIndex = arguments.index(after: index)
            guard arguments.indices.contains(pathIndex) else {
                return nil
            }

            return arguments[pathIndex]
        }

        return nil
    }
}
