import XCTest

@testable import Locus

@MainActor
final class TerminalPanelTests: XCTestCase {
  func testJumpPillVisibilityFollowsSnapshotBottomState() {
    XCTAssertFalse(TerminalPanelPresentation.shouldShowJumpToBottom(snapshot: nil))
    XCTAssertFalse(
      TerminalPanelPresentation.shouldShowJumpToBottom(
        snapshot: terminalPanelSnapshot(atBottom: true)
      )
    )
    XCTAssertTrue(
      TerminalPanelPresentation.shouldShowJumpToBottom(
        snapshot: terminalPanelSnapshot(atBottom: false)
      )
    )
  }

  func testDisplayTitlePrefersTitleThenAbbreviatedPwd() {
    let homeDirectory = URL(filePath: "/Users/nash", directoryHint: .isDirectory)

    XCTAssertNil(
      TerminalPanelPresentation.displayTitle(
        snapshot: nil,
        homeDirectory: homeDirectory
      )
    )
    XCTAssertEqual(
      TerminalPanelPresentation.displayTitle(
        snapshot: terminalPanelSnapshot(
          atBottom: true,
          title: "vim README.md",
          workingDirectory: URL(
            filePath: "/Users/nash/dev",
            directoryHint: .isDirectory
          )
        ),
        homeDirectory: homeDirectory
      ),
      "vim README.md"
    )
    XCTAssertEqual(
      TerminalPanelPresentation.displayTitle(
        snapshot: terminalPanelSnapshot(
          atBottom: true,
          workingDirectory: URL(
            filePath: "/Users/nash/dev",
            directoryHint: .isDirectory
          )
        ),
        homeDirectory: homeDirectory
      ),
      "~/dev"
    )
    XCTAssertEqual(
      TerminalPanelPresentation.displayTitle(
        snapshot: terminalPanelSnapshot(
          atBottom: true,
          workingDirectory: URL(
            filePath: "/tmp/locus",
            directoryHint: .isDirectory
          )
        ),
        homeDirectory: homeDirectory
      ),
      "/tmp/locus"
    )
    XCTAssertNil(
      TerminalPanelPresentation.displayTitle(
        snapshot: terminalPanelSnapshot(atBottom: true),
        homeDirectory: homeDirectory
      )
    )
  }

  func testPanelHeightClampsToBounds() {
    let minimumHeight = TerminalPanelMetrics.minimumHeight

    XCTAssertEqual(
      TerminalPanelMetrics.clampedHeight(
        minimumHeight - 40,
        parentHeight: 500
      ),
      minimumHeight
    )
    XCTAssertEqual(
      TerminalPanelMetrics.clampedHeight(
        480,
        parentHeight: 500
      ),
      400
    )
  }

  func testPanelHeightPersistsAcrossState() throws {
    let suiteName = "TerminalPanelTests.height.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let firstState = TerminalPanelState(userDefaults: defaults)
    firstState.updatePanelHeight(320, parentHeight: 600)

    let restoredState = TerminalPanelState(userDefaults: defaults)

    XCTAssertEqual(restoredState.panelHeight, 320)
  }

  func testPanelHeightSurvivesToggle() throws {
    let suiteName = "TerminalPanelTests.toggleHeight.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer {
      defaults.removePersistentDomain(forName: suiteName)
    }
    let state = TerminalPanelState(startCommand: "/bin/sh", userDefaults: defaults)
    defer {
      state.shutdown()
    }
    state.updatePanelHeight(300, parentHeight: 600)

    state.toggle()
    state.toggle()

    XCTAssertEqual(state.panelHeight, 300)
  }

  func testToggleShowsAndHidesPanel() throws {
    let state = TerminalPanelState(startCommand: "/bin/sh")
    defer {
      state.session?.terminate()
    }

    state.toggle()
    let session = try XCTUnwrap(state.session)
    XCTAssertTrue(state.isVisible)

    state.toggle()
    XCTAssertFalse(state.isVisible)
    XCTAssertTrue(state.session === session)
  }

  func testSessionStartsLazilyOnFirstShow() throws {
    let state = TerminalPanelState(startCommand: "/bin/sh")
    defer {
      state.session?.terminate()
    }

    XCTAssertNil(state.session)

    state.toggle()

    XCTAssertTrue(state.isVisible)
    XCTAssertEqual(try XCTUnwrap(state.session).state, .running)
  }

  func testSessionSurvivesHide() throws {
    let state = TerminalPanelState(startCommand: "/bin/sh")
    defer {
      state.session?.terminate()
    }
    state.toggle()
    let session = try XCTUnwrap(state.session)
    session.send(Data("echo terminal-panel-marker\n".utf8))
    XCTAssertTrue(
      waitForTerminalPanelCondition {
        session.plainTextForTesting()?.contains("terminal-panel-marker") == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )

    state.toggle()
    state.toggle()

    XCTAssertTrue(state.isVisible)
    XCTAssertTrue(state.session === session)
    XCTAssertTrue(state.session?.plainTextForTesting()?.contains("terminal-panel-marker") == true)
  }

  func testExitedSessionCanBeRestarted() throws {
    let state = TerminalPanelState(startCommand: "/bin/sh")
    defer {
      state.session?.terminate()
    }
    state.toggle()
    let exitedSession = try XCTUnwrap(state.session)
    exitedSession.send(Data("exit\n".utf8))
    XCTAssertTrue(
      waitForTerminalPanelCondition {
        if case .exited = exitedSession.state {
          return true
        }
        return false
      },
      "State was: \(exitedSession.state)"
    )

    state.toggle()
    state.toggle()

    let restartedSession = try XCTUnwrap(state.session)
    XCTAssertFalse(restartedSession === exitedSession)
    XCTAssertEqual(restartedSession.state, .running)
  }

  func testSessionSurvivesBrowserEquivalentReplacement() throws {
    let windowOwnedState = TerminalPanelState(startCommand: "/bin/sh")
    defer {
      windowOwnedState.session?.terminate()
    }
    var browserReference: TerminalPanelState? = windowOwnedState
    browserReference?.toggle()
    let session = try XCTUnwrap(browserReference?.session)
    session.send(Data("echo browser-replacement-marker\n".utf8))
    XCTAssertTrue(
      waitForTerminalPanelCondition {
        session.plainTextForTesting()?.contains("browser-replacement-marker") == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )

    // WorkspaceContentView can replace WorkspaceBrowserView while loading a
    // folder. HomeView remains the window owner and injects this same state.
    browserReference = nil
    browserReference = windowOwnedState

    XCTAssertTrue(browserReference?.session === session)
    XCTAssertTrue(
      browserReference?.session?.plainTextForTesting()?.contains("browser-replacement-marker")
        == true)
  }

  func testTerminateOnTeardown() throws {
    var state: TerminalPanelState? = TerminalPanelState(startCommand: "/bin/sh")
    state?.toggle()
    let session = try XCTUnwrap(state?.session)
    XCTAssertEqual(session.state, .running)

    state = nil

    XCTAssertTrue(
      waitForTerminalPanelCondition {
        if case .exited = session.state {
          return true
        }
        return false
      },
      "State was: \(session.state)"
    )
  }

  func testRestartUsesLatestFolder() throws {
    let root = URL(
      filePath: "/tmp/locus-terminal-panel-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let firstDirectory = root.appending(path: "first", directoryHint: .isDirectory)
    let secondDirectory = root.appending(path: "second", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
    }
    let state = TerminalPanelState(startCommand: "/bin/sh")
    defer {
      state.shutdown()
    }
    state.currentWorkspaceFolder = firstDirectory
    state.toggle()
    let firstSession = try XCTUnwrap(state.session)
    firstSession.send(Data("pwd\n".utf8))
    XCTAssertTrue(
      waitForTerminalPanelCondition {
        firstSession.plainTextForTesting()?.contains(
          firstDirectory.resolvingSymlinksInPath().path) == true
      },
      "Snapshot was: \(firstSession.plainTextForTesting() ?? "<nil>")"
    )
    firstSession.send(Data("exit\n".utf8))
    XCTAssertTrue(
      waitForTerminalPanelCondition {
        if case .exited = firstSession.state {
          return true
        }
        return false
      }
    )

    state.currentWorkspaceFolder = secondDirectory
    state.toggle()
    state.toggle()
    let restartedSession = try XCTUnwrap(state.session)
    restartedSession.send(Data("pwd\n".utf8))

    XCTAssertFalse(restartedSession === firstSession)
    XCTAssertTrue(
      waitForTerminalPanelCondition {
        restartedSession.plainTextForTesting()?.contains(
          secondDirectory.resolvingSymlinksInPath().path) == true
      },
      "Snapshot was: \(restartedSession.plainTextForTesting() ?? "<nil>")"
    )
  }
}

private func terminalPanelSnapshot(
  atBottom: Bool,
  title: String? = nil,
  workingDirectory: URL? = nil
) -> TerminalSession.Snapshot {
  TerminalSession.Snapshot(
    generation: 1,
    columns: 80,
    rows: 24,
    cursorX: 0,
    cursorY: 0,
    cursorVisible: true,
    cursorBlinking: true,
    atBottom: atBottom,
    title: title,
    workingDirectory: workingDirectory
  )
}

@MainActor
private func waitForTerminalPanelCondition(
  timeout: TimeInterval = 3,
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
