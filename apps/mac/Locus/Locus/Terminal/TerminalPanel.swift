import AppKit
import SwiftUI

enum TerminalPanelMetrics {
  static let defaultHeight: CGFloat = 240
  static let resizeHandleHeight: CGFloat = 8
  static let maximumParentHeightFraction: CGFloat = 0.8

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
    isVisible = false
    if let window, window.firstResponder === terminalView {
      window.makeFirstResponder(previousFirstResponder)
    }
    previousFirstResponder = nil
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
        TerminalPanelContent(session: session) { view in
          state.registerTerminalView(view)
        }
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
}

private struct TerminalPanelContent: View {
  @ObservedObject var session: TerminalSession
  let onViewReady: (TerminalPaneView) -> Void

  var body: some View {
    switch session.state {
    case .idle, .running:
      ZStack(alignment: .bottomTrailing) {
        TerminalPane(session: session, onViewReady: onViewReady)
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
    case .exited, .failed:
      Text("The process has ended.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
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
