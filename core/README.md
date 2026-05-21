# Core

Shared Rust code lives here.

The core owns heavier cross-platform behavior:

- file scanning
- file metadata
- hashing
- diffing
- search indexes
- SQLite access
- cache management
- workspace state

UI-specific behavior belongs in the native app folders.

## Performance Smoke

`app-cli` includes a small release-mode folder listing smoke command:

```sh
cargo run --manifest-path core/Cargo.toml -p app-cli --release -- \
  perf-list-directory /path/to/folder --iterations 5 --budget-ms 50 --max-budget-ms 150
```

Use `scripts/perf-smoke.sh` from the repository root for the full lightweight check that also enforces Rust static library and macOS app bundle size budgets.

Budget defaults and current baselines are documented in `docs/specs/performance-budget.md`.
