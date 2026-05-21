# MVP and Roadmap

## Phase 1: macOS MVP

The first release should focus on a strong native macOS experience.

MVP scope:

- native macOS app
- shared Rust core
- Home screen
- Finder-like sidebar
- favorite folders
- recent files and folders
- open a local folder as the current working location
- file list and file opening
- Markdown editing
- PDF viewing
- PDF highlights and comments
- Quick Look-based Office preview
- image viewing
- video and audio playback
- file name search
- reveal in Finder
- open in external app
- Space-key quick preview
- command palette
- file change detection
- external change review
- static official site

## Phase 2: macOS Quality

After the MVP works end to end, improve depth and polish:

- faster search
- full-text search
- SQLite FTS5
- metadata cache
- workspace state restoration
- Markdown diff view
- PDF annotation persistence
- delayed thumbnail generation
- dark mode
- performance benchmarks

## Phase 3: Windows

Build a Windows native app after the macOS app has a stable product shape.

Expected direction:

- C#
- WinUI 3
- Windows App SDK
- shared Rust core
- Windows-native file preview behavior
- Windows packaging and signing

## Later Possibilities

Potential future additions:

- cross-workspace search
- tags
- collections
- temporary workspaces
- simple PDF page operations
- Office text extraction
- Markdown export
- sponsor or donation flow
- managed distribution for organizations

These should not distract from the first product goal: a fast, local, native document workspace.
