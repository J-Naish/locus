import Combine
import Dispatch
import Foundation

enum TerminalShellEnvironment {
  static func overrides(
    environment: [String: String],
    locale: Locale,
    localeExists: (String) -> Bool
  ) -> [(String, String)] {
    var overrides = environment.filter { key, _ in
      key == "LANG" || key.hasPrefix("LC_")
    }

    if overrides["LANG"] == nil {
      if let lang = synthesizedLang(locale: locale, localeExists: localeExists) {
        overrides["LANG"] = lang
      } else if overrides["LC_CTYPE"] == nil {
        overrides["LC_CTYPE"] = "UTF-8"
      }
    }

    return overrides.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
  }

  static func synthesizedLang(
    locale: Locale,
    localeExists: (String) -> Bool
  ) -> String? {
    guard
      let language = locale.language.languageCode?.identifier,
      let region = locale.region?.identifier
    else {
      return nil
    }

    let candidate = "\(language)_\(region).UTF-8"
    return localeExists(candidate) ? candidate : nil
  }

  static func currentOverrides() -> [(String, String)] {
    overrides(
      environment: ProcessInfo.processInfo.environment,
      locale: .current,
      localeExists: { localeName in
        FileManager.default.fileExists(
          atPath: "/usr/share/locale/\(localeName)"
        )
      }
    )
  }
}

/// Owns one shell session and publishes render snapshots for the future
/// terminal view layer. The PTY, terminal core, and frame are deliberately kept
/// off the main actor and are used only on `TerminalSessionWorker`'s serial
/// queue; only value snapshots cross back to the main actor.
@MainActor
final class TerminalSession: ObservableObject {
  /// Scrollback byte budget for new sessions. The FFI caps this at 256 MiB;
  /// 10 MB retains a few thousand typical 120-column rows.
  nonisolated static let defaultMaxScrollbackBytes = 10_000_000

  struct Snapshot: Equatable, Sendable {
    let generation: UInt64
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

  enum PasteOutcome: Equatable, Sendable {
    case sent
    case needsConfirmation
    case dropped
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var snapshot: Snapshot?

  private let publisher: TerminalSessionPublisher
  private let worker: TerminalSessionWorker

  init(
    columns: UInt16 = 80,
    rows: UInt16 = 24,
    maxScrollback: Int = TerminalSession.defaultMaxScrollbackBytes,
    pendingOutputStallGrace: TimeInterval = 5
  ) {
    let publisher = TerminalSessionPublisher()
    self.publisher = publisher
    worker = TerminalSessionWorker(
      columns: columns,
      rows: rows,
      maxScrollback: maxScrollback,
      pendingOutputStallGrace: pendingOutputStallGrace,
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

  func paste(
    _ text: String,
    allowUnsafe: Bool = false,
    completion: @escaping @MainActor @Sendable (PasteOutcome) -> Void = { _ in }
  ) {
    worker.paste(text, allowUnsafe: allowUnsafe, completion: completion)
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
  /// Stall-detection threshold for buffered output while the child is not reading.
  private static let maxPendingOutputBytes = 4 * 1024 * 1024
  private static let teardownQueue = DispatchQueue(
    label: "locus.terminal.session.teardown",
    qos: .utility
  )

  private enum Command: Sendable {
    case start(command: String, arguments: [String], currentDirectory: String?)
    case send(Data)
    case sendKey(TerminalKeyEvent)
    case sendKeys([TerminalKeyEvent])
    case paste(
      text: String,
      allowUnsafe: Bool,
      completion: @MainActor @Sendable (TerminalSession.PasteOutcome) -> Void
    )
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
  private var writeSource: DispatchSourceWrite?
  private var sourceCancellationGroup: DispatchGroup?
  private var pendingOutputStallTimer: DispatchSourceTimer?
  private var pendingOutput = Data()
  private var lastDrainProgressAt = DispatchTime.now()
  private var writeSourceIsActive = false
  private var generation: UInt64 = 0
  private var columns: UInt16
  private var rows: UInt16
  private let maxScrollback: Int
  private let pendingOutputStallGraceNanoseconds: UInt64

  init(
    columns: UInt16,
    rows: UInt16,
    maxScrollback: Int,
    pendingOutputStallGrace: TimeInterval,
    publishState: @escaping @MainActor (TerminalSession.State) -> Void,
    publishSnapshot: @escaping @MainActor (TerminalSession.Snapshot) -> Void
  ) {
    self.columns = columns
    self.rows = rows
    self.maxScrollback = maxScrollback
    pendingOutputStallGraceNanoseconds = UInt64(
      max(0.001, pendingOutputStallGrace) * 1_000_000_000
    )
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

  func paste(
    _ text: String,
    allowUnsafe: Bool,
    completion: @escaping @MainActor @Sendable (TerminalSession.PasteOutcome) -> Void
  ) {
    enqueue(
      .paste(
        text: text,
        allowUnsafe: allowUnsafe,
        completion: completion
      )
    )
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
    case .paste(let text, let allowUnsafe, let completion):
      pasteOnQueue(text, allowUnsafe: allowUnsafe, completion: completion)
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
      let environment = TerminalShellEnvironment.currentOverrides()
      let pty = try PtySession(
        command: command,
        arguments: arguments,
        environment: environment,
        currentDirectory: currentDirectory,
        columns: columns,
        rows: rows
      )
      let terminal = try TerminalCore(
        columns: columns,
        rows: rows,
        maxScrollback: maxScrollback
      )
      let frame = try TerminalFrame()
      let source = DispatchSource.makeReadSource(
        fileDescriptor: pty.masterFileDescriptor,
        queue: queue
      )
      let writeSource = DispatchSource.makeWriteSource(
        fileDescriptor: pty.masterFileDescriptor,
        queue: queue
      )
      let sourceCancellationGroup = DispatchGroup()
      sourceCancellationGroup.enter()
      sourceCancellationGroup.enter()

      self.pty = pty
      self.terminal = terminal
      self.frame = frame
      readSource = source
      self.writeSource = writeSource
      self.sourceCancellationGroup = sourceCancellationGroup

      source.setEventHandler { [weak self] in
        self?.readAvailableData()
      }
      // A dispatch source's monitored descriptor must remain open until its
      // cancellation handler runs. Retain the PTY through cancellation delivery.
      source.setCancelHandler {
        _ = pty
        sourceCancellationGroup.leave()
      }
      writeSource.setEventHandler { [weak self] in
        self?.flushPendingOutput()
      }
      writeSource.setCancelHandler {
        _ = pty
        sourceCancellationGroup.leave()
      }
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
      try enqueueWrite(data)
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
        encoded.append(
          try event.withLocusEvent { rawEvent in
            try terminal.encodeKey(rawEvent)
          }
        )
      }
      if !encoded.isEmpty {
        try enqueueWrite(encoded)
      }
    } catch {
      fail(error)
    }
  }

  private func pasteOnQueue(
    _ text: String,
    allowUnsafe: Bool,
    completion: @escaping @MainActor @Sendable (TerminalSession.PasteOutcome) -> Void
  ) {
    guard pty != nil, let terminal else {
      completePaste(.dropped, completion: completion)
      return
    }

    do {
      switch try terminal.encodePaste(text, allowUnsafe: allowUnsafe) {
      case .safe(let data):
        try enqueueWrite(data)
        completePaste(.sent, completion: completion)
      case .unsafe:
        completePaste(.needsConfirmation, completion: completion)
      }
    } catch {
      fail(error)
      completePaste(.dropped, completion: completion)
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
          try enqueueWrite(responses)
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
      columns: frame.columns,
      rows: frame.rows,
      cursorX: cursor.x,
      cursorY: cursor.y,
      cursorVisible: cursor.visible,
      cursorBlinking: cursor.blinking
    )
    publish(snapshot: snapshot)
  }

  private func enqueueWrite(_ data: Data) throws {
    guard pty != nil, !data.isEmpty else {
      return
    }
    if !pendingOutput.isEmpty {
      appendPendingOutput(data)
      return
    }

    let leftover = try writeAvailable(data)
    if !leftover.isEmpty {
      appendPendingOutput(leftover)
    }
  }

  /// Writes until the PTY would block and returns the unwritten tail.
  private func writeAvailable(_ data: Data) throws -> Data {
    guard let pty else {
      return Data()
    }
    var offset = 0
    while offset < data.count {
      do {
        let written = try pty.write(data.dropFirst(offset))
        guard written > 0 else {
          break
        }
        offset += written
        lastDrainProgressAt = .now()
      } catch let error as PtyError {
        if case .wouldBlock = error {
          break
        }
        throw error
      }
    }
    return Data(data.dropFirst(offset))
  }

  private func appendPendingOutput(_ data: Data) {
    pendingOutput.append(data)
    activateWriteSource()
    updatePendingOutputStallTimer()
  }

  private func flushPendingOutput() {
    guard !pendingOutput.isEmpty else {
      suspendWriteSource()
      return
    }

    let queued = pendingOutput
    pendingOutput.removeAll(keepingCapacity: true)
    do {
      pendingOutput = try writeAvailable(queued)
      if pendingOutput.isEmpty {
        suspendWriteSource()
      }
      updatePendingOutputStallTimer()
    } catch {
      fail(error)
    }
  }

  private func activateWriteSource() {
    guard let writeSource, !writeSourceIsActive else {
      return
    }
    writeSourceIsActive = true
    writeSource.resume()
  }

  private func suspendWriteSource() {
    guard let writeSource, writeSourceIsActive else {
      return
    }
    writeSourceIsActive = false
    writeSource.suspend()
  }

  private func updatePendingOutputStallTimer() {
    guard pendingOutput.count > Self.maxPendingOutputBytes else {
      cancelPendingOutputStallTimer()
      return
    }

    guard pendingOutputStallTimer == nil else {
      return
    }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { [weak self] in
      self?.checkPendingOutputStall()
    }
    pendingOutputStallTimer = timer
    timer.resume()
    schedulePendingOutputStallCheck(on: timer, after: pendingOutputStallGraceNanoseconds)
  }

  private func checkPendingOutputStall() {
    guard pendingOutput.count > Self.maxPendingOutputBytes else {
      cancelPendingOutputStallTimer()
      return
    }

    let now = DispatchTime.now().uptimeNanoseconds
    let lastProgress = lastDrainProgressAt.uptimeNanoseconds
    let elapsed = now >= lastProgress ? now - lastProgress : 0
    guard elapsed >= pendingOutputStallGraceNanoseconds else {
      if let pendingOutputStallTimer {
        schedulePendingOutputStallCheck(
          on: pendingOutputStallTimer,
          after: pendingOutputStallGraceNanoseconds - elapsed
        )
      }
      return
    }

    fail(
      PtyError.io(
        "Terminal output stalled with more than \(Self.maxPendingOutputBytes) buffered bytes."
      )
    )
  }

  private func schedulePendingOutputStallCheck(
    on timer: DispatchSourceTimer,
    after nanoseconds: UInt64
  ) {
    timer.schedule(
      deadline: .now() + .nanoseconds(Int(min(nanoseconds, UInt64(Int.max)))),
      leeway: .milliseconds(10)
    )
  }

  private func cancelPendingOutputStallTimer() {
    pendingOutputStallTimer?.cancel()
    pendingOutputStallTimer = nil
  }

  private func finishExited(code: Int32) {
    _ = cancelSource()
    pty = nil
    terminal = nil
    frame = nil
    publish(state: .exited(code: code))
  }

  private func terminate(publishExit: Bool) {
    let ptyForTeardown = pty
    let cancellationGroup = cancelSource()
    pty = nil
    terminal = nil
    frame = nil
    if publishExit {
      publish(state: .exited(code: -1))
    }
    Self.scheduleShutdown(of: ptyForTeardown, after: cancellationGroup)
  }

  private func fail(_ error: Error) {
    let ptyForTeardown = pty
    let cancellationGroup = cancelSource()
    pty = nil
    terminal = nil
    frame = nil
    publish(state: .failed(error.localizedDescription))
    Self.scheduleShutdown(of: ptyForTeardown, after: cancellationGroup)
  }

  @discardableResult
  private func cancelSource() -> DispatchGroup? {
    let cancellationGroup = sourceCancellationGroup
    sourceCancellationGroup = nil
    cancelPendingOutputStallTimer()
    readSource?.cancel()
    readSource = nil
    if let writeSource {
      if !writeSourceIsActive {
        writeSource.resume()
      }
      writeSource.cancel()
    }
    writeSource = nil
    writeSourceIsActive = false
    pendingOutput.removeAll()
    return cancellationGroup
  }

  private static func scheduleShutdown(
    of pty: PtySession?,
    after cancellationGroup: DispatchGroup?
  ) {
    guard let pty else {
      return
    }
    let retained = Unmanaged.passRetained(pty)
    let opaqueAddress = UInt(bitPattern: retained.toOpaque())
    let shutdown: @Sendable () -> Void = {
      shutdownRetainedPty(at: opaqueAddress)
    }
    if let cancellationGroup {
      cancellationGroup.notify(queue: teardownQueue, execute: shutdown)
    } else {
      teardownQueue.async(execute: shutdown)
    }
  }

  private static func shutdownRetainedPty(at opaqueAddress: UInt) {
    guard let opaque = UnsafeMutableRawPointer(bitPattern: opaqueAddress) else {
      preconditionFailure("Retained PTY pointer was unexpectedly nil.")
    }
    let retained = Unmanaged<PtySession>.fromOpaque(opaque)
    let pty = retained.takeRetainedValue()
    try? pty.shutdown()
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

  private func completePaste(
    _ outcome: TerminalSession.PasteOutcome,
    completion: @escaping @MainActor @Sendable (TerminalSession.PasteOutcome) -> Void
  ) {
    Task { @MainActor in
      completion(outcome)
    }
  }
}
