//! DFA-based non-allocating error-replacing UTF-8 decoder.
//!
//! This implementation is based largely on the work of Bjoern Hoehrmann, with
//! slight modifications to support replacement on ill-formed input. Details:
//! http://bjoern.hoehrmann.de/utf-8/decoder/dfa

const CHAR_CLASSES: [u8; 256] = generate_char_classes();

const TRANSITIONS: [u8; 108] = [
    0, 12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    12, 0, 12, 12, 12, 12, 12, 0, 12, 0, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12, 12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
];

const ACCEPT_STATE: u8 = 0;
const REJECT_STATE: u8 = 12;

const fn generate_char_classes() -> [u8; 256] {
    let mut classes = [0u8; 256];
    fill(&mut classes, 0x80, 0x8F, 1);
    fill(&mut classes, 0x90, 0x9F, 9);
    fill(&mut classes, 0xA0, 0xBF, 7);
    fill(&mut classes, 0xC0, 0xC1, 8);
    fill(&mut classes, 0xC2, 0xDF, 2);
    classes[0xE0] = 10;
    fill(&mut classes, 0xE1, 0xEC, 3);
    classes[0xED] = 4;
    fill(&mut classes, 0xEE, 0xEF, 3);
    classes[0xF0] = 11;
    fill(&mut classes, 0xF1, 0xF3, 6);
    classes[0xF4] = 5;
    fill(&mut classes, 0xF5, 0xFF, 8);
    classes
}

const fn fill(classes: &mut [u8; 256], from: usize, to: usize, value: u8) {
    let mut index = from;
    while index <= to {
        classes[index] = value;
        index += 1;
    }
}

#[derive(Debug, Clone, Copy, Default)]
pub struct Utf8Decoder {
    accumulator: u32,
    state: u8,
}

impl Utf8Decoder {
    pub fn next(&mut self, byte: u8) -> (Option<char>, bool) {
        let char_class = CHAR_CLASSES[byte as usize];
        let initial_state = self.state;

        if self.state != ACCEPT_STATE {
            self.accumulator <<= 6;
            self.accumulator |= u32::from(byte & 0x3F);
        } else {
            self.accumulator = (0xFFu32 >> char_class) & u32::from(byte);
        }

        self.state = TRANSITIONS[(self.state + char_class) as usize];

        if self.state == ACCEPT_STATE {
            let codepoint = self.accumulator;
            self.accumulator = 0;
            let decoded = char::from_u32(codepoint);
            debug_assert!(decoded.is_some(), "DFA accepted an invalid scalar");
            (Some(decoded.unwrap_or(char::REPLACEMENT_CHARACTER)), true)
        } else if self.state == REJECT_STATE {
            self.accumulator = 0;
            self.state = ACCEPT_STATE;
            (
                Some(char::REPLACEMENT_CHARACTER),
                initial_state == ACCEPT_STATE,
            )
        } else {
            (None, true)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Utf8Decoder;

    #[test]
    fn ascii_bytes_decode_to_their_own_codepoints() {
        let mut decoder = Utf8Decoder::default();
        let mut output = String::new();
        for byte in b"Hello, World!" {
            let (decoded, consumed) = decoder.next(*byte);
            assert!(consumed);
            if let Some(decoded) = decoded {
                output.push(decoded);
            }
        }
        assert_eq!(output, "Hello, World!");
    }

    #[test]
    fn well_formed_utf8_decodes_each_sequence_once() {
        let mut decoder = Utf8Decoder::default();
        let mut output = Vec::new();
        for byte in "😄✤ÁA".bytes() {
            let mut consumed = false;
            while !consumed {
                let (decoded, did_consume) = decoder.next(byte);
                consumed = did_consume;
                assert!(consumed);
                if let Some(decoded) = decoded {
                    output.push(decoded);
                }
            }
        }
        assert_eq!(output, ['\u{1F604}', '\u{2724}', '\u{C1}', 'A']);
    }

    #[test]
    fn invalid_utf8_emits_replacements_with_maximal_subparts() {
        let mut decoder = Utf8Decoder::default();
        let mut output = Vec::new();
        for byte in b"\xF0\x9F\xF0\x9F\x98\x84\xED\xA0\x80" {
            let mut consumed = false;
            while !consumed {
                let (decoded, did_consume) = decoder.next(*byte);
                consumed = did_consume;
                if let Some(decoded) = decoded {
                    output.push(decoded);
                }
            }
        }
        assert_eq!(
            output,
            [
                char::REPLACEMENT_CHARACTER,
                '\u{1F604}',
                char::REPLACEMENT_CHARACTER,
                char::REPLACEMENT_CHARACTER,
                char::REPLACEMENT_CHARACTER,
            ]
        );
    }
}
