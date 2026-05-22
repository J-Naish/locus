# Core Feature Scope

## Workspace and File Management

Must support:

- open a local folder as a working location
- browse files and folders
- open files
- reveal files in Finder
- open files in external apps
- show recent files and folders
- pin favorite folders
- detect file changes

Should support:

- restore state per location
- reflect external changes clearly
- delay expensive loading and thumbnails
- show basic metadata

## Search

Must support:

- file name search
- folder name search
- recent item search
- search within the current working location
- search across favorites, recent folders, and recent files
- fast first results
- result actions for open, preview, reveal in Finder, open externally, and copy path
- result presentation that keeps local file and folder locations understandable

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
- preview through native system facilities where possible
- open in external apps
- reveal in Finder

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

## Media and Other Files

Must support:

- image viewing
- video playback
- audio playback
- external handoff for unsupported files

Should support:

- thumbnails
- Quick Look preview
- file type icons
- simple metadata

Not a goal:

- image editing
- video editing
- audio editing

## Security and Privacy

Must preserve:

- local-first behavior
- no hidden upload of user files
- no built-in AI chat or agent
- no bundled AI model
- no plugin execution
- no arbitrary code execution features
- minimal network behavior

Should support:

- clear file permission prompts
- explicit external app handoff
- dependency license tracking
- dependency vulnerability checks
- signed and verified updates when distribution begins
