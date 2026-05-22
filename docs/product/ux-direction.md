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
- a normal launch starts at the user's home folder as the first working location
- the launch-time home location is not treated as a user-chosen recent folder
- switching locations should be fast
- the current location should always be clear
- users should be able to jump to an item's containing folder inside Locus and keep the item selected
- users should be able to preview and edit supported files without leaving Locus

Locus should feel familiar to Finder users, but search should be a first-class way to move through files and folders. The goal is not to copy a launcher UI. Users should be able to keep the mental model of folders, locations, recents, and favorites while getting fast, forgiving search across the places they care about.

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
- show containing folder in Locus
- copy path

The default shortcut should be `Command-K`.

## Language and Localization

The MVP UI may ship with English strings while the product surface is still changing quickly.

Keep user-facing strings plain, short, and ready for a future String Catalog pass. Avoid embedding developer terms in UI copy. Plan a Japanese localization pass once the main file browsing, preview, and editing flows stabilize enough that wording will not churn every milestone.

## Editing and Preview Experience

Markdown should feel like document editing, not source code editing.

YAML, JSON, TOML, and similar configuration files should also receive a rich editing experience. These files are often used to configure AI agents and local automation tools, so Locus should make them readable, safe, and comfortable to edit without turning the app into an IDE.

The broad editing layout may borrow from familiar editor patterns, but the user experience should not feel like VS Code or Cursor. It should be easier to scan, more document-oriented, and less technical. AI-adjacent files such as prompts, instructions, Markdown drafts, structured configuration, and generated artifacts should receive richer presentation where it helps comprehension, while the underlying local file remains explicit and portable.

Notion-like ease is a useful reference for readability and approachable document handling, but Locus should not adopt block-database complexity or hide files behind an app-specific content model. Detailed UI controls and secondary affordances can evolve later; the durable direction is a fast local file workspace with unusually strong search, preview, and lightweight editing.

PDFs should focus on reading, searching, highlighting, comments, and lightweight review. Locus should not attempt full PDF content editing.

Office files should focus on recognition, preview, and search metadata rather than full editing.

Unsupported files should still have useful actions: preview when possible, show in Locus, and copy path. In-app navigation should be the default path when the goal is locating or selecting a file; leaving Locus should not be a primary product flow.

## UI Anti-Goals

Avoid:

- dense IDE-style file trees
- Office ribbon-style command surfaces
- Notion-like block complexity
- loud gradients and AI-tool visual tropes
- permanent oversized toolbars
- developer terminology in primary flows
- hidden behavior that modifies files unexpectedly
