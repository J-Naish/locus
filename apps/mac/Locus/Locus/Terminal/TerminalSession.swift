import Combine
import Foundation

/// Owns one shell session and publishes render snapshots for the future
/// terminal view layer. The PTY, terminal core, and frame are deliberately kept
/// off the main actor and are used only by `TerminalSessionWorker`'s actor
/// executor; only value snapshots cross back to the main actor.
@MainActor
final class TerminalSession: ObservableObject {
  struct Snapshot: Equatable, Sendable {
    let generation: UInt64
    /// Temporary text surface used until U3 renders directly from terminal
    /// frames. Every render currently stringifies the frame for headless tests.
    let plainText: String
    let columns: UInt16
    let rows: UInt16
    let cursorX: UInt16
    let cursorY: UInt16
  }

  enum State: Equatable, Sendable {
    case idle
    case running
    case exited(code: Int32)
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var snapshot: Snapshot?

  private let publisher: TerminalSessionPublisher
  private let worker: TerminalSessionWorker

  init(columns: UInt16 = 80, rows: UInt16 = 24) {
    let publisher = TerminalSessionPublisher()
    self.publisher = publisher
    worker = TerminalSessionWorker(
      columns: columns,
      rows: rows,
      publishState: { [weak publisher] state in
        publisher?.publish(state: state)
      },
      publishSnapshot: { [weak publisher] snapshot in
        publisher?.publish(snapshot: snapshot)
      }
    )
    publisher.session = self
  }

  func start(command: String? = nil) {
    guard state == .idle else {
      return
    }

    state = .running
    let resolvedCommand = command ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let arguments = command == nil ? ["-l"] : []
    Task {
      await worker.start(command: resolvedCommand, arguments: arguments)
    }
  }

  func send(_ data: Data) {
    Task {
      await worker.send(data)
    }
  }

  func resize(columns: UInt16, rows: UInt16) {
    Task {
      await worker.resize(columns: columns, rows: rows)
    }
  }

  func terminate() {
    Task {
      await worker.terminate()
    }
  }

  fileprivate func publish(state: State) {
    self.state = state
  }

  fileprivate func publish(snapshot: Snapshot) {
    self.snapshot = snapshot
  }
}

@MainActor
private final class TerminalSessionPublisher {
  weak var session: TerminalSession?

  func publish(state: TerminalSession.State) {
    session?.publish(state: state)
  }

  func publish(snapshot: TerminalSession.Snapshot) {
    session?.publish(snapshot: snapshot)
  }
}

private actor TerminalSessionWorker {
  private let readQueue = DispatchQueue(label: "locus.terminal.session.read")
  private let publishState: @MainActor (TerminalSession.State) -> Void
  private let publishSnapshot: @MainActor (TerminalSession.Snapshot) -> Void

  private var pty: PtySession?
  private var terminal: TerminalCore?
  private var frame: TerminalFrame?
  private var readSource: DispatchSourceRead?
  private var generation: UInt64 = 0
  private var columns: UInt16
  private var rows: UInt16

  init(
    columns: UInt16,
    rows: UInt16,
    publishState: @escaping @MainActor (TerminalSession.State) -> Void,
    publishSnapshot: @escaping @MainActor (TerminalSession.Snapshot) -> Void
  ) {
    self.columns = columns
    self.rows = rows
    self.publishState = publishState
    self.publishSnapshot = publishSnapshot
  }

  func start(command: String, arguments: [String]) {
    guard pty == nil, terminal == nil, frame == nil, readSource == nil else {
      return
    }

    do {
      let environment = ProcessInfo.processInfo.environment
        .map { key, value in (key, value) }
        .sorted { $0.0 < $1.0 }
      let pty = try PtySession(
        command: command,
        arguments: arguments,
        environment: environment,
        columns: columns,
        rows: rows
      )
      let terminal = try TerminalCore(columns: columns, rows: rows)
      let frame = try TerminalFrame()
      let source = DispatchSource.makeReadSource(
        fileDescriptor: pty.masterFileDescriptor,
        queue: readQueue
      )

      self.pty = pty
      self.terminal = terminal
      self.frame = frame
      readSource = source

      source.setEventHandler { [weak self] in
        Task {
          await self?.readAvailableData()
        }
      }
      source.setCancelHandler {}
      source.resume()

      try renderAndPublish()
    } catch {
      fail(error)
    }
  }

  func send(_ data: Data) {
    guard pty != nil, !data.isEmpty else {
      return
    }

    do {
      try writeAll(data)
    } catch {
      fail(error)
    }
  }

  func resize(columns: UInt16, rows: UInt16) {
    self.columns = columns
    self.rows = rows

    guard let pty, let terminal = terminal else {
      return
    }

    do {
      try terminal.resize(columns: columns, rows: rows)
      try pty.resize(columns: columns, rows: rows)
      try renderAndPublish()
    } catch {
      fail(error)
    }
  }

  func terminate() {
    terminate(publishExit: true)
  }

  private func readAvailableData() {
    guard let pty, let terminal else {
      return
    }

    do {
      var didRead = false
      var buffer = [UInt8](repeating: 0, count: 4096)

      while true {
        let count = try buffer.withUnsafeMutableBytes { rawBuffer in
          try pty.read(into: rawBuffer)
        }
        guard count > 0 else {
          break
        }

        didRead = true
        try terminal.feed(Data(buffer.prefix(count)))
        let responses = try terminal.takeResponses()
        if !responses.isEmpty {
          try writeAll(responses)
        }
      }

      if didRead {
        try renderAndPublish()
      }

      if let exitStatus = try pty.tryWait() {
        finishExited(code: exitStatus.code)
      }
    } catch {
      fail(error)
    }
  }

  private func renderAndPublish() throws {
    guard let terminal, let frame else {
      return
    }

    try terminal.render(into: frame)
    generation &+= 1
    let cursor = frame.cursor
    let snapshot = TerminalSession.Snapshot(
      generation: generation,
      plainText: frame.plainText(),
      columns: frame.columns,
      rows: frame.rows,
      cursorX: cursor.x,
      cursorY: cursor.y
    )
    publish(snapshot: snapshot)
  }

  private func writeAll(_ data: Data) throws {
    var offset = 0
    while offset < data.count {
      let written = try pty?.write(data.dropFirst(offset)) ?? 0
      guard written > 0 else {
        throw PtyError.wouldBlock("PTY write accepted zero bytes.")
      }
      offset += written
    }
  }

  private func finishExited(code: Int32) {
    cancelSource()
    pty = nil
    terminal = nil
    frame = nil
    publish(state: .exited(code: code))
  }

  private func terminate(publishExit: Bool) {
    cancelSource()
    do {
      try pty?.shutdown()
    } catch {
      if publishExit {
        publish(state: .failed(error.localizedDescription))
      }
      pty = nil
      terminal = nil
      frame = nil
      return
    }

    pty = nil
    terminal = nil
    frame = nil
    if publishExit {
      publish(state: .exited(code: -1))
    }
  }

  private func fail(_ error: Error) {
    cancelSource()
    try? pty?.shutdown()
    pty = nil
    terminal = nil
    frame = nil
    publish(state: .failed(error.localizedDescription))
  }

  private func cancelSource() {
    readSource?.cancel()
    readSource = nil
  }

  private func publish(state: TerminalSession.State) {
    Task { @MainActor [publishState] in
      publishState(state)
    }
  }

  private func publish(snapshot: TerminalSession.Snapshot) {
    Task { @MainActor [publishSnapshot] in
      publishSnapshot(snapshot)
    }
  }
}
