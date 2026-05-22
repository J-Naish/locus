import Foundation
import OSLog
// Quick Look's AppKit-facing APIs are not fully annotated for Swift concurrency yet.
@preconcurrency import Quartz

@MainActor
protocol QuickLookPreviewing: AnyObject {
    @discardableResult
    func preview(_ urls: [URL]) -> Bool
}

@MainActor
final class QuickLookPreviewService: NSObject, QuickLookPreviewing {
    private static let logger = Logger(subsystem: "Locus", category: "QuickLookPreviewService")

    private var items: [QuickLookPreviewItem] = []

    @discardableResult
    func preview(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else {
            return false
        }

        items = urls.map { QuickLookPreviewItem(url: $0) }

        guard let panel = QLPreviewPanel.shared() else {
            Self.logger.error("Quick Look preview panel is unavailable.")
            return false
        }

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        return true
    }
}

extension QuickLookPreviewService: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        // QLPreviewPanel invokes its data source and delegate on the main thread.
        MainActor.assumeIsolated {
            items.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // QLPreviewPanel invokes its data source and delegate on the main thread.
        MainActor.assumeIsolated {
            guard items.indices.contains(index) else {
                return nil
            }

            return items[index]
        }
    }

    nonisolated func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        // QLPreviewPanel invokes its data source and delegate on the main thread.
        MainActor.assumeIsolated {
            items = []
        }
    }
}

private final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL) {
        self.previewItemURL = url
        self.previewItemTitle = url.lastPathComponent
    }
}

#if DEBUG
@MainActor
final class UITestQuickLookPreviewService: QuickLookPreviewing {
    private let key: String
    private let fileURL: URL?
    private let userDefaults: UserDefaults

    init(key: String, fileURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        self.key = key
        self.fileURL = fileURL
        self.userDefaults = userDefaults
    }

    @discardableResult
    func preview(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else {
            return false
        }

        let paths = urls.map(\.locusStandardizedPath)
        userDefaults.set(paths, forKey: key)
        userDefaults.synchronize()
        if let fileURL {
            try? paths.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return true
    }
}
#endif
