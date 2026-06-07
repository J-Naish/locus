import Foundation

extension URL {
  var locusDisplayName: String {
    let name = lastPathComponent
    return name.isEmpty || name == "/" ? path(percentEncoded: false) : name
  }

  var locusStandardizedPath: String {
    var path = standardizedFileURL.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") {
      path.removeLast()
    }
    return path
  }

  /// Fully symlink-resolved, standardized path. Use it for the workspace root
  /// and for any folder written *into* (create, move/import destination): a
  /// write that targets a symlinked directory lands on the link's destination,
  /// so the destination — not the lexical path — is what must stay inside the
  /// workspace. Resolving both sides the same way keeps a workspace reached
  /// through a symlink (such as macOS `/var` -> `/private/var`) self-consistent.
  var locusResolvedPath: String {
    resolvingSymlinksInPath().locusStandardizedPath
  }

  /// Standardized path with intermediate symlinks resolved but the final
  /// component left intact. Use it when an operation acts on the entry *itself*
  /// (deleting or moving an entry, classifying a dragged item): the entry is
  /// located by where the link lives, not by where it points, while a symlinked
  /// *directory* anywhere in the path still resolves so it cannot smuggle the
  /// operation outside the workspace.
  var locusResolvedParentPath: String {
    deletingLastPathComponent()
      .resolvingSymlinksInPath()
      .appending(component: lastPathComponent)
      .locusStandardizedPath
  }

  /// Whether the file is effectively read-only: it sits on a read-only volume or
  /// is otherwise unwritable (mode, ACL, or ownership), or it carries a user or
  /// system immutable flag. This is more precise than the core's mode-bit
  /// `readonly`, but it stats the file, so call it once when a document is opened
  /// rather than for every entry while listing a folder. `fallback` is returned
  /// when the metadata cannot be read.
  func locusIsReadOnly(fallback: Bool) -> Bool {
    guard
      let values = try? resourceValues(
        forKeys: [.isWritableKey, .isUserImmutableKey, .isSystemImmutableKey]
      )
    else {
      return fallback
    }
    if values.isUserImmutable == true || values.isSystemImmutable == true {
      return true
    }
    return values.isWritable.map { !$0 } ?? fallback
  }
}
