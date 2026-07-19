fn trim_ascii_kitty(bytes: &[u8]) -> &[u8] {
    let trim = |byte: &u8| matches!(*byte, b' ' | b'\t' | b'\n' | b'\r' | 0x0B | 0x0C);
    let start = bytes
        .iter()
        .position(|byte| !trim(byte))
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|byte| !trim(byte))
        .map(|index| index + 1)
        .unwrap_or(start);
    &bytes[start..end]
}

pub(super) fn find_option_value<'a>(metadata: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    let mut index = 0;
    while index <= metadata.len() {
        let end = metadata[index..]
            .iter()
            .position(|byte| *byte == b':')
            .map(|position| index + position)
            .unwrap_or(metadata.len());
        let option = trim_ascii_kitty(&metadata[index..end]);
        if option.starts_with(key) {
            let rest = &option[key.len()..];
            let rest = trim_ascii_kitty(rest);
            if !rest.starts_with(b"=") {
                return None;
            }
            return Some(trim_ascii_kitty(&rest[1..]));
        }
        if end == metadata.len() {
            break;
        }
        index = end + 1;
    }
    None
}
