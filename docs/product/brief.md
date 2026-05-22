# Product Brief

## Product

Locus is a lightweight native desktop workspace for local business documents.

It is designed for people who regularly work with folders full of Markdown files, PDFs, Office documents, images, videos, meeting notes, manuals, proposals, and training materials.

The product should feel closer to Finder, Preview, Apple Notes, and a focused Markdown editor than to VS Code, Cursor, Notion, Office, or Acrobat.

## Core Concept

AI agents such as Codex and Claude Code are becoming general-purpose tools. They are no longer only for engineers. Business users increasingly use agents to draft, transform, inspect, and organize local files.

That creates a gap. Agent desktop apps are useful for orchestration, but they are not strong at everyday local file work: quick previews, lightweight edits, Markdown review, file comparison, and moving between generated artifacts. Developer tools such as VS Code and Cursor can do many of these things, but they are too technical, too dense, and too broad for non-engineers.

Locus is the companion workspace for that environment. It should make agent-produced and agent-edited files easy to find, move through, inspect, organize, preview, and lightly revise without turning into an AI chat app or an IDE.

The file and folder experience is a core part of the product, not a secondary picker. Finder is familiar and approachable for almost everyone, but its search experience is not strong enough for people working across many local documents. Keyboard-first launchers such as Raycast can find files quickly, but their command-style UI is less natural for beginners and many business users. Locus should combine Finder-like clarity with much better local file search, so users can browse, search, and move through local folders without needing a developer tool or a power-user launcher.

The editing and preview experience should remain lightweight and high performance, but it should make common AI-adjacent files feel richer and easier to handle than they do in code editors. VS Code and Cursor are useful reference points for flexible editing and preview layouts, but Locus should make those flows readable, comfortable, and non-technical for business users. For Markdown, structured text, notes, plans, and agent-related configuration files, the closer product feeling is a clear document workspace: more approachable and visually legible, with some of the ease people associate with Notion-like document handling, while still preserving local files as plain files.

## Target Users

Primary users:

- Business professionals who manage local documents daily
- Consultants, trainers, marketers, sales, planning, and operations roles
- People who are comfortable with Finder and Office but do not want developer tools
- People who use external AI or automation tools and need a clean place to review, organize, and lightly edit the resulting files

Out of scope:

- Developers looking for an IDE
- Users who need full Office document editing
- Users who need advanced PDF production workflows
- Linux desktop users in the initial product phase

## Product Principles

- Native first
- Local first
- Fast startup and responsive browsing
- No Electron
- No bundled AI model
- No built-in AI chat
- No extension or plugin system
- No always-on terminal
- No developer-centric features such as Git, LSP, or debuggers
- Clear file ownership and predictable behavior

## Positioning

Locus should be perceived as a local document workspace, not as a code editor, generic note-taking app, launcher, or file manager clone.

The core value is not feature count. The value is that local documents are easy to open, inspect, organize, search, review, and lightly revise without the app feeling heavy or technical.
