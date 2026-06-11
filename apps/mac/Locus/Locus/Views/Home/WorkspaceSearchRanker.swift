import Foundation

// Tested in WorkspaceEntrySearchTests.swift (there is no WorkspaceSearchRankerTests.swift).
enum WorkspaceSearchMatchKind: Int, Comparable {
  case exactName = 0
  case stem = 1
  case prefix = 2
  case contains = 3
  case singleTypo = 4

  var rank: Int {
    rawValue
  }

  static func < (lhs: WorkspaceSearchMatchKind, rhs: WorkspaceSearchMatchKind) -> Bool {
    lhs.rank < rhs.rank
  }
}

enum WorkspaceSearchRanker {
  static func rankedFilter<Item>(
    _ items: [Item],
    query: String,
    matchableString: (Item) -> String
  ) -> [Item] {
    let terms = searchTerms(from: query).map(SearchTerm.init)
    guard !terms.isEmpty else {
      return items
    }

    return items.enumerated().compactMap { offset, item -> RankedItem<Item>? in
      var searchableString = SearchableString(matchableString(item))
      var weakestMatchKind = WorkspaceSearchMatchKind.exactName
      var totalMatchRank = 0

      for term in terms {
        guard let matchKind = matchKind(for: term, in: &searchableString) else {
          return nil
        }

        weakestMatchKind = max(weakestMatchKind, matchKind)
        totalMatchRank += matchKind.rank
      }

      return RankedItem(
        item: item,
        originalOffset: offset,
        score: SearchScore(
          weakestMatchKind: weakestMatchKind,
          totalMatchRank: totalMatchRank
        )
      )
    }
    .sorted { lhs, rhs in
      if lhs.score != rhs.score {
        return lhs.score < rhs.score
      }

      return lhs.originalOffset < rhs.originalOffset
    }
    .map(\.item)
  }

  static func matchKind(for rawTerm: String, in rawString: String) -> WorkspaceSearchMatchKind? {
    var searchableString = SearchableString(rawString)
    return matchKind(for: SearchTerm(rawTerm), in: &searchableString)
  }

  private static func matchKind(
    for term: SearchTerm,
    in string: inout SearchableString
  ) -> WorkspaceSearchMatchKind? {
    if string.normalized == term.normalized {
      return .exactName
    }

    if string.normalizedStem == term.normalized {
      return .stem
    }

    if string.normalized.hasPrefix(term.normalized)
      || string.normalizedStem.hasPrefix(term.normalized)
    {
      return .prefix
    }

    if string.raw.localizedStandardContains(term.raw) || string.normalized.contains(term.normalized)
    {
      return .contains
    }

    guard term.allowsFuzzyMatch else {
      return nil
    }

    for token in string.searchTokens() {
      if FuzzyMatching.isSingleTypoMatch(term.characters, Array(token)) {
        return .singleTypo
      }
    }

    return nil
  }

  private static func searchTerms(from query: String) -> [String] {
    query
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }
}

private struct SearchTerm {
  let raw: String
  let normalized: String
  let characters: [Character]
  let allowsFuzzyMatch: Bool

  init(_ raw: String) {
    self.raw = raw
    let normalized = Self.normalizedSearchString(raw)
    let characters = Array(normalized)
    self.normalized = normalized
    self.characters = characters
    allowsFuzzyMatch = characters.count >= 4 && !Self.containsCJKCharacter(in: normalized)
  }

  private static func normalizedSearchString(_ string: String) -> String {
    string.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: .current
    )
  }

  private static func containsCJKCharacter(in string: String) -> Bool {
    string.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3040...0x309F,  // Hiragana
        0x30A0...0x30FF,  // Katakana
        0x3400...0x4DBF,  // CJK Extension A
        0x4E00...0x9FFF,  // CJK Unified Ideographs
        0xF900...0xFAFF,  // CJK Compatibility Ideographs
        0xFF66...0xFF9F:  // Halfwidth Katakana
        return true
      default:
        return false
      }
    }
  }
}

private struct SearchableString {
  let raw: String
  let normalized: String
  let normalizedStem: String
  private var tokens: [String]?

  init(_ raw: String) {
    self.raw = raw
    normalized = Self.normalizedSearchString(raw)
    normalizedStem = Self.normalizedStem(from: normalized)
  }

  mutating func searchTokens() -> [String] {
    if let tokens {
      return tokens
    }

    let tokens =
      normalized
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    self.tokens = tokens
    return tokens
  }

  private static func normalizedSearchString(_ string: String) -> String {
    string.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: .current
    )
  }

  private static func normalizedStem(from normalizedString: String) -> String {
    guard let dotIndex = normalizedString.lastIndex(of: "."),
      dotIndex != normalizedString.startIndex
    else {
      return normalizedString
    }

    return String(normalizedString[..<dotIndex])
  }
}

private struct RankedItem<Item> {
  let item: Item
  let originalOffset: Int
  let score: SearchScore
}

private struct SearchScore: Comparable {
  let weakestMatchKind: WorkspaceSearchMatchKind
  let totalMatchRank: Int

  static func < (lhs: SearchScore, rhs: SearchScore) -> Bool {
    if lhs.weakestMatchKind != rhs.weakestMatchKind {
      return lhs.weakestMatchKind < rhs.weakestMatchKind
    }

    if lhs.totalMatchRank != rhs.totalMatchRank {
      return lhs.totalMatchRank < rhs.totalMatchRank
    }

    return false
  }
}
