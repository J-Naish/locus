---
paths:
  - "**/*.rs"
---
# Rust Testing

> This file extends [testing.md](../testing.md) with Rust-specific content.

## Test Framework

- **`#[test]`** with `#[cfg(test)]` modules for unit tests
- **rstest** for parameterized tests and fixtures
- **proptest** for property-based testing
- **mockall** for trait-based mocking
- **`#[tokio::test]`** for async tests

## Test Organization

```text
my_crate/
├── src/
│   ├── lib.rs           # Unit tests in #[cfg(test)] modules
│   ├── workspace/
│   │   └── mod.rs       # #[cfg(test)] mod tests { ... }
│   └── file_type/
│       └── service.rs   # #[cfg(test)] mod tests { ... }
├── tests/               # Integration tests (each file = separate binary)
│   ├── workspace_listing_test.rs
│   ├── ffi_test.rs
│   └── common/          # Shared test utilities
│       └── mod.rs
└── benches/             # Criterion benchmarks
    └── benchmark.rs
```

Unit tests go inside `#[cfg(test)]` modules in the same file. Integration tests go in `tests/`.

## Unit Test Pattern

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classifies_markdown_file_from_extension() {
        let file_type = classify_path(Path::new("notes.md"));
        assert_eq!(file_type, FileType::Markdown);
    }

    #[test]
    fn returns_partial_error_when_child_metadata_fails() {
        let result = list_workspace_with_blocked_child();
        assert_eq!(result.partial_errors.len(), 1);
    }
}
```

## Parameterized Tests

```rust
use rstest::rstest;

#[rstest]
#[case("hello", 5)]
#[case("", 0)]
#[case("rust", 4)]
fn test_string_length(#[case] input: &str, #[case] expected: usize) {
    assert_eq!(input.len(), expected);
}
```

## Async Tests

```rust
#[tokio::test]
async fn loads_workspace_snapshot_successfully() {
    let workspace = TestWorkspace::new().await;
    let result = workspace.load_snapshot().await;
    assert!(result.is_ok());
}
```

## Mocking with mockall

Define traits in production code; generate mocks in test modules:

```rust
// Production trait — pub so integration tests can import it
pub trait WorkspaceStore {
    fn recent_workspaces(&self) -> Vec<WorkspaceLocation>;
}

#[cfg(test)]
mod tests {
    use super::*;
    use mockall::predicate::eq;

    mockall::mock! {
        pub Repo {}
        impl WorkspaceStore for Repo {
            fn recent_workspaces(&self) -> Vec<WorkspaceLocation>;
        }
    }

    #[test]
    fn service_returns_recent_workspaces() {
        let mut mock = MockRepo::new();
        mock.expect_recent_workspaces()
            .times(1)
            .returning(|| vec![WorkspaceLocation::new("/tmp/project")]);

        let service = WorkspaceService::new(Box::new(mock));
        assert_eq!(service.recent_workspaces().len(), 1);
    }
}
```

## Test Naming

Use descriptive names that explain the scenario:
- `sorts_folders_before_files()`
- `returns_partial_error_when_child_metadata_fails()`
- `rejects_file_path_when_folder_required()`

## Coverage

- Target 80%+ line coverage
- Use **cargo-llvm-cov** for coverage reporting
- Focus on business logic — exclude generated code and FFI bindings

```bash
cargo llvm-cov                       # Summary
cargo llvm-cov --html                # HTML report
cargo llvm-cov --fail-under-lines 80 # Fail if below threshold
```

## Testing Commands

```bash
cargo test                       # Run all tests
cargo test -- --nocapture        # Show println output
cargo test test_name             # Run tests matching pattern
cargo test --lib                 # Unit tests only
cargo test --test ffi_test       # Specific integration test (tests/ffi_test.rs)
cargo test --doc                 # Doc tests only
```

## References

See skill: `rust-testing` for comprehensive testing patterns including property-based testing, fixtures, and benchmarking with Criterion.
