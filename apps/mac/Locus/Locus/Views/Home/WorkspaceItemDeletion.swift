import Foundation
import os

enum WorkspaceItemDeletionError: LocalizedError, Equatable {
  case noActiveWorkspace
  case cannotDeleteWorkspaceRoot
  case outsideWorkspace
  case deleteFailed(String)
  case partiallyDeleted(succeededURLs: [URL], failedName: String, remainingCount: Int)

  var errorDescription: String? {
    switch self {
    case .noActiveWorkspace:
      return "No folder is open."
    case .cannotDeleteWorkspaceRoot:
      return "The workspace folder can't be deleted from Locus."
    case .outsideWorkspace:
      return "The item is outside the open folder."
    case .deleteFailed(let name):
      return "Locus couldn't move '\(name)' to the Trash."
    case .partiallyDeleted(let succeededURLs, let failedName, let remainingCount):
      return
        "Moved \(succeededURLs.count) item(s) to the Trash, but couldn't move '\(failedName)'. \(remainingCount) item(s) were not moved."
    }
  }
}

enum WorkspaceItemDeletion {
  typealias MoveToTrash = (URL) throws -> Void
  private static let logger = Logger(subsystem: "com.nash.locus", category: "WorkspaceItemDeletion")

  static func delete(
    _ entries: [WorkspaceEntry],
    in workspaceURL: URL,
    moveToTrash: MoveToTrash = defaultMoveToTrash
  ) throws -> [URL] {
    let targets = try deletionTargets(for: entries, workspaceURL: workspaceURL)
    var deletedURLs: [URL] = []
    for (index, target) in targets.enumerated() {
      do {
        try moveToTrash(target)
        deletedURLs.append(target)
      } catch {
        logger.error(
          "trashItem failed for '\(target.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
        let remainingCount = targets.count - index - 1
        if deletedURLs.isEmpty {
          throw WorkspaceItemDeletionError.deleteFailed(target.lastPathComponent)
        }

        throw WorkspaceItemDeletionError.partiallyDeleted(
          succeededURLs: deletedURLs,
          failedName: target.lastPathComponent,
          remainingCount: remainingCount
        )
      }
    }
    return deletedURLs
  }

  private static func deletionTargets(
    for entries: [WorkspaceEntry],
    workspaceURL: URL
  ) throws -> [URL] {
    let workspacePath = workspaceURL.locusStandardizedPath
    var seenPaths = Set<String>()
    var targets: [URL] = []

    for entry in entries {
      let path = entry.url.locusStandardizedPath
      guard path != workspacePath else {
        throw WorkspaceItemDeletionError.cannotDeleteWorkspaceRoot
      }
      guard path.locusHasPathPrefix(workspacePath) else {
        throw WorkspaceItemDeletionError.outsideWorkspace
      }
      guard seenPaths.insert(path).inserted else {
        continue
      }
      targets.append(entry.url)
    }

    return targets
  }

  private static func defaultMoveToTrash(_ url: URL) throws {
    var resultingURL: NSURL?
    try FileManager.default.trashItem(
      at: url,
      resultingItemURL: &resultingURL
    )
  }
}
