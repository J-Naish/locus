import Darwin
import Foundation
import OSLog

enum GitWorkspaceChangeKind: Equatable, Sendable {
  case modified
  case added
}

protocol GitWorkspaceStatusProviding: Sendable {
  func sidebarStatuses(
    for workspaceURL: URL,
    repositoryRootURL: URL?
  ) async -> [String: GitWorkspaceChangeKind]

  func repositoryMetadata(for workspaceURL: URL) async -> GitRepositoryMetadata?
}

struct GitRepositoryMetadata: Equatable, Sendable {
  let gitDirectoryURL: URL
  let commonDirectoryURL: URL
  let workTreeURL: URL
}

struct GitWorkspaceStatusProvider: GitWorkspaceStatusProviding {
  private enum Defaults {
    static let statusTimeout: TimeInterval = 2
  }

  private static let logger = Logger(subsystem: "com.nash.locus", category: "GitWorkspaceStatus")

  private let gitExecutableURL: URL
  private let statusTimeout: TimeInterval

  init(
    gitExecutableURL: URL = URL(filePath: "/usr/bin/git"),
    statusTimeout: TimeInterval = Defaults.statusTimeout
  ) {
    self.gitExecutableURL = gitExecutableURL
    self.statusTimeout = statusTimeout
  }

  func sidebarStatuses(
    for workspaceURL: URL,
    repositoryRootURL: URL? = nil
  ) async -> [String: GitWorkspaceChangeKind] {
    do {
      let output = try await gitOutput(
        for: workspaceURL,
        arguments: [
          "-C",
          workspaceURL.locusStandardizedPath,
          "status",
          "--porcelain=v1",
          "-z",
          "--untracked-files=all",
          "--",
          ".",
        ]
      )
      let changes = GitStatusParser.parsePorcelainZ(output)
      return GitSidebarStatusAggregator.statuses(
        for: changes,
        workspaceURL: workspaceURL,
        repositoryRootURL: repositoryRootURL ?? workspaceURL
      )
    } catch is CancellationError {
      return [:]
    } catch {
      Self.logger.debug(
        "Skipping Git sidebar status for '\(workspaceURL.locusStandardizedPath, privacy: .private)': \(String(describing: error), privacy: .public)"
      )
      return [:]
    }
  }

  func repositoryMetadata(for workspaceURL: URL) async -> GitRepositoryMetadata? {
    do {
      let output = try await gitOutput(
        for: workspaceURL,
        arguments: [
          "-C",
          workspaceURL.locusStandardizedPath,
          "rev-parse",
          "--absolute-git-dir",  // lines[0]
          "--git-common-dir",  // lines[1]
          "--show-toplevel",  // lines[2]
        ]
      )
      return GitRepositoryMetadataParser.parse(output, workspaceURL: workspaceURL)
    } catch is CancellationError {
      return nil
    } catch {
      Self.logger.debug(
        "Skipping Git metadata monitor for '\(workspaceURL.locusStandardizedPath, privacy: .private)': \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private func gitOutput(for workspaceURL: URL, arguments: [String]) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask(priority: .utility) {
        try Self.gitOutputSync(
          gitExecutableURL: gitExecutableURL,
          arguments: arguments,
          timeout: statusTimeout,
          isCancelled: { Task.isCancelled }
        )
      }

      guard let output = try await group.next() else {
        throw CancellationError()
      }

      return output
    }
  }

  private static func gitOutputSync(
    gitExecutableURL: URL,
    arguments: [String],
    timeout: TimeInterval,
    isCancelled: () -> Bool
  ) throws -> Data {
    let temporaryDirectory = FileManager.default.temporaryDirectory
      .appending(path: "LocusGitStatus-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: temporaryDirectory, withIntermediateDirectories: false)
    defer {
      try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    let outputURL = temporaryDirectory.appending(path: "stdout")
    let errorURL = temporaryDirectory.appending(path: "stderr")
    try Data().write(to: outputURL, options: .withoutOverwriting)
    try Data().write(to: errorURL, options: .withoutOverwriting)

    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
      try? outputHandle.close()
      try? errorHandle.close()
    }

    let process = Process()
    process.executableURL = gitExecutableURL
    process.arguments = arguments

    process.standardOutput = outputHandle
    process.standardError = errorHandle

    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning {
      if isCancelled() {
        terminateProcess(process)
        throw CancellationError()
      }

      if Date() >= deadline {
        terminateProcess(process)
        throw GitWorkspaceStatusError.timedOut
      }

      Thread.sleep(forTimeInterval: 0.025)
    }

    guard process.terminationStatus == 0 else {
      throw GitWorkspaceStatusError.statusFailed(process.terminationStatus)
    }

    try? outputHandle.close()
    try? errorHandle.close()

    return try Data(contentsOf: outputURL)
  }

  private static func terminateProcess(_ process: Process) {
    process.terminate()

    let deadline = Date().addingTimeInterval(0.25)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }

    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
    }

    process.waitUntilExit()
  }
}

enum GitRepositoryMetadataParser {
  static func parse(_ data: Data, workspaceURL: URL) -> GitRepositoryMetadata? {
    guard let output = String(data: data, encoding: .utf8) else {
      return nil
    }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    guard lines.count >= 3 else {
      return nil
    }

    let gitDirectoryURL = resolveGitPath(lines[0], relativeTo: workspaceURL)
    let commonDirectoryURL = resolveGitPath(lines[1], relativeTo: workspaceURL)
    let workTreeURL = resolveGitPath(lines[2], relativeTo: workspaceURL)
    return GitRepositoryMetadata(
      gitDirectoryURL: gitDirectoryURL,
      commonDirectoryURL: commonDirectoryURL,
      workTreeURL: workTreeURL
    )
  }

  private static func resolveGitPath(_ path: String, relativeTo workspaceURL: URL) -> URL {
    if path.hasPrefix("/") {
      return URL(filePath: path).standardizedFileURL
    }

    return workspaceURL.appending(path: path).standardizedFileURL
  }
}

enum GitRepositoryMetadataChange: Equatable, Sendable {
  case statusOnly
  case metadataChanged
}

@MainActor
final class GitRepositoryMetadataMonitor {
  private let debounceDuration: Duration
  private var eventSources: [DispatchSourceFileSystemObject] = []
  private var pendingRefreshTask: Task<Void, Never>?
  private var pendingChange: GitRepositoryMetadataChange?
  private var monitorGeneration: UInt64 = 0
  private var currentMetadata: GitRepositoryMetadata?
  private var currentMonitoredPaths: Set<String> = []

  init(debounceDuration: Duration = .milliseconds(250)) {
    self.debounceDuration = debounceDuration
  }

  func startMonitoring(
    _ metadata: GitRepositoryMetadata,
    onChange: @escaping @MainActor (GitRepositoryMetadataChange) -> Void
  ) {
    let urls = monitoredURLs(for: metadata)
    let monitoredPaths = Set(urls.map(\.locusStandardizedPath))
    guard metadata != currentMetadata || monitoredPaths != currentMonitoredPaths else {
      return
    }

    stopMonitoring()
    monitorGeneration &+= 1
    let generation = monitorGeneration
    currentMetadata = metadata
    currentMonitoredPaths = monitoredPaths

    for url in urls {
      startMonitoring(
        url,
        generation: generation,
        changeKind: changeKind(for: url, metadata: metadata),
        onChange: onChange
      )
    }
  }

  func stopMonitoring() {
    monitorGeneration &+= 1
    pendingRefreshTask?.cancel()
    pendingRefreshTask = nil
    pendingChange = nil
    currentMetadata = nil
    currentMonitoredPaths = []
    for eventSource in eventSources {
      eventSource.cancel()
    }
    eventSources = []
  }

  private func startMonitoring(
    _ url: URL,
    generation: UInt64,
    changeKind: GitRepositoryMetadataChange,
    onChange: @escaping @MainActor (GitRepositoryMetadataChange) -> Void
  ) {
    let descriptor = open(url.path(percentEncoded: false), O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      return
    }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .delete, .rename],
      queue: .main
    )
    source.setEventHandler { [weak self] in
      Task { @MainActor [weak self] in
        self?.scheduleChange(changeKind, onChange: onChange, generation: generation)
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }

    eventSources.append(source)
    source.resume()
  }

  private func scheduleChange(
    _ changeKind: GitRepositoryMetadataChange,
    onChange: @escaping @MainActor (GitRepositoryMetadataChange) -> Void,
    generation: UInt64
  ) {
    guard generation == monitorGeneration else {
      return
    }

    pendingChange = pendingChange?.merged(with: changeKind) ?? changeKind
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

      let change = self.pendingChange ?? .statusOnly
      self.pendingChange = nil
      onChange(change)
    }
  }

  private func monitoredURLs(for metadata: GitRepositoryMetadata) -> [URL] {
    // Work tree file changes are handled by WorkspaceDirectoryMonitor; this
    // monitor only tracks Git metadata that can change status meaning.
    var candidateURLs = [
      metadata.gitDirectoryURL,
      metadata.commonDirectoryURL,
      metadata.gitDirectoryURL.appending(path: "HEAD"),
      metadata.gitDirectoryURL.appending(path: "index"),
      metadata.gitDirectoryURL.appending(path: "refs", directoryHint: .isDirectory),
      metadata.gitDirectoryURL.appending(path: "refs/heads", directoryHint: .isDirectory),
      metadata.gitDirectoryURL.appending(path: "refs/tags", directoryHint: .isDirectory),
      metadata.commonDirectoryURL.appending(path: "HEAD"),
      metadata.commonDirectoryURL.appending(path: "index"),
      metadata.commonDirectoryURL.appending(path: "packed-refs"),
      metadata.commonDirectoryURL.appending(path: "refs", directoryHint: .isDirectory),
      metadata.commonDirectoryURL.appending(path: "refs/heads", directoryHint: .isDirectory),
      metadata.commonDirectoryURL.appending(path: "refs/tags", directoryHint: .isDirectory),
    ]

    if let headReferenceURL = currentHeadReferenceURL(for: metadata) {
      candidateURLs.append(headReferenceURL)
    }

    var seen: Set<String> = []
    var urls: [URL] = []
    for url in candidateURLs {
      let path = url.locusStandardizedPath
      guard seen.insert(path).inserted else {
        continue
      }
      guard FileManager.default.fileExists(atPath: path) else {
        continue
      }
      urls.append(url)
    }

    return urls
  }

  private func currentHeadReferenceURL(for metadata: GitRepositoryMetadata) -> URL? {
    let headURL = metadata.gitDirectoryURL.appending(path: "HEAD")
    guard let head = try? String(contentsOf: headURL, encoding: .utf8) else {
      return nil
    }

    let prefix = "ref: "
    guard head.hasPrefix(prefix) else {
      return nil
    }

    let referencePath = head.dropFirst(prefix.count)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard referencePath.hasPrefix("refs/"), !referencePath.contains("..") else {
      return nil
    }

    return metadata.commonDirectoryURL.appending(path: referencePath)
  }

  private func changeKind(
    for url: URL,
    metadata: GitRepositoryMetadata
  ) -> GitRepositoryMetadataChange {
    let path = url.locusStandardizedPath
    let metadataPaths: Set<String> = [
      metadata.gitDirectoryURL.locusStandardizedPath,
      metadata.commonDirectoryURL.locusStandardizedPath,
      metadata.gitDirectoryURL.appending(path: "HEAD").locusStandardizedPath,
      metadata.gitDirectoryURL.appending(path: "refs", directoryHint: .isDirectory)
        .locusStandardizedPath,
      metadata.gitDirectoryURL.appending(path: "refs/heads", directoryHint: .isDirectory)
        .locusStandardizedPath,
      metadata.gitDirectoryURL.appending(path: "refs/tags", directoryHint: .isDirectory)
        .locusStandardizedPath,
      metadata.commonDirectoryURL.appending(path: "refs", directoryHint: .isDirectory)
        .locusStandardizedPath,
      metadata.commonDirectoryURL.appending(path: "refs/heads", directoryHint: .isDirectory)
        .locusStandardizedPath,
      metadata.commonDirectoryURL.appending(path: "refs/tags", directoryHint: .isDirectory)
        .locusStandardizedPath,
    ]

    return metadataPaths.contains(path) ? .metadataChanged : .statusOnly
  }
}

extension GitRepositoryMetadataChange {
  fileprivate func merged(with other: GitRepositoryMetadataChange) -> GitRepositoryMetadataChange {
    switch (self, other) {
    case (.metadataChanged, _), (_, .metadataChanged):
      return .metadataChanged
    case (.statusOnly, .statusOnly):
      return .statusOnly
    }
  }
}

enum GitWorkspaceStatusError: Error, Equatable {
  case statusFailed(Int32)
  case timedOut
}

struct GitStatusChange: Equatable, Sendable {
  let path: String
  let kind: GitWorkspaceChangeKind
}

enum GitStatusParser {
  static func parsePorcelainZ(_ data: Data) -> [GitStatusChange] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: true)
    var changes: [GitStatusChange] = []
    var index = fields.startIndex

    while index < fields.endIndex {
      let field = fields[index]
      index = fields.index(after: index)

      guard field.count >= 4 else {
        continue
      }

      let status = String(decoding: field.prefix(2), as: UTF8.self)
      let pathBytes = field.dropFirst(3)
      let path = String(decoding: pathBytes, as: UTF8.self)
      guard !path.isEmpty else {
        continue
      }

      changes.append(GitStatusChange(path: path, kind: changeKind(for: status)))

      if (status.hasPrefix("R") || status.hasPrefix("C")) && index < fields.endIndex {
        // Porcelain -z emits the original path as the next NUL-delimited field.
        index = fields.index(after: index)
      }
    }

    return changes
  }

  private static func changeKind(for status: String) -> GitWorkspaceChangeKind {
    if status == "??" || status.contains("A") {
      return .added
    }

    return .modified
  }
}

enum GitSidebarStatusAggregator {
  static func statuses(
    for changes: [GitStatusChange],
    workspaceURL: URL,
    repositoryRootURL: URL
  ) -> [String: GitWorkspaceChangeKind] {
    let workspacePath = workspaceURL.locusStandardizedPath
    let repositoryRootPath = repositoryRootURL.locusStandardizedPath
    guard
      let workspacePrefixComponents = workspacePrefixComponents(
        repositoryRootPath: repositoryRootPath,
        workspacePath: workspacePath
      )
    else {
      return [:]
    }

    var statuses: [String: GitWorkspaceChangeKind] = [:]

    for change in changes {
      guard
        let components = workspaceRelativeComponents(
          forRepositoryRelativePath: change.path,
          workspacePrefixComponents: workspacePrefixComponents
        )
      else {
        continue
      }

      var accumulated = workspacePath
      for component in components {
        accumulated = appending(component, to: accumulated)
        merge(change.kind, into: &statuses, at: accumulated)
      }
    }

    return statuses
  }

  private static func merge(
    _ kind: GitWorkspaceChangeKind,
    into statuses: inout [String: GitWorkspaceChangeKind],
    at path: String
  ) {
    guard let current = statuses[path] else {
      statuses[path] = kind
      return
    }

    // Folder aggregation follows VS Code's visual priority: a tracked-file edit
    // is more salient than a newly introduced sibling, so modified wins over added.
    if priority(of: kind) > priority(of: current) {
      statuses[path] = kind
    }
  }

  private static func priority(of kind: GitWorkspaceChangeKind) -> Int {
    switch kind {
    case .modified:
      return 2
    case .added:
      return 1
    }
  }

  private static func appending(_ component: String, to path: String) -> String {
    path == "/" ? "/\(component)" : "\(path)/\(component)"
  }

  private static func workspaceRelativeComponents(
    forRepositoryRelativePath path: String,
    workspacePrefixComponents: [String]
  ) -> [String]? {
    let repositoryRelativePath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard !repositoryRelativePath.isEmpty else {
      return nil
    }

    let components = repositoryRelativePath.split(separator: "/").map(String.init)
    guard !components.isEmpty else {
      return nil
    }
    guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
      return nil
    }
    guard components.count > workspacePrefixComponents.count else {
      return nil
    }

    for (index, prefixComponent) in workspacePrefixComponents.enumerated() {
      guard components[index] == prefixComponent else {
        return nil
      }
    }

    let workspaceComponents = components.dropFirst(workspacePrefixComponents.count)
    return workspaceComponents.isEmpty ? nil : Array(workspaceComponents)
  }

  private static func workspacePrefixComponents(
    repositoryRootPath: String,
    workspacePath: String
  ) -> [String]? {
    guard workspacePath != repositoryRootPath else {
      return []
    }
    guard workspacePath.locusHasPathPrefix(repositoryRootPath) else {
      return nil
    }

    let prefix = repositoryRootPath == "/" ? "/" : repositoryRootPath + "/"
    guard workspacePath.hasPrefix(prefix) else {
      return nil
    }

    let workspaceRelativePath = String(workspacePath.dropFirst(prefix.count))
    let components = workspaceRelativePath.split(separator: "/").map(String.init)
    return components.isEmpty ? nil : components
  }
}
