# Inline Syntax Cases

This file concentrates punctuation-heavy inline Markdown on normal paragraphs.

Plain emphasis: *italic with asterisks* and _italic with underscores_.

Strong emphasis: **bold with asterisks** and __bold with underscores__.

Combined emphasis: ***bold italic*** and ___bold italic with underscores___.

Nested emphasis: **bold with *italic inside*** and *italic with **bold inside***.

Code wins over markers: `*not italic*`, `**not bold**`, and
`[not a link](https://example.com)`.

Mixed inline syntax: **bold with `code` inside**, *italic with
[a link](https://example.com) inside*, and ~~strike with `code` inside~~.

Escaped markers should stay literal: \*not italic\*, \*\*not bold\*\*,
\_not italic\_, \[not a link\]\(https://example.com\), and \`not code\`.

Underscores inside words should stay literal: product_owner_name and
Q2_report_final.

Broken delimiters should not swallow the document: *open italic, **open bold,
`open code, and [open link](https://example.com.

Strikethrough cases: ~~removed text~~, ~~removed with **bold** inside~~, and
~~~~too many tildes~~~~.

Entities: AT&amp;T, 100&nbsp;%, &lt;tag&gt;, &copy; 2026, and &quot;quoted&quot;.

Inline HTML: <kbd>Cmd</kbd> + <kbd>S</kbd>, <mark>highlight</mark>,
<small>small print</small>, <code>html code</code>, and <u>underline</u>.

Unsafe inline HTML should stay safe: <a href="javascript:alert(1)">bad link</a>.
