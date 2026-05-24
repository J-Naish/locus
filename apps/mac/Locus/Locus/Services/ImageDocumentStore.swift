import AppKit
import Foundation
import ImageIO

struct ImageDocument: @unchecked Sendable {
  let image: NSImage
}

protocol ImageDocumentStoring: Sendable {
  func loadImage(at url: URL) async throws -> ImageDocument
}

struct ImageDocumentStore: ImageDocumentStoring {
  func loadImage(at url: URL) async throws -> ImageDocument {
    let task = Task.detached(priority: .userInitiated) {
      let didStartAccess = url.startAccessingSecurityScopedResource()
      defer {
        if didStartAccess {
          url.stopAccessingSecurityScopedResource()
        }
      }

      try Task.checkCancellation()

      let sourceOptions: [CFString: Any] = [
        kCGImageSourceShouldCache: false
      ]
      guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary)
      else {
        throw ImageDocumentStoreError.cannotDecode
      }

      try Task.checkCancellation()

      let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: ImageDocumentStore.maxRenderedPixelLength,
      ]
      guard
        let cgImage = CGImageSourceCreateThumbnailAtIndex(
          source, 0, thumbnailOptions as CFDictionary)
      else {
        throw ImageDocumentStoreError.cannotDecode
      }

      let image = NSImage(
        cgImage: cgImage,
        size: CGSize(width: cgImage.width, height: cgImage.height)
      )
      return ImageDocument(image: image)
    }

    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  private static let maxRenderedPixelLength = 4096
}

enum ImageDocumentStoreError: LocalizedError {
  case cannotDecode

  var errorDescription: String? {
    "This image file could not be decoded."
  }
}
