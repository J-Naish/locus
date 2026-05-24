import Foundation

enum WorkspaceNavigation {
  static func parentFolderURL(for folderURL: URL, within rootURL: URL? = nil) -> URL? {
    let standardizedURL = folderURL.standardizedFileURL
    let standardizedRootURL = rootURL?.standardizedFileURL

    if let standardizedRootURL,
      standardizedURL.path(percentEncoded: false) == standardizedRootURL.path(percentEncoded: false)
    {
      return nil
    }

    let parentURL = standardizedURL.deletingLastPathComponent()

    guard parentURL.path(percentEncoded: false) != standardizedURL.path(percentEncoded: false)
    else {
      return nil
    }

    if let standardizedRootURL,
      !parentURL.path(percentEncoded: false).locusHasPathPrefix(
        standardizedRootURL.path(percentEncoded: false))
    {
      return nil
    }

    return parentURL
  }
}

extension String {
  func locusHasPathPrefix(_ prefix: String) -> Bool {
    var normalizedPrefix = prefix
    while normalizedPrefix.count > 1, normalizedPrefix.hasSuffix("/") {
      normalizedPrefix.removeLast()
    }
    guard normalizedPrefix != "/" else {
      return hasPrefix(normalizedPrefix)
    }

    return self == normalizedPrefix || hasPrefix(normalizedPrefix + "/")
  }
}
