import AppKit
import OSLog

struct ClipboardService: Sendable {
  private static let logger = Logger(subsystem: "Locus", category: "ClipboardService")

  @discardableResult
  @MainActor
  func copyEntryPaths(_ entries: [WorkspaceEntry]) -> Bool {
    guard let text = WorkspaceEntryPathCopy.pasteboardString(for: entries) else {
      return false
    }

    return copyPlainText(text)
  }

  @discardableResult
  @MainActor
  func copyPlainText(_ text: String) -> Bool {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    let didCopy = pasteboard.setString(text, forType: .string)
    if !didCopy {
      Self.logger.error("Failed to write plain text to pasteboard.")
    }
    return didCopy
  }
}
