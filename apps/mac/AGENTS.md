# apps/mac/AGENTS.md

Rules for the native macOS app, Swift, SwiftUI, CoreBridge, and Xcode project work.

## Scope

- Build a native macOS UI shell.
- Keep raw C/FFI calls inside the bridge layer; do not spread them through SwiftUI views.
- Keep UI-specific behavior in Swift unless it is truly cross-platform domain logic.
- Use native OS capabilities for preview, file handoff, file dialogs, metadata, and logging where practical.

## Xcode Commands

Use the macOS destination explicitly:

```sh
xcodebuild test -project apps/mac/Locus/Locus.xcodeproj -scheme Locus -destination 'platform=macOS,arch=arm64'
xcodebuild -project apps/mac/Locus/Locus.xcodeproj -scheme Locus -destination 'platform=macOS,arch=arm64' build
```

Before handoff for changes that affect speed, size, startup, file listing, FFI, or the app bundle, also run:

```sh
scripts/perf-smoke.sh
```

## Swift Style

- Follow Apple API Design Guidelines.
- Prefer `let` over `var`; use `var` only when mutation is required and clear.
- Use `struct` and value semantics by default; use `class` only when identity or reference semantics are needed.
- Prefer `Sendable` value types for data crossing isolation boundaries.
- Keep UI updates on the main actor.
- Prefer structured concurrency (`async let`, `TaskGroup`) over unstructured `Task {}`.
- Avoid force unwrap, force try, and force cast in production code.
- Use the project's existing formatter and lint setup; add SwiftFormat or SwiftLint only when explicitly adopted.

## SwiftUI and macOS UX

- Favor Finder-like and Preview-like behavior over developer-tool behavior.
- Use plain user-facing language: folders, locations, recent items, favorites.
- Keep advanced concepts internal unless users genuinely need them.
- Prefer native controls and OS facilities.
- Make file changes explicit and predictable.
- Do not hide file formats behind abstractions that make users unsure what will be saved.
- Markdown editing should feel document-like, not code-like.
- Early UI implementation should prioritize coherent product flows over polishing every visual detail in isolation.
- Explain the intended user flow before starting a substantial new UI surface, but avoid blocking implementation on micro-level visual decisions unless the choice would be hard to reverse.
- Once meaningful UI functionality is in place, shift into a deliberate polish pass with the user on the actual Mac.
- When UI changes are made or a new UI slice is complete, explain what changed, how to run it, and what should be checked.
- Automated tests and local builds catch functional regressions, but user review on the actual Mac is the acceptance path for visual quality, interaction feel, responsiveness, and native polish.

## CoreBridge and File Access

- Keep CoreBridge thin and explicit.
- Copy borrowed FFI values into Swift-owned values before freeing Rust snapshots.
- Log unknown FFI status, kind, and type values so ABI drift is visible in release builds.
- Validate user-selected URLs before handing them to Rust or persistence.
- Use `URL(filePath:)` or validated file URLs rather than force-unwrapping URL strings.
- Use security-scoped bookmarks for sandboxed persistent folder access when persistence is introduced.
- Start and stop security-scoped access in a balanced scope.
- Treat file metadata, file contents, drag/drop data, file importer results, and pasteboard data as untrusted input.
- Prefer native file presenters, preview, and handoff APIs where possible.

## Swift Patterns

- Define small focused protocols only when they improve substitution, testing, or platform boundaries.
- Prefer concrete types when abstraction adds no value.
- Inject dependencies with default parameters where it improves testability.
- Use enums with associated values to model UI and loading states.
- Use actors for shared mutable state instead of locks or dispatch queues when shared mutation appears.

## Swift Testing

- New tests should use the repository's active test framework unless deliberately migrating.
- Use Swift Testing (`import Testing`) for new test surfaces only when the project has adopted it for that area; otherwise follow the existing XCTest pattern.
- Each test must be isolated and avoid shared mutable state.
- Add tests before implementation for subtle, risky, or unclear behavior.
- Cover edge cases:
  - folder importer cancellation
  - refresh generation/race handling
  - selected entry preservation
  - CoreBridge status and ABI layout
  - empty/loading/error states where testable
  - file handoff and open/reveal failure handling where testable
- Target at least 80% coverage for view-independent logic and bridge behavior.
