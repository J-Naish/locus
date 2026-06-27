---
title: Heading Syntax Cases
status: fixture
tags: [markdown, headings, edge-cases]
---

# Heading Syntax Cases

The goal of this file is to make heading hierarchy, spacing, and malformed
heading-like text easy to inspect.

# H1: Product Brief

## H2: Review Notes

### H3: Section With Inline **Bold** And `Code`

#### H4: Section With [A Link](https://example.com)

##### H5: Small Heading

###### H6: Smallest Heading

Setext H1
=========

Setext H2
---------

# Closed Heading With Trailing Hashes ###

## Closed Heading With Extra Spaces     ####

#No space after hash should stay literal

####### Seven hashes should stay literal

\# Escaped hash should stay literal

### Heading followed by a thematic rule

---

> ## Heading inside a quote
>
> The quote body should keep its quote treatment after the heading.

- ### Heading-looking text inside a list item
- The next list item should not inherit heading styling.

1. #### Ordered list item that starts with heading syntax
2. Plain ordered item after it.

Paragraph before a Setext-looking underline
---

The previous line may be treated as a Setext H2 by parsers that support it.

```
# Heading marker inside code must stay code.
## Another code heading
```
