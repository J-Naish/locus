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

  func testPendingConflictIsStoredAndClearedWithEntry() throws {
    let cache = OpenDocumentCache()
    cache.store(buffer: try makeBuffer("hello"), encoding: .utf8, fingerprint: nil, forKey: "a")
    XCTAssertFalse(cache.hasPendingConflict(forKey: "a"))

    cache.setPendingConflict(true, forKey: "a")
    XCTAssertTrue(cache.hasPendingConflict(forKey: "a"))

    cache.setPendingConflict(false, forKey: "a")
    XCTAssertFalse(cache.hasPendingConflict(forKey: "a"))

    cache.setPendingConflict(true, forKey: "a")
    cache.drop(forKey: "a")
    XCTAssertFalse(cache.hasPendingConflict(forKey: "a"))
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

  func testReportsWhetherAnyCachedDocumentIsDirty() throws {
    let cache = OpenDocumentCache()
    cache.store(buffer: try makeBuffer("a"), encoding: .utf8, fingerprint: nil, forKey: "a")
    XCTAssertFalse(cache.hasDirtyDocuments)

    cache.store(
      buffer: try makeBuffer("b", dirty: true), encoding: .utf8, fingerprint: nil, forKey: "b")
    XCTAssertTrue(cache.hasDirtyDocuments)
  }

  /// A clean buffer whose UTF-8 byte length is exactly `byteCount` (ASCII fill).
  private func makeBuffer(byteCount: Int) throws -> TextBuffer {
    try makeBuffer(String(repeating: "a", count: max(byteCount, 1)))
  }

  func testEvictsCleanBuffersOverByteBudget() throws {
    // Count limit is generous; only the byte budget should force eviction.
    let cache = OpenDocumentCache(maxRetained: 100, maxRetainedByteCount: 300)
    cache.store(
      buffer: try makeBuffer(byteCount: 200), encoding: .utf8, fingerprint: nil, forKey: "a")
    cache.store(
      buffer: try makeBuffer(byteCount: 200), encoding: .utf8, fingerprint: nil, forKey: "b")

    // a + b = 400 bytes > 300 → least-recently-used clean "a" is evicted.
    XCTAssertNil(cache.cached(forKey: "a"))
    XCTAssertNotNil(cache.cached(forKey: "b"))
    XCTAssertEqual(cache.count, 1)
  }

  func testKeepsMostRecentlyStoredBufferEvenWhenAloneOverByteBudget() throws {
    // The active document is never evicted to satisfy the byte budget.
    let cache = OpenDocumentCache(maxRetained: 100, maxRetainedByteCount: 100)
    cache.store(
      buffer: try makeBuffer(byteCount: 500), encoding: .utf8, fingerprint: nil, forKey: "big")

    XCTAssertNotNil(cache.cached(forKey: "big"))
    XCTAssertEqual(cache.count, 1)
  }

  func testNeverEvictsDirtyBuffersToHonorByteBudget() throws {
    let cache = OpenDocumentCache(maxRetained: 100, maxRetainedByteCount: 100)
    cache.store(
      buffer: try makeBuffer(String(repeating: "a", count: 200), dirty: true),
      encoding: .utf8, fingerprint: nil, forKey: "a")
    cache.store(
      buffer: try makeBuffer(String(repeating: "b", count: 200), dirty: true),
      encoding: .utf8, fingerprint: nil, forKey: "b")

    // Both far exceed the budget but hold unsaved edits → both retained.
    XCTAssertNotNil(cache.cached(forKey: "a"))
    XCTAssertNotNil(cache.cached(forKey: "b"))
    XCTAssertEqual(cache.count, 2)
  }

  func testByteBudgetEvictsLeastRecentlyUsedCleanBufferFirst() throws {
    let cache = OpenDocumentCache(maxRetained: 100, maxRetainedByteCount: 250)
    cache.store(
      buffer: try makeBuffer(byteCount: 100), encoding: .utf8, fingerprint: nil, forKey: "a")
    cache.store(
      buffer: try makeBuffer(byteCount: 100), encoding: .utf8, fingerprint: nil, forKey: "b")
    _ = cache.cached(forKey: "a")  // touch "a" → "b" becomes least-recently-used
    cache.store(
      buffer: try makeBuffer(byteCount: 100), encoding: .utf8, fingerprint: nil, forKey: "c")

    // a + b + c = 300 > 250 → LRU clean "b" is evicted (a was touched, c is newest).
    XCTAssertNotNil(cache.cached(forKey: "a"))
    XCTAssertNil(cache.cached(forKey: "b"))
    XCTAssertNotNil(cache.cached(forKey: "c"))
    XCTAssertEqual(cache.count, 2)
  }
}
