//! Terminal mode state and DECRPM reports.
//!
//! This ports Ghostty's `modes.zig` mode table and state container without the
//! Zig comptime type generation. The compact `ModeBits` keeps the same “one
//! bit per supported mode” shape while the public API stays explicit.

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub enum Mode {
    DisableKeyboard = 0x8002,
    Insert = 0x8004,
    SendReceiveMode = 0x800C,
    Linefeed = 0x8014,
    CursorKeys = 1,
    Column132 = 3,
    SlowScroll = 4,
    ReverseColors = 5,
    Origin = 6,
    Wraparound = 7,
    Autorepeat = 8,
    MouseEventX10 = 9,
    CursorBlinking = 12,
    CursorVisible = 25,
    EnableMode3 = 40,
    ReverseWrap = 45,
    AltScreenLegacy = 47,
    KeypadKeys = 66,
    BackarrowKeyMode = 67,
    EnableLeftAndRightMargin = 69,
    MouseEventNormal = 1000,
    MouseEventButton = 1002,
    MouseEventAny = 1003,
    FocusEvent = 1004,
    MouseFormatUtf8 = 1005,
    MouseFormatSgr = 1006,
    MouseAlternateScroll = 1007,
    MouseFormatUrxvt = 1015,
    MouseFormatSgrPixels = 1016,
    IgnoreKeypadWithNumlock = 1035,
    AltEscPrefix = 1036,
    AltSendsEscape = 1039,
    ReverseWrapExtended = 1045,
    AltScreen = 1047,
    SaveCursor = 1048,
    AltScreenSaveCursorClearEnter = 1049,
    BracketedPaste = 2004,
    SynchronizedOutput = 2026,
    GraphemeCluster = 2027,
    ReportColorScheme = 2031,
    InBandSizeReports = 2048,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModeTag {
    pub value: u16,
    pub ansi: bool,
}

impl ModeTag {
    pub const ANSI_BIT: u16 = 0x8000;
    pub const VALUE_MASK: u16 = 0x7FFF;

    pub const fn new(value: u16, ansi: bool) -> Self {
        Self {
            value: value & Self::VALUE_MASK,
            ansi,
        }
    }

    pub const fn from_mode(mode: Mode) -> Self {
        Self::from_u16(mode as u16)
    }

    pub const fn from_u16(value: u16) -> Self {
        Self {
            value: value & Self::VALUE_MASK,
            ansi: (value & Self::ANSI_BIT) != 0,
        }
    }

    pub const fn to_u16(self) -> u16 {
        self.value | if self.ansi { Self::ANSI_BIT } else { 0 }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ModeBits(u64);

impl ModeBits {
    /// The packed defaults for all modes (as declared in `ENTRIES`).
    pub const fn default_values() -> Self {
        let mut bits = Self(0);
        let mut index = 0;
        while index < ENTRIES.len() {
            if ENTRIES[index].default {
                bits.0 |= 1u64 << index;
            }
            index += 1;
        }
        bits
    }

    /// Return a copy of these bits with `mode` set to `value`. Useful for
    /// building an initial `default_modes` set for `Terminal`/`Options`.
    pub fn with_mode(mut self, mode: Mode, value: bool) -> Self {
        self.set(mode, value);
        self
    }

    fn get(self, mode: Mode) -> bool {
        let bit = mode_index(mode);
        self.0 & (1u64 << bit) != 0
    }

    fn set(&mut self, mode: Mode, value: bool) {
        let bit = mode_index(mode);
        if value {
            self.0 |= 1u64 << bit;
        } else {
            self.0 &= !(1u64 << bit);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModeState {
    values: ModeBits,
    saved: ModeBits,
    default: ModeBits,
}

impl Default for ModeState {
    fn default() -> Self {
        let default = ModeBits::default_values();
        Self {
            values: default,
            // ghostty: modes.zig:22 — `.{}`
            // carries the per-mode declaration defaults, not all-zero bits.
            saved: ModeBits::default_values(),
            default,
        }
    }
}

impl ModeState {
    /// Construct a state whose current and default values both come from
    /// `default_modes`, mirroring ghostty's `Terminal.init`
    /// (`modes = .{ .values = default_modes, .default = default_modes }`).
    pub fn with_default(default_modes: ModeBits) -> Self {
        Self {
            values: default_modes,
            // ghostty: modes.zig:22 — saved starts at the mode defaults.
            saved: ModeBits::default_values(),
            default: default_modes,
        }
    }

    pub fn reset(&mut self) {
        self.values = self.default;
        // ghostty: modes.zig:32 — reset restores saved modes to defaults too.
        self.saved = ModeBits::default_values();
    }

    pub fn set(&mut self, mode: Mode, value: bool) {
        self.values.set(mode, value);
    }

    pub fn get(&self, mode: Mode) -> bool {
        self.values.get(mode)
    }

    pub fn save(&mut self, mode: Mode) {
        self.saved.set(mode, self.values.get(mode));
    }

    pub fn restore(&mut self, mode: Mode) -> bool {
        let restored = self.saved.get(mode);
        self.values.set(mode, restored);
        restored
    }

    pub fn get_report(&self, tag: ModeTag) -> Report {
        let Some(mode) = mode_from_int(tag.value, tag.ansi) else {
            return Report {
                tag,
                state: ReportState::NotRecognized,
            };
        };
        Report {
            tag,
            state: if self.get(mode) {
                ReportState::Set
            } else {
                ReportState::Reset
            },
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Report {
    pub tag: ModeTag,
    pub state: ReportState,
}

impl Report {
    pub const MAX_SIZE: usize = 12;

    pub fn encode<W: fmt::Write>(&self, writer: &mut W) -> fmt::Result {
        write!(
            writer,
            "\x1B[{}{};{}$y",
            if self.tag.ansi { "" } else { "?" },
            self.tag.value,
            self.state as u8
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ReportState {
    NotRecognized = 0,
    Set = 1,
    Reset = 2,
    PermanentlySet = 3,
    PermanentlyReset = 4,
}

#[derive(Clone, Copy)]
struct ModeEntry {
    mode: Mode,
    value: u16,
    ansi: bool,
    default: bool,
}

const ENTRIES: [ModeEntry; 41] = [
    ModeEntry {
        mode: Mode::DisableKeyboard,
        value: 2,
        ansi: true,
        default: false,
    },
    ModeEntry {
        mode: Mode::Insert,
        value: 4,
        ansi: true,
        default: false,
    },
    ModeEntry {
        mode: Mode::SendReceiveMode,
        value: 12,
        ansi: true,
        default: true,
    },
    ModeEntry {
        mode: Mode::Linefeed,
        value: 20,
        ansi: true,
        default: false,
    },
    ModeEntry {
        mode: Mode::CursorKeys,
        value: 1,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::Column132,
        value: 3,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::SlowScroll,
        value: 4,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::ReverseColors,
        value: 5,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::Origin,
        value: 6,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::Wraparound,
        value: 7,
        ansi: false,
        default: true,
    },
    ModeEntry {
        mode: Mode::Autorepeat,
        value: 8,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::MouseEventX10,
        value: 9,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::CursorBlinking,
        value: 12,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::CursorVisible,
        value: 25,
        ansi: false,
        default: true,
    },
    ModeEntry {
        mode: Mode::EnableMode3,
        value: 40,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::ReverseWrap,
        value: 45,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::AltScreenLegacy,
        value: 47,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::KeypadKeys,
        value: 66,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::BackarrowKeyMode,
        value: 67,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::EnableLeftAndRightMargin,
        value: 69,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::MouseEventNormal,
        value: 1000,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::MouseEventButton,
        value: 1002,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::MouseEventAny,
        value: 1003,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::FocusEvent,
        value: 1004,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::MouseFormatUtf8,
        value: 1005,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::MouseFormatSgr,
        value: 1006,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::MouseAlternateScroll,
        value: 1007,
        ansi: false,
        default: true,
    },
    ModeEntry {
        mode: Mode::MouseFormatUrxvt,
        value: 1015,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::MouseFormatSgrPixels,
        value: 1016,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::IgnoreKeypadWithNumlock,
        value: 1035,
        ansi: false,
        default: true,
    },
    ModeEntry {
        mode: Mode::AltEscPrefix,
        value: 1036,
        ansi: false,
        default: true,
    },
    ModeEntry {
        mode: Mode::AltSendsEscape,
        value: 1039,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::ReverseWrapExtended,
        value: 1045,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::AltScreen,
        value: 1047,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::SaveCursor,
        value: 1048,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::AltScreenSaveCursorClearEnter,
        value: 1049,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::BracketedPaste,
        value: 2004,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::SynchronizedOutput,
        value: 2026,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::GraphemeCluster,
        value: 2027,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::ReportColorScheme,
        value: 2031,
        ansi: false,
        default: false,
    },
    ModeEntry {
        mode: Mode::InBandSizeReports,
        value: 2048,
        ansi: false,
        default: false,
    },
];

pub fn mode_from_int(value: u16, ansi: bool) -> Option<Mode> {
    ENTRIES
        .iter()
        .find(|entry| entry.value == value && entry.ansi == ansi)
        .map(|entry| entry.mode)
}

fn mode_index(mode: Mode) -> usize {
    let Some(index) = ENTRIES.iter().position(|entry| entry.mode == mode) else {
        unreachable!("all Mode variants must be in ENTRIES");
    };
    index
}

#[cfg(test)]
mod tests {
    use super::{mode_from_int, Mode, ModeBits, ModeState, ModeTag, Report, ReportState};

    fn encoded(report: Report) -> String {
        let mut output = String::new();
        report.encode(&mut output).unwrap();
        output
    }

    // ghostty: unnamed size canary (modes.zig:92)
    #[test]
    fn mode_bits_size_is_explicit() {
        assert_eq!(std::mem::size_of::<ModeBits>(), 8);
    }

    // ghostty: "order" (modes.zig:156)
    #[test]
    fn mode_tag_order_packs_value_below_ansi_bit() {
        let tag = ModeTag::new(1, false);
        assert_eq!(tag.to_u16(), 1);
        assert_eq!(ModeTag::from_u16(0x8004), ModeTag::new(4, true));
        assert_eq!(ModeTag::from_mode(Mode::Insert), ModeTag::new(4, true));
    }

    // ghostty: "modeFromInt" (modes.zig:307)
    #[test]
    fn mode_from_int_filters_by_ansi_bit() {
        assert_eq!(mode_from_int(4, true), Some(Mode::Insert));
        assert_eq!(mode_from_int(9, true), None);
        assert_eq!(mode_from_int(9, false), Some(Mode::MouseEventX10));
        assert_eq!(mode_from_int(14, true), None);
    }

    // ghostty: unnamed mode type reification (modes.zig:302)
    #[test]
    fn mode_public_types_are_reified() {
        let _ = Mode::Insert;
        let _ = ModeBits::default();
    }

    // ghostty: "ModeState" (modes.zig:314)
    #[test]
    fn mode_state_sets_saves_restores_and_resets() {
        let mut state = ModeState::default();
        assert!(!state.get(Mode::CursorKeys));
        assert!(state.get(Mode::Wraparound));
        assert!(state.get(Mode::SendReceiveMode));

        state.set(Mode::CursorKeys, true);
        assert!(state.get(Mode::CursorKeys));
        state.save(Mode::CursorKeys);
        state.set(Mode::CursorKeys, false);
        assert!(!state.get(Mode::CursorKeys));
        assert!(state.restore(Mode::CursorKeys));
        assert!(state.get(Mode::CursorKeys));

        state.set(Mode::Wraparound, false);
        state.save(Mode::CursorKeys);
        state.reset();
        assert!(!state.get(Mode::CursorKeys));
        assert!(state.get(Mode::Wraparound));
    }

    // ghostty: "getReport known DEC mode" (modes.zig:330)
    #[test]
    fn get_report_known_dec_mode() {
        let mut state = ModeState::default();
        let report = state.get_report(ModeTag::new(1, false));
        assert_eq!(report.state, ReportState::Reset);
        assert_eq!(report.tag, ModeTag::new(1, false));

        state.set(Mode::CursorKeys, true);
        let report = state.get_report(ModeTag::new(1, false));
        assert_eq!(report.state, ReportState::Set);
    }

    // ghostty: "getReport known ANSI mode" (modes.zig:342)
    #[test]
    fn get_report_known_ansi_mode() {
        let mut state = ModeState::default();
        state.set(Mode::Insert, true);
        let report = state.get_report(ModeTag::new(4, true));
        assert_eq!(report.state, ReportState::Set);
        assert_eq!(report.tag, ModeTag::new(4, true));
    }

    // ghostty: "getReport unknown mode" (modes.zig:350)
    #[test]
    fn get_report_unknown_mode() {
        let report = ModeState::default().get_report(ModeTag::new(9999, false));
        assert_eq!(report.state, ReportState::NotRecognized);
    }

    // ghostty: "Report.encode DEC mode set" (modes.zig:356)
    #[test]
    fn report_encode_dec_mode_set() {
        assert_eq!(
            encoded(Report {
                tag: ModeTag::new(1, false),
                state: ReportState::Set,
            }),
            "\x1B[?1;1$y"
        );
    }

    // ghostty: "Report.encode DEC mode reset" (modes.zig:364)
    #[test]
    fn report_encode_dec_mode_reset() {
        assert_eq!(
            encoded(Report {
                tag: ModeTag::new(1, false),
                state: ReportState::Reset,
            }),
            "\x1B[?1;2$y"
        );
    }

    // ghostty: "Report.encode ANSI mode" (modes.zig:372)
    #[test]
    fn report_encode_ansi_mode() {
        assert_eq!(
            encoded(Report {
                tag: ModeTag::new(4, true),
                state: ReportState::Set,
            }),
            "\x1B[4;1$y"
        );
    }

    // ghostty: "Report.encode not recognized" (modes.zig:380)
    #[test]
    fn report_encode_not_recognized() {
        assert_eq!(
            encoded(Report {
                tag: ModeTag::new(9999, false),
                state: ReportState::NotRecognized,
            }),
            "\x1B[?9999;0$y"
        );
    }

    // port-added: The ANSI bit disambiguates SRM (12) from DEC cursor blinking.
    #[test]
    fn duplicate_mode_value_is_disambiguated_by_ansi_bit() {
        assert_eq!(mode_from_int(12, true), Some(Mode::SendReceiveMode));
        assert_eq!(mode_from_int(12, false), Some(Mode::CursorBlinking));
    }

    // port-added: The largest report fits in the public static bound.
    #[test]
    fn report_max_size_covers_largest_wire_encoding() {
        let report = Report {
            tag: ModeTag::new(ModeTag::VALUE_MASK, false),
            state: ReportState::PermanentlyReset,
        };
        let output = encoded(report);
        assert_eq!(output, "\x1B[?32767;4$y");
        assert!(output.len() <= Report::MAX_SIZE);
    }
}
