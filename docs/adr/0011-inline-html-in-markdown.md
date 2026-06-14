# ADR 0011: Inline HTML in the Markdown View

- Status: accepted
- Date: 2026-06-13

## Context

The rendered Markdown view (ADR 0006/0008/0009) is a custom Core Text
engine, not a browser, and not WebKit. Until now HTML embedded in
Markdown was not handled at all: tags and entities rendered as literal
text. Authors (and the AI agents Locus is built to work alongside)
routinely use a little inline HTML — `<br>`, `<kbd>`, `<mark>`,
`<b>`/`<i>`, `<a>`, and HTML entities like `&copy;` / `&#x1F600;`. We
want that to render, as broadly as is tasteful, without turning the
document view into an HTML/CSS/JS engine. (`<sub>`/`<sup>` are deferred —
see Consequences.)

A future standalone HTML *preview* surface (likely WKWebView or
QuickLook) is the intended home for full-fidelity, single-file HTML. Its
rendering logic does not transfer to this engine, so HTML support inside
Markdown is built natively here.

## Decision

Render a curated allowlist of **inline** HTML in the existing two-pass
display-space inline pipeline (`renderedInlineDisplayMap` builds the
marker-removed display string + column map; `applyRenderedMarkdownInline`
applies attributes). HTML reuses the same machinery and the same
typographic attributes as the Markdown equivalents, so it looks native.

- **Formatting tags** (paired, single-line): `<b>`/`<strong>` → bold,
  `<i>`/`<em>`/`<cite>` → italic, `<s>`/`<strike>`/`<del>` →
  strikethrough, `<u>`/`<ins>` → underline, `<code>`/`<kbd>` and
  `<mark>` → the inline-code chip, `<small>` → dimmed. The tag markers
  are removed in display space exactly like emphasis delimiters, so the
  inner text remains lightly editable (ADR 0009).
- **Entities**: a static table of ~110 common named entities plus
  numeric/hex (`&#169;`, `&#x1F600;`) decode to their character. Invalid
  code points, surrogate halves, and NUL/control/bidi-format scalars are
  left literal. A decoded character collapses to a single buffer span
  (every UTF-16 unit, including both halves of a surrogate pair, maps to
  the whole entity), so the caret never lands inside it and copy returns
  the original markup.
- **Links**: `<a href>` renders its text in the link style only when the
  href is safe — `http`/`https`/`mailto` or a scheme-less relative
  reference, checked after entity-decoding the value so obfuscated
  schemes (`&#106;avascript:`) cannot slip through. Any other tag stays
  literal; opening links is deferred (Markdown links do not open today
  either).
- **`<br>`** becomes a space; a true forced mid-line break is not
  expressible in the per-buffer-line soft-wrap model.

Everything not on the allowlist — `<script>`, `<style>`, `<iframe>`,
`on*` handlers, unknown tags, and **all block HTML** (`<div>`,
`<table>`, `<details>`, `<ul>`, `<blockquote>`, …) — is left **literal**.
The regexes simply never match it, so no stripping code is needed and
the behaviour is honest. Escaped HTML (`&lt;b&gt;`) decodes to literal
`<b>` text and is not re-interpreted as a tag (decoded entity output is
protected from the tag rules).

Security: no JavaScript, no CSS, no `<style>`/`<script>` interpretation.
Only `href` (links), `src`, and `alt` (`<img>`) are read, and they are
read with a quote-aware tag scanner — never a loose regex — so an
attribute keyword sitting inside another attribute's quoted value (e.g.
`src=` inside `alt="… src=https://evil/x.png"`) is not mistaken for a
real attribute and cannot trigger a fetch. The only network access is the
existing image store fetching an `https://` `<img>`/`![]()` source (no
cookies, response size- and pixel-capped); `http`, `data:`, `file:`, and
every other scheme stay literal. The map and attribute passes apply the
identical, pure, deterministic rule sequence, so they run safely on the
off-main measurement worker and keep the display↔buffer caret map in
parity.

## Consequences

- The common inline-HTML and entity cases render beautifully by
  inheriting the Markdown typography; documents read as one hand.
- Block HTML and full CSS/JS/layout stay literal, by design — that
  fidelity is the future standalone HTML preview surface's job.
- Inline HTML spans are light-editable like emphasis (markers preserved
  in the buffer); there is no HTML serialization or toggle, consistent
  with the user's acceptance of read-only-ish HTML.
- Single-line **block** HTML followed (same engine, same security model):
  a whole-line `<img>` reuses the markdown image-block renderer (its
  `src` unquoted, entity-decoded, and limited to `https://` or a
  scheme-less local path; its `alt` the caption) and a whole-line `<hr>`
  reuses the thematic-break rule. An inline `<img>` mid-paragraph
  collapses to its alt, like an inline markdown image. Multi-line block
  HTML (`<details>`, `<table>`, `<div>`, …) stays literal — that fidelity
  remains the future standalone HTML preview surface's job.
- The tag regexes match a single `[^<>\n]*` run, so a literal `>` inside
  an attribute value (`<img alt="a > b">`) truncates the match and the
  line degrades to literal text. This is accepted: it keeps matching
  linear-time (no quoted-attribute backtracking) and is consistent with
  the literal-degrade policy for anything the allowlist cannot parse.
- Local image sources (markdown `![](…)` and HTML `<img>` alike) resolve
  any user-readable path, including `../` and absolute paths, and probe
  it header-only. This is bounded — only existence and pixel dimensions
  are ever surfaced, nothing is read into the document or sent over the
  network — and intended, since cross-folder asset references (`../assets/
  logo.png`) are a normal local-document pattern. Confining sources to the
  document folder is a possible future hardening, tracked separately.
- Deferred follow-ups: `<sub>`/`<sup>` (baseline offset can perturb wrap
  measurement), `<small>` true font-shrink (same reason; dimmed for
  now), opening links (for both Markdown and HTML at once), and any
  multi-line block HTML.
