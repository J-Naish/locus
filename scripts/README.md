# Scripts

Development and release automation lives here.

Keep scripts grouped by platform or responsibility:

- `mac/`
- `windows/`
- `rust/`
- `release/`

## Performance Smoke

Run the lightweight performance and size budget checks from the repository root:

```sh
scripts/perf-smoke.sh
```

The smoke check builds the Rust core in release mode, measures immediate folder listing over a generated mixed-file workspace, checks the Rust FFI static library size, builds the macOS app in release mode, and checks the app bundle size.

Budget defaults and current baselines are documented in `docs/specs/performance-budget.md`.

Useful environment overrides:

```sh
LOCUS_PERF_ENTRY_COUNT=5000 scripts/perf-smoke.sh
LOCUS_PERF_LIST_BUDGET_MS=200 scripts/perf-smoke.sh
LOCUS_PERF_LIST_MAX_BUDGET_MS=500 scripts/perf-smoke.sh
LOCUS_PERF_SKIP_MAC_BUILD=1 scripts/perf-smoke.sh
```

## Performance Records

Use `perf-record.sh` when you want to keep a local history for a specific
implementation change:

```sh
scripts/perf-record.sh --label home-search --notes "After adding shortcut search"
```

The record script forwards all `LOCUS_PERF_*` overrides accepted by
`perf-smoke.sh`, stores raw JSONL and full command output in `target/perf-runs/`,
and can append a curated note to `docs/performance/perf-log.md`:

```sh
scripts/perf-record.sh --label home-search --append-summary
```
