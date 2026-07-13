import XCTest

@testable import Locus

@MainActor
final class TerminalSessionTests: XCTestCase {
  func testShellEnvironmentIsCleanAndLocalized() {
    let session = TerminalSession(columns: 120, rows: 40)
    defer {
      session.terminate()
    }

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.send(Data("/usr/bin/env\n".utf8))

    XCTAssertTrue(
      waitUntil {
        guard let text = session.plainTextForTesting() else {
          return false
        }
        return text.contains("TERM=xterm-256color")
          && (text.contains("LANG=") || text.contains("LC_CTYPE="))
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    let text = session.plainTextForTesting() ?? ""
    XCTAssertFalse(text.contains("DYLD_"))
    XCTAssertFalse(text.contains("XCTestConfigurationFilePath"))
  }

  func testLangSynthesisRequiresInstalledLocale() {
    let locale = Locale(identifier: "ja_JP")

    XCTAssertEqual(
      TerminalShellEnvironment.synthesizedLang(
        locale: locale,
        localeExists: { $0 == "ja_JP.UTF-8" }
      ),
      "ja_JP.UTF-8"
    )
    XCTAssertNil(
      TerminalShellEnvironment.synthesizedLang(
        locale: locale,
        localeExists: { _ in false }
      )
    )
  }

  func testEchoCommandAppearsInSnapshot() throws {
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.send(Data("echo hello-world\n".utf8))

    XCTAssertTrue(
      waitUntil { session.plainTextForTesting()?.contains("hello-world") == true },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testFloodedOutputKeepsPublishingWithoutInput() {
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.send(Data([0x03]))
      session.terminate()
    }

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    let initialGeneration = session.snapshot?.generation ?? 0

    session.send(Data("yes\n".utf8))

    XCTAssertTrue(
      waitUntil(timeout: 5) {
        guard let snapshot = session.snapshot,
          snapshot.generation >= initialGeneration + 3,
          let text = session.plainTextForTesting()
        else {
          return false
        }
        return text.contains("y\ny\ny")
      },
      "Generation was \(session.snapshot?.generation ?? 0), snapshot was: "
        + "\(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testInterruptTakesEffectDuringFlood() {
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.send(Data([0x03]))
      session.terminate()
    }

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    let interruptStartedAt = Date()
    session.send(Data("yes\n".utf8))
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    session.send(Data([0x03]))
    session.send(Data("echo flood-done\n".utf8))

    let didFinish = waitUntil(timeout: 5) {
      session.plainTextForTesting()?.contains("flood-done") == true
    }
    let elapsed = Date().timeIntervalSince(interruptStartedAt)
    XCTAssertTrue(
      didFinish,
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    XCTAssertLessThan(
      elapsed,
      6,
      "Interrupt and queued input took \(elapsed) seconds during a PTY flood"
    )
  }

  func testShellEchoRoundTrip() {
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.send(Data("echo shell-roundtrip\n".utf8))

    XCTAssertTrue(
      waitUntil { session.plainTextForTesting()?.contains("shell-roundtrip") == true },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testDeviceAttributesAutoReply() {
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.send(Data("printf '\\033[c'; sleep 0.2; echo da-ok\n".utf8))

    XCTAssertTrue(
      waitUntil(timeout: 5) { session.plainTextForTesting()?.contains("da-ok") == true },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testResizePropagatesToSttySize() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      sleep 0.2
      stty size
      sleep 1
      """
    )
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
    }

    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: scriptURL.path)
    session.resize(columns: 44, rows: 11)
    XCTAssertTrue(waitUntil { session.snapshot?.columns == 44 && session.snapshot?.rows == 11 })

    XCTAssertTrue(
      waitUntil(timeout: 5) { session.plainTextForTesting()?.contains("11 44") == true },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testExitUpdatesState() {
    let session = TerminalSession(columns: 40, rows: 10)

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.send(Data("exit 3\n".utf8))

    XCTAssertTrue(
      waitUntil(timeout: 5) {
        if case .exited(code: 3) = session.state {
          return true
        }
        return false
      },
      "State was: \(session.state)"
    )
  }

  func testTerminateStopsSession() {
    let session = TerminalSession(columns: 40, rows: 10)

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.terminate()

    XCTAssertTrue(
      waitUntil {
        if case .exited = session.state {
          return true
        }
        return false
      },
      "State was: \(session.state)"
    )

    session.send(Data("echo after-terminate\n".utf8))
  }

  func testShutdownDoesNotBlockWithFrame() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      trap '' HUP
      printf READY
      while :; do
        sleep 1
      done
      """
    )
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
    }
    let session = TerminalSession(columns: 40, rows: 10)

    session.start(command: scriptURL.path)
    XCTAssertTrue(waitUntil { session.plainTextForTesting()?.contains("READY") == true })

    let startedAt = ProcessInfo.processInfo.systemUptime
    session.terminate()
    session.withFrame { _ in }
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

    XCTAssertLessThan(elapsed, 0.15)
    XCTAssertTrue(
      waitUntil {
        if case .exited = session.state {
          return true
        }
        return false
      },
      "State was: \(session.state)"
    )
  }

  func testRepeatedStartStopCyclesDoNotCrash() {
    for _ in 0..<10 {
      let session = TerminalSession(columns: 40, rows: 10)
      session.start(command: "/bin/sh")
      XCTAssertTrue(waitForInitialShellFrame(session))

      session.terminate()

      XCTAssertTrue(
        waitUntil {
          if case .exited = session.state {
            return true
          }
          return false
        },
        "State was: \(session.state)"
      )
    }
  }

  func testSnapshotGenerationIncreases() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      echo first-generation
      sleep 0.2
      echo second-generation
      sleep 1
      """
    )
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
    }

    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: scriptURL.path)
    XCTAssertTrue(waitUntil { session.plainTextForTesting()?.contains("first-generation") == true })
    guard let firstGeneration = session.snapshot?.generation else {
      XCTFail("Missing first snapshot")
      return
    }

    XCTAssertTrue(
      waitUntil {
        guard let snapshot = session.snapshot else {
          return false
        }
        return snapshot.generation > firstGeneration
          && session.plainTextForTesting()?.contains("second-generation") == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testColumnsRowsReflectResize() {
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.resize(columns: 50, rows: 12)

    XCTAssertTrue(
      waitUntil {
        session.snapshot?.columns == 50 && session.snapshot?.rows == 12
      },
      "Snapshot was: \(String(describing: session.snapshot))"
    )
  }

  func testSessionStartsInWorkspaceFolder() throws {
    let directory = try makeTerminalSessionDirectory()
    defer {
      try? FileManager.default.removeItem(at: directory)
    }
    let session = TerminalSession(columns: 100, rows: 12)
    defer {
      session.terminate()
    }

    session.start(command: "/bin/sh", currentDirectory: directory)
    session.send(Data("pwd\n".utf8))

    let expectedPath = directory.resolvingSymlinksInPath().path
    XCTAssertTrue(
      waitUntil {
        session.plainTextForTesting()?.contains(expectedPath) == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testLargeWriteIntoRawModeSurvivesBackpressure() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      /bin/stty raw -echo
      printf READY
      sleep 1
      exec /bin/cat
      """
    )
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
    }
    let session = TerminalSession(columns: 120, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: scriptURL.path)
    XCTAssertTrue(
      waitUntil { session.plainTextForTesting()?.contains("READY") == true },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    let payload = Data((String(repeating: "A", count: 8_187) + "@END@").utf8)
    session.send(payload)

    XCTAssertTrue(
      waitUntil(timeout: 6) { session.plainTextForTesting()?.contains("@END@") == true },
      "State was: \(session.state), snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    XCTAssertEqual(session.state, .running)
  }

  func testLargePasteIntoDrainingShellSurvives() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      /bin/stty raw -echo
      printf READY
      exec /bin/cat
      """
    )
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
    }
    let session = TerminalSession(columns: 120, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: scriptURL.path)
    XCTAssertTrue(waitUntil { session.plainTextForTesting()?.contains("READY") == true })
    let payload = Data((String(repeating: "A", count: 8 * 1024 * 1024) + "@END@").utf8)
    session.send(payload)

    XCTAssertTrue(
      waitUntil(timeout: 30) { session.plainTextForTesting()?.contains("@END@") == true },
      "State was: \(session.state), snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    XCTAssertEqual(session.state, .running)
  }

  func testStuckSinkStillFailsAfterStall() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      /bin/stty raw -echo
      printf READY
      sleep 30
      """
    )
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
    }
    let session = TerminalSession(
      columns: 120,
      rows: 10,
      pendingOutputStallGrace: 0.25
    )
    defer {
      session.terminate()
    }

    session.start(command: scriptURL.path)
    XCTAssertTrue(waitUntil { session.plainTextForTesting()?.contains("READY") == true })
    session.send(Data(repeating: 0x41, count: 5 * 1024 * 1024))

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    XCTAssertEqual(session.state, .running)
    XCTAssertTrue(
      waitUntil(timeout: 3) {
        if case .failed(let message) = session.state {
          return message.contains("stalled")
        }
        return false
      },
      "State was: \(session.state)"
    )
  }

  func testWriteOrderingPreservedAcrossBackpressure() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      /bin/stty raw -echo
      printf READY
      sleep 1
      exec /bin/cat
      """
    )
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
    }
    let session = TerminalSession(columns: 120, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: scriptURL.path)
    XCTAssertTrue(waitUntil { session.plainTextForTesting()?.contains("READY") == true })
    session.send(Data((String(repeating: "A", count: 3_000) + "@ONE@").utf8))
    session.send(Data("@TWO@".utf8))

    XCTAssertTrue(
      waitUntil(timeout: 6) {
        guard let text = session.plainTextForTesting(),
          let one = text.range(of: "@ONE@"),
          let two = text.range(of: "@TWO@")
        else {
          return false
        }
        return one.lowerBound < two.lowerBound
      },
      "State was: \(session.state), snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    XCTAssertEqual(session.state, .running)
  }

  func testMultilinePasteRequiresConfirmationThenSends() {
    let session = TerminalSession(columns: 80, rows: 10)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))

    var firstOutcome: TerminalSession.PasteOutcome?
    session.paste("echo ONE\necho TWO") { outcome in
      firstOutcome = outcome
    }
    XCTAssertTrue(waitUntil { firstOutcome != nil })
    XCTAssertEqual(firstOutcome, .needsConfirmation)
    XCTAssertFalse(session.plainTextForTesting()?.contains("TWO") == true)

    var confirmedOutcome: TerminalSession.PasteOutcome?
    session.paste("echo ONE\necho TWO", allowUnsafe: true) { outcome in
      confirmedOutcome = outcome
    }
    XCTAssertTrue(waitUntil { confirmedOutcome != nil })
    XCTAssertEqual(confirmedOutcome, .sent)
    XCTAssertTrue(
      waitUntil(timeout: 5) { session.plainTextForTesting()?.contains("TWO") == true },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testSelectionGestureSelectsEchoedText() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.send(Data("echo abcdef\n".utf8))

    guard let row = waitForTerminalRow(startingWith: "abcdef", in: session) else {
      XCTFail("Snapshot was: \(session.plainTextForTesting() ?? "<nil>")")
      return
    }
    // The drag endpoint cell only joins the selection once the pointer passes
    // its midpoint, so fraction 0.9 selects through column 3 inclusive.
    session.selectionGesture(.press, column: 0, row: row, cellFractionX: 0.5, rectangle: false)
    session.selectionGesture(.drag, column: 3, row: row, cellFractionX: 0.9, rectangle: false)
    session.selectionGesture(.release, column: 3, row: row, cellFractionX: 0.9, rectangle: false)

    XCTAssertTrue(
      waitUntil {
        var range: ClosedRange<UInt16>?
        session.withFrame { frame in
          range = frame.selectionRange(forRow: Int(row))
        }
        return range == 0...3 && session.selectionText() == "abcd"
      },
      "Selection was range=\(String(describing: selectionRange(in: session, row: row))) text=\(session.selectionText())"
    )
  }

  func testMousePressRoutesToApplicationWhenCaptureEnabled() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    // A raw ESC byte would be eaten by the shell's line editor; send the
    // literal \033 for printf to expand on output instead.
    session.send(Data("echo selected; printf '\\033[?1002h'; echo ready\n".utf8))

    guard let row = waitForTerminalRow(startingWith: "selected", in: session) else {
      XCTFail("Snapshot was: \(session.plainTextForTesting() ?? "<nil>")")
      return
    }
    XCTAssertTrue(waitUntil { session.plainTextForTesting()?.contains("ready") == true })
    selectColumns(0...3, row: row, in: session)
    XCTAssertTrue(waitUntil { selectionRange(in: session, row: row) == 0...3 })

    XCTAssertTrue(
      session.routeMousePress(button: .left, column: 0, row: 0, modifiers: [])
    )
    XCTAssertTrue(waitUntil { selectionRange(in: session, row: row) == nil })
  }

  func testMousePressStaysLocalWithoutCapture() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    session.send(Data("echo local-selection\n".utf8))

    guard let row = waitForTerminalRow(startingWith: "local-selection", in: session) else {
      XCTFail("Snapshot was: \(session.plainTextForTesting() ?? "<nil>")")
      return
    }
    XCTAssertFalse(
      session.routeMousePress(button: .left, column: 0, row: row, modifiers: [])
    )
    selectColumns(0...3, row: row, in: session)

    XCTAssertTrue(waitUntil { selectionRange(in: session, row: row) == 0...3 })
    XCTAssertEqual(session.selectionText(), "loca")
  }

  func testShiftedMousePressStaysLocalUnderCapture() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    // Literal \033 for printf to expand; a raw ESC byte would be eaten by
    // the shell's line editor before reaching printf.
    session.send(Data("printf '\\033[?1002h'; echo ready\n".utf8))
    XCTAssertTrue(waitUntil { session.plainTextForTesting()?.contains("ready") == true })

    XCTAssertFalse(
      session.routeMousePress(button: .left, column: 0, row: 0, modifiers: [.shift])
    )
  }

  func testSelectionTextIsEmptyWithoutSelection() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))
    XCTAssertEqual(session.selectionText(), "")
    session.send(Data("echo clear-me\n".utf8))

    guard let row = waitForTerminalRow(startingWith: "clear-me", in: session) else {
      XCTFail("Snapshot was: \(session.plainTextForTesting() ?? "<nil>")")
      return
    }
    selectColumns(0...3, row: row, in: session)
    XCTAssertTrue(waitUntil { selectionRange(in: session, row: row) == 0...3 })
    session.clearSelection()

    XCTAssertTrue(waitUntil { selectionRange(in: session, row: row) == nil })
    XCTAssertEqual(session.selectionText(), "")
  }

  func testTitleReportReachesSnapshot() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))

    session.send(
      Data("printf '\\033]2;locus-p3-title\\007'; echo title-sent\n".utf8)
    )

    XCTAssertTrue(
      waitUntil {
        session.plainTextForTesting()?.contains("title-sent") == true
          && session.snapshot?.title == "locus-p3-title"
      }
    )
  }

  func testWorkingDirectoryReportReachesSnapshot() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForInitialShellFrame(session))

    session.send(
      Data(
        "printf '\\033]7;file:///tmp/locus%%20p3\\007'; echo pwd-sent\n".utf8
      )
    )
    XCTAssertTrue(
      waitUntil {
        session.plainTextForTesting()?.contains("pwd-sent") == true
          && session.snapshot?.workingDirectory?.path == "/tmp/locus p3"
      }
    )

    session.send(Data("printf '\\033]7;\\007'; echo pwd-cleared\n".utf8))
    XCTAssertTrue(
      waitUntil {
        session.plainTextForTesting()?.contains("pwd-cleared") == true
          && session.snapshot?.workingDirectory == nil
      }
    )
  }

  func testScrollWheelScrollsPrimaryScrollback() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    XCTAssertTrue(prepareScrollableTerminal(session))

    session.scrollWheel(deltaRows: -10, column: 0, row: 0, modifiers: [])
    XCTAssertTrue(waitUntil { session.snapshot?.atBottom == false })

    session.scrollWheel(deltaRows: 10_000, column: 0, row: 0, modifiers: [])
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(session.snapshot?.atBottom, false)

    session.scrollWheel(deltaRows: 4096, column: 0, row: 0, modifiers: [])
    XCTAssertTrue(waitUntil { session.snapshot?.atBottom == true })
  }

  func testScrollWheelUnderMouseCaptureDoesNotMoveViewport() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    XCTAssertTrue(prepareScrollableTerminal(session))
    session.send(Data("printf '\\033[?1002h'; echo ready\n".utf8))
    XCTAssertTrue(waitUntil { session.plainTextForTesting()?.contains("ready") == true })
    let generation = session.snapshot?.generation ?? 0

    session.scrollWheel(deltaRows: -10, column: 0, row: 0, modifiers: [])

    XCTAssertTrue(waitUntil { (session.snapshot?.generation ?? 0) > generation })
    XCTAssertEqual(session.snapshot?.atBottom, true)
  }

  func testScrollToBottomReturnsViewport() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    XCTAssertTrue(prepareScrollableTerminal(session))
    session.scrollWheel(deltaRows: -10, column: 0, row: 0, modifiers: [])
    XCTAssertTrue(waitUntil { session.snapshot?.atBottom == false })

    session.scrollToBottom()

    XCTAssertTrue(waitUntil { session.snapshot?.atBottom == true })
  }

  func testTypingReturnsViewportToBottom() {
    let session = TerminalSession(columns: 80, rows: 12)
    defer {
      session.terminate()
    }
    XCTAssertTrue(prepareScrollableTerminal(session))
    session.scrollWheel(deltaRows: -10, column: 0, row: 0, modifiers: [])
    XCTAssertTrue(waitUntil { session.snapshot?.atBottom == false })

    session.send(Data("x".utf8))

    XCTAssertTrue(waitUntil { session.snapshot?.atBottom == true })
  }
}

@MainActor
extension TerminalSession {
  func plainTextForTesting() -> String? {
    var text: String?
    withFrame { frame in
      text = frame.plainText()
    }
    return text
  }
}

@MainActor
private func waitUntil(
  timeout: TimeInterval = 3.0,
  interval: TimeInterval = 0.01,
  condition: () -> Bool
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() {
      return true
    }
    RunLoop.current.run(until: Date().addingTimeInterval(interval))
  }
  return condition()
}

@MainActor
private func waitForInitialShellFrame(_ session: TerminalSession) -> Bool {
  waitUntil {
    guard let plainText = session.plainTextForTesting() else {
      return false
    }
    return !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

@MainActor
private func prepareScrollableTerminal(_ session: TerminalSession) -> Bool {
  session.start(command: "/bin/sh")
  guard waitForInitialShellFrame(session) else {
    return false
  }
  session.send(
    Data(
      "i=0; while [ $i -lt 200 ]; do echo line-$i; i=$((i+1)); done\n".utf8
    )
  )
  return waitUntil(timeout: 5) {
    session.plainTextForTesting()?.contains("line-199") == true
  }
}

@MainActor
private func waitForTerminalRow(
  startingWith prefix: String,
  in session: TerminalSession
) -> UInt16? {
  var resolvedRow: UInt16?
  _ = waitUntil {
    session.withFrame { frame in
      let lines = frame.plainText().split(separator: "\n", omittingEmptySubsequences: false)
      if let index = lines.firstIndex(where: { $0.hasPrefix(prefix) }) {
        resolvedRow = UInt16(clamping: index)
      }
    }
    return resolvedRow != nil
  }
  return resolvedRow
}

/// Selects the inclusive column range. The drag endpoint cell only joins the
/// selection once the pointer passes its midpoint, so the drag/release
/// fraction sits at 0.9 to select through `columns.upperBound`.
@MainActor
private func selectColumns(
  _ columns: ClosedRange<UInt16>,
  row: UInt16,
  in session: TerminalSession
) {
  session.selectionGesture(
    .press,
    column: columns.lowerBound,
    row: row,
    cellFractionX: 0.5,
    rectangle: false
  )
  session.selectionGesture(
    .drag,
    column: columns.upperBound,
    row: row,
    cellFractionX: 0.9,
    rectangle: false
  )
  session.selectionGesture(
    .release,
    column: columns.upperBound,
    row: row,
    cellFractionX: 0.9,
    rectangle: false
  )
}

@MainActor
private func selectionRange(
  in session: TerminalSession,
  row: UInt16
) -> ClosedRange<UInt16>? {
  var range: ClosedRange<UInt16>?
  session.withFrame { frame in
    range = frame.selectionRange(forRow: Int(row))
  }
  return range
}

private func makeExecutableShellScript(_ contents: String) throws -> URL {
  let scriptURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("locus-terminal-session-\(UUID().uuidString).sh")
  try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: scriptURL.path
  )
  return scriptURL
}

private func makeTerminalSessionDirectory() throws -> URL {
  let directory = URL(
    filePath: "/tmp/locus-terminal-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}
