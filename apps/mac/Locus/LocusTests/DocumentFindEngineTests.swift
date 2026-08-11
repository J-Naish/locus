import AppKit
import XCTest

@testable import Locus

final class DocumentFindEngineTests: XCTestCase {
  func testPlainLinesMatchCaseInsensitivelyAndNonOverlapping() {
    let lines = [
      "Alpha alpha ALPHA",
      "aaaa",
      "beta",
    ]

    let result = DocumentFindEngine.scan(
      lineCount: lines.count,
      lineProvider: { lines[$0] },
      query: "alpha"
    )
    let repeated = DocumentFindEngine.scan(
      lineCount: 1,
      lineProvider: { _ in lines[1] },
      query: "aa"
    )

    XCTAssertEqual(result.matches.map(\.line), [0, 0, 0])
    XCTAssertEqual(
      result.matches.map(\.range),
      [
        NSRange(location: 0, length: 5),
        NSRange(location: 6, length: 5),
        NSRange(location: 12, length: 5),
      ])
    XCTAssertEqual(
      repeated.matches.map(\.range),
      [
        NSRange(location: 0, length: 2),
        NSRange(location: 2, length: 2),
      ])
    XCTAssertFalse(result.capped)
  }

  func testMarkdownDisplaySpaceConcealsEmphasisMarkers() {
    let line = "**bold**"
    let display = DocumentFindDisplayText.markdownDisplayText(
      for: line,
      state: TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    )

    let bold = DocumentFindEngine.scan(lineCount: 1, lineProvider: { _ in display }, query: "bold")
    let doubleMarkers = DocumentFindEngine.scan(
      lineCount: 1,
      lineProvider: { _ in display },
      query: "**"
    )
    let singleMarker = DocumentFindEngine.scan(
      lineCount: 1,
      lineProvider: { _ in display },
      query: "*"
    )

    XCTAssertEqual(
      bold.matches,
      [
        DocumentFindMatch(line: 0, range: NSRange(location: 0, length: 4))
      ])
    XCTAssertTrue(doubleMarkers.matches.isEmpty)
    XCTAssertTrue(singleMarker.matches.isEmpty)
  }

  func testMarkdownEntitiesMatchDecodedDisplayText() {
    let line = "AT&amp;T"
    let display = DocumentFindDisplayText.markdownDisplayText(
      for: line,
      state: TextDocumentSyntaxHighlighter.markdownLineStates(for: [line])[0]
    )

    let decoded = DocumentFindEngine.scan(
      lineCount: 1, lineProvider: { _ in display }, query: "AT&T")
    let sourceEntity = DocumentFindEngine.scan(
      lineCount: 1,
      lineProvider: { _ in display },
      query: "&amp;"
    )

    XCTAssertEqual(
      decoded.matches,
      [
        DocumentFindMatch(line: 0, range: NSRange(location: 0, length: 4))
      ])
    XCTAssertTrue(sourceEntity.matches.isEmpty)
  }

  func testCaseInsensitiveSearchDoesNotFoldJapaneseDakuten() {
    let lines = ["が", "テスト"]

    let dakuten = DocumentFindEngine.scan(
      lineCount: lines.count,
      lineProvider: { lines[$0] },
      query: "か"
    )
    let katakana = DocumentFindEngine.scan(
      lineCount: lines.count,
      lineProvider: { lines[$0] },
      query: "テスト"
    )

    XCTAssertTrue(dakuten.matches.isEmpty)
    XCTAssertEqual(
      katakana.matches,
      [
        DocumentFindMatch(line: 1, range: NSRange(location: 0, length: 3))
      ])
  }

  func testMarkdownDisplayTextMatchesRendererForAllSyntaxFixture() throws {
    let fixture = try fixtureURL(path: "markdown/all-syntax.md")
    let text = try String(contentsOf: fixture, encoding: .utf8)
    let lines = text.components(separatedBy: "\n")
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let typography = MarkdownTypography(baseFont: TextDocumentSyntax.markdown.font)

    for index in lines.indices {
      let state = index < states.count ? states[index] : .plain
      let searched = DocumentFindDisplayText.markdownDisplayText(for: lines[index], state: state)
      let rendered = TextDocumentSyntaxHighlighter.renderedMarkdownLineText(
        lines[index],
        font: TextDocumentSyntax.markdown.font,
        state: state,
        typography: typography
      )
      XCTAssertEqual(searched, rendered, "line \(index)")
    }
  }

  func testMarkerOnlyMarkdownRowsProduceNoMatches() {
    let lines = [
      "```",
      "let value = 1",
      "```",
      "Title",
      "---",
      "| Left | Right |",
      "| --- | --- |",
      "| A | B |",
      "***",
    ]
    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let display = lines.indices.map {
      DocumentFindDisplayText.markdownDisplayText(for: lines[$0], state: states[$0])
    }

    let markerRows: [(line: Int, marker: String)] = [
      (0, "```"),
      (2, "```"),
      (4, "---"),
      (6, "|"),
      (8, "***"),
    ]
    for row in markerRows {
      XCTAssertEqual(display[row.line], "", "line \(row.line)")
      let result = DocumentFindEngine.scan(
        lineCount: 1,
        lineProvider: { _ in display[row.line] },
        query: row.marker
      )
      XCTAssertTrue(result.matches.isEmpty, row.marker)
    }
  }

  func testMatchCapStopsAtMaximumAndReportsCapped() {
    let lineCount = documentFindMaximumMatches + 25
    let result = DocumentFindEngine.scan(
      lineCount: lineCount,
      lineProvider: { _ in "needle" },
      query: "needle"
    )

    XCTAssertEqual(result.matches.count, documentFindMaximumMatches)
    XCTAssertEqual(
      result.matches.first, DocumentFindMatch(line: 0, range: NSRange(location: 0, length: 6)))
    XCTAssertEqual(
      result.matches.last,
      DocumentFindMatch(
        line: documentFindMaximumMatches - 1,
        range: NSRange(location: 0, length: 6))
    )
    XCTAssertTrue(result.capped)
  }

  func testScanDeadlineReturnsPartialCappedResults() {
    let lineCount = 1_024
    let result = DocumentFindEngine.scan(
      lineCount: lineCount,
      lineProvider: { _ in "needle" },
      query: "needle",
      deadline: .zero)

    XCTAssertTrue(result.capped)
    XCTAssertGreaterThan(result.matches.count, 0)
    XCTAssertLessThan(result.matches.count, lineCount)
    XCTAssertEqual(
      DocumentFindPresentation.findCountLabel(
        query: "needle",
        matches: result.matches,
        currentMatchIndex: 0,
        capped: result.capped),
      "1/\(result.matches.count)+")
  }

  func testFirstMatchAtOrAfterPositionWrapsWhenNoneFollows() {
    let matches = [
      DocumentFindMatch(line: 0, range: NSRange(location: 4, length: 2)),
      DocumentFindMatch(line: 2, range: NSRange(location: 1, length: 2)),
      DocumentFindMatch(line: 2, range: NSRange(location: 9, length: 2)),
    ]

    XCTAssertEqual(
      DocumentFindEngine.firstMatchIndex(
        atOrAfter: DocumentFindPosition(line: 0, columnUTF16: 4),
        in: matches
      ),
      0
    )
    XCTAssertEqual(
      DocumentFindEngine.firstMatchIndex(
        atOrAfter: DocumentFindPosition(line: 2, columnUTF16: 2),
        in: matches
      ),
      2
    )
    XCTAssertEqual(
      DocumentFindEngine.firstMatchIndex(
        atOrAfter: DocumentFindPosition(line: 9, columnUTF16: 0),
        in: matches
      ),
      0
    )
  }

  func testNextAndPreviousMatchIndicesWrapAroundBothEnds() {
    XCTAssertEqual(DocumentFindEngine.nextIndex(after: nil, matchCount: 3), 0)
    XCTAssertEqual(DocumentFindEngine.nextIndex(after: 0, matchCount: 3), 1)
    XCTAssertEqual(DocumentFindEngine.nextIndex(after: 2, matchCount: 3), 0)
    XCTAssertEqual(DocumentFindEngine.previousIndex(before: nil, matchCount: 3), 2)
    XCTAssertEqual(DocumentFindEngine.previousIndex(before: 2, matchCount: 3), 1)
    XCTAssertEqual(DocumentFindEngine.previousIndex(before: 0, matchCount: 3), 2)
    XCTAssertNil(DocumentFindEngine.nextIndex(after: nil, matchCount: 0))
    XCTAssertNil(DocumentFindEngine.previousIndex(before: nil, matchCount: 0))
  }

  @MainActor
  func testPassiveRescanUpdatesMatchesWithoutMovingSelection() throws {
    let view = try makeEditableMarkdownViewer("foo xx foo")
    let state = DocumentFindState()
    state.registerDocumentView(view)
    state.showFindBar()
    state.updateFindQuery("foo")
    state.flushPendingSearchForTesting()
    XCTAssertEqual(state.matches.count, 2)

    view.beginCaretSelection(at: .init(line: 0, columnUTF16: 4))
    view.insertText("foo ")
    let selectionAfterEdit = try XCTUnwrap(view.selection)

    state.documentDidChange()
    state.flushPendingSearchForTesting()

    XCTAssertEqual(state.matches.count, 3)
    XCTAssertEqual(view.selection, selectionAfterEdit)
  }

  @MainActor
  func testNavigationDuringPendingSearchSelectsFirstMatch() throws {
    let view = try makeEditableMarkdownViewer("foo xx foo")
    let state = DocumentFindState()
    state.registerDocumentView(view)
    state.showFindBar()
    state.updateFindQuery("foo")

    state.selectSearch(.next)

    XCTAssertEqual(state.currentMatchIndex, 0)
    XCTAssertEqual(
      view.selection,
      TextSelection(
        anchor: .init(line: 0, columnUTF16: 0),
        head: .init(line: 0, columnUTF16: 3)))
  }

  @MainActor
  func testMarkdownDisplayTextMemoReusesRevisionAndInvalidatesAfterEdit() throws {
    let view = try makeEditableMarkdownViewer("needle\n**needle**\nneedle")

    _ = view.documentFindResult(for: "needle")
    let productionCountAfterColdSearch =
      view.documentFindDisplayTextProductionCountForTesting
    XCTAssertGreaterThan(productionCountAfterColdSearch, 0)

    _ = view.documentFindResult(for: "needle")
    XCTAssertEqual(
      view.documentFindDisplayTextProductionCountForTesting,
      productionCountAfterColdSearch)

    view.beginCaretSelection(at: .init(line: 0, columnUTF16: 0))
    view.insertText("x")
    _ = view.documentFindResult(for: "needle")

    XCTAssertGreaterThan(
      view.documentFindDisplayTextProductionCountForTesting,
      productionCountAfterColdSearch)
  }

  @MainActor
  func testSyntheticMarkdownScanCompletesWithinDebugBudget() throws {
    let lines = syntheticMarkdownLines(count: 5_000)
    let view = try makeEditableMarkdownViewer(lines.joined(separator: "\n"))

    let coldStart = ProcessInfo.processInfo.systemUptime
    let coldResult = view.documentFindResult(for: "needle")
    let coldElapsedMs = (ProcessInfo.processInfo.systemUptime - coldStart) * 1_000
    let coldBenchmarkLine = String(
      format: "DocumentFind production cold: %.3f ms\n", coldElapsedMs)
    FileHandle.standardError.write(Data(coldBenchmarkLine.utf8))
    XCTContext.runActivity(
      named: coldBenchmarkLine.trimmingCharacters(in: .whitespacesAndNewlines)
    ) { _ in }

    let productionCountAfterColdSearch =
      view.documentFindDisplayTextProductionCountForTesting
    let warmStart = ProcessInfo.processInfo.systemUptime
    let warmResult = view.documentFindResult(for: "needle")
    let warmElapsedMs = (ProcessInfo.processInfo.systemUptime - warmStart) * 1_000
    let warmBenchmarkLine = String(
      format: "DocumentFind production warm: %.3f ms\n", warmElapsedMs)
    FileHandle.standardError.write(Data(warmBenchmarkLine.utf8))
    XCTContext.runActivity(
      named: warmBenchmarkLine.trimmingCharacters(in: .whitespacesAndNewlines)
    ) { _ in }

    let states = TextDocumentSyntaxHighlighter.markdownLineStates(for: lines)
    let display = lines.indices.map {
      DocumentFindDisplayText.markdownDisplayText(for: lines[$0], state: states[$0])
    }
    let engineStart = ProcessInfo.processInfo.systemUptime
    let engineResult = DocumentFindEngine.scan(
      lineCount: display.count,
      lineProvider: { display[$0] },
      query: "needle")
    let engineElapsedMs = (ProcessInfo.processInfo.systemUptime - engineStart) * 1_000
    let engineBenchmarkLine = String(
      format: "DocumentFind engine only: %.3f ms\n", engineElapsedMs)
    FileHandle.standardError.write(Data(engineBenchmarkLine.utf8))
    XCTContext.runActivity(
      named: engineBenchmarkLine.trimmingCharacters(in: .whitespacesAndNewlines)
    ) { _ in }

    XCTAssertGreaterThan(coldResult.matches.count, 1_000)
    XCTAssertEqual(warmResult, coldResult)
    XCTAssertEqual(engineResult, coldResult)
    XCTAssertEqual(
      view.documentFindDisplayTextProductionCountForTesting,
      productionCountAfterColdSearch)
    XCTAssertLessThan(coldElapsedMs, 2_000)
    XCTAssertLessThan(warmElapsedMs, 50)
    XCTAssertLessThan(engineElapsedMs, 50)
  }

  private func syntheticMarkdownLines(count: Int) -> [String] {
    (0..<count).map { index in
      switch index % 10 {
      case 0:
        return "## Heading \(index) needle"
      case 1:
        return "Paragraph with **needle** and [link](https://example.com/\(index))."
      case 2:
        return "| Column | Value |"
      case 3:
        return "| --- | ---: |"
      case 4:
        return "| Item \(index) | needle \(index) |"
      case 5:
        return "```swift"
      case 6:
        return "let needle\(index) = \"value\""
      case 7:
        return "```"
      case 8:
        return "> Quote with _needle_ and `code`."
      default:
        return "- [ ] Task needle \(index)"
      }
    }
  }

  @MainActor
  private func makeEditableMarkdownViewer(_ contents: String) throws -> LineRenderingTextView {
    let buffer = try TextBuffer.open(bytes: Data(contents.utf8))
    let view = LineRenderingTextView()
    view.setBuffer(buffer)
    view.syntax = .markdown
    view.isEditable = true
    view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    view.updateLayout()
    return view
  }

  private func fixtureURL(path: String, filePath: String = #filePath) throws -> URL {
    var directory = URL(filePath: filePath).deletingLastPathComponent()
    let fileManager = FileManager.default

    while !directory.path(percentEncoded: false).isEmpty,
      directory.path(percentEncoded: false) != "/"
    {
      let candidate = directory.appending(path: "fixtures/\(path)")
      if fileManager.fileExists(atPath: candidate.path(percentEncoded: false)) {
        return candidate
      }
      directory.deleteLastPathComponent()
    }

    throw XCTSkip("Could not find fixture \(path)")
  }
}
