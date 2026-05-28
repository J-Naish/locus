import AppKit

enum NativeSidebarToggle {
  @MainActor
  static func toggle() {
    _ = NSApp.sendAction(
      #selector(NSSplitViewController.toggleSidebar(_:)),
      to: nil,
      from: nil
    )
  }
}
