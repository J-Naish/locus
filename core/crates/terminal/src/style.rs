//! Terminal cell style storage and resolution.
//!
//! Ghostty stores styles in a ref-counted set. This port uses `PackedStyle`
//! as the set value directly: the u128 bit layout is the storage format.
//! The storage layer and the VT/HTML formatters are kept together because the
//! formatter output is a direct view of the packed style fields.

use crate::color::{Palette, Rgb};
use crate::page::{Cell, CellContentTag};
use crate::ref_counted_set::{RefCountedSet, RefCountedSetContext};
use crate::sgr;
use crate::size::{BufValue, StyleCountInt};
use std::fmt;

pub type StyleId = StyleCountInt;
pub const DEFAULT_STYLE_ID: StyleId = 0;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum StyleColor {
    #[default]
    None,
    Palette(u8),
    Rgb(Rgb),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StyleFlags {
    pub bold: bool,
    pub italic: bool,
    pub faint: bool,
    pub blink: bool,
    pub inverse: bool,
    pub invisible: bool,
    pub strikethrough: bool,
    pub overline: bool,
    pub underline: sgr::Underline,
}

impl Default for StyleFlags {
    fn default() -> Self {
        Self {
            bold: false,
            italic: false,
            faint: false,
            blink: false,
            inverse: false,
            invisible: false,
            strikethrough: false,
            overline: false,
            underline: sgr::Underline::None,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Style {
    pub fg_color: StyleColor,
    pub bg_color: StyleColor,
    pub underline_color: StyleColor,
    pub flags: StyleFlags,
}

impl Style {
    pub fn is_default(self) -> bool {
        PackedStyle::from(self).0 == 0
    }

    pub fn bg(self, cell: &Cell, palette: &Palette) -> Option<Rgb> {
        match cell.content_tag() {
            CellContentTag::BgColorPalette => Some(palette[cell.palette_index() as usize]),
            CellContentTag::BgColorRgb => Some(cell.rgb()),
            CellContentTag::Codepoint | CellContentTag::CodepointGrapheme => {
                resolve_color(self.bg_color, palette)
            }
        }
    }

    pub fn fg(self, opts: FgOptions<'_>) -> Rgb {
        match self.fg_color {
            StyleColor::None => {
                if self.flags.bold {
                    if let Some(BoldColor::Color(color)) = opts.bold {
                        return color;
                    }
                }
                opts.default
            }
            StyleColor::Palette(index) => {
                if self.flags.bold && opts.bold.is_some() && index < 8 {
                    opts.palette[(index + 8) as usize]
                } else {
                    opts.palette[index as usize]
                }
            }
            StyleColor::Rgb(rgb) => {
                if self.flags.bold && rgb == opts.default {
                    if let Some(BoldColor::Color(color)) = opts.bold {
                        return color;
                    }
                }
                rgb
            }
        }
    }

    pub fn underline_color(self, palette: &Palette) -> Option<Rgb> {
        resolve_color(self.underline_color, palette)
    }

    pub fn formatter_vt(&self) -> VtFormatter<'_> {
        VtFormatter {
            style: self,
            palette: None,
        }
    }

    pub fn formatter_html(&self) -> HtmlFormatter<'_> {
        HtmlFormatter {
            style: self,
            palette: None,
        }
    }
}

fn resolve_color(color: StyleColor, palette: &Palette) -> Option<Rgb> {
    match color {
        StyleColor::None => None,
        StyleColor::Palette(index) => Some(palette[index as usize]),
        StyleColor::Rgb(rgb) => Some(rgb),
    }
}

pub struct VtFormatter<'a> {
    style: &'a Style,
    pub palette: Option<&'a Palette>,
}

impl fmt::Display for VtFormatter<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // ghostty: Style.formatterVt is self-contained and always starts with
        // reset (style.zig:314-323).
        formatter.write_str("\x1b[0m")?;

        let flags = self.style.flags;
        if flags.bold {
            formatter.write_str("\x1b[1m")?;
        }
        if flags.faint {
            formatter.write_str("\x1b[2m")?;
        }
        if flags.italic {
            formatter.write_str("\x1b[3m")?;
        }
        if flags.blink {
            formatter.write_str("\x1b[5m")?;
        }
        if flags.inverse {
            formatter.write_str("\x1b[7m")?;
        }
        if flags.invisible {
            formatter.write_str("\x1b[8m")?;
        }
        if flags.strikethrough {
            formatter.write_str("\x1b[9m")?;
        }
        if flags.overline {
            formatter.write_str("\x1b[53m")?;
        }
        match flags.underline {
            sgr::Underline::None => {}
            sgr::Underline::Single => formatter.write_str("\x1b[4m")?,
            sgr::Underline::Double => formatter.write_str("\x1b[4:2m")?,
            sgr::Underline::Curly => formatter.write_str("\x1b[4:3m")?,
            sgr::Underline::Dotted => formatter.write_str("\x1b[4:4m")?,
            sgr::Underline::Dashed => formatter.write_str("\x1b[4:5m")?,
        }

        self.format_color(formatter, 38, self.style.fg_color)?;
        self.format_color(formatter, 48, self.style.bg_color)?;
        self.format_color(formatter, 58, self.style.underline_color)
    }
}

impl VtFormatter<'_> {
    fn format_color(
        &self,
        formatter: &mut fmt::Formatter<'_>,
        prefix: u8,
        color: StyleColor,
    ) -> fmt::Result {
        match color {
            StyleColor::None => Ok(()),
            StyleColor::Palette(index) => {
                if let Some(palette) = self.palette {
                    let rgb = palette[index as usize];
                    write!(formatter, "\x1b[{prefix};2;{};{};{}m", rgb.r, rgb.g, rgb.b)
                } else {
                    write!(formatter, "\x1b[{prefix};5;{index}m")
                }
            }
            StyleColor::Rgb(rgb) => {
                write!(formatter, "\x1b[{prefix};2;{};{};{}m", rgb.r, rgb.g, rgb.b)
            }
        }
    }
}

pub struct HtmlFormatter<'a> {
    style: &'a Style,
    pub palette: Option<&'a Palette>,
}

impl fmt::Display for HtmlFormatter<'_> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.format_color(formatter, "color", self.style.fg_color)?;
        self.format_color(formatter, "background-color", self.style.bg_color)?;
        self.format_color(
            formatter,
            "text-decoration-color",
            self.style.underline_color,
        )?;

        let flags = self.style.flags;
        let has_decoration_line = flags.underline != sgr::Underline::None
            || flags.strikethrough
            || flags.overline
            || flags.blink;
        if has_decoration_line {
            formatter.write_str("text-decoration-line:")?;
            if flags.underline != sgr::Underline::None {
                formatter.write_str(" underline")?;
            }
            if flags.strikethrough {
                formatter.write_str(" line-through")?;
            }
            if flags.overline {
                formatter.write_str(" overline")?;
            }
            if flags.blink {
                formatter.write_str(" blink")?;
            }
            formatter.write_str(";")?;
        }

        match flags.underline {
            sgr::Underline::None => {}
            sgr::Underline::Single => formatter.write_str("text-decoration-style: solid;")?,
            sgr::Underline::Double => formatter.write_str("text-decoration-style: double;")?,
            sgr::Underline::Curly => formatter.write_str("text-decoration-style: wavy;")?,
            sgr::Underline::Dotted => formatter.write_str("text-decoration-style: dotted;")?,
            sgr::Underline::Dashed => formatter.write_str("text-decoration-style: dashed;")?,
        }

        if flags.bold {
            formatter.write_str("font-weight: bold;")?;
        }
        if flags.italic {
            formatter.write_str("font-style: italic;")?;
        }
        if flags.faint {
            formatter.write_str("opacity: 0.5;")?;
        }
        if flags.invisible {
            formatter.write_str("visibility: hidden;")?;
        }
        if flags.inverse {
            formatter.write_str("filter: invert(100%);")?;
        }
        Ok(())
    }
}

impl HtmlFormatter<'_> {
    fn format_color(
        &self,
        formatter: &mut fmt::Formatter<'_>,
        property: &str,
        color: StyleColor,
    ) -> fmt::Result {
        match color {
            StyleColor::None => Ok(()),
            StyleColor::Palette(index) => {
                if let Some(palette) = self.palette {
                    let rgb = palette[index as usize];
                    write!(
                        formatter,
                        "{property}: rgb({}, {}, {});",
                        rgb.r, rgb.g, rgb.b
                    )
                } else {
                    write!(formatter, "{property}: var(--vt-palette-{index});")
                }
            }
            StyleColor::Rgb(rgb) => {
                write!(
                    formatter,
                    "{property}: rgb({}, {}, {});",
                    rgb.r, rgb.g, rgb.b
                )
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BoldColor {
    Color(Rgb),
    Bright,
}

#[derive(Debug, Clone, Copy)]
pub struct FgOptions<'a> {
    pub default: Rgb,
    pub palette: &'a Palette,
    pub bold: Option<BoldColor>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct PackedStyle(pub(crate) u128);

impl PackedStyle {
    const FG_TAG_SHIFT: u32 = 0;
    const BG_TAG_SHIFT: u32 = 8;
    const UNDERLINE_TAG_SHIFT: u32 = 16;
    const FG_DATA_SHIFT: u32 = 24;
    const BG_DATA_SHIFT: u32 = 48;
    const UNDERLINE_DATA_SHIFT: u32 = 72;
    const FLAGS_SHIFT: u32 = 96;

    #[allow(dead_code)]
    pub(crate) const fn is_default(self) -> bool {
        self.0 == 0
    }
}

impl From<Style> for PackedStyle {
    fn from(value: Style) -> Self {
        let mut raw = 0u128;
        pack_color(
            value.fg_color,
            &mut raw,
            Self::FG_TAG_SHIFT,
            Self::FG_DATA_SHIFT,
        );
        pack_color(
            value.bg_color,
            &mut raw,
            Self::BG_TAG_SHIFT,
            Self::BG_DATA_SHIFT,
        );
        pack_color(
            value.underline_color,
            &mut raw,
            Self::UNDERLINE_TAG_SHIFT,
            Self::UNDERLINE_DATA_SHIFT,
        );
        raw |= u128::from(pack_flags(value.flags)) << Self::FLAGS_SHIFT;
        Self(raw)
    }
}

impl From<PackedStyle> for Style {
    fn from(value: PackedStyle) -> Self {
        Self {
            fg_color: unpack_color(
                value.0,
                PackedStyle::FG_TAG_SHIFT,
                PackedStyle::FG_DATA_SHIFT,
            ),
            bg_color: unpack_color(
                value.0,
                PackedStyle::BG_TAG_SHIFT,
                PackedStyle::BG_DATA_SHIFT,
            ),
            underline_color: unpack_color(
                value.0,
                PackedStyle::UNDERLINE_TAG_SHIFT,
                PackedStyle::UNDERLINE_DATA_SHIFT,
            ),
            flags: unpack_flags(((value.0 >> PackedStyle::FLAGS_SHIFT) & 0xFFFF) as u16),
        }
    }
}

impl BufValue for PackedStyle {
    const SIZE: usize = u128::SIZE;
    const ALIGN: usize = u128::ALIGN;

    fn read(buf: &[u8], at: usize) -> Self {
        Self(u128::read(buf, at))
    }

    fn write(self, buf: &mut [u8], at: usize) {
        self.0.write(buf, at);
    }
}

fn pack_color(color: StyleColor, raw: &mut u128, tag_shift: u32, data_shift: u32) {
    match color {
        StyleColor::None => {}
        StyleColor::Palette(index) => {
            *raw |= 1u128 << tag_shift;
            *raw |= u128::from(index) << data_shift;
        }
        StyleColor::Rgb(rgb) => {
            *raw |= 2u128 << tag_shift;
            *raw |= u128::from(rgb.r) << data_shift;
            *raw |= u128::from(rgb.g) << (data_shift + 8);
            *raw |= u128::from(rgb.b) << (data_shift + 16);
        }
    }
}

fn unpack_color(raw: u128, tag_shift: u32, data_shift: u32) -> StyleColor {
    match ((raw >> tag_shift) & 0xFF) as u8 {
        1 => StyleColor::Palette(((raw >> data_shift) & 0xFF) as u8),
        2 => StyleColor::Rgb(Rgb {
            r: ((raw >> data_shift) & 0xFF) as u8,
            g: ((raw >> (data_shift + 8)) & 0xFF) as u8,
            b: ((raw >> (data_shift + 16)) & 0xFF) as u8,
        }),
        _ => StyleColor::None,
    }
}

fn pack_flags(flags: StyleFlags) -> u16 {
    u16::from(flags.bold)
        | u16::from(flags.italic) << 1
        | u16::from(flags.faint) << 2
        | u16::from(flags.blink) << 3
        | u16::from(flags.inverse) << 4
        | u16::from(flags.invisible) << 5
        | u16::from(flags.strikethrough) << 6
        | u16::from(flags.overline) << 7
        | (flags.underline as u16) << 8
}

fn unpack_flags(raw: u16) -> StyleFlags {
    StyleFlags {
        bold: raw & (1 << 0) != 0,
        italic: raw & (1 << 1) != 0,
        faint: raw & (1 << 2) != 0,
        blink: raw & (1 << 3) != 0,
        inverse: raw & (1 << 4) != 0,
        invisible: raw & (1 << 5) != 0,
        strikethrough: raw & (1 << 6) != 0,
        overline: raw & (1 << 7) != 0,
        underline: underline_from_bits(((raw >> 8) & 0b111) as u8),
    }
}

fn underline_from_bits(bits: u8) -> sgr::Underline {
    match bits {
        1 => sgr::Underline::Single,
        2 => sgr::Underline::Double,
        3 => sgr::Underline::Curly,
        4 => sgr::Underline::Dotted,
        5 => sgr::Underline::Dashed,
        _ => sgr::Underline::None,
    }
}

// Deliberate Ghostty deviation: pre-mix the high half before combining it
// with the low half. Ghostty's direct lo^hi fold permits constructible SGR
// collisions where a flag bit cancels the corresponding foreground bit.
fn hash_packed_style(value: PackedStyle) -> u64 {
    let lo = value.0 as u64;
    let hi = (value.0 >> 64) as u64;
    let mut h = hi;
    h ^= h >> 33;
    h = h.wrapping_mul(0xFF51_AFD7_ED55_8CCD);
    let mut x = lo ^ h;
    x ^= x >> 27;
    x = x.wrapping_mul(0x3C79_AC49_2BA7_B653);
    x ^= x >> 33;
    x = x.wrapping_mul(0x1C69_B3F7_4AC4_AE35);
    x ^= x >> 27;
    x
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct StyleContext;

impl RefCountedSetContext<PackedStyle> for StyleContext {
    fn hash(&self, _buf: &[u8], value: &PackedStyle) -> u64 {
        hash_packed_style(*value)
    }

    fn eql(&self, _buf: &[u8], a: &PackedStyle, b: &PackedStyle) -> bool {
        a == b
    }
}

#[allow(dead_code)]
pub(crate) type StyleSet = RefCountedSet<PackedStyle, StyleContext>;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::DEFAULT_PALETTE;
    use crate::ref_counted_set::Layout;
    use crate::size::OffsetBuf;

    fn rgb(r: u8, g: u8, b: u8) -> Rgb {
        Rgb { r, g, b }
    }

    #[test]
    fn default_style_packs_to_zero() {
        let packed = PackedStyle::from(Style::default());
        assert_eq!(packed.0, 0);
        assert!(packed.is_default());
        assert!(Style::default().is_default());
    }

    #[test]
    fn pack_unpack_round_trips_all_color_slots_and_flags() {
        let style = Style {
            fg_color: StyleColor::Palette(7),
            bg_color: StyleColor::Rgb(rgb(1, 2, 3)),
            underline_color: StyleColor::Palette(9),
            flags: StyleFlags {
                bold: true,
                italic: true,
                faint: true,
                blink: true,
                inverse: true,
                invisible: true,
                strikethrough: true,
                overline: true,
                underline: sgr::Underline::Curly,
            },
        };
        let packed = PackedStyle::from(style);
        assert_eq!(Style::from(packed), style);
    }

    #[test]
    fn unused_lanes_are_zeroed_when_color_is_none_or_palette() {
        let style = Style {
            fg_color: StyleColor::Palette(0xAA),
            bg_color: StyleColor::None,
            underline_color: StyleColor::None,
            flags: StyleFlags::default(),
        };
        let packed = PackedStyle::from(style).0;
        assert_eq!((packed >> 32) & 0xFFFF, 0);
        assert_eq!((packed >> 48) & 0xFF_FFFF, 0);
        assert_eq!((packed >> 72) & 0xFF_FFFF, 0);
        assert_eq!(packed >> 112, 0);
    }

    #[test]
    fn packed_equality_matches_rich_equality() {
        let a = Style {
            fg_color: StyleColor::Rgb(rgb(1, 2, 3)),
            ..Style::default()
        };
        let b = Style {
            fg_color: StyleColor::Rgb(rgb(1, 2, 3)),
            ..Style::default()
        };
        let c = Style {
            fg_color: StyleColor::Rgb(rgb(1, 2, 4)),
            ..Style::default()
        };
        assert_eq!(PackedStyle::from(a), PackedStyle::from(b));
        assert_ne!(PackedStyle::from(a), PackedStyle::from(c));
    }

    #[test]
    fn packed_style_hash_no_trivial_fold_collisions() {
        // port-added: unlike Ghostty's lo^hi fold, untrusted SGR flags must
        // not cancel matching foreground RGB bits before the mixer runs.
        let bold_black = PackedStyle::from(Style {
            fg_color: StyleColor::Rgb(rgb(0, 0, 0)),
            flags: StyleFlags {
                bold: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        });
        let plain_green_bit = PackedStyle::from(Style {
            fg_color: StyleColor::Rgb(rgb(0, 1, 0)),
            ..Style::default()
        });
        assert_ne!(
            hash_packed_style(bold_black),
            hash_packed_style(plain_green_bit)
        );

        for bit in 0..16 {
            let flag = PackedStyle(2 | (1u128 << (96 + bit)));
            let paired_fg = PackedStyle(2 | (1u128 << (32 + bit)));
            assert_ne!(
                hash_packed_style(flag),
                hash_packed_style(paired_fg),
                "flag/foreground pair {bit} collided"
            );
        }
    }

    #[test]
    fn fg_none_uses_bold_color_only_for_color_variant() {
        let style = Style {
            flags: StyleFlags {
                bold: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        let default = rgb(10, 11, 12);
        let bold = rgb(20, 21, 22);
        assert_eq!(
            style.fg(FgOptions {
                default,
                palette: &DEFAULT_PALETTE,
                bold: Some(BoldColor::Color(bold)),
            }),
            bold
        );
        assert_eq!(
            style.fg(FgOptions {
                default,
                palette: &DEFAULT_PALETTE,
                bold: Some(BoldColor::Bright),
            }),
            default
        );
    }

    #[test]
    fn fg_palette_brightens_low_indices_for_any_bold_option() {
        let style = Style {
            fg_color: StyleColor::Palette(2),
            flags: StyleFlags {
                bold: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(
            style.fg(FgOptions {
                default: rgb(0, 0, 0),
                palette: &DEFAULT_PALETTE,
                bold: Some(BoldColor::Color(rgb(1, 1, 1))),
            }),
            DEFAULT_PALETTE[10]
        );
        assert_eq!(
            style.fg(FgOptions {
                default: rgb(0, 0, 0),
                palette: &DEFAULT_PALETTE,
                bold: Some(BoldColor::Bright),
            }),
            DEFAULT_PALETTE[10]
        );
    }

    #[test]
    fn fg_rgb_substitutes_only_when_rgb_matches_default_and_bold_color_is_explicit() {
        let default = rgb(9, 9, 9);
        let style = Style {
            fg_color: StyleColor::Rgb(default),
            flags: StyleFlags {
                bold: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(
            style.fg(FgOptions {
                default,
                palette: &DEFAULT_PALETTE,
                bold: Some(BoldColor::Color(rgb(2, 3, 4))),
            }),
            rgb(2, 3, 4)
        );
        assert_eq!(
            style.fg(FgOptions {
                default,
                palette: &DEFAULT_PALETTE,
                bold: Some(BoldColor::Bright),
            }),
            default
        );
    }

    #[test]
    fn bg_cell_content_wins_over_style_for_palette_and_rgb() {
        let style = Style {
            bg_color: StyleColor::Rgb(rgb(9, 9, 9)),
            ..Style::default()
        };
        assert_eq!(
            style.bg(&Cell::bg_palette(4), &DEFAULT_PALETTE),
            Some(DEFAULT_PALETTE[4])
        );
        assert_eq!(
            style.bg(&Cell::bg_rgb(rgb(1, 2, 3)), &DEFAULT_PALETTE),
            Some(rgb(1, 2, 3))
        );
        assert_eq!(
            style.bg(&Cell::new('x'), &DEFAULT_PALETTE),
            Some(rgb(9, 9, 9))
        );
    }

    #[test]
    fn underline_color_resolves_palette_rgb_and_none() {
        let none = Style::default();
        assert_eq!(none.underline_color(&DEFAULT_PALETTE), None);
        let palette = Style {
            underline_color: StyleColor::Palette(5),
            ..Style::default()
        };
        assert_eq!(
            palette.underline_color(&DEFAULT_PALETTE),
            Some(DEFAULT_PALETTE[5])
        );
        let direct = Style {
            underline_color: StyleColor::Rgb(rgb(3, 4, 5)),
            ..Style::default()
        };
        assert_eq!(direct.underline_color(&DEFAULT_PALETTE), Some(rgb(3, 4, 5)));
    }

    fn vt(style: &Style) -> String {
        style.formatter_vt().to_string()
    }

    fn vt_with_default_palette(style: &Style) -> String {
        let mut formatter = style.formatter_vt();
        formatter.palette = Some(&DEFAULT_PALETTE);
        formatter.to_string()
    }

    fn html(style: &Style) -> String {
        style.formatter_html().to_string()
    }

    fn html_with_default_palette(style: &Style) -> String {
        let mut formatter = style.formatter_html();
        formatter.palette = Some(&DEFAULT_PALETTE);
        formatter.to_string()
    }

    // ghostty: "Style VT formatting empty" (style.zig:566)
    #[test]
    fn style_vt_formatting_empty() {
        assert_eq!(vt(&Style::default()), "\x1b[0m");
    }

    // ghostty: "Style VT formatting bold" (style.zig:577)
    #[test]
    fn style_vt_formatting_bold() {
        let style = Style {
            flags: StyleFlags {
                bold: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[1m");
    }

    // ghostty: "Style VT formatting faint" (style.zig:588)
    #[test]
    fn style_vt_formatting_faint() {
        let style = Style {
            flags: StyleFlags {
                faint: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[2m");
    }

    // ghostty: "Style VT formatting italic" (style.zig:599)
    #[test]
    fn style_vt_formatting_italic() {
        let style = Style {
            flags: StyleFlags {
                italic: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[3m");
    }

    // ghostty: "Style VT formatting blink" (style.zig:610)
    #[test]
    fn style_vt_formatting_blink() {
        let style = Style {
            flags: StyleFlags {
                blink: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[5m");
    }

    // ghostty: "Style VT formatting inverse" (style.zig:621)
    #[test]
    fn style_vt_formatting_inverse() {
        let style = Style {
            flags: StyleFlags {
                inverse: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[7m");
    }

    // ghostty: "Style VT formatting invisible" (style.zig:632)
    #[test]
    fn style_vt_formatting_invisible() {
        let style = Style {
            flags: StyleFlags {
                invisible: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[8m");
    }

    // ghostty: "Style VT formatting strikethrough" (style.zig:643)
    #[test]
    fn style_vt_formatting_strikethrough() {
        let style = Style {
            flags: StyleFlags {
                strikethrough: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[9m");
    }

    // ghostty: "Style VT formatting overline" (style.zig:654)
    #[test]
    fn style_vt_formatting_overline() {
        let style = Style {
            flags: StyleFlags {
                overline: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[53m");
    }

    fn underline_style(underline: sgr::Underline) -> Style {
        Style {
            flags: StyleFlags {
                underline,
                ..StyleFlags::default()
            },
            ..Style::default()
        }
    }

    // ghostty: "Style VT formatting underline single" (style.zig:665)
    #[test]
    fn style_vt_formatting_underline_single() {
        assert_eq!(
            vt(&underline_style(sgr::Underline::Single)),
            "\x1b[0m\x1b[4m"
        );
    }

    // ghostty: "Style VT formatting underline double" (style.zig:676)
    #[test]
    fn style_vt_formatting_underline_double() {
        assert_eq!(
            vt(&underline_style(sgr::Underline::Double)),
            "\x1b[0m\x1b[4:2m"
        );
    }

    // ghostty: "Style VT formatting underline curly" (style.zig:687)
    #[test]
    fn style_vt_formatting_underline_curly() {
        assert_eq!(
            vt(&underline_style(sgr::Underline::Curly)),
            "\x1b[0m\x1b[4:3m"
        );
    }

    // ghostty: "Style VT formatting underline dotted" (style.zig:698)
    #[test]
    fn style_vt_formatting_underline_dotted() {
        assert_eq!(
            vt(&underline_style(sgr::Underline::Dotted)),
            "\x1b[0m\x1b[4:4m"
        );
    }

    // ghostty: "Style VT formatting underline dashed" (style.zig:709)
    #[test]
    fn style_vt_formatting_underline_dashed() {
        assert_eq!(
            vt(&underline_style(sgr::Underline::Dashed)),
            "\x1b[0m\x1b[4:5m"
        );
    }

    // ghostty: "Style VT formatting fg palette" (style.zig:720)
    #[test]
    fn style_vt_formatting_fg_palette() {
        let style = Style {
            fg_color: StyleColor::Palette(42),
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[38;5;42m");
    }

    // ghostty: "Style VT formatting fg rgb" (style.zig:731)
    #[test]
    fn style_vt_formatting_fg_rgb() {
        let style = Style {
            fg_color: StyleColor::Rgb(rgb(255, 128, 64)),
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[38;2;255;128;64m");
    }

    // ghostty: "Style VT formatting bg palette" (style.zig:742)
    #[test]
    fn style_vt_formatting_bg_palette() {
        let style = Style {
            bg_color: StyleColor::Palette(7),
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[48;5;7m");
    }

    // ghostty: "Style VT formatting bg rgb" (style.zig:753)
    #[test]
    fn style_vt_formatting_bg_rgb() {
        let style = Style {
            bg_color: StyleColor::Rgb(rgb(32, 64, 96)),
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[48;2;32;64;96m");
    }

    // ghostty: "Style VT formatting underline_color palette" (style.zig:764)
    #[test]
    fn style_vt_formatting_underline_color_palette() {
        let style = Style {
            underline_color: StyleColor::Palette(15),
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[58;5;15m");
    }

    // ghostty: "Style VT formatting underline_color rgb" (style.zig:775)
    #[test]
    fn style_vt_formatting_underline_color_rgb() {
        let style = Style {
            underline_color: StyleColor::Rgb(rgb(200, 100, 50)),
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[58;2;200;100;50m");
    }

    // ghostty: "Style VT formatting multiple flags" (style.zig:786)
    #[test]
    fn style_vt_formatting_multiple_flags() {
        let style = Style {
            flags: StyleFlags {
                bold: true,
                italic: true,
                underline: sgr::Underline::Single,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[1m\x1b[3m\x1b[4m");
    }

    // ghostty: "Style VT formatting all flags" (style.zig:797)
    #[test]
    fn style_vt_formatting_all_flags() {
        let style = Style {
            flags: StyleFlags {
                bold: true,
                faint: true,
                italic: true,
                blink: true,
                inverse: true,
                invisible: true,
                strikethrough: true,
                overline: true,
                underline: sgr::Underline::Curly,
            },
            ..Style::default()
        };
        assert_eq!(
            vt(&style),
            "\x1b[0m\x1b[1m\x1b[2m\x1b[3m\x1b[5m\x1b[7m\x1b[8m\x1b[9m\x1b[53m\x1b[4:3m"
        );
    }

    // ghostty: "Style VT formatting combined colors and flags" (style.zig:821)
    #[test]
    fn style_vt_formatting_combined_colors_and_flags() {
        let style = Style {
            fg_color: StyleColor::Rgb(rgb(255, 0, 0)),
            bg_color: StyleColor::Palette(8),
            underline_color: StyleColor::Rgb(rgb(0, 255, 0)),
            flags: StyleFlags {
                bold: true,
                italic: true,
                underline: sgr::Underline::Double,
                ..StyleFlags::default()
            },
        };
        assert_eq!(
            vt(&style),
            "\x1b[0m\x1b[1m\x1b[3m\x1b[4:2m\x1b[38;2;255;0;0m\x1b[48;5;8m\x1b[58;2;0;255;0m"
        );
    }

    // ghostty: "Style VT formatting all colors rgb" (style.zig:840)
    #[test]
    fn style_vt_formatting_all_colors_rgb() {
        let style = Style {
            fg_color: StyleColor::Rgb(rgb(10, 20, 30)),
            bg_color: StyleColor::Rgb(rgb(40, 50, 60)),
            underline_color: StyleColor::Rgb(rgb(70, 80, 90)),
            ..Style::default()
        };
        assert_eq!(
            vt(&style),
            "\x1b[0m\x1b[38;2;10;20;30m\x1b[48;2;40;50;60m\x1b[58;2;70;80;90m"
        );
    }

    // ghostty: "Style VT formatting all colors palette" (style.zig:858)
    #[test]
    fn style_vt_formatting_all_colors_palette() {
        let style = Style {
            fg_color: StyleColor::Palette(1),
            bg_color: StyleColor::Palette(2),
            underline_color: StyleColor::Palette(3),
            ..Style::default()
        };
        assert_eq!(vt(&style), "\x1b[0m\x1b[38;5;1m\x1b[48;5;2m\x1b[58;5;3m");
    }

    // ghostty: "Style VT formatting palette with palette set emits rgb" (style.zig:876)
    #[test]
    fn style_vt_formatting_palette_with_palette_set_emits_rgb() {
        let style = Style {
            fg_color: StyleColor::Palette(1),
            ..Style::default()
        };
        assert_eq!(
            vt_with_default_palette(&style),
            "\x1b[0m\x1b[38;2;204;102;102m"
        );
    }

    // ghostty: "Style VT formatting all palette colors with palette set" (style.zig:889)
    #[test]
    fn style_vt_formatting_all_palette_colors_with_palette_set() {
        let style = Style {
            fg_color: StyleColor::Palette(1),
            bg_color: StyleColor::Palette(2),
            underline_color: StyleColor::Palette(3),
            ..Style::default()
        };
        assert_eq!(
            vt_with_default_palette(&style),
            "\x1b[0m\x1b[38;2;204;102;102m\x1b[48;2;181;189;104m\x1b[58;2;240;198;116m"
        );
    }

    // ghostty: "Style HTML formatting basic bold" (style.zig:969)
    #[test]
    fn style_html_formatting_basic_bold() {
        let style = Style {
            flags: StyleFlags {
                bold: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        assert_eq!(html(&style), "font-weight: bold;");
    }

    // ghostty: "Style HTML formatting fg color rgb" (style.zig:980)
    #[test]
    fn style_html_formatting_fg_color_rgb() {
        let style = Style {
            fg_color: StyleColor::Rgb(rgb(255, 128, 64)),
            ..Style::default()
        };
        assert_eq!(html(&style), "color: rgb(255, 128, 64);");
    }

    // ghostty: "Style HTML formatting bg color palette" (style.zig:991)
    #[test]
    fn style_html_formatting_bg_color_palette() {
        let style = Style {
            bg_color: StyleColor::Palette(7),
            ..Style::default()
        };
        assert_eq!(html(&style), "background-color: var(--vt-palette-7);");
    }

    // ghostty: "Style HTML formatting combined colors and flags" (style.zig:1002)
    #[test]
    fn style_html_formatting_combined_colors_and_flags() {
        let style = Style {
            fg_color: StyleColor::Rgb(rgb(255, 0, 0)),
            bg_color: StyleColor::Rgb(rgb(0, 0, 255)),
            flags: StyleFlags {
                bold: true,
                italic: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        let result = html(&style);
        assert!(result.contains("color: rgb(255, 0, 0);"));
        assert!(result.contains("background-color: rgb(0, 0, 255);"));
        assert!(result.contains("font-weight: bold;"));
        assert!(result.contains("font-style: italic;"));
    }

    // ghostty: "Style HTML formatting single decoration line" (style.zig:1021)
    #[test]
    fn style_html_formatting_single_decoration_line() {
        let result = html(&underline_style(sgr::Underline::Single));
        assert!(result.contains("text-decoration-line: underline;"));
        assert!(result.contains("text-decoration-style: solid;"));
    }

    // ghostty: "Style HTML formatting multiple decoration lines" (style.zig:1034)
    #[test]
    fn style_html_formatting_multiple_decoration_lines() {
        let style = Style {
            flags: StyleFlags {
                underline: sgr::Underline::Curly,
                strikethrough: true,
                overline: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        };
        let result = html(&style);
        assert!(result.contains("text-decoration-line: underline line-through overline;"));
        assert!(result.contains("text-decoration-style: wavy;"));
    }

    // ghostty: "Style HTML formatting palette with palette set emits rgb" (style.zig:1047)
    #[test]
    fn style_html_formatting_palette_with_palette_set_emits_rgb() {
        let style = Style {
            bg_color: StyleColor::Palette(7),
            ..Style::default()
        };
        assert_eq!(
            html_with_default_palette(&style),
            "background-color: rgb(197, 200, 198);"
        );
    }

    // ghostty: "Style HTML formatting all palette colors with palette set" (style.zig:1060)
    #[test]
    fn style_html_formatting_all_palette_colors_with_palette_set() {
        let style = Style {
            fg_color: StyleColor::Palette(1),
            bg_color: StyleColor::Palette(2),
            underline_color: StyleColor::Palette(3),
            ..Style::default()
        };
        assert_eq!(
            html_with_default_palette(&style),
            "color: rgb(204, 102, 102);background-color: rgb(181, 189, 104);text-decoration-color: rgb(240, 198, 116);"
        );
    }

    #[test]
    fn style_set_basic_usage() {
        // ghostty: "Set basic usage" (style.zig:909)
        let layout = Layout::init::<PackedStyle>(16);
        let mut buf = vec![0; layout.total_size];
        let mut set = StyleSet::init(OffsetBuf::init(), layout, &mut buf, StyleContext);
        let style = PackedStyle::from(Style {
            flags: StyleFlags {
                bold: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        });
        let style2 = PackedStyle::from(Style {
            flags: StyleFlags {
                italic: true,
                ..StyleFlags::default()
            },
            ..Style::default()
        });

        let id = set.add(&mut buf, style).unwrap();
        assert!(id > 0);
        assert_eq!(set.add(&mut buf, style).unwrap(), id);
        assert_eq!(set.get(&buf, id), Some(style));
        let id2 = set.add(&mut buf, style2).unwrap();
        assert_eq!(set.get(&buf, id2), Some(style2));
        assert_eq!(set.ref_count(&buf, id), 2);
        assert_eq!(set.ref_count(&buf, id2), 1);
        set.release(&mut buf, id);
        assert_eq!(set.ref_count(&buf, id), 1);
        set.release(&mut buf, id2);
        assert_eq!(set.ref_count(&buf, id2), 0);
        set.release(&mut buf, id);
        assert_eq!(set.ref_count(&buf, id), 0);
    }

    #[test]
    fn style_set_capacities_support_ghostty_target() {
        // ghostty: "Set capacities" (style.zig:964)
        let layout = Layout::init::<PackedStyle>(16_384);
        assert!(layout.total_size > 16_384 * PackedStyle::SIZE);
    }

    #[test]
    fn packed_style_buf_value_is_16_byte_little_endian() {
        let packed = PackedStyle(0x1122_3344_5566_7788_99AA_BBCC_DDEE_F001);
        let mut buf = [0u8; PackedStyle::SIZE];
        packed.write(&mut buf, 0);
        assert_eq!(PackedStyle::read(&buf, 0), packed);
        assert_eq!(PackedStyle::SIZE, 16);
        assert_eq!(PackedStyle::ALIGN, 16);
    }
}
