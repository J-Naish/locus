# Performance Budget

Locus treats speed and weight regressions as product bugs. These budgets are smoke-test thresholds, not final UX targets.

## Current Smoke Budgets

Run from the repository root:

```sh
scripts/perf-smoke.sh
```

Default budgets:

- immediate folder listing over the generated 1,000-file workspace: average <= 50 ms
- immediate folder listing spike limit: max <= 150 ms
- symlink-heavy folder listing over the generated 200-symlink workspace: average <= 50 ms
- symlink-heavy folder listing spike limit: max <= 150 ms
- text buffer 256 KiB smoke: open <= 50 ms, scroll <= 20 ms, edit <= 50 ms
- release Rust FFI static library: <= 25,000,000 bytes
- release macOS app bundle: <= 10,240 KiB

The default workspace is generated under `target/perf-fixtures/listing-1000`
by `scripts/generate-performance-fixtures.sh`. Set
`LOCUS_PERF_ENTRY_COUNT` to scale the generated top-level file count or
`LOCUS_PERF_WORKSPACE` to measure a specific existing folder. The symlink-heavy
workspace is regenerated under `target/perf-fixtures/symlink-listing-200`.
Set `LOCUS_PERF_BUFFER_SIZE_BYTES` to scale the text-buffer smoke input.

## Baseline

Local baseline captured on 2026-06-10:

- generated workspace: 1,010 visible entries, average 3.104 ms, max 4.067 ms
- symlink-heavy workspace: 200 visible entries, average 1.041 ms, max 1.082 ms
- text buffer @256 KiB: open 0.195 ms, scroll 0.005 ms, edit 0.032 ms
- `core/target/release/libapp_ffi.a`: 17,805,224 bytes
- `.build/xcode-derived/Build/Products/Release/Locus.app`: 5,988 KiB

The defaults leave headroom for CI variance and near-term features while still
catching obvious dependency, bundle, folder-listing, and text-buffer regressions.

## Recording Implementation Impact

Use `scripts/perf-record.sh` when a change should leave an auditable
performance trail. It runs the same smoke check, writes raw JSONL and complete
command output under `target/perf-runs/`, and can append a compact note to
`docs/performance/perf-log.md`:

```sh
scripts/perf-record.sh --label feature-name --notes "What changed"
scripts/perf-record.sh --label feature-name --append-summary
```

Keep raw run files out of git. Commit only curated notes that explain meaningful
changes, regressions, or baseline updates.

## Exit Codes

- `0`: all budgets passed
- `1`: command ran, but a performance or size budget failed
- `2`: invalid CLI or script usage
