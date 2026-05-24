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
- notes: Workspace search now surfaces matching favorite and recent items alongside current folder results; debug XCTest 10k-entry plus 3k-shortcut resolver guard ran in 0.108s.

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

- commit: pending
- branch: `main`
- dirty tree: `true`
- status: `0`
- generated folder listing: entries `1010`, avg `4.644 ms`, max `5.740 ms`
- Rust FFI static library: `17682728 bytes`
- macOS app bundle: `2404 KiB`
- notes: Added NSTextView-based lightweight text highlighting. Regex patterns are cached, incremental edits re-highlight the edited paragraph, and full-document highlighting keeps a 200k UTF-16-unit guard for large files.

## 2026-05-24T13:35:42Z lazy-listing-metadata

- commit: pending
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
