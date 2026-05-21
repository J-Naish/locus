---
paths:
  - "**/*.rs"
---
# Rust Security

> This file extends [security.md](../security.md) with Rust-specific content.

## Secrets Management

- Never hardcode API keys, tokens, or credentials in source code
- Use environment variables, OS keychain facilities, or the project's existing secret mechanism
- Fail fast if required secrets are missing at startup
- Keep `.env` files in `.gitignore`

## SQL Injection Prevention

When SQL exists, always use parameterized queries — never format user input into SQL strings.
Use SQLite bindings or query helpers with bound parameters.

```rust
// BAD — SQL injection via format string
let query = format!("SELECT path FROM recent_workspaces WHERE path = '{path}'");
connection.prepare(&query)?;

// GOOD — parameterized query with SQLite
let mut statement = connection.prepare("SELECT path FROM recent_workspaces WHERE path = ?1")?;
let rows = statement.query_map([path], |row| row.get::<_, String>(0))?;
```

## Input Validation

- Validate all user input at system boundaries before processing
- Use the type system to enforce invariants (newtype pattern)
- Parse, don't validate — convert unstructured data to typed structs at the boundary
- Reject invalid input with clear error messages

```rust
// Parse, don't validate — invalid states are unrepresentable
pub struct WorkspacePath(PathBuf);

impl WorkspacePath {
    pub fn parse(input: PathBuf) -> Result<Self, ValidationError> {
        if !input.exists() {
            return Err(ValidationError::MissingPath(input));
        }
        if !input.is_dir() {
            return Err(ValidationError::NotDirectory(input));
        }
        Ok(Self(input))
    }

    pub fn as_path(&self) -> &Path {
        &self.0
    }
}
```

## Unsafe Code

- Minimize `unsafe` blocks — prefer safe abstractions
- Every `unsafe` block must have a `// SAFETY:` comment explaining the invariant
- Never use `unsafe` to bypass the borrow checker for convenience
- Audit all `unsafe` code during review — it is a red flag without justification
- Prefer `safe` FFI wrappers around C libraries

```rust
// GOOD — safety comment documents ALL required invariants
let widget: &Widget = {
    // SAFETY: `ptr` is non-null, aligned, points to an initialized Widget,
    // and no mutable references or mutations exist for its lifetime.
    unsafe { &*ptr }
};

// BAD — no safety justification
unsafe { &*ptr }
```

## Dependency Security

- Run `cargo audit` to scan for known CVEs in dependencies
- Run `cargo deny check` for license and advisory compliance
- Use `cargo tree` to audit transitive dependencies
- Keep dependencies updated — set up Dependabot or Renovate
- Minimize dependency count — evaluate before adding new crates, especially in native/local-first tools

```bash
# Security audit
cargo audit

# Deny advisories, duplicate versions, and restricted licenses
cargo deny check

# Inspect dependency tree
cargo tree
cargo tree -d  # Show duplicates only
```

## Error Messages

- Never expose sensitive internal paths, stack traces, database errors, or credentials in user-facing messages
- Keep user-facing messages clear and safe; preserve diagnostic detail in logs where logging exists
- Use the project's existing logging strategy; add `tracing` or `log` only when justified

```rust
// Map detailed internal errors to safe user-facing messages.
match workspace_service.list(path) {
    Ok(snapshot) => Ok(snapshot),
    Err(WorkspaceError::NotFound(_)) => Err(UserMessage::new("Folder not found")),
    Err(e) => {
        log::error!("workspace listing failed: {e}");
        Err(UserMessage::new("Folder could not be opened"))
    }
}
```

## References

See skill: `rust-patterns` for unsafe code guidelines and ownership patterns.
See skill: `security-review` for general security checklists.
