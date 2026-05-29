# Performance Log

Use this file for curated performance notes that explain meaningful changes.
Raw machine-local run data belongs in `target/perf-runs/` and is not committed.

## 2026-05-22T13:21:25Z workspace-directory-monitor

- commit: `1cb1fb6`
- branch: `main`
- dirty tree: `true`
- status: `0`
- folder listing: entries `1010`, avg `4.338 ms`, max `4.787 ms`
- Rust FFI static library: `17682728 bytes`
- macOS app bundle: `1244 KiB`
- notes: Added DispatchSource-based current-folder change monitoring and auto-refresh.

## 2026-05-22T14:13:43Z search-ranking

- commit: `87724f4`
- branch: `main`
- dirty tree: `true`
- status: `0`
- folder listing: entries `1010`, avg `4.419 ms`, max `5.734 ms`
- Rust FFI static library: `17682728 bytes`
- macOS app bundle: `1320 KiB`
- notes: Added relevance-ranked name search with conservative typo matching; debug XCTest 10k-entry search guard ran in 0.091s during full test.

## 2026-05-22T14:28:21Z workspace-cross-search

- commit: `63175f2`
- branch: `main`
- dirty tree: `true`
- status: `0`
- folder listing: entries `1010`, avg `4.190 ms`, max `5.349 ms`
- Rust FFI static library: `17682728 bytes`
- macOS app bundle: `1348 KiB`
- notes: Before the prototype chrome trim, workspace search surfaced saved shortcuts alongside current folder results; debug XCTest 10k-entry plus 3k-shortcut resolver guard ran in 0.108s.

## 2026-05-22T18:56:29Z home-default-launch

- commit: `adc0af4`
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `2.796 ms`, max `3.142 ms`
- local home folder listing: entries `141`, avg `0.265 ms`, max `0.288 ms`
- Rust FFI static library: `17682728 bytes`
- macOS app bundle: `1776 KiB`
- notes: Normal unsandboxed launch now starts at the home folder. Startup still uses a single non-recursive immediate-children listing; current-folder monitoring uses debounced directory events and does not watch recursively.

## 2026-05-22T19:03:20Z home-hidden-entry-filter

- commit: `1fdd7de`
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `4.263 ms`, max `4.682 ms`
- Rust FFI static library: `17682728 bytes`
- macOS app bundle: `1836 KiB`
- notes: Added home-folder presentation filtering for hidden files, hidden folders, and matching home shortcuts. The hidden-resource check runs off the main actor after the non-recursive core listing returns.

## 2026-05-24T10:40:21Z text-syntax-highlighting

- commit: `ad0ef03`
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `4.644 ms`, max `5.740 ms`
- Rust FFI static library: `17682728 bytes`
- macOS app bundle: `2404 KiB`
- notes: Added NSTextView-based lightweight text highlighting. Regex patterns are cached, incremental edits re-highlight the edited paragraph, and full-document highlighting keeps a 200k UTF-16-unit guard for large files.

## 2026-05-24T13:35:42Z lazy-listing-metadata

- commit: `b6da469`
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `5.234 ms`, max `6.231 ms`
- Rust FFI static library: `17683360 bytes`
- macOS app bundle: `2404 KiB`
- notes: Default folder snapshots now omit extended size and modified-time
  values. This is primarily a contract and Swift conversion cleanup, not yet a
  syscall reduction; per-entry metadata reads still happen for kind and
  readonly state. Extended metadata is available through an explicit Rust/FFI
  list option for future contextual surfaces.

## 2026-05-24T14:27:02Z pdf-text-search

- commit: `773354b`
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `3.403 ms`, max `4.612 ms`
- Rust FFI static library: `17683360 bytes`
- macOS app bundle: `2556 KiB`
- notes: Historical entry from the earlier PDF text-search slice. The prototype
  later removed custom PDF chrome; keep this measurement only as context for
  the prior implementation.

## 2026-05-25T01:07:43+09:00 document-external-change-sync

- commit: `4a396e3`
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `4.735 ms`, max `5.981 ms`
- Rust FFI static library: `17683360 bytes`
- macOS app bundle: `2728 KiB`
- notes: Added open-document external change synchronization. Displayed
  in-place files use file-system notifications and compare lightweight
  size/modified fingerprints before reloading document contents, so folder
  refreshes and unrelated filesystem events avoid full document reads in the
  common no-change path. The folder-listing number is unrelated to document
  sync and appears to be local smoke-run variance; it remains below budget.

## 2026-05-25T06:13:53+09:00 defer-custom-pdf-chrome

- commit: `a975896`
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `4.661 ms`, max `5.720 ms`
- Rust FFI static library: `17683360 bytes`
- macOS app bundle: `2196 KiB`
- notes: Removed custom PDF page, zoom, and search chrome from the prototype
  document surface and returned PDFs to a plain PDFKit preview. The app bundle
  size dropped because the PDF controller/search UI and related UI-test fixture
  helpers were removed.

## 2026-05-29T13:29:42+09:00 symlink-target-listing

- commit: `7627a28`
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `5.084 ms`, max `5.569 ms`
- symlink-heavy folder listing: entries `200`, avg `0.988 ms`, max `1.016 ms`
- Rust FFI static library: `17695048 bytes`
- macOS app bundle: `3352 KiB`
- notes: Added target-aware symlink listing so directory links can expand like
  folders and file links can open like their targets. The symlink-heavy smoke
  fixture alternates file and directory links that point outside the listed
  folder, covering the extra target metadata resolution work in the listing
  path.
