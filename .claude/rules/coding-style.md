# Coding Style

## Immutability (CRITICAL)

Prefer immutable data and explicit replacement over hidden mutation:

```
// Pseudocode
PREFER: update(original, field, value) → returns new copy with change
AVOID:  modify(original, field, value) → changes shared state in-place
```

Rationale: Immutable data prevents hidden side effects, makes debugging easier, and enables safe concurrency.

Mutation is allowed when it is local, explicit, and simpler:
- Local accumulators, builders, buffers, and tight loops
- UI state managed by the platform framework
- Rust ownership patterns where `mut` is scoped and obvious
- Performance-sensitive code where allocation would be wasteful

## Core Principles

### KISS (Keep It Simple)

- Prefer the simplest solution that actually works
- Avoid premature optimization
- Optimize for clarity over cleverness

### DRY (Don't Repeat Yourself)

- Extract repeated logic into shared functions or utilities
- Avoid copy-paste implementation drift
- Introduce abstractions when repetition is real, not speculative

### YAGNI (You Aren't Gonna Need It)

- Do not build features or abstractions before they are needed
- Avoid speculative generality
- Start simple, then refactor when the pressure is real

## File Organization

MANY SMALL FILES > FEW LARGE FILES:
- High cohesion, low coupling
- 200-400 lines typical, 800 max
- Extract utilities from large modules
- Organize by feature/domain, not by type
- Do not split cohesive native UI views or Rust modules just to satisfy a line count

## Error Handling

ALWAYS handle errors comprehensively:
- Handle errors explicitly at every level
- Provide user-friendly error messages in UI-facing code
- Log detailed diagnostic context at system and integration boundaries
- Never silently swallow errors

## Input Validation

ALWAYS validate at system boundaries:
- Validate all user input before processing
- Use schema-based validation where available
- Fail fast with clear error messages
- Never trust external data, user-selected files, file content, metadata, or tool output

## Naming Conventions

- Follow the language-specific naming rules for the file being edited
- Booleans: prefer `is`, `has`, `should`, or `can` prefixes
- Types and components: use the language's type naming convention
- Constants: use the language's constant naming convention
- Avoid abbreviations unless they are standard in the domain

## Code Smells to Avoid

### Deep Nesting

Prefer early returns over nested conditionals once the logic starts stacking.

### Magic Numbers

Use named constants for meaningful thresholds, delays, and limits.

### Long Functions

Split large functions into focused pieces with clear responsibilities.

## Code Quality Checklist

Before marking work complete:
- [ ] Code is readable and well-named
- [ ] Functions are small (<50 lines)
- [ ] Files are focused (<800 lines)
- [ ] No deep nesting (>4 levels)
- [ ] Proper error handling
- [ ] No hardcoded values (use constants or config)
- [ ] No hidden shared mutation; immutable patterns used where practical
