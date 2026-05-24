import Darwin
import Foundation

struct DocumentFileFingerprint: Equatable, Sendable {
  let size: UInt64?
  let modificationDate: Date?

  static func load(at url: URL) async -> DocumentFileFingerprint? {
    await Task.detached(priority: .utility) {
      let didStartAccess = url.startAccessingSecurityScopedResource()
      defer {
        if didStartAccess {
          url.stopAccessingSecurityScopedResource()
        }
      }

      guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
      else {
        return nil
      }

      return DocumentFileFingerprint(
        size: values.fileSize.map(UInt64.init),
        modificationDate: values.contentModificationDate
      )
    }.value
  }
}

@MainActor
final class DocumentChangeMonitor: ObservableObject {
  private let debounceDuration: Duration
  private var eventSource: DispatchSourceFileSystemObject?
  private var pendingChangeTask: Task<Void, Never>?
  private var onChange: (@MainActor () -> Void)?
  private var monitoredPath: String?
  private var generation: UInt64 = 0

  init(debounceDuration: Duration = .milliseconds(250)) {
    self.debounceDuration = debounceDuration
  }

  deinit {
    eventSource?.cancel()
    pendingChangeTask?.cancel()
  }

  func startMonitoring(_ fileURL: URL, onChange: @escaping @MainActor () -> Void) {
    let path = fileURL.path(percentEncoded: false)
    guard monitoredPath != path || eventSource == nil else {
      self.onChange = onChange
      return
    }

    stopMonitoring()
    self.onChange = onChange
    monitoredPath = path
    generation &+= 1
    let currentGeneration = generation

    let descriptor = open(path, O_EVTONLY)
    guard descriptor >= 0 else {
      monitoredPath = nil
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .delete, .rename, .extend],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      let shouldReopen = !source.data.isDisjoint(with: [.delete, .rename])
      Task { @MainActor [weak self] in
        self?.scheduleChange(generation: currentGeneration, shouldReopen: shouldReopen)
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }

    eventSource = source
    source.resume()
  }

  func stopMonitoring() {
    generation &+= 1
    pendingChangeTask?.cancel()
    pendingChangeTask = nil
    eventSource?.cancel()
    eventSource = nil
    onChange = nil
    monitoredPath = nil
  }

  private func scheduleChange(generation: UInt64, shouldReopen: Bool) {
    guard generation == self.generation else {
      return
    }

    pendingChangeTask?.cancel()
    let delay = debounceDuration
    pendingChangeTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }

      guard let self, self.generation == generation else {
        return
      }

      if shouldReopen {
        self.reopenCurrentFile()
      }
      self.onChange?()
    }
  }

  private func reopenCurrentFile() {
    guard let monitoredPath, let onChange else {
      return
    }

    eventSource?.cancel()
    eventSource = nil
    self.monitoredPath = nil
    startMonitoring(URL(filePath: monitoredPath), onChange: onChange)
  }
}
