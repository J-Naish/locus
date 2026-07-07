//! Terminal key encoding.

use super::function_keys;
use super::key::{Action, Key, KeyEvent};
use super::key_mods::{Mods, Side};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OptionAsAlt {
    #[default]
    False,
    True,
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Options {
    pub cursor_key_application: bool,
    pub keypad_key_application: bool,
    pub backarrow_key_mode: bool,
    pub ignore_keypad_with_numlock: bool,
    pub alt_esc_prefix: bool,
    pub modify_other_keys_state_2: bool,
    pub macos_option_as_alt: OptionAsAlt,
    pub is_macos: bool,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            cursor_key_application: false,
            keypad_key_application: false,
            backarrow_key_mode: false,
            ignore_keypad_with_numlock: false,
            alt_esc_prefix: false,
            modify_other_keys_state_2: false,
            macos_option_as_alt: OptionAsAlt::False,
            is_macos: cfg!(target_os = "macos"),
        }
    }
}

pub fn encode(event: KeyEvent<'_>, opts: Options) -> Vec<u8> {
    // The Kitty keyboard protocol branch is intentionally deferred to the next
    // input phase; this phase always uses Ghostty's legacy fallback path.
    legacy(event, opts)
}

pub fn legacy(event: KeyEvent<'_>, opts: Options) -> Vec<u8> {
    let all_mods = event.mods;
    let effective_mods = event.effective_mods();
    let binding_mods = effective_mods.binding();
    let mut output = Vec::new();

    if !matches!(event.action, Action::Press | Action::Repeat) {
        return output;
    }

    if event.composing {
        return output;
    }

    if let Some(sequence) = pc_style_function_key(event.key, all_mods, opts) {
        let mut emit_pc_style = true;
        if !event.utf8.is_empty()
            && matches!(event.key, Key::Backspace | Key::Enter | Key::Escape)
            && !is_control_utf8(event.utf8)
        {
            if event.key == Key::Backspace {
                return output;
            }
            emit_pc_style = false;
        }

        if emit_pc_style {
            output.extend_from_slice(sequence.as_bytes());
            return output;
        }
    }

    if let Some(byte) = ctrl_seq(event.key, event.utf8, event.unshifted_codepoint, all_mods) {
        if binding_mods.alt {
            output.push(0x1b);
        }
        output.push(byte);
        return output;
    }

    if event.utf8.is_empty() {
        if let Some(byte) = legacy_alt_prefix(event, binding_mods, all_mods, opts) {
            output.push(0x1b);
            output.push(byte);
        }
        return output;
    }

    if opts.modify_other_keys_state_2 {
        if let Some(codepoint) = single_codepoint(event.utf8) {
            let mods = modify_other_mods(event.mods, opts);
            let should_modify = (0x40..=0x7f).contains(&codepoint)
                || {
                    let mut no_shift = mods;
                    no_shift.shift = false;
                    !no_shift.empty()
                }
                || (mods.shift && codepoint == ' ' as u32);

            if should_modify {
                if let Some(code) = function_keys::modifier_code(mods) {
                    output.extend_from_slice(format!("\x1b[27;{code};{codepoint}~").as_bytes());
                    return output;
                }
            }
        }
    }

    if event.mods.ctrl {
        if let Some(mut codepoint) = single_codepoint(event.utf8) {
            let mut mods = CsiUMods::from_input(event.mods);

            if (b'A' as u32..=b'Z' as u32).contains(&codepoint) && mods.shift {
                codepoint += (b'a' - b'A') as u32;
            }

            if event.unshifted_codepoint != codepoint {
                mods.shift = false;
            }

            output.extend_from_slice(format!("\x1b[{codepoint};{}u", mods.seq_int()).as_bytes());
            return output;
        }
    }

    if let Some(byte) = legacy_alt_prefix(event, binding_mods, all_mods, opts) {
        output.push(0x1b);
        output.push(byte);
        return output;
    }

    if opts.is_macos && all_mods.super_key {
        return output;
    }

    output.extend_from_slice(event.utf8);
    output
}

fn modify_other_mods(mut mods: Mods, opts: Options) -> Mods {
    mods = mods.binding();
    if opts.is_macos {
        let keep_alt = match opts.macos_option_as_alt {
            OptionAsAlt::False => false,
            OptionAsAlt::True => true,
            OptionAsAlt::Left => mods.sides.alt == Side::Left,
            OptionAsAlt::Right => mods.sides.alt == Side::Right,
        };
        if !keep_alt {
            mods.alt = false;
        }
    }
    mods
}

fn legacy_alt_prefix(
    event: KeyEvent<'_>,
    binding_mods: Mods,
    mods: Mods,
    opts: Options,
) -> Option<u8> {
    if !binding_mods.alt || !opts.alt_esc_prefix {
        return None;
    }

    if opts.is_macos {
        match opts.macos_option_as_alt {
            OptionAsAlt::False => return None,
            OptionAsAlt::Left if mods.sides.alt == Side::Right => return None,
            OptionAsAlt::Right if mods.sides.alt == Side::Left => return None,
            OptionAsAlt::True | OptionAsAlt::Left | OptionAsAlt::Right => {}
        }
    }

    if event.utf8.len() == 1 {
        return Some(event.utf8[0]);
    }

    u8::try_from(event.unshifted_codepoint).ok()
}

fn pc_style_function_key(key: Key, mods: Mods, opts: Options) -> Option<String> {
    let binding = mods.binding();
    let keypad_application = !opts.ignore_keypad_with_numlock && opts.keypad_key_application;

    if let Some(sequence) = backspace_sequence(key, binding, opts) {
        return Some(sequence.to_owned());
    }
    if let Some(sequence) = tab_sequence(key, binding, opts.modify_other_keys_state_2) {
        return Some(sequence.to_owned());
    }
    if let Some(sequence) = enter_sequence(key, binding, opts.modify_other_keys_state_2) {
        return Some(sequence.to_owned());
    }
    if let Some(sequence) = escape_sequence(key, binding) {
        return Some(sequence.to_owned());
    }

    if let Some(code) = function_keys::modifier_code(binding) {
        if let Some(pattern) = pc_style_pattern(key) {
            return Some(pattern.replace("{}", &code.to_string()));
        }

        if keypad_application {
            if let Some(suffix) = keypad_suffix(key) {
                return Some(format!("\x1bO{code}{suffix}"));
            }
        }
    }

    match key {
        Key::ArrowUp => Some(cursor_sequence(
            opts.cursor_key_application,
            "\x1b[A",
            "\x1bOA",
        )),
        Key::ArrowDown => Some(cursor_sequence(
            opts.cursor_key_application,
            "\x1b[B",
            "\x1bOB",
        )),
        Key::ArrowRight => Some(cursor_sequence(
            opts.cursor_key_application,
            "\x1b[C",
            "\x1bOC",
        )),
        Key::ArrowLeft => Some(cursor_sequence(
            opts.cursor_key_application,
            "\x1b[D",
            "\x1bOD",
        )),
        Key::Home => Some(cursor_sequence(
            opts.cursor_key_application,
            "\x1b[H",
            "\x1bOH",
        )),
        Key::End => Some(cursor_sequence(
            opts.cursor_key_application,
            "\x1b[F",
            "\x1bOF",
        )),
        Key::Insert => Some("\x1b[2~".to_owned()),
        Key::Delete => Some("\x1b[3~".to_owned()),
        Key::PageUp => Some("\x1b[5~".to_owned()),
        Key::PageDown => Some("\x1b[6~".to_owned()),
        Key::F1 => Some("\x1bOP".to_owned()),
        Key::F2 => Some("\x1bOQ".to_owned()),
        Key::F3 => Some("\x1bOR".to_owned()),
        Key::F4 => Some("\x1bOS".to_owned()),
        Key::F5 => Some("\x1b[15~".to_owned()),
        Key::F6 => Some("\x1b[17~".to_owned()),
        Key::F7 => Some("\x1b[18~".to_owned()),
        Key::F8 => Some("\x1b[19~".to_owned()),
        Key::F9 => Some("\x1b[20~".to_owned()),
        Key::F10 => Some("\x1b[21~".to_owned()),
        Key::F11 => Some("\x1b[23~".to_owned()),
        Key::F12 => Some("\x1b[24~".to_owned()),
        Key::NumpadEnter => Some(if keypad_application {
            "\x1bOM".to_owned()
        } else {
            "\r".to_owned()
        }),
        key if keypad_application => keypad_suffix(key).map(|suffix| format!("\x1bO{suffix}")),
        _ => None,
    }
}

fn cursor_sequence(application: bool, normal: &str, application_sequence: &str) -> String {
    if application {
        application_sequence.to_owned()
    } else {
        normal.to_owned()
    }
}

fn pc_style_pattern(key: Key) -> Option<&'static str> {
    match key {
        Key::ArrowUp | Key::NumpadUp => Some("\x1b[1;{}A"),
        Key::ArrowDown | Key::NumpadDown => Some("\x1b[1;{}B"),
        Key::ArrowRight | Key::NumpadRight => Some("\x1b[1;{}C"),
        Key::ArrowLeft | Key::NumpadLeft => Some("\x1b[1;{}D"),
        Key::NumpadBegin => Some("\x1b[1;{}E"),
        Key::Home | Key::NumpadHome => Some("\x1b[1;{}H"),
        Key::End | Key::NumpadEnd => Some("\x1b[1;{}F"),
        Key::Insert | Key::NumpadInsert => Some("\x1b[2;{}~"),
        Key::Delete | Key::NumpadDelete => Some("\x1b[3;{}~"),
        Key::PageUp | Key::NumpadPageUp => Some("\x1b[5;{}~"),
        Key::PageDown | Key::NumpadPageDown => Some("\x1b[6;{}~"),
        Key::F1 => Some("\x1b[1;{}P"),
        Key::F2 => Some("\x1b[1;{}Q"),
        Key::F3 => Some("\x1b[13;{}~"),
        Key::F4 => Some("\x1b[1;{}S"),
        Key::F5 => Some("\x1b[15;{}~"),
        Key::F6 => Some("\x1b[17;{}~"),
        Key::F7 => Some("\x1b[18;{}~"),
        Key::F8 => Some("\x1b[19;{}~"),
        Key::F9 => Some("\x1b[20;{}~"),
        Key::F10 => Some("\x1b[21;{}~"),
        Key::F11 => Some("\x1b[23;{}~"),
        Key::F12 => Some("\x1b[24;{}~"),
        _ => None,
    }
}

fn keypad_suffix(key: Key) -> Option<&'static str> {
    match key {
        Key::Numpad0 => Some("p"),
        Key::Numpad1 => Some("q"),
        Key::Numpad2 => Some("r"),
        Key::Numpad3 => Some("s"),
        Key::Numpad4 => Some("t"),
        Key::Numpad5 => Some("u"),
        Key::Numpad6 => Some("v"),
        Key::Numpad7 => Some("w"),
        Key::Numpad8 => Some("x"),
        Key::Numpad9 => Some("y"),
        Key::NumpadDecimal => Some("n"),
        Key::NumpadDivide => Some("o"),
        Key::NumpadMultiply => Some("j"),
        Key::NumpadSubtract => Some("m"),
        Key::NumpadAdd => Some("k"),
        Key::NumpadEnter => Some("M"),
        _ => None,
    }
}

fn backspace_sequence(key: Key, mods: Mods, opts: Options) -> Option<&'static str> {
    if key != Key::Backspace {
        return None;
    }

    if opts.modify_other_keys_state_2 {
        if let Some(code) = function_keys::modifier_code(mods) {
            return match code {
                2 => Some("\x1b[27;2;127~"),
                3 => Some("\x1b[27;3;127~"),
                4 => Some("\x1b[27;4;127~"),
                6 => Some("\x1b[27;6;127~"),
                7 => Some("\x1b[27;7;127~"),
                8 => Some("\x1b[27;8;127~"),
                9 => Some("\x1b[27;9;127~"),
                10 => Some("\x1b[27;10;127~"),
                11 => Some("\x1b[27;11;127~"),
                12 => Some("\x1b[27;12;127~"),
                13 => Some("\x1b[27;13;127~"),
                14 => Some("\x1b[27;14;127~"),
                15 => Some("\x1b[27;15;127~"),
                16 => Some("\x1b[27;16;127~"),
                _ => None,
            };
        }
    }

    match (mods.ctrl, mods.shift, mods.alt, opts.backarrow_key_mode) {
        (true, true, false, _) => Some("\x08"),
        (true, false, false, false) => Some("\x08"),
        (true, false, false, true) => Some("\x7f"),
        (false, false, false, false) => Some("\x7f"),
        (false, false, false, true) => Some("\x08"),
        (false, true, false, _) => Some("\x7f"),
        (false, false, true, _) | (false, true, true, _) => Some("\x1b\x7f"),
        (true, _, true, _) => Some("\x1b\x08"),
    }
}

fn tab_sequence(key: Key, mods: Mods, modify_other_keys: bool) -> Option<&'static str> {
    if key != Key::Tab {
        return None;
    }
    if modify_other_keys {
        return match function_keys::modifier_code(mods) {
            Some(2) => Some("\x1b[27;2;9~"),
            Some(3) => Some("\x1b[27;3;9~"),
            Some(4) => Some("\x1b[27;4;9~"),
            Some(5) => Some("\x1b[27;5;9~"),
            Some(6) => Some("\x1b[27;6;9~"),
            Some(7) => Some("\x1b[27;7;9~"),
            Some(8) => Some("\x1b[27;8;9~"),
            Some(9) => Some("\x1b[27;9;9~"),
            Some(10) => Some("\x1b[27;10;9~"),
            Some(11) => Some("\x1b[27;11;9~"),
            Some(12) => Some("\x1b[27;12;9~"),
            Some(13) => Some("\x1b[27;13;9~"),
            Some(14) => Some("\x1b[27;14;9~"),
            Some(15) => Some("\x1b[27;15;9~"),
            Some(16) => Some("\x1b[27;16;9~"),
            _ => Some("\t"),
        };
    }
    match (mods.shift, mods.alt, mods.ctrl, mods.super_key) {
        (true, false, false, false) => Some("\x1b[Z"),
        (false, true, false, false) => Some("\x1b\t"),
        (false, false, false, false) => Some("\t"),
        _ => function_keys::modifier_code(mods)
            .and_then(|code| match code {
                4 => Some("\x1b[27;4;9~"),
                5 => Some("\x1b[27;5;9~"),
                6 => Some("\x1b[27;6;9~"),
                7 => Some("\x1b[27;7;9~"),
                8 => Some("\x1b[27;8;9~"),
                9 => Some("\x1b[27;9;9~"),
                10 => Some("\x1b[27;10;9~"),
                11 => Some("\x1b[27;11;9~"),
                12 => Some("\x1b[27;12;9~"),
                13 => Some("\x1b[27;13;9~"),
                14 => Some("\x1b[27;14;9~"),
                15 => Some("\x1b[27;15;9~"),
                16 => Some("\x1b[27;16;9~"),
                _ => None,
            })
            .or(Some("\t")),
    }
}

fn enter_sequence(key: Key, mods: Mods, modify_other_keys: bool) -> Option<&'static str> {
    if key != Key::Enter {
        return None;
    }
    if modify_other_keys {
        return function_keys::modifier_code(mods)
            .and_then(|code| match code {
                2 => Some("\x1b[27;2;13~"),
                3 => Some("\x1b[27;3;13~"),
                4 => Some("\x1b[27;4;13~"),
                5 => Some("\x1b[27;5;13~"),
                6 => Some("\x1b[27;6;13~"),
                7 => Some("\x1b[27;7;13~"),
                8 => Some("\x1b[27;8;13~"),
                9 => Some("\x1b[27;9;13~"),
                10 => Some("\x1b[27;10;13~"),
                11 => Some("\x1b[27;11;13~"),
                12 => Some("\x1b[27;12;13~"),
                13 => Some("\x1b[27;13;13~"),
                14 => Some("\x1b[27;14;13~"),
                15 => Some("\x1b[27;15;13~"),
                16 => Some("\x1b[27;16;13~"),
                _ => None,
            })
            .or(Some("\r"));
    }
    match (mods.shift, mods.alt, mods.ctrl, mods.super_key) {
        (false, false, false, false) => Some("\r"),
        (true, false, false, false) => Some("\x1b[27;2;13~"),
        (false, true, false, false) => Some("\x1b\r"),
        _ => function_keys::modifier_code(mods).and_then(|code| match code {
            4 => Some("\x1b[27;4;13~"),
            5 => Some("\x1b[27;5;13~"),
            6 => Some("\x1b[27;6;13~"),
            7 => Some("\x1b[27;7;13~"),
            8 => Some("\x1b[27;8;13~"),
            9 => Some("\x1b[27;9;13~"),
            10 => Some("\x1b[27;10;13~"),
            11 => Some("\x1b[27;11;13~"),
            12 => Some("\x1b[27;12;13~"),
            13 => Some("\x1b[27;13;13~"),
            14 => Some("\x1b[27;14;13~"),
            15 => Some("\x1b[27;15;13~"),
            16 => Some("\x1b[27;16;13~"),
            _ => None,
        }),
    }
}

fn escape_sequence(key: Key, mods: Mods) -> Option<&'static str> {
    if key != Key::Escape {
        return None;
    }
    match function_keys::modifier_code(mods) {
        Some(2) => Some("\x1b[27;2;27~"),
        Some(3) => Some("\x1b\x1b"),
        Some(4) => Some("\x1b[27;4;27~"),
        Some(5) => Some("\x1b[27;5;27~"),
        Some(6) => Some("\x1b[27;6;27~"),
        Some(7) => Some("\x1b[27;7;27~"),
        Some(8) => Some("\x1b[27;8;27~"),
        Some(9) => Some("\x1b[27;9;27~"),
        Some(10) => Some("\x1b[27;10;27~"),
        Some(11) => Some("\x1b[27;11;27~"),
        Some(12) => Some("\x1b[27;12;27~"),
        Some(13) => Some("\x1b[27;13;27~"),
        Some(14) => Some("\x1b[27;14;27~"),
        Some(15) => Some("\x1b[27;15;27~"),
        Some(16) => Some("\x1b[27;16;27~"),
        _ => Some("\x1b"),
    }
}

fn single_codepoint(bytes: &[u8]) -> Option<u32> {
    let mut chars = std::str::from_utf8(bytes).ok()?.chars();
    let ch = chars.next()?;
    if chars.next().is_some() {
        None
    } else {
        Some(ch as u32)
    }
}

fn is_control(cp: u32) -> bool {
    cp < 0x20 || cp == 0x7f
}

fn is_control_utf8(bytes: &[u8]) -> bool {
    bytes.len() == 1 && is_control(bytes[0] as u32)
}

fn ctrl_seq(logical_key: Key, utf8: &[u8], unshifted_codepoint: u32, mods: Mods) -> Option<u8> {
    if !mods.ctrl {
        return None;
    }

    let ctrl_only = Mods {
        ctrl: true,
        ..Mods::none()
    }
    .int();

    let mut unset_mods = mods.binding();
    unset_mods.alt = false;

    let mut byte = if utf8.len() == 1 {
        utf8[0]
    } else if let Some(codepoint) = logical_key.codepoint() {
        let byte = u8::try_from(codepoint).ok()?;
        if unset_mods.int() != ctrl_only {
            return None;
        }
        byte
    } else {
        return None;
    };

    if unset_mods.shift && !byte.is_ascii_uppercase() && byte != b'@' {
        unset_mods.shift = false;
    }

    if byte.is_ascii_uppercase() && unshifted_codepoint > 0 {
        if let Ok(unshifted) = u8::try_from(unshifted_codepoint) {
            byte = unshifted;
        }
    }

    if unset_mods.int() != ctrl_only {
        return None;
    }

    match byte {
        b' ' => Some(0),
        b'/' => Some(31),
        b'0' => Some(48),
        b'1' => Some(49),
        b'2' => Some(0),
        b'3' => Some(27),
        b'4' => Some(28),
        b'5' => Some(29),
        b'6' => Some(30),
        b'7' => Some(31),
        b'8' => Some(127),
        b'9' => Some(57),
        b'?' => Some(127),
        b'@' => Some(0),
        b'\\' => Some(28),
        b']' => Some(29),
        b'^' => Some(30),
        b'_' => Some(31),
        b'a' => Some(1),
        b'b' => Some(2),
        b'c' => Some(3),
        b'd' => Some(4),
        b'e' => Some(5),
        b'f' => Some(6),
        b'g' => Some(7),
        b'h' => Some(8),
        b'j' => Some(10),
        b'k' => Some(11),
        b'l' => Some(12),
        b'n' => Some(14),
        b'o' => Some(15),
        b'p' => Some(16),
        b'q' => Some(17),
        b'r' => Some(18),
        b's' => Some(19),
        b't' => Some(20),
        b'u' => Some(21),
        b'v' => Some(22),
        b'w' => Some(23),
        b'x' => Some(24),
        b'y' => Some(25),
        b'z' => Some(26),
        b'~' => Some(30),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CsiUMods {
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
}

impl CsiUMods {
    pub fn from_input(mods: Mods) -> Self {
        Self {
            shift: mods.shift,
            alt: mods.alt,
            ctrl: mods.ctrl,
        }
    }

    pub const fn int(self) -> u8 {
        (self.shift as u8) | ((self.alt as u8) << 1) | ((self.ctrl as u8) << 2)
    }

    pub const fn seq_int(self) -> u8 {
        self.int() + 1
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::key_mods::{ModifierSides, Side};

    fn event(key: Key) -> KeyEvent<'static> {
        KeyEvent {
            key,
            ..KeyEvent::default()
        }
    }

    fn text_event(key: Key, utf8: &'static [u8]) -> KeyEvent<'static> {
        KeyEvent {
            key,
            utf8,
            ..KeyEvent::default()
        }
    }

    fn m(shift: bool, ctrl: bool, alt: bool, super_key: bool) -> Mods {
        Mods {
            shift,
            ctrl,
            alt,
            super_key,
            ..Mods::none()
        }
    }

    fn s(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes).into_owned()
    }

    #[test]
    fn csiu_modifier_sequence_values() {
        // ghostty: "modifier sequence values" (key_encode.zig:868)
        assert_eq!(CsiUMods::default().seq_int(), 1);
        assert_eq!(
            CsiUMods {
                shift: true,
                ..CsiUMods::default()
            }
            .seq_int(),
            2
        );
        assert_eq!(
            CsiUMods {
                alt: true,
                ..CsiUMods::default()
            }
            .seq_int(),
            3
        );
        assert_eq!(
            CsiUMods {
                ctrl: true,
                ..CsiUMods::default()
            }
            .seq_int(),
            5
        );
        assert_eq!(
            CsiUMods {
                alt: true,
                shift: true,
                ..CsiUMods::default()
            }
            .seq_int(),
            4
        );
        assert_eq!(
            CsiUMods {
                ctrl: true,
                shift: true,
                ..CsiUMods::default()
            }
            .seq_int(),
            6
        );
        assert_eq!(
            CsiUMods {
                alt: true,
                ctrl: true,
                ..CsiUMods::default()
            }
            .seq_int(),
            7
        );
        assert_eq!(
            CsiUMods {
                alt: true,
                ctrl: true,
                shift: true,
            }
            .seq_int(),
            8
        );
    }

    #[test]
    fn legacy_backspace_with_utf8_dead_key_state() {
        // ghostty: "legacy: backspace with utf8 (dead key state)" (key_encode.zig:1904)
        let actual = legacy(
            KeyEvent {
                key: Key::Backspace,
                utf8: b"A",
                unshifted_codepoint: 0x0d,
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"");
    }

    #[test]
    fn legacy_enter_with_utf8_dead_key_state() {
        // ghostty: "legacy: enter with utf8 (dead key state)" (key_encode.zig:1952)
        let actual = legacy(
            KeyEvent {
                key: Key::Enter,
                utf8: b"A",
                unshifted_codepoint: 0x0d,
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"A");
    }

    #[test]
    fn legacy_esc_with_utf8_dead_key_state() {
        // ghostty: "legacy: esc with utf8 (dead key state)" (key_encode.zig:1963)
        let actual = legacy(
            KeyEvent {
                key: Key::Escape,
                utf8: b"A",
                unshifted_codepoint: 0x0d,
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"A");
    }

    #[test]
    fn legacy_ctrl_shift_minus_underscore_on_us() {
        // ghostty: "legacy: ctrl+shift+minus (underscore on US)" (key_encode.zig:1974)
        let actual = legacy(
            KeyEvent {
                key: Key::Minus,
                mods: m(true, true, false, false),
                utf8: b"_",
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x1f");
    }

    #[test]
    fn legacy_ctrl_alt_c() {
        // ghostty: "legacy: ctrl+alt+c" (key_encode.zig:1985)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyC,
                mods: m(false, true, true, false),
                utf8: b"c",
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x1b\x03");
    }

    #[test]
    fn legacy_alt_c() {
        // ghostty: "legacy: alt+c" (key_encode.zig:1996)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyC,
                mods: m(false, false, true, false),
                utf8: b"c",
                ..KeyEvent::default()
            },
            Options {
                alt_esc_prefix: true,
                macos_option_as_alt: OptionAsAlt::True,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1bc");
    }

    #[test]
    fn legacy_alt_e_only_unshifted() {
        // ghostty: "legacy: alt+e only unshifted" (key_encode.zig:2010)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyE,
                mods: m(false, false, true, false),
                unshifted_codepoint: 'e' as u32,
                ..KeyEvent::default()
            },
            Options {
                alt_esc_prefix: true,
                macos_option_as_alt: OptionAsAlt::True,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1be");
    }

    #[test]
    fn legacy_alt_x_macos_runtime() {
        // ghostty: "legacy: alt+x macos" (key_encode.zig:2024)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyC,
                mods: m(false, false, true, false),
                utf8: "≈".as_bytes(),
                unshifted_codepoint: 'c' as u32,
                ..KeyEvent::default()
            },
            Options {
                alt_esc_prefix: true,
                macos_option_as_alt: OptionAsAlt::True,
                is_macos: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1bc");
    }

    #[test]
    fn legacy_shift_alt_period_macos_runtime() {
        // ghostty: "legacy: shift+alt+. macos" (key_encode.zig:2041)
        let actual = legacy(
            KeyEvent {
                key: Key::Period,
                mods: m(true, false, true, false),
                utf8: b">",
                unshifted_codepoint: '.' as u32,
                ..KeyEvent::default()
            },
            Options {
                alt_esc_prefix: true,
                macos_option_as_alt: OptionAsAlt::True,
                is_macos: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1b>");
    }

    #[test]
    fn legacy_alt_cyrillic_falls_through_to_text() {
        // ghostty: "legacy: alt+ф" (key_encode.zig:2058)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyF,
                mods: m(false, false, true, false),
                utf8: "ф".as_bytes(),
                ..KeyEvent::default()
            },
            Options {
                alt_esc_prefix: true,
                ..Options::default()
            },
        );
        assert_eq!(s(&actual), "ф");
    }

    #[test]
    fn legacy_ctrl_c() {
        // ghostty: "legacy: ctrl+c" (key_encode.zig:2071)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyC,
                mods: m(false, true, false, false),
                utf8: b"c",
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x03");
    }

    #[test]
    fn legacy_ctrl_space() {
        // ghostty: "legacy: ctrl+space" (key_encode.zig:2082)
        let actual = legacy(
            KeyEvent {
                key: Key::Space,
                mods: m(false, true, false, false),
                utf8: b" ",
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x00");
    }

    #[test]
    fn legacy_ctrl_shift_backspace() {
        // ghostty: "legacy: ctrl+shift+backspace" (key_encode.zig:2093)
        let actual = legacy(
            KeyEvent {
                key: Key::Backspace,
                mods: m(true, true, false, false),
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x08");
    }

    #[test]
    fn legacy_backspace_decbkm_reset() {
        // ghostty: "legacy: backspace (DECBKM reset)" (key_encode.zig:2103)
        assert_eq!(legacy(event(Key::Backspace), Options::default()), b"\x7f");
    }

    #[test]
    fn legacy_backspace_decbkm_reset_with_ctrl() {
        // ghostty: "legacy: backspace (DECBKM reset, with ctrl)" (key_encode.zig:2113)
        let actual = legacy(
            KeyEvent {
                key: Key::Backspace,
                mods: m(false, true, false, false),
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x08");
    }

    #[test]
    fn legacy_backspace_decbkm_set() {
        // ghostty: "legacy: backspace (DECBKM set)" (key_encode.zig:2125)
        let actual = legacy(
            event(Key::Backspace),
            Options {
                backarrow_key_mode: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x08");
    }

    #[test]
    fn legacy_backspace_decbkm_set_with_ctrl() {
        // ghostty: "legacy: backspace (DECBKM set, with ctrl)" (key_encode.zig:2135)
        let actual = legacy(
            KeyEvent {
                key: Key::Backspace,
                mods: m(false, true, false, false),
                ..KeyEvent::default()
            },
            Options {
                backarrow_key_mode: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x7f");
    }

    #[test]
    fn legacy_ctrl_shift_char_with_modify_other_state_2() {
        // ghostty: "legacy: ctrl+shift+char with modify other state 2" (key_encode.zig:2147)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyH,
                mods: m(true, true, false, false),
                utf8: b"H",
                ..KeyEvent::default()
            },
            Options {
                modify_other_keys_state_2: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1b[27;6;72~");
    }

    #[test]
    fn legacy_ctrl_shift_char_with_modify_other_state_2_and_consumed_mods() {
        // ghostty: "legacy: ctrl+shift+char with modify other state 2 and consumed mods" (key_encode.zig:2160)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyH,
                mods: m(true, true, false, false),
                consumed_mods: Mods {
                    shift: true,
                    ..Mods::none()
                },
                utf8: b"H",
                ..KeyEvent::default()
            },
            Options {
                modify_other_keys_state_2: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1b[27;6;72~");
    }

    #[test]
    fn legacy_alt_digit_with_modify_other_state_2() {
        // ghostty: "legacy: alt+digit with modify other state 2" (key_encode.zig:2174)
        let actual = legacy(
            KeyEvent {
                key: Key::Digit8,
                mods: m(false, false, true, false),
                utf8: b"8",
                ..KeyEvent::default()
            },
            Options {
                modify_other_keys_state_2: true,
                macos_option_as_alt: OptionAsAlt::True,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1b[27;3;56~");
    }

    #[test]
    fn legacy_alt_digit_with_modify_other_state_2_and_macos_option_false() {
        // ghostty: "legacy: alt+digit with modify other state 2 and macos-option-as-alt = false" (key_encode.zig:2189)
        let actual = legacy(
            KeyEvent {
                key: Key::Digit8,
                mods: m(false, false, true, false),
                consumed_mods: Mods {
                    alt: true,
                    ..Mods::none()
                },
                utf8: b"[",
                ..KeyEvent::default()
            },
            Options {
                modify_other_keys_state_2: true,
                macos_option_as_alt: OptionAsAlt::False,
                is_macos: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"[");
    }

    #[test]
    fn legacy_fixterm_awkward_letters() {
        // ghostty: "legacy: fixterm awkward letters" (key_encode.zig:2205)
        assert_eq!(
            legacy(
                KeyEvent {
                    key: Key::KeyI,
                    mods: m(false, true, false, false),
                    utf8: b"i",
                    ..KeyEvent::default()
                },
                Options::default()
            ),
            b"\x1b[105;5u"
        );
        assert_eq!(
            legacy(
                KeyEvent {
                    key: Key::KeyM,
                    mods: m(false, true, false, false),
                    utf8: b"m",
                    ..KeyEvent::default()
                },
                Options::default()
            ),
            b"\x1b[109;5u"
        );
        assert_eq!(
            legacy(
                KeyEvent {
                    key: Key::BracketLeft,
                    mods: m(false, true, false, false),
                    utf8: b"[",
                    ..KeyEvent::default()
                },
                Options::default()
            ),
            b"\x1b[91;5u"
        );
        assert_eq!(
            legacy(
                KeyEvent {
                    key: Key::Digit2,
                    mods: m(true, true, false, false),
                    utf8: b"@",
                    unshifted_codepoint: '2' as u32,
                    ..KeyEvent::default()
                },
                Options::default()
            ),
            b"\x1b[64;5u"
        );
    }

    #[test]
    fn legacy_ctrl_shift_letter_ascii() {
        // ghostty: "legacy: ctrl+shift+letter ascii" (key_encode.zig:2248)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyM,
                mods: m(true, true, false, false),
                utf8: b"M",
                unshifted_codepoint: 'm' as u32,
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x1b[109;6u");
    }

    #[test]
    fn legacy_shift_function_key_should_use_all_mods() {
        // ghostty: "legacy: shift+function key should use all mods" (key_encode.zig:2262)
        let actual = legacy(
            KeyEvent {
                key: Key::ArrowUp,
                mods: m(true, false, false, false),
                consumed_mods: Mods {
                    shift: true,
                    ..Mods::none()
                },
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x1b[1;2A");
    }

    #[test]
    fn legacy_keypad_enter() {
        // ghostty: "legacy: keypad enter" (key_encode.zig:2273)
        assert_eq!(legacy(event(Key::NumpadEnter), Options::default()), b"\r");
    }

    #[test]
    fn legacy_keypad_1() {
        // ghostty: "legacy: keypad 1" (key_encode.zig:2284)
        assert_eq!(
            legacy(text_event(Key::Numpad1, b"1"), Options::default()),
            b"1"
        );
    }

    #[test]
    fn legacy_keypad_1_with_application_keypad() {
        // ghostty: "legacy: keypad 1 with application keypad" (key_encode.zig:2296)
        let actual = legacy(
            text_event(Key::Numpad1, b"1"),
            Options {
                keypad_key_application: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1bOq");
    }

    #[test]
    fn legacy_keypad_1_with_application_keypad_and_numlock() {
        // ghostty: "legacy: keypad 1 with application keypad and numlock" (key_encode.zig:2310)
        let actual = legacy(
            KeyEvent {
                key: Key::Numpad1,
                mods: Mods {
                    num_lock: true,
                    ..Mods::none()
                },
                utf8: b"1",
                ..KeyEvent::default()
            },
            Options {
                keypad_key_application: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x1bOq");
    }

    #[test]
    fn legacy_keypad_1_with_application_keypad_and_numlock_ignore() {
        // ghostty: "legacy: keypad 1 with application keypad and numlock ignore" (key_encode.zig:2324)
        let actual = legacy(
            text_event(Key::Numpad1, b"1"),
            Options {
                keypad_key_application: true,
                ignore_keypad_with_numlock: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"1");
    }

    #[test]
    fn legacy_f1_family_ctrl_sequences() {
        // ghostty: "legacy: f1" (key_encode.zig:2339)
        for (key, expected) in [
            (Key::F1, b"\x1b[1;5P".as_slice()),
            (Key::F2, b"\x1b[1;5Q".as_slice()),
            (Key::F3, b"\x1b[13;5~".as_slice()),
            (Key::F4, b"\x1b[1;5S".as_slice()),
            (Key::F5, b"\x1b[15;5~".as_slice()),
        ] {
            let actual = legacy(
                KeyEvent {
                    key,
                    mods: m(false, true, false, false),
                    ..KeyEvent::default()
                },
                Options::default(),
            );
            assert_eq!(actual, expected);
        }
    }

    #[test]
    fn legacy_left_shift_tab() {
        // ghostty: "legacy: left_shift+tab" (key_encode.zig:2398)
        let actual = legacy(
            KeyEvent {
                key: Key::Tab,
                mods: Mods {
                    shift: true,
                    sides: ModifierSides {
                        shift: Side::Left,
                        ..ModifierSides::default()
                    },
                    ..Mods::none()
                },
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x1b[Z");
    }

    #[test]
    fn legacy_right_shift_tab() {
        // ghostty: "legacy: right_shift+tab" (key_encode.zig:2411)
        let actual = legacy(
            KeyEvent {
                key: Key::Tab,
                mods: Mods {
                    shift: true,
                    sides: ModifierSides {
                        shift: Side::Right,
                        ..ModifierSides::default()
                    },
                    ..Mods::none()
                },
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x1b[Z");
    }

    #[test]
    fn legacy_hu_layout_ctrl_o_double_acute_sends_proper_codepoint() {
        // ghostty: "legacy: hu layout ctrl+ő sends proper codepoint" (key_encode.zig:2424)
        let actual = legacy(
            KeyEvent {
                key: Key::BracketLeft,
                mods: m(false, true, false, false),
                utf8: "ő".as_bytes(),
                unshifted_codepoint: 337,
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(s(&actual), "\u{1b}[337;5u");
    }

    #[test]
    fn legacy_super_only_on_macos_with_text() {
        // ghostty: "legacy: super-only on macOS with text" (key_encode.zig:2437)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyB,
                mods: m(false, false, false, true),
                utf8: b"b",
                ..KeyEvent::default()
            },
            Options {
                is_macos: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"");
    }

    #[test]
    fn legacy_super_and_other_mods_on_macos_with_text() {
        // ghostty: "legacy: super and other mods on macOS with text" (key_encode.zig:2450)
        let actual = legacy(
            KeyEvent {
                key: Key::KeyB,
                mods: m(true, false, false, true),
                utf8: b"B",
                ..KeyEvent::default()
            },
            Options {
                is_macos: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"");
    }

    #[test]
    fn legacy_backspace_with_del_utf8_decbkm_reset() {
        // ghostty: "legacy: backspace with DEL utf8 (DECBKM reset)" (key_encode.zig:2463)
        let actual = legacy(
            KeyEvent {
                key: Key::Backspace,
                utf8: b"\x7f",
                unshifted_codepoint: 0x08,
                ..KeyEvent::default()
            },
            Options::default(),
        );
        assert_eq!(actual, b"\x7f");
    }

    #[test]
    fn legacy_backspace_with_del_utf8_decbkm_set() {
        // ghostty: "legacy: backspace with DEL utf8 (DECBKM set)" (key_encode.zig:2474)
        let actual = legacy(
            KeyEvent {
                key: Key::Backspace,
                utf8: b"\x7f",
                unshifted_codepoint: 0x08,
                ..KeyEvent::default()
            },
            Options {
                backarrow_key_mode: true,
                ..Options::default()
            },
        );
        assert_eq!(actual, b"\x08");
    }

    #[test]
    fn ctrlseq_normal_ctrl_c() {
        // ghostty: "ctrlseq: normal ctrl c" (key_encode.zig:2485)
        assert_eq!(
            ctrl_seq(
                Key::Unidentified,
                b"c",
                'c' as u32,
                m(false, true, false, false)
            ),
            Some(0x03)
        );
    }

    #[test]
    fn ctrlseq_normal_ctrl_c_right_control() {
        // ghostty: "ctrlseq: normal ctrl c, right control" (key_encode.zig:2490)
        assert_eq!(
            ctrl_seq(
                Key::Unidentified,
                b"c",
                'c' as u32,
                Mods {
                    ctrl: true,
                    sides: ModifierSides {
                        ctrl: Side::Right,
                        ..ModifierSides::default()
                    },
                    ..Mods::none()
                }
            ),
            Some(0x03)
        );
    }

    #[test]
    fn ctrlseq_alt_should_be_allowed() {
        // ghostty: "ctrlseq: alt should be allowed" (key_encode.zig:2495)
        assert_eq!(
            ctrl_seq(
                Key::Unidentified,
                b"c",
                'c' as u32,
                m(false, true, true, false)
            ),
            Some(0x03)
        );
    }

    #[test]
    fn ctrlseq_no_ctrl_does_nothing() {
        // ghostty: "ctrlseq: no ctrl does nothing" (key_encode.zig:2500)
        assert_eq!(
            ctrl_seq(Key::Unidentified, b"c", 'c' as u32, Mods::none()),
            None
        );
    }

    #[test]
    fn ctrlseq_shifted_non_character() {
        // ghostty: "ctrlseq: shifted non-character" (key_encode.zig:2504)
        assert_eq!(
            ctrl_seq(
                Key::Unidentified,
                b"_",
                '-' as u32,
                m(true, true, false, false)
            ),
            Some(0x1f)
        );
    }

    #[test]
    fn ctrlseq_caps_ascii_letter() {
        // ghostty: "ctrlseq: caps ascii letter" (key_encode.zig:2509)
        assert_eq!(
            ctrl_seq(
                Key::Unidentified,
                b"C",
                'c' as u32,
                Mods {
                    ctrl: true,
                    caps_lock: true,
                    ..Mods::none()
                }
            ),
            Some(0x03)
        );
    }

    #[test]
    fn ctrlseq_shift_does_not_generate_ctrl_seq() {
        // ghostty: "ctrlseq: shift does not generate ctrl seq" (key_encode.zig:2514)
        assert_eq!(
            ctrl_seq(
                Key::Unidentified,
                b"C",
                'c' as u32,
                m(true, false, false, false)
            ),
            None
        );
        assert_eq!(
            ctrl_seq(
                Key::Unidentified,
                b"C",
                'c' as u32,
                m(true, true, false, false)
            ),
            None
        );
    }

    #[test]
    fn ctrlseq_russian_ctrl_c() {
        // ghostty: "ctrlseq: russian ctrl c" (key_encode.zig:2519)
        assert_eq!(
            ctrl_seq(
                Key::KeyC,
                "с".as_bytes(),
                0x0441,
                m(false, true, false, false)
            ),
            Some(0x03)
        );
    }

    #[test]
    fn ctrlseq_russian_shifted_ctrl_c() {
        // ghostty: "ctrlseq: russian shifted ctrl c" (key_encode.zig:2524)
        assert_eq!(
            ctrl_seq(
                Key::KeyC,
                "с".as_bytes(),
                0x0441,
                m(true, true, false, false)
            ),
            None
        );
    }

    #[test]
    fn ctrlseq_russian_alt_ctrl_c() {
        // ghostty: "ctrlseq: russian alt ctrl c" (key_encode.zig:2529)
        assert_eq!(
            ctrl_seq(
                Key::KeyC,
                "с".as_bytes(),
                0x0441,
                m(false, true, true, false)
            ),
            Some(0x03)
        );
    }

    #[test]
    fn ctrlseq_right_ctrl_c() {
        // ghostty: "ctrlseq: right ctrl c" (key_encode.zig:2534)
        assert_eq!(
            ctrl_seq(
                Key::KeyC,
                "с".as_bytes(),
                'c' as u32,
                Mods {
                    ctrl: true,
                    sides: ModifierSides {
                        ctrl: Side::Right,
                        ..ModifierSides::default()
                    },
                    ..Mods::none()
                }
            ),
            Some(0x03)
        );
    }
}
