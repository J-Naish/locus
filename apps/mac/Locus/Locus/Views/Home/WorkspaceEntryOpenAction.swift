import Foundation

enum WorkspaceEntryOpenAction: Equatable, Sendable {
  case browseFolder(URL)
  case openInPlace(URL)
}

enum WorkspaceEntryOpenActionResolver {
  static func action(for entries: [WorkspaceEntry]) -> WorkspaceEntryOpenAction? {
    guard entries.count == 1, let entry = entries.first else {
      return nil
    }

    switch entry.kind {
    case .directory, .symlinkToDirectory:
      return .browseFolder(entry.url)
    case .file, .symlinkToFile:
      let surfaceKind = WorkspaceDocumentSurfaceSupport.surfaceKind(for: entry)
      if surfaceKind.supportsInPlaceOpen {
        return .openInPlace(entry.url)
      }

      return nil
    case .symlink, .other:
      return nil
    }
  }
}

enum WorkspaceLinkedPathEntryResolver {
  static func entry(
    matching url: URL,
    visibleEntries: [WorkspaceEntry],
    loadedParentEntries: [WorkspaceEntry] = []
  ) -> WorkspaceEntry? {
    let path = url.standardizedFileURL.locusStandardizedPath
    return (visibleEntries + loadedParentEntries).first {
      $0.url.standardizedFileURL.locusStandardizedPath == path
    }
  }

  static func syntheticEntry(
    for url: URL,
    fileManager: FileManager = .default
  ) -> WorkspaceEntry? {
    let standardized = url.standardizedFileURL
    var isDirectory = ObjCBool(false)
    guard
      fileManager.fileExists(
        atPath: standardized.path(percentEncoded: false),
        isDirectory: &isDirectory)
    else {
      return nil
    }

    let values = try? standardized.resourceValues(
      forKeys: [.contentModificationDateKey, .fileSizeKey, .isWritableKey]
    )
    let kind: WorkspaceEntryKind = isDirectory.boolValue ? .directory : .file
    return WorkspaceEntry(
      id: standardized.locusStandardizedPath,
      url: standardized,
      name: standardized.locusDisplayName,
      kind: kind,
      fileType: .unknown,
      sizeBytes: values?.fileSize.map(UInt64.init),
      modified: values?.contentModificationDate,
      isReadOnly: values?.isWritable == false
    )
  }
}
