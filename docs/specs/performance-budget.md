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
- release Rust FFI static library: <= 25,000,000 bytes
- release macOS app bundle: <= 10,240 KiB

## Baseline

Local baseline captured on 2026-05-21:

- generated workspace: 1,006 visible entries, average 4.497 ms, max 5.004 ms
- `core/target/release/libapp_ffi.a`: 17,680,200 bytes
- `.build/xcode-derived/Build/Products/Release/Locus.app`: 644 KiB

The defaults leave headroom for CI variance and near-term features while still catching obvious dependency, bundle, and folder-listing regressions.

## Exit Codes

- `0`: all budgets passed
- `1`: command ran, but a performance or size budget failed
- `2`: invalid CLI or script usage
