use std::fmt;

use crate::color::Rgb;
use crate::osc::{KittyColorKind, Pending, Terminator};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittySpecial {
    Foreground,
    Background,
    SelectionForeground,
    SelectionBackground,
    Cursor,
    CursorText,
    VisualBell,
    SecondTransparentBackground,
}

impl KittyColorKind {
    pub const MAX: usize = u8::MAX as usize + 8;

    pub fn parse(key: &[u8]) -> Option<Self> {
        Some(match key {
            b"foreground" => Self::Special(KittySpecial::Foreground),
            b"background" => Self::Special(KittySpecial::Background),
            b"selection_foreground" => Self::Special(KittySpecial::SelectionForeground),
            b"selection_background" => Self::Special(KittySpecial::SelectionBackground),
            b"cursor" => Self::Special(KittySpecial::Cursor),
            b"cursor_text" => Self::Special(KittySpecial::CursorText),
            b"visual_bell" => Self::Special(KittySpecial::VisualBell),
            b"second_transparent_background" => {
                Self::Special(KittySpecial::SecondTransparentBackground)
            }
            _ => Self::Palette(std::str::from_utf8(key).ok()?.parse::<u8>().ok()?),
        })
    }
}

impl fmt::Display for KittyColorKind {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Palette(index) => write!(formatter, "{index}"),
            Self::Special(special) => formatter.write_str(match special {
                KittySpecial::Foreground => "foreground",
                KittySpecial::Background => "background",
                KittySpecial::SelectionForeground => "selection_foreground",
                KittySpecial::SelectionBackground => "selection_background",
                KittySpecial::Cursor => "cursor",
                KittySpecial::CursorText => "cursor_text",
                KittySpecial::VisualBell => "visual_bell",
                KittySpecial::SecondTransparentBackground => "second_transparent_background",
            }),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyColorRequest {
    Query(KittyColorKind),
    Set { key: KittyColorKind, color: Rgb },
    Reset(KittyColorKind),
}

pub(crate) fn parse(data: &[u8], terminator: Terminator) -> Option<Pending> {
    let mut requests = Vec::new();
    for kv in data.split(|byte| *byte == b';') {
        if requests.len() >= KittyColorKind::MAX * 2 {
            return None;
        }
        let eq = kv.iter().position(|byte| *byte == b'=');
        let (key, value) = if let Some(eq) = eq {
            (&kv[..eq], &kv[eq + 1..])
        } else {
            (kv, &[][..])
        };
        if key.is_empty() {
            continue;
        }
        let Some(kind) = KittyColorKind::parse(key) else {
            continue;
        };
        let value = trim_spaces(value);
        if value.is_empty() {
            requests.push(KittyColorRequest::Reset(kind));
        } else if value == b"?" {
            requests.push(KittyColorRequest::Query(kind));
        } else if let Ok(text) = std::str::from_utf8(value) {
            if let Ok(color) = Rgb::parse(text) {
                requests.push(KittyColorRequest::Set { key: kind, color });
            }
        }
    }
    Some(Pending::KittyColorProtocol {
        requests,
        terminator,
    })
}

fn trim_spaces(bytes: &[u8]) -> &[u8] {
    let start = bytes
        .iter()
        .position(|byte| *byte != b' ')
        .unwrap_or(bytes.len());
    let end = bytes
        .iter()
        .rposition(|byte| *byte != b' ')
        .map(|index| index + 1)
        .unwrap_or(start);
    &bytes[start..end]
}

#[cfg(test)]
mod tests {
    use super::{KittyColorRequest, KittySpecial};
    use crate::color::Rgb;
    use crate::osc::{Command, KittyColorKind, State, Terminator};

    const BIG_INPUT: &[u8] = b"21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";

    fn parser_for(input: &[u8]) -> crate::osc::Parser {
        super::super::parse_body(input, Some(0x1b))
    }

    fn aliceblue() -> Rgb {
        Rgb {
            r: 0xf0,
            g: 0xf8,
            b: 0xff,
        }
    }

    // ghostty: "OSC 21: kitty color protocol" (kitty_color.zig:80)
    #[test]
    fn osc21_parses_kitty_color_protocol_requests() {
        let parser = parser_for(BIG_INPUT);
        let Command::KittyColorProtocol {
            requests,
            terminator,
        } = parser.command().expect("expected kitty color command")
        else {
            panic!("expected kitty color protocol");
        };

        assert_eq!(terminator, Terminator::St);
        assert_eq!(requests.len(), 9);
        assert_eq!(
            requests[0],
            KittyColorRequest::Query(KittyColorKind::Special(KittySpecial::Foreground))
        );
        assert_eq!(
            requests[1],
            KittyColorRequest::Set {
                key: KittyColorKind::Special(KittySpecial::Background),
                color: aliceblue(),
            }
        );
        assert_eq!(
            requests[2],
            KittyColorRequest::Set {
                key: KittyColorKind::Special(KittySpecial::Cursor),
                color: aliceblue(),
            }
        );
        assert_eq!(
            requests[3],
            KittyColorRequest::Reset(KittyColorKind::Special(KittySpecial::CursorText))
        );
        assert_eq!(
            requests[4],
            KittyColorRequest::Reset(KittyColorKind::Special(KittySpecial::VisualBell))
        );
        assert_eq!(
            requests[5],
            KittyColorRequest::Query(KittyColorKind::Special(KittySpecial::SelectionBackground))
        );
        assert_eq!(
            requests[6],
            KittyColorRequest::Set {
                key: KittyColorKind::Special(KittySpecial::SelectionBackground),
                color: Rgb {
                    r: 0xaa,
                    g: 0xbb,
                    b: 0xcc,
                },
            }
        );
        assert_eq!(
            requests[7],
            KittyColorRequest::Query(KittyColorKind::Palette(2))
        );
        assert_eq!(
            requests[8],
            KittyColorRequest::Set {
                key: KittyColorKind::Palette(3),
                color: Rgb {
                    r: 0xff,
                    g: 0xff,
                    b: 0xff,
                },
            }
        );
    }

    // Non-portable upstream allocator-less test:
    // ghostty: "OSC 21: kitty color protocol without allocator" (kitty_color.zig:151).

    // ghostty: "OSC 21: kitty color protocol double reset" (kitty_color.zig:164)
    #[test]
    fn osc21_parser_can_reset_twice_after_successful_command() {
        let mut parser = super::super::parse_body(BIG_INPUT, Some(0x1b));
        assert!(matches!(
            parser.command(),
            Some(Command::KittyColorProtocol { .. })
        ));
        parser.reset();
        parser.reset();
        assert_eq!(parser.state, State::Start);
    }

    // ghostty: "OSC 21: kitty color protocol reset after invalid" (kitty_color.zig:181)
    #[test]
    fn osc21_parser_can_reset_after_invalid_state() {
        let mut parser = super::super::parse_body(BIG_INPUT, Some(0x1b));
        assert!(matches!(
            parser.command(),
            Some(Command::KittyColorProtocol { .. })
        ));
        parser.reset();
        assert_eq!(parser.state, State::Start);
        parser.next(b'X');
        assert_eq!(parser.state, State::Invalid);
        parser.reset();
        assert_eq!(parser.state, State::Start);
    }

    // ghostty: "OSC 21: kitty color protocol no key" (kitty_color.zig:202)
    #[test]
    fn osc21_empty_key_yields_empty_request_list() {
        let parser = parser_for(b"21;");
        let Command::KittyColorProtocol { requests, .. } =
            parser.command().expect("expected kitty color protocol")
        else {
            panic!("expected kitty color protocol");
        };
        assert!(requests.is_empty());
    }

    // ghostty: "OSC: kitty color protocol kind string" (kitty/color.zig:65)
    #[test]
    fn kitty_color_kind_formats_like_ghostty() {
        assert_eq!(
            KittyColorKind::Special(KittySpecial::Foreground).to_string(),
            "foreground"
        );
        assert_eq!(KittyColorKind::Palette(42).to_string(), "42");
    }
}
