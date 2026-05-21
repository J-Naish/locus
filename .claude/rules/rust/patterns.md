---
paths:
  - "**/*.rs"
---
# Rust Patterns

> This file extends [patterns.md](../patterns.md) with Rust-specific content.

## Persistence Boundary with Traits

Use this when there is real data-source complexity or multiple implementations. Encapsulate data access behind a trait:

```rust
pub trait WorkspaceStore: Send + Sync {
    fn recent_workspaces(&self) -> Result<Vec<WorkspaceLocation>, StorageError>;
    fn save_recent_workspace(&self, location: &WorkspaceLocation) -> Result<(), StorageError>;
    fn remove_recent_workspace(&self, id: WorkspaceLocationId) -> Result<(), StorageError>;
}
```

Concrete implementations handle storage details (SQLite, filesystem fixtures, or in-memory tests).
Do not introduce a repository abstraction for a simple one-off local file operation.

## Service Layer

Use service structs when business logic has meaningful dependencies. Inject dependencies via constructor:

```rust
pub struct WorkspaceService {
    store: Box<dyn WorkspaceStore>,
}

impl WorkspaceService {
    pub fn new(store: Box<dyn WorkspaceStore>) -> Self {
        Self { store }
    }

    pub fn remember_workspace(&self, location: WorkspaceLocation) -> Result<(), StorageError> {
        self.store.save_recent_workspace(&location)
    }
}
```

## Newtype Pattern for Type Safety

Prevent argument mix-ups with distinct wrapper types:

```rust
struct WorkspaceLocationId(u64);
struct Generation(u64);

fn should_apply_snapshot(current: Generation, snapshot: Generation) -> bool {
    current.0 == snapshot.0
}
```

## Enum State Machines

Model states as enums — make illegal states unrepresentable:

```rust
enum ConnectionState {
    Idle,
    Loading { path: PathBuf },
    Ready { path: PathBuf, entries: Vec<WorkspaceEntry> },
    Failed { path: PathBuf, reason: String },
}

fn handle(state: &ConnectionState) {
    match state {
        ConnectionState::Idle => show_empty_state(),
        ConnectionState::Loading { path } => show_loading(path),
        ConnectionState::Ready { path, entries } => show_entries(path, entries),
        ConnectionState::Failed { path, reason } => show_error(path, reason),
    }
}
```

Always match exhaustively — no wildcard `_` for business-critical enums.

## Builder Pattern

Use for structs with many optional parameters:

```rust
pub struct WorkspaceScanConfig {
    root: PathBuf,
    include_ignored: bool,
    max_entries: usize,
}

impl WorkspaceScanConfig {
    pub fn builder(root: impl Into<PathBuf>) -> WorkspaceScanConfigBuilder {
        WorkspaceScanConfigBuilder {
            root: root.into(),
            include_ignored: false,
            max_entries: 10_000,
        }
    }
}

pub struct WorkspaceScanConfigBuilder {
    root: PathBuf,
    include_ignored: bool,
    max_entries: usize,
}

impl WorkspaceScanConfigBuilder {
    pub fn include_ignored(mut self, value: bool) -> Self {
        self.include_ignored = value;
        self
    }

    pub fn build(self) -> WorkspaceScanConfig {
        WorkspaceScanConfig {
            root: self.root,
            include_ignored: self.include_ignored,
            max_entries: self.max_entries,
        }
    }
}
```

## Sealed Traits for Extensibility Control

Use a private module to seal a trait, preventing external implementations:

```rust
mod private {
    pub trait Sealed {}
}

pub trait Format: private::Sealed {
    fn label(&self) -> &'static str;
}

pub struct Markdown;
impl private::Sealed for Markdown {}
impl Format for Markdown {
    fn label(&self) -> &'static str { "Markdown" }
}
```

## References

See skill: `rust-patterns` for comprehensive patterns including ownership, traits, generics, concurrency, and async.
