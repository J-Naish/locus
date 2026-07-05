#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DecodeError;

pub(crate) fn printf_q_decode(output: &mut Vec<u8>, raw: &[u8]) -> Result<(), DecodeError> {
    let raw = if raw.starts_with(b"$'") {
        if raw.len() < 3 || raw.last() != Some(&b'\'') {
            return Err(DecodeError);
        }
        &raw[2..raw.len() - 1]
    } else if raw.starts_with(b"'") {
        if raw.len() < 2 || raw.last() != Some(&b'\'') {
            return Err(DecodeError);
        }
        &raw[1..raw.len() - 1]
    } else {
        raw
    };

    let mut index = 0;
    while index < raw.len() {
        if raw[index] != b'\\' {
            output.push(raw[index]);
            index += 1;
            continue;
        }
        index += 1;
        let Some(byte) = raw.get(index).copied() else {
            return Err(DecodeError);
        };
        match byte {
            b' ' | b'\\' | b'"' | b'\'' | b'$' => output.push(byte),
            b'e' => output.push(0x1B),
            b'n' => output.push(0x0A),
            b'r' => output.push(0x0D),
            b't' => output.push(0x09),
            b'v' => output.push(0x0B),
            _ => return Err(DecodeError),
        }
        index += 1;
    }
    Ok(())
}

pub(crate) fn url_percent_decode(output: &mut Vec<u8>, raw: &[u8]) -> Result<(), DecodeError> {
    let mut index = 0;
    while index < raw.len() {
        if raw[index] != b'%' {
            output.push(raw[index]);
            index += 1;
            continue;
        }
        let hi = *raw.get(index + 1).ok_or(DecodeError)?;
        let lo = *raw.get(index + 2).ok_or(DecodeError)?;
        output.push(from_hex(hi)? * 16 + from_hex(lo)?);
        index += 3;
    }
    Ok(())
}

fn from_hex(byte: u8) -> Result<u8, DecodeError> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => Err(DecodeError),
    }
}

#[cfg(test)]
mod tests {
    use super::{printf_q_decode, url_percent_decode, DecodeError};

    fn printf_q(input: &[u8]) -> Result<Vec<u8>, DecodeError> {
        let mut output = Vec::new();
        printf_q_decode(&mut output, input)?;
        Ok(output)
    }

    fn percent(input: &[u8]) -> Result<Vec<u8>, DecodeError> {
        let mut output = Vec::new();
        url_percent_decode(&mut output, input)?;
        Ok(output)
    }

    #[test]
    fn printf_q_1() {
        // ghostty: "printf_q 1" (string_encoding.zig:68)
        assert_eq!(printf_q(br"bobr\ kurwa").unwrap(), b"bobr kurwa");
    }

    #[test]
    fn printf_q_2() {
        // ghostty: "printf_q 2" (string_encoding.zig:80)
        assert_eq!(printf_q(br"bobr\nkurwa").unwrap(), b"bobr\nkurwa");
    }

    #[test]
    fn printf_q_3() {
        // ghostty: "printf_q 3" (string_encoding.zig:92)
        assert!(printf_q(br"bobr\dkurwa").is_err());
    }

    #[test]
    fn printf_q_4() {
        // ghostty: "printf_q 4" (string_encoding.zig:103)
        assert!(printf_q(br"bobr kurwa\").is_err());
    }

    #[test]
    fn printf_q_5() {
        // ghostty: "printf_q 5" (string_encoding.zig:114)
        assert_eq!(printf_q(br"$'bobr kurwa'").unwrap(), b"bobr kurwa");
    }

    #[test]
    fn printf_q_6() {
        // ghostty: "printf_q 6" (string_encoding.zig:126)
        assert_eq!(printf_q(br"'bobr kurwa'").unwrap(), b"bobr kurwa");
    }

    #[test]
    fn printf_q_7() {
        // ghostty: "printf_q 7" (string_encoding.zig:138)
        assert!(printf_q(br"$'bobr kurwa").is_err());
    }

    #[test]
    fn printf_q_8() {
        // ghostty: "printf_q 8" (string_encoding.zig:148)
        assert!(printf_q(br"$'").is_err());
    }

    #[test]
    fn printf_q_9() {
        // ghostty: "printf_q 9" (string_encoding.zig:158)
        assert!(printf_q(br"'bobr kurwa").is_err());
    }

    #[test]
    fn printf_q_10() {
        // ghostty: "printf_q 10" (string_encoding.zig:168)
        assert!(printf_q(br"'").is_err());
    }

    #[test]
    fn singles_percent() {
        // ghostty: "singles percent" (string_encoding.zig:202)
        for byte in 0u8..=254 {
            let input = format!("%{byte:02x}");
            assert_eq!(percent(input.as_bytes()).unwrap(), vec![byte]);
        }
        for byte in 0u8..=254 {
            let input = format!("%{byte:02X}");
            assert_eq!(percent(input.as_bytes()).unwrap(), vec![byte]);
        }
    }

    #[test]
    fn percent_1() {
        // ghostty: "percent 1" (string_encoding.zig:231)
        assert_eq!(percent(b"bobr%20kurwa").unwrap(), b"bobr kurwa");
    }

    #[test]
    fn percent_2() {
        // ghostty: "percent 2" (string_encoding.zig:243)
        assert!(percent(b"bobr%2kurwa").is_err());
    }

    #[test]
    fn percent_3() {
        // ghostty: "percent 3" (string_encoding.zig:254)
        assert!(percent(b"bobr%kurwa").is_err());
    }

    #[test]
    fn percent_4() {
        // ghostty: "percent 4" (string_encoding.zig:265)
        assert!(percent(b"bobr%%kurwa").is_err());
    }

    #[test]
    fn percent_5() {
        // ghostty: "percent 5" (string_encoding.zig:276)
        assert_eq!(percent(b"bobr%20kurwa%20").unwrap(), b"bobr kurwa ");
    }

    #[test]
    fn percent_6() {
        // ghostty: "percent 6" (string_encoding.zig:288)
        assert!(percent(b"bobr%20kurwa%2").is_err());
    }

    #[test]
    fn percent_7() {
        // ghostty: "percent 7" (string_encoding.zig:299)
        assert!(percent(b"bobr%20kurwa%").is_err());
    }
}
