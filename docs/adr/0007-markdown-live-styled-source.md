# 0007. Render Markdown As Live-Styled Source In The Custom Text Engine

## Status

Accepted; the editing-time concealment and caret-interaction rules are
superseded by ADR 0008 (the Markdown view is now a read-only rendered
document). The rendering model — live styling over the Rust buffer, byte
fidelity, the Rust-core classification direction — stands.

## Context

Markdown is the core document type in Locus, and the product direction calls
for editing that feels document-like, not code-like, with Notion-like ease as
a readability reference but explicitly without Notion's block-database
complexity (see `docs/product/ux-direction.md`). At the same time, Locus
files are routinely written by AI agents, the disk is the source of truth,
and the app must never hide or reformat the underlying file.

Three rendering architectures were considered:

1. **Block WYSIWYG** (Notion, Craft): parse Markdown into a block model,
   render blocks, serialize back on save. Rejected: serialization cannot
   guarantee byte fidelity (blank lines, indent style, marker choice all get
   normalized), it builds an app-specific content model the product
   explicitly prohibits, and it would replace the editing engine wholesale.
2. **Syntax highlighting only** (iA Writer): markers always visible, styled
   to recede. Safe, but it never reaches "typeset document" quality — raw
   syntax remains the dominant texture, which is what the product wants to
   move past for non-technical users.
3. **Live-styled source** (Typora, Bear): the plain-text source is the only
   document model; lines render with real typography; syntax markers stay in
   the buffer but are concealed on screen, revealed only at the caret.

Survey of shipped editors shows the main failure modes of live styling are
line-level marker reveal (vertical layout shift on every caret move, as in
Obsidian) and auto-expanding links under the caret (cursor jumps, as in
Typora). Span-level reveal with stable block layout avoids both.

The existing engine (ADR 0006) is a custom virtualized renderer over the
Rust `TextBuffer` with uniform row heights. It currently draws rows with
TextKit (`NSAttributedString.draw`) but measures wrapping with
`CTTypesetter` and hit-tests with `CTLine`. Real document typography
requires variable per-line row heights, and concealment requires custom run
advances — which TextKit drawing does not honor.

## Decision

Render Markdown as live-styled source inside the existing custom text engine:

- The Rust `TextBuffer` remains the single document model. One source line
  renders as one styled block line. Rendering never mutates the buffer;
  copy, cut, and save always produce raw Markdown.
- **Display string identity**: the attributed line used for layout, drawing,
  and hit-testing contains every buffer character. Concealment is an
  attribute (zero-point or fixed-point run advances), never character
  removal, so engine sites that treat the displayed line as buffer content
  stay correct by construction.
- **One CoreText row pipeline**: row drawing migrates from TextKit to
  `CTLineDraw`, so measurement, drawing, caret x, and hit-testing share one
  typesetter and run-delegate advances implement concealment. Effects
  TextKit drew for free (the IME marked-text underline) are drawn manually.
- Inline markers reveal per span under the caret (boundary-inclusive); block
  prefixes render as typography (bullets, checkboxes, bars, cards) and are
  not revealed in place. Block layout never shifts from caret travel; inline
  reveal may re-wrap the caret line only, absorbed by caret-anchored
  scrolling.
- The engine gains variable per-line row heights, paddings, and x-origins,
  with a uniform fast path so non-Markdown documents keep current behavior
  and budgets. Read-only `LargeFile` documents and huge lines keep the plain
  uniform rendering.
- Markdown classification lives in the Rust core (`app_core::markdown`) as
  an incremental per-line index with zero external dependencies, crossing
  FFI as compact spans using the established snapshot pattern. It is in the
  core because it runs on every edit over the Rust-owned buffer — the
  "where useful" performance case, not Rust by default.

The full design, interaction contract, and phasing live in
`docs/specs/markdown-document-view.md`.

## Consequences

- Byte fidelity holds by construction; there is no serializer to drift.
- The document view and the file never disagree: what renders is the file,
  with presentation applied per line. Copy yields exact source, which also
  serves as the v1 raw-inspection story.
- The engine takes on real layout complexity (per-line heights and
  x-origins, concealment-aware caret/IME/accessibility geometry). This is
  the main cost and the main regression surface; it is paid once, inside
  the engine, rather than by replacing the engine.
- The TextKit-to-CoreText draw migration is prerequisite work that touches
  every document type, gated by draw-parity tests.
- A hand-written classifier intentionally covers a documented CommonMark
  subset; unsupported constructs render as plain text rather than erroring.
- Per-span reveal, caret clamping, and the Backspace peel matrix introduce
  editing semantics that must be tested as a contract (specified in the
  spec).
