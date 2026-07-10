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
