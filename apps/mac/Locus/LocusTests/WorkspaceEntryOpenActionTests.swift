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
      ("component.tsx", "fileicon-typescript"),
      ("README.md", "fileicon-markdown"),
      ("config.yaml", "fileicon-yaml"),
      ("Widget.vue", "fileicon-vue"),
      ("page.astro", "fileicon-astro"),
      ("main.c", "fileicon-c"),
      ("mix.exs", "fileicon-elixir"),
      ("main.dart", "fileicon-flutter"),
      ("solver.f90", "fileicon-fortran"),
      ("mcp.json", "fileicon-mcp"),
      ("gatsby-config.js", "fileicon-gatsby"),
      ("welcome.blade.php", "fileicon-laravel"),
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
