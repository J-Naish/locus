# macOS MVP Implementation Plan

## Goal

Build the first usable native macOS version of Locus: a quiet local document workspace that can open a folder, browse files, preview common document/media formats, and lightly edit Markdown and structured text.

The implementation should keep the product native, local-first, fast, and document-oriented. It should not introduce Electron, a built-in AI chat surface, plugin execution, IDE workflows, or heavy startup indexing.

## Current Starting Point

- `apps/mac/` contains the macOS app direction but no app implementation yet.
- `core/` contains a minimal Rust workspace with `app-core`, `app-ffi`, and `app-cli`.
- The Rust FFI surface currently exposes only `locus_core_version`.
- Product scope and architecture are defined in:
  - `docs/product/mvp-roadmap.md`
  - `docs/specs/core-feature-scope.md`
  - `docs/architecture/technical-direction.md`
  - `docs/adr/0001-use-native-ui-and-rust-core.md`

## Implementation Principles

- Start with an end-to-end vertical slice before broad feature depth.
- Keep macOS UI behavior in Swift/AppKit/SwiftUI.
- Put reusable file, search, cache, diff, and persistence behavior in Rust.
- Keep raw C ABI calls inside a thin Swift bridge, not in view code.
- Make expensive work cancellable or backgrounded from the start.
- Prefer small tested Rust modules over large UI-driven behavior.
- Use native frameworks for previews: PDFKit, Quick Look, AVKit, image views, and TextKit 2/NSTextView.
- Defer full-text search, delayed thumbnails, PDF annotation persistence polish, and state restoration until the basic MVP path is stable.

## Proposed macOS App Shape

Create the macOS app under `apps/mac/Locus/`.

Initial structure:

```text
apps/mac/Locus/
  Locus.xcodeproj/
  Locus/
    App/
    CoreBridge/
    Models/
    Views/
    Views/Home/
    Views/Browser/
    Views/Preview/
    Views/Editors/
    Services/
  LocusTests/
  LocusUITests/
```

Responsibilities:

- `App/`: app entry point, window setup, menus, command routing.
- `CoreBridge/`: Swift wrapper around the C ABI. Owns unsafe calls, memory release, status conversion, and background dispatch.
- `Models/`: Swift-facing view models and value types.
- `Views/Home/`: recent items, favorites, and locations.
- `Views/Browser/`: sidebar, file list, folder navigation, search field.
- `Views/Preview/`: PDF, Quick Look, image, audio, video, and unsupported-file views.
- `Views/Editors/`: Markdown and structured plain-text editors.
- `Services/`: in-app location navigation helpers, file dialogs, file watching, recents/favorites storage if still app-owned.

Use SwiftUI for app structure and normal controls, with AppKit bridges where native document behavior matters:

- `NSTextView` / TextKit 2 for Markdown and structured text editing.
- `PDFView` for PDFs.
- `QLPreviewView` or Quick Look panel/controller for Office and unknown previewable files.
- `AVPlayerView` for video and audio.

## Rust Core Shape

Grow `core/crates/app-core` in small modules:

```text
core/crates/app-core/src/
  lib.rs
  file_type.rs
  workspace.rs
  metadata.rs
  search.rs
  recents.rs
  favorites.rs
  storage.rs
  diff.rs
```

Initial ownership:

- `file_type`: extension and MIME-ish classification used by both app and CLI.
- `workspace`: open a folder, list child entries, apply shallow filters, sort folders/files.
- `metadata`: size, modified time, directory flag, readonly flag, lightweight type metadata.
- `search`: file-name search within the current location.
- `recents` and `favorites`: start simple; persist through SQLite once the storage boundary is ready.
- `storage`: SQLite wrapper for recents, favorites, metadata cache, and later FTS5.
- `diff`: defer until external-change review is implemented.

Do not parse PDFs, Office documents, or media in Rust for MVP browsing. The macOS app should use native preview frameworks for those.

## FFI Boundary

Keep the C ABI coarse and explicit. Early APIs should support:

- core version and ABI version checks
- opening a workspace folder
- listing a folder
- file-name search
- reading lightweight metadata
- storing and reading recents/favorites once persistence lands
- releasing Rust-allocated strings and arrays
- retrieving structured error details

Preferred pattern:

- Return status codes from FFI functions.
- Return data through opaque handles or Rust-owned buffers released by Rust.
- Keep Swift view code away from raw pointers by routing all calls through `CoreBridge`.
- Avoid one FFI call per file row interaction; fetch folder snapshots in batches.

The first app milestone can use a folder-list snapshot API before adding long-lived workspace handles, as long as ownership and release functions are explicit.

## Milestones

### 1. Native App Foundation

Deliverables:

- Create the macOS app project under `apps/mac/Locus/`.
- Add a minimal SwiftUI/AppKit app shell with one main window.
- Add build documentation in `apps/mac/README.md`.
- Link the Rust `app-ffi` library into the macOS target.
- Add `CoreBridge` with a version-check call to `locus_core_version`.

Acceptance:

- The app builds and launches.
- The main window shows the Locus shell.
- A Swift test or startup assertion verifies the Rust core bridge can call the FFI version function.

### 2. Folder Opening and File List

Deliverables:

- Add Rust file-type classification and folder-listing APIs.
- Add deterministic Rust unit tests using temporary directories and `fixtures/` where useful.
- Add Swift folder picker and current location state.
- Show a Finder-like file list with names, type labels, size, and modified date.
- Add in-app "show containing folder and select item" behavior for files reached from recents, favorites, and search results.
- Keep file location actions inside Locus: open, preview, show containing folder, select item, and copy path.

Acceptance:

- A user can choose a local folder and browse its immediate contents.
- File list loading does not block the main thread.
- Rust tests cover sorting, hidden files policy, symlink policy, and basic metadata.

### 3. Home, Recents, and Favorites

Deliverables:

- Add Home view with recent files, recent folders, and favorite folders.
- Add favorite/unfavorite actions for folders.
- Decide whether initial persistence is app-owned or Rust-owned; move to Rust/SQLite before broader indexing work.
- Add command/menu actions for opening recent folders and favorite folders.

Acceptance:

- Recently opened folders and files survive app restart.
- Favorites are explicit and user-controlled.
- User-facing language uses "folders", "locations", "recent items", and "favorites".

### 4. Preview and Editing Vertical Slice

Deliverables:

- Markdown editor using `NSTextView`/TextKit with normal save behavior.
- Structured plain-text editor for YAML, JSON, TOML, and common text files.
- PDF viewer using PDFKit with page navigation, zoom, text selection, and search.
- Image preview.
- Video/audio playback using AVKit.
- Office preview through native system preview facilities where possible.
- Unsupported-file fallback with useful actions.

Acceptance:

- Opening a supported file chooses the right native surface.
- Markdown and structured text save back to disk predictably.
- Office files are previewable where macOS supports them.
- Unsupported files still support show in Locus and copy path, with richer in-app preview/edit support added by file type.

### 5. Search and Command Palette

Deliverables:

- Add file-name search within the current location.
- Add recent-item search.
- Add `Command-K` command palette for common actions:
  - open recent file
  - open recent folder
  - search files by name
  - create Markdown document
  - show containing folder in Locus
  - copy path

Acceptance:

- Search returns fast first results without full startup indexing.
- Command palette is useful but does not become a developer command surface.
- Search and command flows keep users in Locus by default when the task is finding, selecting, or previewing a local item.

### 6. File Change Detection and Review

Deliverables:

- Watch the current location for external changes.
- Refresh file lists when files are added, removed, renamed, or modified.
- For editable text files, detect external modification while open.
- Add a clear review/reload path before overwriting external changes.

Acceptance:

- External edits are visible and do not get silently overwritten.
- Conflict messaging is plain and non-technical.

### 7. MVP Polish and Packaging

Deliverables:

- Add app icon placeholder or final asset.
- Add menus, keyboard shortcuts, toolbar polish, and empty/error states.
- Add basic accessibility labels and keyboard navigation pass.
- Add release-oriented build script once the app target is stable.
- Add packaging/signing notes; defer distribution automation until needed.

Acceptance:

- The app feels like a native macOS document workspace.
- MVP user flows work without manual setup beyond building the app.
- Narrow Rust tests and macOS unit tests pass.

## First Implementation Sprint

Start with these tasks in order:

1. Add the macOS app scaffold in `apps/mac/Locus/`.
2. Add a Swift `CoreBridge` that calls the existing `locus_core_version`.
3. Add Rust `file_type` and `workspace` modules with unit tests.
4. Extend the FFI with one coarse folder-list snapshot API and explicit free functions.
5. Build a minimal UI: Home, "Open Folder", current location title, and file list.
6. Add in-app containing-folder navigation and row selection for file-list, recent, favorite, and search result rows.
7. Keep context-menu actions scoped to in-app navigation, preview, and path copying.
8. Run:
   - `cargo test --manifest-path core/Cargo.toml`
   - the narrow macOS app tests available from the Xcode project

This produces the smallest useful vertical slice and validates the core architectural boundary before preview/editing depth is added.

## Test Strategy

Rust:

- Unit tests for file classification, folder listing, metadata, sorting, and search.
- Integration tests for workspace flows and FFI memory ownership.
- Fixtures for representative files and folders.

macOS:

- Unit tests for `CoreBridge` conversions and view models.
- Lightweight UI tests for opening a folder and selecting a file once the shell is stable.
- Manual checks only for native preview rendering that cannot be reliably automated early.

Before handoff for core-affecting work, run:

```sh
cargo test --manifest-path core/Cargo.toml
cargo check --manifest-path core/Cargo.toml
```

Before handoff for app-affecting work, also run the narrowest relevant Xcode/macOS tests.

## Deferred Until After MVP Slice

- Full-text search and SQLite FTS5.
- Metadata cache and delayed thumbnails.
- Markdown diff view.
- Deep PDF annotation persistence and annotation list.
- Office text extraction.
- Workspace state restoration.
- Windows app work.
- Site changes unrelated to download or product positioning.

## Key Risks

- Xcode project churn: keep project changes small and documented.
- FFI memory ownership bugs: add explicit release functions and test them early.
- UI blocking during file scans: make folder listing asynchronous from the first UI slice.
- Scope creep into IDE features: keep source files as editable documents, not development projects.
- Preview framework edge cases: provide reliable fallback actions for every unsupported or failed preview.
