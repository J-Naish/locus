use crate::color::{Dynamic, Rgb, Special};
use crate::osc::ColorTarget;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorOperationKind {
    Osc4,
    Osc5,
    Osc10,
    Osc11,
    Osc12,
    Osc13,
    Osc14,
    Osc15,
    Osc16,
    Osc17,
    Osc18,
    Osc19,
    Osc104,
    Osc105,
    Osc110,
    Osc111,
    Osc112,
    Osc113,
    Osc114,
    Osc115,
    Osc116,
    Osc117,
    Osc118,
    Osc119,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorRequest {
    Set { target: ColorTarget, color: Rgb },
    Query(ColorTarget),
    Reset(ColorTarget),
    ResetPalette,
    ResetSpecial,
}

pub(crate) fn parse_requests(kind: ColorOperationKind, data: &[u8]) -> Vec<ColorRequest> {
    let tokens: Vec<&[u8]> = data
        .split(|byte| *byte == b';')
        .filter(|token| !token.is_empty())
        .collect();
    match kind {
        ColorOperationKind::Osc4 | ColorOperationKind::Osc5 => parse_palette(kind, &tokens),
        ColorOperationKind::Osc104 | ColorOperationKind::Osc105 => {
            parse_palette_reset(kind, &tokens)
        }
        ColorOperationKind::Osc10
        | ColorOperationKind::Osc11
        | ColorOperationKind::Osc12
        | ColorOperationKind::Osc13
        | ColorOperationKind::Osc14
        | ColorOperationKind::Osc15
        | ColorOperationKind::Osc16
        | ColorOperationKind::Osc17
        | ColorOperationKind::Osc18
        | ColorOperationKind::Osc19 => parse_dynamic(kind, &tokens),
        ColorOperationKind::Osc110
        | ColorOperationKind::Osc111
        | ColorOperationKind::Osc112
        | ColorOperationKind::Osc113
        | ColorOperationKind::Osc114
        | ColorOperationKind::Osc115
        | ColorOperationKind::Osc116
        | ColorOperationKind::Osc117
        | ColorOperationKind::Osc118
        | ColorOperationKind::Osc119 => parse_dynamic_reset(kind, &tokens),
    }
}

fn parse_palette(kind: ColorOperationKind, tokens: &[&[u8]]) -> Vec<ColorRequest> {
    let mut requests = Vec::new();
    let mut chunks = tokens.chunks_exact(2);
    for pair in &mut chunks {
        let Ok(index) = parse_u16(pair[0]) else {
            return requests;
        };
        let Some(target) = palette_target(kind, index) else {
            return requests;
        };
        if pair[1] == b"?" {
            requests.push(ColorRequest::Query(target));
            continue;
        }
        let Ok(spec) = std::str::from_utf8(pair[1]) else {
            return requests;
        };
        let Ok(color) = Rgb::parse(spec) else {
            return requests;
        };
        requests.push(ColorRequest::Set { target, color });
    }
    requests
}

fn parse_palette_reset(kind: ColorOperationKind, tokens: &[&[u8]]) -> Vec<ColorRequest> {
    let mut requests = Vec::new();
    if tokens.is_empty() {
        requests.push(if kind == ColorOperationKind::Osc104 {
            ColorRequest::ResetPalette
        } else {
            ColorRequest::ResetSpecial
        });
        return requests;
    }
    for token in tokens {
        let Ok(index) = parse_u16(token) else {
            continue;
        };
        let Some(target) = palette_target_for_reset(kind, index) else {
            continue;
        };
        requests.push(ColorRequest::Reset(target));
    }
    requests
}

fn parse_dynamic(kind: ColorOperationKind, tokens: &[&[u8]]) -> Vec<ColorRequest> {
    let mut requests = Vec::new();
    let Some(mut dynamic) = dynamic_for_kind(kind) else {
        return requests;
    };
    for token in tokens {
        let target = ColorTarget::Dynamic(dynamic);
        if *token == b"?" {
            requests.push(ColorRequest::Query(target));
        } else {
            let Ok(spec) = std::str::from_utf8(token) else {
                return requests;
            };
            let Ok(color) = Rgb::parse(spec) else {
                return requests;
            };
            requests.push(ColorRequest::Set { target, color });
        }
        let Some(next) = dynamic.next() else {
            return requests;
        };
        dynamic = next;
    }
    requests
}

fn parse_dynamic_reset(kind: ColorOperationKind, tokens: &[&[u8]]) -> Vec<ColorRequest> {
    if !tokens.is_empty() {
        return Vec::new();
    }
    let Some(dynamic) = dynamic_for_reset_kind(kind) else {
        return Vec::new();
    };
    vec![ColorRequest::Reset(ColorTarget::Dynamic(dynamic))]
}

fn parse_u16(bytes: &[u8]) -> Result<u16, std::num::ParseIntError> {
    std::str::from_utf8(bytes)
        .unwrap_or_default()
        .parse::<u16>()
}

fn palette_target(kind: ColorOperationKind, index: u16) -> Option<ColorTarget> {
    if index > 511 {
        return None;
    }
    match kind {
        ColorOperationKind::Osc4 => match index {
            0..=255 => Some(ColorTarget::Palette(index as u8)),
            256..=260 => Some(ColorTarget::Special(special_from_index(index - 256)?)),
            _ => None,
        },
        ColorOperationKind::Osc5 => Some(ColorTarget::Special(special_from_index(index)?)),
        _ => None,
    }
}

fn palette_target_for_reset(kind: ColorOperationKind, index: u16) -> Option<ColorTarget> {
    match kind {
        ColorOperationKind::Osc104 => palette_target(ColorOperationKind::Osc4, index),
        // OSC 105 is not reachable from the trie but is kept for parse fidelity.
        ColorOperationKind::Osc105 => Some(ColorTarget::Special(special_from_index(index)?)),
        _ => None,
    }
}

fn special_from_index(index: u16) -> Option<Special> {
    match index {
        0 => Some(Special::Bold),
        1 => Some(Special::Underline),
        2 => Some(Special::Blink),
        3 => Some(Special::Reverse),
        4 => Some(Special::Italic),
        _ => None,
    }
}

fn dynamic_for_kind(kind: ColorOperationKind) -> Option<Dynamic> {
    match kind {
        ColorOperationKind::Osc10 => Some(Dynamic::Foreground),
        ColorOperationKind::Osc11 => Some(Dynamic::Background),
        ColorOperationKind::Osc12 => Some(Dynamic::Cursor),
        ColorOperationKind::Osc13 => Some(Dynamic::PointerForeground),
        ColorOperationKind::Osc14 => Some(Dynamic::PointerBackground),
        ColorOperationKind::Osc15 => Some(Dynamic::TektronixForeground),
        ColorOperationKind::Osc16 => Some(Dynamic::TektronixBackground),
        ColorOperationKind::Osc17 => Some(Dynamic::HighlightBackground),
        ColorOperationKind::Osc18 => Some(Dynamic::TektronixCursor),
        ColorOperationKind::Osc19 => Some(Dynamic::HighlightForeground),
        _ => None,
    }
}

fn dynamic_for_reset_kind(kind: ColorOperationKind) -> Option<Dynamic> {
    match kind {
        ColorOperationKind::Osc110 => Some(Dynamic::Foreground),
        ColorOperationKind::Osc111 => Some(Dynamic::Background),
        ColorOperationKind::Osc112 => Some(Dynamic::Cursor),
        ColorOperationKind::Osc113 => Some(Dynamic::PointerForeground),
        ColorOperationKind::Osc114 => Some(Dynamic::PointerBackground),
        ColorOperationKind::Osc115 => Some(Dynamic::TektronixForeground),
        ColorOperationKind::Osc116 => Some(Dynamic::TektronixBackground),
        ColorOperationKind::Osc117 => Some(Dynamic::HighlightBackground),
        ColorOperationKind::Osc118 => Some(Dynamic::TektronixCursor),
        ColorOperationKind::Osc119 => Some(Dynamic::HighlightForeground),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::{parse_requests, ColorOperationKind, ColorRequest};
    use crate::color::{Dynamic, Rgb, Special};
    use crate::osc::ColorTarget;

    fn red() -> Rgb {
        Rgb { r: 255, g: 0, b: 0 }
    }

    fn blue() -> Rgb {
        Rgb { r: 0, g: 0, b: 255 }
    }

    // ghostty: "OSC 4:" (color.zig:357)
    #[test]
    fn osc4_sets_queries_and_accepts_palette_and_special_targets() {
        for index in 0u8..=254 {
            let body = format!("{index};red");
            assert_eq!(
                parse_requests(ColorOperationKind::Osc4, body.as_bytes()),
                vec![ColorRequest::Set {
                    target: ColorTarget::Palette(index),
                    color: red(),
                }]
            );

            let body = format!("{index};?");
            assert_eq!(
                parse_requests(ColorOperationKind::Osc4, body.as_bytes()),
                vec![ColorRequest::Query(ColorTarget::Palette(index))]
            );

            let body = format!("{index};red;");
            assert_eq!(
                parse_requests(ColorOperationKind::Osc4, body.as_bytes()),
                vec![ColorRequest::Set {
                    target: ColorTarget::Palette(index),
                    color: red(),
                }]
            );

            let body = format!("{index};red ");
            assert_eq!(
                parse_requests(ColorOperationKind::Osc4, body.as_bytes()),
                vec![ColorRequest::Set {
                    target: ColorTarget::Palette(index),
                    color: red(),
                }]
            );
        }

        let specials = [
            Special::Bold,
            Special::Underline,
            Special::Blink,
            Special::Reverse,
            Special::Italic,
        ];
        for (index, special) in specials.into_iter().enumerate() {
            let body = format!("{};red", 256 + index);
            assert_eq!(
                parse_requests(ColorOperationKind::Osc4, body.as_bytes()),
                vec![ColorRequest::Set {
                    target: ColorTarget::Special(special),
                    color: red(),
                }]
            );
        }
    }

    // Non-portable upstream allocator-less test:
    // ghostty: "OSC 4: empty param" (color.zig:102).

    // ghostty: "OSC 5:" (color.zig:479)
    #[test]
    fn osc5_sets_special_targets() {
        let specials = [
            Special::Bold,
            Special::Underline,
            Special::Blink,
            Special::Reverse,
            Special::Italic,
        ];
        for (index, special) in specials.into_iter().enumerate() {
            let body = format!("{index};red");
            assert_eq!(
                parse_requests(ColorOperationKind::Osc5, body.as_bytes()),
                vec![ColorRequest::Set {
                    target: ColorTarget::Special(special),
                    color: red(),
                }]
            );
        }
    }

    // ghostty: "OSC 4: multiple requests" (color.zig:511)
    #[test]
    fn osc4_parses_multiple_requests_in_order() {
        assert_eq!(
            parse_requests(ColorOperationKind::Osc4, b"0;red;1;blue"),
            vec![
                ColorRequest::Set {
                    target: ColorTarget::Palette(0),
                    color: red(),
                },
                ColorRequest::Set {
                    target: ColorTarget::Palette(1),
                    color: blue(),
                },
            ]
        );

        assert_eq!(
            parse_requests(ColorOperationKind::Osc4, b"0;red;0;blue"),
            vec![
                ColorRequest::Set {
                    target: ColorTarget::Palette(0),
                    color: red(),
                },
                ColorRequest::Set {
                    target: ColorTarget::Palette(0),
                    color: blue(),
                },
            ]
        );
    }

    // ghostty: "OSC 104:" (color.zig:567)
    #[test]
    fn osc104_resets_palette_and_special_targets() {
        for index in 0u8..=254 {
            let body = index.to_string();
            assert_eq!(
                parse_requests(ColorOperationKind::Osc104, body.as_bytes()),
                vec![ColorRequest::Reset(ColorTarget::Palette(index))]
            );
        }

        let specials = [
            Special::Bold,
            Special::Underline,
            Special::Blink,
            Special::Reverse,
            Special::Italic,
        ];
        for (index, special) in specials.into_iter().enumerate() {
            let body = (256 + index).to_string();
            assert_eq!(
                parse_requests(ColorOperationKind::Osc104, body.as_bytes()),
                vec![ColorRequest::Reset(ColorTarget::Special(special))]
            );
        }
    }

    // ghostty: "OSC 104: empty index" (color.zig:618)
    #[test]
    fn osc104_skips_empty_reset_indices() {
        assert_eq!(
            parse_requests(ColorOperationKind::Osc104, b"0;;1"),
            vec![
                ColorRequest::Reset(ColorTarget::Palette(0)),
                ColorRequest::Reset(ColorTarget::Palette(1)),
            ]
        );
    }

    // ghostty: "OSC 104: invalid index" (color.zig:635)
    #[test]
    fn osc104_skips_invalid_reset_indices() {
        assert_eq!(
            parse_requests(ColorOperationKind::Osc104, b"ffff;1"),
            vec![ColorRequest::Reset(ColorTarget::Palette(1))]
        );
    }

    // ghostty: "OSC 104: reset all" (color.zig:648)
    #[test]
    fn osc104_empty_resets_entire_palette() {
        assert_eq!(
            parse_requests(ColorOperationKind::Osc104, b""),
            vec![ColorRequest::ResetPalette]
        );
    }

    // ghostty: "OSC 105: reset all" (color.zig:661)
    #[test]
    fn osc105_empty_resets_all_special_colors() {
        assert_eq!(
            parse_requests(ColorOperationKind::Osc105, b""),
            vec![ColorRequest::ResetSpecial]
        );
    }

    // ghostty: "OSC 10: OSC 11: OSC 12: OSC: 13: OSC 14: OSC 15: OSC: 16: OSC 17: OSC 18: OSC 19: dynamic" (color.zig:675)
    #[test]
    fn osc10_through_19_set_each_dynamic_color() {
        let cases = [
            (ColorOperationKind::Osc10, Dynamic::Foreground),
            (ColorOperationKind::Osc11, Dynamic::Background),
            (ColorOperationKind::Osc12, Dynamic::Cursor),
            (ColorOperationKind::Osc13, Dynamic::PointerForeground),
            (ColorOperationKind::Osc14, Dynamic::PointerBackground),
            (ColorOperationKind::Osc15, Dynamic::TektronixForeground),
            (ColorOperationKind::Osc16, Dynamic::TektronixBackground),
            (ColorOperationKind::Osc17, Dynamic::HighlightBackground),
            (ColorOperationKind::Osc18, Dynamic::TektronixCursor),
            (ColorOperationKind::Osc19, Dynamic::HighlightForeground),
        ];

        for (kind, dynamic) in cases {
            assert_eq!(
                parse_requests(kind, b"red"),
                vec![ColorRequest::Set {
                    target: ColorTarget::Dynamic(dynamic),
                    color: red(),
                }]
            );
        }
    }

    // ghostty: "OSC 10: OSC 11: OSC 12: OSC: 13: OSC 14: OSC 15: OSC: 16: OSC 17: OSC 18: OSC 19: dynamic multiple" (color.zig:703)
    #[test]
    fn osc_dynamic_requests_advance_the_target() {
        assert_eq!(
            parse_requests(ColorOperationKind::Osc11, b"red;blue"),
            vec![
                ColorRequest::Set {
                    target: ColorTarget::Dynamic(Dynamic::Background),
                    color: red(),
                },
                ColorRequest::Set {
                    target: ColorTarget::Dynamic(Dynamic::Cursor),
                    color: blue(),
                },
            ]
        );
    }

    // ghostty: "OSC 110: OSC 111: OSC 112: OSC: 113: OSC 114: OSC 115: OSC: 116: OSC 117: OSC 118: OSC 119: reset dynamic" (color.zig:735)
    #[test]
    fn osc110_through_119_reset_dynamic_colors_only_when_empty() {
        let cases = [
            (ColorOperationKind::Osc110, Dynamic::Foreground),
            (ColorOperationKind::Osc111, Dynamic::Background),
            (ColorOperationKind::Osc112, Dynamic::Cursor),
            (ColorOperationKind::Osc113, Dynamic::PointerForeground),
            (ColorOperationKind::Osc114, Dynamic::PointerBackground),
            (ColorOperationKind::Osc115, Dynamic::TektronixForeground),
            (ColorOperationKind::Osc116, Dynamic::TektronixBackground),
            (ColorOperationKind::Osc117, Dynamic::HighlightBackground),
            (ColorOperationKind::Osc118, Dynamic::TektronixCursor),
            (ColorOperationKind::Osc119, Dynamic::HighlightForeground),
        ];

        for (kind, dynamic) in cases {
            assert_eq!(
                parse_requests(kind, b""),
                vec![ColorRequest::Reset(ColorTarget::Dynamic(dynamic))]
            );
            assert_eq!(
                parse_requests(kind, b";"),
                vec![ColorRequest::Reset(ColorTarget::Dynamic(dynamic))]
            );
            assert_eq!(parse_requests(kind, b" "), Vec::new());
        }
    }
}
