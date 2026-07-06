//! Terminal cell style storage and resolution.
//!
//! Ghostty stores styles in a ref-counted set. This port uses `PackedStyle`
//! as the set value directly: the u128 bit layout is the storage format.
//! The 35 upstream VT/HTML formatter tests are intentionally deferred to the
//! later formatter phase; this module ports the two style-set tests and pins
//! the storage/resolution behavior that upstream leaves implicit.

use crate::color::{Palette, Rgb};
use crate::page::{Cell, CellContentTag};
use crate::ref_counted_set::{RefCountedSet, RefCountedSetContext};
use crate::sgr;
use crate::size::{BufValue, StyleCountInt};

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
}

fn resolve_color(color: StyleColor, palette: &Palette) -> Option<Rgb> {
    match color {
        StyleColor::None => None,
        StyleColor::Palette(index) => Some(palette[index as usize]),
        StyleColor::Rgb(rgb) => Some(rgb),
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

// Ghostty hashes packed styles by lo^hi and a Moremur-like integer mixer.
// No upstream test pins concrete outputs, but matching the mixer keeps bucket
// behavior stable for any future trace-based tests.
fn hash_packed_style(value: PackedStyle) -> u64 {
    let lo = value.0 as u64;
    let hi = (value.0 >> 64) as u64;
    let mut x = lo ^ hi;
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
