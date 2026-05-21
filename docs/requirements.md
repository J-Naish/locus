# Product Requirements

This document is the entry point for the Locus product requirements.

The detailed requirements are split into a few stable documents so each file stays readable:

- [Product Brief](product/brief.md)
- [UX Direction](product/ux-direction.md)
- [MVP and Roadmap](product/mvp-roadmap.md)
- [Technical Direction](architecture/technical-direction.md)
- [Core Feature Scope](specs/core-feature-scope.md)

## Summary

Locus is a lightweight local document workspace for people who work with business files every day. It combines the clarity of Finder, the immediacy of Preview, and a focused document editing and review experience.

The first target is a native macOS app. Heavy cross-platform logic should live in a shared Rust core so a future Windows app can reuse file indexing, search, cache, diff, and workspace behavior.

Locus should stay local-first, fast, quiet, and approachable. It should not become an IDE, an Office suite, an Acrobat replacement, an AI chat tool, or a plugin platform.
