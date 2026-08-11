import Foundation

let documentFindMaximumMatches = 10_000
let documentFindScanDeadline: Duration = .milliseconds(100)

struct DocumentFindPosition: Equatable, Sendable {
  let line: Int
  let columnUTF16: Int
}

struct DocumentFindMatch: Equatable, Sendable {
  let line: Int
  let range: NSRange
}

struct DocumentFindResult: Equatable, Sendable {
  let matches: [DocumentFindMatch]
  let capped: Bool
}

enum DocumentFindEngine {
  static func scan(
    lineCount: Int,
    lineProvider: (Int) -> String,
    query: String,
    maximumMatches: Int = documentFindMaximumMatches,
    deadline: Duration? = nil
  ) -> DocumentFindResult {
    guard lineCount > 0, !query.isEmpty, maximumMatches > 0 else {
      return DocumentFindResult(matches: [], capped: false)
    }

    var matches: [DocumentFindMatch] = []
    matches.reserveCapacity(min(maximumMatches, 256))
    let clock = ContinuousClock()
    let expiration = deadline.map { clock.now.advanced(by: $0) }

    for line in 0..<lineCount {
      let string = lineProvider(line) as NSString
      var searchRange = NSRange(location: 0, length: string.length)
      while searchRange.length > 0 {
        let range = string.range(
          of: query,
          options: [.caseInsensitive],
          range: searchRange
        )
        guard range.location != NSNotFound else {
          break
        }
        matches.append(DocumentFindMatch(line: line, range: range))
        if matches.count >= maximumMatches {
          return DocumentFindResult(matches: matches, capped: true)
        }
        let nextLocation = NSMaxRange(range)
        searchRange = NSRange(
          location: nextLocation,
          length: max(0, string.length - nextLocation)
        )
      }
      if (line + 1).isMultiple(of: 256),
        let expiration,
        clock.now >= expiration
      {
        return DocumentFindResult(matches: matches, capped: true)
      }
    }

    return DocumentFindResult(matches: matches, capped: false)
  }

  static func firstMatchIndex(
    atOrAfter position: DocumentFindPosition,
    in matches: [DocumentFindMatch]
  ) -> Int? {
    guard !matches.isEmpty else { return nil }
    if let index = matches.firstIndex(where: { match in
      match.line > position.line
        || (match.line == position.line && match.range.location >= position.columnUTF16)
    }) {
      return index
    }
    return 0
  }

  static func nextIndex(after currentIndex: Int?, matchCount: Int) -> Int? {
    guard matchCount > 0 else { return nil }
    guard let currentIndex, currentIndex >= 0 else { return 0 }
    return (currentIndex + 1) % matchCount
  }

  static func previousIndex(before currentIndex: Int?, matchCount: Int) -> Int? {
    guard matchCount > 0 else { return nil }
    guard let currentIndex, currentIndex >= 0 else { return matchCount - 1 }
    return (currentIndex - 1 + matchCount) % matchCount
  }
}

enum DocumentFindDisplayText {
  static func markdownDisplayText(
    for line: String,
    state: MarkdownLineStyleState
  ) -> String {
    TextDocumentSyntaxHighlighter.markdownDisplayMap(for: line, state: state).displayText
  }
}
