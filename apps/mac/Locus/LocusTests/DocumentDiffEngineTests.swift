import XCTest

@testable import Locus

final class DocumentDiffEngineTests: XCTestCase {
  func testIdenticalInputsProduceOnlyCommonRows() throws {
    let diff = try XCTUnwrap(
      DocumentDiffEngine.diff(base: ["alpha", "beta"], current: ["alpha", "beta"]))

    XCTAssertEqual(
      diff.rows,
      [
        DocumentDiffRow(kind: .common, text: "alpha"),
        DocumentDiffRow(kind: .common, text: "beta"),
      ])
    XCTAssertEqual(diff.addedCount, 0)
    XCTAssertEqual(diff.removedCount, 0)
    XCTAssertFalse(diff.hasChanges)
  }

  func testInsertionDeletionAndReplacementProduceOrderedRowsAndCounts() throws {
    let insertion = try XCTUnwrap(
      DocumentDiffEngine.diff(base: ["a", "c"], current: ["a", "b", "c"]))
    let deletion = try XCTUnwrap(
      DocumentDiffEngine.diff(base: ["a", "b", "c"], current: ["a", "c"]))
    let replacement = try XCTUnwrap(
      DocumentDiffEngine.diff(base: ["a", "old", "c"], current: ["a", "new", "c"]))

    XCTAssertEqual(insertion.rows.map(\.kind), [.common, .added, .common])
    XCTAssertEqual(insertion.addedCount, 1)
    XCTAssertEqual(insertion.removedCount, 0)
    XCTAssertEqual(deletion.rows.map(\.kind), [.common, .removed, .common])
    XCTAssertEqual(deletion.addedCount, 0)
    XCTAssertEqual(deletion.removedCount, 1)
    XCTAssertEqual(
      replacement.rows,
      [
        DocumentDiffRow(kind: .common, text: "a"),
        DocumentDiffRow(kind: .removed, text: "old"),
        DocumentDiffRow(kind: .added, text: "new"),
        DocumentDiffRow(kind: .common, text: "c"),
      ])
    XCTAssertEqual(replacement.addedCount, 1)
    XCTAssertEqual(replacement.removedCount, 1)
  }

  func testEmptyInputsProduceAddedRemovedOrEmptyRows() throws {
    let added = try XCTUnwrap(DocumentDiffEngine.diff(base: [], current: ["a", "b"]))
    let removed = try XCTUnwrap(DocumentDiffEngine.diff(base: ["a", "b"], current: []))
    let empty = try XCTUnwrap(DocumentDiffEngine.diff(base: [], current: []))

    XCTAssertEqual(added.rows.map(\.kind), [.added, .added])
    XCTAssertEqual(removed.rows.map(\.kind), [.removed, .removed])
    XCTAssertTrue(empty.rows.isEmpty)
    XCTAssertFalse(empty.hasChanges)
  }

  func testInterleavedEditsRoundTripBaseAndCurrentDocuments() throws {
    let base = (0..<200).map { "line \($0)" }
    var current = base
    current.remove(at: 171)
    current[121] = "replacement 121"
    current.insert("inserted 80", at: 80)
    current[22] = "replacement 22"

    let diff = try XCTUnwrap(DocumentDiffEngine.diff(base: base, current: current))
    let reconstructedBase = diff.rows.filter { $0.kind != .added }.map(\.text)
    let reconstructedCurrent = diff.rows.filter { $0.kind != .removed }.map(\.text)

    XCTAssertEqual(reconstructedBase, base)
    XCTAssertEqual(reconstructedCurrent, current)
  }

  func testDocumentsOverLineBudgetReturnNil() {
    let base = Array(repeating: "base", count: documentDiffMaximumLineCount)

    XCTAssertNil(DocumentDiffEngine.diff(base: base, current: ["overflow"]))
  }

  func testFiveThousandLinesWithScatteredEditsStayWithinBudget() throws {
    let base = (0..<5_000).map { "line \($0)" }
    var current = base
    for index in stride(from: 0, to: 5_000, by: 25) {
      current[index] = "edited \(index)"
    }

    let clock = ContinuousClock()
    let start = clock.now
    let diff = try XCTUnwrap(DocumentDiffEngine.diff(base: base, current: current))
    let elapsed = start.duration(to: clock.now)

    print("DocumentDiffEngine 5,000 lines / 200 edits: \(elapsed)")
    XCTAssertEqual(diff.addedCount, 200)
    XCTAssertEqual(diff.removedCount, 200)
    XCTAssertLessThan(elapsed, .milliseconds(100))
  }

  func testLargeCommonEndsPreserveTheFineGrainedMiddleDiff() throws {
    let prefix = (0..<7_000).map { "prefix \($0)" }
    let suffix = (0..<7_000).map { "suffix \($0)" }
    let baseMiddle = ["old before", "shared middle", "old after"]
    let currentMiddle = ["new before", "shared middle", "new after"]
    let reference = try XCTUnwrap(
      DocumentDiffEngine.diff(base: baseMiddle, current: currentMiddle))

    let diff = try XCTUnwrap(
      DocumentDiffEngine.diff(
        base: prefix + baseMiddle + suffix,
        current: prefix + currentMiddle + suffix))

    let expectedRows =
      prefix.map { DocumentDiffRow(kind: .common, text: $0) }
      + reference.rows
      + suffix.map { DocumentDiffRow(kind: .common, text: $0) }
    XCTAssertEqual(diff.rows, expectedRows)
    XCTAssertEqual(diff.addedCount, reference.addedCount)
    XCTAssertEqual(diff.removedCount, reference.removedCount)
  }

  func testLargeDissimilarMiddleFallsBackToRemovedThenAddedRows() throws {
    let baseMiddle = (0..<6_001).map { "old \($0)" }
    let currentMiddle = (0..<6_001).map { "new \($0)" }

    let diff = try XCTUnwrap(
      DocumentDiffEngine.diff(
        base: ["prefix"] + baseMiddle + ["suffix"],
        current: ["prefix"] + currentMiddle + ["suffix"]))

    XCTAssertEqual(diff.rows.first, DocumentDiffRow(kind: .common, text: "prefix"))
    XCTAssertEqual(
      Array(diff.rows.dropFirst().prefix(baseMiddle.count)),
      baseMiddle.map { DocumentDiffRow(kind: .removed, text: $0) })
    XCTAssertEqual(
      Array(diff.rows.dropFirst(1 + baseMiddle.count).prefix(currentMiddle.count)),
      currentMiddle.map { DocumentDiffRow(kind: .added, text: $0) })
    XCTAssertEqual(diff.rows.last, DocumentDiffRow(kind: .common, text: "suffix"))
    XCTAssertEqual(diff.addedCount, currentMiddle.count)
    XCTAssertEqual(diff.removedCount, baseMiddle.count)
    XCTAssertTrue(diff.hasChanges)
  }

  func testTwentyThousandLineRewriteStaysWithinLatencyBudget() throws {
    let base = (0..<20_000).map { "old \($0)" }
    let current = (0..<20_000).map { "new \($0)" }

    let clock = ContinuousClock()
    let start = clock.now
    let diff = try XCTUnwrap(DocumentDiffEngine.diff(base: base, current: current))
    let elapsed = start.duration(to: clock.now)

    print("DocumentDiffEngine 20,000-line rewrite: \(elapsed)")
    XCTAssertEqual(diff.removedCount, 20_000)
    XCTAssertEqual(diff.addedCount, 20_000)
    XCTAssertLessThan(elapsed, .milliseconds(150))
  }

  func testTwentyThousandLinesWithDistantScatteredEditsStayExactAndFast() throws {
    let base = (0..<20_000).map { "line \($0)" }
    var current = base
    let editedIndices = Array(100..<150) + Array(19_800..<19_850)
    for index in editedIndices {
      current[index] = "edited \(index)"
    }

    let clock = ContinuousClock()
    let start = clock.now
    let diff = try XCTUnwrap(DocumentDiffEngine.diff(base: base, current: current))
    let elapsed = start.duration(to: clock.now)

    print("DocumentDiffEngine 20,000 lines / 100 distant edits: \(elapsed)")
    XCTAssertEqual(diff.addedCount, editedIndices.count)
    XCTAssertEqual(diff.removedCount, editedIndices.count)
    XCTAssertEqual(diff.rows.filter { $0.kind == .common }.count, 19_900)
    XCTAssertEqual(
      diff.rows.filter { $0.kind != .common }.map(\.text),
      (100..<150).map { "line \($0)" }
        + (100..<150).map { "edited \($0)" }
        + (19_800..<19_850).map { "line \($0)" }
        + (19_800..<19_850).map { "edited \($0)" })
    XCTAssertLessThan(elapsed, .milliseconds(150))
  }

  func testMaximumEditDistanceBoundarySelectsFineGrainedThenCoarseRows() throws {
    func documents(replacementCount: Int) -> (base: [String], current: [String]) {
      let split = replacementCount / 2
      let base =
        (0..<split).map { "old leading \($0)" }
        + ["shared"]
        + (split..<replacementCount).map { "old trailing \($0)" }
      let current =
        (0..<split).map { "new leading \($0)" }
        + ["shared"]
        + (split..<replacementCount).map { "new trailing \($0)" }
      return (base, current)
    }

    let underLimit = documents(replacementCount: 999)
    let overLimit = documents(replacementCount: 1_001)
    let fine = try XCTUnwrap(
      DocumentDiffEngine.diff(base: underLimit.base, current: underLimit.current))
    let coarse = try XCTUnwrap(
      DocumentDiffEngine.diff(base: overLimit.base, current: overLimit.current))

    XCTAssertEqual(fine.rows.filter { $0.kind == .common }.map(\.text), ["shared"])
    XCTAssertFalse(coarse.rows.contains { $0.kind == .common })
    XCTAssertEqual(
      Array(coarse.rows.prefix(overLimit.base.count)).map(\.kind),
      Array(repeating: .removed, count: overLimit.base.count))
    XCTAssertEqual(
      Array(coarse.rows.suffix(overLimit.current.count)).map(\.kind),
      Array(repeating: .added, count: overLimit.current.count))
  }

  func testLargeHalfDocumentReorderFallsBackWithinLatencyBudget() throws {
    let firstHalf = (0..<2_500).map { "first \($0)" }
    let secondHalf = (0..<2_500).map { "second \($0)" }
    let base = firstHalf + secondHalf
    let current = secondHalf + firstHalf

    let clock = ContinuousClock()
    let start = clock.now
    let diff = try XCTUnwrap(DocumentDiffEngine.diff(base: base, current: current))
    let elapsed = start.duration(to: clock.now)

    print("DocumentDiffEngine 5,000-line half-document reorder: \(elapsed)")
    XCTAssertFalse(diff.rows.contains { $0.kind == .common })
    XCTAssertEqual(
      Array(diff.rows.prefix(base.count)).map(\.kind),
      Array(repeating: .removed, count: base.count))
    XCTAssertEqual(
      Array(diff.rows.suffix(current.count)).map(\.kind),
      Array(repeating: .added, count: current.count))
    XCTAssertLessThan(elapsed, .milliseconds(700))
  }

  func testSeededSmallInputsAlwaysReconstructBothDocuments() throws {
    var generator = SeededGenerator(seed: 0x4C_4F_43_55_53)

    for caseIndex in 0..<200 {
      let baseCount = Int(generator.next() % 25)
      let currentCount = Int(generator.next() % 25)
      let base = (0..<baseCount).map { _ in "value \(generator.next() % 12)" }
      let current = (0..<currentCount).map { _ in "value \(generator.next() % 12)" }

      let diff = try XCTUnwrap(DocumentDiffEngine.diff(base: base, current: current))
      let reconstructedBase = diff.rows.filter { $0.kind != .added }.map(\.text)
      let reconstructedCurrent = diff.rows.filter { $0.kind != .removed }.map(\.text)

      XCTAssertEqual(reconstructedBase, base, "base reconstruction failed for case \(caseIndex)")
      XCTAssertEqual(
        reconstructedCurrent,
        current,
        "current reconstruction failed for case \(caseIndex)")
    }
  }
}

private struct SeededGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    return state
  }
}
