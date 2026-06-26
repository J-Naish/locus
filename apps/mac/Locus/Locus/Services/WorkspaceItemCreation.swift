import Foundation

enum WorkspaceItemCreationKind: Equatable, Sendable {
  case file
  case folder

  var undoActionName: String {
    switch self {
    case .file:
      return "Create File"
    case .folder:
      return "Create Folder"
    }
  }
}

enum WorkspaceItemCreationError: LocalizedError, Equatable {
  case emptyName
  case nestedPath
  case invalidCharacters
  case nameTooLong
  case alreadyExists(String)
  case noActiveWorkspace
  case fileCreateFailed
  case folderCreateFailed

  var errorDescription: String? {
    switch self {
    case .emptyName:
      return "Enter a name."
    case .nestedPath:
      return "Use a single file or folder name."
    case .invalidCharacters:
      return "The name contains characters that cannot be used."
    case .nameTooLong:
      return "The name is too long."
    case .alreadyExists(let name):
      return "'\(name)' already exists."
    case .noActiveWorkspace:
      return "No folder is open."
    case .fileCreateFailed:
      return "Locus couldn't create the file."
    case .folderCreateFailed:
      return "Locus couldn't create the folder."
    }
  }
}

enum WorkspaceItemCreation {
  private static let maximumNameLengthInBytes = 255

  static func destinationURL(in folderURL: URL, name: String) throws -> URL {
    let sanitizedName = try sanitizedName(name)
    return folderURL.appending(path: sanitizedName)
  }

  static func create(
    _ kind: WorkspaceItemCreationKind,
    named name: String,
    in folderURL: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    let destinationURL = try destinationURL(in: folderURL, name: name)

    switch kind {
    case .file:
      try createEmptyFile(at: destinationURL)
    case .folder:
      do {
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: false)
      } catch {
        throw creationError(
          from: error,
          existingName: destinationURL.lastPathComponent,
          fallback: .folderCreateFailed
        )
      }
    }

    return destinationURL
  }

  private static func createEmptyFile(at url: URL) throws {
    do {
      try Data().write(to: url, options: [.withoutOverwriting])
    } catch {
      throw creationError(
        from: error,
        existingName: url.lastPathComponent,
        fallback: .fileCreateFailed
      )
    }
  }

  private static func creationError(
    from error: Error,
    existingName: String,
    fallback: WorkspaceItemCreationError
  ) -> WorkspaceItemCreationError {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError {
      return .alreadyExists(existingName)
    }

    return fallback
  }

  private static func sanitizedName(_ name: String) throws -> String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      throw WorkspaceItemCreationError.emptyName
    }

    guard !trimmedName.contains("/"), trimmedName != ".", trimmedName != ".." else {
      throw WorkspaceItemCreationError.nestedPath
    }

    guard
      !trimmedName.unicodeScalars.contains(where: { scalar in
        scalar.value == 0 || scalar.value < 0x20 || scalar.value == 0x3A
      })
    else {
      throw WorkspaceItemCreationError.invalidCharacters
    }

    guard trimmedName.utf8.count <= maximumNameLengthInBytes else {
      throw WorkspaceItemCreationError.nameTooLong
    }

    return trimmedName
  }
}

enum WorkspaceItemCreationPlacement {
  static func insertionIndex(
    for kind: WorkspaceItemCreationKind,
    in entries: [WorkspaceEntry]
  ) -> Int {
    entries.firstIndex { shouldInsert(kind, before: $0) } ?? entries.endIndex
  }

  static func shouldInsert(
    _ kind: WorkspaceItemCreationKind,
    before entry: WorkspaceEntry
  ) -> Bool {
    switch kind {
    case .folder:
      return true
    case .file:
      return !entry.kind.isDirectoryLike
    }
  }
}
