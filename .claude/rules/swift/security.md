---
paths:
  - "**/*.swift"
  - "**/Package.swift"
---
# Swift Security

> This file extends [security.md](../security.md) with Swift specific content.

## Secret Management

- Use **Keychain Services** for sensitive data (tokens, passwords, keys) — never `UserDefaults`
- Use environment variables or `.xcconfig` files for build-time secrets
- Never hardcode secrets in source — decompilation tools extract them trivially
- Do not add secret storage unless a product feature genuinely needs it

```swift
let bookmarkData = try url.bookmarkData(
    options: .withSecurityScope,
    includingResourceValuesForKeys: nil,
    relativeTo: nil
)
guard !bookmarkData.isEmpty else {
    throw FileAccessError.missingBookmark
}
```

## Local File Access

- Use security-scoped bookmarks for sandboxed persistent folder access
- Start and stop security-scoped access in a balanced scope
- Treat external file metadata and contents as untrusted input
- Prefer native file presenters, preview, and handoff APIs where possible

## Input Validation

- Validate user-selected URLs before handing them to Rust or persistence
- Use `URL(filePath:)` or validated file URLs instead of force-unwrapping URL strings
- Validate data from file contents, drag/drop, file importer, and pasteboard before processing
