import AppKit
import XCTest

@testable import Locus

@MainActor
final class TerminalKeyTranslationTests: XCTestCase {
  func testEnterMapsToEnterKey() throws {
    let event = try XCTUnwrap(
      TerminalKeyTranslator.translate(
        TerminalKeyInput(
          keyCode: 36,
          modifierFlagsRawValue: 0,
          characters: "\r",
          charactersIgnoringModifiers: "\r",
          isARepeat: false
        )
      )
    )

    XCTAssertEqual(event.key, LOCUS_TERM_KEY_ENTER)
    XCTAssertEqual(event.action, LOCUS_TERM_ACTION_PRESS)
  }

  func testArrowKeysMapToArrows() throws {
    let expected: [(UInt16, UInt32)] = [
      (123, LOCUS_TERM_KEY_ARROW_LEFT),
      (124, LOCUS_TERM_KEY_ARROW_RIGHT),
      (125, LOCUS_TERM_KEY_ARROW_DOWN),
      (126, LOCUS_TERM_KEY_ARROW_UP),
    ]

    for (keyCode, key) in expected {
      let event = try XCTUnwrap(
        TerminalKeyTranslator.translate(
          TerminalKeyInput(
            keyCode: keyCode,
            modifierFlagsRawValue: 0,
            characters: nil,
            charactersIgnoringModifiers: nil,
            isARepeat: false
          )
        )
      )
      XCTAssertEqual(event.key, key, "Unexpected translation for keyCode \(keyCode)")
    }
  }

  func testControlCPassesCharacterAndMods() throws {
    let event = try XCTUnwrap(
      TerminalKeyTranslator.translate(
        TerminalKeyInput(
          keyCode: 8,
          modifierFlagsRawValue: NSEvent.ModifierFlags.control.rawValue,
          characters: "\u{3}",
          charactersIgnoringModifiers: "c",
          isARepeat: false
        )
      )
    )

    XCTAssertEqual(event.key, LOCUS_TERM_KEY_UNIDENTIFIED)
    XCTAssertTrue(event.modifiers.contains(.control))
    XCTAssertEqual(event.utf8, Data("c".utf8))
    XCTAssertEqual(event.unshiftedCodepoint, UnicodeScalar("c").value)
  }

  func testUnrepresentableModifiedKeyDetection() {
    // CSI-u and modifyOtherKeys forms are protocol-only and must fall back.
    XCTAssertTrue(
      TerminalKeyEncodingFallback.isUnrepresentableModifiedKey(Data("\u{1B}[59;5u".utf8)))
    XCTAssertTrue(
      TerminalKeyEncodingFallback.isUnrepresentableModifiedKey(Data("\u{1B}[27;2;13~".utf8)))
    // Navigation/function keys keep their modifiers, plain bytes pass through.
    XCTAssertFalse(
      TerminalKeyEncodingFallback.isUnrepresentableModifiedKey(Data("\u{1B}[15;2~".utf8)))
    XCTAssertFalse(
      TerminalKeyEncodingFallback.isUnrepresentableModifiedKey(Data("\u{1B}[5~".utf8)))
    XCTAssertFalse(TerminalKeyEncodingFallback.isUnrepresentableModifiedKey(Data("\r".utf8)))
    XCTAssertFalse(
      TerminalKeyEncodingFallback.isUnrepresentableModifiedKey(Data("\u{1B}[A".utf8)))
  }

  func testCommandDeleteTranslatesToKillLine() throws {
    // Cmd+Delete clears the whole shell line via Ctrl+U, like Terminal.app.
    let event = try XCTUnwrap(
      TerminalKeyTranslator.translate(
        TerminalKeyInput(
          keyCode: 51,
          modifierFlagsRawValue: NSEvent.ModifierFlags.command.rawValue,
          characters: nil,
          charactersIgnoringModifiers: nil,
          isARepeat: false
        )
      )
    )

    XCTAssertEqual(event.modifiers, .control)
    XCTAssertEqual(event.utf8, Data("u".utf8))
    XCTAssertEqual(event.unshiftedCodepoint, UnicodeScalar("u").value)
  }

  func testCommandEventsAreNotTranslated() {
    let event = TerminalKeyTranslator.translate(
      TerminalKeyInput(
        keyCode: 38,
        modifierFlagsRawValue: NSEvent.ModifierFlags.command.rawValue,
        characters: "j",
        charactersIgnoringModifiers: "j",
        isARepeat: false
      )
    )

    XCTAssertNil(event)
  }

  func testModifierSideBitsRoundTrip() {
    XCTAssertEqual(TerminalModifiers.rightShift.rawValue, 1 << 6)
    XCTAssertEqual(TerminalModifiers.rightControl.rawValue, 1 << 7)
    XCTAssertEqual(TerminalModifiers.rightOption.rawValue, 1 << 8)
    XCTAssertEqual(TerminalModifiers.rightCommand.rawValue, 1 << 9)
  }

  func testCommandSelectorsMapToTerminalKeys() throws {
    let expected: [(String, UInt32)] = [
      ("moveLeft:", LOCUS_TERM_KEY_ARROW_LEFT),
      ("moveRight:", LOCUS_TERM_KEY_ARROW_RIGHT),
      ("moveUp:", LOCUS_TERM_KEY_ARROW_UP),
      ("moveDown:", LOCUS_TERM_KEY_ARROW_DOWN),
      ("insertNewline:", LOCUS_TERM_KEY_ENTER),
      ("deleteBackward:", LOCUS_TERM_KEY_BACKSPACE),
      ("deleteForward:", LOCUS_TERM_KEY_DELETE),
      ("insertTab:", LOCUS_TERM_KEY_TAB),
      ("cancelOperation:", LOCUS_TERM_KEY_ESCAPE),
      ("pageUp:", LOCUS_TERM_KEY_PAGE_UP),
      ("pageDown:", LOCUS_TERM_KEY_PAGE_DOWN),
      ("scrollToBeginningOfDocument:", LOCUS_TERM_KEY_HOME),
      ("scrollToEndOfDocument:", LOCUS_TERM_KEY_END),
    ]

    for (selectorName, key) in expected {
      let event = try XCTUnwrap(
        TerminalCommandKeyTranslator.terminalKey(for: Selector(selectorName))
      )
      XCTAssertEqual(event.key, key, "Unexpected key for \(selectorName)")
      XCTAssertEqual(event.action, LOCUS_TERM_ACTION_PRESS)
    }
    XCTAssertNil(TerminalCommandKeyTranslator.terminalKey(for: Selector("unknownCommand:")))
  }

  func testMoveLeftCommandSendsLeftKey() {
    var received: [TerminalKeyEvent] = []
    let view = TerminalPaneView(keyEventObserver: { received.append($0) })

    view.doCommand(by: Selector("moveLeft:"))

    XCTAssertEqual(received.map(\.key), [LOCUS_TERM_KEY_ARROW_LEFT])
  }

  func testArrowKeyDownSendsExactlyOnce() throws {
    var received: [TerminalKeyEvent] = []
    let view = TerminalPaneView(keyEventObserver: { received.append($0) })
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: 123
      )
    )

    view.keyDown(with: event)

    XCTAssertEqual(received.map(\.key), [LOCUS_TERM_KEY_ARROW_LEFT])
  }

  func testMoveLeftCommandMovesCursorThroughPty() throws {
    let scriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("locus-terminal-command-\(UUID().uuidString).sh")
    try "#!/bin/sh\n/bin/stty raw -echo\nprintf READY\nexec /bin/cat\n".write(
      to: scriptURL,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: scriptURL.path
    )
    defer {
      try? FileManager.default.removeItem(at: scriptURL)
    }

    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }
    let view = TerminalPaneView(session: session)
    session.start(command: scriptURL.path)
    XCTAssertTrue(
      waitForTerminalInputCondition {
        session.snapshot?.plainText.contains("READY") == true
      },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )

    session.send(Data("abcd".utf8))
    XCTAssertTrue(
      waitForTerminalInputCondition {
        session.snapshot?.plainText.contains("abcd") == true
      },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )
    let before = try XCTUnwrap(session.snapshot?.cursorX)
    XCTAssertGreaterThanOrEqual(before, 2)
    let expected = before - 2

    view.doCommand(by: Selector("moveLeft:"))
    view.doCommand(by: Selector("moveLeft:"))

    XCTAssertTrue(
      waitForTerminalInputCondition {
        session.snapshot?.cursorX == expected
      },
      "Cursor was: \(session.snapshot?.cursorX.description ?? "<nil>")"
    )
  }

  func testInsertTextSendsUtf8ToShell() {
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }
    let view = TerminalPaneView(session: session)

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForTerminalInputCondition { session.snapshot != nil })
    view.insertText("echo IME-テスト\n", replacementRange: NSRange(location: NSNotFound, length: 0))

    XCTAssertTrue(
      waitForTerminalInputCondition {
        session.snapshot?.plainText.contains("IME-テスト") == true
      },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )
  }

  func testSendKeyEncodesEnterThroughPty() throws {
    let session = TerminalSession(columns: 80, rows: 10)
    defer {
      session.terminate()
    }

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForTerminalInputCondition { session.snapshot != nil })
    session.send(Data("printf '\\123\\105\\116\\104\\113\\105\\131\\055\\117\\113\\012'".utf8))
    let enter = try XCTUnwrap(
      TerminalKeyTranslator.translate(
        TerminalKeyInput(
          keyCode: 36,
          modifierFlagsRawValue: 0,
          characters: "\r",
          charactersIgnoringModifiers: "\r",
          isARepeat: false
        )
      )
    )
    session.sendKey(enter)

    XCTAssertTrue(
      waitForTerminalInputCondition {
        session.snapshot?.plainText.contains("SENDKEY-OK") == true
      },
      "Snapshot was: \(session.snapshot?.plainText ?? "<nil>")"
    )
  }
}

@MainActor
private func waitForTerminalInputCondition(
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
