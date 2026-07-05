//! SGR attribute parser.

use crate::color::{Name, Rgb};
use crate::parser::SepList;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Unknown<'a> {
    pub full: &'a [u16],
    pub partial: &'a [u16],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Underline {
    None = 0,
    Single = 1,
    Double = 2,
    Curly = 3,
    Dotted = 4,
    Dashed = 5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Attribute<'a> {
    Unset,
    Unknown(Unknown<'a>),
    Bold,
    ResetBold,
    Italic,
    ResetItalic,
    Faint,
    Underline(Underline),
    UnderlineColor(Rgb),
    UnderlineColor256(u8),
    ResetUnderlineColor,
    Overline,
    ResetOverline,
    Blink,
    ResetBlink,
    Inverse,
    ResetInverse,
    Invisible,
    ResetInvisible,
    Strikethrough,
    ResetStrikethrough,
    DirectColorFg(Rgb),
    DirectColorBg(Rgb),
    Bg8(Name),
    Fg8(Name),
    ResetFg,
    ResetBg,
    BrightBg8(Name),
    BrightFg8(Name),
    Bg256(u8),
    Fg256(u8),
}

pub struct Parser<'a> {
    params: &'a [u16],
    params_sep: SepList,
    idx: usize,
}

impl<'a> Parser<'a> {
    pub fn new(params: &'a [u16], params_sep: SepList) -> Self {
        Self {
            params,
            params_sep,
            idx: 0,
        }
    }

    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Option<Attribute<'a>> {
        if self.idx >= self.params.len() {
            let first_exhaustion = self.idx == 0;
            self.idx += 1;
            return first_exhaustion.then_some(Attribute::Unset);
        }

        let slice = &self.params[self.idx..];
        let colon = self.params_sep.is_set(self.idx);
        self.idx += 1;

        if colon && !matches!(slice[0], 4 | 38 | 48 | 58) {
            return Some(self.unknown_for_colon_run(slice));
        }

        let attribute = match slice[0] {
            0 => Attribute::Unset,
            1 => Attribute::Bold,
            2 => Attribute::Faint,
            3 => Attribute::Italic,
            4 => return Some(self.parse_underline(slice, colon)),
            5 | 6 => Attribute::Blink,
            7 => Attribute::Inverse,
            8 => Attribute::Invisible,
            9 => Attribute::Strikethrough,
            21 => Attribute::Underline(Underline::Double),
            22 => Attribute::ResetBold,
            23 => Attribute::ResetItalic,
            24 => Attribute::Underline(Underline::None),
            25 => Attribute::ResetBlink,
            27 => Attribute::ResetInverse,
            28 => Attribute::ResetInvisible,
            29 => Attribute::ResetStrikethrough,
            30..=37 => Attribute::Fg8(Name((slice[0] - 30) as u8)),
            38 => return Some(self.parse_extended_color(Attribute::DirectColorFg, slice, colon)),
            39 => Attribute::ResetFg,
            40..=47 => Attribute::Bg8(Name((slice[0] - 40) as u8)),
            48 => return Some(self.parse_extended_color(Attribute::DirectColorBg, slice, colon)),
            49 => Attribute::ResetBg,
            53 => Attribute::Overline,
            55 => Attribute::ResetOverline,
            58 => return Some(self.parse_extended_color(Attribute::UnderlineColor, slice, colon)),
            59 => Attribute::ResetUnderlineColor,
            90..=97 => Attribute::BrightFg8(Name((slice[0] - 82) as u8)),
            100..=107 => Attribute::BrightBg8(Name((slice[0] - 92) as u8)),
            _ => {
                return Some(Attribute::Unknown(Unknown {
                    full: self.params,
                    partial: slice,
                }));
            }
        };

        Some(attribute)
    }

    fn parse_underline(&mut self, slice: &'a [u16], colon: bool) -> Attribute<'a> {
        if !colon {
            return Attribute::Underline(Underline::Single);
        }
        if slice.len() < 2 {
            return Attribute::Unknown(Unknown {
                full: self.params,
                partial: slice,
            });
        }
        if self.params_sep.is_set(self.idx) {
            self.consume_unknown_colon();
            return Attribute::Unknown(Unknown {
                full: self.params,
                partial: slice,
            });
        }
        self.idx += 1;
        let underline = match slice[1] {
            0 => Underline::None,
            1 => Underline::Single,
            2 => Underline::Double,
            3 => Underline::Curly,
            4 => Underline::Dotted,
            5 => Underline::Dashed,
            _ => Underline::Single,
        };
        Attribute::Underline(underline)
    }

    fn parse_extended_color(
        &mut self,
        constructor: fn(Rgb) -> Attribute<'a>,
        slice: &'a [u16],
        colon: bool,
    ) -> Attribute<'a> {
        if slice.len() >= 2 {
            match slice[1] {
                2 => {
                    if let Some(attribute) = self.parse_direct_color(constructor, slice, colon) {
                        return attribute;
                    }
                }
                5 if slice.len() >= 3 => {
                    self.idx += 2;
                    let value = slice[2] as u8;
                    return match slice[0] {
                        38 => Attribute::Fg256(value),
                        48 => Attribute::Bg256(value),
                        58 => Attribute::UnderlineColor256(value),
                        _ => unreachable!("only extended-color SGR codes call this parser"),
                    };
                }
                _ => {}
            }
        }
        Attribute::Unknown(Unknown {
            full: self.params,
            partial: slice,
        })
    }

    fn parse_direct_color(
        &mut self,
        constructor: fn(Rgb) -> Attribute<'a>,
        slice: &'a [u16],
        colon: bool,
    ) -> Option<Attribute<'a>> {
        if slice.len() < 5 {
            return None;
        }
        debug_assert_eq!(slice[1], 2);
        if !colon {
            self.idx += 4;
            return Some(constructor(Rgb {
                r: slice[2] as u8,
                g: slice[3] as u8,
                b: slice[4] as u8,
            }));
        }

        match self.count_colon() {
            3 => {
                self.idx += 4;
                Some(constructor(Rgb {
                    r: slice[2] as u8,
                    g: slice[3] as u8,
                    b: slice[4] as u8,
                }))
            }
            4 => {
                if slice.len() < 6 {
                    self.consume_unknown_colon();
                    return None;
                }
                self.idx += 5;
                Some(constructor(Rgb {
                    r: slice[3] as u8,
                    g: slice[4] as u8,
                    b: slice[5] as u8,
                }))
            }
            _ => {
                self.consume_unknown_colon();
                None
            }
        }
    }

    fn count_colon(&self) -> usize {
        let mut count = 0;
        let mut index = self.idx;
        while index < self.params.len().saturating_sub(1) && self.params_sep.is_set(index) {
            count += 1;
            index += 1;
        }
        count
    }

    fn consume_unknown_colon(&mut self) {
        self.idx += self.count_colon() + 1;
    }

    fn unknown_for_colon_run(&mut self, slice: &'a [u16]) -> Attribute<'a> {
        let start = self.idx;
        while self.params_sep.is_set(self.idx) {
            self.idx += 1;
        }
        self.idx += 1;
        let len = (self.idx - start + 1).min(slice.len());
        Attribute::Unknown(Unknown {
            full: self.params,
            partial: &slice[..len],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::{Attribute, Parser, Underline, Unknown};
    use crate::color::{Name, Rgb};
    use crate::parser::SepList;

    fn test_parse(params: &[u16]) -> Attribute<'_> {
        Parser::new(params, SepList::default()).next().unwrap()
    }

    fn test_parse_colon(params: &[u16]) -> Attribute<'_> {
        let mut sep = SepList::default();
        for i in 0..params.len() - 1 {
            sep.set(i);
        }
        Parser::new(params, sep).next().unwrap()
    }

    // ghostty skips only the ABI helper test: "sgr: Attribute C compat" (sgr.zig:537)

    // ghostty: "sgr: Parser" (sgr.zig:541)
    #[test]
    fn parser() {
        assert_eq!(test_parse(&[]), Attribute::Unset);
        assert_eq!(test_parse(&[0]), Attribute::Unset);
        assert_eq!(
            test_parse(&[38, 2, 40, 44, 52]),
            Attribute::DirectColorFg(Rgb {
                r: 40,
                g: 44,
                b: 52
            })
        );
        assert!(matches!(
            test_parse(&[38, 2, 44, 52]),
            Attribute::Unknown(_)
        ));
        assert_eq!(
            test_parse(&[48, 2, 40, 44, 52]),
            Attribute::DirectColorBg(Rgb {
                r: 40,
                g: 44,
                b: 52
            })
        );
        assert!(matches!(
            test_parse(&[48, 2, 44, 52]),
            Attribute::Unknown(_)
        ));
    }

    // ghostty: "sgr: Parser multiple" (sgr.zig:566)
    #[test]
    fn parser_multiple() {
        let mut parser = Parser::new(&[0, 38, 2, 40, 44, 52], SepList::default());
        assert_eq!(parser.next(), Some(Attribute::Unset));
        assert_eq!(
            parser.next(),
            Some(Attribute::DirectColorFg(Rgb {
                r: 40,
                g: 44,
                b: 52
            }))
        );
        assert_eq!(parser.next(), None);
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: unsupported with colon" (sgr.zig:574)
    #[test]
    fn unsupported_with_colon() {
        let mut sep = SepList::default();
        sep.set(0);
        let mut parser = Parser::new(&[0, 4, 1], sep);
        assert!(matches!(parser.next(), Some(Attribute::Unknown(_))));
        assert_eq!(parser.next(), Some(Attribute::Bold));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: unsupported with multiple colon" (sgr.zig:588)
    #[test]
    fn unsupported_with_multiple_colon() {
        let mut sep = SepList::default();
        sep.set(0);
        sep.set(1);
        let mut parser = Parser::new(&[0, 4, 2, 1], sep);
        assert!(matches!(parser.next(), Some(Attribute::Unknown(_))));
        assert_eq!(parser.next(), Some(Attribute::Bold));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: bold" (sgr.zig:603)
    #[test]
    fn bold() {
        assert_eq!(test_parse(&[1]), Attribute::Bold);
        assert_eq!(test_parse(&[22]), Attribute::ResetBold);
    }

    // ghostty: "sgr: italic" (sgr.zig:615)
    #[test]
    fn italic() {
        assert_eq!(test_parse(&[3]), Attribute::Italic);
        assert_eq!(test_parse(&[23]), Attribute::ResetItalic);
    }

    // ghostty: "sgr: underline" (sgr.zig:627)
    #[test]
    fn underline() {
        assert_eq!(test_parse(&[4]), Attribute::Underline(Underline::Single));
        assert_eq!(test_parse(&[24]), Attribute::Underline(Underline::None));
    }

    // ghostty: "sgr: underline styles" (sgr.zig:640)
    #[test]
    fn underline_styles() {
        assert_eq!(
            test_parse_colon(&[4, 2]),
            Attribute::Underline(Underline::Double)
        );
        assert_eq!(
            test_parse_colon(&[4, 0]),
            Attribute::Underline(Underline::None)
        );
        assert_eq!(
            test_parse_colon(&[4, 1]),
            Attribute::Underline(Underline::Single)
        );
        assert_eq!(
            test_parse_colon(&[4, 3]),
            Attribute::Underline(Underline::Curly)
        );
        assert_eq!(
            test_parse_colon(&[4, 4]),
            Attribute::Underline(Underline::Dotted)
        );
        assert_eq!(
            test_parse_colon(&[4, 5]),
            Attribute::Underline(Underline::Dashed)
        );
    }

    // ghostty: "sgr: underline style with more" (sgr.zig:678)
    #[test]
    fn underline_style_with_more() {
        let mut sep = SepList::default();
        sep.set(0);
        let mut parser = Parser::new(&[4, 2, 1], sep);
        assert_eq!(parser.next(), Some(Attribute::Underline(Underline::Double)));
        assert_eq!(parser.next(), Some(Attribute::Bold));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: underline style with too many colons" (sgr.zig:693)
    #[test]
    fn underline_style_with_too_many_colons() {
        let mut sep = SepList::default();
        sep.set(0);
        sep.set(1);
        let mut parser = Parser::new(&[4, 2, 3, 1], sep);
        assert!(matches!(parser.next(), Some(Attribute::Unknown(_))));
        assert_eq!(parser.next(), Some(Attribute::Bold));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: blink" (sgr.zig:709)
    #[test]
    fn blink() {
        assert_eq!(test_parse(&[5]), Attribute::Blink);
        assert_eq!(test_parse(&[6]), Attribute::Blink);
        assert_eq!(test_parse(&[25]), Attribute::ResetBlink);
    }

    // ghostty: "sgr: inverse" (sgr.zig:726)
    #[test]
    fn inverse() {
        assert_eq!(test_parse(&[7]), Attribute::Inverse);
        assert_eq!(test_parse(&[27]), Attribute::ResetInverse);
    }

    // ghostty: "sgr: strikethrough" (sgr.zig:738)
    #[test]
    fn strikethrough() {
        assert_eq!(test_parse(&[9]), Attribute::Strikethrough);
        assert_eq!(test_parse(&[29]), Attribute::ResetStrikethrough);
    }

    // ghostty: "sgr: 8 color" (sgr.zig:750)
    #[test]
    fn eight_color() {
        let mut parser = Parser::new(&[31, 43, 90, 103], SepList::default());
        assert_eq!(parser.next(), Some(Attribute::Fg8(Name::RED)));
        assert_eq!(parser.next(), Some(Attribute::Bg8(Name::YELLOW)));
        assert_eq!(
            parser.next(),
            Some(Attribute::BrightFg8(Name::BRIGHT_BLACK))
        );
        assert_eq!(
            parser.next(),
            Some(Attribute::BrightBg8(Name::BRIGHT_YELLOW))
        );
    }

    // ghostty: "sgr: 256 color" (sgr.zig:778)
    #[test]
    fn two_hundred_fifty_six_color() {
        let mut parser = Parser::new(&[38, 5, 161, 48, 5, 236], SepList::default());
        assert_eq!(parser.next(), Some(Attribute::Fg256(161)));
        assert_eq!(parser.next(), Some(Attribute::Bg256(236)));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: 256 color underline" (sgr.zig:785)
    #[test]
    fn two_hundred_fifty_six_color_underline() {
        let mut parser = Parser::new(&[58, 5, 9], SepList::default());
        assert_eq!(parser.next(), Some(Attribute::UnderlineColor256(9)));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: 24-bit bg color" (sgr.zig:791)
    #[test]
    fn twenty_four_bit_bg_color() {
        assert_eq!(
            test_parse_colon(&[48, 2, 1, 2, 3]),
            Attribute::DirectColorBg(Rgb { r: 1, g: 2, b: 3 })
        );
    }

    // ghostty: "sgr: underline color" (sgr.zig:801)
    #[test]
    fn underline_color() {
        assert_eq!(
            test_parse_colon(&[58, 2, 1, 2, 3]),
            Attribute::UnderlineColor(Rgb { r: 1, g: 2, b: 3 })
        );
        assert_eq!(
            test_parse_colon(&[58, 2, 0, 1, 2, 3]),
            Attribute::UnderlineColor(Rgb { r: 1, g: 2, b: 3 })
        );
    }

    // ghostty: "sgr: reset underline color" (sgr.zig:819)
    #[test]
    fn reset_underline_color() {
        let mut parser = Parser::new(&[59], SepList::default());
        assert_eq!(parser.next(), Some(Attribute::ResetUnderlineColor));
    }

    // ghostty: "sgr: invisible" (sgr.zig:824)
    #[test]
    fn invisible() {
        let mut parser = Parser::new(&[8, 28], SepList::default());
        assert_eq!(parser.next(), Some(Attribute::Invisible));
        assert_eq!(parser.next(), Some(Attribute::ResetInvisible));
    }

    // ghostty: "sgr: underline, bg, and fg" (sgr.zig:830)
    #[test]
    fn underline_bg_and_fg() {
        let mut parser = Parser::new(
            &[4, 38, 2, 255, 247, 219, 48, 2, 242, 93, 147, 4],
            SepList::default(),
        );
        assert_eq!(parser.next(), Some(Attribute::Underline(Underline::Single)));
        assert_eq!(
            parser.next(),
            Some(Attribute::DirectColorFg(Rgb {
                r: 255,
                g: 247,
                b: 219
            }))
        );
        assert_eq!(
            parser.next(),
            Some(Attribute::DirectColorBg(Rgb {
                r: 242,
                g: 93,
                b: 147
            }))
        );
        assert_eq!(parser.next(), Some(Attribute::Underline(Underline::Single)));
    }

    // ghostty: "sgr: direct color fg missing color" (sgr.zig:860)
    #[test]
    fn direct_color_fg_missing_color_does_not_crash() {
        let mut parser = Parser::new(&[38, 5], SepList::default());
        while parser.next().is_some() {}
    }

    // ghostty: "sgr: direct color bg missing color" (sgr.zig:866)
    #[test]
    fn direct_color_bg_missing_color_does_not_crash() {
        let mut parser = Parser::new(&[48, 5], SepList::default());
        while parser.next().is_some() {}
    }

    // ghostty: "sgr: direct fg/bg/underline ignore optional color space" (sgr.zig:872)
    #[test]
    fn direct_colors_handle_optional_color_space_only_for_colon_form() {
        assert_eq!(
            test_parse_colon(&[38, 2, 0, 1, 2, 3]),
            Attribute::DirectColorFg(Rgb { r: 1, g: 2, b: 3 })
        );
        assert_eq!(
            test_parse_colon(&[48, 2, 0, 1, 2, 3]),
            Attribute::DirectColorBg(Rgb { r: 1, g: 2, b: 3 })
        );
        assert_eq!(
            test_parse_colon(&[58, 2, 0, 1, 2, 3]),
            Attribute::UnderlineColor(Rgb { r: 1, g: 2, b: 3 })
        );
        assert_eq!(
            test_parse(&[38, 2, 0, 1, 2, 3]),
            Attribute::DirectColorFg(Rgb { r: 0, g: 1, b: 2 })
        );
        assert_eq!(
            test_parse(&[48, 2, 0, 1, 2, 3]),
            Attribute::DirectColorBg(Rgb { r: 0, g: 1, b: 2 })
        );
        assert_eq!(
            test_parse(&[58, 2, 0, 1, 2, 3]),
            Attribute::UnderlineColor(Rgb { r: 0, g: 1, b: 2 })
        );
    }

    // ghostty: "sgr: direct fg colon with too many colons" (sgr.zig:928)
    #[test]
    fn direct_fg_colon_with_too_many_colons() {
        let mut sep = SepList::default();
        for index in 0..6 {
            sep.set(index);
        }
        let mut parser = Parser::new(&[38, 2, 0, 1, 2, 3, 4, 1], sep);
        assert!(matches!(parser.next(), Some(Attribute::Unknown(_))));
        assert_eq!(parser.next(), Some(Attribute::Bold));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: direct fg colon with colorspace and extra param" (sgr.zig:943)
    #[test]
    fn direct_fg_colon_with_colorspace_and_extra_param() {
        let mut sep = SepList::default();
        for index in 0..5 {
            sep.set(index);
        }
        let mut parser = Parser::new(&[38, 2, 0, 1, 2, 3, 1], sep);
        assert_eq!(
            parser.next(),
            Some(Attribute::DirectColorFg(Rgb { r: 1, g: 2, b: 3 }))
        );
        assert_eq!(parser.next(), Some(Attribute::Bold));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: direct fg colon no colorspace and extra param" (sgr.zig:965)
    #[test]
    fn direct_fg_colon_no_colorspace_and_extra_param() {
        let mut sep = SepList::default();
        for index in 0..4 {
            sep.set(index);
        }
        let mut parser = Parser::new(&[38, 2, 1, 2, 3, 1], sep);
        assert_eq!(
            parser.next(),
            Some(Attribute::DirectColorFg(Rgb { r: 1, g: 2, b: 3 }))
        );
        assert_eq!(parser.next(), Some(Attribute::Bold));
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: kakoune input" (sgr.zig:988)
    #[test]
    fn kakoune_input() {
        let mut sep = SepList::default();
        for index in [1, 8, 9, 10, 11, 12] {
            sep.set(index);
        }
        let mut parser = Parser::new(&[0, 4, 3, 38, 2, 175, 175, 215, 58, 2, 0, 190, 80, 70], sep);
        assert_eq!(parser.next(), Some(Attribute::Unset));
        assert_eq!(parser.next(), Some(Attribute::Underline(Underline::Curly)));
        assert_eq!(
            parser.next(),
            Some(Attribute::DirectColorFg(Rgb {
                r: 175,
                g: 175,
                b: 215
            }))
        );
        assert_eq!(
            parser.next(),
            Some(Attribute::UnderlineColor(Rgb {
                r: 190,
                g: 80,
                b: 70
            }))
        );
        // Ghostty intentionally leaves the final exhaustion assertion commented.
    }

    // ghostty: "sgr: kakoune input issue underline, fg, and bg" (sgr.zig:1032)
    #[test]
    fn kakoune_input_issue_underline_fg_and_bg() {
        let mut sep = SepList::default();
        sep.set(0);
        let mut parser = Parser::new(
            &[
                4, 3, 38, 2, 51, 51, 51, 48, 2, 170, 170, 170, 58, 2, 255, 97, 136,
            ],
            sep,
        );
        assert_eq!(parser.next(), Some(Attribute::Underline(Underline::Curly)));
        assert_eq!(
            parser.next(),
            Some(Attribute::DirectColorFg(Rgb {
                r: 51,
                g: 51,
                b: 51
            }))
        );
        assert_eq!(
            parser.next(),
            Some(Attribute::DirectColorBg(Rgb {
                r: 170,
                g: 170,
                b: 170
            }))
        );
        assert_eq!(
            parser.next(),
            Some(Attribute::UnderlineColor(Rgb {
                r: 255,
                g: 97,
                b: 136
            }))
        );
        assert_eq!(parser.next(), None);
    }

    // ghostty: "sgr: underline colon with trailing separator and short slice" (sgr.zig:1083)
    #[test]
    fn underline_colon_with_trailing_separator_and_short_slice() {
        let mut sep = SepList::default();
        sep.set(0);
        sep.set(1);
        let mut parser = Parser::new(&[58, 4], sep);
        assert!(matches!(parser.next(), Some(Attribute::Unknown(_))));
        assert!(matches!(parser.next(), Some(Attribute::Unknown(_))));
        assert_eq!(parser.next(), None);
    }

    #[test]
    fn unknown_partial_covers_the_colon_run() {
        let mut sep = SepList::default();
        sep.set(0);
        let mut parser = Parser::new(&[0, 4, 1], sep);
        assert_eq!(
            parser.next(),
            Some(Attribute::Unknown(Unknown {
                full: &[0, 4, 1],
                partial: &[0, 4]
            }))
        );
        let mut parser = Parser::new(&[99], SepList::default());
        assert_eq!(
            parser.next(),
            Some(Attribute::Unknown(Unknown {
                full: &[99],
                partial: &[99]
            }))
        );
    }
}
