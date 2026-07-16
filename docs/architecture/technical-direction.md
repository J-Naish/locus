# Technical Direction

## Platform Strategy

Build native UI shells for each supported operating system and share heavy cross-platform logic through Rust.

Initial platform:

- macOS

Future platform:

- Windows

Not planned initially:

- Linux

## macOS App

Expected stack:

- Swift
- AppKit
- SwiftUI
- Core Text (custom virtualized text engine over the Rust buffer; text editing
  does not use NSTextView/TextKit)
- Metal (terminal pane rendering via a glyph atlas; the Core Graphics
  path is retained as the offscreen test oracle)
- PDFKit
- Quick Look
- AVKit

The macOS app owns:

- UI
- window management
- menus
- keyboard shortcuts
- drag and drop
- Finder-like file navigation
- native previews
- native media playback
- Markdown editing surface
- terminal pane UI: input, IME, selection, and rendering over the core's
  terminal frames (ADR 0012)

## Rust Core

The Rust core owns behavior that should be shared, tested, and reused across platforms:

- file scanning
- lightweight listing metadata, with richer file metadata loaded lazily
- the UTF-8 text buffer for editing text up to a bounded in-memory size (larger
  files open read-only): persistent rope, line index and snapshots, position
  lookups, and edit/undo primitives exposed through the C ABI
- hashing
- diffing
- search indexes
- SQLite access
- cache management
- workspace state
- Markdown parsing and serialization where useful
- terminal emulation (`core/crates/terminal`, a faithful ghostty port:
  VT parsing, screen and scrollback state, selection, search) and PTY
  process management (`core/crates/pty`) — see ADR 0012 and
  `docs/specs/terminal.md`
- CLI tools for debugging and benchmarking

The macOS app keeps the UI, input/IME, text drawing, selection, and text
encoding detection/conversion; the Rust buffer stores and edits UTF-8 bytes.

## FFI Boundary

Rust should expose a C ABI. Native apps should call it through a thin platform-specific bridge.

Guidelines:

- do not call raw C APIs throughout app UI code
- keep FFI calls coarse enough to avoid chatty boundaries
- use handle-based objects where useful
- keep memory ownership explicit
- memory allocated by Rust should be released by Rust
- return structured status codes and make error messages retrievable
- run expensive work off the UI thread

## Performance Direction

The app should feel fast because it avoids unnecessary work.

Important constraints:

- no Electron
- no bundled Chromium or Node runtime in the desktop app
- no startup scan of every file
- no bulk thumbnail generation on launch
- no bulk PDF or Office parsing on launch
- lazy-load file lists
- run heavy work in the background
- keep the UI responsive during indexing and search

## Testing Direction

Development speed depends on having careful tests around each module. Tests are not optional supporting work; they are part of how the app should be designed and implemented.

Default expectations:

- write unit tests for core logic by default
- prefer small, deterministic module-level tests before broad integration tests
- use test-first development when behavior is unclear or failure modes matter
- add integration tests for cross-module flows such as scanning, indexing, search, cache, diff, and FFI behavior
- keep fixtures explicit, minimal, and reusable
- avoid relying on manual app testing for behavior that can be verified automatically
- treat regressions as missing tests first, then as implementation bugs

Unit tests are especially important for the Rust core because it owns shared behavior that both macOS and future Windows shells depend on.

## Storage and Search

SQLite is the default persistence layer.

Expected uses:

- workspace metadata
- recent items
- file metadata cache
- search index data
- FTS5 when full-text search becomes necessary

The storage model should stay boring and inspectable until the product proves it needs more complexity.
