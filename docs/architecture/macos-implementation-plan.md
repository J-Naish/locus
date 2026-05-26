# macOS MVP Implementation Plan

## Goal

Build the first usable native macOS version of Locus: a quiet local document workspace that can open a folder, browse files, preview common document/media formats, and lightly edit Markdown and structured text.

The implementation should keep the product native, local-first, fast, and document-oriented. It should not introduce Electron, a built-in AI chat surface, plugin execution, IDE workflows, or heavy startup indexing.

## Current Implementation Baseline

- `apps/mac/Locus/` contains the active native macOS prototype.
- The app launches into the home folder when available, supports explicit folder opening, shows a name-first sidebar file browser, expands folders inline, keeps session folder history, and tracks recent files/folders.
- The document surface supports editable Markdown, structured text, plain text, and common source files, plus native previews for images, PDFs, media, and Office files through Quick Look where macOS can render them.
- `core/` contains the Rust workspace with `app-core`, `app-ffi`, and `app-cli`; the current core covers file type classification, shallow folder listing, lightweight listing metadata, ignored-name policy, FFI snapshots, and a performance-listing CLI.
- The Rust FFI surface exposes ABI/version checks, folder listing with explicit options, stable status codes, partial listing errors, and Rust-owned snapshot release functions.
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

## macOS App Shape

The app is under `apps/mac/Locus/`.

Current structure:

```text
apps/mac/Locus/
  Locus.xcodeproj/
  Locus/
    App/
    CoreBridge/
    Views/
    Views/Home/
    Services/
  LocusTests/
  LocusUITests/
```

Responsibilities:

- `App/`: app entry point, window setup, menus, command routing.
- `CoreBridge/`: Swift wrapper around the C ABI. Owns unsafe calls, memory release, status conversion, and background dispatch.
- `Views/Home/`: current folder browsing, inline folder expansion, recent items, search ranking support, document tabs, preview surfaces, and text editor bridge.
- `Services/`: in-app location navigation helpers, file dialogs, file watching, and recents storage if still app-owned.

Use SwiftUI for app structure and normal controls, with AppKit bridges where native document behavior matters:

- `NSTextView` / TextKit 2 for Markdown and structured text editing.
- `PDFView` for PDFs.
- `QLPreviewView` for Office previews inside Locus; defer Quick Look panel handoff until an explicit fallback workflow is needed.
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
  storage.rs
  diff.rs
```

Initial ownership:

- `file_type`: extension and MIME-ish classification used by both app and CLI.
- `workspace`: open a folder, list child entries, apply shallow filters, sort folders/files.
- `metadata`: directory flag, readonly flag, lightweight type metadata, and contextual size/modified-time loading when a surface needs it.
- `search`: file-name search within the current location.
- `recents`: start simple; persist through SQLite once the storage boundary is ready.
- `storage`: SQLite wrapper for recents, metadata cache, and later FTS5.
- `diff`: defer until external-change review is implemented.

Do not parse PDFs, Office documents, or media in Rust for MVP browsing. The macOS app should use native preview frameworks for those.

## FFI Boundary

Keep the C ABI coarse and explicit. Early APIs should support:

- core version and ABI version checks
- opening a workspace folder
- listing a folder
- file-name search
- reading lightweight listing metadata, with size and modified time loaded lazily when needed
- listing with explicit options through FFI when contextual surfaces request
  extended metadata
- storing and reading recents once persistence lands
- releasing Rust-allocated strings and arrays
- retrieving structured error details

Preferred pattern:

- Return status codes from FFI functions.
- Return data through opaque handles or Rust-owned buffers released by Rust.
- Keep Swift view code away from raw pointers by routing all calls through `CoreBridge`.
- Avoid one FFI call per file row interaction; fetch folder snapshots in batches.
- Keep the default folder-list API lightweight. Use the explicit options
  listing API when a contextual surface needs size or modified-time values.

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
- Start normal unsandboxed launches in the user's home folder, listing only immediate children.
- Filter hidden files and folders from the home folder presentation, including hidden home shortcuts, without changing project-folder dotfile visibility.
- Show a quiet, name-first file list for the current location. The default
  browser should not expose Type, Size, or Modified columns; keep those
  metadata values lazy for future contextual surfaces, and avoid making the
  primary list feel like a developer or spreadsheet view.
- Let folder rows expand inline from a native outline-style disclosure chevron
  in the sidebar, loading child folder contents lazily and indenting nested
  items; double-clicking a folder remains the explicit navigation action.
- Add in-app "show containing folder and select item" behavior for files reached from recents and search results.
- Add session-scoped folder Back/Forward navigation.
- Keep file and folder context menus minimal: open supported items in Locus and copy paths. External preview and explicit "show in Locus" commands are deferred until a concrete workflow needs them.

Acceptance:

- A user can launch into their home folder, choose another local folder, and browse immediate contents without recursive startup scanning.
- A user can expand a folder row by clicking its disclosure chevron to inspect
  nearby children without changing the current working location, and can still
  double-click the folder to navigate into it.
- Hidden home-directory entries and shortcuts are not shown by default, while useful project dotfiles remain visible when a project folder is opened explicitly.
- File list loading does not block the main thread.
- Rust tests cover sorting, hidden files policy, symlink policy, and the lazy
  extended metadata policy.
- UI tests cover browser-style folder history and forward-stack clearing after
  a new navigation.

### 3. Home and Recents

Deliverables:

- Add Home view with recent files and recent folders.
- Decide whether initial persistence is app-owned or Rust-owned; move to Rust/SQLite before broader indexing work.
- Add command/menu actions for opening recent folders.

Acceptance:

- Recently opened folders and files survive app restart.
- User-facing language uses "folders", "locations", and "recent items".

### 4. Preview and Editing Vertical Slice

Deliverables:

- Markdown editor using `NSTextView`/TextKit with normal save behavior.
- Structured plain-text editor for YAML, JSON, TOML, and common text files.
- Lightweight readability-focused syntax highlighting for Markdown, structured
  text, and common source files; avoid IDE-oriented language tooling in this
  slice.
- PDF viewer using PDFKit. The current vertical slice is a plain read-only
  in-app preview without custom controls; explicit page navigation chrome,
  explicit zoom chrome, search, highlights, and comments follow as separate PDF
  review slices. Native PDFKit behaviors such as scrolling, selection, and
  trackpad zoom may remain available without custom UI.
- Image preview.
- Video/audio playback using AVKit. The first vertical slice uses in-app,
  manually started playback with native controls; richer audio metadata and
  artwork presentation can follow once the core document surface is stable.
- Office preview through an in-app Quick Look surface where macOS can render the file.
- Unsupported-file fallback with useful actions.

Acceptance:

- Opening a supported file chooses the right native surface.
- Markdown and structured text save back to disk predictably.
- Text editing remains document-oriented while making headings, keys, strings,
  numbers, comments, and common code keywords easier to scan.
- Office files are previewable inside Locus where macOS supports them.
- Unsupported files still support copy path, with richer in-app preview/edit support added by file type.

### 5. Search

Deliverables:

- Add file-name search within the current location.
- Add recent-item search.

Acceptance:

- Search returns fast first results without full startup indexing.
- Search flows keep users in Locus by default when the task is finding,
  selecting, or opening a local item.

### 6. File Change Detection and Sync

Deliverables:

- Watch the current location for external changes.
- Refresh file lists when files are added, removed, renamed, or modified.
- For open in-place documents, detect external modification while open.
- Automatically reload the displayed document from disk when it changes.
- Use file-system notifications plus lightweight metadata checks before
  reloading document contents for external-change sync.

Acceptance:

- External edits become visible without a manual reload action.
- Text editor contents follow the latest disk version when another process
  writes the file.
- For the prototype, disk changes win even when the editor has unsaved text;
  conflict review and merge UI are deferred.
- In-place previews refresh after the displayed file changes on disk.

### 7. MVP Polish and Packaging

Deliverables:

- Add app icon placeholder or final asset.
- Add empty/error states where missing from the core prototype flows.
- Add basic accessibility labels for primary prototype flows.
- Add release-oriented build script once the app target is stable.
- Add packaging/signing notes; defer distribution automation until needed.

Acceptance:

- The app feels like a native macOS document workspace.
- MVP user flows work without manual setup beyond building the app.
- Narrow Rust tests and macOS unit tests pass.

## Current Validation Focus

Keep validation tied to the active prototype rather than the old scaffold path:

1. Run focused Rust tests and clippy when touching `core/`.
2. Run focused macOS unit/UI tests when touching app flows.
3. Keep the sidebar visible by default because folder browsing is the primary workspace flow.
4. Keep search ranking tested separately from visible search chrome so the matching model remains ready without reintroducing launcher-style UI.
5. Keep context-menu actions scoped to opening supported items in Locus and path copying.
6. Run `scripts/perf-smoke.sh` before handoff for changes affecting speed, size, startup, file listing, FFI, or the app bundle.

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
- Preview framework edge cases: keep unsupported or failed previews understandable without adding fallback chrome before the workflow is clear.
