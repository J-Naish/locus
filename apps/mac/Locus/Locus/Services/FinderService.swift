import AppKit
import Foundation
import OSLog

protocol FinderServicing {
    @discardableResult
    @MainActor
    func openExternally(_ url: URL) -> Bool

    @MainActor
    func reveal(_ url: URL)
}

struct FinderService: FinderServicing, Sendable {
    private static let logger = Logger(subsystem: "Locus", category: "FinderService")

    /// Returns whether macOS accepted the request to open the URL, not whether
    /// the receiving app ultimately displayed it successfully.
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

#if DEBUG
struct UITestFinderService: FinderServicing {
    private let revealInvocationsKey: String
    private let revealInvocationsFileURL: URL?
    private let userDefaults: UserDefaults

    init(
        revealInvocationsKey: String,
        revealInvocationsFileURL: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.revealInvocationsKey = revealInvocationsKey
        self.revealInvocationsFileURL = revealInvocationsFileURL
        self.userDefaults = userDefaults
    }

    @discardableResult
    @MainActor
    func openExternally(_ url: URL) -> Bool {
        true
    }

    @MainActor
    func reveal(_ url: URL) {
        let path = url.locusStandardizedPath
        userDefaults.set([path], forKey: revealInvocationsKey)
        userDefaults.synchronize()
        if let revealInvocationsFileURL {
            try? path.write(to: revealInvocationsFileURL, atomically: true, encoding: .utf8)
        }
    }
}
#endif
