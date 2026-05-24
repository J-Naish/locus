import XCTest

@testable import Locus

final class WorkspaceNavigationTests: XCTestCase {
  func testParentFolderURLReturnsParentForNestedFolder() {
    let folderURL = URL(filePath: "/Users/nash/dev", directoryHint: .isDirectory)

    XCTAssertEqual(
      WorkspaceNavigation.parentFolderURL(for: folderURL),
      URL(filePath: "/Users/nash", directoryHint: .isDirectory)
    )
  }

  func testParentFolderURLReturnsNilForRoot() {
    let folderURL = URL(filePath: "/", directoryHint: .isDirectory)

    XCTAssertNil(WorkspaceNavigation.parentFolderURL(for: folderURL))
  }

  func testParentFolderURLNormalizesTrailingSlash() {
    let folderURL = URL(filePath: "/Users/nash/dev/", directoryHint: .isDirectory)

    XCTAssertEqual(
      WorkspaceNavigation.parentFolderURL(for: folderURL),
      URL(filePath: "/Users/nash", directoryHint: .isDirectory)
    )
  }

  func testParentFolderURLReturnsRootForSinglePathComponent() {
    let folderURL = URL(filePath: "/Users", directoryHint: .isDirectory)

    XCTAssertEqual(
      WorkspaceNavigation.parentFolderURL(for: folderURL),
      URL(filePath: "/", directoryHint: .isDirectory)
    )
  }

  func testParentFolderURLDoesNotEscapeRootFolder() {
    let rootURL = URL(filePath: "/Users/nash", directoryHint: .isDirectory)
    let childURL = URL(filePath: "/Users/nash/dev", directoryHint: .isDirectory)

    XCTAssertEqual(
      WorkspaceNavigation.parentFolderURL(for: childURL, within: rootURL),
      rootURL
    )
    XCTAssertNil(WorkspaceNavigation.parentFolderURL(for: rootURL, within: rootURL))
  }

  func testParentFolderURLDoesNotTreatSiblingPrefixAsRoot() {
    let rootURL = URL(filePath: "/Users/nash/dev", directoryHint: .isDirectory)
    let siblingPrefixURL = URL(
      filePath: "/Users/nash/dev-other/project", directoryHint: .isDirectory)

    XCTAssertNil(WorkspaceNavigation.parentFolderURL(for: siblingPrefixURL, within: rootURL))
  }

  func testPathPrefixMatchesRootAndExactPaths() {
    XCTAssertTrue("/Users/nash".locusHasPathPrefix("/"))
    XCTAssertTrue("/Users/nash".locusHasPathPrefix("/Users/nash"))
  }

  func testPathPrefixMatchesNestedPathsWithOrWithoutTrailingSlash() {
    XCTAssertTrue("/Users/nash/dev/locus".locusHasPathPrefix("/Users/nash"))
    XCTAssertTrue("/Users/nash/dev/locus".locusHasPathPrefix("/Users/nash/"))
  }

  func testPathPrefixDoesNotMatchSiblingNames() {
    XCTAssertFalse("/Users/nashville/project".locusHasPathPrefix("/Users/nash"))
  }
}
