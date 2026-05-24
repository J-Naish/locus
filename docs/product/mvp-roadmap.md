# MVP and Roadmap

## Phase 1: macOS MVP

The first prototype should prove the core product loop: open a local place,
move through files and folders with Finder-like clarity, find files faster than
Finder, preview the right item, and lightly edit common document and
AI-adjacent text files. Scope should stay focused on those prototype flows
instead of broad polish work.

### Phase 1A: Native Shell and Folder Navigation

Build the local workspace foundation first.

- native macOS app
- shared Rust core
- Home screen
- Finder-like sidebar
- favorite folders
- recent files and folders
- open a local folder as the current working location
- file list browsing
- folder navigation, including opening child folders and moving back up
- show an item's containing folder inside Locus and select the item
- Space-key quick preview
- file change detection

### Phase 1B: Search as a Core Navigation Flow

Search is part of the MVP product identity, not only a later optimization pass. The first version does not need every advanced index, but it must already feel like a better everyday file search experience than Finder for the active local workspace.

- fast file and folder name search in the current location
- search across the current location, favorite folders, recent folders, and recent files
- search results that remain understandable to Finder users
- clear result grouping by file, folder, favorite, and recent item where useful
- predictable open, show-in-Locus, preview, and copy-path actions from search results
- basic ranking that favors exact name matches, recent items, favorites, and current location matches
- no launcher-only UI as the primary search experience

### Phase 1C: Lightweight Preview and Editing Foundation

Once local movement and search are reliable, add the document work surface.

- Markdown editing
- structured text editing for YAML, JSON, TOML, prompts, instructions, and similar AI-adjacent files
- readable syntax highlighting without IDE features
- Quick Look-based Office preview
- image viewing
- video and audio playback
- PDF viewing
- common preview actions for unsupported files

### Phase 1D: Review and Change Awareness

Round out the MVP with the minimum review capabilities needed for local document work.

- external change review
- Markdown diff view for changed text documents
- basic PDF highlights and comments
- workspace state restoration for the current location
- performance and size smoke checks for the full app

## Phase 2: macOS Quality

After the MVP works end to end, improve search depth, document richness, and polish:

- full-text search
- SQLite FTS5
- metadata cache
- incremental index updates
- cross-location search beyond favorites and recents
- saved search scopes
- richer Markdown editing
- richer structured text validation
- PDF annotation persistence
- delayed thumbnail generation
- dark mode
- performance benchmarks

## Phase 3: Windows

Build a Windows native app after the macOS app has a stable product shape.

Expected direction:

- C#
- WinUI 3
- Windows App SDK
- shared Rust core
- Windows-native file preview behavior
- Windows packaging and signing

## Later Possibilities

Potential future additions:

- tags
- collections
- temporary workspaces
- simple PDF page operations
- Office text extraction
- Markdown export
- sponsor or donation flow
- managed distribution for organizations

These should not distract from the first product goal: a fast, local, native document workspace.
