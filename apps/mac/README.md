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

## Current Scaffold

The initial macOS app lives at `apps/mac/Locus/`.

It contains:

- `Locus.xcodeproj`: app and unit test targets.
- `Locus/CoreBridge`: Swift wrapper around the Rust C ABI.
- `Locus/Views/Home`: minimal launch surface that verifies the Rust core link.

The Xcode target builds the Rust `app-ffi` static library before linking the app.
Debug builds link `core/target/debug/libapp_ffi.a`; Release builds link `core/target/release/libapp_ffi.a`.
The Rust build is routed through `scripts/build-rust-ffi.sh`.

Useful commands from the repository root:

```sh
xcodebuild -project apps/mac/Locus/Locus.xcodeproj -scheme Locus -configuration Debug -derivedDataPath .build/xcode-derived -destination 'platform=macOS' build
xcodebuild -project apps/mac/Locus/Locus.xcodeproj -scheme Locus -configuration Debug -derivedDataPath .build/xcode-derived -destination 'platform=macOS' test
```
