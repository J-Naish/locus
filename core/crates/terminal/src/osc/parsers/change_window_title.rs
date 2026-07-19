use crate::osc::Pending;

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    Some(Pending::ChangeWindowTitle(0..data.len()))
}

#[cfg(test)]
mod tests {
    use crate::osc::{parsers::parse_body, Command, FIXED_CAPTURE_MAX, MAX_BUF};

    // ghostty: "OSC 0: change_window_title" (change_window_title.zig:23)
    #[test]
    fn osc_0_change_window_title() {
        let parser = parse_body(b"0;ab", None);
        assert_eq!(parser.command(), Some(Command::ChangeWindowTitle(b"ab")));
    }

    // ghostty: "OSC 0: longer than buffer" (change_window_title.zig:36)
    #[test]
    fn osc_0_longer_than_buffer_is_discarded() {
        let mut body = Vec::from(&b"0;"[..]);
        body.extend(std::iter::repeat_n(b'a', MAX_BUF + 2));
        let parser = parse_body(&body, None);
        assert!(parser.command().is_none());
    }

    // ghostty: "OSC 0: one shorter than buffer length" (change_window_title.zig:47)
    #[test]
    fn osc_0_one_shorter_than_buffer_length_succeeds() {
        let mut body = Vec::from(&b"0;"[..]);
        body.extend(std::iter::repeat_n(b'a', FIXED_CAPTURE_MAX));
        let parser = parse_body(&body, None);
        let Some(Command::ChangeWindowTitle(title)) = parser.command() else {
            panic!("expected title, got {:?}", parser.command());
        };
        assert_eq!(title.len(), FIXED_CAPTURE_MAX);
    }

    // ghostty: "OSC 0: exactly at buffer length" (change_window_title.zig:62)
    #[test]
    fn osc_0_exactly_at_buffer_length_is_discarded() {
        let mut body = Vec::from(&b"0;"[..]);
        body.extend(std::iter::repeat_n(b'a', MAX_BUF));
        let parser = parse_body(&body, None);
        assert!(parser.command().is_none());
    }

    // ghostty: "OSC 2: change_window_title with 2" (change_window_title.zig:75)
    #[test]
    fn osc_2_change_window_title() {
        let parser = parse_body(b"2;ab", None);
        assert_eq!(parser.command(), Some(Command::ChangeWindowTitle(b"ab")));
    }

    // ghostty: "OSC 2: change_window_title with utf8" (change_window_title.zig:88)
    #[test]
    fn osc_2_change_window_title_keeps_utf8_bytes() {
        let parser = parse_body(b"2;\xE2\x80\x94 \xE2\x80\x90", None);
        assert_eq!(
            parser.command(),
            Some(Command::ChangeWindowTitle(b"\xE2\x80\x94 \xE2\x80\x90"))
        );
    }

    // ghostty: "OSC 2: change_window_title empty" (change_window_title.zig:110)
    #[test]
    fn osc_2_empty_title_succeeds() {
        let parser = parse_body(b"2;", None);
        assert_eq!(parser.command(), Some(Command::ChangeWindowTitle(b"")));
    }
}
