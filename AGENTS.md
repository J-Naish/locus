# AGENTS.md

This file gives coding agents the shared working rules for the whole Locus repository.

Locus is currently in prototype development. Prioritize the core prototype
flows: local folder browsing, search, in-app preview, lightweight editing, and
external change review. Do not add convenience-only shortcuts, command palettes,
toolbar polish, or broad secondary affordances unless explicitly requested.

Directory-specific rules live closer to the code they govern:

- `core/AGENTS.md` for Rust core, FFI, Cargo, and core test rules.
- `apps/mac/AGENTS.md` for Swift, SwiftUI, macOS UI, CoreBridge, and Xcode rules.
- `docs/AGENTS.md` for requirements, product docs, architecture docs, and ADRs.

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
- a plugin or extension platform

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
- `docs/`: product, architecture, specs, and ADRs
- `fixtures/`: reusable test fixtures
- `scripts/`: development, build, release, and platform scripts
- `Makefile`: thin task runner over `scripts/` and the toolchains; run `make help` for common tasks (`make run-release`, `make test`, `make perf`, …)

## Architecture Rules

- Build native UI shells per platform.
- For Apple platform UI, stay as close as practical to native SwiftUI and
  AppKit patterns before introducing custom chrome or custom-drawn controls.
- Put performance-sensitive, testable logic in the Rust core. The core exists primarily for speed and efficiency; cross-platform reuse is a secondary benefit.
- Keep UI-specific behavior in the native app. Move work into the Rust core when it measurably improves performance, not by default, and only when it can cross the FFI boundary as compact data rather than large copies.
- Use thin platform-specific bridges around the core; do not spread low-level integration details through UI code.
- Use SQLite for boring, inspectable local persistence unless there is a clear reason not to.
- Prefer simple native OS capabilities over bundled runtimes, heavy dependencies, or custom infrastructure.
- Choose boring, inspectable implementations unless extra complexity clearly improves responsiveness, reliability, or user clarity.

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
- Git workflow surfaces such as commit, branch, diff, merge, blame, staging,
  LSP, debugger, or other IDE-oriented features
- heavy parsing or thumbnail generation on startup

Passive, read-only Git status indicators may be used as local file-status cues
to make changed or newly created files easier to notice in the sidebar. Keep
this limited to lightweight status display; do not add commit, branch, diff,
merge, blame, staging, or other Git workflow surfaces unless the product
direction explicitly changes.

## Performance, Weight, and Polish Rules

User experience is the top priority: Locus must feel comfortable, responsive, calm, and native to use. Judge performance, weight, and polish work by its effect on that experience — pursue an optimization when it makes the product feel better to use, not for its own sake.

## Coding Style

- Prefer immutable data and explicit replacement over hidden shared mutation.
- Local, explicit mutation is allowed for accumulators, builders, buffers, UI state, Rust ownership patterns, and performance-sensitive code.
- Prefer the simplest solution that actually works.
- Avoid speculative abstractions and features.
- Extract repeated logic only when repetition is real, not hypothetical.
- Keep files focused, but do not split cohesive native UI views or Rust modules just to satisfy a line count.
- Prefer early returns over deeply nested control flow.
- Use named constants for meaningful thresholds, delays, budgets, and limits.
- Follow language-specific naming rules in the directory-specific `AGENTS.md`.
- Avoid abbreviations unless they are standard in the domain.

## Security Rules

- Never hardcode secrets, API keys, passwords, tokens, or credentials.
- Validate inputs at system boundaries.
- Treat user-selected files, file contents, metadata, drag/drop data, pasteboard data, tool output, and external data as untrusted.
- Handle file paths deliberately; do not accidentally traverse, persist, or reveal sensitive paths.
- Use parameterized SQLite queries when persistence code exists.
- Keep FFI boundaries explicit about nullability, encoding, ownership, and lifetimes.
- Use security-scoped file access where sandboxed persistent folder access is involved.
- Keep user-facing errors clear and safe; preserve diagnostic detail only where appropriate.
- If a critical security issue is found, stop feature work, fix it first, and review related entry points for the same class of issue.

## Testing Rules

Tests are part of the implementation, not cleanup.

- Target at least 80% coverage for meaningful business logic.
- Use test-driven development for new features, bug fixes, and refactors:
  1. Write a failing test first.
  2. Run it and verify it fails for the right reason.
  3. Implement the smallest passing change.
  4. Verify the test passes.
  5. Refactor while tests stay green.
- Add unit tests for individual functions, models, utilities, and view-independent helpers.
- Add integration tests for Rust core, FFI, file listing, persistence, fixtures, and platform bridge behavior.
- Add E2E or UI-flow tests for critical macOS user flows and file handoff flows where automation is practical.
- Use `fixtures/` for explicit reusable sample files and workspaces.
- Treat regressions as missing tests first and implementation bugs second.
- Do not rely on manual app testing for behavior that can be automated.
- Fix implementation, not tests, unless the tests are wrong.
- Prefer Arrange-Act-Assert structure and descriptive test names that state the behavior under test.

Run the narrowest relevant tests while working, then broader checks before handoff. Before handoff for changes that can affect speed, size, startup, file listing, FFI, or the macOS app bundle, run:

```sh
scripts/perf-smoke.sh
```

## Common Patterns

- Study Apple, Rust, SQLite, and existing project examples before inventing new structure.
- Prefer adapting the current architecture over importing external structure.
- Do not clone or vendor external project structure unless explicitly approved.
- Introduce a local persistence boundary only when SQLite or durable local persistence appears.
- Keep SQL and schema details out of UI views.
- Keep Rust/native integration coarse and explicit.
- Keep ABI structs versioned and layout-tested.

## Git and Change Hygiene

- Keep changes scoped to the request.
- Do not reformat unrelated files.
- Do not delete or rewrite user changes unless explicitly asked.
- Do not commit unless the user asks.
- Stage files explicitly; do not use broad staging commands unless the user clearly wants every current change included.
- Keep each commit focused on one coherent product, documentation, or infrastructure change.
- Use a clear imperative commit message such as `Add macOS workspace plan` or `Fix file list sorting`.
- Do not mention agents, AI tools, or implementation process in commit messages unless that is the actual product/documentation change.
- Do not amend, squash, rebase, force-push, or rewrite history unless the user explicitly asks.
- If the working tree contains unrelated changes, leave them alone and mention what was intentionally included.
- After committing, report the commit hash and confirm whether the working tree is clean.
