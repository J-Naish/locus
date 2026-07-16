# 0012. Embed a Terminal Built on a Ported ghostty Core

## Status

Accepted.

## Context

Locus positions itself as the workspace beside general-purpose AI agents
such as Codex and Claude Code, and those agents run as terminal CLIs. Users
kept leaving Locus to start and watch agent sessions, which broke the
review loop the product exists to serve. A terminal was originally excluded
("no always-on terminal") to avoid IDE drift, but an on-demand companion
terminal proved to be part of the core flow rather than developer-tool
creep.

Options considered for the emulation core: reusing `alacritty_terminal`
(mismatched ownership and API churn), linking libghostty (C ABI not yet
stable, brings its own runtime), and writing an emulator from scratch
(correctness risk without a mature test corpus). Porting ghostty's terminal
core file by file — tests included — offered proven correctness with full
ownership inside our Rust workspace.

## Decision

- Port ghostty's `src/terminal/` (Zig, MIT) to Rust as
  `core/crates/terminal`, keeping algorithms, data layouts, and the
  upstream test suite faithful. Deviations are commented at the site.
  The crate uses no `unsafe` code and depends only on `unicode-width`.
- PTY process management is a small original crate (`core/crates/pty`,
  libc only). `app-ffi` exposes the terminal to the app as coarse POD
  frames; presentation policy (for example, snapping selection highlights
  to wide-glyph boundaries) lives at that boundary, never as silent edits
  to ported files.
- The macOS pane is native AppKit/SwiftUI. Live rendering uses Metal
  (glyph atlas plus instanced quads); the Core Graphics draw path is
  retained as the offscreen oracle that differential tests compare
  against.
- The terminal is an on-demand toggle panel (⌘J / Ctrl+`) below the
  editor for running and reviewing agent CLI sessions. It is not an
  always-visible IDE terminal, and IDE-oriented chrome stays out of
  scope.
- OSC 52 (escape sequences asking the terminal to write the clipboard) is
  parsed but not honored. The policy decision is deferred; the safe
  default stands until it is made deliberately.

## Consequences

- Agent sessions can be run and reviewed without leaving the app. The
  product guardrail is restated from "no terminal" to "no persistent
  terminal chrome" across the product docs.
- `core/crates/terminal` carries roughly two thousand upstream-derived
  tests. Fidelity is the maintenance contract: fixes port the corrected
  upstream behavior with a citation instead of diverging ad hoc, which
  keeps future upstream comparisons meaningful.
- ghostty's MIT license and the ported snapshot hash are recorded in
  `core/THIRD_PARTY_NOTICES.md`.
- The Metal renderer adds a shader and glyph-atlas subsystem; the CG
  oracle keeps it honest. A future Windows app can reuse the same
  architecture (Direct3D/DirectWrite against the identical frame ABI).
- Behavior users can rely on is specified in `docs/specs/terminal.md`.
