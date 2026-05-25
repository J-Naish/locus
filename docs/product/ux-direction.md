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
- the home folder view should stay quiet by hiding hidden files and folders whether it was opened at launch or chosen later; explicit project folders may still show useful dotfiles such as `.env` and `.agents`
- switching locations should be fast
- the current location should always be clear
- users should be able to jump to an item's containing folder inside Locus and keep the item selected
- users should be able to move backward and forward through the current
  session's folder navigation history; this history is intentionally
  session-scoped and is not persisted across app restarts
- users should be able to preview and edit supported files without leaving Locus

Locus should feel familiar to Finder users while staying much quieter than a full file manager. Search can return once the prototype's browsing and document surfaces are stable; keep the underlying matching model available, but do not make a search box or launcher-like UI part of the default chrome yet.

The current-location file browser should stay name-first, closer to a compact native outline than to Finder's multi-column list. It should be narrow by default so the document surface remains dominant, while still allowing users to widen the divider when a folder has unusually long names. File and folder names are the primary information scent; Type, Size, and Modified metadata should not be shown as default columns. Surface metadata later only where it supports a specific decision, such as document details, search refinement, or inspection.

Folder rows can expand inline like a native outline-style sidebar so users can peek
into nearby folders without losing the current location. Double-click remains
the deliberate gesture for navigating into a folder.

The main window should open large enough for the file list and document surface
to sit side by side comfortably, but the minimum size should stay smaller than
that default so users can place Locus next to Finder, Preview, a browser, or an
AI agent app.

For the prototype, prioritize visible primary flows: browsing, preview, and
lightweight editing. Do not expand scope around secondary controls
until those flows are stable.

Recommended top-level areas:

- Home
- Recents
- Locations
- Tags

Use plain user-facing language such as "folder", "location", and "recent items". Internal concepts such as workspace can exist, but they should not dominate the UI language.

## Language and Localization

The MVP UI may ship with English strings while the product surface is still changing quickly.

Keep user-facing strings plain, short, and ready for a future String Catalog pass. Avoid embedding developer terms in UI copy. Plan a Japanese localization pass once the main file browsing, preview, and editing flows stabilize enough that wording will not churn every milestone.

## Editing and Preview Experience

Markdown should feel like document editing, not source code editing.

YAML, JSON, TOML, and similar configuration files should also receive a rich editing experience. These files are often used to configure AI agents and local automation tools, so Locus should make them readable, safe, and comfortable to edit without turning the app into an IDE.

The broad editing layout may borrow from familiar editor patterns, but the user experience should not feel like VS Code or Cursor. It should be easier to scan, more document-oriented, and less technical. AI-adjacent files such as prompts, instructions, Markdown drafts, structured configuration, and generated artifacts should receive richer presentation where it helps comprehension, while the underlying local file remains explicit and portable.

Notion-like ease is a useful reference for readability and approachable document handling, but Locus should not adopt block-database complexity or hide files behind an app-specific content model. Detailed UI controls and secondary affordances can evolve later; the durable direction is a fast local file workspace with unusually strong search, preview, and lightweight editing.

PDFs should start as plain native previews in the prototype. Searching, highlighting, comments, and lightweight review controls can return once the PDF review flow is deliberately expanded. Locus should not attempt full PDF content editing.

Office files should focus on recognition, in-app Quick Look preview, and search metadata rather than full editing.

Unsupported files should keep their fallback surface quiet and offer path copying where useful. External preview and explicit "show in Locus" commands are not part of the prototype chrome; opening supported items in place is the default path when the goal is locating or reviewing a file.

## UI Anti-Goals

Avoid:

- dense IDE-style file trees
- Office ribbon-style command surfaces
- Notion-like block complexity
- loud gradients and AI-tool visual tropes
- permanent oversized toolbars
- developer terminology in primary flows
- hidden behavior that modifies files unexpectedly
