# UX Direction

## Design Tone

The product should feel like a quiet professional workspace.

The visual direction should be:

- simple
- calm
- lightweight
- native
- clear enough for Finder users
- polished without feeling decorative
- approachable for non-technical users

Useful references:

- Finder
- Preview
- Apple Notes
- Raycast
- Arc
- Craft
- Linear

## Navigation Model

The app should center on local places and recent work.

The primary model is:

- one window usually represents one current working location
- switching locations should be fast
- the current location should always be clear
- users should be able to reveal items in Finder
- users should be able to open files in external apps

Recommended top-level areas:

- Home
- Favorites
- Recents
- Locations
- Tags

Use plain user-facing language such as "folder", "location", "recent items", and "favorites". Internal concepts such as workspace can exist, but they should not dominate the UI language.

## Command Palette

The command palette should provide a fast keyboard-first path to common actions.

Initial commands:

- open a recent file
- open a recent folder
- search files by name
- create a Markdown document
- reveal in Finder
- open in an external app

The default shortcut should be `Command-K`.

## Editing and Preview Experience

Markdown should feel like document editing, not source code editing.

YAML, JSON, TOML, and similar configuration files should also receive a rich editing experience. These files are often used to configure AI agents and local automation tools, so Locus should make them readable, safe, and comfortable to edit without turning the app into an IDE.

PDFs should focus on reading, searching, highlighting, comments, and lightweight review. Locus should not attempt full PDF content editing.

Office files should focus on recognition, preview, search metadata, and external app handoff rather than full editing.

Unsupported files should still have useful actions: preview when possible, reveal in Finder, open externally, and copy path.

## UI Anti-Goals

Avoid:

- dense IDE-style file trees
- Office ribbon-style command surfaces
- Notion-like block complexity
- loud gradients and AI-tool visual tropes
- permanent oversized toolbars
- developer terminology in primary flows
- hidden behavior that modifies files unexpectedly
