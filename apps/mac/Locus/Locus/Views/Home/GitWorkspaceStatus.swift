import Darwin
import Foundation
import OSLog

enum GitWorkspaceChangeKind: Equatable, Sendable {
  case modified
  case added
}

protocol GitWorkspaceStatusProviding: Sendable {
  func sidebarStatuses(for workspaceURL: URL) async -> [String: GitWorkspaceChangeKind]
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

  func sidebarStatuses(for workspaceURL: URL) async -> [String: GitWorkspaceChangeKind] {
    do {
      let output = try await gitStatusOutput(for: workspaceURL)
      let changes = GitStatusParser.parsePorcelainZ(output)
      return GitSidebarStatusAggregator.statuses(for: changes, workspaceURL: workspaceURL)
    } catch is CancellationError {
      return [:]
    } catch {
      Self.logger.debug(
        "Skipping Git sidebar status for '\(workspaceURL.locusStandardizedPath, privacy: .private)': \(String(describing: error), privacy: .public)"
      )
      return [:]
    }
  }

  private func gitStatusOutput(for workspaceURL: URL) async throws -> Data {
    try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask(priority: .utility) {
        try Self.gitStatusOutputSync(
          for: workspaceURL,
          gitExecutableURL: gitExecutableURL,
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

  private static func gitStatusOutputSync(
    for workspaceURL: URL,
    gitExecutableURL: URL,
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
    process.arguments = [
      "-C",
      workspaceURL.locusStandardizedPath,
      "status",
      "--porcelain=v1",
      "-z",
      "--untracked-files=all",
      "--",
      ".",
    ]

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
    workspaceURL: URL
  ) -> [String: GitWorkspaceChangeKind] {
    let workspacePath = workspaceURL.locusStandardizedPath
    var statuses: [String: GitWorkspaceChangeKind] = [:]

    for change in changes {
      let relativePath = change.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      guard !relativePath.isEmpty else {
        continue
      }

      let components = relativePath.split(separator: "/").map(String.init)
      guard !components.isEmpty else {
        continue
      }
      guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
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
    guard statuses[path] != .added else {
      return
    }

    statuses[path] = kind
  }

  private static func appending(_ component: String, to path: String) -> String {
    path == "/" ? "/\(component)" : "\(path)/\(component)"
  }
}
