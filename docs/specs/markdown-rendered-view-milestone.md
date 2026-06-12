# Markdown Rendered View — Slim Marker Rows (Per-Line Row Heights)

Execution plan for the engine's first variable-row-height capability:
lines may carry a custom row height, and the table delimiter row becomes
a ~6 pt slim row, so the header→body gap (today a fixed 24 pt source row
plus insets ≈ 31 pt) shrinks to ≈ 13 pt — the user's accepted target.
This is the geometry half of the long-deferred Phase A, scoped to
per-LINE heights (all wrapped visual rows of a line share its height; no
per-row heights, no heading paddings yet — but the machinery enables
both later).

User approval: explicit ("可変行高を実装する(推奨)" selected,
2026-06-13). Slim set v1 = **table separator rows only**
(`tableSeparatorRowHeight = 6`); the mechanism is general
(`markdownRowHeight(for state)`), so setext underlines, fence closers,
frontmatter delimiters, and hr rows can be slimmed later by extending
one function.

Standing rules: failing test first, smallest change, suite green after
every consumer conversion, `scripts/perf-smoke.sh` at the end, feel in
Release. 616 tests green at start.

## Architecture

- `WrapIndex` today stores per-line prefix sums of visual ROW COUNTS
  (`rowOffsets`: line → first visual row), spliced on edit. Add the
  parallel **y-geometry**: per-line `height(line)` (from
  `markdownRowHeight(for state)`; uniform `layout.lineHeight` for
  non-markdown and for any line without a custom height) and prefix sums
  `yOffsets[line]` = cumulative height of all rows before the line.
  `y(line, rowInLine) = yOffsets[line] + rowInLine × height(line)`;
  content height = `yOffsets[last] + rows(last) × height(last)`;
  `line(forY:)` = binary search. **Uniform fast path**: when no line has
  a custom height (non-markdown, or markdown with no slim rows), keep
  the existing `row × lineHeight` O(1) arithmetic — assert parity in
  tests.
- Maintained in the same three places row counts are maintained: the
  synchronous build, the detached worker build (heights derive from the
  states the worker already computes), and the per-edit splice.
- While `wrapIndex == nil` (background-build window), geometry falls
  back to uniform — a transient, already-accepted state.

## Consumer conversion checklist (the known inventory)

Every `CGFloat(row) * layout.lineHeight` and `y / lineHeight` site:

1. `visibleVisualRowRange(in:)` (dirty-rect → rows) and
   `accessibilityVisibleCharacterRange`.
2. `TextViewportLayout.frameHeight` incl. the overscroll tail (tail uses
   the LAST row's actual height).
3. Draw: `drawVisualRows` y, huge-row draw, selection highlight rects,
   caret rect (height = its line's row height), composition caret.
4. Hit-testing: `endpoint(at:)` y→row resolution, `columnUTF16(forX:)`
   unaffected (x only), `characterIndex(for:)` via endpoint.
5. `scrollCaretToVisible` rect; `firstRectInViewCoordinates` (IME
   candidate window) y + height.
6. Margin line numbers (skip drawing numbers on rows shorter than the
   number's natural height — slim rows are unnumbered, like wrapped
   continuation rows).
7. Markdown chrome: table frame/rule ys (mid rule = slim separator row's
   vertical center), fence/frontmatter card spans, quote bar y/height,
   hr rule y, bullet/ordered/checkbox marker y (all already take y from
   row math — they convert mechanically once y(line) exists).
8. Huge-line branches (grid path) — exempt: huge lines keep uniform
   height by policy.
9. Vertical caret travel (`moveVertically` goal-x) — row-based, only the
   y lookup changes.

## Sequence

1. Pure geometry core + tests: extend `WrapIndex` (or a sibling
   `RowGeometry` struct it owns) with heights + y prefix sums + binary
   search + splice; parity tests (uniform doc: y == row×h for every row;
   slim doc: hand-computed ys; splice == full rebuild).
2. `markdownRowHeight(for state)` (+ constant
   `tableSeparatorRowHeight: CGFloat = 6` in `MarkdownDocumentMetrics`);
   heights threaded into the three build paths.
3. Convert consumers in the checklist order, full suite after each
   group; the table-rule/spacing tests updated last (header→body gap
   assertion ≈ 13 pt: 24 + 6/2 for the mid rule y, etc.).
4. `scripts/perf-smoke.sh` + scroll feel in Release (binary search
   replaces O(1) row math only on markdown documents with slim rows).

## Risks

- The caret can land on a 6 pt row (arrow down through the separator) —
  honest, visible as a short caret; acceptable.
- Any consumer missed = misaligned drawing/hit-testing on documents with
  tables; the checklist above is the inventory established by three
  prior reviews — trust it over re-derivation.
- Scroll perf: y→row becomes O(log lines) per event on affected docs;
  budgets verified by perf-smoke.
