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
site/           static marketing and download site
```

## Current Status

This repository is in the initial skeleton phase. The first implementation target is the macOS MVP described in the requirements.
