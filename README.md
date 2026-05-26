# Locus

Locus is a lightweight local document workspace for macOS first, with a shared Rust core for file indexing, search, cache, and workspace state.

The product direction is documented in [docs/requirements.md](docs/requirements.md).

## Repository Layout

```text
apps/
  mac/          macOS native app
  windows/      future Windows native app
core/
  crates/       shared Rust crates
  include/      generated or exported C ABI headers
docs/
  product/      product decisions and UX notes
  architecture/ system design notes
  specs/        feature specifications
  adr/          architecture decision records
fixtures/       sample files and workspaces for tests
scripts/        development and release automation
```

## Current Status

This repository is in prototype development. The macOS app can launch into a local folder, browse a native sidebar-style file list, navigate folder history, track recent files and folders, preview common document/media files, and lightly edit Markdown, structured text, plain text, and common source files through an in-app document surface.

Search ranking, Rust folder listing, FFI ownership, recents, preview routing, text editing, and the main macOS flows have automated coverage. The next product work should stay focused on the MVP flows in [docs/product/mvp-roadmap.md](docs/product/mvp-roadmap.md), especially richer search, external-change review, state restoration, and measured performance/size checks.
