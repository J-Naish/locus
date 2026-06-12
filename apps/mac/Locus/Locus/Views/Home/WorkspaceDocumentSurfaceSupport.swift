import Foundation

enum WorkspaceDocumentSurfaceKind: Equatable {
  case editableText
  case image
  case pdf
  case video
  case audio
  case quickLookPreview
  case folder
  case unsupported

  var supportsInPlaceOpen: Bool {
    switch self {
    case .editableText, .image, .pdf, .video, .audio, .quickLookPreview:
      return true
    case .folder, .unsupported:
      return false
    }
  }

  var isAutoSynced: Bool {
    // Auto-sync currently follows every in-place surface. Keep this as a
    // separate policy hook so a future surface can opt out without changing
    // the open-in-place resolver.
    supportsInPlaceOpen
  }
}

enum WorkspaceDocumentSurfaceSupport {
  static func surfaceKind(for entry: WorkspaceEntry) -> WorkspaceDocumentSurfaceKind {
    switch entry.kind {
    case .file, .symlinkToFile:
      if WorkspaceTextDocumentSupport.canOpenInTextSurface(entry) {
        return .editableText
      }
      if canRenderImageInPlace(entry) {
        return .image
      }
      if entry.fileType == .pdf {
        return .pdf
      }
      if entry.fileType == .video {
        return .video
      }
      if entry.fileType == .audio {
        return .audio
      }
      if entry.fileType == .office {
        return .quickLookPreview
      }
      return .unsupported
    case .directory, .symlinkToDirectory:
      return .folder
    case .symlink, .other:
      return .unsupported
    }
  }

  private static func canRenderImageInPlace(_ entry: WorkspaceEntry) -> Bool {
    guard entry.fileType == .image else {
      return false
    }

    return supportedRasterImageExtensions.contains(
      entry.url.pathExtension.lowercased()
    )
  }

  private static let supportedRasterImageExtensions: Set<String> = [
    "bmp",
    "gif",
    "heic",
    "heif",
    "jpeg",
    "jpg",
    "png",
    "tif",
    "tiff",
    "webp",
  ]

  /// A text file larger than this opens read-only in the windowed viewer instead
  /// of the in-memory editable buffer. Mirrors `TextBufferStore`'s editable cap.
  ///
  /// A UI test may lower it with `--ui-test-large-text-byte-limit` (honored only
  /// under the `LOCUS_UI_TESTING` hook) so a small fixture routes to the read-only
  /// viewer without a multi-hundred-megabyte file.
  static var editableTextByteLimit: Int {
    if ProcessInfo.processInfo.environment["LOCUS_UI_TESTING"] == "1",
      let raw = LaunchArgumentValues.value(
        named: "--ui-test-large-text-byte-limit", in: ProcessInfo.processInfo.arguments),
      let limit = Int(raw)
    {
      return limit
    }
    return TextBufferStore.defaultMaximumOpenByteCount
  }

  /// Whether a text file of `byteCount` bytes is too large to edit in memory and
  /// should open in the read-only windowed viewer.
  static func isLargeText(byteCount: Int) -> Bool {
    byteCount > editableTextByteLimit
  }

  /// Which backend the text view should open a file with.
  enum TextDocumentBackend: Equatable {
    /// The in-memory editable buffer (also the path that refuses a too-large file).
    case editable
    /// The read-only windowed `LargeFile`, for a file too big to edit in memory.
    case readOnlyWindowed
  }

  /// Chooses the text backend for a file. Only a *recognized* text type over the
  /// editable limit opens read-only in the windowed viewer; everything else — a
  /// small file, an unknown size, or an unrecognized (possibly binary) file of any
  /// size — opens on the editable path, which refuses a too-large file rather than
  /// scanning a binary into mojibake.
  static func textBackend(byteCount: Int?, recognizedTextType: Bool) -> TextDocumentBackend {
    if recognizedTextType, let byteCount, isLargeText(byteCount: byteCount) {
      return .readOnlyWindowed
    }
    return .editable
  }

  /// Logical size of `url` in bytes, read inside a balanced security scope so it
  /// resolves the same way the document open does (which holds the scope before
  /// reading). Returns nil when the size is unavailable.
  static func fileByteCount(at url: URL) -> Int? {
    let didStartAccess = url.startAccessingSecurityScopedResource()
    defer {
      if didStartAccess {
        url.stopAccessingSecurityScopedResource()
      }
    }
    return (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
  }

  /// How a cached-but-inactive text document catches up with the disk state
  /// found when the user switches back to it (it is not monitored while
  /// inactive, so this is the reconciliation decision).
  enum InactiveDocumentReconciliation: Equatable {
    /// Nothing changed on disk (or the document is not cached): keep the buffer.
    case keepBuffer
    /// Disk changed under unsaved edits: keep them and warn; the user resolves.
    case conflict
    /// Disk changed and the buffer is clean: drop it and reload from disk.
    case reloadFromDisk
  }

  /// Decides how a document that was open-but-inactive reconciles with disk.
  /// `baselineFingerprint` is the disk state the cached buffer was last in sync
  /// with; `currentFingerprint` is the state found now — either side is nil
  /// when unreadable (e.g. the file was deleted), which still counts as a
  /// divergence when the two differ.
  static func reconciliation(
    isCached: Bool,
    baselineFingerprint: DocumentFileFingerprint?,
    currentFingerprint: DocumentFileFingerprint?,
    hasPendingConflict: Bool,
    hasUnsavedEdits: Bool
  ) -> InactiveDocumentReconciliation {
    guard isCached else {
      return .keepBuffer
    }
    if hasPendingConflict {
      return .conflict
    }
    guard baselineFingerprint != currentFingerprint else {
      return .keepBuffer
    }
    return hasUnsavedEdits ? .conflict : .reloadFromDisk
  }
}
