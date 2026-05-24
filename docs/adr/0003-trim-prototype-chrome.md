# 0003. Trim Prototype Chrome to Browsing and Documents

## Status

Accepted

## Context

The prototype needs to prove the core local-document loop: browse a folder, open files in place, preview supported formats, and lightly edit text documents. Favorites, always-visible search chrome, manual reload controls, and secondary metadata added UI and persistence weight before those flows were settled.

## Decision

Keep the default workspace chrome minimal for the prototype.

- Remove Favorite folder UI, storage, and tests.
- Hide search from the default toolbar while retaining the filtering and ranking code path for a later visible search flow.
- Rely on automatic directory and document monitoring instead of a manual reload control.
- Show location by folder name only; avoid absolute paths, item counts, and timestamp chrome in the main browser.

## Consequences

The prototype is quieter and easier to evaluate around browsing, previewing, and editing. Search and saved-location workflows can return later if user feedback shows they are needed, but they should come back as deliberate product flows rather than default chrome.
