# Testing Requirements

## Minimum Test Coverage: 80%

Test Types (ALL required):
1. **Unit Tests** - Individual functions, models, utilities, and view-independent helpers
2. **Integration Tests** - Rust core, FFI, file listing, persistence, fixtures, and platform bridge behavior
3. **E2E Tests** - Critical macOS user flows and file handoff flows where automation is practical

## Test-Driven Development

MANDATORY workflow:
1. Write test first (RED)
2. Run test - it should FAIL
3. Write minimal implementation (GREEN)
4. Run test - it should PASS
5. Refactor (IMPROVE)
6. Verify coverage (80%+)

## Troubleshooting Test Failures

1. Use **tdd-guide** agent
2. Check test isolation
3. Verify mocks are correct
4. Fix implementation, not tests (unless tests are wrong)

## Agent Support

- **tdd-guide** - Use PROACTIVELY for new features, enforces write-tests-first

## Test Structure (AAA Pattern)

Prefer Arrange-Act-Assert structure for tests:

```text
test "sorts workspace entries naturally" {
  // Arrange
  const entries = ['file10.md', 'file2.md', 'file1.md']

  // Act
  const sorted = sortWorkspaceEntries(entries)

  // Assert
  assert sorted == ['file1.md', 'file2.md', 'file10.md']
}
```

### Test Naming

Use descriptive names that explain the behavior under test:

```text
returns_empty_snapshot_when_folder_has_no_visible_entries
reports_partial_error_when_child_metadata_cannot_be_read
preserves_selected_entry_when_refresh_returns_same_file_path
```
