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
    case ".dev.vars", "wrangler.json", "wrangler.toml":
      return "fileicon-cloudflare"
    case ".eslintrc", ".eslintrc.cjs", ".eslintrc.js", ".eslintrc.json", ".eslintrc.yaml",
      ".eslintrc.yml", "eslint.config.cjs", "eslint.config.js", "eslint.config.mjs",
      "eslint.config.ts":
      return "fileicon-eslint"
    case ".gitattributes", ".gitconfig", ".gitignore", ".gitkeep", ".gitmodules", ".mailmap",
      "gitconfig":
      return "fileicon-git"
    case ".terraform.lock.hcl":
      return "fileicon-terraform"
    case "angular.json":
      return "fileicon-angular"
    case "claude.md":
      return "fileicon-claude"
    case "cargo.lock", "cargo.toml":
      return "fileicon-rust"
    case "dataset-metadata.json", "kaggle.json", "kernel-metadata.json":
      return "fileicon-kaggle"
    case "gemfile", "rakefile":
      return "fileicon-ruby"
    case "go.mod", "go.sum", "go.work":
      return "fileicon-go"
    case "kustomization.yaml", "kustomization.yml":
      return "fileicon-kubernetes"
    case "mcp.json", ".mcp.json", "mcp.yaml", "mcp.yml":
      return "fileicon-mcp"
    case "pipfile", "poetry.lock", "pyproject.toml", "requirements.txt":
      return "fileicon-python"
    case "pom.xml":
      return "fileicon-java"
    case "pubspec.yaml", "pubspec.yml":
      return "fileicon-flutter"
    case "rebar.config":
      return "fileicon-erlang"
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
    if Self.isAngularFile(lowerName) {
      return "fileicon-angular"
    }
    if lowerName.hasSuffix(".k8s.yaml") || lowerName.hasSuffix(".k8s.yml")
      || lowerName.hasSuffix(".kubernetes.yaml") || lowerName.hasSuffix(".kubernetes.yml")
    {
      return "fileicon-kubernetes"
    }

    switch lowerExtension {
    case "cs", "csproj", "csx", "sln":
      return "fileicon-csharp"
    case "cpp", "cxx", "cc", "hpp", "hh", "hxx", "ipp", "ixx", "tpp":
      return "fileicon-cpp"
    case "md", "markdown", "mdx":
      return "fileicon-markdown"
    case "json", "json5", "jsonc":
      return "fileicon-json"
    case "toml":
      return "fileicon-toml"
    case "yml", "yaml":
      return "fileicon-yaml"
    case "js", "mjs", "cjs":
      return "fileicon-javascript"
    case "jsx", "tsx":
      return "fileicon-react"
    case "ts", "mts", "cts":
      return "fileicon-typescript"
    case "html", "htm", "xhtml":
      return "fileicon-html"
    case "css":
      return "fileicon-css"
    case "vue":
      return "fileicon-vue"
    case "svelte":
      return "fileicon-svelte"
    case "astro":
      return "fileicon-astro"
    case "c", "h":
      return "fileicon-c"
    case "ex", "exs":
      return "fileicon-elixir"
    case "erl", "hrl":
      return "fileicon-erlang"
    case "dart":
      return "fileicon-dart"
    case "go":
      return "fileicon-go"
    case "graphql", "gql":
      return "fileicon-graphql"
    case "java", "gradle":
      return "fileicon-java"
    case "ipynb":
      return "fileicon-jupyter"
    case "tex", "sty", "cls", "bib":
      return "fileicon-latex"
    case "glsl", "vert", "frag", "geom", "tesc", "tese", "comp", "shader":
      return "fileicon-opengl"
    case "php", "phtml":
      return "fileicon-php"
    case "py", "pyi", "pyw":
      return "fileicon-python"
    case "r", "rmd", "rproj":
      return "fileicon-r"
    case "rb", "rake", "gemspec":
      return "fileicon-ruby"
    case "rs":
      return "fileicon-rust"
    case "sol":
      return "fileicon-solidity"
    case "swift":
      return "fileicon-swift"
    case "tf", "tfvars", "hcl":
      return "fileicon-terraform"
    case "xml", "xsd", "xslt", "plist", "storyboard", "xib":
      return "fileicon-xml"
    case "zig", "zon":
      return "fileicon-zig"
    case "f", "for", "f77", "f90", "f95", "f03", "f08":
      return "fileicon-fortran"
    default:
      return nil
    }
  }

  private static func isAngularFile(_ lowerName: String) -> Bool {
    [
      ".component.ts",
      ".component.html",
      ".component.css",
      ".component.scss",
      ".component.sass",
      ".directive.ts",
      ".guard.ts",
      ".module.ts",
      ".pipe.ts",
      ".resolver.ts",
      ".routes.ts",
      ".service.ts",
    ].contains { lowerName.hasSuffix($0) }
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
