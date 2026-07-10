import AppKit
import SwiftUI

enum TerminalPanelMetrics {
  static let defaultHeight: CGFloat = 240
}

@MainActor
final class TerminalPanelState: ObservableObject {
  @Published private(set) var isVisible = false
  @Published private(set) var session: TerminalSession?
  var currentWorkspaceFolder: URL?

  private let sessionFactory: () -> TerminalSession
  private let startCommand: String?
  private weak var terminalView: TerminalPaneView?
  private weak var previousFirstResponder: NSResponder?
  private var didRequestShutdown = false

  init(
    startCommand: String? = nil,
    sessionFactory: @escaping () -> TerminalSession = { TerminalSession() }
  ) {
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
    .frame(height: TerminalPanelMetrics.defaultHeight)
    .modifier(DocumentCardModifier())
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("terminal-panel")
  }
}

private struct TerminalPanelContent: View {
  @ObservedObject var session: TerminalSession
  let onViewReady: (TerminalPaneView) -> Void

  var body: some View {
    switch session.state {
    case .idle, .running:
      TerminalPane(session: session, onViewReady: onViewReady)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
