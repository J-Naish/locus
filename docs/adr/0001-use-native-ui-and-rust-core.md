# 0001. Use Native UI Shells With A Shared Rust Core

## Status

Accepted. The text-editing portion (TextKit 2 / NSTextView) is superseded by
ADR 0006: text editing now uses a custom Core Text engine over the Rust buffer.

## Context

Locus targets a lightweight local document workspace. The app must feel native, avoid Electron, and share non-UI logic between macOS and a future Windows version.

## Decision

Build native UI shells per platform and centralize heavy cross-platform behavior in Rust.

- macOS UI: Swift, AppKit, SwiftUI, TextKit 2, PDFKit, Quick Look, AVKit
- Windows UI: C#, WinUI 3, Windows App SDK
- Shared core: Rust, SQLite, search, cache, diff, workspace state
- Integration boundary: C ABI with thin platform-specific wrappers

## Consequences

This keeps the user experience close to each OS while allowing indexing, search, cache, and workspace behavior to be reused across platforms.
