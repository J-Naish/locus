---
paths:
  - "**/*.swift"
  - "**/Package.swift"
---
# Swift Testing

> This file extends [testing.md](../testing.md) with Swift specific content.

## Framework

Use **Swift Testing** (`import Testing`) for new tests. Use `@Test` and `#expect`:

```swift
@Test("Workspace entry formats file size")
func workspaceEntryFormatsFileSize() throws {
    let entry = WorkspaceEntry.fixture(sizeBytes: 42)

    #expect(entry.sizeLabel == "42 bytes")
}

@Test("Folder importer cancellation preserves state")
func folderImporterCancellationPreservesState() throws {
    #expect(HomeView.isUserCancellationError(CancellationError()))
}
```

## Test Isolation

Each test gets a fresh instance — set up in `init`, tear down in `deinit`. No shared mutable state between tests.

## Parameterized Tests

```swift
@Test("Classifies document formats", arguments: ["md", "json", "pdf"])
func classifiesDocumentFormat(extension fileExtension: String) throws {
    let fileType = WorkspaceFileType.classify(fileExtension: fileExtension)
    #expect(fileType.isPreviewable)
}
```

## Coverage

```bash
swift test --enable-code-coverage
```

## Reference

See skill: `swift-protocol-di-testing` for protocol-based dependency injection and mock patterns with Swift Testing.
