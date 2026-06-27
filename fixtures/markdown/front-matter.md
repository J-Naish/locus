---
title: Front Matter Cases
status: draft
name: pdf
description: "Comprehensive PDF toolkit for extracting text and tables, merging, splitting, and handling forms."
license: see LICENSE.txt
allowed-tools: [Read, Write, Bash]
tags:
  - markdown
  - rendering
  - fixture
reviewers:
  - dario
  - altman
  - musk
empty-value:
quoted-colon: "owner: docs"
single-quoted: 'literal value'
nested:
  owner: docs
  priority: high
multiline-literal: |
  First line of a literal value.
  Second line should stay visually grouped.
multiline-folded: >
  Folded values are common in descriptions and should remain readable even
  when the renderer does not fully understand YAML folding.
---

# Front Matter Cases

This file exercises YAML front matter that appears in SKILL.md files and
business documents.

The following delimiter-looking line is in the body, not front matter:

---

Body text after a thematic rule should render as normal Markdown.
