# Markdown Fixtures

Sample Markdown files for parser, editor, search, and diff tests.

Files here intentionally cover common business-document shapes and editor edge
cases: front matter, tables, links, code fences, Unicode, CRLF newlines, and
larger repeated sections.

- `all-syntax.md`: broad rendering checklist covering headings, inline styling,
  links, images, quotes, lists, tasks, tables, code, rules, HTML, footnotes, and
  escape cases.
- `headings.md`: ATX and Setext headings, closed headings, escaped heading
  markers, headings inside quotes and lists, and malformed heading-like text.
- `inline.md`: emphasis, strong emphasis, nested inline code, escapes, entities,
  HTML inline tags, broken delimiters, and punctuation-heavy spans.
- `list.md`: unordered, ordered, task, nested, mixed-marker, continuation,
  indented-code, and malformed list cases.
- `blockquotes.md`: nested quotes plus quotes containing headings, lists, tasks,
  tables, rules, and code fences.
- `table.md`: small, wide, and tall tables covering alignment, empty cells,
  escaped pipes, inline formatting, malformed rows, delimiter-less pipe text,
  column sizing, horizontal overflow, row rhythm, and long cell content.
- `code-fences.md`: fenced, tilde, unlabeled, indented, nested-looking, and
  intentionally unclosed code block cases.
- `links-and-images.md`: inline, reference, shortcut, autolink, image, missing
  image, unsafe URL, and escaped-link cases.
- `front-matter.md`: YAML front matter scalars, inline arrays, block arrays,
  nested values, quoted colons, and multiline values.
- `block-elements.md`: horizontal rules, HTML blocks, comments, footnotes,
  definition lists, soft breaks, hard breaks, and escaped block markers.
