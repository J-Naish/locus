# Markdown Document View

Design and implementation plan for the core Markdown experience: a Markdown
file renders as a beautifully typeset document and stays directly editable in
place. This is the highest-value surface in Locus.

Related decisions: [ADR 0006](../adr/0006-custom-text-engine-over-nstextview.md)
(custom text engine), [ADR 0007](../adr/0007-markdown-live-styled-source.md)
(live-styled source for Markdown). Product expectations:
[core-feature-scope.md](core-feature-scope.md),
[ux-direction.md](../product/ux-direction.md),
[performance-budget.md](performance-budget.md).

Roadmap position: this deliberately pulls the Phase 2 "richer Markdown
editing" item forward and makes it the core document surface of the
prototype, because the typeset Markdown view is the product's main value
claim. The roadmap is annotated accordingly.

## Goal

- Markdown reads as a typeset document: real heading sizes, list bullets,
  quote bars, code cards, checkboxes — not source code with colors.
- The document stays editable in place. There is no preview mode, no raw/rich
  toggle, and no mode switch.
- The file on disk is the document. Rendering never rewrites, reformats, or
  normalizes the file. Byte fidelity is absolute: AI agents write these files,
  and Locus must never surprise them or the user with silent changes.

What you see is the file: copy and cut always yield the exact source
(including concealed characters inside the selection), and save writes only
what the user actually edited. That is the v1 answer to "do not make users
unsure what will be saved"; if real-world use shows users still need to *see*
raw source in-app, the deferred raw-source toggle gets promoted.

## Non-goals (v1)

- Notion-style block model, drag handles, or `/` insert menus (prohibited by
  [ux-direction.md](../product/ux-direction.md) anti-goals).
- Raw-source toggle, split preview, or export.
- Typeset tables, inline image loading, math, footnotes (deferred; see
  Deferred work).
- Formatting toolbar or heading-level menus.

## Architecture summary

Markdown renders as **live-styled source** in the existing custom text engine
(per ADR 0007): the Rust `TextBuffer` remains the single source of truth,
every source line maps to one rendered block line, and syntax markers are
*concealed by rendering*, never removed. Block WYSIWYG was rejected because
round-trip serialization cannot guarantee byte fidelity.

Two load-bearing engine decisions:

- **Display string identity.** The attributed line handed to layout, drawing,
  and hit-testing contains *every buffer character*. Concealment is an
  attribute (a zero-point or fixed-point advance), not character removal.
  This keeps every site that treats the displayed line as buffer content
  (`lineLengthUTF16`, word/character stepping, `composedLineForDisplay`,
  accessibility text) correct without translation. The per-line
  `ConcealmentMap` is then a thin layer: concealed ranges, caret-clamp zones,
  and reveal-span boundaries — not a string remapping.
- **One CoreText row pipeline.** Today rows are drawn with TextKit
  (`NSAttributedString.draw`) but measured with `CTTypesetter` and hit-tested
  with `CTLine`. TextKit ignores custom run advances, so concealment has no
  route through it. Row drawing migrates to `CTLineDraw` (run-delegate
  advances for concealed runs), unifying measure, draw, caret x, and
  hit-testing on the same typesetter. Consequence: effects TextKit drew for
  free (the IME marked-text underline) are drawn manually. *Interim
  divergence*: until Phase A unifies the pipeline, concealment ships on the
  TextKit draw path via a near-zero-size font whose advances every layer
  honors, with `.kern` providing fixed advances (indent spacers, chip
  padding) where run delegates would later be used — see the milestone
  plan.

New pieces, in dependency order:

1. **Variable-height row layout + CoreText row drawing** (Swift, engine):
   per-line row heights, paddings, and x-origins replace the single uniform
   `lineHeight` scalar and fixed left margin.
2. **Markdown index** (Rust core + FFI): incremental per-line block
   classification and on-demand inline spans, crossing FFI as compact spans.
3. **Markdown stylist** (Swift): classification → attributed display lines,
   layout specs, decorations, concealment maps; styled wrap measurement.
4. **Concealment interaction** (Swift): span-level marker reveal at the
   caret, caret clamping, the Backspace peel matrix, interactive checkboxes
   and links.

Markdown styling applies only to editable `TextBuffer`-backed documents:
routing branches on the backend, not on syntax alone. A read-only `LargeFile`
Markdown document (over the open-byte limit) keeps today's uniform plain
rendering — a 256 MiB file is not a typeset-reading scenario, and the
`LargeFile` FFI handle has no classification surface. Lines over the
huge-line threshold (20,000 characters) keep the existing unstyled grid path
at body metrics. Non-Markdown documents keep today's uniform-height fast
path untouched.

## UX design

### Principles

- A quiet, well-typeset page — closer to Apple Notes and Craft than to an IDE.
- **Block layout never shifts from caret travel.** Moving the caret never
  changes any line's block classification, row height, or padding. Inline
  marker reveal may re-wrap the caret line only, and any resulting shift is
  absorbed by caret-anchored scrolling (rule 10) so the text under the
  user's eyes stays put.
- Nothing is ever hidden *from the file*. What is concealed on screen is
  still in the buffer, still copied on copy, still saved on save.
- Comfortable Japanese: generous line height for mixed CJK/Latin text, IME
  composition is never disturbed by concealment changes, and the candidate
  window is always positioned from concealment-aware geometry.

### Layout

- Markdown content is set in a centered column. Measure is defined in body
  ems: 40 × body size = 600 pt at 15 pt body (≈40 zenkaku characters, ≈80
  Latin characters), minimum horizontal padding 32 pt. Narrower cards use
  the available width minus padding. Japanese fixture text is an explicit
  input to the tuning pass. Other file types keep the current full-width
  layout.
- The classic editor gutter is replaced for editable Markdown by margin
  line numbers (next section). The read-only `LargeFile` Markdown path
  keeps the classic gutter (it renders plain, and very large files are
  exactly where line numbers matter most). Note that gutter width feeds
  wrap width, so the existing wrap tests that toggle line numbers are the
  regression surface.
- The existing card top inset and scroll behavior are unchanged.

### Line numbers

Line position is first-class information in this product: agents report
edits as `file:line`, and the numbers on screen must match what an agent
means by L42. The typeset page must answer "which line is this" without
ever looking like an IDE.

- Margin line numbers are **always visible** for editable Markdown.
  Quietness comes from visual weight (small, faint), never from conditional
  visibility: no hover or scroll triggers, no fade timers, no state machine.
  (An earlier intent-driven design — fade in on pointer/scroll, hide after
  a delay — was implemented and read as instability; persistent-but-faint
  is the rule.)
- Numbers are per *logical source line*: a wrapped line is numbered on its
  first visual row only, sharing that row's baseline; continuation rows are
  never numbered.
- Right-aligned in the left margin, ending 10 pt before the text column;
  monospaced-digit 10 pt; quaternary-level color, with the caret line one
  step stronger (tertiary). No gutter background, no separator — numbers
  float on the page.
- The Markdown layout **reserves a number rail**: rail width derives from
  the digit count of the document's line count (as the classic gutter
  does), and the centered measure is computed inside the space left over,
  so numbers can never clip at narrow window widths.
- There is no document-status readout (line count / byte size). One was
  built and removed by product decision: the page carries no persistent
  chrome beyond the numbers themselves.
- The read-only `LargeFile` Markdown path keeps the classic gutter.

### Type scale

System font (SF Pro) for prose, monospaced system font for code. All values
are named constants in one metrics type; expect a visual tuning pass with the
product owner on a real device before they are final. Named tuning cases:
H3 next to H4 in both Japanese and English, H6 directly above body text,
a document starting with H1, and a 40-character Japanese paragraph at the
full measure.

| Element | Font | Row height | Padding above | Padding below |
| --- | --- | --- | --- | --- |
| Body | 15 pt regular | 24 pt | 0 | 0 |
| H1 | 26 pt bold | glyph + paddings | 20 | 6 |
| H2 | 21 pt bold | glyph + paddings | 16 | 5 |
| H3 | 18 pt semibold | glyph + paddings | 12 | 4 |
| H4 | 16 pt semibold | glyph + paddings | 10 | 3 |
| H5 | 14 pt semibold | glyph + paddings | 8 | 2 |
| H6 | 13 pt semibold, secondary color | glyph + paddings | 8 | 2 |
| Blank line | — | 24 pt (body height) | 0 | 0 |
| Code block text | 13 pt mono | 20 pt | 0 | 0 |
| Fence line | 11 pt mono label | 18 pt | 0 | 0 |
| Horizontal rule | — | 24 pt | 0 | 0 |

Notes:

- Body row height 24 pt at 15 pt type (≈1.6) is chosen for mixed
  Japanese/Latin comfort.
- Blank lines are full body height deliberately: pressing Return and then
  typing must not change the new line's height between those two keystrokes
  (contract rule 9). Paragraph spacing is therefore generous and honest —
  one blank line in the file is one body-height row on screen.
- Heading padding-above is suppressed on line 1 so a document starting with
  a heading aligns to the same top inset as one starting with body text.
- A wrapped logical line uses one uniform row height for all its visual
  rows; heading paddings apply to the first/last visual row of the line.
- An empty heading line (`## ` with no content) takes its row height from
  the heading font's metrics, not from measured glyphs.

### Block elements

- **Headings (ATX `#`–`######`, setext)**: rendered at scale, prefix
  concealed. A setext underline line renders as a thin rule row; the caret
  skips it (Up/Down passes through), and it is removed by selecting across
  it or by joining from the heading line's end.
- **Paragraphs**: body text. Source line breaks render as line breaks (the
  editing-first convention used by Typora/Obsidian; we do not re-flow
  paragraphs the way a CommonMark renderer would).
- **Bullet lists (`-`, `*`, `+`)**: marker concealed; a typeset bullet is
  drawn in the marker column: `•` (depth 1), `◦` (depth 2), `▪` (depth 3+),
  secondary color. Indent 24 pt per depth; wrapped rows hang-align to the
  text start. Nesting depth is detected tolerantly (2–4 space steps,
  CommonMark's marker-relative rule) because agents commonly emit 4-space
  nesting; the file is never "corrected".
- **Ordered lists (`1.`, `1)`)**: the number *and delimiter* from the
  source are displayed as typeset text (`1.` or `1)`, tabular digits,
  secondary color). We do not renumber or pretend the file says something
  it does not. The marker column widens to the widest number in the list
  (minimum 24 pt) so `10.` and `100.` align.
- **Task items (`- [ ]`, `- [x]`)**: marker and brackets concealed; a drawn
  14×14 pt rounded-square checkbox (1.5 pt secondary stroke; checked =
  accent fill with check glyph). Checked item labels render in secondary
  color, no strikethrough. Interaction is specified in Phase E.
- **Blockquotes (`>`)**: stacked accent bars, one 3 pt bar per nesting
  depth (≤3, Bear-style), each adding a 14 pt text inset; `>` markers
  concealed. Text stays primary color.
- **Fenced code blocks**: a rounded card (8 pt radius, theme code background)
  spans from opening to closing fence. Fence rows render at 18 pt: the
  opening fence shows the info string (language) as a muted 11 pt label;
  backticks concealed. Code lines render in 13 pt mono. No syntax
  highlighting inside fences in v1.
- **YAML frontmatter** (opening `---` on line 1): rendered like a muted code
  card labeled `frontmatter`, mono text in secondary color. Agents emit
  frontmatter constantly; it should look intentional but recede.
- **Horizontal rules (`---`, `***`, `___`)**: a 1 pt centered rule in the
  separator color; source characters concealed.
- **Anything that does not parse** renders as a plain body paragraph — raw
  text, never an error state.

### Inline elements

- **Bold / italic / bold-italic / strikethrough**: rendered with markers
  concealed (reveal rules below). Both asterisk and underscore forms
  (`**`/`__`, `*`/`_`) are supported; intraword `_` is not emphasis, per
  CommonMark.
- **Inline code**: 13 pt mono on a rounded chip (4 pt radius, theme inline
  code background). The concealed backticks render as 4 pt advances, which
  become the chip's horizontal padding — no extra characters, no layout lies.
- **Links `[label](url)`**: label shown in the accent color; brackets and
  URL concealed. Hovering shows an underline, and after a short delay a
  quiet tooltip with the destination URL and the hint "⌘クリックで開く /
  Cmd+click to open". The pointing-hand cursor appears only while Cmd is
  held (a plain click places the caret, and the cursor must tell the truth
  about that); otherwise the I-beam stays. Links never auto-expand on caret
  entry (Typora's most-complained-about failure). URL schemes are restricted
  to `http`/`https`; anything else renders with the URL visible and is not
  clickable — file content is untrusted input.
- **Images `![alt](url)`**: v1 renders the alt text in secondary color
  with the `![`/`](url)`/`)` syntax concealed. No loading, no layout
  surprises; the photo-symbol chip treatment and inline rendering are
  deferred work.
- **Escapes (`\*`)**: the backslash is concealed; the escaped character
  renders literally.

### Interaction contract

These rules are the contract; tests encode them. "Content start" means the
first buffer column after a line's concealed block prefix.

1. **The buffer is the file.** Copy, cut, and save always produce raw
   Markdown. Rendering never mutates the buffer.
2. **Inline reveal is span-level and boundary-inclusive.** While the caret
   or selection touches an inline span — including positions immediately
   before its opening marker and immediately after its closing marker —
   that span's markers render visibly in tertiary color at the span's font
   size. Escapes (`\x`) are inline spans for this rule: the backslash
   reveals on touch. Once revealed by typing inside the span, the state persists until
   the caret leaves the span's outer boundary. Row height never changes from
   reveal; the line may re-wrap (absorbed per rule 10). Boundary inclusion
   means arrowing through markers always moves the caret visibly — no dead
   keypresses — and typing the closing `)` of a link does not collapse the
   URL under the caret mid-keystroke.
3. **Block prefixes are never revealed in place.** They render as typography
   (bullets, checkboxes, bars, cards, rules). The caret cannot enter a
   concealed prefix. Exception — **whole-marker lines** (thematic breaks,
   setext underlines, fence delimiters, frontmatter delimiters), where the
   entire line is marker: these reveal as muted source text while the caret
   is on that line, so they are never an invisible editing zone; row height
   does not change on reveal. Caret travel:
   - Left at content start moves to the previous line's end — never sticks.
   - Right at a line's end moves to the next line's content start, skipping
     its prefix.
   - Home / Cmd+Left lands on content start; column 0 of a prefixed line is
     unreachable by caret travel.
   - Up/Down keep the goal column in display x, translated per line, so
     vertical travel through mixed bullets and headings does not drift.
   - Clicks in padding strips and blank rows resolve to the nearest row's
     nearest caret position; there are no dead zones.
4. **Backspace at content start peels one level**, one undo step per press:

   | Line kind | Backspace at content start |
   | --- | --- |
   | Heading | remove prefix → paragraph |
   | Blockquote depth n | depth n−1 |
   | Task item | remove `[ ]`/`[x]` → bullet item |
   | List item depth n > 1 | outdent one level |
   | List item depth 1 | remove marker → paragraph |
   | Paragraph | join with previous line (normal) |

   Forward-delete at the end of the previous line deletes the newline only —
   the honest primitive — even if the joined line then renders raw.
5. **Typing syntax works live.** Typing `# ` at line start restyles the line
   as a heading immediately; deleting a fence's backtick restyles everything
   the fence contained. Restyle cascades from cross-line state are honest
   and immediate (and listed as a known behavior in Risks).
6. **IME composition is protected.** While marked text is active on a line,
   that line's concealment state *and block classification* are frozen; row
   height and wrap follow the composed text (height may grow with the
   composition — that is the text changing, not the caret). Marked text
   inherits the line's resolved font (composing inside a heading composes at
   heading size). All `NSTextInputClient` geometry — marked-text rects,
   candidate-window positioning, reconversion ranges — uses concealment-aware
   x/y mapping.
7. **Selection is honest and contiguous.** Selection across concealed
   regions includes the concealed characters (zero-width on screen, present
   in the copied text); concealed runs contribute no visible highlight rect.
   Deleting a selection removes exactly the selected buffer range —
   concealed characters strictly inside it go with it, the same way copy
   includes them. Multi-line selection highlight extends through padding
   strips as one contiguous band. Double-click selects the visible word
   only, never silently extending into adjacent concealed markers.
8. **Accessibility reads the buffer.** VoiceOver continues to read buffer
   text; all accessibility ranges and any future buffer-range highlight
   (find, search-hit jump) translate through the concealment-aware geometry.
9. **Return is calm.** Pressing Return and then typing must not change the
   new line's height between those two keystrokes (blank rows are body
   height).
10. **Caret-anchored scrolling.** When a reveal or restyle changes the
    y-origin or row count of any revealed line (inline reveal re-wrap —
    caret or selection — or typing `# ` adding heading padding), the
    viewport compensates in the same frame so the caret's screen position
    stays fixed; the shift is absorbed away from the reading point.
11. **The caret is constant.** Caret width and color never change; only its
    height follows the row, so the size change reads as typography, not a
    glitch.

### Theme integration

Extend `LocusTheme` with Markdown slots, following the existing fixed-look
pattern (`LocusChromeColors`, three themes, tests in `LocusChromeColorsTests`):

- `accent`: links, checkbox fill, quote bar. Light = system
  `controlAccentColor` (native feel); Paper/Dark = the existing clay.
- `codeBackground` / `inlineCodeBackground`: a step deeper than
  `documentCard` per theme (Light: ~4% darken; Paper: deeper cream; Dark:
  lighter slate).
- `rule`: horizontal rule / setext underline color.

## Implementation plan

Each phase lands as its own reviewed change with tests written first
(repository TDD rules apply), and must leave non-Markdown behavior and all
existing tests green. Phases A and B are independent; C needs both; D needs
C; E needs D.

### Phase A — variable-height rows and the CoreText row pipeline (Swift)

The engine's geometry is built on a single `TextViewportLayout.lineHeight`
scalar (`LineRenderingTextView.swift:1173`) and a fixed left text origin.
This phase generalizes geometry and unifies drawing, *without* changing what
any document looks like (markdown styling arrives in Phase C).

- `LineLayoutSpec` per logical line: row height, padding above/below, first
  line indent, head (hanging) indent, wrap width, x-origin. Provided by a
  per-syntax provider; non-Markdown syntaxes return one uniform spec,
  preserving an O(1) arithmetic fast path so huge-file behavior and budgets
  are unchanged.
- A row-geometry index alongside `WrapIndex`: per-line cumulative y offsets
  (prefix sums over `rowCount × rowHeight + paddings`), spliced on edit the
  same way `updateWrapIndex(afterChange:)` splices row counts; lookups are
  binary searches.
- Migrate row drawing from `NSAttributedString.draw` to `CTLineDraw`
  (flipped-context baseline handling), so measure, draw, caret x, and
  hit-testing share one typesetter and concealment advances become possible
  in Phase C. Draw the IME marked-text underline manually (TextKit drew it
  from `.underlineStyle`).
- Update every geometry consumer. Y sites: visible-row range, caret rect,
  selection rects, hit-testing, scroll-to-caret, frame height *including the
  overscroll tail* (`TextViewportLayout.frameHeight` subtracts
  `overscrollAnchorRowCount × lineHeight`; the tail must use actual last-row
  heights), gutter drawing, and the IME candidate-window rect
  `firstRectInViewCoordinates(forCharacterRange:)` (y, height, and x). X
  sites (the centered column and hanging indents move x as well): the draw
  origin, `endpoint(at:)` hit-testing, `scrollCaretToVisible`, the I-beam
  cursor boundary (`resetCursorRects` / `mouseMoved`), and the
  width-equality guards (`lastWrapWidth == wrapContentWidth` and
  `updateLayout`), which must compare the *effective measure* — a window
  resize from 800 to 900 pt leaves a 600 pt-clamped measure unchanged and
  must not trigger a rebuild.
- Huge-line subsystem (`hugeLineColumns`, `drawHugeLineRows`, huge branches
  of `visualRow(of:)` / `caretGeometry`): stays uniform-grid; policy is that
  huge lines render unstyled at body metrics even in Markdown.
- Wrap measurement keeps using the engine font in this phase (styled
  measurement moves in Phase C with the stylist). Note: drawing and
  measurement currently agree on the base font because `highlightedLine`
  re-applies it over rule fonts; do not "fix" that here.
- Verified non-issues (do not spend time): drag autoscroll is AppKit
  `autoscroll(with:)` with no row math; there is no scroll-to-line-on-open
  or find/jump feature today; scroller adjustment is x-inset only.

Tests: row-geometry math; splice-vs-full-rebuild parity; hit-test/caret/
IME-rect round-trips; `accessibilityVisibleCharacterRange` under mixed
heights; CTLineDraw visual parity for plain text (bitmap precedent exists).
Exit: `scripts/perf-smoke.sh` within budget; record a
`scripts/perf-record.sh` label for the engine change.

### Phase B — Markdown index (Rust core + FFI)

Markdown classification lives in the Rust core because it runs on every edit
over the Rust-owned buffer and crosses FFI as compact spans — the sanctioned
"where useful" case in
[technical-direction.md](../architecture/technical-direction.md) and the
performance-first core rule. Zero new dependencies — a hand-written
classifier for the documented subset (the bundle budget and CommonMark's
long tail both argue against importing a full parser).

- `app_core::markdown`: an incremental index over buffer text.
  - Build: full-document line classification reads a buffer *snapshot*
    off-main (the live handle is main-actor-owned and not Sendable),
    chunked like the wrap build, revalidated by revision on completion
    (the `completeWrapBuild` pattern).
  - `splice(change)`: runs synchronously on-main against the live handle,
    reclassifying only affected lines and expanding while cross-line state
    (fence open/close, setext, frontmatter) changes.
  - Edit pipeline order is part of the contract: buffer edit → index splice
    → restyle changed lines → wrap/row-geometry splice → caret/scroll.
    Rewritten lines must never be measured against stale layout specs.
  - External reload (disk is source of truth) reuses the open path: new
    buffer, full index and row-geometry rebuild, concealment and IME state
    reset. A test pins this.
  - Per-line block info: kind, heading level, list depth (tolerant 2–4 space
    steps / marker-relative) and marker width, content start (UTF-16), task
    state, fence info-string range, ordered number text range.
  - On-demand per-line inline spans for the visible band: kind, range, link
    URL range. All offsets UTF-16.
- Supported subset v1 (documented in the module): ATX headings 1–6, setext
  H1/H2, paragraphs, blank lines, bullet/ordered/task list items (nesting
  ≤5), blockquotes (nesting ≤3), fenced code (``` and ~~~, info string),
  YAML frontmatter, thematic breaks, bold/italic/bold-italic,
  strikethrough, inline code, links, image syntax, backslash escapes.
  Explicitly not v1: indented code blocks, HTML blocks, autolinks,
  reference links, tables (classified raw → body text).
- FFI (`app-ffi`): snapshot pattern identical to the workspace listing —
  opaque handle, counted borrowed arrays of `#[repr(C)]` span structs, copy
  then free on the Swift side, dual layout tests (Rust `offset_of!` + Swift
  `MemoryLayout`), status codes in a new 200+ band, hand-written header
  update in `core/include/locus_core.h`. Additive exports only (no ABI bump
  per the stated policy).
- Swift `CoreBridge` wrapper returning Sendable value types.

Tests: Rust unit tests per element including Japanese text, mixed-width
content, 4-space-nested list fixtures, fence edge cases, splice parity with
full rebuild; FFI layout tests; CoreBridge integration tests. Optional: an
`app-cli` bench subcommand for the classify pass to leave a perf trail.

### Phase C — Markdown stylist, styled measurement, decorations (Swift)

- `MarkdownLineStylist` replaces the regex highlighter path for editable
  Markdown documents (branch on backend: editable `TextBuffer` present; the
  read-only `LargeFile` path keeps the plain renderer, with a test pinning
  the fallback). The styling entry points change signature: today
  `highlightedLine(_ line: String)` receives only text; the stylist needs
  (line index, revision)-keyed lookups against the Markdown index for block
  info and cross-line state. Both the cached band and the single-line
  fallback path are updated — a fence cannot be styled from line text alone.
- Stylist output per line: the attributed display string (identity with the
  buffer line; fonts, colors, concealment advances as attributes), the
  `LineLayoutSpec`, the `ConcealmentMap` (concealed ranges, clamp zones,
  span boundaries), and decoration metadata (quote bars, code/frontmatter
  card spans, inline chips, rules, bullets, checkbox glyph + state).
- **Styled wrap measurement** moves here, reaching all three build paths:
  the synchronous build, the detached background build (its worker holds
  only a Sendable reading — extend it with per-line classification spans
  and a font table derived from the same buffer snapshot, revision-validated
  on completion), and the per-edit splice; plus the draw/caret-side
  `visualRowStartOffsets(ofLine:attributed:)` must consume identical
  attributed content. Measure-vs-draw parity tests across all three paths
  are mandatory.
- Decorations draw in `draw(_:)` behind text, derived from the visible band
  plus fence pairing from the index (a code card's top/bottom are the fence
  rows, so partial visibility works without measuring off-screen rows).
- Centered measure for Markdown; hide the line-number gutter for Markdown
  (`supportsLineNumbers`), accounting for the gutter-width → wrap-width
  coupling in the existing wrap tests.
- Theme slots added to `LocusTheme` with the existing three-theme tests.
- Styling stays visible-band only, preserving the cached-band model.

Tests: stylist output per element (attributed runs, concealment ranges,
specs); display-string identity property (`displayString == bufferLine` for
every styled line); measure-vs-draw parity; bitmap tests for decorations
(precedent: `DocumentCardModifierTests`); theme contract tests; gutter-off
wrap regression.

### Phase D — concealment interaction (Swift)

- Caret-span reveal per contract rule 2 (boundary-inclusive, persistent
  while inside): track the span under the caret/selection; restyle only the
  affected lines (invalidate those lines in the cached band). Pure functions
  for span-hit and state transitions so they unit-test cleanly.
- Caret travel rules 3 (clamping, Left/Right/Home/Up-Down goal column,
  padding-strip clicks) and the Backspace peel matrix of rule 4, each one
  undo step.
- Caret-anchored scrolling (rule 10) for caret-line restyles.
- IME (rule 6): enumerate and fix the four marked-text sites —
  `composedLineForDisplay` (buffer-column splicing and base-font styling;
  marked text must inherit the line's resolved font),
  `drawCompositionCaret`, `firstRectInViewCoordinates`, and the
  `markedRange`/`selectedRange`/`attributedSubstring` offset exchange.
- VoiceOver range translation (rule 8).
- Selection visuals (rule 7): contiguous band through paddings; no visible
  rect for concealed runs; visible-word double-click.

Tests: reveal-state transitions (caret enters/leaves/boundary-touches a
span); the full caret-travel matrix; the peel matrix per block kind; undo
grouping; IME composition on a styled heading line including candidate-rect
position; accessibility parameter conversion; caret-anchored scroll
compensation.

### Phase LN — margin line numbers (Swift)

Implementable against the current uniform-row engine; does not depend on
Phases A–D.

- Engine-only: draw margin numbers for editable Markdown in `draw(_:)` —
  every logical line in the visible band, first visual row only,
  right-aligned ending 10 pt before the text column, always visible (no
  visibility state, no timers). Caret line tertiary, others quaternary.
- Reserve the number rail in the Markdown layout math (digit-count-derived
  width feeding the centered-measure calculation) so numbers never clip.
- Read-only Markdown keeps the classic gutter (`supportsLineNumbers` stays
  true for that backend).

Tests: number-to-line mapping under wrapping (continuation rows
unnumbered); all band lines numbered with no event/timer dependency; rail
fit at 1–6 digits and at the minimum window width; caret-line emphasis;
read-only fallback keeps the gutter.

### Phase E — interactive elements (Swift)

Rule-3 caret clamping means a user can never place the caret before a list
marker to manage indentation by typing — so list structure needs first-class
keys; and the target user (a non-engineer) needs a way to produce emphasis
without knowing Markdown syntax. These are required by the interaction model
and by "rich document-like editing" and "checklist support" (Should-level
items in [core-feature-scope.md](core-feature-scope.md)) — not convenience
chrome.

- **Checkbox**: hit area is the full marker column × row height (not the
  14 pt glyph); hover shows a subtle stroke darkening and pointer; pressed
  state; click toggles `[ ]`↔`[x]` via the normal buffer edit path (dirty
  state, undo, save all standard). Mouse-down-plus-drag starting on the
  checkbox falls through to text selection so toggling and selecting never
  fight.
- **Links**: hover underline + delayed URL tooltip; pointing hand only while
  Cmd is held; Cmd+click opens `http`/`https` via `NSWorkspace`.
- **Lists**: Return inside an item continues the list — bullets keep the
  marker, ordered items insert previous number + 1 with the same delimiter
  (never renumbering existing lines), task items insert `- [ ]`. Return on
  an empty item removes the marker and ends the list. Tab / Shift+Tab at
  item start indent/outdent one level.
- **Emphasis keys**: Cmd+B / Cmd+I wrap (or unwrap) the selection in
  `**` / `*` as plain, byte-honest buffer edits with normal undo. This is
  the standard macOS document-editing vocabulary (Notes, Mail, Craft), and
  without it a non-engineer cannot make text bold at all.

Tests: toggle writes exact bytes (fidelity assertions); hit-area and
drag-fall-through; scheme restriction; list continuation/outdent matrix
including ordered-number increments; emphasis wrap/unwrap round-trips; undo
grouping.

## Performance

Budgets (snapshot — source of truth is
[performance-budget.md](performance-budget.md)): text buffer open ≤ 50 ms,
scroll ≤ 20 ms, edit ≤ 50 ms at 256 KiB; app bundle ≤ 10,240 KiB.

- Classification is O(changed lines) per edit and chunked on open; styling
  and inline-span extraction touch only the visible band.
- Zero new Cargo dependencies, so no bundle-budget pressure.
- Non-Markdown files keep the uniform-height O(1) geometry path.
- Run `scripts/perf-smoke.sh` at every phase boundary; Phases A and C also
  record `scripts/perf-record.sh` labels.

## Risks

- **Phase A is invasive**: every geometry site changes, plus the draw-path
  migration. Mitigation: uniform fast path for non-Markdown, splice-parity
  and draw-parity tests, perf gates per phase.
- **ConcealmentMap correctness** is the main regression surface (caret,
  mouse, selection, IME, VoiceOver all flow through it). Mitigation: the
  display-string identity decision keeps buffer-content sites correct by
  construction; property-based round-trip tests cover the rest.
- **Reveal-induced re-wrap** of the caret line is accepted and absorbed by
  caret-anchored scrolling; the contract makes the residual motion explicit
  instead of pretending it away.
- **Cross-line restyle cascades** (deleting a closing fence restyles the
  rest of the document as code in one keypress) are honest, immediate, and
  tested as known behavior.
- **Caret-unreachable prefixes** mean a user cannot edit `##` into `###` in
  place (peel and retype instead). Accepted for v1; a quiet heading
  affordance is possible later work.
- **Hand-written classifier divergence** from CommonMark on edge cases.
  Accepted: the subset is documented, unparsed text renders raw, and agents
  overwhelmingly emit the supported subset.

## Deferred work

Typeset tables, inline image rendering, frontmatter folding, code-fence
syntax highlighting, heading-level affordances, find-in-document highlight
styling, copy-as-rich-text (rule 7 means pasting into Mail yields raw
Markdown — recorded as a deliberate tradeoff), and the raw-source toggle
(promoted if real-world use shows in-app source inspection is needed). Each
should get its own slice against this foundation.
