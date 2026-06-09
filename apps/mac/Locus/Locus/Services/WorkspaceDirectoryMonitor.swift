import CoreServices
import Darwin
import Foundation
import OSLog

@MainActor
protocol WorkspaceDirectoryMonitoring: AnyObject {
  func startMonitoring(_ folderURL: URL, onChange: @escaping @MainActor () -> Void)

  func stopMonitoring()
}

@MainActor
final class WorkspaceDirectoryMonitor: WorkspaceDirectoryMonitoring {
  private static let logger = Logger(
    subsystem: "com.nash.locus", category: "WorkspaceDirectoryMonitor")

  private let debounceDuration: Duration
  private var directoryEventSource: DispatchSourceFileSystemObject?
  private var pendingRefreshTask: Task<Void, Never>?
  private var monitorGeneration: UInt64 = 0

  init(
    debounceDuration: Duration = .milliseconds(250)
  ) {
    self.debounceDuration = debounceDuration
  }

  deinit {
    directoryEventSource?.cancel()
    pendingRefreshTask?.cancel()
  }

  func startMonitoring(_ folderURL: URL, onChange: @escaping @MainActor () -> Void) {
    stopMonitoring()
    monitorGeneration &+= 1
    let generation = monitorGeneration

    // DispatchSource file-system monitoring requires a file descriptor;
    // O_EVTONLY avoids requesting read/write access to the directory.
    let descriptor = open(folderURL.path(percentEncoded: false), O_EVTONLY)
    guard descriptor >= 0 else {
      let errorCode = errno
      Self.logger.error(
        "Failed to monitor directory '\(folderURL.path(percentEncoded: false), privacy: .private)': errno \(errorCode)"
      )
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      Task { @MainActor [weak self] in
        self?.scheduleChange(onChange, generation: generation)
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }

    directoryEventSource = source
    source.resume()
  }

  func stopMonitoring() {
    monitorGeneration &+= 1
    pendingRefreshTask?.cancel()
    pendingRefreshTask = nil
    directoryEventSource?.cancel()
    directoryEventSource = nil
  }

  private func scheduleChange(_ onChange: @escaping @MainActor () -> Void, generation: UInt64) {
    guard generation == monitorGeneration else {
      return
    }

    pendingRefreshTask?.cancel()

    let delay = debounceDuration
    pendingRefreshTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }

      guard let self, self.monitorGeneration == generation else {
        return
      }

      onChange()
    }
  }
}

/// Recursively watches a workspace folder tree with FSEvents, so an external
/// change anywhere under the root — at any depth, even while Locus is the active
/// app — can refresh the sidebar. `WorkspaceDirectoryMonitor` only watches the
/// root folder's own entries (a single vnode); this complements it by catching
/// changes inside subfolders. Events the app itself causes are ignored
/// (`kFSEventStreamCreateFlagIgnoreSelf`) because in-app edits already refresh
/// directly, and changes confined to high-churn tool directories (build output,
/// dependency caches, `.git`) are filtered out (Git status is tracked separately).
@MainActor
final class WorkspaceTreeMonitor {
  private static let logger = Logger(
    subsystem: "com.nash.locus", category: "WorkspaceTreeMonitor")
  /// FSEvents coalescing window before the stream delivers a batch.
  private static let latencySeconds = 0.2

  private let debounceDuration: Duration
  private let queue = DispatchQueue(label: "com.nash.locus.workspace-tree-monitor")
  // `nonisolated(unsafe)` so `deinit` can release the stream: it is only set or
  // cleared on the main actor (start/stop) and `deinit` runs after the view is
  // gone, so there is no concurrent access.
  private nonisolated(unsafe) var stream: FSEventStreamRef?
  private var pendingRefreshTask: Task<Void, Never>?
  private var monitorGeneration: UInt64 = 0
  private var onChange: (@MainActor () -> Void)?

  init(debounceDuration: Duration = .milliseconds(250)) {
    self.debounceDuration = debounceDuration
  }

  deinit {
    // Backstop for the app-teardown path where `stopMonitoring()` did not run.
    // No `queue` drain here: `deinit` must not block, and in the normal path
    // `stopMonitoring()` already released the stream, so `stream` is nil and this
    // is a no-op.
    Self.teardown(stream)
    pendingRefreshTask?.cancel()
  }

  func startMonitoring(_ folderURL: URL, onChange: @escaping @MainActor () -> Void) {
    stopMonitoring()
    monitorGeneration &+= 1
    self.onChange = onChange

    // `passUnretained`: the stream does not own `self`. Safe because the host view
    // calls `stopMonitoring()` (onDisappear / re-target) before the monitor can
    // deallocate; that invalidates the stream and drains any in-flight callback off
    // `queue` (see `stopMonitoring`) before releasing it, so no callback reads
    // `self` after it is gone. (An earlier `passRetained` + C release-callback
    // variant crashed: the stream's final Release re-entered `deinit`, which
    // released the same stream again. The drain closes that race without the
    // re-entrancy.)
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags = UInt32(
      kFSEventStreamCreateFlagUseCFTypes
        | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagIgnoreSelf
    )
    let path = folderURL.path(percentEncoded: false)
    guard
      let stream = FSEventStreamCreate(
        kCFAllocatorDefault,
        Self.eventCallback,
        &context,
        [path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        Self.latencySeconds,
        flags
      )
    else {
      Self.logger.error("Failed to create FSEvent stream for '\(path, privacy: .private)'")
      return
    }

    FSEventStreamSetDispatchQueue(stream, queue)
    guard FSEventStreamStart(stream) else {
      // Never started, so do not call Stop; just release the created stream.
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      Self.logger.error("Failed to start FSEvent stream for '\(path, privacy: .private)'")
      return
    }

    self.stream = stream
  }

  func stopMonitoring() {
    monitorGeneration &+= 1
    pendingRefreshTask?.cancel()
    pendingRefreshTask = nil
    if let stream {
      // Tear down with a queue drain so a callback already dispatched onto `queue`
      // cannot read `self` after this monitor deallocates. Order matters:
      //   Stop + Invalidate → the stream schedules no new callback onto `queue`.
      //   queue.sync { }     → wait out any callback already running on the serial
      //                        `queue`. It only bridges the path array and enqueues
      //                        a main-actor Task (never blocks on main), so this
      //                        drain returns promptly and cannot deadlock. `self`
      //                        is still alive here, so that callback's unretained
      //                        read stays valid.
      //   Release            → now safe; no callback can be mid-read.
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      queue.sync {}
      FSEventStreamRelease(stream)
    }
    stream = nil
    onChange = nil
  }

  /// C callback — captures no state. Forwards changed paths to the main actor via
  /// the `self` pointer stashed (unretained) in the stream context.
  private static let eventCallback: FSEventStreamCallback = {
    _, info, numEvents, eventPaths, _, _ in
    guard let info, numEvents > 0 else {
      return
    }

    let monitor = Unmanaged<WorkspaceTreeMonitor>.fromOpaque(info).takeUnretainedValue()
    let paths = (unsafeBitCast(eventPaths, to: NSArray.self) as? [String]) ?? []
    Task { @MainActor in
      monitor.handleChange(paths: paths)
    }
  }

  private func handleChange(paths: [String]) {
    // Ignore batches confined to high-churn, tool-managed trees (build output,
    // dependency caches, Git internals); reloading the sidebar for those is wasted
    // I/O and Git status is tracked separately. Any change outside them still fires.
    guard paths.contains(where: { !Self.isExcludedChurnPath($0) }) else {
      return
    }

    scheduleChange()
  }

  private func scheduleChange() {
    pendingRefreshTask?.cancel()
    let generation = monitorGeneration
    let delay = debounceDuration
    pendingRefreshTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }

      guard let self, self.monitorGeneration == generation else {
        return
      }

      onChange?()
    }
  }

  /// Path components whose subtrees are skipped: high-churn or tool-managed
  /// directories whose changes are not worth reloading the sidebar for (the
  /// editor "watcher exclude" idea). Unambiguous tool directories only, so a
  /// user's own folder named e.g. "build" is still watched.
  private static let excludedPathComponents: Set<String> = [
    ".git", "node_modules", ".build", "DerivedData", ".next", "__pycache__", ".venv",
  ]

  private static func isExcludedChurnPath(_ path: String) -> Bool {
    path.split(separator: "/").contains { excludedPathComponents.contains(String($0)) }
  }

  // `nonisolated` so `deinit` (a nonisolated context) can tear the stream down;
  // it touches only the passed FSEvents stream, never actor-isolated state.
  private nonisolated static func teardown(_ stream: FSEventStreamRef?) {
    guard let stream else {
      return
    }

    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }
}
