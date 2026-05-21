import Foundation

enum WorkspaceNavigation {
    static func parentFolderURL(for folderURL: URL, within rootURL: URL? = nil) -> URL? {
        let standardizedURL = folderURL.standardizedFileURL
        let standardizedRootURL = rootURL?.standardizedFileURL

        if let standardizedRootURL,
           standardizedURL.path(percentEncoded: false) == standardizedRootURL.path(percentEncoded: false) {
            return nil
        }

        let parentURL = standardizedURL.deletingLastPathComponent()

        guard parentURL.path(percentEncoded: false) != standardizedURL.path(percentEncoded: false) else {
            return nil
        }

        if let standardizedRootURL,
           !parentURL.path(percentEncoded: false).hasPathPrefix(standardizedRootURL.path(percentEncoded: false)) {
            return nil
        }

        return parentURL
    }
}

private extension String {
    func hasPathPrefix(_ prefix: String) -> Bool {
        guard prefix != "/" else {
            return hasPrefix(prefix)
        }

        return self == prefix || hasPrefix(prefix + "/")
    }
}
