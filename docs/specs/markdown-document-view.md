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
- Line position stays first-class: margin line numbers map 1:1 to source
  lines, because agents talk about files as `file:line`.

## Non-goals

- Slash-command menus, block handles, drag-to-reorder, toolbars
  (explicitly excluded; also prohibited by
  [ux-direction.md](../product/ux-direction.md)).
- A raw-source mode in this view (a separate raw editor surface may come
  later as Phase R; it is no longer a prerequisite for editing).
- Typeset tables, inline image loading, math, footnotes (deferred).
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

### Layout, line numbers, type scale

Unchanged from the current implementation: centered 600 pt measure with
symmetric rail reservation; always-visible margin line numbers
(quaternary, logical lines, first visual row only; caret line one step
stronger now that a caret exists again); the interim compressed type
scale inside the uniform 24 pt row (full scale arrives with Phase A
variable row heights):
Body 15 regular / H1 20 bold / H2 18 bold / H3 16 semibold / H4 15
semibold / H5 14 semibold / H6 13 semibold secondary / code 13 mono /
fence label 11 mono / blank lines 24 pt.

### Block and inline elements

As implemented in the rendered pipeline (markers removed, decorations
drawn): typeset bullets `•`/`◦`/`▪` and ordered numbers (source number +
delimiter, tabular, secondary) and checkboxes in the marker column;
stacked quote bars (3 pt per depth ≤3) with per-depth inset; fence cards
with the info string as a muted 11 pt label on the opening row and empty
delimiter rows; frontmatter as a muted mono card; thematic breaks as
drawn rules on empty rows; setext underlines as empty rows; links show
the label in accent (URL removed; schemes other than `http`/`https`
render as plain text); images show alt text in secondary; escapes render
the escaped character. Both asterisk and underscore emphasis forms.
Depth detection is tolerant (2–4 spaces, marker-relative); marker-choice
invariance holds (`-`/`*`/`+`, `1.`/`1)`, equivalent nesting spellings
render identically). **Fences require closure**: an unclosed fence
renders as literal text rather than swallowing the rest of the document —
a deliberate CommonMark divergence so that typing ``` ``` ``` never
restyles the whole page per keystroke; the block snaps to a code card
once when the closing fence lands. (Frontmatter already requires its
closing delimiter.)

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
   removes the newline only; a merged prefix re-renders as literal text
   (it no longer parses at line start — visible, honest). Word deletes
   clamp at content start.
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
   newline is inserted in either case. Inside fences it is a plain
   newline.
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
    selection). **Links: plain click places the caret; Cmd+click opens**
    (`http`/`https` only) — this is an editor, the cursor must tell the
    truth, and label typos must be clickable. The pointing hand shows
    only while Cmd is held over a link span. A quiet link editor, Cmd+K,
    and paste-URL-over-selection are named deferrals.
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

The current round (editing restoration) is sequenced in
[markdown-rendered-view-milestone.md](markdown-rendered-view-milestone.md).
Later: Phase A (variable row heights, full type scale), Phase R (optional
raw editor surface), Phase B (Rust-core classification), polish backlog
(theme slots, find-in-document with mapped highlights, link editor,
copy-as-rich-text, fence syntax highlighting, tables, inline images).

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
