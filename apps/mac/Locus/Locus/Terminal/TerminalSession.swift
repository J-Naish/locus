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
    let atBottom: Bool
    let title: String?
    let workingDirectory: URL?
    let search: SearchState?
  }

  struct SearchState: Equatable, Sendable {
    let status: TerminalSearchStatus
    let viewportMatches: [TerminalSearchMatch]
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

  /// Routes wheel input through the terminal's wheel policy. Negative
  /// deltas scroll toward older history rows.
  func scrollWheel(
    deltaRows: Int32,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) {
    worker.scrollWheel(
      deltaRows: deltaRows,
      column: column,
      row: row,
      modifiers: modifiers
    )
  }

  /// Returns the viewport to the live bottom of the terminal.
  func scrollToBottom() {
    worker.scrollToBottom()
  }

  func searchStart(_ needle: String) {
    guard !needle.isEmpty else {
      return
    }
    worker.searchStart(needle)
  }

  func searchEnd() {
    worker.searchEnd()
  }

  func searchSelect(_ direction: TerminalSearchDirection) {
    worker.searchSelect(direction)
  }

  func terminate() {
    worker.terminate()
  }

  func withFrame(_ body: (TerminalFrame) -> Void) {
    worker.withFrame(body)
  }

  /// Synchronously routes a mouse press through the running application's
  /// mouse-reporting mode. Do not call this from inside `withFrame`.
  func routeMousePress(
    button: TerminalMouseButton,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) -> Bool {
    worker.routeMousePress(
      button: button,
      column: column,
      row: row,
      modifiers: modifiers
    )
  }

  func sendMouse(
    kind: TerminalMouseEventKind,
    button: TerminalMouseButton,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) {
    worker.sendMouse(
      kind: kind,
      button: button,
      column: column,
      row: row,
      modifiers: modifiers
    )
  }

  func selectionGesture(
    _ kind: TerminalSelectionGestureKind,
    column: UInt16,
    row: UInt16,
    cellFractionX: Float,
    rectangle: Bool
  ) {
    worker.selectionGesture(
      kind,
      column: column,
      row: row,
      cellFractionX: cellFractionX,
      rectangle: rectangle
    )
  }

  func selectionAutoscrollTick(
    direction: Int32,
    column: UInt16,
    cellFractionX: Float,
    rectangle: Bool
  ) {
    worker.selectionAutoscrollTick(
      direction: direction,
      column: column,
      cellFractionX: cellFractionX,
      rectangle: rectangle
    )
  }

  func clearSelection() {
    worker.clearSelection()
  }

  /// Synchronously returns the current selection. Do not call this from
  /// inside `withFrame`.
  func selectionText() -> String {
    worker.selectionText()
  }

  /// Synchronously scans links in the current viewport. Do not call this
  /// from inside `withFrame` because both accessors share the worker queue.
  func viewportLinks() -> [TerminalLinkMatch] {
    worker.viewportLinks()
  }

  /// Resolves an ID returned by the latest `viewportLinks` call. Do not call
  /// this from inside `withFrame`; unknown, stale, and failed lookups return nil.
  func linkURI(_ id: UInt32) -> String? {
    worker.linkURI(id)
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
  /// Cap on bytes consumed per read-source event. The kqueue-backed read
  /// source re-fires while the descriptor stays readable, so throughput is
  /// unchanged; the cap bounds how long a flood can monopolize the serial
  /// queue before queued input and rendering get a turn.
  private static let maxBytesPerReadEvent = 256 * 1024
  private static let maxWheelRowsPerEvent: Int32 = 4096
  /// PageList's down-overflow path clamps at the active viewport while
  /// walking pages, so a large positive delta is a safe jump to bottom.
  /// See core/crates/terminal/src/page_list.rs:746.
  private static let scrollToBottomRowDelta = Int(Int32.max)
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
    case scrollWheel(
      deltaRows: Int32,
      column: UInt16,
      row: UInt16,
      modifiers: TerminalModifiers
    )
    case scrollToBottom
    case searchStart(String)
    case searchEnd
    case searchSelect(TerminalSearchDirection)
    case sendMouse(
      kind: TerminalMouseEventKind,
      button: TerminalMouseButton,
      column: UInt16,
      row: UInt16,
      modifiers: TerminalModifiers
    )
    case selectionGesture(
      TerminalSelectionGestureKind,
      column: UInt16,
      row: UInt16,
      cellFractionX: Float,
      rectangle: Bool
    )
    case selectionAutoscrollTick(
      direction: Int32,
      column: UInt16,
      cellFractionX: Float,
      rectangle: Bool
    )
    case clearSelection
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
  private var lastTitleReport = ""
  private var lastWorkingDirectoryReport = ""
  private var cachedTitle: String?
  private var cachedWorkingDirectory: URL?
  private var searchIsActive = false
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

  func scrollWheel(
    deltaRows: Int32,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) {
    enqueue(
      .scrollWheel(
        deltaRows: deltaRows,
        column: column,
        row: row,
        modifiers: modifiers
      )
    )
  }

  func scrollToBottom() {
    enqueue(.scrollToBottom)
  }

  func searchStart(_ needle: String) {
    enqueue(.searchStart(needle))
  }

  func searchEnd() {
    enqueue(.searchEnd)
  }

  func searchSelect(_ direction: TerminalSearchDirection) {
    enqueue(.searchSelect(direction))
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

  func routeMousePress(
    button: TerminalMouseButton,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) -> Bool {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return routeMousePressOnQueue(
        button: button,
        column: column,
        row: row,
        modifiers: modifiers
      )
    }
    return queue.sync {
      routeMousePressOnQueue(
        button: button,
        column: column,
        row: row,
        modifiers: modifiers
      )
    }
  }

  func sendMouse(
    kind: TerminalMouseEventKind,
    button: TerminalMouseButton,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) {
    enqueue(
      .sendMouse(
        kind: kind,
        button: button,
        column: column,
        row: row,
        modifiers: modifiers
      )
    )
  }

  func selectionGesture(
    _ kind: TerminalSelectionGestureKind,
    column: UInt16,
    row: UInt16,
    cellFractionX: Float,
    rectangle: Bool
  ) {
    enqueue(
      .selectionGesture(
        kind,
        column: column,
        row: row,
        cellFractionX: cellFractionX,
        rectangle: rectangle
      )
    )
  }

  func selectionAutoscrollTick(
    direction: Int32,
    column: UInt16,
    cellFractionX: Float,
    rectangle: Bool
  ) {
    enqueue(
      .selectionAutoscrollTick(
        direction: direction,
        column: column,
        cellFractionX: cellFractionX,
        rectangle: rectangle
      )
    )
  }

  func clearSelection() {
    enqueue(.clearSelection)
  }

  func selectionText() -> String {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return selectionTextOnQueue()
    }
    return queue.sync {
      selectionTextOnQueue()
    }
  }

  func viewportLinks() -> [TerminalLinkMatch] {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return viewportLinksOnQueue()
    }
    return queue.sync {
      viewportLinksOnQueue()
    }
  }

  func linkURI(_ id: UInt32) -> String? {
    if DispatchQueue.getSpecific(key: queueKey) != nil {
      return linkURIOnQueue(id)
    }
    return queue.sync {
      linkURIOnQueue(id)
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
    case .scrollWheel(let deltaRows, let column, let row, let modifiers):
      scrollWheelOnQueue(
        deltaRows: deltaRows,
        column: column,
        row: row,
        modifiers: modifiers
      )
    case .scrollToBottom:
      scrollToBottomOnQueue()
    case .searchStart(let needle):
      searchStartOnQueue(needle)
    case .searchEnd:
      searchEndOnQueue()
    case .searchSelect(let direction):
      searchSelectOnQueue(direction)
    case .sendMouse(let kind, let button, let column, let row, let modifiers):
      sendMouseOnQueue(
        kind: kind,
        button: button,
        column: column,
        row: row,
        modifiers: modifiers
      )
    case .selectionGesture(let kind, let column, let row, let cellFractionX, let rectangle):
      selectionGestureOnQueue(
        kind,
        column: column,
        row: row,
        cellFractionX: cellFractionX,
        rectangle: rectangle
      )
    case .selectionAutoscrollTick(let direction, let column, let cellFractionX, let rectangle):
      selectionAutoscrollTickOnQueue(
        direction: direction,
        column: column,
        cellFractionX: cellFractionX,
        rectangle: rectangle
      )
    case .clearSelection:
      clearSelectionOnQueue()
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
      returnToBottomForUserInputIfNeeded()
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
      returnToBottomForUserInputIfNeeded()
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
        returnToBottomForUserInputIfNeeded()
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

  private func scrollWheelOnQueue(
    deltaRows: Int32,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) {
    guard
      let terminal,
      deltaRows != 0,
      deltaRows >= -Self.maxWheelRowsPerEvent,
      deltaRows <= Self.maxWheelRowsPerEvent
    else {
      return
    }
    let coordinate = clampedCoordinate(column: column, row: row)
    do {
      let bytes = try terminal.scrollWheel(
        deltaRows: deltaRows,
        column: coordinate.column,
        row: coordinate.row,
        modifiers: modifiers
      )
      if !bytes.isEmpty {
        try enqueueWrite(bytes)
      }
      try renderAndPublish()
    } catch {
      handleMouseInteractionError(error)
    }
  }

  private func scrollToBottomOnQueue() {
    guard let terminal else {
      return
    }
    do {
      try terminal.scroll(byRows: Self.scrollToBottomRowDelta)
      try renderAndPublish()
    } catch {
      handleMouseInteractionError(error)
    }
  }

  private func returnToBottomForUserInputIfNeeded() {
    guard frame?.atBottom == false, let terminal else {
      return
    }
    do {
      try terminal.scroll(byRows: Self.scrollToBottomRowDelta)
      try renderAndPublish()
    } catch {
      handleMouseInteractionError(error)
    }
  }

  private func routeMousePressOnQueue(
    button: TerminalMouseButton,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) -> Bool {
    guard let terminal else {
      return false
    }
    let coordinate = clampedCoordinate(column: column, row: row)
    do {
      let bytes = try terminal.encodeMouse(
        kind: .press,
        button: button,
        column: coordinate.column,
        row: coordinate.row,
        modifiers: modifiers
      )
      guard !bytes.isEmpty else {
        return false
      }
      try enqueueWrite(bytes)
      try renderAndPublish()
      return true
    } catch {
      handleMouseInteractionError(error)
      return false
    }
  }

  private func sendMouseOnQueue(
    kind: TerminalMouseEventKind,
    button: TerminalMouseButton,
    column: UInt16,
    row: UInt16,
    modifiers: TerminalModifiers
  ) {
    guard let terminal else {
      return
    }
    let coordinate = clampedCoordinate(column: column, row: row)
    do {
      let bytes = try terminal.encodeMouse(
        kind: kind,
        button: button,
        column: coordinate.column,
        row: coordinate.row,
        modifiers: modifiers
      )
      guard !bytes.isEmpty else {
        return
      }
      try enqueueWrite(bytes)
      try renderAndPublish()
    } catch {
      handleMouseInteractionError(error)
    }
  }

  private func selectionGestureOnQueue(
    _ kind: TerminalSelectionGestureKind,
    column: UInt16,
    row: UInt16,
    cellFractionX: Float,
    rectangle: Bool
  ) {
    guard let terminal else {
      return
    }
    let coordinate = clampedCoordinate(column: column, row: row)
    do {
      try terminal.selectionGesture(
        kind,
        column: coordinate.column,
        row: coordinate.row,
        cellFractionX: cellFractionX,
        rectangle: rectangle
      )
      try renderAndPublish()
    } catch {
      handleMouseInteractionError(error)
    }
  }

  private func selectionAutoscrollTickOnQueue(
    direction: Int32,
    column: UInt16,
    cellFractionX: Float,
    rectangle: Bool
  ) {
    guard let terminal else {
      return
    }
    let clampedColumn = min(column, columns > 0 ? columns - 1 : 0)
    do {
      try terminal.autoscrollSelection(
        direction: direction,
        column: clampedColumn,
        cellFractionX: cellFractionX,
        rectangle: rectangle
      )
      try renderAndPublish()
    } catch {
      handleMouseInteractionError(error)
    }
  }

  private func clearSelectionOnQueue() {
    guard let terminal else {
      return
    }
    do {
      try terminal.clearSelection()
      try renderAndPublish()
    } catch {
      handleMouseInteractionError(error)
    }
  }

  private func selectionTextOnQueue() -> String {
    guard let terminal else {
      return ""
    }
    do {
      return try terminal.selectionString()
    } catch {
      handleMouseInteractionError(error)
      return ""
    }
  }

  private func viewportLinksOnQueue() -> [TerminalLinkMatch] {
    guard let terminal else {
      return []
    }
    do {
      return try terminal.viewportLinks()
    } catch {
      handleMouseInteractionError(error)
      return []
    }
  }

  private func linkURIOnQueue(_ id: UInt32) -> String? {
    guard let terminal else {
      return nil
    }
    do {
      let uri = try terminal.linkURI(id)
      return uri.isEmpty ? nil : uri
    } catch {
      handleMouseInteractionError(error)
      return nil
    }
  }

  private func clampedCoordinate(
    column: UInt16,
    row: UInt16
  ) -> (column: UInt16, row: UInt16) {
    (
      min(column, columns > 0 ? columns - 1 : 0),
      min(row, rows > 0 ? rows - 1 : 0)
    )
  }

  private func handleMouseInteractionError(_ error: Error) {
    if case TerminalBridgeError.corePanic = error {
      fail(error)
    }
  }

  private func readAvailableData() {
    guard let pty, let terminal else {
      return
    }

    do {
      var didRead = false
      var bytesReadThisEvent = 0
      var buffer = [UInt8](repeating: 0, count: 4096)

      while bytesReadThisEvent < Self.maxBytesPerReadEvent {
        let count = try buffer.withUnsafeMutableBytes { rawBuffer in
          try pty.read(into: rawBuffer)
        }
        guard count > 0 else {
          break
        }

        didRead = true
        bytesReadThisEvent += count
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
    refreshReportedMetadata(from: terminal)
    generation &+= 1
    let cursor = frame.cursor
    let search: TerminalSession.SearchState?
    do {
      search = try searchState(from: terminal)
    } catch {
      searchIsActive = false
      handleMouseInteractionError(error)
      guard self.terminal != nil, self.frame != nil else {
        return
      }
      search = nil
    }
    let snapshot = TerminalSession.Snapshot(
      generation: generation,
      columns: frame.columns,
      rows: frame.rows,
      cursorX: cursor.x,
      cursorY: cursor.y,
      cursorVisible: cursor.visible,
      cursorBlinking: cursor.blinking,
      atBottom: frame.atBottom,
      title: cachedTitle,
      workingDirectory: cachedWorkingDirectory,
      search: search
    )
    publish(snapshot: snapshot)
  }

  private func searchStartOnQueue(_ needle: String) {
    guard let terminal, !needle.isEmpty else {
      return
    }
    do {
      try terminal.searchStart(Data(needle.utf8))
      searchIsActive = true
      try renderAndPublish()
    } catch {
      clearSearchAfterError(error)
    }
  }

  private func searchEndOnQueue() {
    guard let terminal else {
      searchIsActive = false
      return
    }
    do {
      try terminal.searchEnd()
      searchIsActive = false
      try renderAndPublish()
    } catch {
      clearSearchAfterError(error)
    }
  }

  private func searchSelectOnQueue(_ direction: TerminalSearchDirection) {
    guard searchIsActive, let terminal else {
      return
    }
    do {
      _ = try terminal.searchSelect(direction)
      try renderAndPublish()
    } catch {
      clearSearchAfterError(error)
    }
  }

  private func searchState(from terminal: TerminalCore) throws -> TerminalSession.SearchState? {
    guard searchIsActive else {
      return nil
    }
    let status = try terminal.searchStatus()
    let matches = try terminal.searchViewportMatches()
    return TerminalSession.SearchState(status: status, viewportMatches: matches)
  }

  private func clearSearchAfterError(_ error: Error) {
    searchIsActive = false
    handleMouseInteractionError(error)
    guard terminal != nil, frame != nil else {
      return
    }
    try? renderAndPublish()
  }

  private func refreshReportedMetadata(from terminal: TerminalCore) {
    do {
      let report = try terminal.latestTitle()
      if report != lastTitleReport {
        lastTitleReport = report
        let title = report.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedTitle = title.isEmpty ? nil : title
      }
    } catch {
      handleMouseInteractionError(error)
    }

    do {
      let report = try terminal.latestWorkingDirectoryReport()
      if report != lastWorkingDirectoryReport {
        lastWorkingDirectoryReport = report
        cachedWorkingDirectory = Self.workingDirectory(from: report)
      }
    } catch {
      handleMouseInteractionError(error)
    }
  }

  private static func workingDirectory(from report: String) -> URL? {
    guard
      let url = URL(string: report),
      url.scheme == "file",
      !url.path.isEmpty
    else {
      return nil
    }
    return url
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
    searchIsActive = false
    pty = nil
    terminal = nil
    frame = nil
    publish(state: .exited(code: code))
  }

  private func terminate(publishExit: Bool) {
    let ptyForTeardown = pty
    let cancellationGroup = cancelSource()
    searchIsActive = false
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
    searchIsActive = false
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
