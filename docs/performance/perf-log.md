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
