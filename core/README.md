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
