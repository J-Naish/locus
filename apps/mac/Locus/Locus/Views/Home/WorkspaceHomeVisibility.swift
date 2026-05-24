import Foundation

/// UI-level home-folder presentation policy. Rust listing already removes
/// cross-platform OS noise such as `.git`, `.DS_Store`, `._*`, and `~$*`; this
/// layer keeps the user's home location quiet without changing explicit
/// project-folder dotfile visibility.
enum WorkspaceHomeVisibility {
  static func filteredSnapshotOffMainActor(
    _ snapshot: WorkspaceSnapshot,
    folderURL: URL,
    homeDirectoryURL: URL
  ) async -> WorkspaceSnapshot {
    await Task.detached(priority: .userInitiated) {
      filteredSnapshot(
        snapshot,
        folderURL: folderURL,
        homeDirectoryURL: homeDirectoryURL
      )
    }.value
  }

  static func filteredSnapshot(
    _ snapshot: WorkspaceSnapshot,
    folderURL: URL,
    homeDirectoryURL: URL,
    isHiddenResource: (URL) -> Bool = WorkspaceHomeVisibility.isHiddenResource
  ) -> WorkspaceSnapshot {
    guard folderURL.locusStandardizedPath == homeDirectoryURL.locusStandardizedPath else {
      return snapshot
    }

    return WorkspaceSnapshot(
      entries: snapshot.entries.filter { entry in
        !isHiddenForHomeContext(
          entry.url, displayName: entry.name, isHiddenResource: isHiddenResource)
      },
      // Partial errors do not currently carry a path through the FFI.
      // Suppress them in the quiet home view so hidden entries cannot
      // leave behind unactionable warnings for rows the user cannot see.
      partialErrors: []
    )
  }

  static func isHiddenHomeURL(
    _ url: URL,
    homeDirectoryURL: URL,
    isHiddenResource: (URL) -> Bool = WorkspaceHomeVisibility.isHiddenResource
  ) -> Bool {
    let standardizedURL = url.standardizedFileURL
    let parentURL = standardizedURL.deletingLastPathComponent()
    guard parentURL.locusStandardizedPath == homeDirectoryURL.locusStandardizedPath else {
      return false
    }

    return isHiddenForHomeContext(
      standardizedURL,
      displayName: standardizedURL.lastPathComponent,
      isHiddenResource: isHiddenResource
    )
  }

  private static func isHiddenResource(_ url: URL) -> Bool {
    guard let values = try? url.resourceValues(forKeys: [.isHiddenKey]) else {
      return false
    }

    return values.isHidden == true
  }

  private static func isHiddenForHomeContext(
    _ url: URL,
    displayName: String,
    isHiddenResource: (URL) -> Bool
  ) -> Bool {
    displayName.hasPrefix(".") || isHiddenResource(url)
  }
}
