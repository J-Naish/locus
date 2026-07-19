use crate::osc::parsers::semantic_prompt::SemanticPromptAction;
use crate::osc::Pending;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProgressState {
    Remove,
    Set,
    Error,
    Indeterminate,
    Pause,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConemuTabTitle<'a> {
    Reset,
    Value(&'a [u8]),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PendingTabTitle {
    Reset,
    Value(std::ops::Range<usize>),
}

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    Some(
        parse_conemu(data).unwrap_or(Pending::ShowDesktopNotification {
            title: 0..0,
            body: 0..data.len(),
        }),
    )
}

fn parse_conemu(data: &[u8]) -> Option<Pending> {
    match data.first().copied()? {
        b'1' => parse_one(data),
        b'2' => gated_payload(data, Pending::ConemuShowMessageBox),
        b'3' => parse_tab_title(data),
        b'4' => parse_progress(data),
        b'5' => Some(Pending::ConemuWaitInput),
        b'6' => gated_payload(data, Pending::ConemuGuimacro),
        b'7' => gated_payload(data, Pending::ConemuRunProcess),
        b'8' => gated_payload(data, Pending::ConemuOutputEnvironmentVariable),
        b'9' => gated_payload(data, |range| Pending::ReportPwd { value: range }),
        _ => None,
    }
}

fn parse_one(data: &[u8]) -> Option<Pending> {
    let second = *data.get(1)?;
    match second {
        b';' => {
            let duration = std::str::from_utf8(&data[2..])
                .ok()
                .and_then(|text| text.parse::<u16>().ok())
                .map(|value| value.min(10_000))
                .unwrap_or(100);
            Some(Pending::ConemuSleep {
                duration_ms: duration,
            })
        }
        b'0' => {
            if data == b"10" {
                return Some(Pending::ConemuXtermEmulation {
                    keyboard: Some(true),
                    output: Some(true),
                });
            }
            if data.len() < 4 || data[2] != b';' {
                return None;
            }
            Some(match data[3] {
                b'0' => Pending::ConemuXtermEmulation {
                    keyboard: Some(false),
                    output: Some(false),
                },
                b'1' => Pending::ConemuXtermEmulation {
                    keyboard: Some(true),
                    output: Some(true),
                },
                b'2' => Pending::ConemuXtermEmulation {
                    keyboard: None,
                    output: Some(false),
                },
                b'3' => Pending::ConemuXtermEmulation {
                    keyboard: None,
                    output: Some(true),
                },
                _ => return None,
            })
        }
        b'1' => {
            if data.len() >= 3 && data[2] == b';' {
                Some(Pending::ConemuComment(3..data.len()))
            } else {
                None
            }
        }
        b'2' => Some(Pending::SemanticPrompt {
            action: SemanticPromptAction::FreshLineNewPrompt,
            options: 0..0,
        }),
        _ => None,
    }
}

fn gated_payload(data: &[u8], make: fn(std::ops::Range<usize>) -> Pending) -> Option<Pending> {
    if data.len() >= 2 && data[1] == b';' {
        Some(make(2..data.len()))
    } else {
        None
    }
}

fn parse_tab_title(data: &[u8]) -> Option<Pending> {
    if data.len() < 2 || data[1] != b';' {
        return None;
    }
    Some(Pending::ConemuChangeTabTitle(if data.len() == 2 {
        PendingTabTitle::Reset
    } else {
        PendingTabTitle::Value(2..data.len())
    }))
}

fn parse_progress(data: &[u8]) -> Option<Pending> {
    if data.len() < 3 || data[1] != b';' {
        return None;
    }
    let (state, mut progress) = match data[2] {
        b'0' => (ProgressState::Remove, None),
        b'1' => (ProgressState::Set, Some(0)),
        b'2' => (ProgressState::Error, None),
        b'3' => (ProgressState::Indeterminate, None),
        b'4' => (ProgressState::Pause, None),
        _ => return None,
    };
    if matches!(
        state,
        ProgressState::Set | ProgressState::Error | ProgressState::Pause
    ) && data.get(3) == Some(&b';')
    {
        progress = std::str::from_utf8(&data[4..])
            .ok()
            .and_then(|text| text.parse::<u64>().ok())
            .map(|value| value.min(100) as u8);
    }
    Some(Pending::ConemuProgressReport { state, progress })
}

#[cfg(test)]
mod tests {
    use crate::osc::parsers::semantic_prompt::SemanticPromptAction;
    use crate::osc::Command;

    use super::{ConemuTabTitle, ProgressState};

    fn with_command(input: &[u8], assert: impl FnOnce(Command<'_>)) {
        let parser = super::super::parse_body(input, Some(0x1B));
        let Some(command) = parser.command() else {
            panic!("expected command for {}", String::from_utf8_lossy(input));
        };
        assert(command);
    }

    fn assert_notification(input: &[u8], body: &[u8]) {
        with_command(input, |command| {
            let Command::ShowDesktopNotification {
                title,
                body: actual,
            } = command
            else {
                panic!("expected notification, got {command:?}");
            };
            assert_eq!(title, b"");
            assert_eq!(actual, body);
        });
    }

    #[test]
    fn osc9_show_desktop_notification() {
        // ghostty: "OSC 9: show desktop notification" (osc9.zig:288)
        assert_notification(b"9;Hello world", b"Hello world");
    }

    #[test]
    fn osc9_show_single_character_desktop_notification() {
        // ghostty: "OSC 9: show single character desktop notification" (osc9.zig:302)
        assert_notification(b"9;H", b"H");
    }

    #[test]
    fn osc91_conemu_sleep() {
        // ghostty: "OSC 9;1: ConEmu sleep" (osc9.zig:316)
        with_command(b"9;1;420", |command| {
            assert_eq!(command, Command::ConemuSleep { duration_ms: 420 });
        });
    }

    #[test]
    fn osc91_conemu_sleep_with_no_value_defaults_to_100ms() {
        // ghostty: "OSC 9;1: ConEmu sleep with no value default to 100ms" (osc9.zig:330)
        with_command(b"9;1;", |command| {
            assert_eq!(command, Command::ConemuSleep { duration_ms: 100 });
        });
    }

    #[test]
    fn osc91_conemu_sleep_cannot_exceed_10000ms() {
        // ghostty: "OSC 9;1: conemu sleep cannot exceed 10000ms" (osc9.zig:344)
        with_command(b"9;1;12345", |command| {
            assert_eq!(command, Command::ConemuSleep { duration_ms: 10000 });
        });
    }

    #[test]
    fn osc91_conemu_sleep_invalid_input() {
        // ghostty: "OSC 9;1: conemu sleep invalid input" (osc9.zig:358)
        with_command(b"9;1;foo", |command| {
            assert_eq!(command, Command::ConemuSleep { duration_ms: 100 });
        });
    }

    #[test]
    fn osc91_conemu_sleep_notification_1() {
        // ghostty: "OSC 9;1: conemu sleep -> desktop notification 1" (osc9.zig:372)
        assert_notification(b"9;1", b"1");
    }

    #[test]
    fn osc91_conemu_sleep_notification_2() {
        // ghostty: "OSC 9;1: conemu sleep -> desktop notification 2" (osc9.zig:386)
        assert_notification(b"9;1a", b"1a");
    }

    #[test]
    fn osc92_conemu_message_box() {
        // ghostty: "OSC 9;2: ConEmu message box" (osc9.zig:400)
        with_command(b"9;2;hello world", |command| {
            assert_eq!(command, Command::ConemuShowMessageBox(b"hello world"));
        });
    }

    #[test]
    fn osc92_conemu_message_box_invalid_input() {
        // ghostty: "OSC 9;2: ConEmu message box invalid input" (osc9.zig:413)
        assert_notification(b"9;2", b"2");
    }

    #[test]
    fn osc92_conemu_message_box_empty_message() {
        // ghostty: "OSC 9;2: ConEmu message box empty message" (osc9.zig:426)
        with_command(b"9;2;", |command| {
            assert_eq!(command, Command::ConemuShowMessageBox(b""));
        });
    }

    #[test]
    fn osc92_conemu_message_box_spaces_only_message() {
        // ghostty: "OSC 9;2: ConEmu message box spaces only message" (osc9.zig:439)
        with_command(b"9;2;   ", |command| {
            assert_eq!(command, Command::ConemuShowMessageBox(b"   "));
        });
    }

    #[test]
    fn osc92_message_box_notification_1() {
        // ghostty: "OSC 9;2: message box -> desktop notification 1" (osc9.zig:452)
        assert_notification(b"9;2", b"2");
    }

    #[test]
    fn osc92_message_box_notification_2() {
        // ghostty: "OSC 9;2: message box -> desktop notification 2" (osc9.zig:466)
        assert_notification(b"9;2a", b"2a");
    }

    #[test]
    fn osc93_conemu_change_tab_title() {
        // ghostty: "OSC 9;3: ConEmu change tab title" (osc9.zig:480)
        with_command(b"9;3;foo bar", |command| {
            assert_eq!(
                command,
                Command::ConemuChangeTabTitle(ConemuTabTitle::Value(b"foo bar"))
            );
        });
    }

    #[test]
    fn osc93_conemu_change_tab_title_reset() {
        // ghostty: "OSC 9;3: ConEmu change tab title reset" (osc9.zig:493)
        with_command(b"9;3;", |command| {
            assert_eq!(
                command,
                Command::ConemuChangeTabTitle(ConemuTabTitle::Reset)
            );
        });
    }

    #[test]
    fn osc93_conemu_change_tab_title_spaces_only() {
        // ghostty: "OSC 9;3: ConEmu change tab title spaces only" (osc9.zig:507)
        with_command(b"9;3;   ", |command| {
            assert_eq!(
                command,
                Command::ConemuChangeTabTitle(ConemuTabTitle::Value(b"   "))
            );
        });
    }

    #[test]
    fn osc93_change_tab_title_notification_1() {
        // ghostty: "OSC 9;3: change tab title -> desktop notification 1" (osc9.zig:521)
        assert_notification(b"9;3", b"3");
    }

    #[test]
    fn osc93_message_box_notification_2() {
        // ghostty: "OSC 9;3: message box -> desktop notification 2" (osc9.zig:535)
        assert_notification(b"9;3a", b"3a");
    }

    #[test]
    fn osc94_conemu_progress_set() {
        // ghostty: "OSC 9;4: ConEmu progress set" (osc9.zig:549)
        with_command(b"9;4;1;100", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Set,
                    progress: Some(100)
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_set_overflow() {
        // ghostty: "OSC 9;4: ConEmu progress set overflow" (osc9.zig:563)
        with_command(b"9;4;1;900", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Set,
                    progress: Some(100)
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_set_single_digit() {
        // ghostty: "OSC 9;4: ConEmu progress set single digit" (osc9.zig:577)
        with_command(b"9;4;1;9", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Set,
                    progress: Some(9)
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_set_double_digit() {
        // ghostty: "OSC 9;4: ConEmu progress set double digit" (osc9.zig:591)
        with_command(b"9;4;1;94", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Set,
                    progress: Some(94)
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_set_extra_semicolon_ignored() {
        // ghostty: "OSC 9;4: ConEmu progress set extra semicolon ignored" (osc9.zig:605)
        with_command(b"9;4;1;100", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Set,
                    progress: Some(100)
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_remove_with_no_progress() {
        // ghostty: "OSC 9;4: ConEmu progress remove with no progress" (osc9.zig:619)
        with_command(b"9;4;0;", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Remove,
                    progress: None
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_remove_with_double_semicolon() {
        // ghostty: "OSC 9;4: ConEmu progress remove with double semicolon" (osc9.zig:633)
        with_command(b"9;4;0;;", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Remove,
                    progress: None
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_remove_ignores_progress() {
        // ghostty: "OSC 9;4: ConEmu progress remove ignores progress" (osc9.zig:647)
        with_command(b"9;4;0;100", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Remove,
                    progress: None
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_remove_extra_semicolon() {
        // ghostty: "OSC 9;4: ConEmu progress remove extra semicolon" (osc9.zig:661)
        with_command(b"9;4;0;100;", |command| {
            let Command::ConemuProgressReport { state, progress: _ } = command else {
                panic!("expected progress report");
            };
            assert_eq!(state, ProgressState::Remove);
        });
    }

    #[test]
    fn osc94_conemu_progress_error() {
        // ghostty: "OSC 9;4: ConEmu progress error" (osc9.zig:674)
        with_command(b"9;4;2", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Error,
                    progress: None
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_error_with_progress() {
        // ghostty: "OSC 9;4: ConEmu progress error with progress" (osc9.zig:688)
        with_command(b"9;4;2;100", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Error,
                    progress: Some(100)
                }
            );
        });
    }

    #[test]
    fn osc94_progress_pause() {
        // ghostty: "OSC 9;4: progress pause" (osc9.zig:702)
        with_command(b"9;4;4", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Pause,
                    progress: None
                }
            );
        });
    }

    #[test]
    fn osc94_conemu_progress_pause_with_progress() {
        // ghostty: "OSC 9;4: ConEmu progress pause with progress" (osc9.zig:716)
        with_command(b"9;4;4;100", |command| {
            assert_eq!(
                command,
                Command::ConemuProgressReport {
                    state: ProgressState::Pause,
                    progress: Some(100)
                }
            );
        });
    }

    #[test]
    fn osc94_progress_notification_1() {
        // ghostty: "OSC 9;4: progress -> desktop notification 1" (osc9.zig:730)
        assert_notification(b"9;4", b"4");
    }

    #[test]
    fn osc94_progress_notification_2() {
        // ghostty: "OSC 9;4: progress -> desktop notification 2" (osc9.zig:744)
        assert_notification(b"9;4;", b"4;");
    }

    #[test]
    fn osc94_progress_notification_3() {
        // ghostty: "OSC 9;4: progress -> desktop notification 3" (osc9.zig:758)
        assert_notification(b"9;4;5", b"4;5");
    }

    #[test]
    fn osc94_progress_notification_4() {
        // ghostty: "OSC 9;4: progress -> desktop notification 4" (osc9.zig:772)
        assert_notification(b"9;4;5a", b"4;5a");
    }

    #[test]
    fn osc95_conemu_wait_input() {
        // ghostty: "OSC 9;5: ConEmu wait input" (osc9.zig:786)
        with_command(b"9;5", |command| {
            assert_eq!(command, Command::ConemuWaitInput);
        });
    }

    #[test]
    fn osc95_conemu_wait_ignores_trailing_characters() {
        // ghostty: "OSC 9;5: ConEmu wait ignores trailing characters" (osc9.zig:798)
        with_command(b"9;5;foo", |command| {
            assert_eq!(command, Command::ConemuWaitInput);
        });
    }

    #[test]
    fn osc96_conemu_guimacro_1() {
        // ghostty: "OSC 9;6: ConEmu guimacro 1" (osc9.zig:810)
        with_command(b"9;6;a", |command| {
            assert_eq!(command, Command::ConemuGuimacro(b"a"));
        });
    }

    #[test]
    fn osc96_conemu_guimacro_2() {
        // ghostty: "OSC: 9;6: ConEmu guimacro 2" (osc9.zig:824)
        with_command(b"9;6;ab", |command| {
            assert_eq!(command, Command::ConemuGuimacro(b"ab"));
        });
    }

    #[test]
    fn osc96_conemu_guimacro_3_incomplete_notification() {
        // ghostty: "OSC: 9;6: ConEmu guimacro 3 incomplete -> desktop notification" (osc9.zig:838)
        assert_notification(b"9;6", b"6");
    }

    #[test]
    fn osc97_conemu_run_process_1() {
        // ghostty: "OSC: 9;7: ConEmu run process 1" (osc9.zig:852)
        with_command(b"9;7;ab", |command| {
            assert_eq!(command, Command::ConemuRunProcess(b"ab"));
        });
    }

    #[test]
    fn osc97_conemu_run_process_2() {
        // ghostty: "OSC: 9;7: ConEmu run process 2" (osc9.zig:866)
        with_command(b"9;7;", |command| {
            assert_eq!(command, Command::ConemuRunProcess(b""));
        });
    }

    #[test]
    fn osc97_conemu_run_process_incomplete_notification() {
        // ghostty: "OSC: 9;7: ConEmu run process incomplete -> desktop notification" (osc9.zig:880)
        assert_notification(b"9;7", b"7");
    }

    #[test]
    fn osc98_conemu_output_environment_variable_1() {
        // ghostty: "OSC: 9;8: ConEmu output environment variable 1" (osc9.zig:894)
        with_command(b"9;8;ab", |command| {
            assert_eq!(command, Command::ConemuOutputEnvironmentVariable(b"ab"));
        });
    }

    #[test]
    fn osc98_conemu_output_environment_variable_2() {
        // ghostty: "OSC: 9;8: ConEmu output environment variable 2" (osc9.zig:908)
        with_command(b"9;8;", |command| {
            assert_eq!(command, Command::ConemuOutputEnvironmentVariable(b""));
        });
    }

    #[test]
    fn osc98_conemu_output_environment_variable_incomplete_notification() {
        // ghostty: "OSC: 9;8: ConEmu output environment variable incomplete -> desktop notification" (osc9.zig:922)
        assert_notification(b"9;8", b"8");
    }

    #[test]
    fn osc99_conemu_set_current_working_directory() {
        // ghostty: "OSC: 9;9: ConEmu set current working directory" (osc9.zig:936)
        with_command(b"9;9;ab", |command| {
            assert_eq!(command, Command::ReportPwd { value: b"ab" });
        });
    }

    #[test]
    fn osc99_conemu_set_current_working_directory_incomplete_notification() {
        // ghostty: "OSC: 9;9: ConEmu set current working directory incomplete -> desktop notification" (osc9.zig:950)
        assert_notification(b"9;9", b"9");
    }

    #[test]
    fn osc910_conemu_xterm_keyboard_and_output_emulation_1() {
        // ghostty: "OSC: 9;10: ConEmu xterm keyboard and output emulation 1" (osc9.zig:964)
        with_command(b"9;10", |command| {
            assert_eq!(
                command,
                Command::ConemuXtermEmulation {
                    keyboard: Some(true),
                    output: Some(true)
                }
            );
        });
    }

    #[test]
    fn osc910_conemu_xterm_keyboard_and_output_emulation_2() {
        // ghostty: "OSC: 9;10: ConEmu xterm keyboard and output emulation 2" (osc9.zig:981)
        with_command(b"9;10;0", |command| {
            assert_eq!(
                command,
                Command::ConemuXtermEmulation {
                    keyboard: Some(false),
                    output: Some(false)
                }
            );
        });
    }

    #[test]
    fn osc910_conemu_xterm_keyboard_and_output_emulation_3() {
        // ghostty: "OSC: 9;10: ConEmu xterm keyboard and output emulation 3" (osc9.zig:998)
        with_command(b"9;10;1", |command| {
            assert_eq!(
                command,
                Command::ConemuXtermEmulation {
                    keyboard: Some(true),
                    output: Some(true)
                }
            );
        });
    }

    #[test]
    fn osc910_conemu_xterm_keyboard_and_output_emulation_4() {
        // ghostty: "OSC: 9;10: ConEmu xterm keyboard and output emulation 4" (osc9.zig:1015)
        with_command(b"9;10;2", |command| {
            assert_eq!(
                command,
                Command::ConemuXtermEmulation {
                    keyboard: None,
                    output: Some(false)
                }
            );
        });
    }

    #[test]
    fn osc910_conemu_xterm_keyboard_and_output_emulation_5() {
        // ghostty: "OSC: 9;10: ConEmu xterm keyboard and output emulation 5" (osc9.zig:1031)
        with_command(b"9;10;3", |command| {
            assert_eq!(
                command,
                Command::ConemuXtermEmulation {
                    keyboard: None,
                    output: Some(true)
                }
            );
        });
    }

    #[test]
    fn osc910_conemu_xterm_keyboard_and_output_emulation_6() {
        // ghostty: "OSC: 9;10: ConEmu xterm keyboard and output emulation 6" (osc9.zig:1047)
        assert_notification(b"9;10;4", b"10;4");
    }

    #[test]
    fn osc910_conemu_xterm_keyboard_and_output_emulation_7() {
        // ghostty: "OSC: 9;10: ConEmu xterm keyboard and output emulation 7" (osc9.zig:1061)
        assert_notification(b"9;10;", b"10;");
    }

    #[test]
    fn osc910_conemu_xterm_keyboard_and_output_emulation_8() {
        // ghostty: "OSC: 9;10: ConEmu xterm keyboard and output emulation 8" (osc9.zig:1075)
        assert_notification(b"9;10;abc", b"10;abc");
    }

    #[test]
    fn osc911_conemu_comment() {
        // ghostty: "OSC: 9;11: ConEmu comment" (osc9.zig:1089)
        with_command(b"9;11;ab", |command| {
            assert_eq!(command, Command::ConemuComment(b"ab"));
        });
    }

    #[test]
    fn osc911_conemu_comment_incomplete_notification() {
        // ghostty: "OSC: 9;11: ConEmu comment incomplete -> desktop notification" (osc9.zig:1103)
        assert_notification(b"9;11", b"11");
    }

    #[test]
    fn osc912_conemu_mark_prompt_start_1() {
        // ghostty: "OSC: 9;12: ConEmu mark prompt start 1" (osc9.zig:1117)
        with_command(b"9;12", |command| {
            let Command::SemanticPrompt(prompt) = command else {
                panic!("expected semantic prompt");
            };
            assert_eq!(prompt.action, SemanticPromptAction::FreshLineNewPrompt);
        });
    }

    #[test]
    fn osc912_conemu_mark_prompt_start_2() {
        // ghostty: "OSC: 9;12: ConEmu mark prompt start 2" (osc9.zig:1130)
        with_command(b"9;12;abc", |command| {
            let Command::SemanticPrompt(prompt) = command else {
                panic!("expected semantic prompt");
            };
            assert_eq!(prompt.action, SemanticPromptAction::FreshLineNewPrompt);
        });
    }
}
