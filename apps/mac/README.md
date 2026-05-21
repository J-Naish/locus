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
