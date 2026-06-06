# 0006. Use One Custom Text Engine Instead Of NSTextView

## Status

Accepted (supersedes the text-editing parts of ADR 0001 and the early
`NSTextView`/TextKit references in the macOS implementation plan).

## Context

Text documents were first edited with an `NSTextView`/TextKit editor that loaded
the whole file into a Swift `String`, while files above a 64 MB limit fell back
to a separate virtualized viewer. Maintaining two engines was costly, and the
string-backed editor could not open very large files or stream them efficiently.

A virtualized engine was built to handle any size: a flipped `NSView` that draws
only the visible band with Core Text, backed by the Rust `TextBuffer` (a
piece-tree the file is memory-mapped into). Over successive slices it reached
parity for the prototype's needs — editing, international input (IME), undo/redo,
cut/copy/paste, save in the original encoding, soft wrap, line numbers, word and
line selection (locale-aware), a blinking caret, and range-based VoiceOver.

## Decision

Use the custom virtualized text engine for every editable text file, at any
size, in every build. Retire the `NSTextView`/TextKit editor (`TextDocumentEditorView`
and its gutter/line-number helpers) and the editable-string load/save service
(`TextDocumentStore`). Reverting to `NSTextView` is comparatively easy if needed,
which keeps the risk of unifying low.

## Consequences

- One text engine to maintain; large files open and edit without a size cap.
- The engine owns its own loading, failure UI, editing, save, dirty state, and
  external-change reconciliation; the document surface just hosts it.
- Lines longer than the display clip are read in full for accessibility but not
  drawn in full; very long single lines have no horizontal scroll in wrap mode.
- Switching files no longer keeps an unsaved in-memory draft (the old
  string-backed behavior). Per-entry dirty-buffer retention can be added later.
- Word boundaries follow the OS text tokenizer, so navigation, selection, and
  deletion are correct for CJK and other scripts rather than ASCII-only.
