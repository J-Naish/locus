# Core Feature Scope

## Workspace and File Management

Must support:

- start in the user's home folder by default on unsandboxed local builds
- hide hidden files and folders whenever the home folder itself is shown, while preserving useful dotfiles in explicit project folders
- open a local folder as a working location
- browse files and folders
- present the current workspace folder as the top expandable row in the
  sidebar, defaulting to expanded
- expand folder rows inline from a disclosure chevron in the sidebar, loading
  children lazily and indenting nested items
- keep double-clicking a folder as an explicit navigation into that folder
- move backward and forward through the current session's folder navigation
  history
- show a collapsed Recent Folders section below the sidebar's folder tree for
  folders the user explicitly opened as a location (folder picker or an
  existing Recent entry) or did real work in (opened a document, saved, or
  changed files there); navigating into a folder while browsing does not by
  itself create a Recent entry
- show the current location as a name-first file and folder list; Type, Size,
  and Modified columns are intentionally not part of the default browser
- keep default folder listing lightweight; size and modified-time metadata
  should be loaded only when a contextual surface explicitly needs it
- create new files and folders in the current workspace folder from the
  sidebar, without overwriting existing items
- move files and folders by dragging them onto a folder row in the sidebar,
  accept files dragged in from Finder (copy), and allow dragging items out to
  Finder; resolve name collisions by asking to replace or keep both, and make
  moves, imports, and replacements undoable
- open one selected file or folder in the document surface
- navigate to an item's containing folder inside Locus and select the item
- show recent files and folders
- detect file changes

Should support:

- restore state per location
- reflect external changes clearly
- delay expensive loading and thumbnails
- expose basic metadata contextually when it helps a concrete task, without
  turning the main file list into a metadata table
- show passive, read-only Git change indicators in the sidebar when the opened
  folder is inside a Git worktree, without exposing commit, branch, staging, or
  other Git workflow controls

## Search

Must support:

- file name search
- folder name search
- recent item search
- search within the current working location
- search across recent folders and recent files when the visible search flow returns
- fast first results
- result actions for open and copy path
- result presentation that keeps local file and folder locations understandable
- consistent name-search behavior in the current location, recent folders, and recent files
- relevance ordering that prefers exact names, extension-stripped name matches, prefix matches, substring matches, then conservative typo matches
- typo matching only for four-or-more-character terms; Japanese and other CJK names should rely on exact, prefix, and substring matching until a dedicated tokenizer exists

Should support:

- basic relevance ranking for exact matches, recency, and current location
- Markdown text search
- Office extracted text search
- SQLite FTS5
- incremental index updates
- saved or reusable search scopes

## Markdown

Markdown opens as a typeset rendered document that is edited in place
(see `docs/specs/markdown-document-view.md` and ADR 0009): only the final
result renders — no Markdown syntax visible, no space reserved for it —
while light editing works directly in the rendered page.

Must support:

- open Markdown files in the rendered document view
- render only the final result — headings, bold, lists, quotes, checklists,
  and code blocks typeset, with no Markdown syntax visible and no space
  reserved for it
- light editing in the rendered view: typing, deleting, list continuation,
  heading/list/quote structure changes via Backspace and Tab, emphasis via
  Cmd+B/I, checkbox toggling — every edit a plain change to the underlying
  file
- save Markdown as Markdown; comfortable Japanese text input
- automatically reflect disk changes for an open Markdown file; disk is the
  source of truth
- margin line numbers that map 1:1 to source lines
- text selection; copy yields raw Markdown source

Should support:

- frontmatter presentation
- a raw Markdown editor surface (optional, later)
- table presentation
- diff view

## Structured Text and Code Files

YAML, JSON, TOML, source code, scripts, and similar plain-text files should be treated as first-class editable documents. Configuration files are especially important because they are common in AI agent, automation, and local tool workflows.

Must support:

- open `.yaml`, `.yml`, `.json`, and `.toml` files
- open common extensionless text files such as `.gitignore`, `.env`,
  `README`, `Dockerfile`, and similar local tool configuration files
- open common source code and script files as plain text
- edit these files as first-class editable documents
- preserve valid plain-text file formats on save
- automatically reflect disk changes for an open text document, including while
  the editor has unsaved text; disk is treated as the latest source of truth in
  the prototype
- provide readable structure-aware presentation without hiding the underlying file format
- support comfortable keyboard editing and Japanese text input where values include natural language
- provide syntax highlighting for common programming, scripting, markup, and configuration languages

The first syntax-highlighting slice is readability-focused rather than IDE-like:
it highlights common keys, strings, numbers, booleans, comments, and a small set
of broadly familiar code keywords. Language-server features, deep parsing, and
validation are separate follow-up work.

Should support:

- indentation assistance
- bracket and quote pairing
- lightweight validation with clear inline errors
- schema-aware hints when a schema is available locally or embedded in the file
- diff view for external changes

Not a goal:

- turning configuration editing into a developer IDE
- adding IDE features such as LSP, debugger, or project-wide code intelligence
- requiring users to understand AI agent internals
- automatically sending configuration content to external services for validation

## PDF

The prototype PDF surface is a plain in-app PDFKit preview with no custom
chrome. Native PDFKit behaviors such as text selection, copy, scroll-based page
navigation, and trackpad zoom are acceptable as part of the base preview.
Explicit page controls, explicit zoom controls, search, highlights, comments,
thumbnails, and annotation saving are deferred until the PDF review flow is
intentionally expanded.

Must support:

- fast viewing
- native PDFKit reading behavior, including text selection and copy where the
  PDF provides selectable text
- scroll-based page navigation
- native trackpad zoom where PDFKit provides it

Should support:

- explicit page navigation controls
- explicit zoom controls
- case-insensitive text search with match navigation
- thumbnails
- highlights
- comments
- saving annotations
- drawing annotations
- text annotations
- shapes
- page rotation
- page deletion
- save a copy while preserving the original
- annotation list

Not a goal:

- full PDF text editing
- paragraph reflow
- Acrobat-level editing

## Office Files

Must support:

- recognize `.docx`, `.xlsx`, and `.pptx`
- preview inside Locus through native Quick Look rendering where possible
- copy path from file and shortcut context menus

Should support:

- text extraction
- search indexing
- thumbnails
- recent item inclusion

Not a goal:

- full Word editing
- full Excel editing
- full PowerPoint editing
- building an Office-compatible suite
- executing macros, embedded scripts, or active Office content

## Media and Other Files

Must support:

- image viewing
- video playback through an in-app native player
- audio playback through an in-app native player
- in-app Quick Look preview for Office files where macOS can render them
- copy path from file list and shortcut context menus, covering supported and unsupported file types

Should support:

- thumbnails
- additional Quick Look fallback actions
- file type icons
- simple metadata
- richer audio metadata and artwork presentation

Not a goal:

- image editing
- video editing
- audio editing

## Terminal

The terminal is an on-demand companion for running and reviewing agent CLI
sessions (ADR 0012). Full behavior is specified in `docs/specs/terminal.md`.

Must support:

- toggle the panel with ⌘J / Ctrl+` below the editor; the session survives
  hiding the panel
- run the user's login shell with faithful VT/xterm-family emulation,
  including full-screen TUIs, mouse reporting, and bounded scrollback
- comfortable Japanese text: correct wide-character layout, inline IME
  preedit, selection and caret interaction that work per character
- selection and copy where the highlight always matches what is copied
- find in the terminal (⌘F) and ⌘-click opening of http/https URLs
- a multi-line paste warning unless bracketed paste makes it safe
- honor program clipboard copies (OSC 52 writes) with a size guard;
  clipboard read requests are never honored

Not a goal:

- an always-visible terminal layout or multiple panes/tabs/splits
- shell configuration management, profiles, or theming surfaces

## Security and Privacy

Must preserve:

- local-first behavior
- no hidden upload of user files
- no recursive home-directory scanning on launch
- no Recent entry for the home folder itself, including the launch-time
  automatic open
- no built-in AI chat or agent
- no bundled AI model
- no plugin execution
- no app-initiated code execution; the terminal panel runs only what the
  user types (ADR 0012)
- minimal network behavior

Should support:

- clear file permission prompts
- dependency license tracking
- dependency vulnerability checks
- signed and verified updates when distribution begins
