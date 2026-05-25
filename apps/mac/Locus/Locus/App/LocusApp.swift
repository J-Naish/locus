import SwiftUI

enum LocusWindowMetrics {
  // Default to a comfortable two-pane workspace without making that size mandatory.
  static let defaultWidth: CGFloat = 1180
  static let defaultHeight: CGFloat = 760

  // Keep the file browser close to a compact native outline by default, while
  // allowing the divider to expand for deep folders and unusually long names.
  static let fileListSidebarMinimumWidth: CGFloat = 170
  static let fileListSidebarIdealWidth: CGFloat = 180
  // At the default window width, this leaves the document surface at its own
  // minimum. Wider windows can make both panes generous at the same time.
  static let fileListSidebarMaximumWidth: CGFloat = 840
  static let documentSurfaceMinimumWidth: CGFloat = 340
  static let documentSurfaceIdealWidth: CGFloat = 460

  // Keep the window minimum at the split-view layout floor: both panes at their
  // own minimums, plus room for the divider and standard split-view chrome.
  static let minimumWidth: CGFloat =
    fileListSidebarMinimumWidth + documentSurfaceMinimumWidth + 20
  static let minimumHeight: CGFloat = 600
}

struct WorkspaceNavigationCommands {
  let canGoBack: Bool
  let canGoForward: Bool
  let goBack: () -> Void
  let goForward: () -> Void
}

struct DocumentSaveCommand {
  let canSave: Bool
  let save: () -> Void
}

private struct WorkspaceNavigationCommandsKey: FocusedValueKey {
  typealias Value = WorkspaceNavigationCommands
}

private struct DocumentSaveCommandKey: FocusedValueKey {
  typealias Value = DocumentSaveCommand
}

extension FocusedValues {
  var workspaceNavigationCommands: WorkspaceNavigationCommands? {
    get { self[WorkspaceNavigationCommandsKey.self] }
    set { self[WorkspaceNavigationCommandsKey.self] = newValue }
  }

  var documentSaveCommand: DocumentSaveCommand? {
    get { self[DocumentSaveCommandKey.self] }
    set { self[DocumentSaveCommandKey.self] = newValue }
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

private struct DocumentSaveCommandMenu: Commands {
  @FocusedValue(\.documentSaveCommand) private var saveCommand

  var body: some Commands {
    CommandGroup(replacing: .saveItem) {
      Button("Save") {
        saveCommand?.save()
      }
      .keyboardShortcut("s", modifiers: [.command])
      .disabled(saveCommand?.canSave != true)
    }
  }
}

@main
struct LocusApp: App {
  var body: some Scene {
    WindowGroup {
      HomeView(
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
      DocumentSaveCommandMenu()
      WorkspaceNavigationCommandMenu()
    }
  }

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
