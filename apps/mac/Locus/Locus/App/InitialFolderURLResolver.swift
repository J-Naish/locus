import Foundation

enum InitialFolderResolution: Equatable {
  case folder(URL)
  case empty
  case unavailable
}

enum InitialFolderURLResolver {
  static func resolution(
    arguments: [String] = ProcessInfo.processInfo.arguments,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) -> InitialFolderResolution {
    #if DEBUG
      if environment["LOCUS_UI_TESTING"] == "1" {
        if let workspaceURL = uiTestWorkspaceURL(in: arguments, fileManager: fileManager) {
          return .folder(workspaceURL)
        }

        if hasArgument(named: "--ui-test-workspace", in: arguments) {
          return .unavailable
        }

        guard environment["LOCUS_UI_TEST_HOME_DEFAULT"] == "1" else {
          return .empty
        }
      }
    #endif

    guard
      let homeURL = readableDirectoryURL(
        homeDirectoryURL,
        fileManager: fileManager
      )
    else {
      return .unavailable
    }

    return .folder(homeURL)
  }

  private static func uiTestWorkspaceURL(
    in arguments: [String],
    fileManager: FileManager
  ) -> URL? {
    guard let path = argumentValue(named: "--ui-test-workspace", in: arguments),
      !path.isEmpty
    else {
      return nil
    }

    return readableDirectoryURL(
      URL(filePath: path, directoryHint: .isDirectory),
      fileManager: fileManager
    )
  }

  private static func readableDirectoryURL(_ url: URL, fileManager: FileManager) -> URL? {
    let path = url.path(percentEncoded: false)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      fileManager.isReadableFile(atPath: path)
    else {
      return nil
    }

    return url
  }

  private static func argumentValue(named name: String, in arguments: [String]) -> String? {
    argumentValues(named: name, in: arguments).first
  }

  private static func argumentValues(named name: String, in arguments: [String]) -> [String] {
    var values: [String] = []
    for (index, argument) in arguments.enumerated() {
      if argument.hasPrefix("\(name)=") {
        values.append(String(argument.dropFirst("\(name)=".count)))
        continue
      }

      guard argument == name else {
        continue
      }

      let valueIndex = arguments.index(after: index)
      guard arguments.indices.contains(valueIndex) else {
        continue
      }

      values.append(arguments[valueIndex])
    }

    return values
  }

  private static func hasArgument(named name: String, in arguments: [String]) -> Bool {
    arguments.contains { argument in
      argument == name || argument.hasPrefix("\(name)=")
    }
  }
}
