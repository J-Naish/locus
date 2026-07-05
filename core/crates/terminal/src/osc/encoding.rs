pub(crate) fn is_safe_utf8(bytes: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    text.chars().all(|ch| {
        let value = ch as u32;
        !matches!(value, 0x00..=0x1F | 0x7F | 0x80..=0x9F)
    })
}

#[cfg(test)]
mod tests {
    use super::is_safe_utf8;

    // ghostty: encoding.zig safe utf8 test (encoding.zig:29)
    #[test]
    fn safe_utf8_rejects_controls_and_invalid_utf8() {
        assert!(is_safe_utf8(b"Hello world!"));
        assert!(is_safe_utf8("安全的ユニコード☀️".as_bytes()));
        assert!(!is_safe_utf8(b"No linebreaks\nallowed"));
        assert!(!is_safe_utf8(b"\x07no bells"));
        assert!(!is_safe_utf8(b"\x1b]9;no OSCs\x1b\\\x1b[m"));
        assert!(!is_safe_utf8(b"\x9f8-bit escapes are clever, but no"));
        assert!(!is_safe_utf8(b"\x7f"));
    }
}
