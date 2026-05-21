# docs/AGENTS.md

Rules for product, architecture, specs, ADRs, and other documentation.

## Documentation Scope

- Keep docs concise and split by stable topic.
- Document important implementation and application knowledge by default:
  - architecture decisions
  - feature behavior
  - platform constraints
  - performance budgets
  - persistence formats
  - FFI contracts
  - build and release flows
  - non-obvious tradeoffs
- Update docs when scope, architecture, or product principles change.
- Add ADRs in `docs/adr/` for important architectural decisions.
- Avoid duplicating the same requirement across many files; link to the source document instead.

## Product Docs

- Use plain language for business users and product collaborators.
- Keep Locus positioned as a lightweight local document workspace, not an IDE, AI chat app, agent runtime, Office suite, Acrobat replacement, or plugin platform.
- Prefer concrete user flows, constraints, and acceptance criteria over broad aspirations.
- Preserve Finder-like and Preview-like product language.

## Architecture Docs

- Record why a platform, persistence, FFI, or performance decision was made.
- State constraints and tradeoffs clearly.
- Keep architecture docs aligned with `core/AGENTS.md` and `apps/mac/AGENTS.md`.
- If implementation diverges from documented direction, update docs or call out the divergence.

## Documentation Testing

- Treat broken commands, stale file paths, and obsolete requirements as documentation bugs.
- When docs mention commands, verify them when practical.
- When docs describe behavior, make sure corresponding automated tests or manual review paths are clear.
