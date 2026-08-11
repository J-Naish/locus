import Foundation

enum MarkdownLinkOpenRequest: Equatable {
  case external(URL)
  case file(URL)
  case anchor(String)
}

enum MarkdownLinkVisualState: Equatable, Sendable {
  case valid
  case invalid
}

enum MarkdownLinkNavigation {
  private static let allowedExternalSchemes: Set<String> = ["http", "https", "mailto", "tel"]

  static func openRequest(
    for destination: String,
    baseFileURL: URL?,
    fileExists: (URL) -> Bool = {
      FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
    }
  ) -> MarkdownLinkOpenRequest? {
    guard let cleaned = primaryDestination(in: destination) else {
      return nil
    }
    if isAnchorDestination(cleaned) {
      guard let fragments = anchorFragments(for: cleaned) else { return nil }
      return .anchor(fragments.decoded)
    }

    if let url = externalURL(for: cleaned) {
      return .external(url)
    }

    guard let fileURL = fileURL(for: cleaned, baseFileURL: baseFileURL),
      fileExists(fileURL)
    else {
      return nil
    }
    return .file(fileURL)
  }

  static func visualState(
    for destination: String,
    baseFileURL: URL?,
    fileExists: (URL) -> Bool = {
      FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
    }
  ) -> MarkdownLinkVisualState {
    guard let cleaned = primaryDestination(in: destination) else {
      return .invalid
    }

    if isAnchorDestination(cleaned) {
      return .valid
    }

    if externalURL(for: cleaned) != nil {
      return .valid
    }

    guard !hasExplicitNonFileScheme(cleaned),
      let fileURL = fileURL(for: cleaned, baseFileURL: baseFileURL)
    else {
      return .invalid
    }

    return fileExists(fileURL) ? .valid : .invalid
  }

  private static func externalURL(for destination: String) -> URL? {
    guard let url = URL(string: destination),
      let scheme = url.scheme?.lowercased(),
      allowedExternalSchemes.contains(scheme)
    else {
      return nil
    }

    switch scheme {
    case "http", "https":
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      return components?.host?.isEmpty == false ? url : nil
    case "mailto", "tel":
      let value = destination.dropFirst(scheme.count + 1)
      return value.isEmpty ? nil : url
    default:
      return nil
    }
  }

  private static func primaryDestination(in raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }

    if value.first == "<", let close = value.firstIndex(of: ">") {
      value = String(value[value.index(after: value.startIndex)..<close])
    } else if let split = value.firstIndex(where: { $0 == " " || $0 == "\t" }) {
      value = String(value[..<split])
    }

    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    return value
  }

  private static func fileURL(for destination: String, baseFileURL: URL?) -> URL? {
    guard !destination.isEmpty else { return nil }
    guard !hasExplicitNonFileScheme(destination) else { return nil }

    if let url = URL(string: destination), url.isFileURL {
      return url.standardizedFileURL
    }

    let path =
      filePathPart(of: destination).removingPercentEncoding ?? filePathPart(of: destination)
    guard !path.isEmpty else { return nil }

    if path.hasPrefix("~/") || path == "~" {
      return URL(filePath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
    if path.hasPrefix("/") {
      return URL(filePath: path).standardizedFileURL
    }
    guard let baseFileURL else { return nil }
    return baseFileURL.deletingLastPathComponent().appending(path: path).standardizedFileURL
  }

  private static func filePathPart(of destination: String) -> String {
    let end = destination.firstIndex { $0 == "#" || $0 == "?" } ?? destination.endIndex
    return String(destination[..<end])
  }

  private static func hasExplicitNonFileScheme(_ destination: String) -> Bool {
    guard let colon = destination.firstIndex(of: ":") else { return false }
    let prefix = destination[..<colon]
    if prefix.contains("/") || prefix.contains("#") || prefix.contains("?") { return false }
    return prefix.lowercased() != "file"
  }

  private static func isAnchorDestination(_ destination: String) -> Bool {
    destination.hasPrefix("#") && destination.dropFirst().isEmpty == false
  }

  static func anchorFragments(for destination: String) -> (decoded: String, raw: String)? {
    guard let cleaned = primaryDestination(in: destination),
      isAnchorDestination(cleaned)
    else {
      return nil
    }
    let raw = String(cleaned.dropFirst())
    return (raw.removingPercentEncoding ?? raw, raw)
  }
}

struct MarkdownHeadingAnchor: Equatable, Sendable {
  let line: Int
  let slug: String
}

enum MarkdownHeadingAnchorTable {
  static func anchors(
    lines: [String],
    states: [MarkdownLineStyleState]
  ) -> [MarkdownHeadingAnchor] {
    var slugCounts: [String: Int] = [:]
    var anchors: [MarkdownHeadingAnchor] = []
    for index in lines.indices {
      guard index < states.count,
        states[index].headingLevel != nil,
        !states[index].isSetextUnderline
      else {
        continue
      }
      let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[index],
        font: TextDocumentSyntax.markdown.font,
        state: states[index])
      let base = slug(for: rendered)
      guard !base.isEmpty else { continue }
      let duplicateIndex = slugCounts[base, default: 0]
      slugCounts[base] = duplicateIndex + 1
      let unique = duplicateIndex == 0 ? base : "\(base)-\(duplicateIndex)"
      anchors.append(MarkdownHeadingAnchor(line: index, slug: unique))
    }
    return anchors
  }

  static func resolve(
    decodedFragment: String,
    rawFragment: String,
    in anchors: [MarkdownHeadingAnchor]
  ) -> Int? {
    if let anchor = anchors.first(where: { $0.slug == decodedFragment }) {
      return anchor.line
    }
    return anchors.first(where: { $0.slug == rawFragment })?.line
  }

  static func slug(for text: String) -> String {
    var result = ""

    for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
      if CharacterSet.whitespacesAndNewlines.contains(scalar) {
        result.append("-")
        continue
      }

      let value: String?
      switch scalar.value {
      case 65...90:
        value = UnicodeScalar(scalar.value + 32).map(String.init)
      case 97...122, 48...57:
        value = String(scalar)
      case 45, 95:
        value = String(scalar)
      default:
        value =
          CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
          ? String(scalar)
          : nil
      }
      guard let value else { continue }
      result.append(value)
    }
    return result
  }
}
