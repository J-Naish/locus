use crate::osc::{KittyTextHAlign, KittyTextVAlign, Pending};

pub const MAX_PAYLOAD_LENGTH: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KittyTextSizing<'a> {
    pub scale: u8,
    pub width: u8,
    pub numerator: u8,
    pub denominator: u8,
    pub valign: KittyTextVAlign,
    pub halign: KittyTextHAlign,
    pub text: &'a [u8],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PendingKittyTextSizing {
    pub scale: u8,
    pub width: u8,
    pub numerator: u8,
    pub denominator: u8,
    pub valign: KittyTextVAlign,
    pub halign: KittyTextHAlign,
    pub text: std::ops::Range<usize>,
}

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    let separator = data.iter().position(|byte| *byte == b';')?;
    let metadata = &data[..separator];
    let payload = &data[separator + 1..];
    if payload.len() > MAX_PAYLOAD_LENGTH || !crate::osc::encoding::is_safe_utf8(payload) {
        return None;
    }
    let mut value = PendingKittyTextSizing {
        scale: 1,
        width: 0,
        numerator: 0,
        denominator: 0,
        valign: KittyTextVAlign::Top,
        halign: KittyTextHAlign::Left,
        text: separator + 1..data.len(),
    };
    if !metadata.is_empty() {
        for pair in metadata.split(|byte| *byte == b':') {
            let Some(eq) = pair.iter().position(|byte| *byte == b'=') else {
                continue;
            };
            let key = &pair[..eq];
            if key.len() != 1 {
                continue;
            }
            let value_end = pair[eq + 1..]
                .iter()
                .position(|byte| *byte == b'=')
                .map(|position| eq + 1 + position)
                .unwrap_or(pair.len());
            let Ok(text) = std::str::from_utf8(&pair[eq + 1..value_end]) else {
                continue;
            };
            let Ok(number) = text.parse::<u8>() else {
                continue;
            };
            if number > 15 {
                continue;
            }
            match key[0] {
                b's' if (1..=7).contains(&number) => value.scale = number,
                b'w' if number <= 7 => value.width = number,
                b'n' => value.numerator = number,
                b'd' => value.denominator = number,
                b'v' => {
                    value.valign = match number {
                        0 => KittyTextVAlign::Top,
                        1 => KittyTextVAlign::Bottom,
                        2 => KittyTextVAlign::Center,
                        _ => continue,
                    }
                }
                b'h' => {
                    value.halign = match number {
                        0 => KittyTextHAlign::Left,
                        1 => KittyTextHAlign::Right,
                        2 => KittyTextHAlign::Center,
                        _ => continue,
                    }
                }
                _ => {}
            }
        }
    }
    Some(Pending::KittyTextSizing(value))
}

#[cfg(test)]
mod tests {
    use super::MAX_PAYLOAD_LENGTH;
    use crate::osc::{Command, KittyTextHAlign, KittyTextVAlign};

    fn parser_for(input: &[u8]) -> crate::osc::Parser {
        super::super::parse_body(input, Some(0x1b))
    }

    // ghostty: "OSC 66: empty parameters" (kitty_text_sizing.zig:148)
    #[test]
    fn osc66_empty_parameters_use_defaults() {
        let parser = parser_for(b"66;;bobr");
        let Some(Command::KittyTextSizing(sizing)) = parser.command() else {
            panic!("expected kitty text sizing command");
        };
        assert_eq!(sizing.scale, 1);
        assert_eq!(sizing.text, b"bobr");
    }

    // ghostty: "OSC 66: single parameter" (kitty_text_sizing.zig:162)
    #[test]
    fn osc66_single_parameter_updates_scale() {
        let parser = parser_for(b"66;s=2;kurwa");
        let Some(Command::KittyTextSizing(sizing)) = parser.command() else {
            panic!("expected kitty text sizing command");
        };
        assert_eq!(sizing.scale, 2);
        assert_eq!(sizing.text, b"kurwa");
    }

    // ghostty: "OSC 66: multiple parameters" (kitty_text_sizing.zig:176)
    #[test]
    fn osc66_multiple_parameters_update_all_supported_fields() {
        let parser = parser_for(b"66;s=2:w=7:n=13:d=15:v=1:h=2;long");
        let Some(Command::KittyTextSizing(sizing)) = parser.command() else {
            panic!("expected kitty text sizing command");
        };
        assert_eq!(sizing.scale, 2);
        assert_eq!(sizing.width, 7);
        assert_eq!(sizing.numerator, 13);
        assert_eq!(sizing.denominator, 15);
        assert_eq!(sizing.valign, KittyTextVAlign::Bottom);
        assert_eq!(sizing.halign, KittyTextHAlign::Center);
        assert_eq!(sizing.text, b"long");
    }

    // ghostty: "OSC 66: scale is zero" (kitty_text_sizing.zig:195)
    #[test]
    fn osc66_zero_scale_is_ignored() {
        let parser = parser_for(b"66;s=0;nope");
        let Some(Command::KittyTextSizing(sizing)) = parser.command() else {
            panic!("expected kitty text sizing command");
        };
        assert_eq!(sizing.scale, 1);
    }

    // ghostty: "OSC 66: invalid parameters" (kitty_text_sizing.zig:208)
    #[test]
    fn osc66_invalid_parameters_are_ignored() {
        let parser = parser_for(b"66;w=8:v=3:n=16;");
        let Some(Command::KittyTextSizing(sizing)) = parser.command() else {
            panic!("expected kitty text sizing command");
        };
        assert_eq!(sizing.width, 0);
        assert_eq!(sizing.valign, KittyTextVAlign::Top);
        assert_eq!(sizing.numerator, 0);
    }

    // ghostty: "OSC 66: UTF-8" (kitty_text_sizing.zig:222)
    #[test]
    fn osc66_accepts_safe_utf8_payload() {
        let parser = parser_for("66;;👻魑魅魍魉ゴースッティ".as_bytes());
        let Some(Command::KittyTextSizing(sizing)) = parser.command() else {
            panic!("expected kitty text sizing command");
        };
        assert_eq!(sizing.text, "👻魑魅魍魉ゴースッティ".as_bytes());
    }

    // ghostty: "OSC 66: unsafe UTF-8" (kitty_text_sizing.zig:236)
    #[test]
    fn osc66_rejects_unsafe_utf8_payload() {
        let parser = parser_for(b"66;;\n");
        assert!(parser.command().is_none());
    }

    // ghostty: "OSC 66: overlong UTF-8" (kitty_text_sizing.zig:248)
    #[test]
    fn osc66_rejects_payloads_over_the_limit() {
        let mut input = Vec::from(&b"66;;"[..]);
        input.extend(std::iter::repeat_n(b'b', MAX_PAYLOAD_LENGTH + 1));
        let parser = parser_for(&input);
        assert!(parser.command().is_none());
    }
}
