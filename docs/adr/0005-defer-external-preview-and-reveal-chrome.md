# 0005. Defer External Preview and Reveal Chrome

## Status

Accepted

## Context

The prototype should stay close to native SwiftUI and AppKit behavior while proving the core local-document loop: browse a folder, open supported files in place, preview common formats inside Locus, and lightly edit text documents. Earlier slices added extra handoff affordances around that loop: a Quick Look panel service, Space-key quick preview, `Preview` context-menu actions, and explicit "show in Locus" actions.

Those controls increased state, event monitoring, UI test plumbing, and menu surface area before there was a concrete prototype workflow that needed them.

## Decision

Remove external preview and explicit reveal chrome from the prototype.

- Keep in-app document surfaces for text, image, PDF, media, and Office files rendered through native frameworks.
- Keep file and shortcut context menus minimal: `Open`, `Copy Path`, and `Remove` where applicable.
- Remove the Quick Look panel service, Space-key preview monitor, `Preview` menu items, explicit "show in Locus" menu items, and unsupported-file preview fallback buttons.
- Treat unsupported files as quiet fallback surfaces with path copying available from the file list.

## Consequences

The browser and document surface have less custom chrome and less event plumbing. Unsupported files are intentionally not opened through an external fallback in the prototype; users can copy paths while richer handoff behavior is deferred.

Future work can reintroduce OS-standard handoff commands, such as Finder reveal or Quick Look panel preview, when a specific workflow justifies the extra menu surface and tests.
