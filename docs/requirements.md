# Product Requirements

This document is the entry point for the Locus product requirements.

The detailed requirements are split into a few stable documents so each file stays readable:

- [Product Brief](product/brief.md)
- [UX Direction](product/ux-direction.md)
- [MVP and Roadmap](product/mvp-roadmap.md)
- [Technical Direction](architecture/technical-direction.md)
- [Core Feature Scope](specs/core-feature-scope.md)

## Summary

Locus is a lightweight local document workspace for people who work with business files every day. It combines the clarity of Finder, the immediacy of Preview, stronger local file search, and a focused document editing and review experience.

The core idea is that AI agents such as Codex and Claude Code are becoming useful for broad, general-purpose work beyond software engineering. Business users increasingly rely on these tools, but they still need a fast, understandable place to preview, review, organize, and lightly edit the files those agents touch or produce.

Agent desktop apps are not strong enough at local file search, preview, and editing. Finder is approachable but weak for search-heavy document work. Launcher-style file search can be fast but is not a natural primary workspace for many business users. VS Code and Cursor are powerful, but they are built for engineers, include too much unrelated functionality, and provide a weak native-feeling experience for document-oriented work such as Markdown review and preview. Locus exists to fill that gap.

The first target is a native macOS app. Heavy cross-platform logic should live in a shared Rust core so a future Windows app can reuse file indexing, search, cache, diff, and workspace behavior.

Locus should stay local-first, fast, quiet, and approachable. It should not become an IDE, an Office suite, an Acrobat replacement, an AI chat tool, or a plugin platform.
