import XCTest

@testable import Locus

final class WorkspaceSidebarSelectionTests: XCTestCase {
  func testVisibleActiveEntryIsHighlighted() {
    let state = WorkspaceSidebarSelectionState(
      activeEntryID: "notes",
      visibleEntryIDs: ["root", "notes"]
    )

    XCTAssertEqual(state.activeEntryID, "notes")
    XCTAssertEqual(state.highlightedEntryID, "notes")
  }

  func testEmptyAreaClickClearsHighlightWithoutClearingActiveEntry() {
    var state = WorkspaceSidebarSelectionState(
      activeEntryID: "notes",
      visibleEntryIDs: ["root", "notes"]
    )

    state.clearHighlightForEmptyAreaClick()

    XCTAssertEqual(state.activeEntryID, "notes")
    XCTAssertNil(state.highlightedEntryID)
  }

  func testSidebarSelectionSetsActiveEntryAndRestoresHighlight() {
    var state = WorkspaceSidebarSelectionState(
      activeEntryID: "notes",
      visibleEntryIDs: ["root", "notes", "brief"]
    )
    state.clearHighlightForEmptyAreaClick()

    state.selectSidebarEntry("brief")

    XCTAssertEqual(state.activeEntryID, "brief")
    XCTAssertEqual(state.highlightedEntryID, "brief")
  }

  func testClearedHighlightStaysClearedAcrossVisibleEntryUpdates() {
    var state = WorkspaceSidebarSelectionState(
      activeEntryID: "notes",
      visibleEntryIDs: ["root", "notes"]
    )
    state.clearHighlightForEmptyAreaClick()

    state.setVisibleEntryIDs(["root", "reports", "notes"])

    XCTAssertEqual(state.activeEntryID, "notes")
    XCTAssertNil(state.highlightedEntryID)
  }

  func testActiveEntryChangeRestoresHighlightWhenVisible() {
    var state = WorkspaceSidebarSelectionState(
      activeEntryID: "notes",
      visibleEntryIDs: ["root", "notes", "brief"]
    )
    state.clearHighlightForEmptyAreaClick()

    state.setActiveEntryID("brief")

    XCTAssertEqual(state.activeEntryID, "brief")
    XCTAssertEqual(state.highlightedEntryID, "brief")
  }

  func testInvisibleActiveEntryIsNotHighlighted() {
    let state = WorkspaceSidebarSelectionState(
      activeEntryID: "nested",
      visibleEntryIDs: ["root", "notes"]
    )

    XCTAssertEqual(state.activeEntryID, "nested")
    XCTAssertNil(state.highlightedEntryID)
  }
}
