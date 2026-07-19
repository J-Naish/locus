//! Terminal color types and palette helpers.

use std::error::Error;
use std::fmt;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
#[repr(C)]
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

#[derive(Debug, PartialEq, Eq)]
pub struct InvalidFormat;

impl fmt::Display for InvalidFormat {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("invalid RGB color format")
    }
}

impl Error for InvalidFormat {}

impl Rgb {
    pub fn luminance(&self) -> f64 {
        0.2126 * component_luminance(self.r)
            + 0.7152 * component_luminance(self.g)
            + 0.0722 * component_luminance(self.b)
    }

    pub fn contrast(&self, other: Rgb) -> f64 {
        let self_luminance = self.luminance();
        let other_luminance = other.luminance();
        let (lighter, darker) = if self_luminance > other_luminance {
            (self_luminance, other_luminance)
        } else {
            (other_luminance, self_luminance)
        };
        (lighter + 0.05) / (darker + 0.05)
    }

    pub fn perceived_luminance(&self) -> f64 {
        0.299 * f64::from(self.r) / 255.0
            + 0.587 * f64::from(self.g) / 255.0
            + 0.114 * f64::from(self.b) / 255.0
    }

    pub fn parse(value: &str) -> Result<Self, InvalidFormat> {
        let bytes = value.as_bytes();
        if bytes.is_empty() {
            return Err(InvalidFormat);
        }

        if bytes[0] == b'#' {
            return match bytes.len() {
                4 => Ok(Self {
                    r: from_hex(&bytes[1..2])?,
                    g: from_hex(&bytes[2..3])?,
                    b: from_hex(&bytes[3..4])?,
                }),
                7 => Ok(Self {
                    r: from_hex(&bytes[1..3])?,
                    g: from_hex(&bytes[3..5])?,
                    b: from_hex(&bytes[5..7])?,
                }),
                10 => Ok(Self {
                    r: from_hex(&bytes[1..4])?,
                    g: from_hex(&bytes[4..7])?,
                    b: from_hex(&bytes[7..10])?,
                }),
                13 => Ok(Self {
                    r: from_hex(&bytes[1..5])?,
                    g: from_hex(&bytes[5..9])?,
                    b: from_hex(&bytes[9..13])?,
                }),
                _ => Err(InvalidFormat),
            };
        }

        if let Some(rgb) = crate::x11_color::get(value.trim_matches(' ')) {
            return Ok(rgb);
        }

        if bytes.len() < b"rgb:a/a/a".len() || &bytes[..3] != b"rgb" {
            return Err(InvalidFormat);
        }

        let mut index = 3;
        let use_intensity = if bytes.get(index) == Some(&b'i') {
            index += 1;
            true
        } else {
            false
        };
        if bytes.get(index) != Some(&b':') {
            return Err(InvalidFormat);
        }
        index += 1;

        let r_end = bytes[index..]
            .iter()
            .position(|byte| *byte == b'/')
            .ok_or(InvalidFormat)?
            + index;
        let r = parse_component(&bytes[index..r_end], use_intensity)?;
        index = r_end + 1;

        let g_end = bytes[index..]
            .iter()
            .position(|byte| *byte == b'/')
            .ok_or(InvalidFormat)?
            + index;
        let g = parse_component(&bytes[index..g_end], use_intensity)?;
        index = g_end + 1;

        let b = parse_component(&bytes[index..], use_intensity)?;
        Ok(Self { r, g, b })
    }
}

fn component_luminance(component: u8) -> f64 {
    let normalized = f64::from(component) / 255.0;
    if normalized <= 0.03928 {
        normalized / 12.92
    } else {
        ((normalized + 0.055) / 1.055).powf(2.4)
    }
}

fn parse_component(bytes: &[u8], intensity: bool) -> Result<u8, InvalidFormat> {
    if intensity {
        from_intensity(bytes)
    } else {
        from_hex(bytes)
    }
}

fn from_hex(bytes: &[u8]) -> Result<u8, InvalidFormat> {
    let text = std::str::from_utf8(bytes).map_err(|_| InvalidFormat)?;
    if text.is_empty() || text.len() > 4 {
        return Err(InvalidFormat);
    }
    let value = u16::from_str_radix(text, 16).map_err(|_| InvalidFormat)?;
    let divisor = match text.len() {
        1 => 15,
        2 => 255,
        3 => 4095,
        4 => 65535,
        _ => return Err(InvalidFormat),
    };
    Ok((usize::from(value) * 255 / divisor) as u8)
}

fn from_intensity(bytes: &[u8]) -> Result<u8, InvalidFormat> {
    let text = std::str::from_utf8(bytes).map_err(|_| InvalidFormat)?;
    let value = text.parse::<f64>().map_err(|_| InvalidFormat)?;
    // This deliberately rejects NaN; Ghostty lets NaN reach a panicking cast.
    if !(0.0..=1.0).contains(&value) {
        return Err(InvalidFormat);
    }
    Ok((value * 255.0) as u8)
}

pub type Palette = [Rgb; 256];

const NAMED_RGB: [Rgb; 16] = [
    Rgb {
        r: 0x1D,
        g: 0x1F,
        b: 0x21,
    },
    Rgb {
        r: 0xCC,
        g: 0x66,
        b: 0x66,
    },
    Rgb {
        r: 0xB5,
        g: 0xBD,
        b: 0x68,
    },
    Rgb {
        r: 0xF0,
        g: 0xC6,
        b: 0x74,
    },
    Rgb {
        r: 0x81,
        g: 0xA2,
        b: 0xBE,
    },
    Rgb {
        r: 0xB2,
        g: 0x94,
        b: 0xBB,
    },
    Rgb {
        r: 0x8A,
        g: 0xBE,
        b: 0xB7,
    },
    Rgb {
        r: 0xC5,
        g: 0xC8,
        b: 0xC6,
    },
    Rgb {
        r: 0x66,
        g: 0x66,
        b: 0x66,
    },
    Rgb {
        r: 0xD5,
        g: 0x4E,
        b: 0x53,
    },
    Rgb {
        r: 0xB9,
        g: 0xCA,
        b: 0x4A,
    },
    Rgb {
        r: 0xE7,
        g: 0xC5,
        b: 0x47,
    },
    Rgb {
        r: 0x7A,
        g: 0xA6,
        b: 0xDA,
    },
    Rgb {
        r: 0xC3,
        g: 0x97,
        b: 0xD8,
    },
    Rgb {
        r: 0x70,
        g: 0xC0,
        b: 0xB1,
    },
    Rgb {
        r: 0xEA,
        g: 0xEA,
        b: 0xEA,
    },
];

pub const DEFAULT_PALETTE: Palette = default_palette();

const fn default_palette() -> Palette {
    let mut palette = [Rgb { r: 0, g: 0, b: 0 }; 256];
    let mut index = 0;
    while index < 16 {
        palette[index] = NAMED_RGB[index];
        index += 1;
    }

    let mut r = 0;
    while r < 6 {
        let mut g = 0;
        while g < 6 {
            let mut b = 0;
            while b < 6 {
                palette[index] = Rgb {
                    r: if r == 0 { 0 } else { r * 40 + 55 },
                    g: if g == 0 { 0 } else { g * 40 + 55 },
                    b: if b == 0 { 0 } else { b * 40 + 55 },
                };
                index += 1;
                b += 1;
            }
            g += 1;
        }
        r += 1;
    }

    index = 232;
    while index < 256 {
        let value = (index - 232) * 10 + 8;
        palette[index] = Rgb {
            r: value as u8,
            g: value as u8,
            b: value as u8,
        };
        index += 1;
    }

    palette
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PaletteMask([u64; 4]);

impl PaletteMask {
    pub fn set(&mut self, index: u8) {
        let index = usize::from(index);
        self.0[index / 64] |= 1u64 << (index % 64);
    }

    pub fn unset(&mut self, index: u8) {
        let index = usize::from(index);
        self.0[index / 64] &= !(1u64 << (index % 64));
    }

    pub fn is_set(&self, index: u8) -> bool {
        let index = usize::from(index);
        self.0[index / 64] & (1u64 << (index % 64)) != 0
    }

    pub fn count(&self) -> usize {
        self.0.iter().map(|value| value.count_ones() as usize).sum()
    }

    pub fn indices(&self) -> impl Iterator<Item = usize> + '_ {
        (0..256).filter(|index| {
            let index = *index;
            self.0[index / 64] & (1u64 << (index % 64)) != 0
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DynamicPalette {
    pub current: Palette,
    pub original: Palette,
    pub mask: PaletteMask,
}

impl DynamicPalette {
    pub fn new(default: Palette) -> Self {
        Self {
            current: default,
            original: default,
            mask: PaletteMask::default(),
        }
    }

    pub fn set(&mut self, index: u8, color: Rgb) {
        self.current[usize::from(index)] = color;
        self.mask.set(index);
    }

    pub fn reset(&mut self, index: u8) {
        self.current[usize::from(index)] = self.original[usize::from(index)];
        self.mask.unset(index);
    }

    pub fn reset_all(&mut self) {
        *self = Self::new(self.original);
    }

    pub fn change_default(&mut self, default: Palette) {
        let previous_current = self.current;
        self.original = default;
        if self.mask.count() == 0 {
            self.current = default;
            return;
        }

        self.current = default;
        for index in self.mask.indices() {
            self.current[index] = previous_current[index];
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DynamicRgb {
    pub override_color: Option<Rgb>,
    pub default: Option<Rgb>,
}

impl DynamicRgb {
    pub const UNSET: Self = Self {
        override_color: None,
        default: None,
    };

    pub fn new(default: Rgb) -> Self {
        Self {
            override_color: None,
            default: Some(default),
        }
    }

    pub fn get(&self) -> Option<Rgb> {
        self.override_color.or(self.default)
    }

    pub fn set(&mut self, color: Rgb) {
        self.override_color = Some(color);
    }

    pub fn reset(&mut self) {
        self.override_color = self.default;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Name(pub u8);

impl Name {
    pub const BLACK: Self = Self(0);
    pub const RED: Self = Self(1);
    pub const GREEN: Self = Self(2);
    pub const YELLOW: Self = Self(3);
    pub const BLUE: Self = Self(4);
    pub const MAGENTA: Self = Self(5);
    pub const CYAN: Self = Self(6);
    pub const WHITE: Self = Self(7);
    pub const BRIGHT_BLACK: Self = Self(8);
    pub const BRIGHT_RED: Self = Self(9);
    pub const BRIGHT_GREEN: Self = Self(10);
    pub const BRIGHT_YELLOW: Self = Self(11);
    pub const BRIGHT_BLUE: Self = Self(12);
    pub const BRIGHT_MAGENTA: Self = Self(13);
    pub const BRIGHT_CYAN: Self = Self(14);
    pub const BRIGHT_WHITE: Self = Self(15);

    pub fn default_rgb(self) -> Option<Rgb> {
        if self.0 < 16 {
            Some(NAMED_RGB[self.0 as usize])
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Special {
    Bold = 0,
    Underline = 1,
    Blink = 2,
    Reverse = 3,
    Italic = 4,
}

impl Special {
    pub fn osc4(self) -> u16 {
        self as u16 + 256
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Dynamic {
    Foreground = 10,
    Background = 11,
    Cursor = 12,
    PointerForeground = 13,
    PointerBackground = 14,
    TektronixForeground = 15,
    TektronixBackground = 16,
    HighlightBackground = 17,
    TektronixCursor = 18,
    HighlightForeground = 19,
}

impl Dynamic {
    #[allow(clippy::should_implement_trait)]
    pub fn next(self) -> Option<Self> {
        match self {
            Self::Foreground => Some(Self::Background),
            Self::Background => Some(Self::Cursor),
            Self::Cursor => Some(Self::PointerForeground),
            Self::PointerForeground => Some(Self::PointerBackground),
            Self::PointerBackground => Some(Self::TektronixForeground),
            Self::TektronixForeground => Some(Self::TektronixBackground),
            Self::TektronixBackground => Some(Self::HighlightBackground),
            Self::HighlightBackground => Some(Self::TektronixCursor),
            Self::TektronixCursor => Some(Self::HighlightForeground),
            Self::HighlightForeground => None,
        }
    }
}

// Deferred from Ghostty's color.zig in this phase: LAB conversion,
// generate256Color, and their tests. The only production caller is Ghostty's
// config/theme startup path, which lands with theme support later.

#[cfg(test)]
mod tests {
    use super::{
        Dynamic, DynamicPalette, DynamicRgb, InvalidFormat, Name, Rgb, Special, DEFAULT_PALETTE,
    };

    // ghostty: Special::osc4 nested test (color.zig:356)
    #[test]
    fn osc4() {
        assert_eq!(Special::Bold.osc4(), 256);
        assert_eq!(Special::Underline.osc4(), 257);
        assert_eq!(Special::Blink.osc4(), 258);
        assert_eq!(Special::Reverse.osc4(), 259);
        assert_eq!(Special::Italic.osc4(), 260);
    }

    // ghostty: Dynamic::next nested test (color.zig:397)
    #[test]
    fn dynamic_next() {
        assert_eq!(Dynamic::Foreground.next(), Some(Dynamic::Background));
        assert_eq!(Dynamic::Background.next(), Some(Dynamic::Cursor));
        assert_eq!(Dynamic::Cursor.next(), Some(Dynamic::PointerForeground));
        assert_eq!(
            Dynamic::PointerForeground.next(),
            Some(Dynamic::PointerBackground)
        );
        assert_eq!(
            Dynamic::PointerBackground.next(),
            Some(Dynamic::TektronixForeground)
        );
        assert_eq!(
            Dynamic::TektronixForeground.next(),
            Some(Dynamic::TektronixBackground)
        );
        assert_eq!(
            Dynamic::TektronixBackground.next(),
            Some(Dynamic::HighlightBackground)
        );
        assert_eq!(
            Dynamic::HighlightBackground.next(),
            Some(Dynamic::TektronixCursor)
        );
        assert_eq!(
            Dynamic::TektronixCursor.next(),
            Some(Dynamic::HighlightForeground)
        );
        assert_eq!(Dynamic::HighlightForeground.next(), None);
    }

    // ghostty: "palette: default" (color.zig:762)
    #[test]
    fn palette_default() {
        for index in 0..16u8 {
            assert_eq!(
                Name(index).default_rgb(),
                Some(DEFAULT_PALETTE[usize::from(index)])
            );
        }
    }

    // ghostty: "RGB.parse" (color.zig:772)
    #[test]
    fn rgb_parse() {
        assert_eq!(Rgb::parse("rgbi:1.0/0/0"), Ok(Rgb { r: 255, g: 0, b: 0 }));
        assert_eq!(
            Rgb::parse("rgb:7f/a0a0/0"),
            Ok(Rgb {
                r: 127,
                g: 160,
                b: 0
            })
        );
        assert_eq!(
            Rgb::parse("rgb:f/ff/fff"),
            Ok(Rgb {
                r: 255,
                g: 255,
                b: 255
            })
        );
        for value in ["#ffffff", "#fff", "#fffffffff", "#ffffffffffff"] {
            assert_eq!(
                Rgb::parse(value),
                Ok(Rgb {
                    r: 255,
                    g: 255,
                    b: 255
                })
            );
        }
        assert_eq!(
            Rgb::parse("#ff0010"),
            Ok(Rgb {
                r: 255,
                g: 0,
                b: 16
            })
        );
        assert_eq!(Rgb::parse("black"), Ok(Rgb { r: 0, g: 0, b: 0 }));
        assert_eq!(Rgb::parse("red"), Ok(Rgb { r: 255, g: 0, b: 0 }));
        assert_eq!(Rgb::parse("green"), Ok(Rgb { r: 0, g: 255, b: 0 }));
        assert_eq!(Rgb::parse("blue"), Ok(Rgb { r: 0, g: 0, b: 255 }));
        assert_eq!(
            Rgb::parse("white"),
            Ok(Rgb {
                r: 255,
                g: 255,
                b: 255
            })
        );
        assert_eq!(
            Rgb::parse("LawnGreen"),
            Ok(Rgb {
                r: 124,
                g: 252,
                b: 0
            })
        );
        assert_eq!(
            Rgb::parse("medium spring green"),
            Ok(Rgb {
                r: 0,
                g: 250,
                b: 154
            })
        );
        assert_eq!(
            Rgb::parse(" Forest Green "),
            Ok(Rgb {
                r: 34,
                g: 139,
                b: 34
            })
        );

        for value in [
            "rgb;",
            "rgb:",
            ":a/a/a",
            "a/a/a",
            "rgb:a/a/a/",
            "rgb:00000///",
            "rgb:000/",
            "rgbi:a/a/a",
            "rgb:0.5/0.0/1.0",
            "rgb:not/hex/zz",
            "#",
            "#ff",
            "#ffff",
            "#fffff",
            "#gggggg",
        ] {
            assert_eq!(Rgb::parse(value), Err(InvalidFormat));
        }
    }

    // ghostty: "DynamicPalette: init" (color.zig:812)
    #[test]
    fn dynamic_palette_init() {
        let palette = DynamicPalette::new(DEFAULT_PALETTE);
        assert_eq!(palette.current, DEFAULT_PALETTE);
        assert_eq!(palette.original, DEFAULT_PALETTE);
        assert_eq!(palette.mask.count(), 0);
    }

    // ghostty: "DynamicPalette: set" (color.zig:821)
    #[test]
    fn dynamic_palette_set() {
        let mut palette = DynamicPalette::new(DEFAULT_PALETTE);
        let red = Rgb { r: 255, g: 0, b: 0 };
        palette.set(0, red);
        assert_eq!(palette.current[0], red);
        assert!(palette.mask.is_set(0));
        assert_eq!(palette.mask.count(), 1);
        assert_eq!(palette.original[0], DEFAULT_PALETTE[0]);
    }

    // ghostty: "DynamicPalette: reset" (color.zig:836)
    #[test]
    fn dynamic_palette_reset() {
        let mut palette = DynamicPalette::new(DEFAULT_PALETTE);
        let red = Rgb { r: 255, g: 0, b: 0 };
        palette.set(0, red);
        palette.reset(0);
        assert_eq!(palette.current[0], DEFAULT_PALETTE[0]);
        assert!(!palette.mask.is_set(0));
        assert_eq!(palette.mask.count(), 0);
    }

    // ghostty: "DynamicPalette: resetAll" (color.zig:850)
    #[test]
    fn dynamic_palette_reset_all() {
        let mut palette = DynamicPalette::new(DEFAULT_PALETTE);
        let red = Rgb { r: 255, g: 0, b: 0 };
        palette.set(0, red);
        palette.set(5, red);
        palette.set(10, red);
        assert_eq!(palette.mask.count(), 3);
        palette.reset_all();
        assert_eq!(palette.current, DEFAULT_PALETTE);
        assert_eq!(palette.original, DEFAULT_PALETTE);
        assert_eq!(palette.mask.count(), 0);
    }

    // ghostty: "DynamicPalette: changeDefault with no changes" (color.zig:867)
    #[test]
    fn dynamic_palette_change_default_with_no_changes() {
        let mut palette = DynamicPalette::new(DEFAULT_PALETTE);
        let mut new_palette = DEFAULT_PALETTE;
        new_palette[0] = Rgb {
            r: 100,
            g: 100,
            b: 100,
        };
        palette.change_default(new_palette);
        assert_eq!(palette.original, new_palette);
        assert_eq!(palette.current, new_palette);
        assert_eq!(palette.mask.count(), 0);
    }

    // ghostty: "DynamicPalette: changeDefault preserves changes" (color.zig:881)
    #[test]
    fn dynamic_palette_change_default_preserves_changes() {
        let mut palette = DynamicPalette::new(DEFAULT_PALETTE);
        let custom = Rgb { r: 255, g: 0, b: 0 };
        palette.set(5, custom);
        let mut new_palette = DEFAULT_PALETTE;
        new_palette[0] = Rgb {
            r: 100,
            g: 100,
            b: 100,
        };
        new_palette[5] = Rgb {
            r: 50,
            g: 50,
            b: 50,
        };
        palette.change_default(new_palette);
        assert_eq!(palette.original, new_palette);
        assert_eq!(palette.current[0], new_palette[0]);
        assert_eq!(palette.current[5], custom);
        assert!(palette.mask.is_set(5));
        assert_eq!(palette.mask.count(), 1);
    }

    // ghostty: "DynamicPalette: changeDefault with multiple changes" (color.zig:903)
    #[test]
    fn dynamic_palette_change_default_with_multiple_changes() {
        let mut palette = DynamicPalette::new(DEFAULT_PALETTE);
        let red = Rgb { r: 255, g: 0, b: 0 };
        let green = Rgb { r: 0, g: 255, b: 0 };
        let blue = Rgb { r: 0, g: 0, b: 255 };
        palette.set(1, red);
        palette.set(2, green);
        palette.set(3, blue);
        let mut new_palette = DEFAULT_PALETTE;
        new_palette[0] = Rgb {
            r: 50,
            g: 50,
            b: 50,
        };
        new_palette[1] = Rgb {
            r: 60,
            g: 60,
            b: 60,
        };
        palette.change_default(new_palette);
        assert_eq!(palette.current[0], new_palette[0]);
        assert_eq!(palette.current[1], red);
        assert_eq!(palette.current[2], green);
        assert_eq!(palette.current[3], blue);
        assert_eq!(palette.mask.count(), 3);
    }

    #[test]
    fn dynamic_rgb_reset_copies_default_into_override() {
        let default = Rgb { r: 1, g: 2, b: 3 };
        let other = Rgb { r: 4, g: 5, b: 6 };
        let mut color = DynamicRgb::new(default);
        assert_eq!(color.get(), Some(default));
        color.set(other);
        assert_eq!(color.get(), Some(other));
        color.reset();
        assert_eq!(color.get(), Some(default));
        assert_eq!(color.override_color, Some(default));
    }
}
