import SwiftUI

enum LocusWindowMetrics {
  // Default to a comfortable two-pane workspace without making that size mandatory.
  static let defaultWidth: CGFloat = 1180
  static let defaultHeight: CGFloat = 760

  // Keep the minimum near the actual split-view layout floor so users can still
  // place Locus beside Finder, Preview, or a browser on smaller displays.
  static let minimumWidth: CGFloat = 900
  static let minimumHeight: CGFloat = 600

  // Keep the file browser close to a compact editor sidebar by default, while
  // still allowing the divider to expand for unusually long names.
  static let fileListSidebarMinimumWidth: CGFloat = 170
  static let fileListSidebarIdealWidth: CGFloat = 180
  static let fileListSidebarMaximumWidth: CGFloat = 420
}

struct WorkspaceNavigationCommands {
  let canGoBack: Bool
  let canGoForward: Bool
  let goBack: () -> Void
  let goForward: () -> Void
}

private struct WorkspaceNavigationCommandsKey: FocusedValueKey {
  typealias Value = WorkspaceNavigationCommands
}

extension FocusedValues {
  var workspaceNavigationCommands: WorkspaceNavigationCommands? {
    get { self[WorkspaceNavigationCommandsKey.self] }
    set { self[WorkspaceNavigationCommandsKey.self] = newValue }
  }
}

private struct WorkspaceNavigationCommandMenu: Commands {
  @FocusedValue(\.workspaceNavigationCommands) private var navigationCommands

  var body: some Commands {
    CommandMenu("Navigate") {
      Button("Go Back") {
        navigationCommands?.goBack()
      }
      .keyboardShortcut("[", modifiers: [.command])
      .disabled(navigationCommands?.canGoBack != true)

      Button("Go Forward") {
        navigationCommands?.goForward()
      }
      .keyboardShortcut("]", modifiers: [.command])
      .disabled(navigationCommands?.canGoForward != true)
    }
  }
}

@main
struct LocusApp: App {
  var body: some Scene {
    WindowGroup {
      HomeView(
        quickLookPreviewService: Self.quickLookPreviewService,
        recentFileStore: Self.recentFileStore,
        recentFolderStore: Self.recentFolderStore,
        initialFolderResolution: Self.initialFolderResolution,
        homeDirectoryURL: Self.homeDirectoryURL
      )
    }
    .windowToolbarStyle(.unified(showsTitle: false))
    .windowResizability(.contentMinSize)
    .defaultSize(
      width: LocusWindowMetrics.defaultWidth,
      height: LocusWindowMetrics.defaultHeight
    )
    .commands {
      WorkspaceNavigationCommandMenu()
    }
  }

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

  private static let recentFolderStore: RecentFolderStore = {
    #if DEBUG
      guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
        return RecentFolderStore()
      }

      let store = RecentFolderStore(key: uiTestRecentFoldersKey)
      for path in argumentValues(
        named: "--ui-test-recent-folder", in: ProcessInfo.processInfo.arguments)
      {
        guard !path.isEmpty else {
          continue
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue
        {
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
      for path in argumentValues(
        named: "--ui-test-recent-file", in: ProcessInfo.processInfo.arguments)
      {
        guard !path.isEmpty else {
          continue
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          !isDirectory.boolValue
        {
          store.record(URL(filePath: path, directoryHint: .notDirectory))
        }
      }
      return store
    #else
      return RecentFileStore()
    #endif
  }()

  private static var initialFolderResolution: InitialFolderResolution {
    InitialFolderURLResolver.resolution(homeDirectoryURL: homeDirectoryURL)
  }

  private static let homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

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
    guard
      let path = argumentValue(
        named: "--ui-test-preview-invocations-file", in: ProcessInfo.processInfo.arguments),
      !path.isEmpty
    else {
      return nil
    }

    return URL(filePath: path, directoryHint: .notDirectory)
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
