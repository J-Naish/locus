# Markdown Document View

Design for the core Markdown experience: a Markdown file renders as a
beautifully typeset document — only the final result, never the syntax —
and supports light editing directly in the rendered page. Notion-like,
minus slash menus and block chrome. Primarily a reading surface; some
editing is part of its purpose.

Related decisions: [ADR 0006](../adr/0006-custom-text-engine-over-nstextview.md)
(custom text engine), [ADR 0007](../adr/0007-markdown-live-styled-source.md)
(live styling over the buffer), [ADR 0008](../adr/0008-markdown-read-only-rendered-view.md)
(display transformation), [ADR 0009](../adr/0009-markdown-display-space-editing.md)
(display-space editing). Product expectations:
[core-feature-scope.md](core-feature-scope.md),
[ux-direction.md](../product/ux-direction.md),
[performance-budget.md](performance-budget.md). The current execution plan
is [markdown-rendered-view-milestone.md](markdown-rendered-view-milestone.md).

## Goal

- Markdown reads as a typeset document: real heading sizes, list bullets,
  quote bars, code cards, checkboxes — only the final rendered result.
  **No syntax marker is ever visible and no marker reserves space** — not
  at rest, not on hover, not at the caret. (Syntax being typed renders
  literally until it parses; the instant it parses, it renders — exactly
  like Notion's markdown shortcuts.)
- The document is editable in place: click, type, fix a word, add a list
  item. The file on disk stays byte-honest — every gesture is a plain
  buffer edit, and nothing is ever written that the user did not do.
- The page is margin and content, nothing else: **no line numbers in the
  Markdown view** (product decision, 2026-06-13 — the number rail
  constrained the page; an earlier margin-number design shipped and was
  removed; if agent-driven `file:line` navigation needs them later they
  return as an opt-in affordance). The classic gutter stays for
  code/config syntaxes.

## Non-goals

- Slash-command menus, block handles, drag-to-reorder, toolbars
  (explicitly excluded; also prohibited by
  [ux-direction.md](../product/ux-direction.md)).
- A raw-source mode in this view (a separate raw editor surface may come
  later as Phase R; it is no longer a prerequisite for editing).
- Math, footnotes, in-paragraph inline image loading (deferred; an
  image-only line renders as an image block — see Images).
- Rich-text pasteboard flavors (copy is raw Markdown; see contract).

## Architecture summary

One pipeline (per ADR 0008/0009): the **rendered transformation** is the
only Markdown styling path.

- **Display string ≠ buffer string.** Per source line the transformation
  produces a display string with marker characters *removed* (heading
  prefixes, list/task/quote prefixes, fence backticks, emphasis/code/
  strike delimiters, link/image syntax, escape backslashes; marker-only
  lines render empty), plus styling, per-line layout params (indent,
  hanging indent, wrap width), decoration metadata (bullets, ordered
  numbers, checkboxes, quote bars, cards, rules, link spans), and a
  **`DisplayMap`** — the ordered removed buffer ranges, giving
  bidirectional display↔buffer column conversion. The legacy
  attribute-concealment path (`muteMarkdownSyntax`) is deleted.
- **Display-space caret and selection.** Every caret/selection position
  is a display coordinate; markers occupy buffer ranges *between* display
  positions and are unaddressable by construction. Buffer crossings
  happen at two seams only: display→buffer for edits and offset lookups
  (`utf16Offset(of:)`), buffer→display for caret restoration after edits
  (`finishEdit`). Boundary positions map **outside** markers.
- **Editing is re-classification.** An edit updates the buffer, splices
  line states and wrap, re-transforms affected lines, and restores the
  caret through the map. Markdown shortcuts (`# `, `- `, `**…**`) work
  because parsing is live, not because of command handling.
- **Measurement/draw parity** holds because measurement and drawing
  consume the same transformed line (already true; the map adds no new
  divergence source — there is no reveal state).
- Read-only `LargeFile` documents, huge lines (>20,000 chars), and
  over-budget documents keep plain rendering with identity maps.
  Non-Markdown documents are untouched.

## UX design

### Principles

- A quiet, well-typeset page — closer to Apple Notes and Craft than to an
  IDE. The rendered result is the only thing on the page.
- Quietness comes from visual weight, never from conditional visibility:
  no hover-revealed chrome, no fades, no marker reveal.
- Comfortable Japanese: generous line height; IME composition is never
  disturbed by re-classification mid-composition.
- Honest structure: ordered numbers come from the file (never
  renumbered); unsupported constructs render as plain text, never an
  error state.
- Find-in-document searches the rendered display text that the user sees,
  not hidden Markdown markers. Cmd-F opens a compact in-surface find bar;
  matches are highlighted in the document, Return/Shift-Return move
  through results, Escape closes the bar and returns focus to editing.
  Regex, replace, and app/menu-wide find commands are intentionally
  outside this surface for now.

### Layout and type scale

Centered 600 pt measure with symmetric 32 pt minimum side padding (no
number rail — see Goal). The full heading scale, Notion-ratio, on
variable-height rows:

| Element | Font | Tracking | Air above/below |
| --- | --- | --- | --- |
| Body | 15 regular | — | 24 pt row |
| H1 | 30 bold | −0.4 | 22 / 6 |
| H2 | 24 bold | −0.2 | 18 / 5 |
| H3 | 21 semibold | — | 14 / 4 |
| H4 | 18 semibold | — | 10 / 3 |
| H5 | 15 semibold | — | 8 / 2 |
| H6 | 13 semibold secondary | — | 8 / 2 |

Heading rows are glyph-height rows with sectional air applied once per
line — generous above, tight below, so a heading binds to the section it
introduces; a heading on the document's first line suppresses its air
(4 pt) so the title sits at the page top. Setext underline rows render
as 6 pt slim rows, like table delimiters. Code 13 mono / fence label 11
mono / blank lines 24 pt. Row text is **vertically centered** within its
row (slack splits evenly, never pooling at the bottom).

### Block and inline elements

**Structure lives inside the text column.** Bullets, ordered numbers,
checkboxes, and quote bars draw *inside* the centered column, in indent
cells the content is shifted right to reserve — exactly like Notion —
never in the left margin. Per-line
layout: a list item at depth d indents its content by d × 24 pt with the
glyph drawn in the last 24 pt cell; a quote at depth d indents by
d × 17 pt with one 3 pt bar per level drawn inside the inset; wrapped
continuation rows hang-align to the content start; an indented
continuation paragraph under a list item aligns to its parent item's
content. Wrap width per line = measure − indent.

- **Headings** (ATX, setext): flush left at scale; setext underline rows
  render empty.
- **Lists**: typeset `•`/`◦`/`▪`, ordered = source number + delimiter
  (tabular, secondary, never renumbered), checkboxes (clickable). Depth
  is list-context-aware: nesting steps of 2–4 spaces count only while a
  list is open; marker-choice invariance holds.
- **Blockquotes** (≤3): stacked bars; **the quoted remainder is
  re-classified for block constructs** — `> ### Title`, `> - item`,
  `> - [ ] task` render as a heading/list/task inside the quote (one
  nesting level), indents composed. A depth-one quote run whose first
  line is exactly one of GitHub's `[!NOTE]`, `[!TIP]`, `[!IMPORTANT]`,
  `[!WARNING]`, or `[!CAUTION]` callout headers renders that source label
  semibold with a matching quiet tinted bar across the run; invalid,
  nested, lowercase, or mid-run headers stay literal.
- **Fenced code**: a **rounded card** (no border), flush with the text
  column (composed with any quote/list indent), code inset 12 pt on both
  sides, breathing 10 pt above and below. A *labeled* opener is a quiet
  **header band** holding the language label (left); a bare fence
  reserves no band — its opener collapses to a slim row so there is no
  empty label space at the top. The closer is always a slim row. The
  language label is a small muted *system* caption (11 pt, secondary,
  lightly tracked), in the same register as table headers and image
  captions, not the mono body. The body carries **calm, language-agnostic
  highlighting**: line comments recede to marker grey and quoted strings
  take a desaturated accent ink — comments and strings only, never
  keywords (honest keyword colour needs a per-language grammar, which is
  IDE territory). The **copy control** is a persistent (never
  hover-revealed) quiet **icon** — no border — in the card's top-right
  that copies the block's verbatim body (the lines between the fences,
  without the markers) to the pasteboard, showing a brief checkmark
  confirmation, and the pointer becomes a hand over it; it is the one
  deliberate convenience affordance on the surface. Fences
  require closure (unclosed fences render literally — deliberate
  divergence so typing ``` ``` ``` never restyles the whole page;
  frontmatter likewise, on the same card, without a copy control).
- **Indented code blocks** (4+ spaces *outside* an open list context):
  mono on the same card (no copy control, since there is no fence
  header), grouped like fences. Inside a list context the
  same indent is a continuation paragraph — this distinction is what
  keeps `  - nested` a list item and `    code` a code block.
- **Tables**: a block of pipe rows confirmed by a delimiter row renders
  as a **print-quality three-rule table** (booktab style) — no outer
  box, no vertical lines, no background fills. Structure comes from
  exactly three hairline rules spanning the table's content width: above
  the header row, through the center of the delimiter row, and under the
  last body row. The delimiter row is a **slim 6 pt row** (the engine's
  first variable-height row — per-line row heights with a uniform fast
  path), so the header sits close to its body the way body rows sit to
  each other; the top and bottom rules breathe 4 pt into adjacent blank
  lines. Header cells are 12 pt semibold in the
  secondary color — a column label, unmistakably not body text; body
  cells are 13 pt. Columns are separated by a 40 pt gutter, the first
  column flush with the table's left padding; column widths come from
  the **styled** rendered cell (chips, code fonts, and emphasis measured
  as drawn, never plain text), with a per-column max of 200 pt. Cells
  whose text exceeds that width wrap inside the cell instead of
  truncating; row height grows only for the affected source row, using a
  compact 20 pt table-cell line height and 6 pt spacing between table
  rows. Header cells may wrap at word boundaries, but should not split
  short labels mid-word. The document measure stays fixed: when a
  table's natural width exceeds the prose column, only the table block
  clips and scrolls horizontally, Notion-style. The page itself never
  widens, and other Markdown blocks keep their normal fixed measure.
  **Column alignment markers are honored** (`:---` left, `:---:`
  center, `---:` right) via aligned tab stops. Escaped pipes (`\|`)
  remain inside the cell and render as a literal pipe. Cell text edits
  work normally; the cell-boundary tab is structural — deleting it is a
  no-op and the caret steps across. A pipe line without a delimiter row
  stays literal. (Tunable later: ultralight row hairlines for tables
  longer than ~8 rows.)
- **Frontmatter / thematic breaks**: unchanged (muted mono card; drawn
  rule on an empty row). A whole-line HTML `<hr>` (`<hr>`, `<hr/>`,
  `<hr class="…">`) renders as the same drawn rule.
- **Images**: a line whose only content is one image (`![alt](src)`,
  optional title and angle brackets accepted, or a whole-line HTML
  `<img src="…" alt="…">`) renders as an image block.
  The image lives in the line's leading inset, fitted to the text column
  (never upscaled past its natural size; very tall images cap at 560 pt,
  width shrinking proportionally), above the alt text rendered as a
  small muted caption — a normal text row, so caret, selection, editing,
  and span-integrity deletion are unchanged, and editing the caption
  edits the alt text. Natural sizes are probed header-only off the main
  thread (rows settle before any pixel decode); pixels decode
  downsampled on demand when the block first scrolls into view, and the
  viewport stays anchored when sizes arrive above it. Relative paths
  resolve against the document's folder; `https://` sources load
  remotely (no cookies sent, responses cached); plain `http://` and
  unknown schemes fail quietly. Formats are whatever ImageIO decodes
  (PNG, JPEG, GIF first frame, TIFF, BMP, HEIC, WebP, AVIF, …) plus SVG
  and PDF through NSImage as best effort. While loading, a quiet card
  holds the space; a source that cannot load shows a quiet labeled card.
  An image inside a paragraph or a list item still renders as secondary
  alt text. Untrusted-input bounds: remote responses stream against a
  size cap, headers declaring absurd pixel counts are rejected before
  decode, and over-long image lines never classify as blocks. An HTML
  `<img>` block shares this renderer: its `src` is unquoted, entity-
  decoded, and limited to `https://` or a scheme-less local path (every
  other scheme — `javascript:`, `data:`, `file:`, … — leaves the tag
  literal), and its `alt` becomes the caption. Unlike a markdown image's
  alt, the HTML `<img>` caption collapses to a single unit (the whole tag
  is one buffer span), so it is not separately editable.
- **Videos**: a line whose only content is one video reference renders in
  the same media-block slot as images. Markdown image syntax with a video
  extension (`.mp4`, `.m4v`, `.mov`, `.webm`, `.m3u8`) and simple
  whole-line `<video src="…" title="…">` tags are accepted. The native
  AppKit/AVKit player is mounted only while the row is visible and reuses
  the same caption row/editing map as image blocks. For now video embeds
  are local-file only; remote video URLs show the quiet unavailable card
  instead of streaming arbitrary media inside the app.
- **Inline**: bold/italic/bold-italic/strike (asterisk and underscore
  forms), inline code chips, links (label in accent; plain click opens
  valid `http`/`https`/`mailto`/`tel` destinations or local file paths
  inside Locus; invalid destinations use the invalid-link tint),
  **fragment anchors** (`#section`) resolved to in-document ATX or setext
  headings with GitHub slug and duplicate-suffix rules, scrolling the
  heading to the viewport top while unresolved anchors stay inert,
  **reference links** `[text][label]` and shortcut references `[label]`
  resolved through a document-wide definitions map (`[label]: url`
  definition lines render as small muted mono; unresolved references
  stay plain literal text with no invalid tint and no target), **autolinks**
  `<https://…>` (URL as the visible label, brackets removed; clickable
  per the scheme rule) and email autolinks (plain non-link text with
  brackets dropped), in-paragraph images as secondary alt text
  (image-only lines render as image blocks — see Images above), escapes
  render the escaped character with the backslash removed. Inline
  constructs nest one level: code spans and links inside emphasis render
  both (code binds tighter than emphasis), and one nested emphasis span
  inside a same-line emphasis span is supported. Standalone dunder names
  like `__init__` follow CommonMark/GitHub/Notion and render as strong;
  use backticks for literal identifiers.
- **Inline HTML**: a curated allowlist renders by reusing the same
  typographic attributes as the markdown equivalents — `<b>`/`<strong>`
  bold, `<i>`/`<em>`/`<cite>` italic, `<s>`/`<strike>`/`<del>`
  strikethrough, `<u>`/`<ins>` underline, `<code>`/`<kbd>` and `<mark>`
  the inline-code chip, `<small>` dimmed, and `<a href>` the link style
  (the tag markers are removed in display space, like emphasis). **HTML
  entities** decode to their character — named (`&amp;`, `&copy;`,
  `&mdash;`, …) and numeric/hex (`&#169;`, `&#x1F600;`), with invalid or
  unsafe code points left literal. `<br>` becomes a space (a forced
  mid-line break is not expressible in the per-line wrap model). Security:
  this is **not** a browser — no JS, no CSS, no `<script>`/`<style>`/
  `<iframe>`; only `href` is read and only `http`/`https`/`mailto` (or a
  relative reference) is honoured (a `javascript:`/`data:` link, or any
  unknown/structural tag — `<div>`, `<table>`, `<details>`, …, and all
  multi-line block HTML — stays **literal**). Escaped HTML (`&lt;b&gt;`)
  stays literal too. Two **single-line block** tags are the exception:
  a whole-line `<img>` renders as an image block and a whole-line `<hr>`
  as a rule (see Images and Frontmatter / thematic breaks above); an
  inline `<img>` mid-paragraph collapses to its alt text, like an inline
  markdown image. Full-fidelity HTML (CSS/layout/scripts) is the job of
  the future standalone HTML preview surface, not this engine.

### Editing contract

The rules below are the acceptance bar; tests encode them. "Content
start" = display column 0 of a line whose buffer line carries a removed
prefix.

1. **Every gesture is a plain buffer edit.** Nothing is written that the
   user did not do; undo is the buffer's undo, with the caret restored
   through the map (including after undo/redo).
2. **Per-operation affinity.** *Insertion* maps the caret position to the
   buffer position **outside** adjacent removed markers: typing at the
   visible edge of a bold span produces plain text (Notion behavior);
   typing strictly inside a span stays inside it. For removed *leading
   block prefixes* the rule inverts by definition: display column 0 is
   the content start, **after** the prefix — typing at the start of a
   heading types into the heading, never before the `#`. On marker-only
   rows (rules, setext underlines, fence/frontmatter delimiters) the
   single display position maps to the buffer line's end. *Deletion and
   replacement* never use caret-position mapping: they operate on the
   selected **visible characters' own buffer ranges** — Backspace removes
   exactly the previous visible character's bytes, even when removed
   markers sit between it and the caret; partial selections remove only
   the selected content characters.
3. **Live conversion, literal until parsed.** Typing `# `, `- `, `> `,
   or a closing `**` restyles immediately on parse; incomplete syntax
   renders literally. Whenever a restyle changes row geometry — on the
   caret line *or anywhere above it* (fence and frontmatter edits cascade)
   — the viewport compensates so the caret's screen position holds.
4. **Backspace peels at content start**, one level, one undo step:

   | Line kind | Backspace at content start |
   | --- | --- |
   | Heading | → paragraph |
   | Blockquote depth n | → depth n−1 |
   | Task item | → bullet item |
   | List item depth n > 1 | outdent one level |
   | Bullet/ordered item depth 1 | → paragraph |
   | Paragraph | join with previous line |

   Peel is state-guarded (never inside fences/frontmatter). A setext
   heading peels by deleting its underline line (one undo step); Backspace
   on the underline row itself does the same. Forward-delete at line end
   cleanly merges the next line and absorbs the next line's concealed
   prefix when that prefix would otherwise become synthetic visible text.
   Word deletes clamp at content start.
5. **Span integrity.** Deleting a span's last visible character also
   removes its markers (no `****` litter), as a pre-expansion of the same
   buffer edit — one undo step. For links and images this removes the
   whole syntax *including the invisible URL* in one keypress — stated
   loudly, tested, and recoverable by undo. Deleting an entire visible
   span through selection removes its markers with it. Escapes follow the
   same rule.
6. **Enter**: splits at the mapped offset (a heading split leaves the
   first half a heading, the second a paragraph). Inside a list item it
   continues the list — same bullet, ordered = previous number + 1
   (existing lines never renumbered), task = unchecked box. On an empty
   item: depth > 1 outdents one level per press (mirroring Backspace);
   depth 1 removes the marker, leaving an empty paragraph line — no
   newline is inserted in either case. Inside a quote it preserves the
   source quote prefix verbatim and composes quoted-list continuation;
   an empty quoted list drops its list marker while an empty plain quote
   peels one quote level, without inserting a newline. Inside fences it
   is a plain newline.
7. **Emphasis keys**: Cmd+B / Cmd+I, one undo step, byte-honest. A
   selection fully inside a span unwraps it; a selection that overlaps or
   abuts same-kind spans **merges** them: inner markers are removed and
   the union is wrapped once (this is how "append to a bold word" works:
   type plainly, select the union, Cmd+B). No selection → no-op.
8. **IME**: composition splices into the rendered line at the mapped
   position and inherits the line's resolved font; the composing line's
   classification and transformation are frozen until commit, then the
   line re-parses. Candidate-window geometry uses mapped, display-space
   rects.
9. **Copy and cut are raw Markdown** of the mapped buffer range, so
   copy/paste round-trips formatting in Locus and gives agents real
   source. Inline-span markers are included exactly when the selection
   covers the span's whole visible content; a line's block prefix (and a
   block's fence/frontmatter delimiter lines) are included exactly when
   the line's whole visible content is covered. Concretely: selecting
   `bold` inside `before **bold** after` copies `**bold**`; selecting
   `old` inside it copies `old`; selecting all of `Heading` on a
   `# Heading` line copies `# Heading`; a multi-line selection across a
   fenced block copies the fences. Paste inserts plain text at the mapped
   offset and re-parses (pasting Markdown source renders). Double-click
   selects the visible word; marker-only rows contribute a line break to
   multi-line selections. Cut = the same raw copy plus the mapped delete.
10. **Checkbox click toggles** `[ ]`↔`[x]` as a normal buffer edit (hit
    area = marker cell × row height; mouse-down-drag falls through to
    selection). **Links: plain click opens valid destinations**:
    external `http`/`https`/`mailto`/`tel` URLs leave Locus through the
    system opener, local file paths open in Locus, `#fragment` anchors
    scroll to resolved in-document headings without changing selection,
    unresolved anchors remain inert, and invalid links do not open. The
    pointing hand shows over all link spans; validity affects activation
    and tint, not the cursor. A quiet link editor, Cmd+K, and
    paste-URL-over-selection are named deferrals.
11. **Accessibility reads the rendered document**; ranges convert through
    the map. VoiceOver editing announcements follow the buffer edits.
12. **Tab** indents/outdents only at list-item starts (rule in Phase E4)
    and inserts a literal tab only inside fences; elsewhere it is a
    no-op — prose tabs are not a Markdown concept this view supports.
13. **No text substitutions.** Smart quotes/dashes and autocorrect are
    off by policy (curly quotes corrupt code spans and URLs in source
    files); spellcheck is deferred work.

### Theme integration

Unchanged intent: `LocusTheme` slots for accent / code backgrounds /
rule (tracked debt — `MarkdownDocumentMetrics` still hardcodes system
colors).

## Implementation plan

The current rendering/editing status is summarized in
[markdown-rendered-view-milestone.md](markdown-rendered-view-milestone.md).
Phase A (variable row heights, full type scale), typeset tables with
cell wrapping and table-local horizontal scroll, image/video blocks,
clickable links, task checkbox toggles, and the code card (language
label, copy control, comments/strings tint), plus document find over
rendered display text with mapped highlights, have shipped. Later:
Phase R (optional raw editor surface), Phase B (Rust-core
classification), polish backlog (theme slots, link editor,
copy-as-rich-text, richer in-paragraph
media, animated GIF playback).

## Performance

Budgets per [performance-budget.md](performance-budget.md). Editing
returns per-keystroke costs: state and wrap splices must be incremental
(no whole-document work per keystroke), styling stays visible-band, and a
typing-latency benchmark joins the open-path benchmarks.
`scripts/perf-smoke.sh` gates every slice; feel is judged in Release.

## Risks

- **DisplayMap seams** (display→buffer on edit, buffer→display on caret
  restore) are the correctness core. Mitigation: pure map with
  property-based round-trip tests; the two seams are single functions.
- **IME in display space** is the hardest piece and Japanese input is a
  product requirement; it lands behind tests for composition on styled
  lines, candidate rects, and the freeze rule.
- **Per-keystroke splices** have known sharp edges (setext looks ahead
  one line; frontmatter depends on a distant closing delimiter); the
  splice rules in the milestone plan encode the corrected convergence
  logic.
