import Foundation

extension URL {
    var locusDisplayName: String {
        let name = lastPathComponent
        return name.isEmpty || name == "/" ? path(percentEncoded: false) : name
    }

    var locusStandardizedPath: String {
        var path = standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
