import Foundation

struct QuickLookDocument: @unchecked Sendable {
    let url: URL
    private let securityScopedAccess: SecurityScopedQuickLookAccess?

    init(url: URL, securityScopedAccess: SecurityScopedQuickLookAccess?) {
        self.url = url
        self.securityScopedAccess = securityScopedAccess
    }
}

protocol QuickLookDocumentStoring: Sendable {
    func loadQuickLookDocument(at url: URL) async throws -> QuickLookDocument
}

struct QuickLookDocumentStore: QuickLookDocumentStoring {
    func loadQuickLookDocument(at url: URL) async throws -> QuickLookDocument {
        let task = Task.detached(priority: .userInitiated) {
            let access = SecurityScopedQuickLookAccess(url: url)

            try Task.checkCancellation()

            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                throw QuickLookDocumentStoreError.cannotOpen
            }

            try Task.checkCancellation()

            return QuickLookDocument(
                url: url,
                securityScopedAccess: access.didStartAccess ? access : nil
            )
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

enum QuickLookDocumentStoreError: LocalizedError, Equatable {
    case cannotOpen

    var errorDescription: String? {
        "This file could not be opened for preview."
    }
}

final class SecurityScopedQuickLookAccess: @unchecked Sendable {
    let didStartAccess: Bool
    private let url: URL

    init(url: URL) {
        self.url = url
        self.didStartAccess = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
