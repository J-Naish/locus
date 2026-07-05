use crate::osc::Pending;

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    let separator = data.iter().position(|byte| *byte == b';')?;
    let uri = separator + 1..data.len();
    let mut id = None;
    let mut offset = 0;
    for chunk in data[..separator].split(|byte| *byte == b':') {
        if let Some(eq) = chunk.iter().position(|byte| *byte == b'=') {
            let key = &chunk[..eq];
            let value_start = offset + eq + 1;
            let value_end = offset + chunk.len();
            if key == b"id" && value_start < value_end {
                id = Some(value_start..value_end);
            }
            offset += chunk.len() + 1;
        } else {
            break;
        }
    }
    if uri.is_empty() {
        if id.is_some() {
            None
        } else {
            Some(Pending::HyperlinkEnd)
        }
    } else {
        Some(Pending::HyperlinkStart { id, uri })
    }
}

#[cfg(test)]
mod tests {
    use crate::osc::{parsers::parse_body, Command};

    // ghostty: "OSC 8: hyperlink" (hyperlink.zig:59)
    #[test]
    fn osc_8_hyperlink_start_with_uri_only() {
        let parser = parse_body(b"8;;http://example.com", Some(0x1B));
        let Some(Command::HyperlinkStart { id, uri }) = parser.command() else {
            panic!("expected hyperlink start, got {:?}", parser.command());
        };
        assert_eq!(id, None);
        assert_eq!(uri, b"http://example.com");
    }

    // ghostty: "OSC 8: hyperlink with id set" (hyperlink.zig:74)
    #[test]
    fn osc_8_hyperlink_start_with_id() {
        let parser = parse_body(b"8;id=foo;http://example.com", Some(0x1B));
        let Some(Command::HyperlinkStart { id, uri }) = parser.command() else {
            panic!("expected hyperlink start, got {:?}", parser.command());
        };
        assert_eq!(id, Some(&b"foo"[..]));
        assert_eq!(uri, b"http://example.com");
    }

    // ghostty: "OSC 8: hyperlink with empty id" (hyperlink.zig:90)
    #[test]
    fn osc_8_hyperlink_empty_id_is_ignored() {
        let parser = parse_body(b"8;id=;http://example.com", Some(0x1B));
        let Some(Command::HyperlinkStart { id, uri }) = parser.command() else {
            panic!("expected hyperlink start, got {:?}", parser.command());
        };
        assert_eq!(id, None);
        assert_eq!(uri, b"http://example.com");
    }

    // ghostty: "OSC 8: hyperlink with incomplete key" (hyperlink.zig:106)
    #[test]
    fn osc_8_hyperlink_incomplete_key_stops_option_scan() {
        let parser = parse_body(b"8;id;http://example.com", Some(0x1B));
        let Some(Command::HyperlinkStart { id, uri }) = parser.command() else {
            panic!("expected hyperlink start, got {:?}", parser.command());
        };
        assert_eq!(id, None);
        assert_eq!(uri, b"http://example.com");
    }

    // ghostty: "OSC 8: hyperlink with empty key" (hyperlink.zig:122)
    #[test]
    fn osc_8_hyperlink_empty_key_is_skipped() {
        let parser = parse_body(b"8;=value;http://example.com", Some(0x1B));
        let Some(Command::HyperlinkStart { id, uri }) = parser.command() else {
            panic!("expected hyperlink start, got {:?}", parser.command());
        };
        assert_eq!(id, None);
        assert_eq!(uri, b"http://example.com");
    }

    // ghostty: "OSC 8: hyperlink with empty key and id" (hyperlink.zig:138)
    #[test]
    fn osc_8_hyperlink_empty_key_does_not_stop_later_id() {
        let parser = parse_body(b"8;=value:id=foo;http://example.com", Some(0x1B));
        let Some(Command::HyperlinkStart { id, uri }) = parser.command() else {
            panic!("expected hyperlink start, got {:?}", parser.command());
        };
        assert_eq!(id, Some(&b"foo"[..]));
        assert_eq!(uri, b"http://example.com");
    }

    // ghostty: "OSC 8: hyperlink with empty uri" (hyperlink.zig:154)
    #[test]
    fn osc_8_hyperlink_empty_uri_with_id_is_invalid() {
        let parser = parse_body(b"8;id=foo;", Some(0x1B));
        assert!(parser.command().is_none());
    }

    // ghostty: "OSC 8: hyperlink end" (hyperlink.zig:163)
    #[test]
    fn osc_8_hyperlink_end() {
        let parser = parse_body(b"8;;", Some(0x1B));
        assert_eq!(parser.command(), Some(Command::HyperlinkEnd));
    }
}
