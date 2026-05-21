import AppKit
import Foundation

struct FinderService: Sendable {
    @discardableResult
    @MainActor
    func openExternally(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    @MainActor
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
