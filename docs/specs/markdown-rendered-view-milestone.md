# Markdown Rendered View — Current Milestone Status

This document records the current shipped state of the rendered Markdown
surface. Earlier versions of this file described the first variable-row-
height implementation plan; that work has now landed and the document is
kept as a compact status reference for follow-up implementation.

## Shipped

- **Display-space editing**: rendered text is edited through a display
  map back to raw Markdown source. Block markers, inline markers, media
  syntax, and structural table tabs are hidden or synthesized in display
  space while edits remain plain buffer edits.
- **Variable row geometry**: the viewport supports per-line heights and
  y-prefix geometry. Slim marker rows now cover table delimiter rows,
  setext underlines, fence/frontmatter delimiters, and other marker-only
  rows. Markdown rows with media, tables, frontmatter, headings, and code
  cards can carry their own measured heights.
- **Type scale**: headings use the current document scale from
  `MarkdownDocumentMetrics` (H1 30, H2 24, H3 21, H4 18, H5 15, H6 13
  secondary). Body text remains 15 pt; table cells use compact 13 pt
  text with a 20 pt cell line height.
- **Tables**: pipe tables render as quiet booktab-style tables. Columns
  are measured from styled content, capped at 200 pt, and long cells wrap
  inside their column. Wide tables scroll horizontally inside the table
  block only; the prose document measure stays fixed. Table scroll state
  and row-layout caches are kept out of IME-sensitive edit paths.
- **Media blocks**: image and local video references render as media
  blocks with captions and unavailable-state cards. Reference-style
  images and images inside links share the image-block renderer.
- **Links and tasks**: valid external links and local file paths open on
  click; invalid destinations use the invalid-link tint. Task
  checkboxes toggle the source marker with a normal undoable edit.
- **Code cards and frontmatter**: fenced and indented code render in
  quiet cards. YAML frontmatter renders as a soft metadata panel with
  vertical key/value layout, wrapped chips, and block scalar value cards.

## Follow-Up Notes

- Some rendered constructs intentionally remain conservative: unsupported
  Markdown/HTML stays literal, and fragment anchors are styled but inert
  until document anchors exist.
- Aggregated YAML sequence chips are still display-oriented because a
  line-local display map cannot directly edit values sourced from hidden
  sibling lines. Bracket arrays and block scalars remain editable through
  real source ranges.
- The rendered/source mode toggle is deliberately local to the document
  surface. Source mode reuses the plain-text presentation rather than a
  separate Markdown-specific raw renderer.
- Before large table or media changes, re-run the markdown layout tests
  plus `scripts/perf-smoke.sh`; row height, table scroll, and viewport
  anchoring are the sensitive paths.
