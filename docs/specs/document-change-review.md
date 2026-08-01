# Document Change Review

Locus reviews external edits against the content the user last saw in the app.
The baseline is captured from the live in-memory document immediately before an
external reload, so it includes unsaved edits. It is session-scoped and does not
use Git.

## Baseline Lifecycle

- The first external reload stores the baseline for that document.
- Further external reloads keep the oldest pending baseline, accumulating changes
  since the user last reviewed or dismissed them.
- Reloading content identical to the baseline clears the pending review.
- Viewing and closing the review, or dismissing its notification, clears the
  baseline. Switching documents only hides the current review; pending baselines
  for other documents remain available.
- Review is available for editable-size text documents. Windowed large-file
  documents are excluded.

## Presentation

A persistent `Changed on disk` chip enters a read-only inline review. Common and
added lines follow the document's normal presentation, with added rows receiving
a quiet green tint. Removed lines are woven back into their original positions
with a quiet red tint and a red strike-through. Selection, copying, links, and
document find remain available, while editing controls stay inert.

Markdown is rendered from the combined review text. This keeps the presentation
self-consistent, but synthetic structure can affect parsing; for example, a
removed fence delimiter can pair with another delimiter in the combined text.
Plain-text reviews hide line numbers because synthetic rows have no stable source
line numbers.

The diff engine declines documents whose baseline and current content together
exceed 40,000 lines. The change chip still appears, but offers dismissal rather
than inline review.
