# Performance Tracking

Locus uses two kinds of performance checks:

- `scripts/perf-smoke.sh` is the budget gate. It should stay stable and fail when a change exceeds the current smoke budgets.
- `scripts/perf-record.sh` is the history tool. It records the same smoke measurements with git and machine metadata so implementation changes can be compared over time.

## Recording A Run

Run from the repository root:

```sh
scripts/perf-record.sh --label home-search --notes "After adding shortcut search"
```

Raw run data is written under `target/perf-runs/` by default:

- `perf-records.jsonl` stores one JSON object per run.
- `*.log` stores the complete `perf-smoke` output for that run.

These raw logs are machine-local and are not committed because local performance numbers vary with hardware, system load, Xcode state, and filesystem cache state.

## Curated Log

When a result explains a meaningful product or implementation change, append a human-readable summary:

```sh
scripts/perf-record.sh \
  --label home-search \
  --notes "Shortcut search did not affect folder listing; app bundle changed by a few KiB." \
  --append-summary
```

Curated notes go in `docs/performance/perf-log.md`. Keep entries short and focused on what changed, which scenario was measured, and whether the result changes future implementation choices.

## Comparing Changes

For implementation work where performance impact matters, prefer a before/after pair:

```sh
scripts/perf-record.sh --label before-feature
# implement the feature
scripts/perf-record.sh --label after-feature --append-summary
```

Use repeated runs when a number looks suspicious. Treat large or persistent regressions as product bugs, then decide whether to optimize, defer the feature, or update the budget with an explicit reason.
