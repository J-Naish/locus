import XCTest

@testable import Locus

@MainActor
final class OpenDocumentCacheTests: XCTestCase {
  private func makeBuffer(_ text: String, dirty: Bool = false) throws -> TextBuffer {
    let buffer = try TextBuffer.open(bytes: Data(text.utf8))
    if dirty {
      try buffer.insert("X", atUTF16: 0)
      XCTAssertTrue(buffer.isDirty)
    }
    return buffer
  }

  func testCachedReturnsNilForMissingKey() {
    let cache = OpenDocumentCache()
    XCTAssertNil(cache.cached(forKey: "missing"))
    XCTAssertFalse(cache.contains(forKey: "missing"))
  }

  func testStoreAndCachedRoundTrip() throws {
    let cache = OpenDocumentCache()
    let buffer = try makeBuffer("hello")
    cache.store(buffer: buffer, encoding: .utf8, fingerprint: nil, forKey: "a")

    XCTAssertTrue(cache.contains(forKey: "a"))
    let got = cache.cached(forKey: "a")
    XCTAssertTrue(got?.buffer === buffer)  // same live buffer, edits and all
    XCTAssertEqual(got?.encoding, .utf8)
  }

  func testFingerprintIsStoredAndUpdatable() throws {
    let cache = OpenDocumentCache()
    let original = DocumentFileFingerprint(
      size: 10, modificationDate: Date(timeIntervalSince1970: 1))
    cache.store(
      buffer: try makeBuffer("hello"), encoding: .utf8, fingerprint: original, forKey: "a")
    XCTAssertEqual(cache.fingerprint(forKey: "a"), original)

    let updated = DocumentFileFingerprint(
      size: 20, modificationDate: Date(timeIntervalSince1970: 2))
    cache.setFingerprint(updated, forKey: "a")
    XCTAssertEqual(cache.fingerprint(forKey: "a"), updated)

    cache.setFingerprint(updated, forKey: "missing")  // no entry → no-op, no crash
    XCTAssertNil(cache.fingerprint(forKey: "missing"))
  }

  func testDropRemovesEntry() throws {
    let cache = OpenDocumentCache()
    cache.store(buffer: try makeBuffer("hello"), encoding: .utf8, fingerprint: nil, forKey: "a")
    cache.drop(forKey: "a")
    XCTAssertNil(cache.cached(forKey: "a"))
    XCTAssertFalse(cache.contains(forKey: "a"))
  }

  func testEvictsLeastRecentlyUsedCleanBufferBeyondLimit() throws {
    let cache = OpenDocumentCache(maxRetained: 2)
    cache.store(buffer: try makeBuffer("a"), encoding: .utf8, fingerprint: nil, forKey: "a")
    cache.store(buffer: try makeBuffer("b"), encoding: .utf8, fingerprint: nil, forKey: "b")
    cache.store(buffer: try makeBuffer("c"), encoding: .utf8, fingerprint: nil, forKey: "c")

    XCTAssertNil(cache.cached(forKey: "a"))  // least-recently-used clean evicted
    XCTAssertNotNil(cache.cached(forKey: "b"))
    XCTAssertNotNil(cache.cached(forKey: "c"))
    XCTAssertEqual(cache.count, 2)
  }

  func testRecencyIsUpdatedOnAccess() throws {
    let cache = OpenDocumentCache(maxRetained: 2)
    cache.store(buffer: try makeBuffer("a"), encoding: .utf8, fingerprint: nil, forKey: "a")
    cache.store(buffer: try makeBuffer("b"), encoding: .utf8, fingerprint: nil, forKey: "b")
    _ = cache.cached(forKey: "a")  // touch "a" → "b" is now least-recently-used
    cache.store(buffer: try makeBuffer("c"), encoding: .utf8, fingerprint: nil, forKey: "c")

    XCTAssertNotNil(cache.cached(forKey: "a"))
    XCTAssertNil(cache.cached(forKey: "b"))  // evicted as LRU
  }

  func testRetainsDirtyBuffersBeyondLimit() throws {
    // Unsaved edits are never dropped to honor the retention limit.
    let cache = OpenDocumentCache(maxRetained: 1)
    cache.store(
      buffer: try makeBuffer("a", dirty: true), encoding: .utf8, fingerprint: nil, forKey: "a")
    cache.store(
      buffer: try makeBuffer("c", dirty: true), encoding: .utf8, fingerprint: nil, forKey: "c")

    XCTAssertNotNil(cache.cached(forKey: "a"))
    XCTAssertNotNil(cache.cached(forKey: "c"))
    XCTAssertEqual(cache.count, 2)  // both kept despite maxRetained == 1
  }
}
