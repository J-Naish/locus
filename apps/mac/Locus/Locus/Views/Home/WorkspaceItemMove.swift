import Foundation
import os

/// A planned move/copy operation resolved to concrete source and destination
/// URLs. Path-only value type so it can be computed and inspected (for
/// collision detection) before any file system mutation happens.
/// `replacesExisting` is set when the user chose to replace an item already at
/// `destinationURL`; the executor trashes that item immediately before the
/// move/copy so the operation can be undone.
struct WorkspacePlannedMove: Equatable, Sendable {
  let sourceURL: URL
  let destinationURL: URL
  var replacesExisting = false
}

/// Records a completed move so the operation can be reversed for undo by moving
/// `newURL` back to `originalURL`.
struct WorkspaceMovedItem: Equatable, Sendable {
  let originalURL: URL
  let newURL: URL
}

/// Outcome of executing a batch of planned moves/copies. Each item is performed
/// atomically with its own replacement: if a single item fails, only that item
/// is rolled back (its replaced destination is restored) and the batch stops,
/// so `moved`/`replacedTrashed` always describe state that actually landed on
/// disk. This lets the caller register undo for the successful part even when a
/// later item fails.
struct WorkspaceMoveExecution: Equatable, Sendable {
  var moved: [WorkspaceMovedItem] = []
  var replacedTrashed: [WorkspaceDeletedItem] = []
  var failure: WorkspaceItemMoveError?
}

enum WorkspaceItemMoveError: LocalizedError, Equatable {
  case noActiveWorkspace
  case outsideWorkspace
  case cannotMoveWorkspaceRoot
  case moveIntoSelf
  case nameCollision(String)
  case moveFailed(String)

  var errorDescription: String? {
    switch self {
    case .noActiveWorkspace:
      return "No folder is open."
    case .outsideWorkspace:
      return "The item is outside the open folder."
    case .cannotMoveWorkspaceRoot:
      return "The workspace folder can't be moved from Locus."
    case .moveIntoSelf:
      return "A folder can't be moved into itself."
    case .nameCollision(let name):
      return "'\(name)' already exists in the destination folder."
    case .moveFailed(let name):
      return "Locus couldn't move '\(name)'."
    }
  }
}

enum WorkspaceItemMove {
  typealias MoveItem = (URL, URL) throws -> Void
  typealias CopyItem = (URL, URL) throws -> Void
  /// Moves a destination item to the Trash and returns its Trash URL.
  typealias TrashItem = (URL) throws -> URL
  /// Restores a previously trashed item back to its original URL.
  typealias RestoreItem = (URL, URL) throws -> Void
  private static let logger = Logger(subsystem: "com.nash.locus", category: "WorkspaceItemMove")

  static func undoActionName(for items: [WorkspaceMovedItem]) -> String {
    items.count == 1 ? "Move Item" : "Move Items"
  }

  static func importActionName(for items: [WorkspaceMovedItem]) -> String {
    items.count == 1 ? "Add Item" : "Add Items"
  }

  /// Splits dropped URLs into those that physically live inside `workspaceURL`
  /// (an internal move) and those that do not (an external import/copy).
  ///
  /// Intermediate path components are resolved through symlinks before the
  /// comparison, so a URL that only *lexically* sits under the workspace — for
  /// example one reached through a symlinked directory that points elsewhere —
  /// is treated as external instead of being moved as if it were a local item.
  /// The final path component is left unresolved so a dragged symlink file is
  /// classified by where the link itself lives, not by its target. Both sides
  /// are resolved the same way, so a workspace reached through a symlink (such
  /// as macOS `/var` -> `/private/var`) still classifies its own children as
  /// internal.
  static func partitionByWorkspace(
    _ urls: [URL],
    workspaceURL: URL
  ) -> (internalURLs: [URL], externalURLs: [URL]) {
    let workspacePath = workspaceURL.locusResolvedPath
    var internalURLs: [URL] = []
    var externalURLs: [URL] = []
    for url in urls {
      if url.locusResolvedParentPath.locusHasPathPrefix(workspacePath) {
        internalURLs.append(url)
      } else {
        externalURLs.append(url)
      }
    }
    return (internalURLs, externalURLs)
  }

  /// Validates source URLs against the workspace and target folder and returns
  /// the concrete (source, destination) pairs to perform. Pure path logic with
  /// no file system access, so it is safe to run before showing collision UI.
  ///
  /// - Drops no-ops (an item already living directly in `target`).
  /// - Rejects moving the workspace root, items outside the workspace, and
  ///   moving a folder into itself or one of its descendants (loop guard).
  /// - Deduplicates repeated sources.
  static func plannedMoves(
    for sources: [URL],
    into target: URL,
    workspaceURL: URL
  ) throws -> [WorkspacePlannedMove] {
    // Symlinks are resolved consistently so a symlinked directory cannot move
    // items outside the workspace while looking lexically internal: the
    // destination folder is resolved fully (a write into it lands on its real
    // target) and each source by its parent (the move acts on the entry itself).
    let workspacePath = workspaceURL.locusResolvedPath
    let targetPath = target.locusResolvedPath

    guard targetPath.locusHasPathPrefix(workspacePath) else {
      throw WorkspaceItemMoveError.outsideWorkspace
    }

    var seenPaths = Set<String>()
    var planned: [WorkspacePlannedMove] = []

    for source in sources {
      let sourcePath = source.locusResolvedParentPath

      guard sourcePath != workspacePath else {
        throw WorkspaceItemMoveError.cannotMoveWorkspaceRoot
      }
      guard sourcePath.locusHasPathPrefix(workspacePath) else {
        throw WorkspaceItemMoveError.outsideWorkspace
      }
      // Loop guard: target must not be the source itself or a descendant of it.
      // locusHasPathPrefix is true when target == source or target is inside it.
      guard !targetPath.locusHasPathPrefix(sourcePath) else {
        throw WorkspaceItemMoveError.moveIntoSelf
      }
      // No-op: the item already lives directly inside the target folder.
      if source.deletingLastPathComponent().locusResolvedPath == targetPath {
        continue
      }
      guard seenPaths.insert(sourcePath).inserted else {
        continue
      }

      planned.append(
        WorkspacePlannedMove(
          sourceURL: source,
          destinationURL: destinationURL(for: source, in: target)
        )
      )
    }

    return planned
  }

  /// Plans copies of external (drag-and-drop import) sources into the target
  /// folder. Unlike `plannedMoves`, sources are expected to live outside the
  /// workspace, so only the target is validated against the workspace. Non-file
  /// URLs are treated as untrusted input and skipped.
  static func plannedImports(
    for sources: [URL],
    into target: URL,
    workspaceURL: URL
  ) throws -> [WorkspacePlannedMove] {
    // Resolve symlinks so the destination cannot land outside the workspace
    // through a symlinked directory (see `plannedMoves`). Sources are expected
    // to be external, so only the target is validated.
    let workspacePath = workspaceURL.locusResolvedPath
    let targetPath = target.locusResolvedPath

    guard targetPath.locusHasPathPrefix(workspacePath) else {
      throw WorkspaceItemMoveError.outsideWorkspace
    }

    var seenPaths = Set<String>()
    var planned: [WorkspacePlannedMove] = []

    for source in sources {
      guard source.isFileURL else {
        continue
      }
      let sourcePath = source.locusStandardizedPath
      guard seenPaths.insert(sourcePath).inserted else {
        continue
      }

      planned.append(
        WorkspacePlannedMove(
          sourceURL: source,
          destinationURL: destinationURL(for: source, in: target)
        )
      )
    }

    return planned
  }

  static func destinationURL(for source: URL, in target: URL) -> URL {
    target.appending(path: source.lastPathComponent)
  }

  /// Finder-style disambiguation: returns the first available "name N.ext"
  /// (starting at 2) when `url` already exists. `exists` is injected so the
  /// rule can be unit tested without touching the file system.
  static func disambiguatedURL(for url: URL, exists: (URL) -> Bool) -> URL {
    guard exists(url) else {
      return url
    }

    let directory = url.deletingLastPathComponent()
    let pathExtension = url.pathExtension
    let baseName = url.deletingPathExtension().lastPathComponent

    var counter = 2
    while true {
      let candidateName =
        pathExtension.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(pathExtension)"
      let candidate = directory.appending(path: candidateName)
      if !exists(candidate) {
        return candidate
      }
      counter += 1
    }
  }

  /// Performs the planned moves, one item at a time. For a plan marked
  /// `replacesExisting`, the destination item is trashed immediately before the
  /// move; if that move then fails, the trashed item is restored so it is never
  /// silently lost. The batch stops at the first failure and reports the
  /// successful part plus the failure.
  static func move(
    _ planned: [WorkspacePlannedMove],
    moveItem: MoveItem = defaultMoveItem,
    trashItem: TrashItem = defaultTrashItem,
    restoreItem: RestoreItem = defaultRestoreItem
  ) -> WorkspaceMoveExecution {
    perform(planned, operation: moveItem, trashItem: trashItem, restoreItem: restoreItem)
  }

  /// Performs the planned copies (drag-and-drop import), one item at a time,
  /// with the same per-item replacement and rollback behavior as `move`.
  static func copy(
    _ planned: [WorkspacePlannedMove],
    copyItem: CopyItem = defaultCopyItem,
    trashItem: TrashItem = defaultTrashItem,
    restoreItem: RestoreItem = defaultRestoreItem
  ) -> WorkspaceMoveExecution {
    perform(planned, operation: copyItem, trashItem: trashItem, restoreItem: restoreItem)
  }

  private static func perform(
    _ planned: [WorkspacePlannedMove],
    operation: (URL, URL) throws -> Void,
    trashItem: TrashItem,
    restoreItem: RestoreItem
  ) -> WorkspaceMoveExecution {
    var result = WorkspaceMoveExecution()

    for plan in planned {
      var trashedForPlan: WorkspaceDeletedItem?
      do {
        if plan.replacesExisting {
          let trashedURL = try trashItem(plan.destinationURL)
          trashedForPlan = WorkspaceDeletedItem(
            originalURL: plan.destinationURL, trashedURL: trashedURL)
        }
        try operation(plan.sourceURL, plan.destinationURL)
        result.moved.append(
          WorkspaceMovedItem(originalURL: plan.sourceURL, newURL: plan.destinationURL))
        if let trashedForPlan {
          result.replacedTrashed.append(trashedForPlan)
        }
      } catch {
        logger.error(
          "move/copy failed for '\(plan.sourceURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
        // Roll back this item's replacement so a trashed destination is never
        // lost when its incoming item failed to land.
        if let trashedForPlan {
          do {
            try restoreItem(trashedForPlan.trashedURL, trashedForPlan.originalURL)
          } catch {
            logger.error(
              "rollback restore failed for '\(trashedForPlan.originalURL.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        result.failure = failureError(for: error, name: plan.sourceURL.lastPathComponent)
        break
      }
    }

    return result
  }

  private static func failureError(for error: Error, name: String) -> WorkspaceItemMoveError {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError {
      return .nameCollision(name)
    }

    return .moveFailed(name)
  }

  private static func defaultMoveItem(_ source: URL, _ destination: URL) throws {
    try FileManager.default.moveItem(at: source, to: destination)
  }

  private static func defaultCopyItem(_ source: URL, _ destination: URL) throws {
    try FileManager.default.copyItem(at: source, to: destination)
  }

  private static func defaultTrashItem(_ url: URL) throws -> URL {
    var resultingURL: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    return (resultingURL as URL?) ?? url
  }

  private static func defaultRestoreItem(_ trashURL: URL, _ originalURL: URL) throws {
    try FileManager.default.moveItem(at: trashURL, to: originalURL)
  }
}
