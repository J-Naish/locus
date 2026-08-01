import Foundation

let documentDiffMaximumLineCount = 40_000
let documentDiffOperationBudget = 50_000_000
let documentDiffMaximumEditDistance = 2_000

enum DocumentDiffRowKind: Equatable, Sendable {
  case common
  case added
  case removed
}

struct DocumentDiffRow: Equatable, Sendable {
  let kind: DocumentDiffRowKind
  let text: String
}

struct DocumentDiff: Equatable, Sendable {
  let rows: [DocumentDiffRow]
  let addedCount: Int
  let removedCount: Int

  var hasChanges: Bool {
    addedCount > 0 || removedCount > 0
  }
}

enum DocumentDiffEngine {
  static func diff(base: [String], current: [String]) -> DocumentDiff? {
    guard base.count + current.count <= documentDiffMaximumLineCount else {
      return nil
    }

    let commonLimit = min(base.count, current.count)
    var prefixCount = 0
    while prefixCount < commonLimit, base[prefixCount] == current[prefixCount] {
      prefixCount += 1
    }

    var suffixCount = 0
    while suffixCount < commonLimit - prefixCount,
      base[base.count - suffixCount - 1] == current[current.count - suffixCount - 1]
    {
      suffixCount += 1
    }

    let baseMiddle = Array(base[prefixCount..<(base.count - suffixCount)])
    let currentMiddle = Array(current[prefixCount..<(current.count - suffixCount)])
    let middleDiff =
      boundedFineGrainedDiff(base: baseMiddle, current: currentMiddle)
      ?? coarseDiff(base: baseMiddle, current: currentMiddle)

    var rows: [DocumentDiffRow] = []
    rows.reserveCapacity(prefixCount + middleDiff.rows.count + suffixCount)
    rows.append(
      contentsOf: base.prefix(prefixCount).map {
        DocumentDiffRow(kind: .common, text: $0)
      })
    rows.append(contentsOf: middleDiff.rows)
    rows.append(
      contentsOf: base.suffix(suffixCount).map {
        DocumentDiffRow(kind: .common, text: $0)
      })

    return DocumentDiff(
      rows: rows,
      addedCount: middleDiff.addedCount,
      removedCount: middleDiff.removedCount)
  }

  private static func boundedFineGrainedDiff(
    base: [String],
    current: [String]
  ) -> DocumentDiff? {
    let totalLineCount = base.count + current.count
    let maximumDistance = min(
      documentDiffMaximumEditDistance,
      documentDiffOperationBudget / max(1, totalLineCount))

    var remainingBaseCounts: [String: Int] = [:]
    remainingBaseCounts.reserveCapacity(base.count)
    for line in base {
      remainingBaseCounts[line, default: 0] += 1
    }

    var commonUpperBound = 0
    for line in current {
      guard let count = remainingBaseCounts[line], count > 0 else { continue }
      commonUpperBound += 1
      if count == 1 {
        remainingBaseCounts.removeValue(forKey: line)
      } else {
        remainingBaseCounts[line] = count - 1
      }
    }

    let distanceLowerBound =
      base.count + current.count - 2 * commonUpperBound
    guard distanceLowerBound <= maximumDistance else {
      return nil
    }

    let interned = internedLineIDs(base: base, current: current)
    guard
      let offsets = boundedMyersOffsets(
        base: interned.base,
        current: interned.current,
        maximumDistance: maximumDistance)
    else {
      return nil
    }

    return weaveDiff(
      base: base,
      current: current,
      removedOffsets: offsets.removed,
      insertedOffsets: offsets.inserted)
  }

  private static func coarseDiff(base: [String], current: [String]) -> DocumentDiff {
    let rows =
      base.map { DocumentDiffRow(kind: .removed, text: $0) }
      + current.map { DocumentDiffRow(kind: .added, text: $0) }
    return DocumentDiff(
      rows: rows,
      addedCount: current.count,
      removedCount: base.count)
  }

  private static func internedLineIDs(
    base: [String],
    current: [String]
  ) -> (base: [Int32], current: [Int32]) {
    var identifiersByLine: [String: Int32] = [:]
    identifiersByLine.reserveCapacity(base.count + current.count)

    func identifiers(for lines: [String]) -> [Int32] {
      var identifiers: [Int32] = []
      identifiers.reserveCapacity(lines.count)
      for line in lines {
        if let existing = identifiersByLine[line] {
          identifiers.append(existing)
          continue
        }

        let identifier = Int32(identifiersByLine.count)
        identifiersByLine[line] = identifier
        identifiers.append(identifier)
      }
      return identifiers
    }

    return (identifiers(for: base), identifiers(for: current))
  }

  private static func boundedMyersOffsets(
    base: [Int32],
    current: [Int32],
    maximumDistance: Int
  ) -> (removed: Set<Int>, inserted: Set<Int>)? {
    // Variable-width frontier rows keep the worst-case trace at
    // (dMax + 1)^2 Int32 values, about 16 MB when dMax is 2,000.
    var trace: [[Int32]] = []
    trace.reserveCapacity(maximumDistance + 1)

    for distance in 0...maximumDistance {
      var frontier = [Int32](repeating: -1, count: 2 * distance + 1)

      for diagonal in stride(from: -distance, through: distance, by: 2) {
        var x: Int
        if distance == 0 {
          x = 0
        } else {
          let previous = trace[distance - 1]
          if diagonal == -distance
            || (diagonal != distance
              && frontierValue(previous, diagonal: diagonal - 1)
                < frontierValue(previous, diagonal: diagonal + 1))
          {
            x = frontierValue(previous, diagonal: diagonal + 1)
          } else {
            x = frontierValue(previous, diagonal: diagonal - 1) + 1
          }
        }

        var y = x - diagonal
        while x < base.count, y < current.count, base[x] == current[y] {
          x += 1
          y += 1
        }
        frontier[diagonal + distance] = Int32(x)

        if x >= base.count, y >= current.count {
          trace.append(frontier)
          return backtrackOffsets(
            trace: trace,
            baseCount: base.count,
            currentCount: current.count,
            distance: distance)
        }
      }

      trace.append(frontier)
    }

    return nil
  }

  private static func frontierValue(_ frontier: [Int32], diagonal: Int) -> Int {
    let distance = (frontier.count - 1) / 2
    return Int(frontier[diagonal + distance])
  }

  private static func backtrackOffsets(
    trace: [[Int32]],
    baseCount: Int,
    currentCount: Int,
    distance: Int
  ) -> (removed: Set<Int>, inserted: Set<Int>) {
    var removedOffsets = Set<Int>()
    var insertedOffsets = Set<Int>()
    removedOffsets.reserveCapacity(distance)
    insertedOffsets.reserveCapacity(distance)

    var x = baseCount
    var y = currentCount
    guard distance > 0 else {
      return (removedOffsets, insertedOffsets)
    }

    for step in stride(from: distance, through: 1, by: -1) {
      let previous = trace[step - 1]
      let diagonal = x - y
      let previousDiagonal: Int
      if diagonal == -step
        || (diagonal != step
          && frontierValue(previous, diagonal: diagonal - 1)
            < frontierValue(previous, diagonal: diagonal + 1))
      {
        previousDiagonal = diagonal + 1
      } else {
        previousDiagonal = diagonal - 1
      }

      let previousX = frontierValue(previous, diagonal: previousDiagonal)
      let previousY = previousX - previousDiagonal
      while x > previousX, y > previousY {
        x -= 1
        y -= 1
      }

      if x == previousX {
        insertedOffsets.insert(previousY)
      } else {
        removedOffsets.insert(previousX)
      }
      x = previousX
      y = previousY
    }

    return (removedOffsets, insertedOffsets)
  }

  private static func weaveDiff(
    base: [String],
    current: [String],
    removedOffsets: Set<Int>,
    insertedOffsets: Set<Int>
  ) -> DocumentDiff {
    var rows: [DocumentDiffRow] = []
    rows.reserveCapacity(base.count + insertedOffsets.count)
    var baseIndex = 0
    var currentIndex = 0
    var addedCount = 0
    var removedCount = 0

    while baseIndex < base.count || currentIndex < current.count {
      var consumedChange = false
      while baseIndex < base.count, removedOffsets.contains(baseIndex) {
        rows.append(DocumentDiffRow(kind: .removed, text: base[baseIndex]))
        baseIndex += 1
        removedCount += 1
        consumedChange = true
      }
      while currentIndex < current.count, insertedOffsets.contains(currentIndex) {
        rows.append(DocumentDiffRow(kind: .added, text: current[currentIndex]))
        currentIndex += 1
        addedCount += 1
        consumedChange = true
      }
      if consumedChange {
        continue
      }

      guard baseIndex < base.count, currentIndex < current.count else {
        // Bounded Myers should account for every unmatched row. Keep this
        // defensive fallback deterministic if its offset representation changes.
        while baseIndex < base.count {
          rows.append(DocumentDiffRow(kind: .removed, text: base[baseIndex]))
          baseIndex += 1
          removedCount += 1
        }
        while currentIndex < current.count {
          rows.append(DocumentDiffRow(kind: .added, text: current[currentIndex]))
          currentIndex += 1
          addedCount += 1
        }
        break
      }

      rows.append(DocumentDiffRow(kind: .common, text: current[currentIndex]))
      baseIndex += 1
      currentIndex += 1
    }

    return DocumentDiff(
      rows: rows,
      addedCount: addedCount,
      removedCount: removedCount)
  }
}
