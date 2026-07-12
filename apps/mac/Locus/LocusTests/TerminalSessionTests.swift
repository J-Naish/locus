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

  func testPendingOutputCapFailsSession() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      /bin/stty raw -echo
      printf READY
      exec /bin/sleep 30
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
    session.send(Data(repeating: UInt8(ascii: "X"), count: 5 * 1024 * 1024))

    XCTAssertTrue(
      waitUntil(timeout: 5) {
        if case .failed = session.state {
          return true
        }
        return false
      },
      "State was: \(session.state)"
    )
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
