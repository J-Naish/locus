use crate::osc::Pending;

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    if data.is_empty() {
        return None;
    }
    if data[0] == b';' {
        return Some(Pending::ClipboardContents {
            kind: b'c',
            data: 1..data.len(),
        });
    }
    if data.len() >= 2 && data[1] == b';' {
        return Some(Pending::ClipboardContents {
            kind: data[0],
            data: 2..data.len(),
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use crate::osc::{parsers::parse_body, Command};

    // ghostty: "OSC 52: get/set clipboard" (clipboard_operation.zig:50)
    #[test]
    fn osc_52_get_set_clipboard() {
        let parser = parse_body(b"52;s;?", None);
        let Some(Command::ClipboardContents { kind, data }) = parser.command() else {
            panic!("expected clipboard contents, got {:?}", parser.command());
        };
        assert_eq!(kind, b's');
        assert_eq!(data, b"?");
    }

    // ghostty: "OSC 52: get/set clipboard (optional parameter)" (clipboard_operation.zig:65)
    #[test]
    fn osc_52_optional_kind_defaults_to_clipboard() {
        let parser = parse_body(b"52;;?", None);
        let Some(Command::ClipboardContents { kind, data }) = parser.command() else {
            panic!("expected clipboard contents, got {:?}", parser.command());
        };
        assert_eq!(kind, b'c');
        assert_eq!(data, b"?");
    }

    // ghostty: "OSC 52: get/set clipboard with allocator" (clipboard_operation.zig:80)
    #[test]
    fn osc_52_allocator_variant_matches_default_rust_capture() {
        let parser = parse_body(b"52;s;?", None);
        let Some(Command::ClipboardContents { kind, data }) = parser.command() else {
            panic!("expected clipboard contents, got {:?}", parser.command());
        };
        assert_eq!(kind, b's');
        assert_eq!(data, b"?");
    }

    // ghostty: "OSC 52: clear clipboard" (clipboard_operation.zig:95)
    #[test]
    fn osc_52_clear_clipboard_allows_empty_payload() {
        let parser = parse_body(b"52;;", None);
        let Some(Command::ClipboardContents { kind, data }) = parser.command() else {
            panic!("expected clipboard contents, got {:?}", parser.command());
        };
        assert_eq!(kind, b'c');
        assert_eq!(data, b"");
    }
}
