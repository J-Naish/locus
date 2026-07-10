import Combine
import Dispatch
import Foundation

/// Owns one shell session and publishes render snapshots for the future
/// terminal view layer. The PTY, terminal core, and frame are deliberately kept
/// off the main actor and are used only on `TerminalSessionWorker`'s serial
/// queue; only value snapshots cross back to the main actor.
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
    let cursorVisible: Bool
    let cursorBlinking: Bool
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

  func start(command: String? = nil, currentDirectory: URL? = nil) {
    guard state == .idle else {
      return
    }

    state = .running
    let resolvedCommand = command ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let arguments = command == nil ? ["-l"] : []
    worker.start(
      command: resolvedCommand,
      arguments: arguments,
      currentDirectory: currentDirectory?.path
    )
  }

  func send(_ data: Data) {
    worker.send(data)
  }

  func sendKey(_ event: TerminalKeyEvent) {
    worker.sendKey(event)
  }

  func sendKeys(_ events: [TerminalKeyEvent]) {
    worker.sendKeys(events)
  }

  func resize(columns: UInt16, rows: UInt16) {
    worker.resize(columns: columns, rows: rows)
  }

  func terminate() {
    worker.terminate()
  }

  func withFrame(_ body: (TerminalFrame) -> Void) {
    worker.withFrame(body)
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

private final class TerminalSessionWorker {
  private enum Command: Sendable {
    case start(command: String, arguments: [String], currentDirectory: String?)
    case send(Data)
    case sendKey(TerminalKeyEvent)
    case sendKeys([TerminalKeyEvent])
    case resize(columns: UInt16, rows: UInt16)
    case terminate
  }

  private let queue = DispatchQueue(label: "locus.terminal.session")
  private let queueKey = DispatchSpecificKey<Void>()
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
    queue.setSpecific(key: queueKey, value: ())
  }

  func start(command: String, arguments: [String], currentDirectory: String?) {
    enqueue(
      .start(
        command: command,
        arguments: arguments,
        currentDirectory: currentDirectory
      )
    )
  }

  func send(_ data: Data) {
    enqueue(.send(data))
  }

  func sendKey(_ event: TerminalKeyEvent) {
    enqueue(.sendKey(event))
  }

  func sendKeys(_ events: [TerminalKeyEvent]) {
    guard !events.isEmpty else {
      return
    }
    enqueue(.sendKeys(events))
  }

  func resize(columns: UInt16, rows: UInt16) {
    enqueue(.resize(columns: columns, rows: rows))
  }

  func terminate() {
    enqueue(.terminate)
  }

  func withFrame(_ body: (TerminalFrame) -> Void) {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      if let frame {
        body(frame)
      }
      return
    }

    queue.sync {
      if let frame {
        body(frame)
      }
    }
  }

  private func enqueue(_ command: Command) {
    let retained = Unmanaged.passRetained(self)
    let opaqueAddress = UInt(bitPattern: retained.toOpaque())
    queue.async {
      guard let opaque = UnsafeMutableRawPointer(bitPattern: opaqueAddress) else {
        preconditionFailure("Retained terminal session worker pointer was unexpectedly nil.")
      }
      let retained = Unmanaged<TerminalSessionWorker>.fromOpaque(opaque)
      defer {
        retained.release()
      }
      retained.takeUnretainedValue().perform(command)
    }
  }

  private func perform(_ command: Command) {
    switch command {
    case .start(let command, let arguments, let currentDirectory):
      startOnQueue(
        command: command,
        arguments: arguments,
        currentDirectory: currentDirectory
      )
    case .send(let data):
      sendOnQueue(data)
    case .sendKey(let event):
      sendKeyOnQueue(event)
    case .sendKeys(let events):
      sendKeysOnQueue(events)
    case .resize(let columns, let rows):
      resizeOnQueue(columns: columns, rows: rows)
    case .terminate:
      terminate(publishExit: true)
    }
  }

  private func startOnQueue(
    command: String,
    arguments: [String],
    currentDirectory: String?
  ) {
    guard pty == nil, terminal == nil, frame == nil, readSource == nil else {
      return
    }

    do {
      var processEnvironment = ProcessInfo.processInfo.environment
      if processEnvironment["LC_CTYPE"] == nil {
        processEnvironment["LC_CTYPE"] = "UTF-8"
      }
      let environment =
        processEnvironment
        .map { key, value in (key, value) }
        .sorted { $0.0 < $1.0 }
      let pty = try PtySession(
        command: command,
        arguments: arguments,
        environment: environment,
        currentDirectory: currentDirectory,
        columns: columns,
        rows: rows
      )
      let terminal = try TerminalCore(columns: columns, rows: rows)
      let frame = try TerminalFrame()
      let source = DispatchSource.makeReadSource(
        fileDescriptor: pty.masterFileDescriptor,
        queue: queue
      )

      self.pty = pty
      self.terminal = terminal
      self.frame = frame
      readSource = source

      source.setEventHandler { [weak self] in
        self?.readAvailableData()
      }
      source.setCancelHandler {}
      source.resume()

      try renderAndPublish()
    } catch {
      fail(error)
    }
  }

  private func sendOnQueue(_ data: Data) {
    guard pty != nil, !data.isEmpty else {
      return
    }

    do {
      try writeAll(data)
    } catch {
      fail(error)
    }
  }

  private func sendKeyOnQueue(_ event: TerminalKeyEvent) {
    sendKeysOnQueue([event])
  }

  private func sendKeysOnQueue(_ events: [TerminalKeyEvent]) {
    guard pty != nil, let terminal else {
      return
    }

    do {
      var encoded = Data()
      for event in events {
        let eventData = try event.withLocusEvent { rawEvent in
          try terminal.encodeKey(rawEvent)
        }
        encoded.append(eventData)
      }
      if !encoded.isEmpty {
        try writeAll(encoded)
      }
    } catch {
      fail(error)
    }
  }

  private func resizeOnQueue(columns: UInt16, rows: UInt16) {
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

    try terminal.render(into: frame, full: true)
    generation &+= 1
    let cursor = frame.cursor
    let snapshot = TerminalSession.Snapshot(
      generation: generation,
      plainText: frame.plainText(),
      columns: frame.columns,
      rows: frame.rows,
      cursorX: cursor.x,
      cursorY: cursor.y,
      cursorVisible: cursor.visible,
      cursorBlinking: cursor.blinking
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
