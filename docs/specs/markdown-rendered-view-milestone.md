# Markdown Rendered View — Editing Restoration Plan

Execution plan for restoring light editing to the rendered Markdown view,
per [ADR 0009](../adr/0009-markdown-display-space-editing.md): Notion-like
— markers never visible, editing in display space through a `DisplayMap`.
Design authority is [markdown-document-view.md](markdown-document-view.md)
(the editing contract lives there). Line references are against the
current working tree.

Standing rules: failing test first, smallest change, suite green,
`scripts/perf-smoke.sh` at workstream boundaries, feel judged in Release.
Japanese IME behavior is release-gating, not optional polish.

Current-state facts the plan builds on (verified):

- The rendered transformation is real string removal
  (`renderedMarkdownBlock` strips prefixes via `substring(from:)`;
  `replaceRenderedMatches` rewrites inline spans with
  `replaceCharacters(in:with:)` tracking a `locationDelta`), with
  decorations drawn separately. **No DisplayMap exists** — the mapping is
  implicit and discarded.
- Two parallel styling pipelines exist: the rendered path (viewer) and
  the legacy `muteMarkdownSyntax`/`styleMarkdownLine` concealment path
  (now unreachable for markdown). Drift risk; the legacy path dies this
  round.
- Read-only is one gate: `if syntax == .markdown { return false }`
  (VirtualizedTextDocumentView.swift:46) plus `canEdit` excluding
  `.markdown` (WorkspaceTextDocumentSupport.swift:9; consumed by
  `isSaveDisabled`, the conflict branch, tests).
- For viewing, the display-space coordinate model is already
  self-consistent (measure, draw, selection rects, copy all use the
  rendered string). The buffer crossings that editing adds are exactly
  `utf16Offset(of:)` (display→buffer) and `finishEdit`'s caret restore
  (buffer→display); IME's `composedLineForDisplay` splices by
  buffer-column-as-rendered-index and needs the map.
- The peel matrix, `toggleMarkdownEmphasis`, and their tests were deleted
  in the read-only round — recover them from version history / the
  working diff and adapt to display coordinates; do not reimplement from
  scratch.
- Scroll-key handling for read-only documents and the
  `if !isEditable` Space guard already coexist with editing (Space falls
  through to self-insert when editable).

## E0 — commit the viewer round, then requirement docs

- **Commit the working tree first.** The entire viewer round (14 modified
  files + the untracked ADRs) is uncommitted; this plan's
  recover-from-history references and any rollback point depend on it
  being committed before E1 starts.
- Update [core-feature-scope.md](core-feature-scope.md) (Markdown Must:
  light editing in the rendered view returns; raw editor stays Should)
  and the roadmap Phase 1C wording. Small doc commit.

## E1 — DisplayMap as a transformation output; one pipeline

- The transformation's removals are NOT recordable as-is — this is real
  mapping work, not bookkeeping:
  - `replaceRenderedMatches` runs seven inline passes, each matching the
    already-mutated string from prior passes, so neither pass-input nor
    current-string coordinates are buffer coordinates. Record each
    removal in pass-input coordinates and convert through the
    accumulated map at record time (block-prefix strip composed first),
    inserting into a position-sorted structure. Links and images yield
    *two* removed ranges each (`[` and `](url)`).
  - The fence-line and frontmatter-delimiter paths derive display text by
    double trimming with Character arithmetic and compute no offsets;
    rewrite `markdownFenceInfo`/`markdownFenceInfoText` to produce UTF-16
    buffer ranges.
- Output schema is **per-line span records**, not a flat removal list:
  kind (prefix / code / bold / italic / bold-italic / strike / link /
  image / escape), content display range, opening/closing removed buffer
  ranges, and the URL for links (currently matched and discarded). The
  removal list and `displayColumn(forBuffer:)` /
  `bufferColumn(forDisplay:affinity:)` derive from the records. Spec
  rule 5 (span cleanup) and E6 (link opening) are unimplementable
  without this.
- **Fence closure requirement** (spec change): the classifier treats an
  unclosed fence as literal text — typing ``` ``` ``` must never restyle
  the rest of the document per keystroke; the block converts once when
  the closing fence lands.
- Delete the legacy concealment pipeline: `muteMarkdownSyntax`,
  `styleMarkdownLine`'s markdown branch and inline appliers, and their
  conceal-era tests — one styling path only.
- Pure-function tests: per-construct span records and maps; round-trip
  properties (display→buffer→display identity; monotonicity; boundary
  affinity); a line where a later pass's removal precedes an earlier
  pass's (`*i* ` + `` `c` `` + `**b**` on one line) — the compounding
  case; marker-only lines (empty display); CRLF; clipped/huge lines
  (identity map by policy); unclosed-fence literal rendering.

## E2 — editable routing returns

- Remove the markdown gate (VirtualizedTextDocumentView.swift:46);
  `canEdit` includes `.markdown` again. Save / dirty / conflict banner
  re-engage through existing machinery (tests). Menu validation flips
  back automatically; verify.
- Caret returns (display space — caret x/height math already operates on
  the rendered string). Restore the caret-line number emphasis (tertiary)
  dropped in the viewer round.

## E3 — display-space editing core

The seams, the affinity policy, then the gesture set:

- **Seams (four, not two)**: `utf16Offset(of:)` (display→buffer),
  `finishEdit`'s caret restore (buffer→display),
  `setSelection(globalStart:globalEnd:)` (buffer→display — the recovered
  emphasis toggle ends there), and `afterUndoRedo` (which today *clamps*
  the stale display selection instead of restoring through any map —
  this is new code per spec rule 1, not existing machinery).
- **Per-operation affinity (spec rule 2)**: insertion maps the caret
  outside inline markers / after block prefixes / to line end on
  marker-only rows. Deletion and replacement never map caret positions:
  `currentSelectionUTF16Range()` / `deleteRange(from:to:)` compute the
  buffer range from the selected visible characters' own ranges, so
  Backspace after `**bold**` deletes `d`, never `d**`.
- **Span integrity** (spec rule 5) hooks as a *pre-expansion* of the
  buffer range inside `deleteRange`/`replace`, before the single
  `buffer.replace` call — one undo step by construction (a post-hoc
  marker delete in `finishEdit` would be a second step). The expansion
  reads the span records from E1's map. Links/images: one Backspace on
  the last label character removes the whole syntax including the URL —
  loud test.
- **Cross-line state cascades (correctness gate for this workstream,
  not E7)**: `spliceWrapIndex` re-measures only the edited text band,
  but a one-line edit can change other lines' *states* and therefore
  their fonts and wrap (setext `===` restyles the line above; fence and
  frontmatter delimiters restyle whole bands). Interim rule that ships
  with E3: any edit whose state splice changes lines outside the edited
  band falls back to a full wrap rebuild — correct first; E7 narrows it
  to a targeted splice.
- Live conversion falls out of re-classification on edit; caret-anchored
  scrolling is verified for parses that change the caret line's row
  count (converting a long paragraph to a heading swaps to 20 pt bold
  and can change its wrapped row count — include it) and for
  above-caret cascades (closing a frontmatter block).
- Word deletes clamp at content start.

Tests: a typing matrix per construct (type into heading/bold/code/link
label/list item/fence interior); boundary-rule cases — typing *and
deleting* at every edge of `**bold**`, `` `code` ``, `[label](url)` (the
delete-at-trailing-edge case is the trickier seam); span cleanup incl.
the link-URL deletion; Enter splits; undo/redo caret restoration through
the map; byte-fidelity assertions on every gesture.

## E4 — structural gestures (the Notion verbs)

State-guarded (never inside fences/frontmatter). Provenance differs:

- **Recovered from HEAD (3a6d8e8) and adapted to display coordinates**:
  the Backspace peel matrix (`peelMarkdownBlockPrefixIfNeeded` /
  `markdownPeelPrefix` exist at HEAD) — heading→paragraph, quote n→n−1,
  task→bullet, depth>1 outdent, depth-1→paragraph — plus the genuinely
  missing ordered-item peel and the setext rule (peel deletes the
  underline line; Backspace on the underline row does the same). One
  undo step each.
- **New work (never existed; earlier plans listed it but no
  implementation reached it)**: Enter list continuation (same marker;
  ordered = previous + 1, never renumbering others; task = `- [ ]`;
  empty item outdents at depth > 1, removes the marker at depth 1, no
  newline inserted), and Tab / Shift+Tab indent/outdent at item start
  (Tab is a no-op outside items, a literal tab inside fences — spec
  rule 12).
- **Recovered + extended**: Cmd+B / Cmd+I (`toggleMarkdownEmphasis` at
  HEAD, fed mapped buffer offsets) with the spec rule-7 merge semantics:
  selection fully inside a span unwraps; overlapping/abutting same-kind
  spans merge into one (inner markers removed, union wrapped once).

Tests: full peel/continuation matrix incl. fence/frontmatter suppression
and setext; toggle round-trips incl. the merge cases (`bold` + plain
`er` → select union → one `**bolder**`); undo grouping.

## E5 — IME in display space (release-gating)

- A source↔rendered column mapping feeds `composedLineForDisplay` (it
  currently splices `composition.anchor.columnUTF16` into the rendered
  string as if buffer == display), `firstRect(forCharacterRange:)`,
  `characterIndex(for:)`, and marked/selected range exchanges.
- Freeze the composing line's classification and transformation until
  commit. The buffer does not change mid-composition (marked text lives
  only in `composition`), so the real hazards are: (a) the
  begin-composition selection-deleting `replace()` in `setMarkedText`,
  which runs `finishEdit` → cache invalidation → a possible restyle and
  span cleanup *before* composition starts — define and pin its
  behavior; (b) async state/wrap build completions landing
  mid-composition — they must not restyle the frozen line. Marked text
  inherits the line's resolved font (heading-size composition in
  headings).
- Tests: composition on a styled heading and inside bold; candidate-rect
  positions on transformed lines; commit-then-reparse; the freeze rule.

## E6 — interactive elements and selection semantics

- **Checkbox click toggles** the buffer (`[ ]`↔`[x]` at the known offset;
  hit area = marker cell × row height; mouse-down-drag falls through to
  selection; dirty/save/undo standard).
- **Links**: plain click places the caret (this is an editor); **Cmd+click
  opens** `http`/`https`, using the span records' URL; pointing hand only
  while Cmd is held over a link span.
- **Copy/cut/paste per spec rule 9** — copy *and cut* yield raw Markdown
  of the mapped range (inline markers on whole-visible-span coverage;
  block prefixes and fence delimiter lines on whole-visible-line
  coverage; the contract's three concrete examples become tests); paste
  = plain-text insert + live re-parse. Land cut and copy together —
  today cut would put display text on the clipboard while deleting raw
  source. Update the viewer round's visible-text copy tests to the
  raw-source contract.
- **Accessibility (spec rule 11)**: audit the mixed-space surface —
  `accessibilitySelectedTextRange` converts display→buffer today while
  sibling APIs assume buffer text; route all parameterized ranges
  through the map so VoiceOver consistently sees the rendered document.

## E7 — per-keystroke performance

Editing returns the costs the viewer round removed (the first edit after
E2 hits a wholesale state-cache invalidation plus, per E3's interim rule,
frequent full wrap rebuilds — correct but O(document)); land before
calling the round done:

- **Incremental state splice** (the corrected rules from the earlier
  review): recompute from `max(0, firstEditedLine − 1)`; compare
  `recomputed[j]` vs `cached[j − lineDelta]`; converge at k only after
  k+1 is processed (setext lookahead); full-rebuild fallback when the
  edit band touches frontmatter membership or adds/removes fence
  delimiters.
- **Markdown wrap splice**: stop full-rebuilding the wrap index per
  keystroke; re-measure only lines whose text or state changed and
  splice (fix any splice-path call that measures with a default state).
- Typing-latency benchmark (XCTest `measure`, 4096-line doc, mid-document
  edits) joins the open-path benchmarks; `perf-smoke.sh` +
  `perf-record.sh` label at round end.

## Out of scope this round

Slash menus and block chrome (excluded by product decision); variable row
heights / full type scale (Phase A); raw editor surface (Phase R,
optional now); link editor popover; find-in-document; tables; inline
images; theme slots (tracked debt); copy-as-rich-text.
