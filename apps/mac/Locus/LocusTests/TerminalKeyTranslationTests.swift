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

  func testTranslatorMapsReleaseAndRepeatActions() throws {
    let input = TerminalKeyInput(
      keyCode: 123,
      modifierFlagsRawValue: 0,
      characters: nil,
      charactersIgnoringModifiers: nil,
      isARepeat: false
    )
    XCTAssertEqual(
      try XCTUnwrap(
        TerminalKeyTranslator.translate(input, action: LOCUS_TERM_ACTION_RELEASE)
      ).action,
      LOCUS_TERM_ACTION_RELEASE
    )
    let repeatInput = TerminalKeyInput(
      keyCode: 123,
      modifierFlagsRawValue: 0,
      characters: nil,
      charactersIgnoringModifiers: nil,
      isARepeat: true
    )
    XCTAssertEqual(
      try XCTUnwrap(TerminalKeyTranslator.translate(repeatInput)).action,
      LOCUS_TERM_ACTION_REPEAT
    )
  }

  func testF13ThroughF20MapToTerminalKeys() throws {
    let expected: [(UInt16, UInt32)] = [
      (105, LOCUS_TERM_KEY_F13), (107, LOCUS_TERM_KEY_F14),
      (113, LOCUS_TERM_KEY_F15), (106, LOCUS_TERM_KEY_F16),
      (64, LOCUS_TERM_KEY_F17), (79, LOCUS_TERM_KEY_F18),
      (80, LOCUS_TERM_KEY_F19), (90, LOCUS_TERM_KEY_F20),
    ]
    for (keyCode, key) in expected {
      let privateUseScalar = try XCTUnwrap(
        UnicodeScalar(0xF710 + UInt32(key - LOCUS_TERM_KEY_F13))
      )
      let event = try XCTUnwrap(
        TerminalKeyTranslator.translate(
          TerminalKeyInput(
            keyCode: keyCode,
            modifierFlagsRawValue: 0,
            characters: String(privateUseScalar),
            charactersIgnoringModifiers: nil,
            isARepeat: false
          )
        )
      )
      XCTAssertEqual(event.key, key)
      XCTAssertTrue(event.utf8.isEmpty)
    }
  }

  func testF13ThroughF20PrivateUseTextIsSuppressed() {
    for value in 0xF710...0xF717 {
      let scalar = UnicodeScalar(value)
      XCTAssertNotNil(scalar)
      if let scalar {
        XCTAssertTrue(TerminalKeyTranslator.suppressesTextInsertion(String(scalar)))
      }
    }
    XCTAssertFalse(TerminalKeyTranslator.suppressesTextInsertion("text"))
  }

  func testUnshiftedResolverUsesTranslationThenAsciiFallback() {
    XCTAssertEqual(
      TerminalUnshiftedCodepointResolver.resolve(
        charactersIgnoringModifiers: "A",
        translate: { "q" }
      ),
      UnicodeScalar("q").value
    )
    XCTAssertEqual(
      TerminalUnshiftedCodepointResolver.resolve(
        charactersIgnoringModifiers: "A",
        translate: { nil }
      ),
      UnicodeScalar("a").value
    )
  }

  func testUnshiftedResolverCachesByLayoutAndKeyCode() {
    var cache = TerminalUnshiftedCodepointCache()
    var translationCount = 0
    let translate = {
      translationCount += 1
      return "a"
    }

    let first = cache.resolve(
      layoutIdentifier: "test-layout",
      keyCode: 0,
      charactersIgnoringModifiers: "A",
      translate: translate
    )
    let second = cache.resolve(
      layoutIdentifier: "test-layout",
      keyCode: 0,
      charactersIgnoringModifiers: "Z",
      translate: translate
    )

    XCTAssertEqual(first, UnicodeScalar("a").value)
    XCTAssertEqual(second, first)
    XCTAssertEqual(translationCount, 1)
  }

  func testCurrentLayoutProducesUnshiftedScalarForShiftAWhenAvailable() throws {
    let value = TerminalUnshiftedCodepointResolver.current(
      keyCode: 0,
      charactersIgnoringModifiers: "A"
    )
    guard value == UnicodeScalar("a").value else {
      throw XCTSkip("Current keyboard layout does not map keyCode 0 to unshifted a")
    }
    XCTAssertEqual(value, UnicodeScalar("a").value)
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
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }
    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForTerminalInputCondition { session.snapshot != nil })

    session.send(Data("abcd".utf8))
    XCTAssertTrue(
      waitForTerminalInputCondition {
        session.plainTextForTesting()?.contains("abcd") == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
    var currentCursorX: UInt16?
    session.withFrame { frame in
      currentCursorX = frame.cursor.x
    }
    let before = try XCTUnwrap(currentCursorX)
    XCTAssertGreaterThanOrEqual(before, 2)
    let expected = before - 2
    let view = TerminalPaneView(session: session)

    view.doCommand(by: Selector("moveLeft:"))
    view.doCommand(by: Selector("moveLeft:"))

    XCTAssertTrue(
      waitForTerminalInputCondition {
        var cursorX: UInt16?
        session.withFrame { frame in
          cursorX = frame.cursor.x
        }
        return cursorX == expected
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
        session.plainTextForTesting()?.contains("IME-テスト") == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testPasteSendsPasteboardTextThroughPty() {
    let session = TerminalSession(columns: 40, rows: 10)
    defer {
      session.terminate()
    }
    let pasteboard = NSPasteboard(
      name: NSPasteboard.Name("locus-test-paste-\(UUID().uuidString)"))
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString("echo PASTE-OK", forType: .string))
    let view = TerminalPaneView(session: session, pasteboard: pasteboard)

    session.start(command: "/bin/sh")
    XCTAssertTrue(waitForTerminalInputCondition { session.snapshot != nil })
    view.paste(nil)

    XCTAssertTrue(
      waitForTerminalInputCondition {
        session.plainTextForTesting()?.contains("PASTE-OK") == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
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
        session.plainTextForTesting()?.contains("SENDKEY-OK") == true
      },
      "Snapshot was: \(session.plainTextForTesting() ?? "<nil>")"
    )
  }

  func testShiftEnterSendsPlainNewlineByDefault() throws {
    let session = TerminalSession(columns: 40, rows: 10)
    defer { session.terminate() }
    session.start(command: "/bin/cat")
    XCTAssertTrue(waitForTerminalInputCondition { session.snapshot != nil })
    let event = try XCTUnwrap(
      TerminalKeyTranslator.translate(
        TerminalKeyInput(
          keyCode: 36,
          modifierFlagsRawValue: NSEvent.ModifierFlags.shift.rawValue,
          characters: "\r",
          charactersIgnoringModifiers: "\r",
          isARepeat: false
        )
      )
    )

    session.sendKey(event)

    XCTAssertTrue(waitForTerminalInputCondition { (session.snapshot?.cursorY ?? 0) > 0 })
    XCTAssertFalse(session.plainTextForTesting()?.contains(";2;13~") == true)
  }

  func testKeyReleaseProducesNoOutputWithoutKittyProtocol() throws {
    let session = TerminalSession(columns: 40, rows: 10)
    defer { session.terminate() }
    session.start(command: "/bin/cat")
    XCTAssertTrue(waitForTerminalInputCondition { session.snapshot != nil })
    let baseline = session.snapshot?.generation
    let release = try XCTUnwrap(
      TerminalKeyTranslator.translate(
        TerminalKeyInput(
          keyCode: 123,
          modifierFlagsRawValue: 0,
          characters: nil,
          charactersIgnoringModifiers: nil,
          isARepeat: false
        ),
        action: LOCUS_TERM_ACTION_RELEASE
      )
    )

    session.sendKey(release)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    XCTAssertEqual(session.snapshot?.generation, baseline)
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
