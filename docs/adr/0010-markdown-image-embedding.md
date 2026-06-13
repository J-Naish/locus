# ADR 0010: Markdown Image Embedding as Leading-Inset Blocks

- Status: accepted
- Date: 2026-06-13

## Context

The markdown view renders display-space text (ADR 0008/0009): syntax
markers are removed from the display string, and a per-line map keeps
caret, selection, and edits working against the buffer. Image syntax
`![alt](src)` rendered as secondary alt text only; users embedding
screenshots and diagrams from local paths or https URLs saw no image.

Any image design must not weaken the editing contract: no caret-reveal,
markers stay invisible and unreachable, deleting a span's last visible
character removes the whole syntax including the URL, and the engine's
per-line row metrics (row height, leading inset, trailing inset — ADR
0006's custom engine extended for headings) remain the only geometry
primitive.

## Decision

A line whose only content is one image renders as an **image block
inside the line's leading inset**, with the alt text below it as a small
muted caption that is the line's normal text row.

- Classification: `MarkdownLineStyleState.imageSource` is set for
  image-only lines (never inside fences, frontmatter, indented code,
  tables, reference definitions, or setext headings — heading
  interpretation wins; list items keep their image as inline alt text so
  bullets never float beside a tall block). Optional titles and angle
  brackets are stripped from the destination. Bodies past a length cap
  never classify, so a clipped huge line (e.g. an unsupported base64
  data URI) cannot carry block metrics its grid-drawn rows cannot honor.
- Geometry: the line's metrics become
  `leadingInset = air + image height + caption gap`,
  `rowHeight = caption row`, `trailingInset = air`. Because the caption
  is an ordinary text row, caret, selection, editing, span-integrity
  deletion, and the display map are untouched; editing the caption edits
  the alt text. Clicks in the image strip resolve to the caption row.
- Loading: a main-actor `MarkdownImageStore` resolves sources (relative
  paths against the document folder; `~/` expands but `~user` forms do
  not; `https://` remote; `http://` and unknown schemes fail quietly),
  probes the natural size header-only off the main thread, then decodes
  downsampled pixels on demand when a block first draws (WWDC18
  `CGImageSourceCreateThumbnailAtIndex` recipe, sized to the fitted rect
  times the backing scale). SVG and PDF fall back to NSImage
  (undocumented best-effort for SVG; nil becomes a quiet failure card).
  Decoded bitmaps live in a byte-budgeted LRU; remote responses go
  through one shared `URLSession` with a dedicated `URLCache`, cookies
  disabled.
- Untrusted-input bounds (documents are often agent-written): remote
  responses stream against a 64 MB cap and abort the moment they exceed
  it (also catching gzip inflation), a 60 s whole-transfer timeout stops
  slow-drip servers, at most four remote fetches run concurrently, and
  headers declaring more than 100 megapixels are rejected before any
  decode — PNG-family decompression bombs never reach a decoder.
- Reflow: size arrivals coalesce into one geometry rebuild per
  main-actor turn, preserving the first visible line's viewport offset
  so content the user is reading does not shift (deferred to the
  background build's completion for documents above the synchronous wrap
  limit); pixel arrivals only repaint.
- Sizing: fit to the text column width, never upscale a bitmap past its
  natural size, cap very tall images at 560 pt (width shrinks
  proportionally).

## Consequences

- Notion-like reading: images render in place with calm placeholders
  and failure cards, while light editing keeps working unchanged.
- In-paragraph inline images still render as alt text (deferred), as
  does GIF animation (first frame shows).
- Remote fetching reveals the reader's IP and read time to image hosts —
  the markdown-editor category norm (Obsidian, Typora, Bear ship the
  same default). Cookies are never sent. A "load remote images" toggle
  can be added if needed. Remote image URLs and bytes persist in the
  app's cache folder under `~/Library/Caches` (standard platform
  behavior; a future clear-caches affordance can empty it).
- The app is currently unsandboxed, so local reads and https fetches
  need no entitlements; the sandboxing milestone (ADR 0002) must add
  `com.apple.security.network.client` for remote images, and image
  resolution must gain security-scoped access — sibling and parent
  paths fall outside a document's own scope and would otherwise fail
  silently.
- A document's image states cache for the life of its open view;
  external image-file changes show after the document reloads.
