# 0009. Edit Markdown Through The Rendered View In Display Space

## Status

Accepted. Supersedes the read-only scoping of ADR 0008 (its display
transformation stands and becomes the editing substrate). Realizes the
editing goal of ADR 0007 with a different mechanism: no concealment
attributes, no marker reveal — display-space editing.

## Context

ADR 0008 made the Markdown view read-only to get the rendering right:
markers removed from the display string, structure drawn from layout.
That shipped, and the rendering is what the product wants — but the
product owner clarified that light editing is part of this view's
purpose: "Notion-like, minus the slash-command blocks. Primarily a
preview, but some editing happens here." A pure viewer is too little; a
separate raw editor is not a substitute for fixing a word in place.

The earlier attempts at editable concealment failed because the caret
lived in buffer coordinates while markers were invisible: every editing
gesture could silently touch characters the user could not see. The
display transformation inverts the situation. The displayed string simply
does not contain markers, so a caret that lives in *display* coordinates
can never sit inside one. Markers occupy buffer ranges that lie *between*
display positions; what remains is to translate display-space edits into
buffer edits through a per-line map — and to give the structural edits
that markers used to mediate (heading demotion, list continuation,
emphasis) explicit, Notion-like gestures.

## Decision

Markdown is edited directly in the rendered view:

- **One pipeline.** The rendered transformation (string removal +
  decorations) is the only Markdown styling path; the legacy
  attribute-concealment path (`muteMarkdownSyntax` et al.) is deleted.
  The transformation additionally emits a per-line `DisplayMap`
  (ordered removed buffer ranges; bidirectional column conversion).
- **Display-space caret and selection.** All caret/selection positions
  are display coordinates. Buffer crossings happen at exactly two seams:
  display→buffer when an edit or lookup needs a buffer offset
  (`utf16Offset(of:)`), buffer→display when restoring the caret after an
  edit (`finishEdit`). Boundary positions adjacent to removed markers
  map *outside* the markers (typing at the edge of bold text produces
  plain text, as in Notion).
- **Markdown semantics come from re-classification, not commands.**
  Typing `# ` at line start becomes a heading because the line re-parses
  on every edit; the prefix vanishes from the display the moment it
  parses. Incomplete syntax (`**bol`) renders literally until it parses —
  the same as Notion. Structural gestures are explicit edits: Backspace
  at a block's content start peels one level; Enter continues lists;
  Tab/Shift+Tab indent; Cmd+B/I wrap or unwrap raw markers; deleting a
  span's last visible character also removes its markers.
- **Copy is raw Markdown** for the mapped buffer range (markers included
  when the selection covers the whole visible span), so copy/paste
  round-trips formatting inside Locus and hands agents real source.
  Paste inserts plain text and re-parses live.
- **No slash menus, no block handles, no toolbar** — explicitly excluded
  by the product owner. The file on disk stays byte-honest; every edit
  is a plain buffer edit.

## Consequences

- The single new correctness primitive is the `DisplayMap` and its two
  seams; the failure modes of attribute concealment (invisible caret
  zones, blind deletions, reveal-induced re-wrap) are impossible by
  construction, and nothing ever reveals.
- IME needs the map (composition splices into the rendered string at a
  mapped position; classification of the composing line freezes until
  commit) — the hardest single piece, and Japanese input is a product
  requirement.
- The editing-era performance work returns: per-keystroke state and wrap
  splices instead of whole-document rebuilds.
- Save, dirty state, and the external-change conflict banner re-engage
  for Markdown through the existing machinery.
- A future raw editor surface (Phase R) remains compatible but is no
  longer a prerequisite for fixing a typo.
