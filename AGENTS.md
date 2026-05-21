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
- `docs/specs/performance-budget.md` for speed and size smoke budgets

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

## Performance, Weight, and Polish Rules

Performance, lightweight behavior, and refined UX/UI are top-priority product qualities. Treat them as core requirements, not later polish.

- Prefer simple native OS capabilities over bundled runtimes, heavy dependencies, or custom infrastructure.
- Keep startup work minimal; do not eagerly scan, parse, index, thumbnail, hash, or preview large folders.
- Load file lists, previews, metadata, thumbnails, and indexes lazily and incrementally.
- Keep UI interactions responsive while background work is running.
- Treat slow startup, unnecessary memory growth, avoidable disk churn, and dependency bloat as product bugs.
- Measure before adding broad caching, background indexing, or complex abstractions.
- Choose boring, inspectable implementations unless extra complexity clearly improves responsiveness, reliability, or user clarity.
- Preserve a quiet, native, document-oriented interface; visual polish should make common work feel clearer and calmer, not more decorative.
- Refine empty states, loading states, error states, keyboard behavior, and file handoff flows as part of implementation, not as cleanup.
- Do not accept technically correct UI that feels dense, developer-centric, sluggish, surprising, or unfinished.

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

Before handoff for changes that can affect speed, size, startup, file listing, FFI, or the macOS app bundle, run:

```sh
scripts/perf-smoke.sh
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
- Early UI implementation should prioritize getting coherent product flows working end-to-end over polishing every visual detail in isolation.
- For early feature slices, use a simple native UI shape that fits the product direction and keep moving; do not force frequent fine-grained UI review before enough functionality exists to judge the experience.
- Explain the intended user flow before starting a substantial new UI surface, but avoid blocking implementation on micro-level visual decisions unless the choice would be hard to reverse.
- Once a meaningful set of UI functionality is in place, shift into a deliberate polish pass with the user: review the actual app on a Mac, refine layout, hierarchy, empty/loading/error states, keyboard behavior, and overall interaction feel together.
- When UI changes are made or a new UI slice is complete, explain what changed, how to run it, and what should be checked. Treat user review on the actual Mac as the acceptance path for visual quality and interaction feel, especially during polish passes.
- Use automated tests and local builds to catch functional regressions, but do not treat them as a substitute for user review of visual quality, interaction feel, responsiveness, and native polish.

## Site Rules

`site/` is the marketing and download site. Keep its JavaScript tooling scoped there.

Do not move it under `apps/` unless it becomes an actual product web app.

## Documentation Rules

- Keep docs concise and split by stable topic.
- Document important implementation and application knowledge by default: architecture decisions, feature behavior, platform constraints, performance budgets, persistence formats, FFI contracts, build/release flows, and non-obvious tradeoffs should leave a written record.
- Leave concise code comments where they materially improve maintainability for humans or AI agents: explain non-obvious constraints, invariants, ownership/lifetime rules, platform quirks, performance tradeoffs, and why a surprising implementation is intentional.
- Avoid comments that merely restate obvious code behavior.
- Update docs when scope, architecture, or product principles change.
- Add ADRs in `docs/adr/` for important architectural decisions.
- Avoid duplicating the same requirement across many files; link to the source document instead.

## Git and Change Hygiene

- Keep changes scoped to the request.
- Do not reformat unrelated files.
- Do not delete or rewrite user changes unless explicitly asked.
- Do not commit unless the user asks.

## Commit Rules

Commits should be small, intentional records of working changes.

- Commit only when the user asks for a commit.
- Before committing, inspect `git status` and the staged diff so unrelated or user-owned changes are not included by accident.
- Stage files explicitly; do not use broad staging commands unless the user clearly wants every current change included.
- Keep each commit focused on one coherent product, documentation, or infrastructure change.
- Use a clear imperative commit message such as `Add macOS workspace plan` or `Fix file list sorting`.
- Do not mention agents, AI tools, or implementation process in commit messages unless that is the actual product/documentation change.
- Do not amend, squash, rebase, force-push, or rewrite history unless the user explicitly asks.
- If the working tree contains unrelated changes, leave them alone and mention what was intentionally included.
- After committing, report the commit hash and confirm whether the working tree is clean.
