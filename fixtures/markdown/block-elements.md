# Block Element Syntax Cases

Paragraphs with soft line breaks:
This source line follows immediately after the previous line and may be wrapped
as part of the same paragraph.

Paragraph with a hard line break.  
The previous line ends with two spaces.

Horizontal rules:

---

***

___

Hyphens with text around them should stay a paragraph:

before --- after

Escaped block markers:

\# Not a heading

\- Not a list

\> Not a quote

HTML block:

<div class="note">
  <strong>HTML block content</strong>
</div>

HTML comment:

<!-- This comment should not create visible prose in renderers that hide comments. -->

Single-line HTML:

<hr>

Footnote reference and definition:

This sentence has a footnote.[^review]

[^review]: Footnote text with **bold** and a second line.
    The continuation line should stay attached to the footnote.

Definition list syntax:

Term
: Definition text for renderers that support definition lists.

Another term
: A second definition with `code`.

Front-matter-like delimiter in the middle of a document:

---
not: front matter
---

The final paragraph should render normally.
