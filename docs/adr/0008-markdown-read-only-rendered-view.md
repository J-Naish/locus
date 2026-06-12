# 0008. Make The Markdown View A Read-Only Rendered Document

## Status

Accepted, then partially superseded by ADR 0009: the read-only scoping
was reversed (light editing is part of this view's purpose); the display
transformation this ADR introduced stands and is the editing substrate.
Also supersedes the editing-time concealment and caret-interaction parts
of ADR 0007 (its rendering model — live styling over the Rust buffer,
byte fidelity, the Rust-core direction — stands).

## Context

ADR 0007 chose live-styled source: markdown renders typeset while staying
editable in place, with syntax markers concealed at rest and revealed at
the caret. Implementing it showed that almost all of the complexity — and
every defect class found in review — came from the *editing* half of that
contract: marker reveal, caret clamping over concealed runs, the Backspace
peel matrix, IME freezing, and keeping wrap measurement in sync with
reveal state. Concealment itself also proved unsatisfying in its safe
form: markers hidden by color retain their advance, so headings indent by
their `#` width and the page reads as subtly broken.

The product owner then clarified the intent: this view exists to *read*
Markdown beautifully. Raw editing will be a separate editor surface added
later. Markers must not exist in the rendered page at all — not at rest,
not on hover, not at the caret — and must not reserve space.

## Decision

The Markdown document view is a **read-only rendered document**:

- **Display transformation.** Each source line renders as a display string
  with marker characters *removed* (not hidden): heading prefixes, list
  and task markers, quote prefixes, fence backticks, emphasis/code/link
  syntax, escape backslashes. A per-line `DisplayMap` records the
  display↔buffer column mapping for selection, copy, hit-testing, and
  accessibility. Markers occupy no space; there is no reveal state.
- **Layout-driven structure.** Indentation and marker columns come from
  per-line layout (first-line indent, hanging indent, wrap width), not
  from source characters: typeset bullets, ordered numbers, checkboxes,
  quote bars, and cards are drawn into layout-reserved space.
- **Read-only routing.** Markdown keeps the editable `TextBuffer` backend
  (styling, line states, margin line numbers, external-change reload all
  depend on it) but the view receives `isEditable = false`: typing, IME,
  undo, cut/paste, and save are inert behind existing guards; no caret is
  drawn. Selection and copy remain; copy yields the *visible* text.
- **Editing is deferred, not redefined.** A raw Markdown editor (plain
  source, the existing editing engine) ships later as a separate surface.
  Until then Markdown files are view-only in Locus — a typo is fixed in
  any external editor or by an agent, and Locus reflects the save
  automatically. This is an accepted, explicit product tradeoff, not an
  oversight.

## Consequences

- The interaction-contract machinery of ADR 0007 — span reveal, caret
  clamping, the peel matrix, emphasis shortcuts, IME concealment freezing
  — is deleted rather than completed. The remaining correctness surface is
  selection/copy/hit-test mapping through `DisplayMap`.
- Byte fidelity is trivial: the view never mutates the buffer; the file on
  disk is untouched by viewing.
- The page can finally match its typography: no marker advances means
  headings sit flush, lists indent by design, and the rendered result is
  the only thing on screen — the Notion-like reading experience the
  product wants, on top of plain local files.
- Per-keystroke performance constraints disappear with editing; the hot
  paths are open, external reload (agents rewriting files), resize, and
  scroll.
- Copying yields what the reader sees. A "copy as Markdown" affordance and
  the raw editor are future work.
