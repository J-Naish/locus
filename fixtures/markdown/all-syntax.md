---
title: Markdown Syntax Coverage
status: fixture
reviewers:
  - dario
  - altman
  - musk
tags:
  - markdown
  - rendering
  - fixture
---

# Markdown Syntax Coverage Fixture

This synthetic file is a rendering checklist for Locus. It intentionally mixes
business-document prose with Markdown syntax so visual regressions are easy to
spot.

## Headings

# Heading 1

## Heading 2

### Heading 3

#### Heading 4

##### Heading 5

###### Heading 6

Setext Heading 1
================

Setext Heading 2
----------------

## Paragraphs And Line Breaks

This is a normal paragraph with enough text to wrap inside the rendered
Markdown column. It should remain readable, calm, and document-like rather than
looking like a code editor.

This paragraph has a soft line break
that stays in the same paragraph in most Markdown renderers.

This paragraph uses an HTML line break.<br>
The next sentence should start on a new visual line.

## Inline Styling

Plain text can include *italic*, **bold**, ***bold italic***, and ~~struck
through~~ spans.

Escaped markers should remain literal: \*not italic\*, \*\*not bold\*\*, and
\`not code\`.

Inline code should render as a small code chip: `config.yaml`, `quarter: 2026-Q2`,
and `locus --open`.

Mixed inline syntax: **bold with `code` inside**, *italic with [a link](https://example.com)
inside*, and `code_with_*_markers`.

## Links And Images

Named link: [Locus requirements](../../docs/requirements.md)

Reference link: [Product brief][product-brief]

Autolink: <https://example.com/reports/q2>

Email autolink: <review@example.com>

Image:

![Fixture SVG](../media/valid/locus-fixture.svg)

[product-brief]: ../../docs/product/brief.md

## Blockquotes

> A single blockquote should show as quoted prose.

> A multi-line blockquote keeps each line visually grouped.
> It may wrap across several visual rows when the column is narrow.

> Nested quote level one.
>> Nested quote level two.
>>> Nested quote level three.

> ### Heading Inside A Quote
>
> - Quoted bullet item
> - Another quoted item with **bold** text

## Lists

Unordered list:

- First bullet
- Second bullet with a continuation paragraph

  The continuation paragraph belongs to the second bullet.
- Third bullet

Alternative bullet markers:

* Asterisk bullet
+ Plus bullet

Ordered list:

1. First ordered item
2. Second ordered item
3. Third ordered item

Ordered list with non-one start:

7. Starts at seven
8. Continues at eight

Nested list:

- Project
  - Draft
    - Section notes
  - Review
- Release
  1. Prepare summary
  2. Send update

Task list:

- [ ] Update revenue summary
- [x] Confirm department numbers
- [ ] Replace attachment with the latest version

## Tables

| Team | Owner | Status | Delta |
| --- | --- | :---: | ---: |
| Sales | Nishi | Draft | +12% |
| Finance | Aoki | Review | -3% |
| Ops | Tanaka | Done | 0% |

Table with inline formatting:

| Field | Example |
| --- | --- |
| Link | [brief](../../docs/product/brief.md) |
| Code | `status: draft` |
| Emphasis | **important** |

## Code

Indented code block:

    quarter: 2026-Q2
    status: draft
    reviewers:
      - nishi

Fenced code block with backticks:

```yaml
quarter: 2026-Q2
status: draft
reviewers:
  - nishi
  - aoki
```

Fenced code block with tildes:

~~~json
{
  "quarter": "2026-Q2",
  "status": "draft",
  "reviewers": ["nishi", "aoki"]
}
~~~

Code fence without a language:

```
# This should stay code, not become a heading.
- This should stay code, not become a list.
```

## Horizontal Rules

Three hyphens:

---

Three asterisks:

***

Three underscores:

___

## HTML

Inline HTML: <kbd>Cmd</kbd> + <kbd>B</kbd>

Block HTML:

<details>
<summary>Review note</summary>

This content is inside an HTML details block.

</details>

## Footnotes

This sentence has a footnote reference.[^1]

[^1]: Footnote definitions are included so unsupported renderers still expose
    the raw Markdown clearly.

## Definition List

Term
: Definition text for renderers that support definition lists.

Another term
: A second definition.

## Escapes And Entities

Escaped punctuation: \# heading marker, \- list marker, \[link label\], and
\> quote marker.

Entities: &amp; &lt; &gt; &copy;

## Final Checklist

- [ ] Headings keep hierarchy.
- [ ] Lists keep indentation.
- [ ] Code fences do not apply Markdown styling inside.
- [ ] Links are readable without hiding the destination forever.
- [ ] Front matter is visually distinct.
- [ ] Markdown markers are hidden at rest and revealed when editing.
