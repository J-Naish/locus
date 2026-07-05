//! Device-attributes response encoders.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Req {
    Primary,
    Secondary,
    Tertiary,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Attributes {
    pub primary: Primary,
    pub secondary: Secondary,
    pub tertiary: Tertiary,
}

impl Attributes {
    pub fn encode<W: std::fmt::Write>(&self, req: Req, writer: &mut W) -> std::fmt::Result {
        match req {
            Req::Primary => self.primary.encode(writer),
            Req::Secondary => self.secondary.encode(writer),
            Req::Tertiary => self.tertiary.encode(writer),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum ConformanceLevel {
    Vt100 = 1,
    Vt132 = 4,
    Vt102 = 6,
    Vt131 = 7,
    Vt125 = 12,
    Level2 = 62,
    Level3 = 63,
    Level4 = 64,
    Level5 = 65,
}

impl ConformanceLevel {
    pub const VT101: Self = Self::Vt100;
    pub const VT220: Self = Self::Level2;
    pub const VT240: Self = Self::Level2;
    pub const VT320: Self = Self::Level3;
    pub const VT340: Self = Self::Level3;
    pub const VT420: Self = Self::Level4;
    pub const VT510: Self = Self::Level5;
    pub const VT520: Self = Self::Level5;
    pub const VT525: Self = Self::Level5;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum DeviceType {
    Vt100 = 0,
    Vt220 = 1,
    Vt240 = 2,
    Vt330 = 18,
    Vt340 = 19,
    Vt320 = 24,
    Vt382 = 32,
    Vt420 = 41,
    Vt510 = 61,
    Vt520 = 64,
    Vt525 = 65,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum Feature {
    Columns132 = 1,
    Printer = 2,
    Regis = 3,
    Sixel = 4,
    SelectiveErase = 6,
    UserDefinedKeys = 8,
    NationalReplacement = 9,
    TechnicalCharacters = 15,
    Locator = 16,
    TerminalState = 17,
    Windowing = 18,
    HorizontalScrolling = 21,
    AnsiColor = 22,
    RectangularEditing = 28,
    AnsiTextLocator = 29,
    Clipboard = 52,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Primary {
    pub conformance_level: ConformanceLevel,
    /// Ghostty's DA enums are open. This phase only ports the declared feature
    /// vocabulary and keeps the Rust enum closed until a caller needs more.
    pub features: Vec<Feature>,
}

impl Default for Primary {
    fn default() -> Self {
        Self {
            conformance_level: ConformanceLevel::VT220,
            features: vec![Feature::AnsiColor],
        }
    }
}

impl Primary {
    pub fn encode<W: std::fmt::Write>(&self, writer: &mut W) -> std::fmt::Result {
        write!(writer, "\x1B[?{}", self.conformance_level as u16)?;
        for feature in &self.features {
            write!(writer, ";{}", *feature as u16)?;
        }
        writer.write_str("c")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Secondary {
    pub device_type: DeviceType,
    pub firmware_version: u16,
    pub rom_cartridge: u16,
}

impl Default for Secondary {
    fn default() -> Self {
        Self {
            device_type: DeviceType::Vt220,
            firmware_version: 0,
            rom_cartridge: 0,
        }
    }
}

impl Secondary {
    pub fn encode<W: std::fmt::Write>(&self, writer: &mut W) -> std::fmt::Result {
        write!(
            writer,
            "\x1B[>{};{};{}c",
            self.device_type as u16, self.firmware_version, self.rom_cartridge
        )
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Tertiary {
    pub unit_id: u32,
}

impl Tertiary {
    pub fn encode<W: std::fmt::Write>(&self, writer: &mut W) -> std::fmt::Result {
        write!(writer, "\x1BP!|{:08X}\x1B\\", self.unit_id)
    }
}

#[cfg(test)]
mod tests {
    use super::{ConformanceLevel, Feature, Primary, Secondary, Tertiary};

    fn encoded_primary(primary: Primary) -> String {
        let mut output = String::new();
        primary.encode(&mut output).unwrap();
        output
    }

    // ghostty: "primary default" (device_attributes.zig:174)
    #[test]
    fn primary_default() {
        assert_eq!(encoded_primary(Primary::default()), "\x1B[?62;22c");
    }

    // ghostty: "primary with clipboard" (device_attributes.zig:181)
    #[test]
    fn primary_with_clipboard() {
        assert_eq!(
            encoded_primary(Primary {
                features: vec![Feature::AnsiColor, Feature::Clipboard],
                ..Primary::default()
            }),
            "\x1B[?62;22;52c"
        );
    }

    // ghostty: "primary with multiple features" (device_attributes.zig:188)
    #[test]
    fn primary_with_multiple_features() {
        assert_eq!(
            encoded_primary(Primary {
                conformance_level: ConformanceLevel::VT420,
                features: vec![
                    Feature::Columns132,
                    Feature::SelectiveErase,
                    Feature::AnsiColor
                ],
            }),
            "\x1B[?64;1;6;22c"
        );
    }

    // ghostty: "primary no features" (device_attributes.zig:198)
    #[test]
    fn primary_no_features() {
        assert_eq!(
            encoded_primary(Primary {
                conformance_level: ConformanceLevel::Vt100,
                features: Vec::new(),
            }),
            "\x1B[?1c"
        );
    }

    // ghostty: "secondary default" (device_attributes.zig:208)
    #[test]
    fn secondary_default() {
        let mut output = String::new();
        Secondary::default().encode(&mut output).unwrap();
        assert_eq!(output, "\x1B[>1;0;0c");
    }

    // ghostty: "tertiary default" (device_attributes.zig:215)
    #[test]
    fn tertiary_default() {
        let mut output = String::new();
        Tertiary::default().encode(&mut output).unwrap();
        assert_eq!(output, "\x1BP!|00000000\x1B\\");
    }

    // ghostty: "tertiary custom unit id" (device_attributes.zig:222)
    #[test]
    fn tertiary_custom_unit_id() {
        let mut output = String::new();
        Tertiary {
            unit_id: 0xAABBCCDD,
        }
        .encode(&mut output)
        .unwrap();
        assert_eq!(output, "\x1BP!|AABBCCDD\x1B\\");
    }
}
