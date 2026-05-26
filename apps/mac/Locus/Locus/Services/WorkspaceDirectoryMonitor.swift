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
      Task { @MainActor in
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
