import XCTest

@testable import Locus

@MainActor
final class TerminalPanelTests: XCTestCase {
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
        session.snapshot?.plainText.contains("terminal-panel-marker") == true
      },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )

    state.toggle()
    state.toggle()

    XCTAssertTrue(state.isVisible)
    XCTAssertTrue(state.session === session)
    XCTAssertTrue(state.session?.snapshot?.plainText.contains("terminal-panel-marker") == true)
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
        session.snapshot?.plainText.contains("browser-replacement-marker") == true
      },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )

    // WorkspaceContentView can replace WorkspaceBrowserView while loading a
    // folder. HomeView remains the window owner and injects this same state.
    browserReference = nil
    browserReference = windowOwnedState

    XCTAssertTrue(browserReference?.session === session)
    XCTAssertTrue(
      browserReference?.session?.snapshot?.plainText.contains("browser-replacement-marker") == true)
  }
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
