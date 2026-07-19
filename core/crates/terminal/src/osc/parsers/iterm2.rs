use crate::osc::Pending;

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    let separator = data.iter().position(|byte| *byte == b'=');
    let (key, value) = if let Some(separator) = separator {
        (
            &data[..separator],
            Some((separator + 1, &data[separator + 1..])),
        )
    } else {
        (data, None)
    };
    if eq_ignore_ascii_case(key, b"Copy") {
        let (value_start, value) = value?;
        if value.len() < 2 || value[0] != b':' {
            return None;
        }
        let payload = &value[1..];
        if payload.is_empty() || payload == b"?" {
            return None;
        }
        let data_offset = value_start + 1;
        return Some(Pending::ClipboardContents {
            kind: b'c',
            data: data_offset..data_offset + payload.len(),
        });
    }
    if eq_ignore_ascii_case(key, b"CurrentDir") {
        let (value_start, value) = value?;
        if value.is_empty() {
            return None;
        }
        return Some(Pending::ReportPwd {
            value: value_start..data.len(),
        });
    }
    None
}

fn eq_ignore_ascii_case(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .all(|(left, right)| left.eq_ignore_ascii_case(right))
}

#[cfg(test)]
mod tests {
    use crate::osc::Command;

    fn with_command(input: &[u8], assert: impl FnOnce(Option<Command<'_>>)) {
        let parser = super::super::parse_body(input, Some(0x1B));
        assert(parser.command());
    }

    #[test]
    fn valid_unimplemented_key_with_no_value() {
        // ghostty: "OSC: 1337: test valid unimplemented key with no value" (iterm2.zig:200)
        with_command(b"1337;SetBadgeFormat", |command| assert!(command.is_none()));
    }

    #[test]
    fn valid_unimplemented_key_with_empty_value() {
        // ghostty: "OSC: 1337: test valid unimplemented key with empty value" (iterm2.zig:213)
        with_command(
            b"1337;SetBadgeFormat=",
            |command| assert!(command.is_none()),
        );
    }

    #[test]
    fn valid_unimplemented_key_with_non_empty_value() {
        // ghostty: "OSC: 1337: test valid unimplemented key with non-empty value" (iterm2.zig:226)
        with_command(b"1337;SetBadgeFormat=abc123", |command| {
            assert!(command.is_none())
        });
    }

    #[test]
    fn valid_key_with_lower_case_and_no_value() {
        // ghostty: "OSC: 1337: test valid key with lower case and with no value" (iterm2.zig:239)
        with_command(b"1337;setbadgeformat", |command| assert!(command.is_none()));
    }

    #[test]
    fn valid_key_with_lower_case_and_empty_value() {
        // ghostty: "OSC: 1337: test valid key with lower case and with empty value" (iterm2.zig:252)
        with_command(
            b"1337;setbadgeformat=",
            |command| assert!(command.is_none()),
        );
    }

    #[test]
    fn valid_key_with_lower_case_and_non_empty_value() {
        // ghostty: "OSC: 1337: test valid key with lower case and with non-empty value" (iterm2.zig:265)
        with_command(b"1337;setbadgeformat=abc123", |command| {
            assert!(command.is_none())
        });
    }

    #[test]
    fn invalid_key_with_no_value() {
        // ghostty: "OSC: 1337: test invalid key with no value" (iterm2.zig:278)
        with_command(b"1337;BobrKurwa", |command| assert!(command.is_none()));
    }

    #[test]
    fn invalid_key_with_empty_value() {
        // ghostty: "OSC: 1337: test invalid key with empty value" (iterm2.zig:291)
        with_command(b"1337;BobrKurwa=", |command| assert!(command.is_none()));
    }

    #[test]
    fn invalid_key_with_non_empty_value() {
        // ghostty: "OSC: 1337: test invalid key with non-empty value" (iterm2.zig:304)
        with_command(b"1337;BobrKurwa=abc123", |command| {
            assert!(command.is_none())
        });
    }

    #[test]
    fn copy_with_no_value() {
        // ghostty: "OSC: 1337: test Copy with no value" (iterm2.zig:317)
        with_command(b"1337;Copy", |command| assert!(command.is_none()));
    }

    #[test]
    fn copy_with_empty_value() {
        // ghostty: "OSC: 1337: test Copy with empty value" (iterm2.zig:330)
        with_command(b"1337;Copy=", |command| assert!(command.is_none()));
    }

    #[test]
    fn copy_with_only_prefix_colon() {
        // ghostty: "OSC: 1337: test Copy with only prefix colon" (iterm2.zig:343)
        with_command(b"1337;Copy=:", |command| assert!(command.is_none()));
    }

    #[test]
    fn copy_with_question_mark() {
        // ghostty: "OSC: 1337: test Copy with question mark" (iterm2.zig:356)
        with_command(b"1337;Copy=:?", |command| assert!(command.is_none()));
    }

    #[test]
    #[ignore = "ghostty skips this test; base64 validity is deliberately not checked"]
    fn copy_with_non_empty_value_that_is_invalid_base64() {
        // ghostty: "OSC: 1337: test Copy with non-empty value that is invalid base64" (iterm2.zig:369)
        with_command(b"1337;Copy=:abc123", |command| assert!(command.is_none()));
    }

    #[test]
    fn copy_with_valid_base64_but_no_colon_prefix() {
        // ghostty: "OSC: 1337: test Copy with non-empty value that is valid base64 but not prefixed with a colon" (iterm2.zig:389)
        with_command(b"1337;Copy=YWJjMTIz", |command| assert!(command.is_none()));
    }

    #[test]
    fn copy_with_non_empty_value_that_is_valid_base64() {
        // ghostty: "OSC: 1337: test Copy with non-empty value that is valid base64" (iterm2.zig:402)
        with_command(b"1337;Copy=:YWJjMTIz", |command| {
            let Some(Command::ClipboardContents { kind, data }) = command else {
                panic!("expected clipboard contents");
            };
            assert_eq!(kind, b'c');
            assert_eq!(data, b"YWJjMTIz");
        });
    }

    #[test]
    fn current_dir_with_no_value() {
        // ghostty: "OSC: 1337: test CurrentDir with no value" (iterm2.zig:418)
        with_command(b"1337;CurrentDir", |command| assert!(command.is_none()));
    }

    #[test]
    fn current_dir_with_empty_value() {
        // ghostty: "OSC: 1337: test CurrentDir with empty value" (iterm2.zig:431)
        with_command(b"1337;CurrentDir=", |command| assert!(command.is_none()));
    }

    #[test]
    fn current_dir_with_non_empty_value() {
        // ghostty: "OSC: 1337: test CurrentDir with non-empty value" (iterm2.zig:444)
        with_command(b"1337;CurrentDir=abc123", |command| {
            let Some(Command::ReportPwd { value }) = command else {
                panic!("expected pwd");
            };
            assert_eq!(value, b"abc123");
        });
    }
}
