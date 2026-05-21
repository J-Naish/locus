# AGENTS.md

This file gives coding agents the working rules for this repository.

## Product Intent

Locus is a lightweight local document workspace for business users working alongside general-purpose AI agents such as Codex and Claude Code.

The product fills the gap between agent desktop apps, which are weak at local file preview and lightweight editing, and developer tools such as VS Code or Cursor, which are too broad and technical for non-engineers.

Keep the app:

- native
- local-first
- fast
- quiet
- approachable
- document-oriented
- useful for reviewing and lightly editing files created or touched by AI agents

Do not turn Locus into:

- an IDE
- an AI chat app
- an agent runtime
- an Office suite
- an Acrobat replacement
- a plugin platform

## Read First

Before making product or architecture decisions, read the relevant docs:

- `docs/requirements.md` for the overview
- `docs/product/brief.md` for positioning and users
- `docs/product/ux-direction.md` for interaction and tone
- `docs/product/mvp-roadmap.md` for scope and sequencing
- `docs/architecture/technical-direction.md` for platform and testing direction
- `docs/specs/core-feature-scope.md` for feature expectations

## Repository Map

- `apps/mac/`: native macOS app, first product target
- `apps/windows/`: future native Windows app
- `core/`: shared Rust core and FFI surface
- `core/crates/app-core/`: reusable core logic
- `core/crates/app-ffi/`: C ABI layer for native app integration
- `core/crates/app-cli/`: debugging and benchmark CLI
- `core/include/`: exported or generated C headers
- `site/`: official static site, not the product app
- `docs/`: product, architecture, specs, and ADRs
- `fixtures/`: reusable test fixtures
- `scripts/`: development, build, release, and platform scripts

## Architecture Rules

- Build native UI shells per platform.
- Put shared, testable behavior in Rust core.
- Keep UI-specific behavior out of Rust unless it is truly cross-platform domain logic.
- Expose Rust through a C ABI and thin platform-specific bridges.
- Do not call raw C APIs throughout app UI code.
- Keep FFI calls coarse enough to avoid chatty boundaries.
- Keep memory ownership explicit; Rust-allocated memory must be released by Rust.
- Use SQLite for boring, inspectable local persistence unless there is a clear reason not to.

## Testing Rules

Tests are part of the implementation, not cleanup.

- Add unit tests for core logic by default.
- Prefer small deterministic module-level tests.
- Write tests before implementation when behavior is subtle, risky, or unclear.
- Add integration tests for scanning, indexing, search, cache, diff, persistence, and FFI flows.
- Use `fixtures/` for explicit reusable sample files and workspaces.
- Treat regressions as missing tests first and implementation bugs second.
- Do not rely on manual app testing for behavior that can be automated.

Run the narrowest relevant tests while working, then broader checks before handoff.

Useful commands:

```sh
cargo test --manifest-path core/Cargo.toml
cargo check --manifest-path core/Cargo.toml
```

For the site:

```sh
cd site
pnpm build
```

## Product Scope Rules

Core file experiences should be strong:

- Markdown editing should feel document-like, not code-like.
- YAML, JSON, TOML, and similar config files should be first-class editable documents.
- Common image, video, and audio files should be previewable using native OS capabilities where possible.
- PDFs should focus on reading, search, highlights, comments, and lightweight review.
- Office files should focus on preview, search metadata, and external-app handoff.

Avoid adding:

- Electron or desktop Chromium runtime
- bundled AI models
- built-in AI chat
- plugin or extension execution
- always-on terminal UI
- Git, LSP, debugger, or other IDE-oriented features
- heavy parsing or thumbnail generation on startup

## UX Rules

- Favor Finder-like and Preview-like behavior over developer-tool behavior.
- Use plain user-facing language: folders, locations, recent items, favorites.
- Keep advanced concepts internal unless users genuinely need them.
- Prefer native controls and OS facilities.
- Make file changes explicit and predictable.
- Do not hide file formats behind abstractions that make users unsure what will be saved.

## Site Rules

`site/` is the marketing and download site. Keep its JavaScript tooling scoped there.

Do not move it under `apps/` unless it becomes an actual product web app.

## Documentation Rules

- Keep docs concise and split by stable topic.
- Update docs when scope, architecture, or product principles change.
- Add ADRs in `docs/adr/` for important architectural decisions.
- Avoid duplicating the same requirement across many files; link to the source document instead.

## Git and Change Hygiene

- Keep changes scoped to the request.
- Do not reformat unrelated files.
- Do not delete or rewrite user changes unless explicitly asked.
- Do not commit unless the user asks.
- If committing, use a clear imperative commit message.
