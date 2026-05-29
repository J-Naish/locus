import Foundation
import os

struct WorkspaceDeletedItem: Equatable, Sendable {
  let originalURL: URL
  let trashedURL: URL
}

enum WorkspaceItemDeletionError: LocalizedError, Equatable {
  case noActiveWorkspace
  case cannotDeleteWorkspaceRoot
  case outsideWorkspace
  case deleteFailed(String)
  case partiallyDeleted(
    succeededItems: [WorkspaceDeletedItem], failedName: String, remainingCount: Int)

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
    case .partiallyDeleted(let succeededItems, let failedName, let remainingCount):
      return
        "Moved \(succeededItems.count) item(s) to the Trash, but couldn't move '\(failedName)'. \(remainingCount) item(s) were not moved."
    }
  }
}

enum WorkspaceItemDeletion {
  typealias MoveToTrash = (URL) throws -> URL
  private static let logger = Logger(subsystem: "com.nash.locus", category: "WorkspaceItemDeletion")

  static func undoActionName(for items: [WorkspaceDeletedItem]) -> String {
    items.count == 1 ? "Delete Item" : "Delete Items"
  }

  static func delete(
    _ entries: [WorkspaceEntry],
    in workspaceURL: URL,
    moveToTrash: MoveToTrash = defaultMoveToTrash
  ) throws -> [WorkspaceDeletedItem] {
    let targets = try deletionTargets(for: entries, workspaceURL: workspaceURL)
    return try deleteTargets(targets, moveToTrash: moveToTrash)
  }

  static func deleteURLs(
    _ urls: [URL],
    in workspaceURL: URL,
    moveToTrash: MoveToTrash = defaultMoveToTrash
  ) throws -> [WorkspaceDeletedItem] {
    let targets = try deletionTargets(for: urls, workspaceURL: workspaceURL)
    return try deleteTargets(targets, moveToTrash: moveToTrash)
  }

  private static func deleteTargets(
    _ targets: [URL],
    moveToTrash: MoveToTrash
  ) throws -> [WorkspaceDeletedItem] {
    var deletedItems: [WorkspaceDeletedItem] = []
    for (index, target) in targets.enumerated() {
      do {
        let trashedURL = try moveToTrash(target)
        deletedItems.append(WorkspaceDeletedItem(originalURL: target, trashedURL: trashedURL))
      } catch {
        logger.error(
          "trashItem failed for '\(target.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
        let remainingCount = targets.count - index - 1
        if deletedItems.isEmpty {
          throw WorkspaceItemDeletionError.deleteFailed(target.lastPathComponent)
        }

        throw WorkspaceItemDeletionError.partiallyDeleted(
          succeededItems: deletedItems,
          failedName: target.lastPathComponent,
          remainingCount: remainingCount
        )
      }
    }
    return deletedItems
  }

  private static func deletionTargets(
    for entries: [WorkspaceEntry],
    workspaceURL: URL
  ) throws -> [URL] {
    try deletionTargets(for: entries.map(\.url), workspaceURL: workspaceURL)
  }

  private static func deletionTargets(
    for urls: [URL],
    workspaceURL: URL
  ) throws -> [URL] {
    let workspacePath = workspaceURL.locusStandardizedPath
    var seenPaths = Set<String>()
    var targets: [URL] = []

    for url in urls {
      let path = url.locusStandardizedPath
      guard path != workspacePath else {
        throw WorkspaceItemDeletionError.cannotDeleteWorkspaceRoot
      }
      guard path.locusHasPathPrefix(workspacePath) else {
        throw WorkspaceItemDeletionError.outsideWorkspace
      }
      guard seenPaths.insert(path).inserted else {
        continue
      }
      targets.append(url)
    }

    return targets
  }

  private static func defaultMoveToTrash(_ url: URL) throws -> URL {
    var resultingURL: NSURL?
    try FileManager.default.trashItem(
      at: url,
      resultingItemURL: &resultingURL
    )
    return (resultingURL as URL?) ?? url
  }
}

enum WorkspaceItemRestorationError: LocalizedError, Equatable {
  case restoreFailed(String)
  case partiallyRestored(succeededURLs: [URL], failedName: String, remainingCount: Int)

  var errorDescription: String? {
    switch self {
    case .restoreFailed(let name):
      return "Locus couldn't restore '\(name)'."
    case .partiallyRestored(let succeededURLs, let failedName, let remainingCount):
      return
        "Restored \(succeededURLs.count) item(s), but couldn't restore '\(failedName)'. \(remainingCount) item(s) were not restored."
    }
  }
}

enum WorkspaceItemRestoration {
  typealias MoveFromTrash = (URL, URL) throws -> Void
  private static let logger = Logger(
    subsystem: "com.nash.locus", category: "WorkspaceItemRestoration")

  static func restore(
    _ items: [WorkspaceDeletedItem],
    moveFromTrash: MoveFromTrash = defaultMoveFromTrash
  ) throws -> [URL] {
    var restoredURLs: [URL] = []
    for (index, item) in items.enumerated() {
      do {
        try moveFromTrash(item.trashedURL, item.originalURL)
        restoredURLs.append(item.originalURL)
      } catch {
        logger.error(
          "restore failed for '\(item.originalURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
        let remainingCount = items.count - index - 1
        if restoredURLs.isEmpty {
          throw WorkspaceItemRestorationError.restoreFailed(item.originalURL.lastPathComponent)
        }

        throw WorkspaceItemRestorationError.partiallyRestored(
          succeededURLs: restoredURLs,
          failedName: item.originalURL.lastPathComponent,
          remainingCount: remainingCount
        )
      }
    }
    return restoredURLs
  }

  private static func defaultMoveFromTrash(_ trashURL: URL, _ originalURL: URL) throws {
    try FileManager.default.moveItem(at: trashURL, to: originalURL)
  }
}
