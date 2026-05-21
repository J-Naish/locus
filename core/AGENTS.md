# core/AGENTS.md

Rules for `core/`, including Rust crates, FFI, generated/exported headers, and core-facing fixtures.

## Scope

- Shared behavior belongs in `app-core`.
- C ABI and memory ownership boundaries belong in `app-ffi`.
- Debugging and benchmark commands belong in `app-cli`.
- UI-specific behavior does not belong in Rust unless it is truly cross-platform domain logic.

## Rust Commands

Use these commands from the repository root unless a narrower command is more appropriate:

```sh
cargo check --manifest-path core/Cargo.toml
cargo test --manifest-path core/Cargo.toml
cargo clippy --manifest-path core/Cargo.toml --all-targets --all-features -- -D warnings
```

Run formatting from `core/`:

```sh
cargo fmt --check
```

Before handoff for changes that affect speed, size, startup, file listing, FFI, or the macOS bundle, also run:

```sh
scripts/perf-smoke.sh
```

## Rust Style

- Use `let` by default; use `let mut` only when mutation is required and scoped.
- Borrow by default; take ownership only when storing or consuming values.
- Accept `&str` over `String`, `&[T]` over `Vec<T>`, and `impl AsRef<Path>` for path-like inputs where appropriate.
- Never clone just to satisfy the borrow checker without understanding the ownership issue.
- Use `Cow<'_, T>` when a function may or may not need to allocate.
- Prefer iterator chains for straightforward transformations; use loops for complex control flow and early returns.
- Keep visibility narrow: private by default, `pub(crate)` for internal sharing, `pub` only for crate or FFI-facing API.
- Match business-critical enums exhaustively; avoid wildcard matches that hide new variants.
- Use newtypes for values that can be confused, such as generation counters, workspace ids, or size budgets.

## Rust Error Handling

- Use `Result<T, E>` and `?` for fallible operations.
- Do not use `unwrap()` or `expect()` in production code paths.
- Define typed errors for library-like APIs.
- Add dependencies such as `thiserror`, `anyhow`, `tracing`, or `log` only when they fit the existing dependency and weight constraints.
- Keep user-facing messages safe; keep detailed diagnostics internal or logged when logging exists.

## FFI Rules

- Expose Rust through a C ABI and thin platform-specific bridges.
- Keep FFI calls coarse enough to avoid chatty boundaries.
- Keep memory ownership explicit: Rust-allocated memory must be released by Rust.
- C ABI structs must remain versioned and layout-tested.
- Every unsafe block must have a `// SAFETY:` comment that states the invariant.
- Never use `unsafe` to bypass the borrow checker for convenience.
- Validate nullability, encoding, ownership, and lifetimes at the boundary.
- Convert Rust strings to sanitized C strings; embedded NUL bytes must not cross the boundary unsafely.
- Platform bridges must copy borrowed FFI data into native values before freeing Rust snapshots.
- Status codes and error messages must remain stable and tested.

## Rust Security

- When SQLite code exists, use parameterized queries and bound values.
- Validate filesystem inputs at boundaries; convert unstructured paths into typed domain values where useful.
- Do not expose sensitive internal paths, stack traces, database errors, or credentials in user-facing messages.
- Minimize dependency count and audit transitive dependencies before adding new crates.

## Rust Testing

- Unit tests go in `#[cfg(test)]` modules near the code under test.
- Integration tests belong under crate-level `tests/` when behavior crosses module, persistence, fixture, or FFI boundaries.
- Add tests before implementation for subtle, risky, or unclear behavior.
- Use deterministic temporary workspaces and `fixtures/` for reusable sample files.
- Cover edge cases:
  - empty folders and files
  - missing paths and file paths where folders are required
  - unreadable children and partial errors
  - Unicode and special characters in file names
  - natural sorting and ignored OS noise
  - pre-epoch and future timestamps
  - null pointers and invalid UTF-8 at FFI boundaries
- Target at least 80% line coverage for core logic.
- Use `cargo-llvm-cov` when coverage measurement is needed.
- Do not add `rstest`, `proptest`, `mockall`, or benchmarking dependencies unless the test need justifies the weight.
