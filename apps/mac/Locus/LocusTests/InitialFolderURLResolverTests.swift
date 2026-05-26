import XCTest

@testable import Locus

final class InitialFolderURLResolverTests: XCTestCase {
  func testReturnsHomeDirectoryForNormalLaunch() throws {
    let homeURL = try temporaryDirectory()

    let resolution = InitialFolderURLResolver.resolution(
      arguments: ["Locus"],
      environment: [:],
      homeDirectoryURL: homeURL
    )

    XCTAssertEqual(resolution, .folder(homeURL))
  }

  func testUITestingWithoutWorkspaceKeepsEmptyLaunchState() {
    let resolution = InitialFolderURLResolver.resolution(
      arguments: ["Locus"],
      environment: ["LOCUS_UI_TESTING": "1"]
    )

    XCTAssertEqual(resolution, .empty)
  }

  func testUITestingUsesExplicitWorkspace() throws {
    let workspaceURL = try temporaryDirectory()

    let resolution = InitialFolderURLResolver.resolution(
      arguments: [
        "Locus",
        "--ui-test-workspace",
        workspaceURL.path(percentEncoded: false),
      ],
      environment: ["LOCUS_UI_TESTING": "1"]
    )

    XCTAssertEqual(resolution, .folder(workspaceURL))
  }

  func testUITestingUsesEqualsFormExplicitWorkspace() throws {
    let workspaceURL = try temporaryDirectory()

    let resolution = InitialFolderURLResolver.resolution(
      arguments: [
        "Locus",
        "--ui-test-workspace=\(workspaceURL.path(percentEncoded: false))",
      ],
      environment: ["LOCUS_UI_TESTING": "1"]
    )

    XCTAssertEqual(resolution, .folder(workspaceURL))
  }

  func testLaunchArgumentValuesCollectRepeatedFlagsInBothSupportedForms() {
    let arguments = [
      "Locus",
      "--ui-test-recent-file=/tmp/one.md",
      "--ui-test-recent-file",
      "/tmp/two.md",
    ]

    XCTAssertEqual(
      LaunchArgumentValues.values(named: "--ui-test-recent-file", in: arguments),
      ["/tmp/one.md", "/tmp/two.md"]
    )
  }

  func testUITestingCanOptIntoHomeDefault() throws {
    let homeURL = try temporaryDirectory()

    let resolution = InitialFolderURLResolver.resolution(
      arguments: ["Locus"],
      environment: [
        "LOCUS_UI_TESTING": "1",
        "LOCUS_UI_TEST_HOME_DEFAULT": "1",
      ],
      homeDirectoryURL: homeURL
    )

    XCTAssertEqual(resolution, .folder(homeURL))
  }

  func testUITestingReportsUnavailableForMissingExplicitWorkspace() {
    let missingURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-missing-workspace-\(UUID().uuidString)", directoryHint: .isDirectory)

    let resolution = InitialFolderURLResolver.resolution(
      arguments: [
        "Locus",
        "--ui-test-workspace",
        missingURL.path(percentEncoded: false),
      ],
      environment: ["LOCUS_UI_TESTING": "1"]
    )

    XCTAssertEqual(resolution, .unavailable)
  }

  func testUITestingReportsUnavailableForFileWorkspace() throws {
    let fileURL = try temporaryFile()

    let resolution = InitialFolderURLResolver.resolution(
      arguments: [
        "Locus",
        "--ui-test-workspace",
        fileURL.path(percentEncoded: false),
      ],
      environment: ["LOCUS_UI_TESTING": "1"]
    )

    XCTAssertEqual(resolution, .unavailable)
  }

  func testNormalLaunchReportsUnavailableWhenHomeDirectoryIsMissing() {
    let missingURL = FileManager.default.temporaryDirectory
      .appending(path: "locus-missing-home-\(UUID().uuidString)", directoryHint: .isDirectory)

    let resolution = InitialFolderURLResolver.resolution(
      arguments: ["Locus"],
      environment: [:],
      homeDirectoryURL: missingURL
    )

    XCTAssertEqual(resolution, .unavailable)
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(
        path: "locus-initial-folder-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }

  private func temporaryFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(
        path: "locus-initial-folder-tests-\(UUID().uuidString).txt", directoryHint: .notDirectory)
    try "not a directory".write(to: url, atomically: true, encoding: .utf8)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: url)
    }
    return url
  }
}
