# 0002. Use Security-Scoped Bookmarks for Persistent macOS Folder Access

## Status

Accepted

## Context

Locus lets users open local folders and will later remember recent folders and favorites. The macOS app is not sandboxed yet, but distribution will require a clear sandbox and file-access model.

SwiftUI `fileImporter` returns user-selected URLs that can be accessed immediately with `startAccessingSecurityScopedResource()`. That is enough for the current folder-list flow, but it is not enough for persistent recents, favorites, and later editor sessions after relaunch.

## Decision

Use two levels of access:

- Immediate folder reads call `startAccessingSecurityScopedResource()` before touching a user-selected URL and stop access with `defer`.
- Persistent folder access stores security-scoped bookmark data when recents and favorites are implemented.
- Stored bookmarks are resolved before later folder reads, previews, edits, reveal actions, or external handoff flows that need access after the original picker session.
- The app should enable App Sandbox and entitlements before relying on recents and favorites as product features.

## Consequences

Milestone 2 can keep the implementation small while still following the correct access pattern for selected folders.

Milestone 3 must introduce bookmark persistence alongside recents and favorites rather than storing raw path strings as the source of truth for user-granted folder access.
