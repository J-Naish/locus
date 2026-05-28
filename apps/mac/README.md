# macOS App

The macOS app is the first product target.

Expected stack:

- Swift
- AppKit
- SwiftUI
- TextKit 2 / NSTextView
- PDFKit
- Quick Look
- AVKit

The app should call the shared Rust core through a thin Swift bridge rather than using the C ABI directly across the UI layer.

## Current Prototype

The macOS app lives at `apps/mac/Locus/`.

It contains:

- `Locus.xcodeproj`: app and unit test targets.
- `Locus/CoreBridge`: Swift wrapper around the Rust C ABI.
- `Locus/Views/Home`: current folder browsing, inline folder expansion, Git change coloring in the sidebar, inline sidebar file/folder creation, recent locations, search ranking support, preview routing, text editing with native line-number gutters for editable text formats, and open-document change sync.
- `Locus/Services`: text/image/PDF/media/Quick Look document loading, including extensionless text candidates, recents and bookmark storage, path copying, file dialog helpers, and file-system monitoring boundaries.

The Xcode target builds the Rust `app-ffi` static library before linking the app.
Debug builds link `core/target/debug/libapp_ffi.a`; Release builds link `core/target/release/libapp_ffi.a`.
The Rust build is routed through `scripts/build-rust-ffi.sh`.

The default launch opens the user's home folder when available, but the initial
home folder is not recorded as a recent location. UI tests use launch arguments
such as `--ui-test-workspace`, `--ui-test-recent-file`, and
`--ui-test-recent-folder` to avoid system file dialogs and shared recents state.

Useful commands from the repository root:

```sh
scripts/mac/run-app.sh
xcodebuild -project apps/mac/Locus/Locus.xcodeproj -scheme Locus -configuration Debug -derivedDataPath .build/xcode-derived -destination 'platform=macOS' build
xcodebuild -project apps/mac/Locus/Locus.xcodeproj -scheme Locus -configuration Debug -derivedDataPath .build/xcode-derived -destination 'platform=macOS' test
```
