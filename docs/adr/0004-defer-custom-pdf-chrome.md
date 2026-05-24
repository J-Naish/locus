# 0004. Defer Custom PDF Chrome

## Status

Accepted

## Context

The prototype needs a quiet document surface that proves local browsing,
previewing, and lightweight editing before deeper PDF review workflows are
settled. The earlier custom PDF slice added page controls, zoom controls,
search state, PDFKit notification handling, and reload restoration logic. That
increased surface complexity while the current prototype mostly needs reliable
in-app PDF viewing.

## Decision

Use a plain PDFKit preview for PDFs in the prototype.

- Keep native PDFKit reading behavior, including scrolling, selection, copy, and
  trackpad zoom where PDFKit provides it.
- Remove custom PDF page, zoom, and search chrome from the default document
  surface.
- Defer explicit PDF controls, text search, thumbnails, highlights, comments,
  and annotation saving to a later PDF review pass.

## Consequences

The PDF surface is smaller and easier to keep native while the prototype focuses
on browsing, previewing, and text editing. Future PDF review work should return
as a deliberate slice with clear UX and performance expectations instead of
incrementally re-adding default chrome.
