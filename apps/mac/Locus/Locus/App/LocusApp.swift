import AppKit
import SwiftUI

enum LocusWindowMetrics {
  // Default to a comfortable two-pane workspace without making that size mandatory.
  static let defaultWidth: CGFloat = 1184
  static let defaultHeight: CGFloat = 760
  static let splitViewChromeWidth: CGFloat = 16

  // Keep the file browser close to a compact native outline by default, while
  // allowing the divider to expand for deep folders and unusually long names.
  static let fileListSidebarMinimumWidth: CGFloat = 160
  static let fileListSidebarIdealWidth: CGFloat = 184
  static let documentSurfaceMinimumWidth: CGFloat = 320
  static let documentSurfaceIdealWidth: CGFloat = 464

  // At the default window width, this leaves the document surface at its own
  // minimum. Wider windows can make both panes generous at the same time.
  static let fileListSidebarMaximumWidth: CGFloat =
    defaultWidth - documentSurfaceMinimumWidth - splitViewChromeWidth

  // Keep the window minimum at the split-view layout floor: both panes at their
  // own minimums, plus room for the divider and standard split-view chrome.
  static let minimumWidth: CGFloat =
    fileListSidebarMinimumWidth + documentSurfaceMinimumWidth + splitViewChromeWidth
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

struct WorkspaceDeletionCommand {
  let canDelete: Bool
  let delete: () -> Void
}

struct WorkspaceSidebarVisibilityCommand {
  let toggle: () -> Void
}

enum LocusPersistedDefaults {
  static let recentFoldersExpanded = "workspace.sidebar.recentFoldersExpanded"
  static let uiTestResetKeys = [
    recentFoldersExpanded
  ]
}

private struct WorkspaceNavigationCommandsKey: FocusedValueKey {
  typealias Value = WorkspaceNavigationCommands
}

private struct DocumentSaveCommandKey: FocusedValueKey {
  typealias Value = DocumentSaveCommand
}

private struct WorkspaceDeletionCommandKey: FocusedValueKey {
  typealias Value = WorkspaceDeletionCommand
}

private struct WorkspaceSidebarVisibilityCommandKey: FocusedValueKey {
  typealias Value = WorkspaceSidebarVisibilityCommand
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

  var workspaceDeletionCommand: WorkspaceDeletionCommand? {
    get { self[WorkspaceDeletionCommandKey.self] }
    set { self[WorkspaceDeletionCommandKey.self] = newValue }
  }

  var workspaceSidebarVisibilityCommand: WorkspaceSidebarVisibilityCommand? {
    get { self[WorkspaceSidebarVisibilityCommandKey.self] }
    set { self[WorkspaceSidebarVisibilityCommandKey.self] = newValue }
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

private struct WorkspaceDeletionCommandMenu: Commands {
  @FocusedValue(\.workspaceDeletionCommand) private var deletionCommand

  var body: some Commands {
    CommandGroup(after: .pasteboard) {
      Button("Delete") {
        deletionCommand?.delete()
      }
      .keyboardShortcut(.delete, modifiers: [.command])
      .disabled(deletionCommand?.canDelete != true)
    }
  }
}

private struct WorkspaceSidebarVisibilityCommandMenu: Commands {
  @FocusedValue(\.workspaceSidebarVisibilityCommand) private var sidebarCommand

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Toggle Sidebar") {
        sidebarCommand?.toggle()
      }
      .keyboardShortcut("b", modifiers: [.command])
      .disabled(sidebarCommand == nil)
    }
  }
}

@MainActor
enum LocusUnsavedChangesPrompt {
  static func confirmDiscardForWindowClose() -> Bool {
    confirmDiscard(
      messageText: "Close Window with Unsaved Edits?",
      informativeText: "This window has unsaved edits. Closing it will discard them.",
      discardTitle: "Discard Changes"
    )
  }

  static func confirmDiscardForApplicationTermination() -> Bool {
    confirmDiscard(
      messageText: "Quit Locus with Unsaved Edits?",
      informativeText: "One or more windows have unsaved edits. Quitting will discard them.",
      discardTitle: "Discard and Quit"
    )
  }

  private static func confirmDiscard(
    messageText: String,
    informativeText: String,
    discardTitle: String
  ) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = messageText
    alert.informativeText = informativeText
    alert.addButton(withTitle: "Cancel")
    alert.addButton(withTitle: discardTitle)
    return alert.runModal() == .alertSecondButtonReturn
  }
}

@MainActor
final class LocusApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard sender.windows.contains(where: \.isDocumentEdited) else {
      return .terminateNow
    }
    return LocusUnsavedChangesPrompt.confirmDiscardForApplicationTermination()
      ? .terminateNow : .terminateCancel
  }
}

struct WindowUnsavedChangesGuard: NSViewRepresentable {
  let hasUnsavedChanges: Bool

  func makeNSView(context: Context) -> TrackingView {
    let view = TrackingView()
    view.coordinator = context.coordinator
    view.isHidden = true
    return view
  }

  func updateNSView(_ nsView: TrackingView, context: Context) {
    context.coordinator.hasUnsavedChanges = hasUnsavedChanges
    if let window = nsView.window {
      context.coordinator.attach(to: window)
    }
  }

  static func dismantleNSView(_ nsView: TrackingView, coordinator: Coordinator) {
    coordinator.detach()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class TrackingView: NSView {
    weak var coordinator: Coordinator?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if let window {
        coordinator?.attach(to: window)
      } else {
        coordinator?.detach()
      }
    }
  }

  @MainActor
  final class Coordinator: NSObject, NSWindowDelegate {
    var hasUnsavedChanges = false {
      didSet { updateEditedState() }
    }

    private weak var window: NSWindow?
    private weak var previousDelegate: NSWindowDelegate?

    func attach(to newWindow: NSWindow) {
      guard window !== newWindow else {
        updateEditedState()
        return
      }

      detach()
      previousDelegate = newWindow.delegate
      window = newWindow
      newWindow.delegate = self
      updateEditedState()
    }

    func detach() {
      if let window, window.delegate === self {
        window.isDocumentEdited = false
        window.delegate = previousDelegate
      }
      window = nil
      previousDelegate = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      if !hasUnsavedChanges {
        return previousDelegate?.windowShouldClose?(sender) ?? true
      }
      guard LocusUnsavedChangesPrompt.confirmDiscardForWindowClose() else {
        return false
      }
      return previousDelegate?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
      previousDelegate?.windowWillClose?(notification)
      detach()
    }

    private func updateEditedState() {
      window?.isDocumentEdited = hasUnsavedChanges
    }
  }
}

@main
struct LocusApp: App {
  @NSApplicationDelegateAdaptor(LocusApplicationDelegate.self) private var appDelegate

  init() {
    Self.resetUITestUserDefaultsIfNeeded()
    // Light is the product's default appearance for now. LocusChromeColors
    // keeps dark variants so a future appearance setting only removes this.
    // Set here, before the first scene materializes: an application-delegate
    // launch hook raced scene bringup and occasionally launched dark.
    NSApplication.shared.appearance = NSAppearance(named: .aqua)
  }

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
      WorkspaceDeletionCommandMenu()
      WorkspaceSidebarVisibilityCommandMenu()
      WorkspaceNavigationCommandMenu()
    }
  }

  @MainActor private static let recentFolderStore: RecentFolderStore = {
    #if DEBUG
      guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
        return RecentFolderStore()
      }

      let store = RecentFolderStore(key: uiTestRecentFoldersKey)
      for path in LaunchArgumentValues.values(
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

  @MainActor private static let recentFileStore: RecentFileStore = {
    #if DEBUG
      guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
        return RecentFileStore()
      }

      let store = RecentFileStore(key: uiTestRecentFilesKey)
      for path in LaunchArgumentValues.values(
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
    LaunchArgumentValues.value(
      named: "--ui-test-recent-folders-key", in: ProcessInfo.processInfo.arguments)
      ?? "recentFolders.uiTests"
  }

  private static var uiTestRecentFilesKey: String {
    LaunchArgumentValues.value(
      named: "--ui-test-recent-files-key", in: ProcessInfo.processInfo.arguments)
      ?? "recentFiles.uiTests"
  }

  private static func resetUITestUserDefaultsIfNeeded() {
    #if DEBUG
      guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1" else {
        return
      }

      for key in LocusPersistedDefaults.uiTestResetKeys {
        UserDefaults.standard.removeObject(forKey: key)
      }
    #endif
  }
}
