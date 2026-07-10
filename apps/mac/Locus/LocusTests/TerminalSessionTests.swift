import XCTest

@testable import Locus

@MainActor
final class TerminalSessionTests: XCTestCase {
  func testEchoCommandAppearsInSnapshot() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      echo hello-world
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

    XCTAssertTrue(
      waitUntil { session.snapshot?.plainText.contains("hello-world") == true },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
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
      waitUntil { session.snapshot?.plainText.contains("shell-roundtrip") == true },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
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
      waitUntil(timeout: 5) { session.snapshot?.plainText.contains("da-ok") == true },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )
  }

  func testResizePropagatesToSttySize() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      sleep 0.2
      stty size
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
      waitUntil(timeout: 5) { session.snapshot?.plainText.contains("11 44") == true },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
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

  func testSnapshotGenerationIncreases() throws {
    let scriptURL = try makeExecutableShellScript(
      """
      #!/bin/sh
      echo first-generation
      sleep 0.2
      echo second-generation
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
    XCTAssertTrue(waitUntil { session.snapshot?.plainText.contains("first-generation") == true })
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
          && snapshot.plainText.contains("second-generation")
      },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
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
        session.snapshot?.plainText.contains(expectedPath) == true
      },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
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
      waitUntil { session.snapshot?.plainText.contains("READY") == true },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )
    let payload = Data((String(repeating: "A", count: 8_187) + "@END@").utf8)
    session.send(payload)

    XCTAssertTrue(
      waitUntil(timeout: 6) { session.snapshot?.plainText.contains("@END@") == true },
      "State was: \(session.state), snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
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
    XCTAssertTrue(waitUntil { session.snapshot?.plainText.contains("READY") == true })
    session.send(Data((String(repeating: "A", count: 3_000) + "@ONE@").utf8))
    session.send(Data("@TWO@".utf8))

    XCTAssertTrue(
      waitUntil(timeout: 6) {
        guard let text = session.snapshot?.plainText,
          let one = text.range(of: "@ONE@"),
          let two = text.range(of: "@TWO@")
        else {
          return false
        }
        return one.lowerBound < two.lowerBound
      },
      "State was: \(session.state), snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
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
    XCTAssertTrue(waitUntil { session.snapshot?.plainText.contains("READY") == true })
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
    XCTAssertFalse(session.snapshot?.plainText.contains("TWO") == true)

    var confirmedOutcome: TerminalSession.PasteOutcome?
    session.paste("echo ONE\necho TWO", allowUnsafe: true) { outcome in
      confirmedOutcome = outcome
    }
    XCTAssertTrue(waitUntil { confirmedOutcome != nil })
    XCTAssertEqual(confirmedOutcome, .sent)
    XCTAssertTrue(
      waitUntil(timeout: 5) { session.snapshot?.plainText.contains("TWO") == true },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )
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
    guard let plainText = session.snapshot?.plainText else {
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
