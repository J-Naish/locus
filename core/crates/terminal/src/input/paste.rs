//! Paste encoding and safety checks.

const BRACKETED_PREFIX: &[u8] = b"\x1b[200~";
const BRACKETED_SUFFIX: &[u8] = b"\x1b[201~";

const STRIP_BYTES: &[u8; 16] = &[
    0x00, // NUL
    0x08, // BS
    0x05, // ENQ
    0x04, // EOT
    0x1B, // ESC
    0x7F, // DEL
    0x03, // VINTR (Ctrl+C)
    0x1C, // VQUIT (Ctrl+\)
    0x15, // VKILL (Ctrl+U)
    0x1A, // VSUSP (Ctrl+Z)
    0x11, // VSTART (Ctrl+Q)
    0x13, // VSTOP (Ctrl+S)
    0x17, // VWERASE (Ctrl+W)
    0x16, // VLNEXT (Ctrl+V)
    0x12, // VREPRINT (Ctrl+R)
    0x0F, // VDISCARD (Ctrl+O)
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Options {
    pub bracketed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EncodedPaste<'a> {
    pub prefix: &'static [u8],
    pub body: &'a [u8],
    pub suffix: &'static [u8],
}

/// Returns false when data contains newline injection or a bracketed-paste end sentinel.
pub fn is_safe(data: &[u8]) -> bool {
    !data.contains(&b'\n')
        && !data
            .windows(BRACKETED_SUFFIX.len())
            .any(|w| w == BRACKETED_SUFFIX)
}

pub fn encode(data: &mut [u8], opts: Options) -> EncodedPaste<'_> {
    for byte in data.iter_mut() {
        if STRIP_BYTES.contains(byte) {
            *byte = b' ';
        }
    }

    let (prefix, suffix) = if opts.bracketed {
        (BRACKETED_PREFIX, BRACKETED_SUFFIX)
    } else {
        for byte in data.iter_mut() {
            if *byte == b'\n' {
                *byte = b'\r';
            }
        }
        (b"".as_slice(), b"".as_slice())
    };

    EncodedPaste {
        prefix,
        body: data,
        suffix,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn joined(result: EncodedPaste<'_>) -> Vec<u8> {
        [result.prefix, result.body, result.suffix].concat()
    }

    #[test]
    fn paste_is_safe_rejects_newlines_and_bracketed_end() {
        // ghostty: "isSafe" (paste.zig:136)
        assert!(is_safe(b"hello"));
        assert!(!is_safe(b"hello\n"));
        assert!(!is_safe(b"hello\nworld"));
        assert!(!is_safe(b"he\x1b[201~llo"));
    }

    #[test]
    fn paste_encode_bracketed_wraps_data() {
        // ghostty: "encode bracketed" (paste.zig:144)
        let mut data = b"hello".to_vec();
        let result = encode(&mut data, Options { bracketed: true });
        assert_eq!(result.prefix, b"\x1b[200~");
        assert_eq!(result.body, b"hello");
        assert_eq!(result.suffix, b"\x1b[201~");
        assert_eq!(joined(result), b"\x1b[200~hello\x1b[201~");
    }

    #[test]
    fn paste_encode_unbracketed_no_newlines_is_plain() {
        // ghostty: "encode unbracketed no newlines" (paste.zig:155)
        let mut data = b"hello".to_vec();
        let result = encode(&mut data, Options { bracketed: false });
        assert_eq!(result.prefix, b"");
        assert_eq!(result.body, b"hello");
        assert_eq!(result.suffix, b"");
    }

    #[test]
    fn paste_encode_unbracketed_newlines_mutates_owned_input() {
        // ghostty: "encode unbracketed newlines const" (paste.zig:166)
        let mut data = b"hello\nworld".to_vec();
        let result = encode(&mut data, Options { bracketed: false });
        assert_eq!(result.body, b"hello\rworld");
    }

    #[test]
    fn paste_encode_unbracketed_newlines() {
        // ghostty: "encode unbracketed newlines" (paste.zig:174)
        let mut data = b"hello\nworld".to_vec();
        let result = encode(&mut data, Options { bracketed: false });
        assert_eq!(result.prefix, b"");
        assert_eq!(result.body, b"hello\rworld");
        assert_eq!(result.suffix, b"");
    }

    #[test]
    fn paste_encode_unbracketed_windows_style_newline() {
        // ghostty: "encode unbracketed windows-stye newline" (paste.zig:184)
        let mut data = b"hello\r\nworld".to_vec();
        let result = encode(&mut data, Options { bracketed: false });
        assert_eq!(result.body, b"hello\r\rworld");
    }

    #[test]
    fn paste_encode_strip_unsafe_bytes_mutates_owned_input() {
        // ghostty: "encode strip unsafe bytes const" (paste.zig:194)
        let mut data = b"hello\x00world".to_vec();
        let result = encode(&mut data, Options { bracketed: true });
        assert_eq!(result.body, b"hello world");
    }

    #[test]
    fn paste_encode_strip_unsafe_bytes_mutable_bracketed() {
        // ghostty: "encode strip unsafe bytes mutable bracketed" (paste.zig:202)
        let mut data = b"hel\x1blo\x00world".to_vec();
        let result = encode(&mut data, Options { bracketed: true });
        assert_eq!(result.prefix, b"\x1b[200~");
        assert_eq!(result.body, b"hel lo world");
        assert_eq!(result.suffix, b"\x1b[201~");
    }

    #[test]
    fn paste_encode_strip_unsafe_bytes_mutable_unbracketed() {
        // ghostty: "encode strip unsafe bytes mutable unbracketed" (paste.zig:212)
        let mut data = b"hel\x03lo".to_vec();
        let result = encode(&mut data, Options { bracketed: false });
        assert_eq!(result.body, b"hel lo");
    }

    #[test]
    fn paste_encode_strip_multiple_unsafe_bytes() {
        // ghostty: "encode strip multiple unsafe bytes" (paste.zig:222)
        let mut data = b"\x00\x08\x7f".to_vec();
        let result = encode(&mut data, Options { bracketed: true });
        assert_eq!(result.body, b"   ");
    }
}
