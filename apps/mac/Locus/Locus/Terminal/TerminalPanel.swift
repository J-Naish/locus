import AppKit
import SwiftUI

enum TerminalPanelMetrics {
  static let defaultHeight: CGFloat = 240
  static let resizeHandleHeight: CGFloat = 8
  static let maximumParentHeightFraction: CGFloat = 0.8
  static let findDebounce: Duration = .milliseconds(250)
  static let findFieldWidth: CGFloat = 180

  static var minimumHeight: CGFloat {
    let metrics = TerminalCellMetrics()
    let insets = TerminalPaneLayoutMetrics.contentInsets
    return metrics.cellHeight * 3 + insets.top + insets.bottom
  }

  static func clampedHeight(_ proposedHeight: CGFloat, parentHeight: CGFloat) -> CGFloat {
    let minimumHeight = minimumHeight
    let maximumHeight = max(minimumHeight, parentHeight * maximumParentHeightFraction)
    return min(max(proposedHeight, minimumHeight), maximumHeight)
  }
}

@MainActor
final class TerminalPanelState: ObservableObject {
  @Published private(set) var isVisible = false
  @Published private(set) var isFindBarVisible = false
  @Published private(set) var findQuery = ""
  @Published private(set) var session: TerminalSession?
  @Published private(set) var panelHeight: CGFloat
  var currentWorkspaceFolder: URL?

  @AppStorage(LocusPersistedDefaults.terminalPanelHeight)
  private var persistedPanelHeight = Double(TerminalPanelMetrics.defaultHeight)

  private let sessionFactory: () -> TerminalSession
  private let startCommand: String?
  private weak var terminalView: TerminalPaneView?
  private weak var previousFirstResponder: NSResponder?
  private var didRequestShutdown = false
  private var findTask: Task<Void, Never>?

  init(
    startCommand: String? = nil,
    userDefaults: UserDefaults = .standard,
    sessionFactory: @escaping () -> TerminalSession = { TerminalSession() }
  ) {
    _persistedPanelHeight = AppStorage(
      wrappedValue: Double(TerminalPanelMetrics.defaultHeight),
      LocusPersistedDefaults.terminalPanelHeight,
      store: userDefaults
    )
    let storedHeight =
      userDefaults.object(
        forKey: LocusPersistedDefaults.terminalPanelHeight
      ) as? Double
    panelHeight =
      if let storedHeight, storedHeight.isFinite {
        max(CGFloat(storedHeight), TerminalPanelMetrics.minimumHeight)
      } else {
        TerminalPanelMetrics.defaultHeight
      }
    self.startCommand = startCommand
    self.sessionFactory = sessionFactory
  }

  deinit {
    MainActor.assumeIsolated {
      findTask?.cancel()
      shutdown()
    }
  }

  func toggle(window: NSWindow? = nil) {
    if isVisible {
      hide(in: window)
    } else {
      show(in: window)
    }
  }

  func updatePanelHeight(_ proposedHeight: CGFloat, parentHeight: CGFloat) {
    guard proposedHeight.isFinite, parentHeight.isFinite else {
      return
    }
    let clampedHeight = TerminalPanelMetrics.clampedHeight(
      proposedHeight,
      parentHeight: parentHeight
    )
    guard panelHeight != clampedHeight else {
      return
    }
    panelHeight = clampedHeight
    persistedPanelHeight = Double(clampedHeight)
  }

  func registerTerminalView(_ view: TerminalPaneView) {
    terminalView = view
    guard isVisible, let window = view.window else {
      return
    }
    window.makeFirstResponder(view)
  }

  func showFindBar() {
    guard isVisible else {
      return
    }
    isFindBarVisible = true
    scheduleSearch(for: findQuery)
  }

  func updateFindQuery(_ query: String) {
    guard findQuery != query else {
      return
    }
    findQuery = query
    scheduleSearch(for: query)
  }

  func selectSearch(_ direction: TerminalSearchDirection) {
    session?.searchSelect(direction)
  }

  func closeFindBar() {
    endFind()
    focusTerminal()
  }

  func shutdown() {
    guard !didRequestShutdown else {
      return
    }
    didRequestShutdown = true
    session?.terminate()
  }

  private func show(in window: NSWindow?) {
    let session = activeSession()
    previousFirstResponder = window?.firstResponder
    isVisible = true
    if session.state == .idle {
      session.start(
        command: startCommand,
        currentDirectory: currentWorkspaceFolder
          ?? FileManager.default.homeDirectoryForCurrentUser
      )
    }
    if let terminalView, let terminalWindow = terminalView.window ?? window {
      terminalWindow.makeFirstResponder(terminalView)
    }
  }

  private func hide(in window: NSWindow?) {
    endFind()
    isVisible = false
    if let window, window.firstResponder === terminalView {
      window.makeFirstResponder(previousFirstResponder)
    }
    previousFirstResponder = nil
  }

  private func scheduleSearch(for query: String) {
    findTask?.cancel()
    if query.isEmpty {
      session?.searchEnd()
      return
    }
    findTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: TerminalPanelMetrics.findDebounce)
      } catch {
        return
      }
      guard let self, self.isFindBarVisible, self.findQuery == query else {
        return
      }
      self.session?.searchStart(query)
    }
  }

  private func endFind() {
    findTask?.cancel()
    findTask = nil
    session?.searchEnd()
    isFindBarVisible = false
  }

  private func focusTerminal() {
    guard let terminalView, let window = terminalView.window else {
      return
    }
    window.makeFirstResponder(terminalView)
  }

  private func activeSession() -> TerminalSession {
    if let session {
      switch session.state {
      case .idle, .running:
        return session
      case .exited, .failed:
        break
      }
    }

    let session = sessionFactory()
    self.session = session
    return session
  }
}

struct TerminalPanelView: View {
  @ObservedObject var state: TerminalPanelState
  let parentHeight: CGFloat

  private var displayedHeight: CGFloat {
    TerminalPanelMetrics.clampedHeight(state.panelHeight, parentHeight: parentHeight)
  }

  var body: some View {
    Group {
      if let session = state.session {
        TerminalPanelContent(state: state, session: session)
      } else {
        Color(nsColor: LocusChromeColors.documentCard)
      }
    }
    .frame(maxWidth: .infinity)
    .frame(height: displayedHeight)
    .modifier(DocumentCardModifier())
    .overlay(alignment: .top) {
      TerminalPanelResizeHandle(
        panelHeight: displayedHeight,
        parentHeight: parentHeight,
        onHeightChange: state.updatePanelHeight
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal-panel")
  }
}

private struct TerminalPanelResizeHandle: View {
  let panelHeight: CGFloat
  let parentHeight: CGFloat
  let onHeightChange: (CGFloat, CGFloat) -> Void

  @State private var dragStartHeight: CGFloat?
  @State private var isHovering = false

  var body: some View {
    Color.clear
      .frame(height: TerminalPanelMetrics.resizeHandleHeight)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
          .onChanged { value in
            if dragStartHeight == nil {
              dragStartHeight = panelHeight
            }
            let proposedHeight = (dragStartHeight ?? panelHeight) - value.translation.height
            onHeightChange(proposedHeight, parentHeight)
          }
          .onEnded { _ in
            dragStartHeight = nil
          }
      )
      .onHover { hovering in
        guard hovering != isHovering else {
          return
        }
        isHovering = hovering
        if hovering {
          NSCursor.resizeUpDown.push()
        } else {
          NSCursor.pop()
        }
      }
      .onDisappear {
        if isHovering {
          NSCursor.pop()
          isHovering = false
        }
      }
      .accessibilityHidden(true)
  }
}

enum TerminalPanelPresentation {
  static func shouldShowJumpToBottom(
    snapshot: TerminalSession.Snapshot?
  ) -> Bool {
    snapshot?.atBottom == false
  }

  /// Label text for the panel: the reported title, else the reported
  /// working directory abbreviated with "~". nil hides the label.
  static func displayTitle(
    snapshot: TerminalSession.Snapshot?,
    homeDirectory: URL
  ) -> String? {
    guard let snapshot else {
      return nil
    }
    if let title = snapshot.title, !title.isEmpty {
      return title
    }
    guard let workingDirectory = snapshot.workingDirectory else {
      return nil
    }

    let path = workingDirectory.standardizedFileURL.path
    let homePath = homeDirectory.standardizedFileURL.path
    guard path != homePath else {
      return "~"
    }
    let homePrefix = homePath.hasSuffix("/") ? homePath : "\(homePath)/"
    guard path.hasPrefix(homePrefix) else {
      return path
    }
    let suffix = path.dropFirst(homePrefix.count)
    return suffix.isEmpty ? "~" : "~/\(suffix)"
  }

  static func shouldShowTitleLabel(isFindBarVisible: Bool) -> Bool {
    !isFindBarVisible
  }

  static func findCountLabel(search: TerminalSession.SearchState?) -> String {
    guard let status = search?.status, status.active else {
      return "—"
    }
    guard status.total > 0 else {
      return "0"
    }
    guard let selectedIndex = status.selectedIndex else {
      return "\(status.total)"
    }
    return "\(selectedIndex + 1)/\(status.total)"
  }
}

private struct TerminalPanelContent: View {
  @ObservedObject var state: TerminalPanelState
  @ObservedObject var session: TerminalSession
  @FocusState private var isFindFieldFocused: Bool

  var body: some View {
    switch session.state {
    case .idle, .running:
      ZStack(alignment: .bottomTrailing) {
        TerminalPane(
          session: session,
          onViewReady: state.registerTerminalView,
          onFindRequested: state.showFindBar
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if TerminalPanelPresentation.shouldShowJumpToBottom(
          snapshot: session.snapshot
        ) {
          Button {
            session.scrollToBottom()
          } label: {
            Image(systemName: "arrow.down.to.line")
              .imageScale(.small)
              .foregroundStyle(.secondary)
              .padding(6)
              .background(.ultraThinMaterial, in: Capsule())
              .overlay {
                Capsule()
                  .strokeBorder(
                    Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 0.5
                  )
              }
          }
          .buttonStyle(.plain)
          .padding(12)
          .accessibilityLabel("Scroll to Bottom")
          .accessibilityIdentifier("terminal-jump-to-bottom")
        }
      }
      .overlay(alignment: .topTrailing) {
        if state.isFindBarVisible {
          findBar
            .padding(.top, 8)
            .padding(.trailing, 12)
        } else if TerminalPanelPresentation.shouldShowTitleLabel(
          isFindBarVisible: state.isFindBarVisible
        ),
          let displayTitle = TerminalPanelPresentation.displayTitle(
            snapshot: session.snapshot,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
          )
        {
          Text(displayTitle)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 320, alignment: .trailing)
            .padding(.top, 10)
            .padding(.trailing, 12)
            .allowsHitTesting(false)
            .accessibilityIdentifier("terminal-title")
        }
      }
      .onChange(of: state.isFindBarVisible) { _, isVisible in
        isFindFieldFocused = isVisible
      }
    case .exited, .failed:
      Text("The process has ended.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var findBar: some View {
    HStack(spacing: 4) {
      TextField(
        "Find",
        text: Binding(
          get: { state.findQuery },
          set: { query in
            state.updateFindQuery(query)
          }
        )
      )
      .textFieldStyle(.plain)
      .frame(width: TerminalPanelMetrics.findFieldWidth)
      .focused($isFindFieldFocused)
      .onKeyPress(phases: .down) { press in
        guard press.key == .return else {
          return .ignored
        }
        state.selectSearch(press.modifiers.contains(.shift) ? .previous : .next)
        return .handled
      }
      .onExitCommand(perform: state.closeFindBar)
      .accessibilityIdentifier("terminal-find-field")

      Text(TerminalPanelPresentation.findCountLabel(search: session.snapshot?.search))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 34, alignment: .trailing)
        .accessibilityIdentifier("terminal-find-count")

      findButton(
        systemName: "chevron.up",
        label: "Previous Match",
        identifier: "terminal-find-previous"
      ) {
        state.selectSearch(.previous)
      }
      findButton(
        systemName: "chevron.down",
        label: "Next Match",
        identifier: "terminal-find-next"
      ) {
        state.selectSearch(.next)
      }
      findButton(
        systemName: "xmark",
        label: "Close Find",
        identifier: "terminal-find-close",
        action: state.closeFindBar
      )
    }
    .font(.caption)
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
    }
  }

  private func findButton(
    systemName: String,
    label: String,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(label)
    .accessibilityLabel(label)
    .accessibilityIdentifier(identifier)
  }
}

struct TerminalPanelShortcutLayer: View {
  @ObservedObject var state: TerminalPanelState

  var body: some View {
    ZStack {
      Button("Toggle Terminal") {
        state.toggle(window: NSApp.keyWindow)
      }
      .keyboardShortcut("j", modifiers: .command)
      .buttonStyle(.plain)
      .frame(width: 0, height: 0)
      .clipped()
      .opacity(0)
      .accessibilityHidden(true)

      TerminalControlBacktickMonitor { window in
        state.toggle(window: window ?? NSApp.keyWindow)
      }
      .frame(width: 0, height: 0)
    }
  }
}

private struct TerminalControlBacktickMonitor: NSViewRepresentable {
  let action: (NSWindow?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(action: action)
  }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.start()
    return NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.action = action
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  final class Coordinator {
    var action: (NSWindow?) -> Void
    private var monitor: Any?

    init(action: @escaping (NSWindow?) -> Void) {
      self.action = action
    }

    func start() {
      guard monitor == nil else {
        return
      }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        // AppKit invokes local event monitors on the main thread. Keep the
        // NSEvent inside that callback instead of crossing an actor boundary.
        guard self?.isControlBacktick(event) == true else {
          return event
        }
        self?.action(event.window)
        return nil
      }
    }

    func stop() {
      if let monitor {
        NSEvent.removeMonitor(monitor)
      }
      monitor = nil
    }

    private func isControlBacktick(_ event: NSEvent) -> Bool {
      guard event.keyCode == 50 else {
        return false
      }
      let significant = event.modifierFlags.intersection([.command, .control, .option, .shift])
      return significant == .control
    }
  }
}
