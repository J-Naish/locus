import XCTest

final class InfoPlistDocumentTypesTests: XCTestCase {
  func testDocumentTypesExposeWorkspaceTextAndPreviewFormats() throws {
    let documentTypes = try documentTypes()
    let contentTypes = Set(documentTypes.flatMap { stringArray($0["LSItemContentTypes"]) })

    XCTAssertTrue(
      contentTypes.isSuperset(of: [
        "public.folder",
        "public.text",
        "public.source-code",
        "net.daringfireball.markdown",
        "public.json",
        "org.yaml.yaml",
        "org.toml-lang.toml",
        "com.adobe.pdf",
        "public.image",
        "org.openxmlformats.wordprocessingml.document",
      ]),
      "Missing document content types: \(contentTypes)"
    )
  }

  func testDocumentTypesKeepLocusAsAlternateHandler() throws {
    for documentType in try documentTypes() {
      XCTAssertEqual(documentType["LSHandlerRank"] as? String, "Alternate")
    }
  }

  func testDocumentTypeExtensionsCoverAgentWorkspaceFormats() throws {
    let documentTypes = try documentTypes()
    let extensions = Set(documentTypes.flatMap { stringArray($0["CFBundleTypeExtensions"]) })

    XCTAssertTrue(
      extensions.isSuperset(of: [
        "md",
        "markdown",
        "yaml",
        "yml",
        "toml",
        "json",
        "jsonc",
        "jsonl",
        "ndjson",
        "txt",
        "env",
        "gitignore",
        "dockerignore",
        "csv",
        "tsv",
        "pdf",
        "docx",
        "xlsx",
        "pptx",
      ]),
      "Missing document extensions: \(extensions)"
    )
  }

  func testImportedTypesDeclareMarkdownAndConfigFormats() throws {
    let info = try infoPlist()
    let declarations = try XCTUnwrap(
      info["UTImportedTypeDeclarations"] as? [[String: Any]]
    )
    let identifiers = Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })

    XCTAssertTrue(
      identifiers.isSuperset(of: [
        "net.daringfireball.markdown",
        "org.yaml.yaml",
        "org.toml-lang.toml",
        "com.microsoft.vscode.jsonc",
        "org.jsonlines.jsonl",
      ]),
      "Missing imported type declarations: \(identifiers)"
    )
  }

  private func documentTypes() throws -> [[String: Any]] {
    try XCTUnwrap(infoPlist()["CFBundleDocumentTypes"] as? [[String: Any]])
  }

  private func infoPlist() throws -> [String: Any] {
    let data = try Data(contentsOf: sourceInfoPlistURL)
    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try XCTUnwrap(value as? [String: Any])
  }

  private var sourceInfoPlistURL: URL {
    URL(filePath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "Locus/Info.plist")
  }

  private func stringArray(_ value: Any?) -> [String] {
    switch value {
    case let values as [String]:
      return values
    case let value as String:
      return [value]
    default:
      return []
    }
  }
}
