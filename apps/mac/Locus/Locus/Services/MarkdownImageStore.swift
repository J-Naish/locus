import AppKit
import Foundation
import ImageIO

/// How an embedded markdown image renders right now.
enum MarkdownImageState: Equatable {
  /// The probe has not finished — the block shows a fixed-height placeholder.
  case loading
  /// Natural pixel size is known; pixels may still be decoding.
  case sized(CGSize)
  /// The source could not be resolved, fetched, or decoded.
  case failed
}

/// An NSImage held for vector sources (SVG, PDF) that ImageIO cannot decode;
/// rasterized per request. Never mutated after the probe creates it.
private struct MarkdownVectorImage: @unchecked Sendable {
  let image: NSImage
}

/// A decoded bitmap crossing back from the decode worker. CGImage is immutable.
private struct MarkdownDecodedBitmap: @unchecked Sendable {
  let image: CGImage
  /// True when the source's natural size is smaller than the requested pixel
  /// size — a larger later request cannot produce more pixels.
  let isAtNaturalLimit: Bool
}

private enum MarkdownImageProbeOutcome: Sendable {
  case bitmap(CGSize)
  case vector(MarkdownVectorImage, CGSize)
  case failure
}

/// Bounds how many remote image downloads run at once, so one document full
/// of remote sources cannot fan out unbounded concurrent transfers.
private actor MarkdownRemoteFetchGate {
  private let limit: Int
  private var active = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    self.limit = limit
  }

  func acquire() async {
    if active < limit {
      active += 1
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      active = max(0, active - 1)
    } else {
      // The slot transfers directly to the next waiter.
      waiters.removeFirst().resume()
    }
  }
}

/// Resolves, probes, and decodes images referenced from markdown documents.
///
/// Probing reads only the image header so row heights settle before any pixel
/// decode; pixels are decoded downsampled, on demand, when a block first draws.
@MainActor
final class MarkdownImageStore {
  /// The markdown document's own file URL; relative sources resolve against
  /// its parent folder.
  var baseURL: URL?
  /// Called on the main actor whenever a probe or decode finishes. The flag is
  /// true when the update can change row geometry (a size became known or a
  /// source failed) and false when only pixels arrived for an already-sized
  /// block (a redraw suffices).
  var onUpdate: ((_ geometryChanged: Bool) -> Void)?

  private var records: [String: MarkdownImageRecord] = [:]
  /// Sources with decoded pixels, least recently used first.
  private var decodedOrder: [String] = []
  private var decodedByteCount = 0
  private var inFlightTasks: [UUID: Task<Void, Never>] = [:]
  /// Bumped by reset() so completions of stale probes and decodes are ignored.
  private var generation = 0

  init(baseURL: URL? = nil) {
    self.baseURL = baseURL
  }

  /// Maps a markdown image destination to a fetchable URL. Relative paths
  /// resolve against the document folder; https stays remote; plain http and
  /// unknown schemes fail quietly (App Transport Security blocks http anyway).
  static func resolvedLocation(source: String, baseURL: URL?) -> (url: URL, isRemote: Bool)? {
    let trimmed = source.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("https://") {
      guard let url = URL(string: trimmed) else { return nil }
      return (url, true)
    }
    if lowercased.hasPrefix("file://") {
      guard let url = URL(string: trimmed), url.isFileURL else { return nil }
      return (url.standardizedFileURL, false)
    }
    guard !trimmed.contains("://") else { return nil }
    var path = trimmed.removingPercentEncoding ?? trimmed
    // Only the user's own home expands; `~otheruser` forms add attack-surface
    // breadth (documents are untrusted) for no legitimate document use —
    // and URL(filePath:) would expand them, so neutralize with "./".
    if path.hasPrefix("~/") {
      path = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst(1))
    } else if path.hasPrefix("~") {
      path = "./" + path
    }
    if path.hasPrefix("/") {
      return (URL(filePath: path).standardizedFileURL, false)
    }
    guard let baseURL else { return nil }
    let folder = baseURL.deletingLastPathComponent()
    return (URL(filePath: path, relativeTo: folder).standardizedFileURL, false)
  }

  /// The current render state for a source, starting a probe when unseen.
  func state(for source: String) -> MarkdownImageState {
    if let record = records[source] {
      return record.state
    }
    var record = MarkdownImageRecord()
    guard let location = Self.resolvedLocation(source: source, baseURL: baseURL) else {
      record.state = .failed
      records[source] = record
      return .failed
    }
    record.url = location.url
    record.isRemote = location.isRemote
    records[source] = record
    startProbe(source: source, url: location.url, isRemote: location.isRemote)
    return .loading
  }

  /// The decoded image when ready, starting a downsampled decode when needed.
  /// `maxPixelSize` caps the longer dimension in device pixels.
  func decodedImage(for source: String, maxPixelSize: CGFloat) -> CGImage? {
    guard let record = records[source], case .sized = record.state else { return nil }
    let target = max(Self.minimumDecodePixelSize, ceil(maxPixelSize))
    if let decoded = record.decoded,
      decoded.requestedPixelSize >= target || decoded.isAtNaturalLimit
    {
      markRecentlyUsed(source)
      return decoded.image
    }
    startDecode(source: source, record: record, targetPixelSize: target)
    return record.decoded?.image
  }

  /// Forgets all states and caches, e.g. when the document buffer is replaced.
  func reset() {
    generation += 1
    for task in inFlightTasks.values {
      task.cancel()
    }
    inFlightTasks.removeAll()
    records.removeAll()
    decodedOrder.removeAll()
    decodedByteCount = 0
  }

  func settleForTesting() async {
    var iterations = 0
    while let task = inFlightTasks.values.first, iterations < Self.settleIterationLimit {
      iterations += 1
      await task.value
    }
  }

  // MARK: - Probing

  private func startProbe(source: String, url: URL, isRemote: Bool) {
    let expectedGeneration = generation
    runTracked { [weak self] in
      let outcome =
        isRemote
        ? await MarkdownImageStore.probeRemote(url: url)
        : await MarkdownImageStore.probeLocal(url: url)
      guard let self, self.generation == expectedGeneration else { return }
      self.finishProbe(source: source, outcome: outcome)
    }
  }

  private func finishProbe(source: String, outcome: MarkdownImageProbeOutcome) {
    guard var record = records[source] else { return }
    switch outcome {
    case .bitmap(let pixelSize):
      record.state = .sized(pixelSize)
    case .vector(let vector, let size):
      record.vector = vector
      record.state = .sized(size)
    case .failure:
      record.state = .failed
    }
    records[source] = record
    onUpdate?(true)
  }

  private nonisolated static func probeLocal(url: URL) async -> MarkdownImageProbeOutcome {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    if let source = CGImageSourceCreateWithURL(url as CFURL, options),
      CGImageSourceGetCount(source) > 0,
      let size = headerPixelSize(of: source)
    {
      return .bitmap(size)
    }
    return vectorOutcome { NSImage(contentsOf: url) }
  }

  private nonisolated static func probeRemote(url: URL) async -> MarkdownImageProbeOutcome {
    guard let data = await fetchRemoteData(url: url) else { return .failure }
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    if let source = CGImageSourceCreateWithData(data as CFData, options),
      CGImageSourceGetCount(source) > 0,
      let size = headerPixelSize(of: source)
    {
      return .bitmap(size)
    }
    return vectorOutcome { NSImage(data: data) }
  }

  /// Reads natural pixel size and orientation from the header without
  /// decoding pixels; sides swap for rotated EXIF orientations (5–8).
  private nonisolated static func headerPixelSize(of source: CGImageSource) -> CGSize? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Double,
      let height = properties[kCGImagePropertyPixelHeight] as? Double,
      naturalPixelSizeIsAcceptable(CGSize(width: width, height: height))
    else {
      return nil
    }
    if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, orientation >= 5 {
      return CGSize(width: height, height: width)
    }
    return CGSize(width: width, height: height)
  }

  /// Rejects decompression-bomb headers before any decode: formats like PNG
  /// have no reduced-resolution decode path, so even a downsampled thumbnail
  /// must inflate every scanline of the declared full image.
  nonisolated static func naturalPixelSizeIsAcceptable(_ size: CGSize) -> Bool {
    size.width > 0 && size.height > 0
      && size.width * size.height <= Double(maxNaturalPixelCount)
  }

  /// SVG and PDF bypass ImageIO; NSImage loads them (SVG support is
  /// undocumented best-effort, so nil simply becomes a failed state).
  private nonisolated static func vectorOutcome(
    loading: () -> NSImage?
  ) -> MarkdownImageProbeOutcome {
    guard let image = loading(), image.size.width > 0, image.size.height > 0 else {
      return .failure
    }
    return .vector(
      MarkdownVectorImage(image: image),
      CGSize(width: image.size.width, height: image.size.height))
  }

  // MARK: - Decoding

  private func startDecode(
    source: String, record: MarkdownImageRecord, targetPixelSize: CGFloat
  ) {
    guard !record.decodeInFlight, let url = record.url else { return }
    records[source]?.decodeInFlight = true
    let expectedGeneration = generation
    let isRemote = record.isRemote
    let vector = record.vector
    runTracked { [weak self] in
      let decoded: MarkdownDecodedBitmap?
      if let vector {
        decoded = await MarkdownImageStore.rasterizeVector(
          vector, targetPixelSize: targetPixelSize)
      } else if isRemote {
        decoded = await MarkdownImageStore.decodeRemote(
          url: url, targetPixelSize: targetPixelSize)
      } else {
        decoded = await MarkdownImageStore.decodeLocal(
          url: url, targetPixelSize: targetPixelSize)
      }
      guard let self, self.generation == expectedGeneration else { return }
      self.finishDecode(source: source, result: decoded, targetPixelSize: targetPixelSize)
    }
  }

  private func finishDecode(
    source: String, result: MarkdownDecodedBitmap?, targetPixelSize: CGFloat
  ) {
    guard var record = records[source] else { return }
    record.decodeInFlight = false
    if let result {
      if let previous = record.decoded {
        decodedByteCount -= previous.byteCount
        decodedOrder.removeAll { $0 == source }
      }
      let decoded = MarkdownDecodedImage(
        image: result.image,
        requestedPixelSize: targetPixelSize,
        isAtNaturalLimit: result.isAtNaturalLimit)
      record.decoded = decoded
      records[source] = record
      decodedOrder.append(source)
      decodedByteCount += decoded.byteCount
      evictDecodedImagesIfNeeded(keeping: source)
      onUpdate?(false)
    } else {
      record.state = .failed
      records[source] = record
      onUpdate?(true)
    }
  }

  private nonisolated static func decodeLocal(
    url: URL, targetPixelSize: CGFloat
  ) async -> MarkdownDecodedBitmap? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return nil }
    return decodeThumbnail(from: source, targetPixelSize: targetPixelSize)
  }

  private nonisolated static func decodeRemote(
    url: URL, targetPixelSize: CGFloat
  ) async -> MarkdownDecodedBitmap? {
    // Served from URLCache after the probe's fetch; no second network hit.
    guard let data = await fetchRemoteData(url: url) else { return nil }
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
    return decodeThumbnail(from: source, targetPixelSize: targetPixelSize)
  }

  /// The WWDC18 downsampling recipe: decode from the full image (never the
  /// EXIF thumbnail), bake in orientation, force the pixel decode to happen
  /// now on this worker instead of lazily at first draw on the main thread.
  private nonisolated static func decodeThumbnail(
    from source: CGImageSource, targetPixelSize: CGFloat
  ) -> MarkdownDecodedBitmap? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(targetPixelSize),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      return nil
    }
    let isAtNaturalLimit = CGFloat(max(image.width, image.height)) < targetPixelSize
    return MarkdownDecodedBitmap(image: image, isAtNaturalLimit: isAtNaturalLimit)
  }

  private nonisolated static func rasterizeVector(
    _ vector: MarkdownVectorImage, targetPixelSize: CGFloat
  ) async -> MarkdownDecodedBitmap? {
    let size = vector.image.size
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = targetPixelSize / max(size.width, size.height)
    let pixelWidth = max(1, Int((size.width * scale).rounded()))
    let pixelHeight = max(1, Int((size.height * scale).rounded()))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      return nil
    }
    // NSGraphicsContext.current is thread-local, so this is safe off-main;
    // restore in defer so a throwing image rep cannot leave it installed.
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer { NSGraphicsContext.current = previous }
    vector.image.draw(
      in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
      from: .zero, operation: .copy, fraction: 1)
    guard let image = context.makeImage() else { return nil }
    return MarkdownDecodedBitmap(image: image, isAtNaturalLimit: false)
  }

  private nonisolated static func fetchRemoteData(url: URL) async -> Data? {
    await remoteFetchGate.acquire()
    let data = await fetchRemoteDataUngated(url: url)
    await remoteFetchGate.release()
    return data
  }

  /// Streams the response so the byte cap is enforced while downloading —
  /// a hostile or huge resource is abandoned the moment it exceeds the cap,
  /// never buffered whole first (the cap also catches transparent gzip
  /// inflation, since the stream yields decompressed bytes).
  private nonisolated static func fetchRemoteDataUngated(url: URL) async -> Data? {
    do {
      let (bytes, response) = try await urlSession.bytes(from: url)
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        return nil
      }
      let expected = response.expectedContentLength
      if expected > 0, expected > Int64(maxRemoteImageByteCount) { return nil }
      var data = Data()
      if expected > 0 {
        data.reserveCapacity(Int(min(expected, Int64(maxRemoteImageByteCount))))
      }
      for try await byte in bytes {
        data.append(byte)
        if data.count > maxRemoteImageByteCount { return nil }
      }
      return data.isEmpty ? nil : data
    } catch {
      return nil
    }
  }

  // MARK: - Cache bookkeeping

  private func markRecentlyUsed(_ source: String) {
    guard decodedOrder.last != source, let index = decodedOrder.lastIndex(of: source) else {
      return
    }
    decodedOrder.remove(at: index)
    decodedOrder.append(source)
  }

  // The byte budget comfortably exceeds the footprint of a screenful of
  // column-fitted, downsampled bitmaps (≈3–8 MB each), so eviction should
  // never touch a currently-visible image in practice.
  private func evictDecodedImagesIfNeeded(keeping recent: String) {
    while decodedByteCount > Self.decodedByteBudget,
      let oldest = decodedOrder.first, oldest != recent
    {
      decodedOrder.removeFirst()
      if let removed = records[oldest]?.decoded {
        decodedByteCount -= removed.byteCount
        records[oldest]?.decoded = nil
      }
    }
  }

  private func runTracked(_ work: @escaping @MainActor () async -> Void) {
    let id = UUID()
    let task = Task { [weak self] in
      await work()
      self?.inFlightTasks[id] = nil
    }
    inFlightTasks[id] = task
  }

  // MARK: - Constants

  private static let decodedByteBudget = 128 * 1024 * 1024
  private static let minimumDecodePixelSize: CGFloat = 16
  /// Settle awaits one task per iteration; the bound only guards against a
  /// pathological self-replenishing task set, far above any fixture's count.
  private static let settleIterationLimit = 10_000
  nonisolated private static let maxRemoteImageByteCount = 64 * 1024 * 1024
  /// Headers declaring more pixels than this are rejected before any decode
  /// (≈100 megapixels — beyond any real photograph this app should inline).
  nonisolated private static let maxNaturalPixelCount = 100_000_000
  nonisolated private static let maxConcurrentRemoteFetches = 4
  nonisolated private static let remoteCacheMemoryCapacity = 32 * 1024 * 1024
  nonisolated private static let remoteCacheDiskCapacity = 256 * 1024 * 1024
  /// Idle timer between received chunks.
  nonisolated private static let remoteRequestTimeout: TimeInterval = 15
  /// Hard bound on a whole transfer, so a slow-drip server cannot hold a
  /// fetch slot (and its buffer) open indefinitely.
  nonisolated private static let remoteResourceTimeout: TimeInterval = 60

  nonisolated private static let remoteFetchGate = MarkdownRemoteFetchGate(
    limit: maxConcurrentRemoteFetches)

  /// One session (and one disk cache) shared across documents. Cookies are
  /// never sent or stored — remote image hosts get no more than the request.
  nonisolated private static let urlSession: URLSession = {
    let configuration = URLSessionConfiguration.default
    let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      .map { base in
        var folder = base
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
          folder.append(path: bundleIdentifier, directoryHint: .isDirectory)
        }
        folder.append(path: "MarkdownRemoteImages", directoryHint: .isDirectory)
        return folder
      }
    configuration.urlCache = URLCache(
      memoryCapacity: remoteCacheMemoryCapacity,
      diskCapacity: remoteCacheDiskCapacity,
      directory: cacheFolder)
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    configuration.timeoutIntervalForRequest = remoteRequestTimeout
    configuration.timeoutIntervalForResource = remoteResourceTimeout
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    return URLSession(configuration: configuration)
  }()
}

private struct MarkdownImageRecord {
  var state: MarkdownImageState = .loading
  var url: URL?
  var isRemote = false
  var vector: MarkdownVectorImage?
  var decoded: MarkdownDecodedImage?
  var decodeInFlight = false
}

private struct MarkdownDecodedImage {
  let image: CGImage
  let requestedPixelSize: CGFloat
  let isAtNaturalLimit: Bool
  var byteCount: Int { image.bytesPerRow * image.height }
}
