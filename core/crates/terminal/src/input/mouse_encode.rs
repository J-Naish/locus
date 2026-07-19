//! Terminal mouse report encoding.
//!
//! This is the cell-coordinate subset of Ghostty's
//! `input/mouse_encode.zig`. Surface pixel conversion remains a platform
//! responsibility until the UI forwards pixel coordinates.

use super::Mods;
use crate::terminal::{MouseEvent as ReportingMode, MouseFormat};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Press,
    Release,
    Motion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    Left,
    Middle,
    Right,
    Four,
    Five,
    Six,
    Seven,
    Eight,
    Nine,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Event {
    pub action: Action,
    pub button: Option<Button>,
    pub mods: Mods,
    pub x: u16,
    pub y: u16,
}

pub fn encode(event: Event, mode: ReportingMode, format: MouseFormat) -> Vec<u8> {
    if !should_report(event, mode) {
        return Vec::new();
    }
    let Some(button_code) = button_code(event, mode, format) else {
        return Vec::new();
    };
    match format {
        MouseFormat::X10 => encode_x10(button_code, event.x, event.y),
        MouseFormat::Utf8 => encode_utf8(button_code, event.x, event.y),
        MouseFormat::Sgr => format!(
            "\x1b[<{button_code};{};{}{}",
            u32::from(event.x) + 1,
            u32::from(event.y) + 1,
            if event.action == Action::Release {
                'm'
            } else {
                'M'
            }
        )
        .into_bytes(),
        MouseFormat::Urxvt => format!(
            "\x1b[{};{};{}M",
            32 + u16::from(button_code),
            u32::from(event.x) + 1,
            u32::from(event.y) + 1
        )
        .into_bytes(),
        // The current ABI supplies cells rather than surface pixels. Preserve
        // SGR syntax and one-based coordinates until pixel positions are added.
        MouseFormat::SgrPixels => format!(
            "\x1b[<{button_code};{};{}{}",
            u32::from(event.x) + 1,
            u32::from(event.y) + 1,
            if event.action == Action::Release {
                'm'
            } else {
                'M'
            }
        )
        .into_bytes(),
    }
}

fn should_report(event: Event, mode: ReportingMode) -> bool {
    // ghostty: input/mouse_encode.zig:178-198
    match mode {
        ReportingMode::None => false,
        ReportingMode::X10 => {
            event.action == Action::Press
                && matches!(
                    event.button,
                    Some(Button::Left | Button::Middle | Button::Right)
                )
        }
        ReportingMode::Normal => event.action != Action::Motion,
        ReportingMode::Button => event.button.is_some(),
        ReportingMode::Any => true,
    }
}

fn button_code(event: Event, mode: ReportingMode, format: MouseFormat) -> Option<u8> {
    // ghostty: input/mouse_encode.zig:200-238
    let legacy_release = event.action == Action::Release
        && !matches!(format, MouseFormat::Sgr | MouseFormat::SgrPixels);
    let mut code = if event.button.is_none() || legacy_release {
        3
    } else {
        match event.button? {
            Button::Left => 0,
            Button::Middle => 1,
            Button::Right => 2,
            Button::Four => 64,
            Button::Five => 65,
            Button::Six => 66,
            Button::Seven => 67,
            Button::Eight => 128,
            Button::Nine => 129,
        }
    };
    if mode != ReportingMode::X10 {
        if event.mods.shift {
            code += 4;
        }
        if event.mods.alt {
            code += 8;
        }
        if event.mods.ctrl {
            code += 16;
        }
    }
    if event.action == Action::Motion {
        code += 32;
    }
    Some(code)
}

fn encode_x10(button_code: u8, x: u16, y: u16) -> Vec<u8> {
    // ghostty: input/mouse_encode.zig:108-128
    if x > 222 || y > 222 {
        return Vec::new();
    }
    vec![
        0x1b,
        b'[',
        b'M',
        32 + button_code,
        33 + x as u8,
        33 + y as u8,
    ]
}

fn encode_utf8(button_code: u8, x: u16, y: u16) -> Vec<u8> {
    // ghostty: input/mouse_encode.zig:130-147
    let mut output = vec![0x1b, b'[', b'M', 32 + button_code];
    for codepoint in [u32::from(x) + 33, u32::from(y) + 33] {
        if let Some(value) = char::from_u32(codepoint) {
            let mut buffer = [0; 4];
            output.extend_from_slice(value.encode_utf8(&mut buffer).as_bytes());
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(action: Action, button: Option<Button>) -> Event {
        Event {
            action,
            button,
            mods: Mods::none(),
            x: 4,
            y: 5,
        }
    }

    #[test]
    fn none_mode_never_reports() {
        // ghostty: "shouldReport: none mode never reports" (mouse_encode.zig:291)
        assert!(encode(
            event(Action::Press, Some(Button::Left)),
            ReportingMode::None,
            MouseFormat::Sgr
        )
        .is_empty());
    }

    #[test]
    fn x10_reports_only_basic_button_presses() {
        // ghostty: "shouldReport: x10 reports only left/middle/right press" (mouse_encode.zig:301)
        assert_eq!(
            encode(
                Event {
                    x: 0,
                    y: 0,
                    ..event(Action::Press, Some(Button::Left))
                },
                ReportingMode::X10,
                MouseFormat::X10
            ),
            [0x1b, b'[', b'M', 32, 33, 33]
        );
        assert!(encode(
            event(Action::Release, Some(Button::Left)),
            ReportingMode::X10,
            MouseFormat::X10
        )
        .is_empty());
    }

    #[test]
    fn normal_mode_filters_motion() {
        // ghostty: "normal ignores motion" (mouse_encode.zig:414)
        assert!(encode(
            event(Action::Motion, Some(Button::Left)),
            ReportingMode::Normal,
            MouseFormat::Sgr
        )
        .is_empty());
    }

    #[test]
    fn button_mode_requires_button_for_motion() {
        // ghostty: "button mode requires button" (mouse_encode.zig:430)
        assert!(encode(
            event(Action::Motion, None),
            ReportingMode::Button,
            MouseFormat::Sgr
        )
        .is_empty());
        assert!(!encode(
            event(Action::Motion, Some(Button::Left)),
            ReportingMode::Button,
            MouseFormat::Sgr
        )
        .is_empty());
    }

    #[test]
    fn sgr_release_preserves_button_identity() {
        // ghostty: "sgr release keeps button identity" (mouse_encode.zig:447)
        assert_eq!(
            encode(
                event(Action::Release, Some(Button::Right)),
                ReportingMode::Any,
                MouseFormat::Sgr
            ),
            b"\x1b[<2;5;6m"
        );
    }

    #[test]
    fn sgr_motion_without_button_uses_motion_code() {
        // ghostty: "sgr motion with no button" (mouse_encode.zig:466)
        assert_eq!(
            encode(
                Event {
                    x: 1,
                    y: 2,
                    ..event(Action::Motion, None)
                },
                ReportingMode::Any,
                MouseFormat::Sgr
            ),
            b"\x1b[<35;2;3M"
        );
    }

    #[test]
    fn urxvt_includes_modifiers() {
        // ghostty: "urxvt with modifiers" (mouse_encode.zig:485)
        let mut value = event(Action::Press, Some(Button::Left));
        value.x = 2;
        value.y = 3;
        value.mods = Mods {
            shift: true,
            alt: true,
            ctrl: true,
            ..Mods::none()
        };
        assert_eq!(
            encode(value, ReportingMode::Any, MouseFormat::Urxvt),
            b"\x1b[60;3;4M"
        );
    }

    #[test]
    fn sgr_wheel_buttons_use_protocol_codes() {
        // ghostty: "sgr wheel button mappings" (mouse_encode.zig:549)
        assert_eq!(
            encode(
                Event {
                    x: 0,
                    y: 0,
                    ..event(Action::Press, Some(Button::Four))
                },
                ReportingMode::Any,
                MouseFormat::Sgr
            ),
            b"\x1b[<64;1;1M"
        );
        assert_eq!(
            encode(
                Event {
                    x: 0,
                    y: 0,
                    ..event(Action::Press, Some(Button::Five))
                },
                ReportingMode::Any,
                MouseFormat::Sgr
            ),
            b"\x1b[<65;1;1M"
        );
    }
}
