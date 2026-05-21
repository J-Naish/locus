import AppKit
import Foundation
import OSLog

struct FinderService: Sendable {
    private static let logger = Logger(subsystem: "Locus", category: "FinderService")

    @discardableResult
    @MainActor
    func openExternally(_ url: URL) -> Bool {
        let didOpen = NSWorkspace.shared.open(url)
        if !didOpen {
            Self.logger.error("Failed to open file externally: \(url.path(percentEncoded: false))")
        }
        return didOpen
    }

    @MainActor
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
