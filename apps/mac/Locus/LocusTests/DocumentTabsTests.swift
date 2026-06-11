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
        onClose: { _ in }
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
        onClose: { _ in }
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
        onClose: { _ in }
      )
    )

    layoutHostedView(host)

    XCTAssertEqual(host.fittingSize.width, 300, accuracy: 0.5)
  }

  func testStripFittingWidthHugsContentBelowCap() throws {
    try skipIfHeadlessHostingLayoutIsUnavailable()
    let tab = DocumentTab(entry: makeEntry(path: "/tmp/locus-test/a.md", name: "a.md"))
    let host = NSHostingView(
      rootView: DocumentTabStripView(
        tabs: [tab],
        activeTabID: tab.id,
        maxWidth: 600,
        onSelect: { _ in },
        onClose: { _ in }
      )
    )

    layoutHostedView(host)

    XCTAssertGreaterThan(host.fittingSize.width, 20)
    XCTAssertLessThan(host.fittingSize.width, 250)
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
        onClose: { _ in }
      )
    )
    let activeHost = NSHostingView(
      rootView: DocumentTabStripView(
        tabs: [tab],
        activeTabID: tab.id,
        maxWidth: 600,
        onSelect: { _ in },
        onClose: { _ in }
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

  func testDocumentCardMatchesEditorBackgroundColor() throws {
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      let card = try resolvedSRGB(LocusChromeColors.documentCard, appearanceName: appearanceName)
      let editorBackground = try resolvedSRGB(.textBackgroundColor, appearanceName: appearanceName)

      XCTAssertEqual(card.redComponent, editorBackground.redComponent, accuracy: 0.001)
      XCTAssertEqual(card.greenComponent, editorBackground.greenComponent, accuracy: 0.001)
      XCTAssertEqual(card.blueComponent, editorBackground.blueComponent, accuracy: 0.001)
      XCTAssertEqual(card.alphaComponent, editorBackground.alphaComponent, accuracy: 0.001)
    }
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
