import AppKit
import SwiftUI

enum WorkspaceFolderOpenRequestNotification {
  static let name = Notification.Name("LocusWorkspaceFolderOpenRequest")
  static let folderURLKey = "folderURL"
  static let requestIDKey = "requestID"
}

struct WorkspaceFolderOpenRequest: Identifiable, Equatable {
  let id: UUID
  let folderURL: URL
}

@MainActor
final class WorkspaceFolderOpenRequestCenter {
  static let shared = WorkspaceFolderOpenRequestCenter()

  private var pendingRequests: [WorkspaceFolderOpenRequest] = []

  func requestOpen(_ folderURL: URL, postsNotification: Bool = true) {
    let request = WorkspaceFolderOpenRequest(
      id: UUID(),
      folderURL: folderURL.standardizedFileURL
    )
    pendingRequests.append(request)
    guard postsNotification else {
      return
    }

    NotificationCenter.default.post(
      name: WorkspaceFolderOpenRequestNotification.name,
      object: self,
      userInfo: [
        WorkspaceFolderOpenRequestNotification.requestIDKey: request.id,
        WorkspaceFolderOpenRequestNotification.folderURLKey: request.folderURL,
      ]
    )
  }

  func consumeRequest(id: UUID) -> WorkspaceFolderOpenRequest? {
    guard let index = pendingRequests.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    return pendingRequests.remove(at: index)
  }

  func consumePendingRequests() -> [WorkspaceFolderOpenRequest] {
    defer { pendingRequests.removeAll() }
    return pendingRequests
  }
}

@MainActor
enum WorkspaceRecentDocumentRegistration {
  static func register(_ folderURL: URL) {
    #if DEBUG
      guard ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] != "1" else {
        return
      }
    #endif

    NSDocumentController.shared.noteNewRecentDocumentURL(folderURL.standardizedFileURL)
  }

  static func synchronize(_ recentFolders: [RecentFolder]) {
    for url in registrationOrder(for: recentFolders) {
      register(url)
    }
  }

  static func registrationOrder(for recentFolders: [RecentFolder]) -> [URL] {
    recentFolders.reversed().map(\.url)
  }
}

enum WorkspaceOpenFileResolution {
  static func firstFolderURL(in filenames: [String]) -> URL? {
    filenames
      .map { URL(filePath: $0, directoryHint: .isDirectory).standardizedFileURL }
      .first(where: isExistingDirectory(_:))
  }

  static func isExistingDirectory(_ folderURL: URL) -> Bool {
    let path = folderURL.path(percentEncoded: false)
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}

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

struct DocumentCloseCommand {
  let canClose: Bool
  let close: () -> Void
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
  static let textEditingAutoSaveEnabled = "workspace.textEditing.autoSaveEnabled"
  static let uiTestResetKeys = [
    recentFoldersExpanded,
    textEditingAutoSaveEnabled,
  ]
}

private struct WorkspaceNavigationCommandsKey: FocusedValueKey {
  typealias Value = WorkspaceNavigationCommands
}

private struct DocumentSaveCommandKey: FocusedValueKey {
  typealias Value = DocumentSaveCommand
}

private struct DocumentCloseCommandKey: FocusedValueKey {
  typealias Value = DocumentCloseCommand
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

  var documentCloseCommand: DocumentCloseCommand? {
    get { self[DocumentCloseCommandKey.self] }
    set { self[DocumentCloseCommandKey.self] = newValue }
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
  @AppStorage(LocusPersistedDefaults.textEditingAutoSaveEnabled)
  private var isAutoSaveEnabled = true

  var body: some Commands {
    CommandGroup(replacing: .saveItem) {
      Button("Save") {
        saveCommand?.save()
      }
      .keyboardShortcut("s", modifiers: [.command])
      .disabled(saveCommand?.canSave != true)

      Divider()

      Toggle("Auto Save", isOn: $isAutoSaveEnabled)
    }
  }
}

private struct DocumentCloseCommandMenu: Commands {
  @FocusedValue(\.documentCloseCommand) private var closeCommand

  var body: some Commands {
    CommandGroup(after: .newItem) {
      Button(closeCommand?.canClose == true ? "Close File" : "Close Window") {
        if closeCommand?.canClose == true {
          closeCommand?.close()
        } else {
          NSApp.keyWindow?.performClose(nil)
        }
      }
      .keyboardShortcut("w", modifiers: [.command])
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
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Re-assert the active theme's appearance set in LocusApp.init: that early
    // write alone occasionally lost a launch race and the first window came up
    // in the system appearance. (The SwiftUI-level .preferredColorScheme pin
    // is not an option — it detaches the sidebar panel from the titlebar.)
    NSApp.appearance = LocusChromeColors.activeAppearance
    WorkspaceRecentDocumentRegistration.synchronize(recentFoldersForOpenRecent())
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard sender.windows.contains(where: \.isDocumentEdited) else {
      return .terminateNow
    }
    return LocusUnsavedChangesPrompt.confirmDiscardForApplicationTermination()
      ? .terminateNow : .terminateCancel
  }

  func application(_ sender: NSApplication, openFile filename: String) -> Bool {
    requestOpenFolderIfPossible(URL(filePath: filename, directoryHint: .isDirectory))
  }

  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    guard let folderURL = WorkspaceOpenFileResolution.firstFolderURL(in: filenames) else {
      sender.reply(toOpenOrPrint: .failure)
      return
    }

    sender.reply(toOpenOrPrint: requestOpenFolderIfPossible(folderURL) ? .success : .failure)
  }

  private func recentFoldersForOpenRecent() -> [RecentFolder] {
    LocusApp.recentFolderStore.recentFolders().filter { folder in
      !WorkspaceHomeVisibility.isHiddenHomeURL(
        folder.url,
        homeDirectoryURL: LocusApp.homeDirectoryURL
      )
    }
  }

  private func requestOpenFolderIfPossible(_ folderURL: URL) -> Bool {
    guard WorkspaceOpenFileResolution.isExistingDirectory(folderURL) else {
      return false
    }

    NSApp.activate(ignoringOtherApps: true)
    WorkspaceFolderOpenRequestCenter.shared.requestOpen(folderURL)
    return true
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
    // Pin the app to the active theme's appearance (Light by default). Set
    // here, before the first scene materializes: an application-delegate launch
    // hook raced scene bringup and occasionally launched in the system
    // appearance.
    NSApplication.shared.appearance = LocusChromeColors.activeAppearance
  }

  var body: some Scene {
    WindowGroup {
      HomeView(
        recentFileStore: Self.recentFileStore,
        recentFolderStore: Self.recentFolderStore,
        initialFolderResolution: Self.initialFolderResolution,
        homeDirectoryURL: Self.homeDirectoryURL
      )
      // Light is pinned at the AppKit level only (see init and the app
      // delegate): .preferredColorScheme(.light) here detached the sidebar
      // panel from the titlebar, floating the traffic lights and the sidebar
      // toggle above it.
    }
    // Unified (not unifiedCompact): the compact style floats the sidebar
    // panel below the titlebar, detaching the traffic lights and the sidebar
    // toggle from the sidebar surface. Unified extends the panel to the
    // window top, at the cost of a taller header band.
    .windowToolbarStyle(.unified(showsTitle: false))
    .windowResizability(.contentMinSize)
    .defaultSize(
      width: LocusWindowMetrics.defaultWidth,
      height: LocusWindowMetrics.defaultHeight
    )
    .commands {
      DocumentCloseCommandMenu()
      DocumentSaveCommandMenu()
      WorkspaceDeletionCommandMenu()
      WorkspaceSidebarVisibilityCommandMenu()
      WorkspaceNavigationCommandMenu()
    }
  }

  @MainActor fileprivate static let recentFolderStore: RecentFolderStore = {
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

  fileprivate static let homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

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
