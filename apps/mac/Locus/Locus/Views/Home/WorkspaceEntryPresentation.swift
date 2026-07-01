import SwiftUI

extension WorkspaceEntry {
  /// Synthesizes a `WorkspaceEntry` for the workspace root folder itself.
  /// The FFI lists only a folder's children, so the root row has no
  /// metadata-bearing entry to copy. Fields not directly observable from the
  /// URL are intentionally left nil, unknown, or false.
  static func workspaceRoot(at folderURL: URL) -> WorkspaceEntry {
    let standardizedURL = folderURL.standardizedFileURL
    let folderName = standardizedURL.lastPathComponent
    return WorkspaceEntry(
      // Keep the synthesized root id aligned with Git status path keys.
      id: standardizedURL.locusStandardizedPath,
      url: standardizedURL,
      name: folderName.isEmpty ? "Workspace" : folderName,
      kind: .directory,
      fileType: .unknown,
      sizeBytes: nil,
      modified: nil,
      isReadOnly: false
    )
  }

  var fileIcon: WorkspaceFileIcon {
    WorkspaceFileIcon(entry: self)
  }
}

extension WorkspaceFileType {
  fileprivate var symbolName: String {
    switch self {
    case .markdown, .structuredText, .plainText:
      return "doc.text"
    case .pdf:
      return "doc.richtext"
    case .office:
      return "doc"
    case .image:
      return "photo"
    case .audio:
      return "waveform"
    case .video:
      return "film"
    case .code:
      return "chevron.left.forwardslash.chevron.right"
    case .unknown:
      return "doc"
    }
  }
}

struct WorkspaceFileIcon: Equatable, Sendable {
  enum SymbolColor: Equatable, Sendable {
    case blue
    case secondary

    var color: Color {
      switch self {
      case .blue:
        return .blue
      case .secondary:
        return .secondary
      }
    }
  }

  let assetName: String?
  let systemName: String
  let systemColor: SymbolColor

  init(entry: WorkspaceEntry) {
    switch entry.kind {
    case .directory, .symlinkToDirectory:
      self.init(assetName: nil, systemName: "folder", systemColor: .blue)
    case .file, .symlinkToFile:
      self.init(
        assetName: Self.assetName(forFileName: entry.name, url: entry.url),
        systemName: entry.fileType.symbolName,
        systemColor: .secondary
      )
    case .symlink:
      self.init(assetName: nil, systemName: "doc", systemColor: .secondary)
    case .other:
      self.init(assetName: nil, systemName: "doc", systemColor: .secondary)
    }
  }

  private init(assetName: String?, systemName: String, systemColor: SymbolColor) {
    self.assetName = assetName
    self.systemName = systemName
    self.systemColor = systemColor
  }

  static func assetName(forFileName fileName: String, url: URL? = nil) -> String? {
    let lowerName = fileName.lowercased()
    let pathExtension =
      (url?.pathExtension.isEmpty == false ? url?.pathExtension : nil)
      ?? (fileName as NSString).pathExtension
    let lowerExtension = pathExtension.lowercased()

    switch lowerName {
    case "claude.md":
      return "fileicon-claude"
    case "mcp.json", ".mcp.json", "mcp.yaml", "mcp.yml":
      return "fileicon-mcp"
    case "pubspec.yaml", "pubspec.yml":
      return "fileicon-flutter"
    case "gatsby-config.js", "gatsby-config.ts", "gatsby-node.js", "gatsby-browser.js",
      "gatsby-ssr.js":
      return "fileicon-gatsby"
    case "artisan":
      return "fileicon-laravel"
    default:
      break
    }

    if lowerName.hasSuffix(".blade.php") {
      return "fileicon-laravel"
    }

    switch lowerExtension {
    case "md", "markdown", "mdx":
      return "fileicon-markdown"
    case "yml", "yaml":
      return "fileicon-yaml"
    case "js", "mjs", "cjs", "jsx":
      return "fileicon-javascript"
    case "ts", "mts", "cts", "tsx":
      return "fileicon-typescript"
    case "vue":
      return "fileicon-vue"
    case "astro":
      return "fileicon-astro"
    case "c", "h":
      return "fileicon-c"
    case "ex", "exs":
      return "fileicon-elixir"
    case "dart":
      return "fileicon-flutter"
    case "f", "for", "f77", "f90", "f95", "f03", "f08":
      return "fileicon-fortran"
    default:
      return nil
    }
  }
}

struct WorkspaceEntryIconImage: View {
  let entry: WorkspaceEntry
  let dimension: CGFloat
  let systemFontSize: CGFloat
  let symlinkBadgeSize: CGFloat
  let symlinkBadgeOffset: CGSize
  let isDimmed: Bool

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      baseIcon

      if entry.kind.isSymlink {
        Image(systemName: "arrowshape.turn.up.right.fill")
          .font(.system(size: symlinkBadgeSize, weight: .semibold))
          .foregroundStyle(.secondary)
          .offset(x: symlinkBadgeOffset.width, y: symlinkBadgeOffset.height)
          .accessibilityHidden(true)
      }
    }
    .frame(width: dimension, height: dimension, alignment: .center)
  }

  @ViewBuilder
  private var baseIcon: some View {
    let icon = entry.fileIcon
    if let assetName = icon.assetName {
      Image(assetName)
        .resizable()
        .scaledToFit()
        .opacity(isDimmed ? 0.45 : 1)
    } else {
      Image(systemName: icon.systemName)
        .font(.system(size: systemFontSize))
        .foregroundStyle(isDimmed ? .secondary : icon.systemColor.color)
    }
  }
}
