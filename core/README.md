# Core

Shared Rust code lives here.

The core owns heavier cross-platform behavior:

- file scanning
- lightweight file metadata needed for listing and routing
- hashing
- diffing
- search indexes
- SQLite access
- cache management
- workspace state

UI-specific behavior belongs in the native app folders.

Folder listing should stay shallow and fast. The default snapshot includes the
entry name, path, kind, file type, and readonly state; richer values such as
size and modified time should be requested or loaded only when a contextual
surface needs them.

This policy primarily keeps the snapshot contract and Swift-side conversion
costs lean. The current implementation still performs per-entry metadata reads
for kind and readonly state; reducing those syscalls is a separate optimization.
Symbolic links are the main exception to the shallow fast path: listing resolves
the immediate target once so the UI can treat directory links like folders and
file links like files.

## Performance Smoke

`app-cli` includes a small release-mode folder listing smoke command:

```sh
cargo run --manifest-path core/Cargo.toml -p app-cli --release -- \
  perf-list-directory /path/to/folder --iterations 5 --budget-ms 50 --max-budget-ms 150
```

Use `scripts/perf-smoke.sh` from the repository root for the full lightweight check that also enforces Rust static library and macOS app bundle size budgets.

Budget defaults and current baselines are documented in `docs/specs/performance-budget.md`.
