---
paths:
  - "**/*.swift"
  - "**/Package.swift"
---
# Swift Patterns

> This file extends [patterns.md](../patterns.md) with Swift specific content.

## Protocol-Oriented Design

Define small, focused protocols when they improve substitution, testing, or platform boundaries. Use protocol extensions for shared defaults:

```swift
protocol Repository: Sendable {
    associatedtype Item: Identifiable & Sendable
    func find(by id: Item.ID) async throws -> Item?
    func save(_ item: Item) async throws
}
```

## Value Types

- Use structs for data transfer objects and models
- Use enums with associated values to model distinct states:

```swift
enum LoadState<T: Sendable>: Sendable {
    case idle
    case loading
    case loaded(T)
    case failed(Error)
}
```

## Actor Pattern

Use actors for shared mutable state instead of locks or dispatch queues:

```swift
actor Cache<Key: Hashable & Sendable, Value: Sendable> {
    private var storage: [Key: Value] = [:]

    func get(_ key: Key) -> Value? { storage[key] }
    func set(_ key: Key, value: Value) { storage[key] = value }
}
```

## Dependency Injection

Inject dependencies with default parameters where it improves testability. Prefer concrete types when abstraction adds no value:

```swift
struct WorkspaceOpener {
    private let finderService: FinderService

    init(finderService: FinderService = FinderService()) {
        self.finderService = finderService
    }
}
```

## References

See skill: `swift-actor-persistence` for actor-based persistence patterns.
See skill: `swift-protocol-di-testing` for protocol-based DI and testing.
