# Markdown Rendered View — Current Milestone Plan

Execution plan for the next implementation round on the Markdown document
view. Design authority is [markdown-document-view.md](markdown-document-view.md)
(the contract rules cited below live there); this file sequences the
concrete work and is deleted or absorbed once the round lands. Line
references are against the current working tree.

Four workstreams. W1 and W2 are small and land first; W3 is the core; W4's
splice work is a prerequisite for W3's reveal mechanics, so its first two
items land before W3.4. Repository TDD rules apply to every item: failing
test first, smallest change, suite green, `scripts/perf-smoke.sh` at each
workstream boundary, and judge feel in Release (`make run-release`) — the
Debug Rust core is ~10x slower.

## W1 — remove the document status badge

Product decision: the page carries no persistent chrome beyond line
numbers. Delete entirely (all sites verified; nothing else references
these symbols):

- `LineRenderingTextView.swift`: the `drawMarkdownStatusBadge()` call
  (:3277), `drawMarkdownStatusBadge()` (:3673–3698),
  `markdownStatusTextForTesting()` (:3700–3702), `markdownStatusText()`
  (:3704–3721), `compactByteCount(_:)` (:3723–3730).
- `TextViewportLayoutTests.swift`: `testMarkdownStatusShowsCaretLineDocumentLinesAndByteSize`
  (:934–941), `testMarkdownStatusShowsSelectedLineRange` (:943–950).
- Keep `markdownLineNumberFont` (:271) — the margin numbers still use it.

## W2 — stabilize margin line numbers (always visible)

The current intent-driven visibility is the instability the user reports:
`markdownLineNumbersTransientlyVisible` starts false on open and nothing
reveals until the first `mouseMoved`/`viewportDidScroll` event ("numbers
appear ~0.5 s after open"), and the 0.6 s hide timer then removes every
non-caret number ("numbers sometimes disappear"). Replace with the
always-visible design (spec, "Line numbers"):

- Delete the state machine: `markdownLineNumbersTransientlyVisible`,
  `markdownLineNumberHideTimer` (:275–277), `markdownLineNumberFadeDelay`,
  `revealMarkdownLineNumbersTemporarily()` /
  `scheduleMarkdownLineNumberHide()` (:1479–1501) and their call sites in
  `mouseMoved` (:1372), `mouseExited` (:1385), `viewportDidScroll`
  (:1472), `didSetDocument` (:1437–1439). The
  `markdownLineNumberWidth`/`Gap` constants (:273–274) are superseded by
  the rail metrics below.
- `drawMarkdownMarginLineNumbers` (:3641+): draw every band line
  unconditionally; right-align the digits (left-aligned today); caret line
  tertiary, others quaternary — **color-only** emphasis, same font weight
  (a weight change would pop on every caret move).
- **Reserve the rail symmetrically.** Today numbers draw at `textX − 56`
  and clip outside the card below ≈712 pt viewport width. Define
  `railWidth` from `max(3, digitCount(lineCount))` (the 3-digit floor
  keeps 999→1000 from re-railing mid-keystroke) and compute the measure as
  `min(600, width − 2 × max(32, railWidth + 10))` with the column centered
  in the **full** card width — symmetric reservation, so the column never
  drifts off optical center. Include the rail in the width-equality
  guards so a rail-width change triggers a re-measure. The rail's
  10 pt gap must also clear the quote-bar/code-card overhang (bars at
  `textX − 14 − 8·depth`, card to `textX − 12`): the number's right edge
  ends left of `textX − 38` (3-bar depth) on quoted lines, or simply give
  the rail gap a 40 pt minimum on lines carrying margin decorations.

Tests (none exist today): all band lines numbered with no event/timer
dependency; wrapped lines numbered on the first visual row only; rail fit
at 1–6 digits and at `documentSurfaceMinimumWidth`; caret-line emphasis;
no rail churn at the 3-digit floor; no overlap with quote bars at depth 3;
read-only Markdown keeps the classic gutter.

## W3 — full concealment: render only the final document

Replace marker *muting* with marker *concealment*, per the spec contract
(rules 1–11). Two invariants are the acceptance bar:

> **Edit visibility.** Every concealed character is (a) caret-unreachable
> (block prefixes: clamping + Backspace peel; word-deletes clamp to
> content start), or (b) revealed while the caret/selection touches its
> span (inline markers *and escapes*, boundary-inclusive), or (c) revealed
> while the caret is on its line (whole-marker lines: thematic breaks,
> setext underlines, fence delimiters, frontmatter delimiters). Range
> deletes remove exactly the selected buffer range — concealed characters
> strictly inside a visible selection go with it (honest, same as copy);
> forward-delete at line end removes the newline only, and the merged
> prefix re-renders as visible plain text.
>
> **Rest-state purity.** With the caret parked on a blank line, a fixture
> exercising every supported construct renders zero marker glyphs — the
> user's literal acceptance criterion. (Fence info strings, ordered
> numbers, and alt text are final-rendered content, not markers.)

### W3.1 — concealment mechanism with fixed advances

Convert `muteMarkdownSyntax` call sites to a `conceal(width:)` attribute
treatment: near-zero-size font (one named constant; its advances are
honored identically by CTTypesetter measurement, CTLine caret/hit-test
math, and TextKit drawing — no draw-path migration needed) + `.clear`
color + `.kern` on the run's last character to set the run's total
advance. This makes the concealed prefix itself the typographic spacer:

| Concealed run | Total advance |
| --- | --- |
| Heading prefix `#…# ` | 0 |
| Bullet/task prefix per depth step | 24 pt (marker column) |
| Ordered prefix `N. ` | max(24, typeset number width + 6) |
| Quote prefix per depth step | 17 pt (3 pt bar + 14 pt inset) |
| Inline-code backticks | 4 pt each (chip padding) |
| All other inline markers, escapes, link/image syntax | 0 |

This is what preserves list/quote indentation and the marker column this
round, without Phase A's `LineLayoutSpec` (which later replaces it
properly; wrapped continuation rows still align to the column start —
hanging indent stays a Phase A item). The conceal font and kern values
are metric attributes, so the existing measurement/draw parity design
(`markdownMeasurementLine` / `includeVisualAttributes`) carries them to
both sides automatically; colors stay visual-only.

Note this diverges from the spec's long-term "CTLineDraw + run delegates"
mechanism — the spec carries an interim-mechanism annotation for this.

### W3.2 — stylist span output

`styleMarkdownLine` (or a sibling pure function) additionally yields the
per-line `ConcealmentMap`: concealed prefix range and its advance,
inline-span ranges with marker sub-ranges (including escapes), and the
whole-marker-line flag. Pure and unit-tested; the caret layer and the
reveal layer consume it.

### W3.3 — caret clamping, travel, and hit-test normalization

Centralize a `clampToVisible(endpoint)` and apply it at **every** entry
point that produces an endpoint, not only arrow keys: `endpoint(at:)`
(mouse down *and* drag-extend, :1861–1886), vertical goal-column moves
(:2241, :2249 — goal x over a concealed prefix is ambiguous; resolve to
content start), IME `characterIndex(for:)` (:3955–3959), and the
`columnUTF16(forX:in:)` results (zero-advance runs make
`CTLineGetStringIndexForPosition` return arbitrary interior indices).
Travel rules per spec rule 3 (Left at content start → previous line end;
Right at line end → next content start; Home → content start; padding/rail
clicks → nearest position). `deleteWordBackward`/`deleteWordForward`
(:2612–2635) clamp at the prefix boundary so a word delete never crosses
into concealed text.

### W3.4 — reveal at caret, threaded through measurement

Reveal state is part of line styling, not a draw-time patch: a
`RevealContext` (caret/selection-touched line + inline span, IME-frozen
line) becomes an input to `highlightedLine`/band styling **and to all
three wrap-measurement paths** (sync build, detached worker via
`WrapBuildInput`, per-edit splice). This is mandatory: revealed markers
measure at full width, so a wrap rebuild that ignores reveal desyncs
measured rows from drawn rows on the very first keystroke inside a
revealed span. Mechanics:

- While the caret/selection touches an inline span (boundary-inclusive),
  that span's markers render in today's muted treatment (tertiary) — the
  current muting becomes the *reveal* state. Whole-marker lines reveal as
  muted source while the caret is on them.
- Reveal-state changes restyle and re-measure only the affected lines:
  patch `cachedBand` lines in place *and* pass the context through band
  rebuilds (any scroll rebuilds the band with exact `(revision, range)`
  matching, so patching alone is insufficient — the context must be an
  input to styling itself). Splice the wrap index for those lines and
  apply caret-anchored scrolling (rule 10) when the caret line's row count
  changes.
- The markdown edit path must stop full-rebuilding the wrap index (see
  W4) so the caret line is always measured in its current reveal state.

### W3.5 — typeset replacements

Drawn in `draw(_:)`, state-guarded, into the space the fixed advances
reserve: bullets `•`/`◦`/`▪` by depth in the 24 pt marker cell; ordered
items typeset the **source number and source delimiter** (`1.` vs `1)`,
tabular digits, secondary — never renumbered) in their reserved cell;
task items draw the checkbox glyph in the marker cell (drawn only;
interactivity stays Phase E); quote bars stay stacked (one 3 pt bar per
depth, Bear-style — matches the current implementation); fence lines
conceal the backticks, keep the info string visible (muted 11 pt); hr =
drawn rule; setext underline = thin rule; frontmatter keeps its card,
delimiters concealed; links show the label in accent (brackets/URL
concealed, zero advance); images show alt text in secondary (`![`, `](url)`,
`)` concealed; the photo-symbol chip stays deferred (spec updated to
match); escapes conceal the backslash (and reveal per rule 2). Underscore
emphasis (`_em_`, `__strong__`, intraword `_` excluded per CommonMark) is
added to the supported subset alongside the asterisk forms.

### W3.6 — peel matrix completion

Mandatory now that prefixes are invisible: add the missing ordered-item
peel and quote depth n→n−1; the peel range must equal the **full**
concealed prefix the caret cannot reach; keep the fence/frontmatter
suppression guards; one undo step per peel.

### W3.7 — IME

Freeze the composing line's concealment, reveal, and block classification;
marked text inherits the line's resolved font (today it composes at the
base font on heading lines — fix here). Candidate-window geometry flows
through the same clamped, concealment-aware x math.

### W3.8 — selection semantics

Concealed runs contribute no visible highlight rect; double-click selects
the visible word only; copy/cut remain raw source (byte-fidelity
assertions).

W3 test matrix: per block kind and inline kind, walk the caret through
the line (Left/Right/Home/Up/Down, click, drag) asserting no position
lands inside concealed text without reveal; Backspace at every content
start matches the peel matrix; word/forward/range deletes per the
invariant; reveal transitions including scroll-during-reveal (band
rebuild) and typing-inside-reveal (measure parity); measured row counts ==
drawn row counts on concealed *and* revealed lines in all three wrap
paths; the rest-state purity fixture; IME on a styled heading.

## W4 — performance

Ordered so W3 can build on it:

1. **Incremental line-state splice** (lands before W3.4). The states are
   *not* prefix-only: setext assigns `states[i−1]` from line `i`
   (lookahead), and frontmatter membership depends on a closing delimiter
   arbitrarily far below. Correct rule: on edit, recompute from
   `max(0, firstEditedLine − 1)`; compare `recomputed[j]` against
   `cached[j − lineDelta]`; declare convergence at index `k` only after
   line `k+1` is processed (the setext retro-assignment trails by one);
   fall back to a full rebuild when any line in the old band had
   `insideFrontMatter`, or the edit adds/removes a trimmed `---` while
   line 0 is a frontmatter delimiter, or a fence delimiter is
   added/removed (parity cascade). Fetch only the rescanned lines.
2. **Markdown wrap splice** (lands before W3.4). Today every markdown
   keystroke routes to a full `rebuildWrapIndex` (:1069–1072) that
   refetches and re-measures the entire document on the main actor — the
   real per-keystroke O(n), bigger than the state rescan. After the state
   splice converges, re-measure exactly the lines whose text *or state or
   reveal* changed and splice via `spliceWrapIndex`; fix the splice
   measurement call (:1210) that currently hardcodes the `.plain`
   markdown state. Full rebuild remains the fallback for the same cascade
   cases as item 1.
3. **Kill the open flash on large documents.** The detached wrap worker
   already computes the full state array (:998–1002) while the draw side
   styles `.plain` until a *separate* utility build lands — a parity
   mismatch window, not just a flash. Return the states in
   `WrapBuildOutcome` and install them into `markdownLineStateCache`
   inside `completeWrapBuild` atomically with the index swap; drop the
   duplicate scheduled build. (A small synchronous above-the-fold prefix
   render remains optional polish, not a correctness mechanism.)
4. **Reveal-driven restyling is line-local** (W3.4) — caret movement must
   not restyle or re-measure the visible band.
5. Markdown micro-benchmarks as XCTest `measure` blocks (state splice,
   wrap splice, band styling at 4096 lines) with generous ceilings;
   `scripts/perf-smoke.sh` stays the cross-cutting gate.

## Out of scope this round

Variable row heights and the full type scale, hanging indent for wrapped
list rows (Phase A); checkbox/link interactivity (Phase E); the image
photo-symbol chip; theme slots for the markdown colors (tracked debt:
`MarkdownDocumentMetrics.accentColor`/`codeBackground` still bypass
`LocusTheme`); Rust-core classification (Phase B); tables.
