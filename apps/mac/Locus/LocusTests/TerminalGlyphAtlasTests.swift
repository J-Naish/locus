import XCTest

@testable import Locus

// Not ported: ghostty Atlas.zig tests "grow OOM" (:780), "init error" (:826),
// "reserve error" (:840), and "grow error" (:858) depend on tripwire/fixed-buffer
// allocation-failure injection, which has no Swift equivalent.
@MainActor
final class TerminalGlyphAtlasTests: XCTestCase {
  // ghostty: Atlas.zig:581 test "exact fit"
  func testExactFit() throws {
    let atlas = TerminalGlyphAtlas(size: 34, format: .grayscale)
    let modified = atlas.modified

    _ = try atlas.reserve(width: 32, height: 32)

    XCTAssertEqual(atlas.modified, modified)
    XCTAssertThrowsError(try atlas.reserve(width: 1, height: 1)) { error in
      XCTAssertEqual(error as? TerminalGlyphAtlas.Error, .atlasFull)
    }
  }

  // ghostty: Atlas.zig:592 test "doesn't fit"
  func testDoesNotFit() {
    let atlas = TerminalGlyphAtlas(size: 32, format: .grayscale)

    XCTAssertThrowsError(try atlas.reserve(width: 32, height: 32)) { error in
      XCTAssertEqual(error as? TerminalGlyphAtlas.Error, .atlasFull)
    }
  }

  // ghostty: Atlas.zig:601 test "fit multiple"
  func testFitMultiple() throws {
    let atlas = TerminalGlyphAtlas(size: 32, format: .grayscale)

    _ = try atlas.reserve(width: 15, height: 30)
    _ = try atlas.reserve(width: 15, height: 30)

    XCTAssertThrowsError(try atlas.reserve(width: 1, height: 1)) { error in
      XCTAssertEqual(error as? TerminalGlyphAtlas.Error, .atlasFull)
    }
  }

  // ghostty: Atlas.zig:611 test "writing data"
  func testWritingData() throws {
    let atlas = TerminalGlyphAtlas(size: 32, format: .grayscale)
    let region = try atlas.reserve(width: 2, height: 2)
    let modified = atlas.modified

    atlas.set(region: region, data: [1, 2, 3, 4])

    XCTAssertGreaterThan(atlas.modified, modified)
    XCTAssertEqual(atlas.data[33], 1)
    XCTAssertEqual(atlas.data[34], 2)
    XCTAssertEqual(atlas.data[65], 3)
    XCTAssertEqual(atlas.data[66], 4)
  }

  // ghostty: Atlas.zig:629 test "writing data from a larger source"
  func testWritingDataFromALargerSource() throws {
    let atlas = TerminalGlyphAtlas(size: 32, format: .grayscale)
    let region = try atlas.reserve(width: 2, height: 2)
    let modified = atlas.modified
    let source: [UInt8] = [
      8, 8, 8, 8, 8,
      8, 8, 1, 2, 8,
      8, 8, 3, 4, 8,
      8, 8, 8, 8, 8,
    ]

    atlas.setFromLarger(
      region: region,
      src: source,
      srcWidth: 5,
      srcX: 2,
      srcY: 1
    )

    XCTAssertGreaterThan(atlas.modified, modified)
    XCTAssertEqual(atlas.data[33], 1)
    XCTAssertEqual(atlas.data[34], 2)
    XCTAssertEqual(atlas.data[65], 3)
    XCTAssertEqual(atlas.data[66], 4)
    XCTAssertFalse(atlas.data.contains(8))
  }

  // ghostty: Atlas.zig:658 test "grow"
  func testGrow() throws {
    let atlas = TerminalGlyphAtlas(size: 4, format: .grayscale)
    let region = try atlas.reserve(width: 2, height: 2)
    XCTAssertThrowsError(try atlas.reserve(width: 1, height: 1)) { error in
      XCTAssertEqual(error as? TerminalGlyphAtlas.Error, .atlasFull)
    }
    atlas.set(region: region, data: [1, 2, 3, 4])
    XCTAssertEqual(atlas.data[5], 1)
    XCTAssertEqual(atlas.data[6], 2)
    XCTAssertEqual(atlas.data[9], 3)
    XCTAssertEqual(atlas.data[10], 4)
    let modified = atlas.modified
    let resized = atlas.resized

    atlas.grow(sizeNew: atlas.size + 1)

    XCTAssertGreaterThan(atlas.modified, modified)
    XCTAssertGreaterThan(atlas.resized, resized)
    _ = try atlas.reserve(width: 1, height: 1)
    XCTAssertEqual(atlas.data[Int(atlas.size) + 1], 1)
    XCTAssertEqual(atlas.data[Int(atlas.size) + 2], 2)
    XCTAssertEqual(atlas.data[Int(atlas.size) * 2 + 1], 3)
    XCTAssertEqual(atlas.data[Int(atlas.size) * 2 + 2], 4)
  }

  // ghostty: Atlas.zig:690 test "writing BGR data"
  func testWritingBGRData() throws {
    let atlas = TerminalGlyphAtlas(size: 32, format: .bgr)
    let region = try atlas.reserve(width: 1, height: 2)

    atlas.set(region: region, data: [1, 2, 3, 4, 5, 6])

    let depth = atlas.format.depth
    XCTAssertEqual(atlas.data[33 * depth], 1)
    XCTAssertEqual(atlas.data[33 * depth + 1], 2)
    XCTAssertEqual(atlas.data[33 * depth + 2], 3)
    XCTAssertEqual(atlas.data[65 * depth], 4)
    XCTAssertEqual(atlas.data[65 * depth + 1], 5)
    XCTAssertEqual(atlas.data[65 * depth + 2], 6)
  }

  // ghostty: Atlas.zig:712 test "grow BGR"
  func testGrowBGR() throws {
    let atlas = TerminalGlyphAtlas(size: 4, format: .bgr)
    let region = try atlas.reserve(width: 2, height: 2)
    XCTAssertThrowsError(try atlas.reserve(width: 1, height: 1)) { error in
      XCTAssertEqual(error as? TerminalGlyphAtlas.Error, .atlasFull)
    }
    atlas.set(
      region: region,
      data: [
        10, 11, 12,
        13, 14, 15,
        20, 21, 22,
        23, 24, 25,
      ]
    )

    assertBGRFixture(in: atlas)
    atlas.grow(sizeNew: 5)
    assertBGRFixture(in: atlas)
    _ = try atlas.reserve(width: 1, height: 3)
    _ = try atlas.reserve(width: 2, height: 1)
    XCTAssertThrowsError(try atlas.reserve(width: 1, height: 1)) { error in
      XCTAssertEqual(error as? TerminalGlyphAtlas.Error, .atlasFull)
    }
  }

  private func assertBGRFixture(
    in atlas: TerminalGlyphAtlas,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let depth = atlas.format.depth
    var topLeft = Int(atlas.size) * depth + depth
    XCTAssertEqual(atlas.data[topLeft], 10, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 1], 11, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 2], 12, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 3], 13, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 4], 14, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 5], 15, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 6], 0, file: file, line: line)

    topLeft += Int(atlas.size) * depth
    XCTAssertEqual(atlas.data[topLeft], 20, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 1], 21, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 2], 22, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 3], 23, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 4], 24, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 5], 25, file: file, line: line)
    XCTAssertEqual(atlas.data[topLeft + 6], 0, file: file, line: line)
  }
}
