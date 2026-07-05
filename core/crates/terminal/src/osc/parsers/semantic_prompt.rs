use crate::osc::Pending;

use super::string_encoding::{printf_q_decode, url_percent_decode, DecodeError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SemanticPromptAction {
    FreshLine,
    FreshLineNewPrompt,
    NewCommand,
    PromptStart,
    EndPromptStartInput,
    EndPromptStartInputTerminateEol,
    EndInputStartOutput,
    EndCommand,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SemanticPrompt<'a> {
    pub action: SemanticPromptAction,
    pub options_unvalidated: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptClick {
    Line,
    Multiple,
    ConservativeVertical,
    SmartVertical,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptKind {
    Initial,
    Right,
    Continuation,
    Secondary,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptRedraw {
    True,
    False,
    Last,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PromptClickEvents {
    Absolute,
    Relative,
}

impl<'a> SemanticPrompt<'a> {
    pub fn read_aid(self) -> Option<&'a [u8]> {
        read_option(self.options_unvalidated, b"aid")
    }
    pub fn read_err(self) -> Option<&'a [u8]> {
        read_option(self.options_unvalidated, b"err")
    }
    pub fn read_cmdline(self) -> Option<&'a [u8]> {
        read_option(self.options_unvalidated, b"cmdline")
    }
    pub fn read_cmdline_url(self) -> Option<&'a [u8]> {
        read_option(self.options_unvalidated, b"cmdline_url")
    }
    pub fn read_cl(self) -> Option<PromptClick> {
        Some(match read_option(self.options_unvalidated, b"cl")? {
            b"line" => PromptClick::Line,
            b"m" => PromptClick::Multiple,
            b"v" => PromptClick::ConservativeVertical,
            b"w" => PromptClick::SmartVertical,
            _ => return None,
        })
    }
    pub fn read_prompt_kind(self) -> Option<PromptKind> {
        Some(match read_option(self.options_unvalidated, b"k")? {
            b"i" => PromptKind::Initial,
            b"r" => PromptKind::Right,
            b"c" => PromptKind::Continuation,
            b"s" => PromptKind::Secondary,
            _ => return None,
        })
    }
    pub fn read_redraw(self) -> Option<PromptRedraw> {
        Some(match read_option(self.options_unvalidated, b"redraw")? {
            b"1" => PromptRedraw::True,
            b"0" => PromptRedraw::False,
            b"last" => PromptRedraw::Last,
            _ => return None,
        })
    }
    pub fn read_special_key(self) -> Option<bool> {
        match read_option(self.options_unvalidated, b"special_key")? {
            b"1" => Some(true),
            b"0" => Some(false),
            _ => None,
        }
    }
    pub fn read_click_events(self) -> Option<PromptClickEvents> {
        Some(
            match read_option(self.options_unvalidated, b"click_events")? {
                b"1" => PromptClickEvents::Absolute,
                b"2" => PromptClickEvents::Relative,
                _ => return None,
            },
        )
    }
    pub fn read_exit_code(self) -> Option<i32> {
        let first = self
            .options_unvalidated
            .split(|byte| *byte == b';')
            .next()
            .unwrap_or_default();
        std::str::from_utf8(first).ok()?.parse::<i32>().ok()
    }
    pub fn command_line(self) -> Result<Option<Vec<u8>>, DecodeError> {
        let mut output = Vec::new();
        if let Some(raw) = self.read_cmdline() {
            printf_q_decode(&mut output, raw)?;
            return Ok(Some(output));
        }
        if let Some(raw) = self.read_cmdline_url() {
            url_percent_decode(&mut output, raw)?;
            return Ok(Some(output));
        }
        Ok(None)
    }
}

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    if data.is_empty() {
        return None;
    }
    let action = match data[0] {
        b'L' => {
            if data.len() > 1 {
                return None;
            }
            SemanticPromptAction::FreshLine
        }
        b'A' => SemanticPromptAction::FreshLineNewPrompt,
        b'N' => SemanticPromptAction::NewCommand,
        b'P' => SemanticPromptAction::PromptStart,
        b'B' => SemanticPromptAction::EndPromptStartInput,
        b'I' => SemanticPromptAction::EndPromptStartInputTerminateEol,
        b'C' => SemanticPromptAction::EndInputStartOutput,
        b'D' => SemanticPromptAction::EndCommand,
        _ => return None,
    };
    let options = if data.len() == 1 {
        1..1
    } else {
        if data[1] != b';' {
            return None;
        }
        2..data.len()
    };
    Some(Pending::SemanticPrompt { action, options })
}

fn read_option<'a>(options: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    for segment in options.split(|byte| *byte == b';') {
        let Some(eq) = segment.iter().position(|byte| *byte == b'=') else {
            continue;
        };
        if &segment[..eq] == key {
            return Some(&segment[eq + 1..]);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use crate::osc::Command;

    use super::{
        PromptClick, PromptClickEvents, PromptKind, PromptRedraw, SemanticPrompt,
        SemanticPromptAction,
    };

    fn with_prompt(input: &[u8], assert: impl FnOnce(SemanticPrompt<'_>)) {
        let parser = super::super::parse_body(input, None);
        let Some(Command::SemanticPrompt(prompt)) = parser.command() else {
            panic!(
                "expected semantic prompt for {}",
                String::from_utf8_lossy(input)
            );
        };
        assert(prompt);
    }

    fn assert_invalid(input: &[u8]) {
        let parser = super::super::parse_body(input, None);
        assert!(parser.command().is_none());
    }

    fn prompt_with_options(options_unvalidated: &[u8]) -> SemanticPrompt<'_> {
        SemanticPrompt {
            action: SemanticPromptAction::FreshLineNewPrompt,
            options_unvalidated,
        }
    }

    #[test]
    fn osc133_end_input_start_output() {
        // ghostty: "OSC 133: end_input_start_output" (semantic_prompt.zig:396)
        with_prompt(b"133;C", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::EndInputStartOutput);
            assert_eq!(prompt.read_aid(), None);
            assert_eq!(prompt.read_cl(), None);
        });
    }

    #[test]
    fn osc133_end_input_start_output_extra_contents() {
        // ghostty: "OSC 133: end_input_start_output extra contents" (semantic_prompt.zig:411)
        assert_invalid(b"133;Cextra");
    }

    #[test]
    fn osc133_end_input_start_output_with_options() {
        // ghostty: "OSC 133: end_input_start_output with options" (semantic_prompt.zig:420)
        with_prompt(b"133;C;aid=foo", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::EndInputStartOutput);
            assert_eq!(prompt.read_aid(), Some(&b"foo"[..]));
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline() {
        // ghostty: "OSC 133: end_input_start_output with cmdline" (semantic_prompt.zig:433)
        with_prompt(b"133;C;cmdline=echo bobr kurwa", |prompt| {
            assert_eq!(
                prompt.command_line().unwrap().as_deref(),
                Some(&b"echo bobr kurwa"[..])
            );
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_3() {
        // ghostty: "OSC 133: end_input_start_output with cmdline 3" (semantic_prompt.zig:451)
        with_prompt(br"133;C;cmdline=echo bobr\nkurwa", |prompt| {
            assert_eq!(
                prompt.command_line().unwrap().as_deref(),
                Some(&b"echo bobr\nkurwa"[..])
            );
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_4() {
        // ghostty: "OSC 133: end_input_start_output with cmdline 4" (semantic_prompt.zig:468)
        with_prompt(b"133;C;cmdline=$'echo bobr kurwa'", |prompt| {
            assert_eq!(
                prompt.command_line().unwrap().as_deref(),
                Some(&b"echo bobr kurwa"[..])
            );
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_5() {
        // ghostty: "OSC 133: end_input_start_output with cmdline 5" (semantic_prompt.zig:486)
        with_prompt(b"133;C;cmdline='echo bobr kurwa'", |prompt| {
            assert_eq!(
                prompt.command_line().unwrap().as_deref(),
                Some(&b"echo bobr kurwa"[..])
            );
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_6() {
        // ghostty: "OSC 133: end_input_start_output with cmdline 6" (semantic_prompt.zig:504)
        with_prompt(b"133;C;cmdline='echo bobr kurwa", |prompt| {
            assert!(prompt.command_line().is_err());
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_7() {
        // ghostty: "OSC 133: end_input_start_output with cmdline 7" (semantic_prompt.zig:520)
        with_prompt(b"133;C;cmdline=$'echo bobr kurwa", |prompt| {
            assert!(prompt.command_line().is_err());
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_8() {
        // ghostty: "OSC 133: end_input_start_output with cmdline 8" (semantic_prompt.zig:537)
        with_prompt(b"133;C;cmdline=$'", |prompt| {
            assert!(prompt.command_line().is_err());
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_9() {
        // ghostty: "OSC 133: end_input_start_output with cmdline 9" (semantic_prompt.zig:553)
        with_prompt(b"133;C;cmdline=", |prompt| {
            assert_eq!(prompt.command_line().unwrap().as_deref(), Some(&b""[..]));
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_url_1() {
        // ghostty: "OSC 133: end_input_start_output with cmdline_url 1" (semantic_prompt.zig:571)
        with_prompt(b"133;C;cmdline_url=echo bobr kurwa", |prompt| {
            assert_eq!(
                prompt.command_line().unwrap().as_deref(),
                Some(&b"echo bobr kurwa"[..])
            );
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_url_2() {
        // ghostty: "OSC 133: end_input_start_output with cmdline_url 2" (semantic_prompt.zig:589)
        with_prompt(b"133;C;cmdline_url=echo bobr%20kurwa", |prompt| {
            assert_eq!(
                prompt.command_line().unwrap().as_deref(),
                Some(&b"echo bobr kurwa"[..])
            );
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_url_3() {
        // ghostty: "OSC 133: end_input_start_output with cmdline_url 3" (semantic_prompt.zig:607)
        with_prompt(b"133;C;cmdline_url=echo bobr%3bkurwa", |prompt| {
            assert_eq!(
                prompt.command_line().unwrap().as_deref(),
                Some(&b"echo bobr;kurwa"[..])
            );
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_url_4() {
        // ghostty: "OSC 133: end_input_start_output with cmdline_url 4" (semantic_prompt.zig:625)
        with_prompt(b"133;C;cmdline_url=echo bobr%3kurwa", |prompt| {
            assert!(prompt.command_line().is_err());
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_url_5() {
        // ghostty: "OSC 133: end_input_start_output with cmdline_url 5" (semantic_prompt.zig:641)
        with_prompt(b"133;C;cmdline_url=echo bobr%kurwa", |prompt| {
            assert!(prompt.command_line().is_err());
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_url_6() {
        // ghostty: "OSC 133: end_input_start_output with cmdline_url 6" (semantic_prompt.zig:657)
        with_prompt(b"133;C;cmdline_url=echo bobr kurwa%20", |prompt| {
            assert_eq!(
                prompt.command_line().unwrap().as_deref(),
                Some(&b"echo bobr kurwa "[..])
            );
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_url_7() {
        // ghostty: "OSC 133: end_input_start_output with cmdline_url 7" (semantic_prompt.zig:675)
        with_prompt(b"133;C;cmdline_url=echo bobr kurwa%2", |prompt| {
            assert!(prompt.command_line().is_err());
        });
    }

    #[test]
    fn osc133_end_input_start_output_with_cmdline_url_8() {
        // ghostty: "OSC 133: end_input_start_output with cmdline_url 8" (semantic_prompt.zig:691)
        with_prompt(b"133;C;cmdline_url=echo bobr kurwa%", |prompt| {
            assert!(prompt.command_line().is_err());
        });
    }

    #[test]
    fn osc133_fresh_line() {
        // ghostty: "OSC 133: fresh_line" (semantic_prompt.zig:707)
        with_prompt(b"133;L", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::FreshLine);
        });
    }

    #[test]
    fn osc133_fresh_line_extra_contents() {
        // ghostty: "OSC 133: fresh_line extra contents" (semantic_prompt.zig:720)
        assert_invalid(b"133;Lol");
        assert_invalid(b"133;L;aid=foo");
    }

    #[test]
    fn osc133_fresh_line_new_prompt() {
        // ghostty: "OSC 133: fresh_line_new_prompt" (semantic_prompt.zig:740)
        with_prompt(b"133;A", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::FreshLineNewPrompt);
            assert_eq!(prompt.read_aid(), None);
            assert_eq!(prompt.read_cl(), None);
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_aid() {
        // ghostty: "OSC 133: fresh_line_new_prompt with aid" (semantic_prompt.zig:755)
        with_prompt(b"133;A;aid=14", |prompt| {
            assert_eq!(prompt.read_aid(), Some(&b"14"[..]));
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_equals_in_aid() {
        // ghostty: "OSC 133: fresh_line_new_prompt with '=' in aid" (semantic_prompt.zig:769)
        with_prompt(b"133;A;aid=a=b", |prompt| {
            assert_eq!(prompt.read_aid(), Some(&b"a=b"[..]));
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_cl_line() {
        // ghostty: "OSC 133: fresh_line_new_prompt with cl=line" (semantic_prompt.zig:783)
        with_prompt(b"133;A;cl=line", |prompt| {
            assert_eq!(prompt.read_cl(), Some(PromptClick::Line));
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_cl_m() {
        // ghostty: "OSC 133: fresh_line_new_prompt with cl=m" (semantic_prompt.zig:797)
        with_prompt(b"133;A;cl=m", |prompt| {
            assert_eq!(prompt.read_cl(), Some(PromptClick::Multiple));
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_invalid_cl() {
        // ghostty: "OSC 133: fresh_line_new_prompt with invalid cl" (semantic_prompt.zig:811)
        with_prompt(b"133;A;cl=invalid", |prompt| {
            assert_eq!(prompt.read_cl(), None);
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_trailing_semicolon() {
        // ghostty: "OSC 133: fresh_line_new_prompt with trailing ;" (semantic_prompt.zig:825)
        with_prompt(b"133;A;", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::FreshLineNewPrompt);
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_bare_key() {
        // ghostty: "OSC 133: fresh_line_new_prompt with bare key" (semantic_prompt.zig:838)
        with_prompt(b"133;A;barekey", |prompt| {
            assert_eq!(prompt.read_aid(), None);
            assert_eq!(prompt.read_cl(), None);
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_multiple_options() {
        // ghostty: "OSC 133: fresh_line_new_prompt with multiple options" (semantic_prompt.zig:853)
        with_prompt(b"133;A;aid=foo;cl=line", |prompt| {
            assert_eq!(prompt.read_aid(), Some(&b"foo"[..]));
            assert_eq!(prompt.read_cl(), Some(PromptClick::Line));
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_default_redraw() {
        // ghostty: "OSC 133: fresh_line_new_prompt default redraw" (semantic_prompt.zig:868)
        with_prompt(b"133;A", |prompt| {
            assert_eq!(prompt.read_redraw(), None);
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_redraw_0() {
        // ghostty: "OSC 133: fresh_line_new_prompt with redraw=0" (semantic_prompt.zig:882)
        with_prompt(b"133;A;redraw=0", |prompt| {
            assert_eq!(prompt.read_redraw(), Some(PromptRedraw::False));
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_redraw_1() {
        // ghostty: "OSC 133: fresh_line_new_prompt with redraw=1" (semantic_prompt.zig:896)
        with_prompt(b"133;A;redraw=1", |prompt| {
            assert_eq!(prompt.read_redraw(), Some(PromptRedraw::True));
        });
    }

    #[test]
    fn osc133_fresh_line_new_prompt_with_invalid_redraw() {
        // ghostty: "OSC 133: fresh_line_new_prompt with invalid redraw" (semantic_prompt.zig:910)
        with_prompt(b"133;A;redraw=x", |prompt| {
            assert_eq!(prompt.read_redraw(), None);
        });
    }

    #[test]
    fn osc133_prompt_start() {
        // ghostty: "OSC 133: prompt_start" (semantic_prompt.zig:924)
        with_prompt(b"133;P", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::PromptStart);
            assert_eq!(prompt.read_prompt_kind(), None);
        });
    }

    #[test]
    fn osc133_prompt_start_with_k_i() {
        // ghostty: "OSC 133: prompt_start with k=i" (semantic_prompt.zig:938)
        with_prompt(b"133;P;k=i", |prompt| {
            assert_eq!(prompt.read_prompt_kind(), Some(PromptKind::Initial));
        });
    }

    #[test]
    fn osc133_prompt_start_with_k_r() {
        // ghostty: "OSC 133: prompt_start with k=r" (semantic_prompt.zig:952)
        with_prompt(b"133;P;k=r", |prompt| {
            assert_eq!(prompt.read_prompt_kind(), Some(PromptKind::Right));
        });
    }

    #[test]
    fn osc133_prompt_start_with_k_c() {
        // ghostty: "OSC 133: prompt_start with k=c" (semantic_prompt.zig:966)
        with_prompt(b"133;P;k=c", |prompt| {
            assert_eq!(prompt.read_prompt_kind(), Some(PromptKind::Continuation));
        });
    }

    #[test]
    fn osc133_prompt_start_with_k_s() {
        // ghostty: "OSC 133: prompt_start with k=s" (semantic_prompt.zig:980)
        with_prompt(b"133;P;k=s", |prompt| {
            assert_eq!(prompt.read_prompt_kind(), Some(PromptKind::Secondary));
        });
    }

    #[test]
    fn osc133_prompt_start_with_invalid_k() {
        // ghostty: "OSC 133: prompt_start with invalid k" (semantic_prompt.zig:994)
        with_prompt(b"133;P;k=x", |prompt| {
            assert_eq!(prompt.read_prompt_kind(), None);
        });
    }

    #[test]
    fn osc133_prompt_start_extra_contents() {
        // ghostty: "OSC 133: prompt_start extra contents" (semantic_prompt.zig:1008)
        assert_invalid(b"133;Pextra");
    }

    #[test]
    fn osc133_new_command() {
        // ghostty: "OSC 133: new_command" (semantic_prompt.zig:1017)
        with_prompt(b"133;N", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::NewCommand);
            assert_eq!(prompt.read_aid(), None);
            assert_eq!(prompt.read_cl(), None);
        });
    }

    #[test]
    fn osc133_new_command_with_aid() {
        // ghostty: "OSC 133: new_command with aid" (semantic_prompt.zig:1032)
        with_prompt(b"133;N;aid=foo", |prompt| {
            assert_eq!(prompt.read_aid(), Some(&b"foo"[..]));
        });
    }

    #[test]
    fn osc133_new_command_with_cl_line() {
        // ghostty: "OSC 133: new_command with cl=line" (semantic_prompt.zig:1046)
        with_prompt(b"133;N;cl=line", |prompt| {
            assert_eq!(prompt.read_cl(), Some(PromptClick::Line));
        });
    }

    #[test]
    fn osc133_new_command_with_multiple_options() {
        // ghostty: "OSC 133: new_command with multiple options" (semantic_prompt.zig:1060)
        with_prompt(b"133;N;aid=foo;cl=line", |prompt| {
            assert_eq!(prompt.read_aid(), Some(&b"foo"[..]));
            assert_eq!(prompt.read_cl(), Some(PromptClick::Line));
        });
    }

    #[test]
    fn osc133_new_command_extra_contents() {
        // ghostty: "OSC 133: new_command extra contents" (semantic_prompt.zig:1075)
        assert_invalid(b"133;Nextra");
    }

    #[test]
    fn osc133_end_prompt_start_input() {
        // ghostty: "OSC 133: end_prompt_start_input" (semantic_prompt.zig:1084)
        with_prompt(b"133;B", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::EndPromptStartInput);
        });
    }

    #[test]
    fn osc133_end_prompt_start_input_extra_contents() {
        // ghostty: "OSC 133: end_prompt_start_input extra contents" (semantic_prompt.zig:1097)
        assert_invalid(b"133;Bextra");
    }

    #[test]
    fn osc133_end_prompt_start_input_with_options() {
        // ghostty: "OSC 133: end_prompt_start_input with options" (semantic_prompt.zig:1106)
        with_prompt(b"133;B;aid=foo", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::EndPromptStartInput);
            assert_eq!(prompt.read_aid(), Some(&b"foo"[..]));
        });
    }

    #[test]
    fn osc133_end_prompt_start_input_terminate_eol() {
        // ghostty: "OSC 133: end_prompt_start_input_terminate_eol" (semantic_prompt.zig:1119)
        with_prompt(b"133;I", |prompt| {
            assert_eq!(
                prompt.action,
                SemanticPromptAction::EndPromptStartInputTerminateEol
            );
        });
    }

    #[test]
    fn osc133_end_prompt_start_input_terminate_eol_extra_contents() {
        // ghostty: "OSC 133: end_prompt_start_input_terminate_eol extra contents" (semantic_prompt.zig:1132)
        assert_invalid(b"133;Iextra");
    }

    #[test]
    fn osc133_end_prompt_start_input_terminate_eol_with_options() {
        // ghostty: "OSC 133: end_prompt_start_input_terminate_eol with options" (semantic_prompt.zig:1141)
        with_prompt(b"133;I;aid=foo", |prompt| {
            assert_eq!(
                prompt.action,
                SemanticPromptAction::EndPromptStartInputTerminateEol
            );
            assert_eq!(prompt.read_aid(), Some(&b"foo"[..]));
        });
    }

    #[test]
    fn osc133_end_command() {
        // ghostty: "OSC 133: end_command" (semantic_prompt.zig:1154)
        with_prompt(b"133;D", |prompt| {
            assert_eq!(prompt.action, SemanticPromptAction::EndCommand);
            assert_eq!(prompt.read_exit_code(), None);
            assert_eq!(prompt.read_aid(), None);
            assert_eq!(prompt.read_err(), None);
        });
    }

    #[test]
    fn osc133_end_command_extra_contents() {
        // ghostty: "OSC 133: end_command extra contents" (semantic_prompt.zig:1170)
        assert_invalid(b"133;Dextra");
    }

    #[test]
    fn osc133_end_command_with_exit_code_0() {
        // ghostty: "OSC 133: end_command with exit code 0" (semantic_prompt.zig:1179)
        with_prompt(b"133;D;0", |prompt| {
            assert_eq!(prompt.read_exit_code(), Some(0));
        });
    }

    #[test]
    fn osc133_end_command_with_exit_code_and_aid() {
        // ghostty: "OSC 133: end_command with exit code and aid" (semantic_prompt.zig:1193)
        with_prompt(b"133;D;12;aid=foo", |prompt| {
            assert_eq!(prompt.read_aid(), Some(&b"foo"[..]));
            assert_eq!(prompt.read_exit_code(), Some(12));
        });
    }

    #[test]
    fn option_read_aid() {
        // ghostty: "Option.read aid" (semantic_prompt.zig:1208)
        assert_eq!(
            prompt_with_options(b"aid=test123").read_aid(),
            Some(&b"test123"[..])
        );
        assert_eq!(
            prompt_with_options(b"cl=line;aid=myaid;k=i").read_aid(),
            Some(&b"myaid"[..])
        );
        assert_eq!(prompt_with_options(b"cl=line;k=i").read_aid(), None);
        assert_eq!(prompt_with_options(b"aid=").read_aid(), Some(&b""[..]));
        assert_eq!(
            prompt_with_options(b"k=i;aid=last").read_aid(),
            Some(&b"last"[..])
        );
        assert_eq!(
            prompt_with_options(b"aid=first;k=i").read_aid(),
            Some(&b"first"[..])
        );
        assert_eq!(prompt_with_options(b"").read_aid(), None);
        assert_eq!(prompt_with_options(b"aid").read_aid(), None);
        assert_eq!(
            prompt_with_options(b";;aid=value;;").read_aid(),
            Some(&b"value"[..])
        );
    }

    #[test]
    fn option_read_cl() {
        // ghostty: "Option.read cl" (semantic_prompt.zig:1221)
        assert_eq!(
            prompt_with_options(b"cl=line").read_cl(),
            Some(PromptClick::Line)
        );
        assert_eq!(
            prompt_with_options(b"cl=m").read_cl(),
            Some(PromptClick::Multiple)
        );
        assert_eq!(
            prompt_with_options(b"cl=v").read_cl(),
            Some(PromptClick::ConservativeVertical)
        );
        assert_eq!(
            prompt_with_options(b"cl=w").read_cl(),
            Some(PromptClick::SmartVertical)
        );
        assert_eq!(prompt_with_options(b"cl=invalid").read_cl(), None);
        assert_eq!(prompt_with_options(b"aid=foo").read_cl(), None);
    }

    #[test]
    fn option_read_prompt_kind() {
        // ghostty: "Option.read prompt_kind" (semantic_prompt.zig:1231)
        assert_eq!(
            prompt_with_options(b"k=i").read_prompt_kind(),
            Some(PromptKind::Initial)
        );
        assert_eq!(
            prompt_with_options(b"k=r").read_prompt_kind(),
            Some(PromptKind::Right)
        );
        assert_eq!(
            prompt_with_options(b"k=c").read_prompt_kind(),
            Some(PromptKind::Continuation)
        );
        assert_eq!(
            prompt_with_options(b"k=s").read_prompt_kind(),
            Some(PromptKind::Secondary)
        );
        assert_eq!(prompt_with_options(b"k=x").read_prompt_kind(), None);
        assert_eq!(prompt_with_options(b"k=ii").read_prompt_kind(), None);
        assert_eq!(prompt_with_options(b"k=").read_prompt_kind(), None);
    }

    #[test]
    fn option_read_err() {
        // ghostty: "Option.read err" (semantic_prompt.zig:1242)
        assert_eq!(
            prompt_with_options(b"err=some_error").read_err(),
            Some(&b"some_error"[..])
        );
        assert_eq!(prompt_with_options(b"aid=foo").read_err(), None);
    }

    #[test]
    fn option_read_redraw() {
        // ghostty: "Option.read redraw" (semantic_prompt.zig:1248)
        assert_eq!(
            prompt_with_options(b"redraw=1").read_redraw(),
            Some(PromptRedraw::True)
        );
        assert_eq!(
            prompt_with_options(b"redraw=0").read_redraw(),
            Some(PromptRedraw::False)
        );
        assert_eq!(
            prompt_with_options(b"redraw=last").read_redraw(),
            Some(PromptRedraw::Last)
        );
        assert_eq!(prompt_with_options(b"redraw=2").read_redraw(), None);
        assert_eq!(prompt_with_options(b"redraw=10").read_redraw(), None);
        assert_eq!(prompt_with_options(b"redraw=").read_redraw(), None);
    }

    #[test]
    fn option_read_special_key() {
        // ghostty: "Option.read special_key" (semantic_prompt.zig:1258)
        assert_eq!(
            prompt_with_options(b"special_key=1").read_special_key(),
            Some(true)
        );
        assert_eq!(
            prompt_with_options(b"special_key=0").read_special_key(),
            Some(false)
        );
        assert_eq!(
            prompt_with_options(b"special_key=x").read_special_key(),
            None
        );
    }

    #[test]
    fn option_read_click_events() {
        // ghostty: "Option.read click_events" (semantic_prompt.zig:1265)
        assert_eq!(
            prompt_with_options(b"click_events=yes").read_click_events(),
            None
        );
        assert_eq!(
            prompt_with_options(b"click_events=0").read_click_events(),
            None
        );
        assert_eq!(
            prompt_with_options(b"click_events=1").read_click_events(),
            Some(PromptClickEvents::Absolute)
        );
        assert_eq!(
            prompt_with_options(b"click_events=2").read_click_events(),
            Some(PromptClickEvents::Relative)
        );
    }

    #[test]
    fn option_read_exit_code() {
        // ghostty: "Option.read exit_code" (semantic_prompt.zig:1273)
        assert_eq!(prompt_with_options(b"42").read_exit_code(), Some(42));
        assert_eq!(prompt_with_options(b"0").read_exit_code(), Some(0));
        assert_eq!(prompt_with_options(b"-1").read_exit_code(), Some(-1));
        assert_eq!(prompt_with_options(b"abc").read_exit_code(), None);
        assert_eq!(
            prompt_with_options(b"127;aid=foo").read_exit_code(),
            Some(127)
        );
    }
}
