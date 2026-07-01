import XCTest

@testable import Locus

final class WorkspaceEntryOpenActionTests: XCTestCase {
  func testWorkspaceFileIconUsesClaudeAssetForClaudeMarkdown() {
    XCTAssertEqual(
      WorkspaceFileIcon.assetName(forFileName: "CLAUDE.md"),
      "fileicon-claude"
    )
  }

  func testWorkspaceFileIconMapsProvidedLanguageExtensions() {
    let cases: [(String, String)] = [
      ("index.js", "fileicon-javascript"),
      ("component.tsx", "fileicon-react"),
      ("README.md", "fileicon-markdown"),
      ("config.yaml", "fileicon-yaml"),
      ("Widget.vue", "fileicon-vue"),
      ("page.astro", "fileicon-astro"),
      ("main.c", "fileicon-c"),
      ("widget.cs", "fileicon-csharp"),
      ("engine.cpp", "fileicon-cpp"),
      ("styles.css", "fileicon-css"),
      ("mix.exs", "fileicon-elixir"),
      ("server.erl", "fileicon-erlang"),
      ("main.dart", "fileicon-dart"),
      ("solver.f90", "fileicon-fortran"),
      ("main.go", "fileicon-go"),
      ("schema.graphql", "fileicon-graphql"),
      ("index.html", "fileicon-html"),
      ("data.json", "fileicon-json"),
      ("notebook.ipynb", "fileicon-jupyter"),
      ("paper.tex", "fileicon-latex"),
      ("fragment.glsl", "fileicon-opengl"),
      ("index.php", "fileicon-php"),
      ("script.py", "fileicon-python"),
      ("analysis.r", "fileicon-r"),
      ("component.jsx", "fileicon-react"),
      ("task.rb", "fileicon-ruby"),
      ("lib.rs", "fileicon-rust"),
      ("contract.sol", "fileicon-solidity"),
      ("Widget.svelte", "fileicon-svelte"),
      ("App.swift", "fileicon-swift"),
      ("main.tf", "fileicon-terraform"),
      ("config.toml", "fileicon-toml"),
      ("layout.xml", "fileicon-xml"),
      ("main.zig", "fileicon-zig"),
      ("mcp.json", "fileicon-mcp"),
      ("gatsby-config.js", "fileicon-gatsby"),
      ("welcome.blade.php", "fileicon-laravel"),
      ("poster.ai", "fileicon-illustrator"),
      ("mockup.psd", "fileicon-photoshop"),
      ("cut.prproj", "fileicon-premiere"),
      ("prototype.xd", "fileicon-xd"),
      ("composition.aep", "fileicon-after-effects"),
      ("styles.scss", "fileicon-scss"),
      ("theme.less", "fileicon-less"),
      ("Program.fs", "fileicon-fsharp"),
      ("Main.hs", "fileicon-haskell"),
      ("Main.kt", "fileicon-kotlin"),
      ("script.lua", "fileicon-lua"),
      ("main.ml", "fileicon-ocaml"),
      ("Controller.m", "fileicon-objectivec"),
      ("script.pl", "fileicon-perl"),
      ("app.sqlite", "fileicon-sqlite"),
      ("build.scala", "fileicon-scala"),
      ("analysis.jl", "fileicon-julia"),
    ]

    for (fileName, assetName) in cases {
      XCTAssertEqual(
        WorkspaceFileIcon.assetName(forFileName: fileName),
        assetName,
        fileName
      )
    }
  }

  func testWorkspaceFileIconMapsProvidedProjectFileNames() {
    let cases: [(String, String)] = [
      ("angular.json", "fileicon-angular"),
      ("app.component.ts", "fileicon-angular"),
      ("wrangler.toml", "fileicon-cloudflare"),
      (".eslintrc.json", "fileicon-eslint"),
      ("eslint.config.js", "fileicon-eslint"),
      (".gitignore", "fileicon-git"),
      ("Cargo.toml", "fileicon-rust"),
      ("dataset-metadata.json", "fileicon-kaggle"),
      ("Gemfile", "fileicon-ruby"),
      ("go.mod", "fileicon-go"),
      ("kustomization.yaml", "fileicon-kubernetes"),
      ("deployment.k8s.yaml", "fileicon-kubernetes"),
      ("Pipfile", "fileicon-python"),
      ("pyproject.toml", "fileicon-python"),
      ("pom.xml", "fileicon-java"),
      ("pubspec.yaml", "fileicon-flutter"),
      ("rebar.config", "fileicon-erlang"),
      (".terraform.lock.hcl", "fileicon-terraform"),
      ("Dockerfile", "fileicon-docker"),
      ("docker-compose.yml", "fileicon-docker"),
      ("CODEOWNERS", "fileicon-github"),
      ("dependabot.yml", "fileicon-github"),
      ("Jenkinsfile", "fileicon-jenkins"),
      ("next.config.ts", "fileicon-nextjs"),
      ("nuxt.config.ts", "fileicon-nuxt"),
      ("tailwind.config.ts", "fileicon-tailwind"),
      ("vite.config.ts", "fileicon-vite"),
      ("build.sbt", "fileicon-scala"),
      ("stack.yaml", "fileicon-haskell"),
      ("dune-project", "fileicon-ocaml"),
    ]

    for (fileName, assetName) in cases {
      XCTAssertEqual(
        WorkspaceFileIcon.assetName(forFileName: fileName),
        assetName,
        fileName
      )
    }
  }

  func testWorkspaceFileIconFallsBackForUnknownExtension() {
    XCTAssertNil(WorkspaceFileIcon.assetName(forFileName: "archive.unknown"))
  }

  func testWorkspaceFileIconUsesURLExtensionWhenDisplayNameHasNoExtension() {
    XCTAssertEqual(
      WorkspaceFileIcon.assetName(
        forFileName: "README",
        url: URL(filePath: "/tmp/locus-test/README.md")
      ),
      "fileicon-markdown"
    )
  }

  func testWorkspaceFileIconUsesNeutralBaseForUnresolvedSymlink() {
    let entry = makeWorkspaceEntry(name: "broken", kind: .symlink, fileType: .unknown)
    let icon = WorkspaceFileIcon(entry: entry)

    XCTAssertNil(icon.assetName)
    XCTAssertEqual(icon.systemName, "doc")
    XCTAssertEqual(icon.systemColor, .secondary)
  }

  func testWorkspaceFileIconUsesFolderBaseForDirectorySymlink() {
    let entry = makeWorkspaceEntry(name: "linked-docs", kind: .symlinkToDirectory)
    let icon = WorkspaceFileIcon(entry: entry)

    XCTAssertNil(icon.assetName)
    XCTAssertEqual(icon.systemName, "folder")
    XCTAssertEqual(icon.systemColor, .blue)
  }

  func testSingleDirectoryBrowsesInLocus() {
    let entry = makeWorkspaceEntry(name: "Drafts", kind: .directory)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .browseFolder(entry.url)
    )
  }

  func testSingleTextFileEditsInLocus() {
    let entry = makeWorkspaceEntry(name: "notes.md", kind: .file, fileType: .markdown)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleImageFileViewsInLocus() {
    let entry = makeWorkspaceEntry(name: "photo.png", kind: .file, fileType: .image)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleVectorImageOpensQuickLookPreviewInLocus() {
    let entry = makeWorkspaceEntry(name: "diagram.svg", kind: .file, fileType: .image)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSinglePDFFileViewsInLocus() {
    let entry = makeWorkspaceEntry(name: "brief.pdf", kind: .file, fileType: .pdf)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleVideoFilePlaysInLocus() {
    let entry = makeWorkspaceEntry(name: "clip.mp4", kind: .file, fileType: .video)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleAudioFilePlaysInLocus() {
    let entry = makeWorkspaceEntry(name: "voice.mp3", kind: .file, fileType: .audio)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleOfficeFilePreviewsInPlace() {
    let entry = makeWorkspaceEntry(name: "deck.pptx", kind: .file, fileType: .office)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleUnknownFileTriesInPlaceTextOpen() {
    let entry = makeWorkspaceEntry(name: "blob", kind: .file, fileType: .unknown)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleTextSymlinkEditsInLocus() {
    let entry = makeWorkspaceEntry(name: "latest", kind: .symlinkToFile, fileType: .plainText)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleImageSymlinkViewsInLocus() {
    let entry = makeWorkspaceEntry(name: "latest.png", kind: .symlinkToFile, fileType: .image)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleUnknownSymlinkTriesInPlaceTextOpen() {
    let entry = makeWorkspaceEntry(name: "latest", kind: .symlinkToFile, fileType: .unknown)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .openInPlace(entry.url)
    )
  }

  func testSingleDirectorySymlinkBrowsesInLocus() {
    let entry = makeWorkspaceEntry(name: "hooks", kind: .symlinkToDirectory)

    XCTAssertEqual(
      WorkspaceEntryOpenActionResolver.action(for: [entry]),
      .browseFolder(entry.url)
    )
  }

  func testUnknownSymlinkCannotBeOpened() {
    let entry = makeWorkspaceEntry(name: "broken", kind: .symlink, fileType: .unknown)

    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [entry]))
  }

  func testOtherEntriesCannotBeOpened() {
    let entry = makeWorkspaceEntry(name: "socket", kind: .other)

    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [entry]))
  }

  func testMultipleSelectionCannotBeOpenedAsOneAction() {
    let folder = makeWorkspaceEntry(name: "Drafts", kind: .directory)
    let file = makeWorkspaceEntry(name: "notes.md", kind: .file)

    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: [folder, file]))
    XCTAssertNil(WorkspaceEntryOpenActionResolver.action(for: []))
  }

  func testLinkedPathResolverFindsEntryLoadedFromParentFolder() {
    let visibleEntry = makeWorkspaceEntry(name: "README.md", kind: .file, fileType: .markdown)
    let linkedEntry = makeWorkspaceEntry(
      path: "/tmp/locus-test/docs/brief.md", kind: .file, fileType: .markdown)

    XCTAssertEqual(
      WorkspaceLinkedPathEntryResolver.entry(
        matching: linkedEntry.url,
        visibleEntries: [visibleEntry],
        loadedParentEntries: [linkedEntry]),
      linkedEntry)
  }

  func testLinkedPathResolverPrefersVisibleEntryMetadata() {
    let visibleEntry = makeWorkspaceEntry(
      path: "/tmp/locus-test/docs/brief.md", kind: .file, fileType: .markdown)
    let staleLoadedEntry = makeWorkspaceEntry(
      path: "/tmp/locus-test/docs/brief.md", kind: .file, fileType: .unknown)

    XCTAssertEqual(
      WorkspaceLinkedPathEntryResolver.entry(
        matching: visibleEntry.url,
        visibleEntries: [visibleEntry],
        loadedParentEntries: [staleLoadedEntry]),
      visibleEntry)
  }

  func testLinkedPathResolverSynthesizesOrdinaryFileEntry() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(component: "locus-linked-path-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appending(component: "external.note", directoryHint: .notDirectory)
    try "linked".write(to: fileURL, atomically: true, encoding: .utf8)

    let entry = try XCTUnwrap(WorkspaceLinkedPathEntryResolver.syntheticEntry(for: fileURL))

    XCTAssertEqual(entry.url.standardizedFileURL, fileURL.standardizedFileURL)
    XCTAssertEqual(entry.name, "external.note")
    XCTAssertEqual(entry.kind, .file)
    XCTAssertEqual(entry.fileType, .unknown)
    XCTAssertEqual(WorkspaceEntryOpenActionResolver.action(for: [entry]), .openInPlace(entry.url))
  }

  func testLinkedPathResolverSynthesizesDirectoryEntry() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(component: "locus-linked-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let entry = try XCTUnwrap(WorkspaceLinkedPathEntryResolver.syntheticEntry(for: directory))

    XCTAssertEqual(entry.url.standardizedFileURL, directory.standardizedFileURL)
    XCTAssertEqual(entry.name, directory.lastPathComponent)
    XCTAssertEqual(entry.kind, .directory)
    XCTAssertEqual(WorkspaceEntryOpenActionResolver.action(for: [entry]), .browseFolder(entry.url))
  }
}

private func makeWorkspaceEntry(
  name: String,
  kind: WorkspaceEntryKind,
  fileType: WorkspaceFileType = .unknown
) -> WorkspaceEntry {
  makeWorkspaceEntry(
    path: "/tmp/locus-test/\(name)",
    kind: kind,
    fileType: fileType)
}

private func makeWorkspaceEntry(
  path: String,
  kind: WorkspaceEntryKind,
  fileType: WorkspaceFileType = .unknown
) -> WorkspaceEntry {
  let url = URL(filePath: path, directoryHint: kind.isDirectoryLike ? .isDirectory : .notDirectory)
  return WorkspaceEntry(
    id: url.path(percentEncoded: false),
    url: url,
    name: url.lastPathComponent,
    kind: kind,
    fileType: fileType,
    sizeBytes: nil,
    modified: nil,
    isReadOnly: false
  )
}
