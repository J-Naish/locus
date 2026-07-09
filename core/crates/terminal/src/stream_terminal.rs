//! Terminal-backed stream handler with explicit side effects.
//!
//! Ghostty's `stream_terminal.zig` couples parser actions to terminal state and
//! PTY write-backs. In Rust the parser remains generic over [`Handler`], while
//! this adapter owns terminal state and records side effects through a small
//! trait so the core stays pure logic.

use std::fmt::Write as _;

use crate::color::{Dynamic, DynamicRgb, Rgb};
use crate::device_attributes::{self, Attributes};
use crate::device_status::{self, ColorScheme};
use crate::modes::{Mode, ModeTag};
use crate::osc::{
    ColorOperationKind, ColorRequest, ColorTarget, KittyColorKind, KittyColorRequest, KittySpecial,
    Terminator,
};
use crate::screen::CursorStyle as ScreenCursorStyle;
use crate::size_report::{self, Size};
use crate::stream::{
    CursorStyle, EraseDisplay, EraseLine, Handler, ProtectedMode, SizeReportStyle,
};
use crate::terminal::{DeccolmMode, MouseEvent, MouseFormat, SwitchScreenMode, Terminal};

pub trait Effects {
    fn write_pty(&mut self, _bytes: &[u8]) {}
    fn bell(&mut self) {}
    fn enquiry(&mut self) -> Option<Vec<u8>> {
        None
    }
    fn color_scheme(&mut self) -> Option<ColorScheme> {
        None
    }
    fn device_attributes(&mut self) -> Option<Attributes> {
        None
    }
    fn size(&mut self) -> Option<Size> {
        None
    }
    fn xtversion(&mut self) -> Option<String> {
        None
    }
    fn title_changed(&mut self, _title: Option<&str>) {}
    fn pwd_changed(&mut self, _pwd: Option<&str>) {}
    fn mouse_shape_changed(&mut self, _shape: Option<&str>) {}
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct CapturedEffects {
    pub pty: Vec<u8>,
    pub bell_count: usize,
    pub enquiry_response: Option<Vec<u8>>,
    pub color_scheme_response: Option<ColorScheme>,
    pub device_attributes_response: Option<Attributes>,
    pub size_response: Option<Size>,
    pub xtversion_response: Option<String>,
    pub titles: Vec<Option<String>>,
    pub pwds: Vec<Option<String>>,
    pub mouse_shapes: Vec<Option<String>>,
}

impl Effects for CapturedEffects {
    fn write_pty(&mut self, bytes: &[u8]) {
        self.pty.extend_from_slice(bytes);
    }

    fn bell(&mut self) {
        self.bell_count += 1;
    }

    fn enquiry(&mut self) -> Option<Vec<u8>> {
        self.enquiry_response.clone()
    }

    fn color_scheme(&mut self) -> Option<ColorScheme> {
        self.color_scheme_response
    }

    fn device_attributes(&mut self) -> Option<Attributes> {
        self.device_attributes_response.clone()
    }

    fn size(&mut self) -> Option<Size> {
        self.size_response
    }

    fn xtversion(&mut self) -> Option<String> {
        self.xtversion_response.clone()
    }

    fn title_changed(&mut self, title: Option<&str>) {
        self.titles.push(title.map(ToOwned::to_owned));
    }

    fn pwd_changed(&mut self, pwd: Option<&str>) {
        self.pwds.push(pwd.map(ToOwned::to_owned));
    }

    fn mouse_shape_changed(&mut self, shape: Option<&str>) {
        self.mouse_shapes.push(shape.map(ToOwned::to_owned));
    }
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct NoopEffects;

impl Effects for NoopEffects {}

#[derive(Debug, Clone)]
pub struct TerminalHandler<E> {
    pub terminal: Terminal,
    pub effects: E,
}

impl<E: Effects> TerminalHandler<E> {
    pub fn new(terminal: Terminal, effects: E) -> Self {
        Self { terminal, effects }
    }

    pub fn into_parts(self) -> (Terminal, E) {
        (self.terminal, self.effects)
    }

    fn write_response(&mut self, response: &str) {
        self.effects.write_pty(response.as_bytes());
    }

    fn write_mode_report(&mut self, tag: ModeTag) {
        let report = self.terminal.modes.get_report(tag);
        let mut output = String::with_capacity(crate::modes::Report::MAX_SIZE);
        if report.encode(&mut output).is_ok() {
            self.write_response(&output);
        }
    }

    fn write_device_attributes(&mut self, req: device_attributes::Req) {
        let attributes = self.effects.device_attributes().unwrap_or_default();
        let mut output = String::new();
        if attributes.encode(req, &mut output).is_ok() {
            self.write_response(&output);
        }
    }

    fn write_cursor_status(&mut self) {
        let cursor = &self.terminal.active_screen().cursor;
        let mut x = cursor.x;
        let mut y = cursor.y;
        if self.terminal.modes.get(Mode::Origin) {
            x = x.saturating_sub(self.terminal.scrolling_region.left);
            y = y.saturating_sub(self.terminal.scrolling_region.top);
        }
        let mut output = String::new();
        let _ = write!(
            output,
            "\x1B[{};{}R",
            y.saturating_add(1),
            x.saturating_add(1)
        );
        self.write_response(&output);
    }

    fn handle_color_request(&mut self, request: ColorRequest, terminator: Terminator) {
        match request {
            ColorRequest::Set { target, color } => {
                if self.set_color_target(target, color) {
                    self.terminal.dirty.palette = true;
                }
            }
            ColorRequest::Query(target) => self.write_color_query(target, terminator),
            ColorRequest::Reset(target) => {
                if self.reset_color_target(target) {
                    self.terminal.dirty.palette = true;
                }
            }
            ColorRequest::ResetPalette => {
                self.terminal.colors.palette.reset_all();
                self.terminal.dirty.palette = true;
            }
            ColorRequest::ResetSpecial => {}
        }
    }

    fn handle_kitty_color_request(&mut self, request: KittyColorRequest, terminator: Terminator) {
        match request {
            KittyColorRequest::Set { key, color } => {
                if self.set_kitty_color(key, color) {
                    self.terminal.dirty.palette = true;
                }
            }
            KittyColorRequest::Query(key) => self.write_kitty_color_query(key, terminator),
            KittyColorRequest::Reset(key) => {
                if self.reset_kitty_color(key) {
                    self.terminal.dirty.palette = true;
                }
            }
        }
    }

    fn set_color_target(&mut self, target: ColorTarget, color: Rgb) -> bool {
        match target {
            ColorTarget::Palette(index) => {
                self.terminal.colors.palette.set(index, color);
                true
            }
            ColorTarget::Dynamic(dynamic) => {
                if let Some(slot) = dynamic_rgb_mut(&mut self.terminal, dynamic) {
                    slot.set(color);
                    true
                } else {
                    false
                }
            }
            ColorTarget::Special(_) => false,
        }
    }

    fn reset_color_target(&mut self, target: ColorTarget) -> bool {
        match target {
            ColorTarget::Palette(index) => {
                self.terminal.colors.palette.reset(index);
                true
            }
            ColorTarget::Dynamic(dynamic) => {
                if let Some(slot) = dynamic_rgb_mut(&mut self.terminal, dynamic) {
                    slot.reset();
                    true
                } else {
                    false
                }
            }
            ColorTarget::Special(_) => false,
        }
    }

    fn set_kitty_color(&mut self, key: KittyColorKind, color: Rgb) -> bool {
        match key {
            KittyColorKind::Palette(index) => {
                self.terminal.colors.palette.set(index, color);
                true
            }
            KittyColorKind::Special(special) => {
                if let Some(slot) = kitty_special_mut(&mut self.terminal, special) {
                    slot.set(color);
                    true
                } else {
                    false
                }
            }
        }
    }

    fn reset_kitty_color(&mut self, key: KittyColorKind) -> bool {
        match key {
            KittyColorKind::Palette(index) => {
                self.terminal.colors.palette.reset(index);
                true
            }
            KittyColorKind::Special(special) => {
                if let Some(slot) = kitty_special_mut(&mut self.terminal, special) {
                    slot.reset();
                    true
                } else {
                    false
                }
            }
        }
    }

    fn write_color_query(&mut self, target: ColorTarget, terminator: Terminator) {
        let (prefix, color) = match target {
            ColorTarget::Palette(index) => (
                format!("4;{index}"),
                Some(self.terminal.colors.palette.current[usize::from(index)]),
            ),
            ColorTarget::Special(_) => return,
            ColorTarget::Dynamic(dynamic) => (
                (dynamic as u8).to_string(),
                dynamic_rgb(&self.terminal, dynamic).and_then(DynamicRgb::get),
            ),
        };
        if let Some(color) = color {
            let response = format!(
                "\x1B]{prefix};{}{}",
                rgb_response(color),
                terminator.string()
            );
            self.write_response(&response);
        }
    }

    fn write_kitty_color_query(&mut self, key: KittyColorKind, terminator: Terminator) {
        let color = match key {
            KittyColorKind::Palette(index) => {
                Some(self.terminal.colors.palette.current[usize::from(index)])
            }
            KittyColorKind::Special(special) => {
                kitty_special(&self.terminal, special).and_then(DynamicRgb::get)
            }
        };
        if let Some(color) = color {
            let response = format!(
                "\x1B]21;{key}={}{}",
                rgb_response(color),
                terminator.string()
            );
            self.write_response(&response);
        }
    }
}

impl<E: Effects> Handler for TerminalHandler<E> {
    fn print(&mut self, cp: char) {
        self.terminal.print(cp);
    }

    fn print_repeat(&mut self, count: usize) {
        self.terminal.print_repeat(count);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            b'\n' | 0x0B | 0x0C => self.terminal.linefeed(),
            b'\r' => self.terminal.carriage_return(),
            0x08 => self.terminal.backspace(),
            b'\t' => self.terminal.horizontal_tab(),
            0x05 => {
                if let Some(response) = self.effects.enquiry() {
                    self.effects.write_pty(&response);
                }
            }
            0x07 => self.effects.bell(),
            // ghostty: stream.zig:776 (SO — locking shift G1 into GL)
            0x0E => self.terminal.invoke_charset(
                crate::charsets::ActiveSlot::Gl,
                crate::charsets::Slots::G1,
                false,
            ),
            // ghostty: stream.zig:777 (SI — locking shift G0 into GL)
            0x0F => self.terminal.invoke_charset(
                crate::charsets::ActiveSlot::Gl,
                crate::charsets::Slots::G0,
                false,
            ),
            _ => {}
        }
    }

    fn index(&mut self) {
        self.terminal.index();
    }

    fn reverse_index(&mut self) {
        self.terminal.reverse_index();
    }

    fn next_line(&mut self) {
        self.terminal.next_line();
    }

    fn cursor_up(&mut self, value: u16) {
        self.terminal.cursor_up(usize::from(value));
    }

    fn cursor_down(&mut self, value: u16) {
        self.terminal.cursor_down(usize::from(value));
    }

    fn cursor_right(&mut self, value: u16) {
        self.terminal.cursor_right(usize::from(value));
    }

    fn cursor_left(&mut self, value: u16) {
        self.terminal.cursor_left(usize::from(value));
    }

    fn cursor_col(&mut self, col: u16) {
        let row = self.terminal.active_screen().cursor.y.saturating_add(1);
        self.terminal.set_cursor_pos(row, col);
    }

    fn cursor_row(&mut self, row: u16) {
        let col = self.terminal.active_screen().cursor.x.saturating_add(1);
        self.terminal.set_cursor_pos(row, col);
    }

    fn cursor_col_relative(&mut self, value: u16) {
        // ghostty: termio/stream_handler.zig:233 — HPR routes through
        // setCursorPos rather than CUF.
        let row = self.terminal.active_screen().cursor.y.saturating_add(1);
        let col = self
            .terminal
            .active_screen()
            .cursor
            .x
            .saturating_add(1)
            .saturating_add(value);
        self.terminal.set_cursor_pos(row, col);
    }

    fn cursor_row_relative(&mut self, value: u16) {
        // ghostty: termio/stream_handler.zig:237 — VPR routes through
        // setCursorPos rather than CUD.
        let row = self
            .terminal
            .active_screen()
            .cursor
            .y
            .saturating_add(1)
            .saturating_add(value);
        let col = self.terminal.active_screen().cursor.x.saturating_add(1);
        self.terminal.set_cursor_pos(row, col);
    }

    fn cursor_position(&mut self, row: u16, col: u16) {
        self.terminal.set_cursor_pos(row, col);
    }

    fn insert_blanks(&mut self, value: usize) {
        self.terminal.insert_blanks(value);
    }

    fn delete_chars(&mut self, value: usize) {
        self.terminal.delete_chars(value);
    }

    fn erase_chars(&mut self, value: usize) {
        self.terminal.erase_chars(value);
    }

    fn insert_lines(&mut self, value: usize) {
        self.terminal.insert_lines(value);
    }

    fn delete_lines(&mut self, value: usize) {
        self.terminal.delete_lines(value);
    }

    fn scroll_up(&mut self, value: usize) {
        self.terminal.scroll_up(value);
    }

    fn scroll_down(&mut self, value: usize) {
        self.terminal.scroll_down(value);
    }

    fn erase_display(&mut self, mode: EraseDisplay, protected: bool) {
        self.terminal.erase_display(mode, protected);
    }

    fn erase_line(&mut self, mode: EraseLine, protected: bool) {
        self.terminal.erase_line(mode, protected);
    }

    fn set_attribute(&mut self, attribute: crate::sgr::Attribute<'_>) {
        self.terminal.active_screen_mut().set_attribute(attribute);
    }

    fn set_mode(&mut self, mode: Mode) {
        self.terminal.set_mode(mode);
        apply_mode_side_effects(&mut self.terminal, mode, true);
        update_mouse_flags(&mut self.terminal, mode, true);
    }

    fn reset_mode(&mut self, mode: Mode) {
        self.terminal.reset_mode(mode);
        apply_mode_side_effects(&mut self.terminal, mode, false);
        update_mouse_flags(&mut self.terminal, mode, false);
    }

    fn save_mode(&mut self, mode: Mode) {
        self.terminal.modes.save(mode);
    }

    fn restore_mode(&mut self, mode: Mode) {
        let enabled = self.terminal.modes.restore(mode);
        apply_mode_side_effects(&mut self.terminal, mode, enabled);
        update_mouse_flags(&mut self.terminal, mode, enabled);
    }

    fn request_mode_report(&mut self, tag: ModeTag) {
        self.write_mode_report(tag);
    }

    fn protected_mode(&mut self, mode: ProtectedMode) {
        self.terminal.set_protected_mode(mode);
    }

    fn cursor_style(&mut self, style: CursorStyle) {
        self.terminal.active_screen_mut().cursor.cursor_style = match style {
            CursorStyle::Default | CursorStyle::BlinkingBlock | CursorStyle::SteadyBlock => {
                ScreenCursorStyle::Block
            }
            CursorStyle::BlinkingUnderline | CursorStyle::SteadyUnderline => {
                ScreenCursorStyle::Underline
            }
            CursorStyle::BlinkingBar | CursorStyle::SteadyBar => ScreenCursorStyle::Bar,
        };
    }

    fn mouse_shift_capture(&mut self, enabled: bool) {
        self.terminal.flags.mouse_shift_capture = enabled;
    }

    fn modify_other_keys_2(&mut self, enabled: bool) {
        self.terminal.flags.modify_other_keys_2 = enabled;
    }

    fn kitty_keyboard_pop(&mut self, _count: u16) {
        // Deferred: Phase map marks kitty keyboard stack as out of scope.
    }

    fn left_and_right_margin(&mut self, left: u16, right: u16) {
        self.terminal.set_left_and_right_margin(left, right);
    }

    fn left_and_right_margin_ambiguous(&mut self) {
        // ghostty: termio/stream_handler.zig:283 — DECSLRM when mode 69
        // (enable_left_and_right_margin) is set, SCOSC (save cursor) otherwise.
        if self.terminal.modes.get(Mode::EnableLeftAndRightMargin) {
            self.terminal.set_left_and_right_margin(0, 0);
        } else {
            self.terminal.save_cursor();
        }
    }

    fn top_and_bottom_margin(&mut self, top: u16, bottom: u16) {
        self.terminal.set_top_and_bottom_margin(top, bottom);
    }

    fn restore_cursor(&mut self) {
        self.terminal.restore_cursor();
    }

    fn save_cursor(&mut self) {
        self.terminal.save_cursor();
    }

    fn size_report(&mut self, style: SizeReportStyle) {
        match style {
            SizeReportStyle::Csi21T => {
                let title = self.terminal.title().unwrap_or_default().to_owned();
                let response = format!("\x1B]l{title}\x1B\\");
                self.write_response(&response);
            }
            SizeReportStyle::Csi14T | SizeReportStyle::Csi16T | SizeReportStyle::Csi18T => {
                if let Some(size) = self.effects.size() {
                    let style = match style {
                        SizeReportStyle::Csi14T => size_report::Style::Csi14T,
                        SizeReportStyle::Csi16T => size_report::Style::Csi16T,
                        SizeReportStyle::Csi18T => size_report::Style::Csi18T,
                        SizeReportStyle::Csi21T => return,
                    };
                    let mut output = String::new();
                    if size_report::encode(&mut output, style, size).is_ok() {
                        self.write_response(&output);
                    }
                }
            }
        }
    }

    fn tab_set(&mut self) {
        self.terminal.tab_set();
    }

    fn horizontal_tab(&mut self, count: usize) {
        for _ in 0..count {
            self.terminal.horizontal_tab();
        }
    }

    fn horizontal_tab_back(&mut self, count: usize) {
        self.terminal.horizontal_tab_back(count);
    }

    fn tab_clear_current(&mut self) {
        self.terminal.tab_clear_current();
    }

    fn tab_clear_all(&mut self) {
        self.terminal.tab_clear_all();
    }

    fn tab_reset(&mut self) {
        self.terminal.tab_reset();
    }

    fn configure_charset(
        &mut self,
        slot: crate::charsets::Slots,
        charset: crate::charsets::Charset,
    ) {
        self.terminal.configure_charset(slot, charset);
    }

    fn invoke_charset(
        &mut self,
        active: crate::charsets::ActiveSlot,
        slot: crate::charsets::Slots,
        single: bool,
    ) {
        self.terminal.invoke_charset(active, slot, single);
    }

    fn decaln(&mut self) {
        self.terminal.decaln();
    }

    fn full_reset(&mut self) {
        self.terminal.full_reset();
    }

    fn start_hyperlink(&mut self, id: Option<&[u8]>, uri: &[u8]) {
        self.terminal.active_screen_mut().start_hyperlink(id, uri);
    }

    fn end_hyperlink(&mut self) {
        self.terminal.active_screen_mut().end_hyperlink();
    }

    fn semantic_prompt(&mut self, cmd: crate::osc::SemanticPrompt<'_>) {
        self.terminal.semantic_prompt(cmd);
    }

    fn mouse_shape(&mut self, shape: &[u8]) {
        if let Ok(shape) = std::str::from_utf8(shape) {
            self.terminal.mouse_shape = if shape.is_empty() {
                None
            } else {
                Some(shape.to_owned())
            };
            self.effects
                .mouse_shape_changed(self.terminal.mouse_shape.as_deref());
        }
    }

    fn color_operation(
        &mut self,
        _kind: ColorOperationKind,
        requests: &[ColorRequest],
        terminator: Terminator,
    ) {
        for request in requests {
            self.handle_color_request(*request, terminator);
        }
    }

    fn kitty_color_protocol(&mut self, requests: &[KittyColorRequest], terminator: Terminator) {
        for request in requests {
            self.handle_kitty_color_request(*request, terminator);
        }
    }

    fn report_pwd(&mut self, value: &[u8]) {
        if let Ok(pwd) = std::str::from_utf8(value) {
            self.terminal.set_pwd(pwd);
            self.effects.pwd_changed(self.terminal.pwd());
        }
    }

    fn xtversion(&mut self) {
        let mut version = self
            .effects
            .xtversion()
            .unwrap_or_else(|| "libghostty".to_owned());
        if version.is_empty() {
            version = "libghostty".to_owned();
        }
        let response = format!("\x1BP>|{version}\x1B\\");
        self.write_response(&response);
    }

    fn device_status(&mut self, request: device_status::Request) {
        match request {
            device_status::Request::OperatingStatus => self.write_response("\x1B[0n"),
            device_status::Request::CursorPosition => self.write_cursor_status(),
            device_status::Request::ColorScheme => {
                if let Some(scheme) = self.effects.color_scheme() {
                    let value = match scheme {
                        ColorScheme::Dark => 1,
                        ColorScheme::Light => 2,
                    };
                    let response = format!("\x1B[?997;{value}n");
                    self.write_response(&response);
                }
            }
        }
    }

    fn device_attributes(&mut self, req: device_attributes::Req) {
        self.write_device_attributes(req);
    }

    fn enquiry(&mut self) {
        if let Some(response) = self.effects.enquiry() {
            self.effects.write_pty(&response);
        }
    }

    fn window_title(&mut self, title: &str) {
        self.terminal.set_title(title);
        self.effects.title_changed(self.terminal.title());
    }

    fn window_icon(&mut self, title: &str) {
        self.window_title(title);
    }
}

fn rgb_response(color: Rgb) -> String {
    format!("rgb:{:02x}/{:02x}/{:02x}", color.r, color.g, color.b)
}

fn dynamic_rgb(terminal: &Terminal, dynamic: Dynamic) -> Option<&DynamicRgb> {
    match dynamic {
        Dynamic::Foreground => Some(&terminal.colors.foreground),
        Dynamic::Background => Some(&terminal.colors.background),
        Dynamic::Cursor => Some(&terminal.colors.cursor),
        _ => None,
    }
}

fn dynamic_rgb_mut(terminal: &mut Terminal, dynamic: Dynamic) -> Option<&mut DynamicRgb> {
    match dynamic {
        Dynamic::Foreground => Some(&mut terminal.colors.foreground),
        Dynamic::Background => Some(&mut terminal.colors.background),
        Dynamic::Cursor => Some(&mut terminal.colors.cursor),
        _ => None,
    }
}

fn kitty_special(terminal: &Terminal, special: KittySpecial) -> Option<&DynamicRgb> {
    match special {
        KittySpecial::Foreground => Some(&terminal.colors.foreground),
        KittySpecial::Background => Some(&terminal.colors.background),
        KittySpecial::Cursor => Some(&terminal.colors.cursor),
        _ => None,
    }
}

fn kitty_special_mut(terminal: &mut Terminal, special: KittySpecial) -> Option<&mut DynamicRgb> {
    match special {
        KittySpecial::Foreground => Some(&mut terminal.colors.foreground),
        KittySpecial::Background => Some(&mut terminal.colors.background),
        KittySpecial::Cursor => Some(&mut terminal.colors.cursor),
        _ => None,
    }
}

fn update_mouse_flags(terminal: &mut Terminal, mode: Mode, enabled: bool) {
    match mode {
        Mode::MouseEventX10 => {
            terminal.flags.mouse_event = if enabled {
                MouseEvent::X10
            } else {
                MouseEvent::None
            }
        }
        Mode::MouseEventNormal => {
            terminal.flags.mouse_event = if enabled {
                MouseEvent::Normal
            } else {
                MouseEvent::None
            }
        }
        Mode::MouseEventButton => {
            terminal.flags.mouse_event = if enabled {
                MouseEvent::Button
            } else {
                MouseEvent::None
            }
        }
        Mode::MouseEventAny => {
            terminal.flags.mouse_event = if enabled {
                MouseEvent::Any
            } else {
                MouseEvent::None
            }
        }
        Mode::MouseFormatUtf8 => {
            terminal.flags.mouse_format = if enabled {
                MouseFormat::Utf8
            } else {
                MouseFormat::X10
            }
        }
        Mode::MouseFormatSgr => {
            terminal.flags.mouse_format = if enabled {
                MouseFormat::Sgr
            } else {
                MouseFormat::X10
            }
        }
        Mode::MouseFormatUrxvt => {
            terminal.flags.mouse_format = if enabled {
                MouseFormat::Urxvt
            } else {
                MouseFormat::X10
            }
        }
        Mode::MouseFormatSgrPixels => {
            terminal.flags.mouse_format = if enabled {
                MouseFormat::SgrPixels
            } else {
                MouseFormat::X10
            }
        }
        _ => {}
    }
}

fn apply_mode_side_effects(terminal: &mut Terminal, mode: Mode, enabled: bool) {
    match mode {
        Mode::Origin => terminal.set_cursor_pos(1, 1),
        Mode::EnableLeftAndRightMargin if !enabled => {
            terminal.scrolling_region.left = 0;
            terminal.scrolling_region.right = terminal.cols.saturating_sub(1);
        }
        Mode::AltScreenLegacy => terminal.switch_screen_mode(SwitchScreenMode::M47, enabled),
        Mode::AltScreen => terminal.switch_screen_mode(SwitchScreenMode::M1047, enabled),
        Mode::AltScreenSaveCursorClearEnter => {
            terminal.switch_screen_mode(SwitchScreenMode::M1049, enabled);
        }
        Mode::SaveCursor => {
            if enabled {
                terminal.save_cursor();
            } else {
                terminal.restore_cursor();
            }
        }
        Mode::Column132 => {
            terminal.deccolm(if enabled {
                DeccolmMode::Cols132
            } else {
                DeccolmMode::Cols80
            });
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::device_attributes::{
        Attributes, ConformanceLevel, DeviceType, Feature, Primary, Secondary,
    };
    use crate::page::SemanticContent;
    use crate::screen_set::ScreenKey;
    use crate::stream::Stream;
    use crate::terminal::{Options, Terminal};

    fn terminal_with_size(cols: u16, rows: u16) -> Terminal {
        Terminal::new(Options {
            cols,
            rows,
            max_scrollback: 1024,
            width_px: 720,
            height_px: 432,
        })
    }

    fn terminal() -> Terminal {
        terminal_with_size(80, 24)
    }

    fn stream(effects: CapturedEffects) -> Stream<TerminalHandler<CapturedEffects>> {
        Stream::new(TerminalHandler::new(terminal(), effects))
    }

    fn stream_with_size(
        cols: u16,
        rows: u16,
        effects: CapturedEffects,
    ) -> Stream<TerminalHandler<CapturedEffects>> {
        Stream::new(TerminalHandler::new(
            terminal_with_size(cols, rows),
            effects,
        ))
    }

    // ghostty: "basic print" (stream_terminal.zig:751)
    #[test]
    fn basic_print() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"Hello");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 5);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
        assert_eq!(stream.handler.terminal.plain_string(), "Hello");
    }

    // ghostty: "cursor movement" (stream_terminal.zig:767)
    #[test]
    fn cursor_movement() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"Hello\x1B[1;1H");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);

        stream.next_slice(b"\x1B[2;3H");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 2);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 1);
    }

    // ghostty: "erase operations" (stream_terminal.zig:785)
    #[test]
    fn erase_operations() {
        let mut stream = stream_with_size(20, 10, CapturedEffects::default());

        stream.next_slice(b"Hello World\x1B[1;6H\x1B[K");

        assert_eq!(stream.handler.terminal.plain_string(), "Hello");
    }

    // ghostty: "tabs" (stream_terminal.zig:806)
    #[test]
    fn tabs() {
        let mut stream = stream_with_size(80, 10, CapturedEffects::default());

        stream.next_slice(b"A\tB");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 9);
        assert_eq!(stream.handler.terminal.plain_string(), "A       B");
    }

    // ghostty: "modes" (stream_terminal.zig:821)
    #[test]
    fn modes() {
        let mut stream = stream(CapturedEffects::default());

        assert!(stream.handler.terminal.modes.get(Mode::Wraparound));
        stream.next_slice(b"\x1B[?7l");
        assert!(!stream.handler.terminal.modes.get(Mode::Wraparound));
        stream.next_slice(b"\x1B[?7h");
        assert!(stream.handler.terminal.modes.get(Mode::Wraparound));
    }

    // ghostty: "scrolling regions" (stream_terminal.zig:836)
    #[test]
    fn scrolling_regions() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[5;20r");

        assert_eq!(stream.handler.terminal.scrolling_region.top, 4);
        assert_eq!(stream.handler.terminal.scrolling_region.bottom, 19);
        assert_eq!(stream.handler.terminal.scrolling_region.left, 0);
        assert_eq!(stream.handler.terminal.scrolling_region.right, 79);
    }

    // ghostty: "charsets" (stream_terminal.zig:851)
    #[test]
    fn charsets() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B(0`");

        assert_eq!(stream.handler.terminal.plain_string(), "◆");
    }

    // ghostty: "alt screen" (stream_terminal.zig:867)
    #[test]
    fn alt_screen() {
        let mut stream = stream_with_size(10, 5, CapturedEffects::default());

        stream.next_slice(b"Primary");
        assert_eq!(
            stream.handler.terminal.screens.active_key(),
            ScreenKey::Primary
        );
        stream.next_slice(b"\x1B[?1049h");
        assert_eq!(
            stream.handler.terminal.screens.active_key(),
            ScreenKey::Alternate
        );
        stream.next_slice(b"Alt");
        stream.next_slice(b"\x1B[?1049l");
        assert_eq!(
            stream.handler.terminal.screens.active_key(),
            ScreenKey::Primary
        );
        assert_eq!(stream.handler.terminal.plain_string(), "Primary");
    }

    // ghostty: "cursor save and restore" (stream_terminal.zig:894)
    #[test]
    fn cursor_save_and_restore() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[10;15H\x1B7\x1B[1;1H\x1B8");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 14);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 9);
    }

    // ghostty: "attributes" (stream_terminal.zig:920)
    #[test]
    fn attributes() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[1mBold\x1B[0m");

        assert_eq!(stream.handler.terminal.plain_string(), "Bold");
    }

    // ghostty: "DECALN screen alignment" (stream_terminal.zig:936)
    #[test]
    fn decaln_screen_alignment() {
        let mut stream = stream_with_size(10, 3, CapturedEffects::default());

        stream.next_slice(b"\x1B#8");

        assert_eq!(
            stream.handler.terminal.plain_string(),
            "EEEEEEEEEE\nEEEEEEEEEE\nEEEEEEEEEE"
        );
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
    }

    // ghostty: "full reset" (stream_terminal.zig:956)
    #[test]
    fn full_reset_without_deferred_glyph_assertions() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"Hello\x1B[10;20H\x1B[5;20r\x1B[?7l\x1Bc");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
        assert_eq!(stream.handler.terminal.scrolling_region.top, 0);
        assert_eq!(stream.handler.terminal.scrolling_region.bottom, 23);
        assert!(stream.handler.terminal.modes.get(Mode::Wraparound));
    }

    #[test]
    fn utf8_invalid_prefix_then_valid_multibyte() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\xF0\x9F\xC2\xA9");

        assert_eq!(stream.handler.terminal.plain_string(), "\u{FFFD}\u{00A9}");
    }

    #[test]
    fn utf8_invalid_then_escape_sequence() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"A\xC2\x1B[2;3H");

        assert_eq!(stream.handler.terminal.plain_string(), "A\u{FFFD}");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 2);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 1);
    }

    #[test]
    fn utf8_invalid_then_c0_control() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"AB\xC2\x08X");

        assert_eq!(stream.handler.terminal.plain_string(), "ABX");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 3);
    }

    #[test]
    fn cud_from_above_top_margin_clamps_at_bottom_margin() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[5;10r\x1b[2;1H\x1b[20B");

        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 9);
    }

    #[test]
    fn cuu_from_below_bottom_margin_clamps_at_top_margin() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[5;10r\x1b[15;1H\x1b[20A");

        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 4);
    }

    #[test]
    fn cuu_from_above_top_margin_reaches_screen_top() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[5;10r\x1b[3;1H\x1b[9A");

        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
    }

    #[test]
    fn cuf_from_left_of_left_margin_clamps_at_right_margin() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[?69h\x1b[10;20s\x1b[1;5H\x1b[40C");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 19);
    }

    #[test]
    fn hpr_crosses_right_margin_via_set_cursor_pos() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[?69h\x1b[10;20s\x1b[1;13H\x1b[30a");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 42);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
    }

    #[test]
    fn vpr_crosses_bottom_margin_via_set_cursor_pos() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[5;10r\x1b[7;1H\x1b[20e");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 23);
    }

    #[test]
    fn xtrestore_without_save_keeps_mode_defaults() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[?7r");
        assert!(stream.handler.terminal.modes.get(Mode::Wraparound));

        stream.next_slice(b"\x1b[?25r");
        assert!(stream.handler.terminal.modes.get(Mode::CursorVisible));
    }

    #[test]
    fn full_reset_resets_saved_modes_to_defaults() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[?7l\x1b[?7s\x1bc\x1b[?7r");

        assert!(stream.handler.terminal.modes.get(Mode::Wraparound));
    }

    #[test]
    fn alt_screen_after_resize_uses_current_size() {
        let mut stream = stream(CapturedEffects::default());

        stream.handler.terminal.resize(100, 30);
        stream.next_slice(b"\x1b[?1049h");

        assert_eq!(stream.handler.terminal.active_screen().cols(), 100);
        assert_eq!(stream.handler.terminal.active_screen().rows(), 30);
    }

    #[test]
    fn alt_screen_before_resize_then_resize_tracks() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1b[?1049h");
        stream.handler.terminal.resize(100, 30);
        stream.next_slice(b"\x1b[?1049l\x1b[?1049h");

        assert_eq!(stream.handler.terminal.active_screen().cols(), 100);
        assert_eq!(stream.handler.terminal.active_screen().rows(), 30);
    }

    // T-omitted (glyph protocol state is not ported): "glyph protocol APC with write_pty callback" (stream_terminal.zig:983)

    // ghostty: "ignores query actions" (stream_terminal.zig:1011)
    #[test]
    fn ignores_query_actions_without_effects() {
        let mut stream = Stream::new(TerminalHandler::new(terminal(), NoopEffects));

        stream.next_slice(b"\x1B[c\x1B[5n\x1B[6nTest");

        assert_eq!(stream.handler.terminal.plain_string(), "Test");
    }

    // ghostty: "OSC 4 set and reset palette" (stream_terminal.zig:1030)
    #[test]
    fn osc_4_set_and_reset_palette() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());
        let original = stream.handler.terminal.colors.palette.original[0];

        stream.next_slice(b"\x1B]4;0;rgb:ff/00/00\x1B\\");
        assert_eq!(
            stream.handler.terminal.colors.palette.current[0],
            Rgb {
                r: 0xff,
                g: 0,
                b: 0
            }
        );
        assert!(stream.handler.terminal.colors.palette.mask.is_set(0));

        stream.next_slice(b"\x1B]104;0\x1B\\");
        assert_eq!(stream.handler.terminal.colors.palette.current[0], original);
        assert!(!stream.handler.terminal.colors.palette.mask.is_set(0));
    }

    // ghostty: "OSC 104 reset all palette colors" (stream_terminal.zig:1053)
    #[test]
    fn osc_104_reset_all_palette_colors() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(
            b"\x1B]4;0;rgb:ff/00/00\x1B\\\x1B]4;1;rgb:00/ff/00\x1B\\\x1B]4;2;rgb:00/00/ff\x1B\\",
        );
        assert!(stream.handler.terminal.colors.palette.mask.is_set(0));
        assert!(stream.handler.terminal.colors.palette.mask.is_set(1));
        assert!(stream.handler.terminal.colors.palette.mask.is_set(2));

        stream.next_slice(b"\x1B]104\x1B\\");
        assert!(!stream.handler.terminal.colors.palette.mask.is_set(0));
        assert!(!stream.handler.terminal.colors.palette.mask.is_set(1));
        assert!(!stream.handler.terminal.colors.palette.mask.is_set(2));
    }

    // ghostty: "OSC 10 set and reset foreground color" (stream_terminal.zig:1078)
    #[test]
    fn osc_10_set_and_reset_foreground_color() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        assert_eq!(stream.handler.terminal.colors.foreground.get(), None);
        stream.next_slice(b"\x1B]10;rgb:ff/00/00\x1B\\");
        assert_eq!(
            stream.handler.terminal.colors.foreground.get(),
            Some(Rgb {
                r: 0xff,
                g: 0,
                b: 0
            })
        );
        stream.next_slice(b"\x1B]110\x1B\\");
        assert_eq!(stream.handler.terminal.colors.foreground.get(), None);
    }

    // ghostty: "OSC 11 set and reset background color" (stream_terminal.zig:1100)
    #[test]
    fn osc_11_set_and_reset_background_color() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]11;rgb:00/ff/00\x1B\\");
        assert_eq!(
            stream.handler.terminal.colors.background.get(),
            Some(Rgb {
                r: 0,
                g: 0xff,
                b: 0
            })
        );
        stream.next_slice(b"\x1B]111\x1B\\");
        assert_eq!(stream.handler.terminal.colors.background.get(), None);
    }

    // ghostty: "OSC 12 set and reset cursor color" (stream_terminal.zig:1119)
    #[test]
    fn osc_12_set_and_reset_cursor_color() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]12;rgb:00/00/ff\x1B\\");
        assert_eq!(
            stream.handler.terminal.colors.cursor.get(),
            Some(Rgb {
                r: 0,
                g: 0,
                b: 0xff
            })
        );
        stream.next_slice(b"\x1B]112\x1B\\");
        assert_eq!(stream.handler.terminal.colors.cursor.get(), None);
    }

    // ghostty: "kitty color protocol set palette" (stream_terminal.zig:1138)
    #[test]
    fn kitty_color_protocol_set_palette() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]21;5=rgb:ff/00/ff\x1B\\");

        assert_eq!(
            stream.handler.terminal.colors.palette.current[5],
            Rgb {
                r: 0xff,
                g: 0,
                b: 0xff
            }
        );
        assert!(stream.handler.terminal.colors.palette.mask.is_set(5));
        assert!(stream.handler.terminal.dirty.palette);
    }

    // ghostty: "kitty color protocol reset palette" (stream_terminal.zig:1154)
    #[test]
    fn kitty_color_protocol_reset_palette() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());
        let original = stream.handler.terminal.colors.palette.original[7];

        stream.next_slice(b"\x1B]21;7=rgb:aa/bb/cc\x1B\\");
        assert!(stream.handler.terminal.colors.palette.mask.is_set(7));
        stream.next_slice(b"\x1B]21;7=\x1B\\");

        assert_eq!(stream.handler.terminal.colors.palette.current[7], original);
        assert!(!stream.handler.terminal.colors.palette.mask.is_set(7));
    }

    // ghostty: "kitty color protocol set foreground" (stream_terminal.zig:1171)
    #[test]
    fn kitty_color_protocol_set_foreground() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]21;foreground=rgb:12/34/56\x1B\\");

        assert_eq!(
            stream.handler.terminal.colors.foreground.get(),
            Some(Rgb {
                r: 0x12,
                g: 0x34,
                b: 0x56
            })
        );
    }

    // ghostty: "kitty color protocol set background" (stream_terminal.zig:1186)
    #[test]
    fn kitty_color_protocol_set_background() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]21;background=rgb:78/9a/bc\x1B\\");

        assert_eq!(
            stream.handler.terminal.colors.background.get(),
            Some(Rgb {
                r: 0x78,
                g: 0x9a,
                b: 0xbc
            })
        );
    }

    // ghostty: "kitty color protocol set cursor" (stream_terminal.zig:1201)
    #[test]
    fn kitty_color_protocol_set_cursor() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]21;cursor=rgb:de/f0/12\x1B\\");

        assert_eq!(
            stream.handler.terminal.colors.cursor.get(),
            Some(Rgb {
                r: 0xde,
                g: 0xf0,
                b: 0x12
            })
        );
    }

    // ghostty: "kitty color protocol reset foreground" (stream_terminal.zig:1216)
    #[test]
    fn kitty_color_protocol_reset_foreground() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]21;foreground=rgb:11/22/33\x1B\\");
        assert!(stream.handler.terminal.colors.foreground.get().is_some());
        stream.next_slice(b"\x1B]21;foreground=\x1B\\");

        assert_eq!(stream.handler.terminal.colors.foreground.get(), None);
    }

    // ghostty: "palette dirty flag set on color change" (stream_terminal.zig:1232)
    #[test]
    fn palette_dirty_flag_set_on_color_change() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.handler.terminal.dirty.palette = false;
        stream.next_slice(b"\x1B]4;0;rgb:ff/00/00\x1B\\");
        assert!(stream.handler.terminal.dirty.palette);

        stream.handler.terminal.dirty.palette = false;
        stream.next_slice(b"\x1B]104;0\x1B\\");
        assert!(stream.handler.terminal.dirty.palette);

        stream.handler.terminal.dirty.palette = false;
        stream.next_slice(b"\x1B]21;1=rgb:00/ff/00\x1B\\");
        assert!(stream.handler.terminal.dirty.palette);
    }

    // ghostty: "semantic prompt fresh line" (stream_terminal.zig:1257)
    #[test]
    fn semantic_prompt_fresh_line() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"Hello\x1B]133;L\x07");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 1);
    }

    // ghostty: "semantic prompt fresh line new prompt" (stream_terminal.zig:1270)
    #[test]
    fn semantic_prompt_fresh_line_new_prompt() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"Hello\x1B]133;A\x07");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 1);
        assert_eq!(
            stream
                .handler
                .terminal
                .active_screen()
                .cursor
                .semantic_content,
            SemanticContent::Prompt
        );

        stream.next_slice(b"prompt$ \x1B]133;A;redraw=1\x07");
        assert!(stream.handler.terminal.flags.shell_redraws_prompt);
    }

    // ghostty: "semantic prompt end of input, then start output" (stream_terminal.zig:1294)
    #[test]
    fn semantic_prompt_end_of_input_then_start_output() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"Hello\x1B]133;A\x07prompt$ \x1B]133;B\x07");
        assert_eq!(
            stream
                .handler
                .terminal
                .active_screen()
                .cursor
                .semantic_content,
            SemanticContent::Input
        );
        stream.next_slice(b"\x1B]133;C\x07");
        assert_eq!(
            stream
                .handler
                .terminal
                .active_screen()
                .cursor
                .semantic_content,
            SemanticContent::Output
        );
    }

    // ghostty: "semantic prompt prompt_start" (stream_terminal.zig:1311)
    #[test]
    fn semantic_prompt_prompt_start() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"Hello\x1B]133;P\x07");

        assert_eq!(
            stream
                .handler
                .terminal
                .active_screen()
                .cursor
                .semantic_content,
            SemanticContent::Prompt
        );
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 5);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
    }

    // ghostty: "semantic prompt new_command" (stream_terminal.zig:1328)
    #[test]
    fn semantic_prompt_new_command() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"Hello\x1B]133;N\x07");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 1);
        assert_eq!(
            stream
                .handler
                .terminal
                .active_screen()
                .cursor
                .semantic_content,
            SemanticContent::Prompt
        );
    }

    // ghostty: "semantic prompt new_command at column zero" (stream_terminal.zig:1346)
    #[test]
    fn semantic_prompt_new_command_at_column_zero() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]133;N\x07");

        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
        assert_eq!(
            stream
                .handler
                .terminal
                .active_screen()
                .cursor
                .semantic_content,
            SemanticContent::Prompt
        );
    }

    // ghostty: "semantic prompt end_prompt_start_input_terminate_eol clears on linefeed" (stream_terminal.zig:1360)
    #[test]
    fn semantic_prompt_end_prompt_start_input_terminate_eol_clears_on_linefeed() {
        let mut stream = stream_with_size(10, 10, CapturedEffects::default());

        stream.next_slice(b"\x1B]133;I\x07");
        assert_eq!(
            stream
                .handler
                .terminal
                .active_screen()
                .cursor
                .semantic_content,
            SemanticContent::Input
        );
        stream.next_slice(b"\n");
        assert_eq!(
            stream
                .handler
                .terminal
                .active_screen()
                .cursor
                .semantic_content,
            SemanticContent::Output
        );
    }

    // ghostty: "bell effect callback" (stream_terminal.zig:1376)
    #[test]
    fn bell_effect_callback() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x07AfterBell");
        assert_eq!(stream.handler.terminal.plain_string(), "AfterBell");
        assert_eq!(stream.handler.effects.bell_count, 1);

        stream.next_slice(b"\x07\x07");
        assert_eq!(stream.handler.effects.bell_count, 3);
    }

    // ghostty: "request mode DECRQM with write_pty callback" (stream_terminal.zig:1420)
    #[test]
    fn request_mode_report_writes_encoded_mode_state() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[?7$p");
        assert_eq!(stream.handler.effects.pty, b"\x1B[?7;1$y");

        stream.next_slice(b"\x1B[?7l\x1B[?7$p");
        assert_eq!(stream.handler.effects.pty, b"\x1B[?7;1$y\x1B[?7;2$y");

        stream.handler.effects.pty.clear();
        stream.next_slice(b"\x1B[?9999$p");
        assert_eq!(stream.handler.effects.pty, b"\x1B[?9999;0$y");
    }

    // ghostty: "stream: CSI W with intermediate but no params" (stream_terminal.zig:1468)
    #[test]
    fn stream_csi_w_with_intermediate_but_no_params() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[?W");

        assert!(stream.handler.terminal.plain_string().is_empty());
    }

    // ghostty: "window_title effect is called" (stream_terminal.zig:1484)
    #[test]
    fn osc_title_updates_terminal_and_effects() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B]0;Quarterly Review\x1B\\");

        assert_eq!(stream.handler.terminal.title(), Some("Quarterly Review"));
        assert_eq!(
            stream.handler.effects.titles,
            vec![Some("Quarterly Review".to_owned())]
        );
    }

    // ghostty: "window_title effect not called without callback" (stream_terminal.zig:1508)
    #[test]
    fn window_title_effect_not_called_without_callback() {
        let mut stream = Stream::new(TerminalHandler::new(terminal(), NoopEffects));

        stream.next_slice(b"\x1B]2;Hello World\x1B\\Test");

        assert_eq!(stream.handler.terminal.title(), Some("Hello World"));
        assert_eq!(stream.handler.terminal.plain_string(), "Test");
    }

    // ghostty: "window_title effect with empty title" (stream_terminal.zig:1528)
    #[test]
    fn window_title_effect_with_empty_title() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B]2;\x1B\\");

        assert_eq!(stream.handler.terminal.title(), None);
        assert_eq!(stream.handler.effects.titles, vec![None]);
    }

    // T-omitted (kitty keyboard stack is deferred): "kitty_keyboard_query" (stream_terminal.zig:1552)

    // ghostty: "xtversion default" (stream_terminal.zig:1581)
    #[test]
    fn xtversion_default() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[>0q");

        assert_eq!(stream.handler.effects.pty, b"\x1BP>|libghostty\x1B\\");
    }

    // ghostty: "xtversion with effect" (stream_terminal.zig:1604)
    #[test]
    fn xtversion_with_effect() {
        let mut stream = stream(CapturedEffects {
            xtversion_response: Some("ghostty 1.2.3".to_owned()),
            ..CapturedEffects::default()
        });

        stream.next_slice(b"\x1B[>0q");

        assert_eq!(stream.handler.effects.pty, b"\x1BP>|ghostty 1.2.3\x1B\\");
    }

    // port-added: DECSTBM without params must reset to the full screen, matching common app behavior.
    #[test]
    fn decstbm_reset_no_params() {
        let mut stream = stream_with_size(10, 5, CapturedEffects::default());
        stream.next_slice(b"\x1B[2;4r");
        assert_eq!(stream.handler.terminal.scrolling_region.top, 1);
        assert_eq!(stream.handler.terminal.scrolling_region.bottom, 3);

        stream.next_slice(b"\x1B[r");
        assert_eq!(stream.handler.terminal.scrolling_region.top, 0);
        assert_eq!(stream.handler.terminal.scrolling_region.bottom, 4);
    }

    // port-added: DECSTBM explicit zero parameters use the same reset path as missing params.
    #[test]
    fn decstbm_reset_explicit_zeros() {
        let mut stream = stream_with_size(10, 5, CapturedEffects::default());
        stream.next_slice(b"\x1B[2;4r");
        stream.next_slice(b"\x1B[0;0r");

        assert_eq!(stream.handler.terminal.scrolling_region.top, 0);
        assert_eq!(stream.handler.terminal.scrolling_region.bottom, 4);
    }

    // port-added: reset DECSTBM must restore full-screen scrolling instead of leaving a partial region.
    #[test]
    fn decstbm_reset_unlocks_full_screen_scroll() {
        let mut stream = stream_with_size(5, 3, CapturedEffects::default());
        stream.next_slice(b"ABC\r\nDEF\r\nGHI");
        stream.next_slice(b"\x1B[1;2r");
        stream.next_slice(b"\x1B[r");
        stream.next_slice(b"\x1B[3;1H\n");

        assert_eq!(stream.handler.terminal.plain_string(), "DEF\nGHI");
    }

    // port-added: DCH explicit zero is a no-op; missing count remains one.
    #[test]
    fn csi_dch_zero_is_noop() {
        let mut stream = stream_with_size(10, 3, CapturedEffects::default());
        stream.next_slice(b"ABCDE\x1B[1;1H");
        stream.next_slice(b"\x1B[0P");
        assert_eq!(stream.handler.terminal.plain_string(), "ABCDE");

        stream.next_slice(b"\x1B[P");
        assert_eq!(stream.handler.terminal.plain_string(), "BCDE");
    }

    // port-added: IL and DL explicit zero counts must remain no-ops at the terminal layer.
    #[test]
    fn csi_il_dl_zero_are_noop() {
        let mut stream = stream_with_size(10, 4, CapturedEffects::default());
        stream.next_slice(b"AAA\r\nBBB");
        stream.next_slice(b"\x1B[1;1H\x1B[0L");
        assert_eq!(stream.handler.terminal.plain_string(), "AAA\nBBB");

        stream.next_slice(b"\x1B[0M");
        assert_eq!(stream.handler.terminal.plain_string(), "AAA\nBBB");
    }

    // port-added: SU and SD explicit zero counts must not disturb the screen.
    #[test]
    fn csi_su_sd_zero_are_noop() {
        let mut stream = stream_with_size(10, 3, CapturedEffects::default());
        stream.next_slice(b"AAA\r\nBBB\r\nCCC");
        stream.next_slice(b"\x1B[0S");
        assert_eq!(stream.handler.terminal.plain_string(), "AAA\nBBB\nCCC");

        stream.next_slice(b"\x1B[0T");
        assert_eq!(stream.handler.terminal.plain_string(), "AAA\nBBB\nCCC");
    }

    // port-added: CBT explicit zero must keep the cursor in place while missing count moves one tab stop.
    #[test]
    fn csi_cbt_zero_keeps_cursor() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\t");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 8);

        stream.next_slice(b"\x1B[0Z");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 8);

        stream.next_slice(b"\x1B[Z");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
    }

    // port-added: CHT was missing from dispatch; counts advance through tab stops.
    #[test]
    fn csi_cht_advances_tabstops() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B[I");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 8);

        stream.next_slice(b"\x1B[2I");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 24);
    }

    // port-added: CSI k/j are Ghostty cursor movement aliases for CUU/CUB.
    #[test]
    fn csi_k_j_alias_cursor_moves() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B[5;5H");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 4);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 4);

        stream.next_slice(b"\x1B[2k");
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 2);
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 4);

        stream.next_slice(b"\x1B[2j");
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 2);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 2);
    }

    // port-added: CNL is cursor-down plus carriage return, not NEL-style scrolling.
    #[test]
    fn csi_cnl_moves_down_and_returns() {
        let mut stream = stream_with_size(10, 5, CapturedEffects::default());
        stream.next_slice(b"\x1B[2;5H\x1B[2E");

        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 3);
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
    }

    // port-added: CNL clamps at the bottom instead of scrolling the region.
    #[test]
    fn csi_cnl_clamps_at_bottom_without_scroll() {
        let mut stream = stream_with_size(10, 3, CapturedEffects::default());
        stream.next_slice(b"TOP");
        stream.next_slice(b"\x1B[3;5H\x1B[5E");

        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 2);
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.plain_string(), "TOP");
    }

    // port-added: CPL is cursor-up plus carriage return and clamps at the top.
    #[test]
    fn csi_cpl_moves_up_and_returns() {
        let mut stream = stream_with_size(10, 5, CapturedEffects::default());
        stream.next_slice(b"\x1B[4;6H\x1B[2F");
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 1);
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);

        stream.next_slice(b"\x1B[9F");
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
    }

    // port-added: SO/SI must lock GL to G1/G0 for DEC special line drawing.
    #[test]
    fn so_si_switch_gl() {
        let mut stream = stream_with_size(10, 3, CapturedEffects::default());
        stream.next_slice(b"\x1B)0q\x0Eqq\x0Fq");

        assert_eq!(stream.handler.terminal.plain_string(), "q\u{2500}\u{2500}q");
    }

    // port-added: SS2 shifts only one printable character to G2.
    #[test]
    fn ss2_single_shift() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B*0\x1BNqq");

        assert_eq!(stream.handler.terminal.plain_string(), "\u{2500}q");
    }

    // port-added: SS3 shifts only one printable character to G3.
    #[test]
    fn ss3_single_shift() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B+0\x1BOqq");

        assert_eq!(stream.handler.terminal.plain_string(), "\u{2500}q");
    }

    // port-added: LS2 is a locking shift, not a single shift.
    #[test]
    fn ls2_locking_shift() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B*0\x1Bnqq");

        assert_eq!(stream.handler.terminal.plain_string(), "\u{2500}\u{2500}");
    }

    // port-added: LS3 is a locking shift, not a single shift.
    #[test]
    fn ls3_locking_shift() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B+0\x1Boqq");

        assert_eq!(stream.handler.terminal.plain_string(), "\u{2500}\u{2500}");
    }

    // port-added: DECKPAM/DECKPNM toggle keypad application mode.
    #[test]
    fn esc_keypad_application_mode() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B=");
        assert!(stream.handler.terminal.modes.get(Mode::KeypadKeys));

        stream.next_slice(b"\x1B>");
        assert!(!stream.handler.terminal.modes.get(Mode::KeypadKeys));
    }

    // port-added: DECSLRM with two params must reach the terminal when mode 69 is set.
    #[test]
    fn decslrm_two_params() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B[?69h\x1B[2;4s");

        assert_eq!(stream.handler.terminal.scrolling_region.left, 1);
        assert_eq!(stream.handler.terminal.scrolling_region.right, 3);
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 0);
        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 0);
    }

    // port-added: DECSLRM with one param defaults the right margin to the full width.
    #[test]
    fn decslrm_one_param() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B[?69h\x1B[3s");

        assert_eq!(stream.handler.terminal.scrolling_region.left, 2);
        assert_eq!(stream.handler.terminal.scrolling_region.right, 79);
    }

    // port-added: ambiguous CSI s resets margins when mode 69 is enabled.
    #[test]
    fn decslrm_ambiguous_mode69_on_resets() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B[?69h\x1B[2;4s\x1B[s");

        assert_eq!(stream.handler.terminal.scrolling_region.left, 0);
        assert_eq!(stream.handler.terminal.scrolling_region.right, 79);
    }

    // port-added: ambiguous CSI s saves the cursor when mode 69 is disabled.
    #[test]
    fn scosc_saves_cursor_mode69_off() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B[3;4H\x1B[s\x1B[1;1H\x1B[u");

        assert_eq!(stream.handler.terminal.active_screen().cursor.y, 2);
        assert_eq!(stream.handler.terminal.active_screen().cursor.x, 3);
    }

    // port-added: Zig clamps oversized DECSTBM bottom values; upstream lacks this oversized test.
    #[test]
    fn decstbm_clamps_oversized_bottom() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B[3;100r");

        assert_eq!(stream.handler.terminal.scrolling_region.top, 2);
        assert_eq!(stream.handler.terminal.scrolling_region.bottom, 23);
    }

    // port-added: Zig clamps oversized DECSLRM right values; upstream lacks this oversized test.
    #[test]
    fn decslrm_clamps_oversized_right() {
        let mut stream = stream(CapturedEffects::default());
        stream.next_slice(b"\x1B[?69h\x1B[3;200s");

        assert_eq!(stream.handler.terminal.scrolling_region.left, 2);
        assert_eq!(stream.handler.terminal.scrolling_region.right, 79);
    }

    // ghostty: "xtversion with empty string effect" (stream_terminal.zig:1630)
    #[test]
    fn xtversion_with_empty_string_effect() {
        let mut stream = stream(CapturedEffects {
            xtversion_response: Some(String::new()),
            ..CapturedEffects::default()
        });

        stream.next_slice(b"\x1B[>0q");

        assert_eq!(stream.handler.effects.pty, b"\x1BP>|libghostty\x1B\\");
    }

    fn size_effects() -> CapturedEffects {
        CapturedEffects {
            size_response: Some(Size {
                rows: 24,
                columns: 80,
                cell_width: 9,
                cell_height: 18,
            }),
            ..CapturedEffects::default()
        }
    }

    // ghostty: "size report csi_14_t with effect" (stream_terminal.zig:1657)
    #[test]
    fn size_report_csi_14_t_with_effect() {
        let mut stream = stream(size_effects());

        stream.next_slice(b"\x1B[14t");

        assert_eq!(stream.handler.effects.pty, b"\x1B[4;432;720t");
    }

    // ghostty: "size report csi_16_t with effect" (stream_terminal.zig:1685)
    #[test]
    fn size_report_csi_16_t_with_effect() {
        let mut stream = stream(size_effects());

        stream.next_slice(b"\x1B[16t");

        assert_eq!(stream.handler.effects.pty, b"\x1B[6;18;9t");
    }

    // ghostty: "size report csi_18_t with effect" (stream_terminal.zig:1713)
    #[test]
    fn size_report_csi_18_t_with_effect() {
        let mut stream = stream(size_effects());

        stream.next_slice(b"\x1B[18t");

        assert_eq!(stream.handler.effects.pty, b"\x1B[8;24;80t");
    }

    // ghostty: "size report no effect callback" (stream_terminal.zig:1741)
    #[test]
    fn size_report_no_effect_callback() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[14t");

        assert!(stream.handler.effects.pty.is_empty());
    }

    // ghostty: "size report csi_21_t title" (stream_terminal.zig:1764)
    #[test]
    fn size_report_csi_21_t_title() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B]2;My Title\x1B\\\x1B[21t");

        assert_eq!(stream.handler.effects.pty, b"\x1B]lMy Title\x1B\\");
    }

    // ghostty: "enquiry no effect" (stream_terminal.zig:1791)
    #[test]
    fn enquiry_no_effect() {
        let mut stream = stream(CapturedEffects::default());

        stream.next(0x05);

        assert!(stream.handler.effects.pty.is_empty());
    }

    // ghostty: "enquiry with effect" (stream_terminal.zig:1814)
    #[test]
    fn enquiry_writes_effect_response() {
        let effects = CapturedEffects {
            enquiry_response: Some(b"locus".to_vec()),
            ..CapturedEffects::default()
        };
        let mut stream = stream(effects);

        stream.next(0x05);

        assert_eq!(stream.handler.effects.pty, b"locus");
    }

    // ghostty: "enquiry with empty response" (stream_terminal.zig:1841)
    #[test]
    fn enquiry_with_empty_response() {
        let effects = CapturedEffects {
            enquiry_response: Some(Vec::new()),
            ..CapturedEffects::default()
        };
        let mut stream = stream(effects);

        stream.next(0x05);

        assert!(stream.handler.effects.pty.is_empty());
    }

    // ghostty: "device status: operating status" (stream_terminal.zig:1868)
    #[test]
    fn device_status_operating_status() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[5n");

        assert_eq!(stream.handler.effects.pty, b"\x1B[0n");
    }

    // ghostty: "device status: cursor position" (stream_terminal.zig:1893)
    #[test]
    fn device_status_reports_cursor_position() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[6n");
        assert_eq!(stream.handler.effects.pty, b"\x1B[1;1R");

        stream.handler.effects.pty.clear();
        stream.next_slice(b"\x1B[5;10H\x1B[6n");
        assert_eq!(stream.handler.effects.pty, b"\x1B[5;10R");
    }

    // ghostty: "device status: cursor position with origin mode" (stream_terminal.zig:1923)
    #[test]
    fn device_status_cursor_position_with_origin_mode() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[5;20r\x1B[?6h\x1B[3;5H\x1B[6n");

        assert_eq!(stream.handler.effects.pty, b"\x1B[3;5R");
    }

    // ghostty: "device status: color scheme dark" (stream_terminal.zig:1955)
    #[test]
    fn device_status_color_scheme_dark() {
        let mut stream = stream(CapturedEffects {
            color_scheme_response: Some(ColorScheme::Dark),
            ..CapturedEffects::default()
        });

        stream.next_slice(b"\x1B[?996n");

        assert_eq!(stream.handler.effects.pty, b"\x1B[?997;1n");
    }

    // ghostty: "device status: color scheme light" (stream_terminal.zig:1984)
    #[test]
    fn device_status_color_scheme_light() {
        let mut stream = stream(CapturedEffects {
            color_scheme_response: Some(ColorScheme::Light),
            ..CapturedEffects::default()
        });

        stream.next_slice(b"\x1B[?996n");

        assert_eq!(stream.handler.effects.pty, b"\x1B[?997;2n");
    }

    // ghostty: "device status: color scheme without callback" (stream_terminal.zig:2013)
    #[test]
    fn device_status_color_scheme_without_callback() {
        let mut stream = stream(CapturedEffects::default());

        stream.next_slice(b"\x1B[?996n");

        assert!(stream.handler.effects.pty.is_empty());
    }

    // ghostty: "device status: readonly ignores all" (stream_terminal.zig:2038)
    #[test]
    fn device_status_readonly_ignores_all() {
        let mut stream = Stream::new(TerminalHandler::new(terminal(), NoopEffects));

        stream.next_slice(b"\x1B[5n\x1B[6n\x1B[?996nTest");

        assert_eq!(stream.handler.terminal.plain_string(), "Test");
    }

    // ghostty: "device attributes: primary DA" (stream_terminal.zig:2057)
    #[test]
    fn device_attributes_default_primary() {
        let effects = CapturedEffects {
            device_attributes_response: Some(Attributes::default()),
            ..CapturedEffects::default()
        };
        let mut stream = stream(effects);

        stream.next_slice(b"\x1B[c");

        assert_eq!(stream.handler.effects.pty, b"\x1B[?62;22c");
    }

    // ghostty: "device attributes: secondary DA" (stream_terminal.zig:2085)
    #[test]
    fn device_attributes_secondary_da() {
        let mut stream = stream(CapturedEffects {
            device_attributes_response: Some(Attributes::default()),
            ..CapturedEffects::default()
        });

        stream.next_slice(b"\x1B[>c");

        assert_eq!(stream.handler.effects.pty, b"\x1B[>1;0;0c");
    }

    // ghostty: "device attributes: tertiary DA" (stream_terminal.zig:2113)
    #[test]
    fn device_attributes_tertiary_da() {
        let mut stream = stream(CapturedEffects {
            device_attributes_response: Some(Attributes::default()),
            ..CapturedEffects::default()
        });

        stream.next_slice(b"\x1B[=c");

        assert_eq!(stream.handler.effects.pty, b"\x1BP!|00000000\x1B\\");
    }

    // ghostty: "device attributes: readonly ignores" (stream_terminal.zig:2141)
    #[test]
    fn device_attributes_readonly_ignores() {
        let mut stream = Stream::new(TerminalHandler::new(terminal(), NoopEffects));

        stream.next_slice(b"\x1B[c\x1B[>c\x1B[=cTest");

        assert_eq!(stream.handler.terminal.plain_string(), "Test");
    }

    // ghostty: "device attributes: custom response" (stream_terminal.zig:2160)
    #[test]
    fn device_attributes_custom_response() {
        let attrs = Attributes {
            primary: Primary {
                conformance_level: ConformanceLevel::VT420,
                features: vec![Feature::AnsiColor, Feature::Clipboard],
            },
            secondary: Secondary {
                device_type: DeviceType::Vt420,
                firmware_version: 100,
                rom_cartridge: 0,
            },
            ..Attributes::default()
        };
        let mut stream = stream(CapturedEffects {
            device_attributes_response: Some(attrs),
            ..CapturedEffects::default()
        });

        stream.next_slice(b"\x1B[c\x1B[>c");

        assert_eq!(
            stream.handler.effects.pty,
            b"\x1B[?64;22;52c\x1B[>41;100;0c"
        );
    }

    // T-omitted (kitty graphics feature is deferred): "kitty graphics APC response" (stream_terminal.zig:2200)
    // T-omitted (kitty graphics feature is deferred): "kitty graphics via APC" (stream_terminal.zig:2229)
}
