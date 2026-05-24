# Core Feature Scope

## Workspace and File Management

Must support:

- start in the user's home folder by default on unsandboxed local builds
- hide hidden files and folders whenever the home folder itself is shown, while preserving useful dotfiles in explicit project folders
- open a local folder as a working location
- browse files and folders
- show the current location as a name-first file and folder list; Type, Size,
  and Modified columns are intentionally not part of the default browser
- keep default folder listing lightweight; size and modified-time metadata
  should be loaded only when a contextual surface explicitly needs it
- open files
- navigate to an item's containing folder inside Locus and select the item
- show recent files and folders
- pin favorite folders
- detect file changes

Should support:

- restore state per location
- reflect external changes clearly
- delay expensive loading and thumbnails
- expose basic metadata contextually when it helps a concrete task, without
  turning the main file list into a metadata table

## Search

Must support:

- file name search
- folder name search
- recent item search
- search within the current working location
- search across favorites, recent folders, and recent files
- fast first results
- result actions for open, preview, show in Locus, and copy path
- result presentation that keeps local file and folder locations understandable
- consistent name-search behavior in the current location, favorites, recent folders, and recent files
- relevance ordering that prefers exact names, extension-stripped name matches, prefix matches, substring matches, then conservative typo matches
- typo matching only for four-or-more-character terms; Japanese and other CJK names should rely on exact, prefix, and substring matching until a dedicated tokenizer exists

Should support:

- basic relevance ranking for exact matches, recency, favorites, and current location
- Markdown text search
- PDF text search
- Office extracted text search
- SQLite FTS5
- incremental index updates
- saved or reusable search scopes

## Markdown

Must support:

- open Markdown files
- edit Markdown files
- save Markdown as Markdown
- common formatting such as headings, bold, lists, quotes, and code blocks
- lightweight syntax highlighting for common readability cues such as headings,
  inline code, links, and list markers
- comfortable Japanese text input

Should support:

- rich document-like editing
- table and checklist support
- frontmatter support
- external change detection
- diff view

## Structured Text and Code Files

YAML, JSON, TOML, source code, scripts, and similar plain-text files should be treated as first-class editable documents. Configuration files are especially important because they are common in AI agent, automation, and local tool workflows.

Must support:

- open `.yaml`, `.yml`, `.json`, and `.toml` files
- open common source code and script files as plain text
- edit these files with the same level of care as Markdown
- preserve valid plain-text file formats on save
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

The MVP PDF surface is an in-app PDFKit reader with page navigation and zoom
controls before deeper review tools are added.

Must support:

- fast viewing
- text search
- text selection and copy
- page navigation
- zoom
- thumbnails
- highlights
- comments
- saving annotations

Should support:

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
- show in Locus where the containing folder is available

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
- in-app location navigation for unsupported files where the containing folder is available

Should support:

- thumbnails
- Quick Look preview
- file type icons
- simple metadata
- richer audio metadata and artwork presentation

Not a goal:

- image editing
- video editing
- audio editing

## Security and Privacy

Must preserve:

- local-first behavior
- no hidden upload of user files
- no recursive home-directory scanning on launch
- no automatic Recent entry for the home folder opened at launch
- no built-in AI chat or agent
- no bundled AI model
- no plugin execution
- no arbitrary code execution features
- minimal network behavior

Should support:

- clear file permission prompts
- dependency license tracking
- dependency vulnerability checks
- signed and verified updates when distribution begins
