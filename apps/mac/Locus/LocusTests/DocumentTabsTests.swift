import AppKit
import SwiftUI
import XCTest

@testable import Locus

final class DocumentTabsTests: XCTestCase {
  func testRecordOpenAppendsNewTabAtEnd() {
    var state = DocumentTabsState()
    let first = makeEntry(path: "/tmp/locus-test/a.md", name: "a.md")
    let second = makeEntry(path: "/tmp/locus-test/b.md", name: "b.md")

    state.recordOpen(of: first)
    state.recordOpen(of: second)

    XCTAssertEqual(state.tabs.map(\.id), [first.id, second.id])
  }

  func testRecordOpenExistingTabKeepsPositionAndCount() {
    var state = DocumentTabsState()
    let first = makeEntry(path: "/tmp/locus-test/a.md", name: "a.md")
    let second = makeEntry(path: "/tmp/locus-test/b.md", name: "b.md")

    state.recordOpen(of: first)
    state.recordOpen(of: second)
    state.recordOpen(of: first)

    XCTAssertEqual(state.tabs.map(\.id), [first.id, second.id])
  }

  func testRecordOpenRefreshesStoredEntryMetadata() {
    var state = DocumentTabsState()
    let original = makeEntry(path: "/tmp/locus-test/a.md", name: "a.md")
    let refreshed = makeEntry(path: "/tmp/locus-test/a.md", name: "renamed.md")

    state.recordOpen(of: original)
    state.recordOpen(of: refreshed)

    XCTAssertEqual(state.tabs.map(\.name), ["renamed.md"])
  }

  func testCloseActiveTabActivatesRightNeighbor() {
    var state = stateWithEntries(["a.md", "b.md", "c.md"])

    let outcome = state.closeTab(
      withID: "/tmp/locus-test/b.md", activeTabID: "/tmp/locus-test/b.md")

    XCTAssertEqual(
      outcome, .activate(DocumentTab(entry: makeEntry(path: "/tmp/locus-test/c.md", name: "c.md"))))
    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/a.md", "/tmp/locus-test/c.md"])
  }

  func testCloseActiveRightmostTabActivatesLeftNeighbor() {
    var state = stateWithEntries(["a.md", "b.md", "c.md"])

    let outcome = state.closeTab(
      withID: "/tmp/locus-test/c.md", activeTabID: "/tmp/locus-test/c.md")

    XCTAssertEqual(
      outcome, .activate(DocumentTab(entry: makeEntry(path: "/tmp/locus-test/b.md", name: "b.md"))))
    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/a.md", "/tmp/locus-test/b.md"])
  }

  func testCloseOnlyTabShowsEmpty() {
    var state = stateWithEntries(["a.md"])

    let outcome = state.closeTab(
      withID: "/tmp/locus-test/a.md", activeTabID: "/tmp/locus-test/a.md")

    XCTAssertEqual(outcome, .showEmpty)
    XCTAssertTrue(state.tabs.isEmpty)
  }

  func testCloseInactiveTabKeepsCurrent() {
    var state = stateWithEntries(["a.md", "b.md"])

    let outcome = state.closeTab(
      withID: "/tmp/locus-test/b.md", activeTabID: "/tmp/locus-test/a.md")

    XCTAssertEqual(outcome, .keepCurrent)
    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/a.md"])
  }

  func testCloseUnknownTabIDKeepsCurrent() {
    var state = stateWithEntries(["a.md"])

    let outcome = state.closeTab(
      withID: "/tmp/locus-test/missing.md", activeTabID: "/tmp/locus-test/a.md")

    XCTAssertEqual(outcome, .keepCurrent)
    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/a.md"])
  }

  func testPrepareForWorkspaceFirstFolderStartsEmpty() {
    var state = DocumentTabsState()

    state.prepareForWorkspace(URL(filePath: "/tmp/locus-test"))

    XCTAssertEqual(state.folderURL?.locusStandardizedPath, "/tmp/locus-test")
    XCTAssertTrue(state.tabs.isEmpty)
  }

  func testPrepareForWorkspaceSameFolderKeepsTabs() {
    var state = DocumentTabsState()
    let folderURL = URL(filePath: "/tmp/locus-test")

    state.prepareForWorkspace(folderURL)
    state.recordOpen(of: makeEntry(path: "/tmp/locus-test/a.md", name: "a.md"))
    state.prepareForWorkspace(URL(filePath: "/tmp/locus-test/."))

    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/a.md"])
  }

  func testPrepareForWorkspaceNewFolderClearsTabs() {
    var state = stateWithEntries(["a.md"])

    state.prepareForWorkspace(URL(filePath: "/tmp/locus-test"))
    state.prepareForWorkspace(URL(filePath: "/tmp/other-locus-test"))

    XCTAssertTrue(state.tabs.isEmpty)
    XCTAssertEqual(state.folderURL?.locusStandardizedPath, "/tmp/other-locus-test")
  }

  func testCloseTabsUnderPathRemovesExactFileTab() {
    var state = stateWithEntries(["a.md", "b.md"])

    state.closeTabs(underPath: "/tmp/locus-test/a.md")

    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/b.md"])
  }

  func testCloseTabsUnderPathRemovesDescendantTabsOfDeletedFolder() {
    var state = DocumentTabsState()
    state.recordOpen(of: makeEntry(path: "/tmp/locus-test/docs/a.md", name: "a.md"))
    state.recordOpen(of: makeEntry(path: "/tmp/locus-test/docs/nested/b.md", name: "b.md"))
    state.recordOpen(of: makeEntry(path: "/tmp/locus-test/root.md", name: "root.md"))

    state.closeTabs(underPath: "/tmp/locus-test/docs")

    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/root.md"])
  }

  func testCloseTabsUnderPathIgnoresSiblingPrefixFolders() {
    var state = DocumentTabsState()
    state.recordOpen(of: makeEntry(path: "/tmp/locus-test/docs/a.md", name: "a.md"))
    state.recordOpen(of: makeEntry(path: "/tmp/locus-test/docs2/c.md", name: "c.md"))

    state.closeTabs(underPath: "/tmp/locus-test/docs")

    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/docs2/c.md"])
  }

  func testCloseTabsUnderPathNeverActivatesANeighbor() {
    var state = stateWithEntries(["a.md", "b.md"])

    state.closeTabs(underPath: "/tmp/locus-test/a.md")

    XCTAssertEqual(state.tabs.map(\.id), ["/tmp/locus-test/b.md"])
  }

  // MARK: Reordering

  func testMoveTabForwardInsertsBeforeTheTarget() {
    var state = stateWithEntries(["a.md", "b.md", "c.md"])

    state.moveTab(withID: "/tmp/locus-test/a.md", before: "/tmp/locus-test/c.md")

    XCTAssertEqual(
      state.tabs.map(\.id),
      ["/tmp/locus-test/b.md", "/tmp/locus-test/a.md", "/tmp/locus-test/c.md"]
    )
  }

  func testMoveTabBackwardInsertsBeforeTheTarget() {
    var state = stateWithEntries(["a.md", "b.md", "c.md"])

    state.moveTab(withID: "/tmp/locus-test/c.md", before: "/tmp/locus-test/a.md")

    XCTAssertEqual(
      state.tabs.map(\.id),
      ["/tmp/locus-test/c.md", "/tmp/locus-test/a.md", "/tmp/locus-test/b.md"]
    )
  }

  func testMoveTabBeforeNilMovesToTheEnd() {
    var state = stateWithEntries(["a.md", "b.md", "c.md"])

    state.moveTab(withID: "/tmp/locus-test/a.md", before: nil)

    XCTAssertEqual(
      state.tabs.map(\.id),
      ["/tmp/locus-test/b.md", "/tmp/locus-test/c.md", "/tmp/locus-test/a.md"]
    )
  }

  func testMoveTabBeforeItselfOrItsFollowerKeepsTheOrder() {
    var state = stateWithEntries(["a.md", "b.md", "c.md"])
    let original = state.tabs.map(\.id)

    state.moveTab(withID: "/tmp/locus-test/a.md", before: "/tmp/locus-test/a.md")
    XCTAssertEqual(state.tabs.map(\.id), original)

    state.moveTab(withID: "/tmp/locus-test/a.md", before: "/tmp/locus-test/b.md")
    XCTAssertEqual(state.tabs.map(\.id), original)
  }

  func testMoveTabIgnoresUnknownDraggedOrTargetIDs() {
    var state = stateWithEntries(["a.md", "b.md"])
    let original = state.tabs.map(\.id)

    state.moveTab(withID: "/tmp/locus-test/missing.md", before: "/tmp/locus-test/a.md")
    XCTAssertEqual(state.tabs.map(\.id), original)

    state.moveTab(withID: "/tmp/locus-test/a.md", before: "/tmp/locus-test/missing.md")
    XCTAssertEqual(state.tabs.map(\.id), original)
  }

  // MARK: Live-reorder swap geometry

  // Chips [100, 80, 120] wide with 6pt spacing; the dragged chip swaps with a
  // neighbor once its displacement crosses that neighbor's midpoint, i.e.
  // (neighborWidth + spacing) / 2.
  func testSwapStepStaysPutBelowTheNeighborMidpoint() {
    XCTAssertNil(
      DocumentTabReorder.swapStep(
        widths: [100, 80, 120], draggedIndex: 1, displacement: 62, spacing: 6))
    XCTAssertNil(
      DocumentTabReorder.swapStep(
        widths: [100, 80, 120], draggedIndex: 1, displacement: -52, spacing: 6))
  }

  func testSwapStepSwapsRightPastTheNextChipMidpoint() {
    XCTAssertEqual(
      DocumentTabReorder.swapStep(
        widths: [100, 80, 120], draggedIndex: 1, displacement: 64, spacing: 6),
      1
    )
  }

  func testSwapStepSwapsLeftPastThePreviousChipMidpoint() {
    XCTAssertEqual(
      DocumentTabReorder.swapStep(
        widths: [100, 80, 120], draggedIndex: 1, displacement: -54, spacing: 6),
      -1
    )
  }

  func testSwapStepNeverLeavesTheStripEnds() {
    XCTAssertNil(
      DocumentTabReorder.swapStep(
        widths: [100, 80, 120], draggedIndex: 0, displacement: -500, spacing: 6))
    XCTAssertNil(
      DocumentTabReorder.swapStep(
        widths: [100, 80, 120], draggedIndex: 2, displacement: 500, spacing: 6))
  }

  func testSwapStepIgnoresUnmeasuredNeighbors() {
    XCTAssertNil(
      DocumentTabReorder.swapStep(
        widths: [100, 80, 0], draggedIndex: 1, displacement: 500, spacing: 6))
  }

  // MARK: Auto-scroll edge speed

  // Viewport 100...500, edge zone 28, max speed 10: the strip scrolls while
  // the pointer drags within an edge zone, faster the deeper it goes.
  func testAutoScrollSpeedIsZeroAwayFromTheEdges() {
    XCTAssertEqual(
      DocumentTabReorder.autoScrollSpeed(
        pointerX: 300, viewportMinX: 100, viewportMaxX: 500, edgeZone: 28, maxSpeed: 10),
      0
    )
  }

  func testAutoScrollSpeedRampsUpInsideTheLeftZone() {
    // Halfway into the left zone: half the maximum speed, leftward.
    XCTAssertEqual(
      DocumentTabReorder.autoScrollSpeed(
        pointerX: 114, viewportMinX: 100, viewportMaxX: 500, edgeZone: 28, maxSpeed: 10),
      -5,
      accuracy: 0.001
    )
  }

  func testAutoScrollSpeedRampsUpInsideTheRightZone() {
    XCTAssertEqual(
      DocumentTabReorder.autoScrollSpeed(
        pointerX: 486, viewportMinX: 100, viewportMaxX: 500, edgeZone: 28, maxSpeed: 10),
      5,
      accuracy: 0.001
    )
  }

  func testAutoScrollSpeedClampsBeyondTheViewport() {
    XCTAssertEqual(
      DocumentTabReorder.autoScrollSpeed(
        pointerX: -50, viewportMinX: 100, viewportMaxX: 500, edgeZone: 28, maxSpeed: 10),
      -10
    )
    XCTAssertEqual(
      DocumentTabReorder.autoScrollSpeed(
        pointerX: 900, viewportMinX: 100, viewportMaxX: 500, edgeZone: 28, maxSpeed: 10),
      10
    )
  }
}

@MainActor
final class DocumentTabStripViewTests: XCTestCase {
  func testHostingViewLayoutProbeWorksHeadlessly() throws {
    let host = NSHostingView(rootView: Text("x"))
    host.layoutSubtreeIfNeeded()

    XCTAssertGreaterThan(host.fittingSize.height, 0)
  }

  func testStripIsContentSizedForToolbarHosting() throws {
    try skipIfHeadlessHostingLayoutIsUnavailable()
    let tab = DocumentTab(entry: makeEntry(path: "/tmp/locus-test/a.md", name: "a.md"))
    let host = NSHostingView(
      rootView: DocumentTabStripView(
        tabs: [tab],
        activeTabID: tab.id,
        maxWidth: 600,
        onSelect: { _ in },
        onClose: { _ in },
        onMove: { _, _ in }
      )
    )

    layoutHostedView(host)

    XCTAssertGreaterThan(host.fittingSize.height, 20)
    XCTAssertLessThan(host.fittingSize.height, 38)
  }

  func testEmptyStripCollapsesToZeroWidth() throws {
    try skipIfHeadlessHostingLayoutIsUnavailable()
    let host = NSHostingView(
      rootView: DocumentTabStripView(
        tabs: [],
        activeTabID: nil,
        maxWidth: 600,
        onSelect: { _ in },
        onClose: { _ in },
        onMove: { _, _ in }
      )
    )

    layoutHostedView(host)

    XCTAssertEqual(host.fittingSize.width, 0, accuracy: 0.5)
  }

  func testStripFittingWidthIsCappedAtMaxWidth() throws {
    try skipIfHeadlessHostingLayoutIsUnavailable()
    let tabs = (0..<8).map { index in
      DocumentTab(
        entry: makeEntry(
          path: "/tmp/locus-test/very-long-document-name-\(index).md",
          name: "very-long-document-name-\(index).md"
        ))
    }
    let host = NSHostingView(
      rootView: DocumentTabStripView(
        tabs: tabs,
        activeTabID: tabs[0].id,
        maxWidth: 300,
        onSelect: { _ in },
        onClose: { _ in },
        onMove: { _, _ in }
      )
    )

    layoutHostedView(host)

    XCTAssertEqual(host.fittingSize.width, 300, accuracy: 0.5)
  }

  func testStripFillsTheAvailableWidthEvenWithOneShortTab() throws {
    try skipIfHeadlessHostingLayoutIsUnavailable()
    // A single short tab no longer hugs its content: the strip spans the full
    // available width so the header reads as one continuous band and the empty
    // trailing area still accepts drags.
    let tab = DocumentTab(entry: makeEntry(path: "/tmp/locus-test/a.md", name: "a.md"))
    let host = NSHostingView(
      rootView: DocumentTabStripView(
        tabs: [tab],
        activeTabID: tab.id,
        maxWidth: 600,
        onSelect: { _ in },
        onClose: { _ in },
        onMove: { _, _ in }
      )
    )

    layoutHostedView(host)

    XCTAssertEqual(host.fittingSize.width, 600, accuracy: 0.5)
  }

  func testStripFittingWidthIsStableWhenTabBecomesActive() throws {
    try skipIfHeadlessHostingLayoutIsUnavailable()
    let tab = DocumentTab(
      entry: makeEntry(
        path: "/tmp/locus-test/planning-notes.md",
        name: "planning-notes.md"
      ))

    let inactiveHost = NSHostingView(
      rootView: DocumentTabStripView(
        tabs: [tab],
        activeTabID: nil,
        maxWidth: 600,
        onSelect: { _ in },
        onClose: { _ in },
        onMove: { _, _ in }
      )
    )
    let activeHost = NSHostingView(
      rootView: DocumentTabStripView(
        tabs: [tab],
        activeTabID: tab.id,
        maxWidth: 600,
        onSelect: { _ in },
        onClose: { _ in },
        onMove: { _, _ in }
      )
    )

    layoutHostedView(inactiveHost)
    layoutHostedView(activeHost)

    XCTAssertEqual(inactiveHost.fittingSize.width, activeHost.fittingSize.width, accuracy: 0.5)
  }

  private func skipIfHeadlessHostingLayoutIsUnavailable() throws {
    let host = NSHostingView(rootView: Text("x"))
    host.layoutSubtreeIfNeeded()
    if host.fittingSize.height <= 0 {
      throw XCTSkip("NSHostingView did not produce a headless fitting size.")
    }
  }

  private func layoutHostedView(_ host: NSView) {
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
  }
}

@MainActor
final class LocusChromeColorsTests: XCTestCase {
  func testDocumentFieldIsDarkerThanCardInBothAppearances() throws {
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      let card = try resolvedSRGB(LocusChromeColors.documentCard, appearanceName: appearanceName)
      let field = try resolvedSRGB(LocusChromeColors.documentField, appearanceName: appearanceName)

      XCTAssertGreaterThanOrEqual(
        card.redComponent - field.redComponent,
        8.0 / 255.0,
        "Expected document field to stay visibly darker than the card in \(appearanceName)."
      )
    }
  }

  func testDocumentFieldIsOpaque() throws {
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      let field = try resolvedSRGB(LocusChromeColors.documentField, appearanceName: appearanceName)

      XCTAssertEqual(field.alphaComponent, 1.0, accuracy: 0.001)
    }
  }

  // The standard theme's light card is the system editor white, so its editor
  // (which fills with documentCard) reads identical to the pre-theme look.
  func testStandardThemeCardIsTheSystemEditorWhiteInLight() throws {
    let card = try resolvedSRGB(LocusChromeColors.standard.documentCard, appearanceName: .aqua)
    let editorWhite = try resolvedSRGB(.textBackgroundColor, appearanceName: .aqua)

    XCTAssertEqual(card.redComponent, editorWhite.redComponent, accuracy: 0.001)
    XCTAssertEqual(card.greenComponent, editorWhite.greenComponent, accuracy: 0.001)
    XCTAssertEqual(card.blueComponent, editorWhite.blueComponent, accuracy: 0.001)
  }

  // The standard theme's dark card is a fixed, neutral, black-based color —
  // not the system dark gray, which absorbs the desktop wallpaper tint on a
  // real window and reads brown.
  func testStandardThemeCardIsAFixedNeutralBlackInDark() throws {
    let card = try resolvedSRGB(LocusChromeColors.standard.documentCard, appearanceName: .darkAqua)
    let systemDark = try resolvedSRGB(.textBackgroundColor, appearanceName: .darkAqua)

    XCTAssertLessThan(card.redComponent, systemDark.redComponent - 0.02)
    XCTAssertLessThan(card.redComponent, 0.15)
    XCTAssertEqual(card.redComponent, card.greenComponent, accuracy: 0.01)
    XCTAssertEqual(card.greenComponent, card.blueComponent, accuracy: 0.01)
  }

  // The paper theme is the warm, ivory-on-slate palette: a warm off-white card
  // (red above blue, never pure white) on a warmer, darker field in light, and
  // a warm near-black slate in dark.
  func testPaperThemeIsWarmInLight() throws {
    let card = try resolvedSRGB(LocusChromeColors.paper.documentCard, appearanceName: .aqua)
    let field = try resolvedSRGB(LocusChromeColors.paper.documentField, appearanceName: .aqua)

    XCTAssertGreaterThan(card.redComponent, 0.9)
    XCTAssertLessThan(card.redComponent, 1.0)
    XCTAssertGreaterThan(card.redComponent, card.blueComponent)  // warm
    XCTAssertLessThan(field.redComponent, card.redComponent)  // field darker
    XCTAssertGreaterThan(field.redComponent, field.blueComponent)  // warm
  }

  func testPaperThemeIsWarmSlateInDark() throws {
    let card = try resolvedSRGB(LocusChromeColors.paper.documentCard, appearanceName: .darkAqua)
    let field = try resolvedSRGB(LocusChromeColors.paper.documentField, appearanceName: .darkAqua)

    XCTAssertLessThan(card.redComponent, 0.2)
    XCTAssertGreaterThanOrEqual(card.redComponent, card.blueComponent)  // warm
    XCTAssertLessThan(field.redComponent, card.redComponent)  // field darker
  }

  // The paper theme's active tab carries the clay (book-cloth) accent — the
  // palette's signature warm terracotta — in both appearances.
  func testPaperThemeActiveTabUsesAWarmClayAccent() throws {
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      let stroke = try resolvedSRGB(
        LocusChromeColors.paper.activeTabStroke, appearanceName: appearanceName)

      XCTAssertGreaterThan(stroke.redComponent, stroke.blueComponent + 0.15)  // clearly warm
      XCTAssertGreaterThan(stroke.redComponent, 0.5)  // a mid-tone clay, not near black/white
    }
  }

  // The active tab is a solid, saturated clay — bold enough to read as the
  // brand accent at a glance, not a pale wash.
  func testPaperThemeActiveTabFillIsASaturatedClay() throws {
    let fill = try resolvedSRGB(LocusChromeColors.paper.activeTabFill, appearanceName: .aqua)

    XCTAssertGreaterThan(fill.redComponent, 0.6)
    XCTAssertGreaterThan(fill.redComponent - fill.blueComponent, 0.2)
  }

  // The active tab's text is light so it reads against the solid clay fill.
  func testPaperThemeActiveTabTextIsLight() throws {
    let text = try resolvedSRGB(LocusChromeColors.paper.activeTabText, appearanceName: .aqua)

    XCTAssertGreaterThan(text.redComponent, 0.85)
    XCTAssertGreaterThan(text.greenComponent, 0.85)
    XCTAssertGreaterThan(text.blueComponent, 0.85)
  }

  // The standard theme's active tab keeps its neutral look: the fill is the
  // card and the stroke is the system separator (no accent).
  func testStandardThemeActiveTabIsNeutral() throws {
    let fill = try resolvedSRGB(LocusChromeColors.standard.activeTabFill, appearanceName: .aqua)
    let card = try resolvedSRGB(LocusChromeColors.standard.documentCard, appearanceName: .aqua)

    XCTAssertEqual(fill.redComponent, card.redComponent, accuracy: 0.001)
    XCTAssertEqual(fill.greenComponent, card.greenComponent, accuracy: 0.001)
    XCTAssertEqual(fill.blueComponent, card.blueComponent, accuracy: 0.001)
  }

  // The paper theme is the active palette: the public chrome colors resolve to
  // it, so the app shows the warm look.
  func testActiveChromeResolvesToThePaperTheme() throws {
    let card = try resolvedSRGB(LocusChromeColors.documentCard, appearanceName: .aqua)
    let paperCard = try resolvedSRGB(LocusChromeColors.paper.documentCard, appearanceName: .aqua)

    XCTAssertEqual(card.redComponent, paperCard.redComponent, accuracy: 0.001)
    XCTAssertEqual(card.greenComponent, paperCard.greenComponent, accuracy: 0.001)
    XCTAssertEqual(card.blueComponent, paperCard.blueComponent, accuracy: 0.001)
  }

  private func resolvedSRGB(
    _ color: NSColor,
    appearanceName: NSAppearance.Name
  ) throws -> NSColor {
    let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance {
      resolved = color.usingColorSpace(.sRGB)
    }
    return try XCTUnwrap(resolved)
  }
}

@MainActor
final class DocumentCardModifierTests: XCTestCase {
  func testDocumentCardModifierMasksHostedAppKitViewCornersAndShowsContent() throws {
    let host = NSHostingView(
      rootView: RedAppKitView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(DocumentCardModifier())
    )
    host.appearance = NSAppearance(named: .aqua)
    host.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    host.layoutSubtreeIfNeeded()

    let imageRep = try XCTUnwrap(
      host.bitmapImageRepForCachingDisplay(in: host.bounds),
      "Expected offscreen rendering to create a bitmap representation."
    )
    host.cacheDisplay(in: host.bounds, to: imageRep)
    guard imageRep.pixelsWide > 0, imageRep.pixelsHigh > 0 else {
      throw XCTSkip("Offscreen rendering produced an empty bitmap.")
    }

    // Sample in points regardless of the bitmap's backing scale.
    let scale = max(1, imageRep.pixelsWide / Int(host.bounds.width))
    let center = try XCTUnwrap(imageRep.colorAt(x: 100 * scale, y: 100 * scale))
    let corner = try XCTUnwrap(
      imageRep.colorAt(
        x: (Int(DocumentCardMetrics.horizontalInset) + 1) * scale,
        y: (Int(DocumentCardMetrics.topInset) + 1) * scale
      )
    )

    // The hosted red content shows through the card interior...
    XCTAssertGreaterThan(center.redComponent, 0.8)
    XCTAssertLessThan(center.greenComponent, 0.3)
    // ...while the top-left corner notch is covered by the field-colored cap
    // (an opaque light gray), not the red content.
    XCTAssertGreaterThan(corner.greenComponent, 0.8)
  }

  // The card floats inside the window like the sidebar panel does: gaps on
  // the sides and bottom (matching the sidebar's gutter), a thin top gap, and
  // rounded corners on all four sides.
  func testDocumentCardFloatsWithGapsAndRoundedCornersOnAllSides() throws {
    let host = NSHostingView(
      rootView: RedAppKitView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(DocumentCardModifier())
    )
    host.appearance = NSAppearance(named: .aqua)
    host.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
    host.layoutSubtreeIfNeeded()

    let imageRep = try XCTUnwrap(
      host.bitmapImageRepForCachingDisplay(in: host.bounds),
      "Expected offscreen rendering to create a bitmap representation."
    )
    host.cacheDisplay(in: host.bounds, to: imageRep)
    guard imageRep.pixelsWide > 0, imageRep.pixelsHigh > 0 else {
      throw XCTSkip("Offscreen rendering produced an empty bitmap.")
    }

    let scale = max(1, imageRep.pixelsWide / Int(host.bounds.width))
    func sample(_ x: Int, _ y: Int) throws -> NSColor {
      try XCTUnwrap(imageRep.colorAt(x: x * scale, y: y * scale))
    }

    // The bottom gap matches the sidebar's gutter: transparent padding below
    // the card.
    XCTAssertLessThan(try sample(100, 197).alphaComponent, 0.5)
    // The bottom-left corner is rounded again: its notch shows the
    // field-colored cap, not the red card content.
    XCTAssertGreaterThan(
      try sample(
        Int(DocumentCardMetrics.horizontalInset) + 1,
        198 - Int(DocumentCardMetrics.bottomInset)
      ).greenComponent,
      0.8
    )
    // The side gap keeps the field visible left of the card.
    XCTAssertLessThan(try sample(4, 100).alphaComponent, 0.5)
    // The card runs all the way to the top edge, flush under the header band.
    let topEdge = try sample(100, 0)
    XCTAssertGreaterThan(topEdge.alphaComponent, 0.5)
    XCTAssertLessThan(topEdge.greenComponent, 0.3)
  }
}

private struct RedAppKitView: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.red.cgColor
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    nsView.layer?.backgroundColor = NSColor.red.cgColor
  }
}

private func stateWithEntries(_ names: [String]) -> DocumentTabsState {
  var state = DocumentTabsState()
  for name in names {
    state.recordOpen(of: makeEntry(path: "/tmp/locus-test/\(name)", name: name))
  }
  return state
}

private func makeEntry(
  path: String,
  name: String,
  modified: Date? = nil
) -> WorkspaceEntry {
  let url = URL(filePath: path)
  return WorkspaceEntry(
    id: url.locusStandardizedPath,
    url: url,
    name: name,
    kind: .file,
    fileType: .markdown,
    sizeBytes: nil,
    modified: modified,
    isReadOnly: false
  )
}
