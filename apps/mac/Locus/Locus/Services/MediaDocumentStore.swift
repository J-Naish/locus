import AVFoundation
import Foundation

struct MediaDocument: @unchecked Sendable {
    let player: AVPlayer
    private let securityScopedAccess: SecurityScopedMediaAccess?

    init(player: AVPlayer, securityScopedAccess: SecurityScopedMediaAccess?) {
        self.player = player
        self.securityScopedAccess = securityScopedAccess
    }
}

protocol MediaDocumentStoring: Sendable {
    func loadMedia(at url: URL) async throws -> MediaDocument
}

struct MediaDocumentStore: MediaDocumentStoring {
    func loadMedia(at url: URL) async throws -> MediaDocument {
        let task = Task.detached(priority: .userInitiated) {
            let access = SecurityScopedMediaAccess(url: url)

            try Task.checkCancellation()

            let asset = AVURLAsset(url: url)
            guard try await asset.load(.isPlayable) else {
                throw MediaDocumentStoreError.cannotOpen
            }

            try Task.checkCancellation()

            let playerItem = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: playerItem)
            return MediaDocument(
                player: player,
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

enum MediaDocumentStoreError: LocalizedError, Equatable {
    case cannotOpen

    var errorDescription: String? {
        "This media file could not be opened."
    }
}

final class SecurityScopedMediaAccess: @unchecked Sendable {
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
