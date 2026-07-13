//! Stream dispatcher over the VT parser.
//!
//! `Parser` owns the byte-level state machine. This module only converts
//! parser actions into typed handler callbacks and handles ground-state UTF-8.

use crate::charsets::{ActiveSlot, Charset, Slots as CharsetSlots};
use crate::device_attributes;
use crate::device_status;
use crate::input::kitty_flags::Flags as KittyFlags;
use crate::modes::{mode_from_int, Mode, ModeTag};
use crate::osc::{ColorOperationKind, ColorRequest, KittyColorRequest, Terminator};
use crate::parser::{Action as ParserAction, Csi, Dcs, Esc, Parser};
use crate::sgr;
use crate::utf8::Utf8Decoder;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtectedMode {
    Off,
    Iso,
    Dec,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EraseDisplay {
    Below,
    Above,
    Complete,
    Scrollback,
    ScrollComplete,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EraseLine {
    Right,
    Left,
    Complete,
    RightUnlessPendingWrap,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorStyle {
    Default,
    BlinkingBlock,
    SteadyBlock,
    BlinkingUnderline,
    SteadyUnderline,
    BlinkingBar,
    SteadyBar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SizeReportStyle {
    Csi14T,
    Csi16T,
    Csi18T,
    Csi21T,
}

pub trait Handler {
    fn interrupt_grapheme_run(&mut self) {}
    fn print(&mut self, _cp: char) {}
    /// A maximal run of printable ASCII observed while the parser is in the
    /// ground state. Implementations may batch this operation.
    fn print_run(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.print(char::from(*byte));
        }
    }
    fn print_repeat(&mut self, _count: usize) {}
    fn execute(&mut self, _byte: u8) {}
    fn index(&mut self) {}
    fn reverse_index(&mut self) {}
    fn next_line(&mut self) {}
    fn cursor_up(&mut self, _value: u16) {}
    fn cursor_down(&mut self, _value: u16) {}
    fn cursor_right(&mut self, _value: u16) {}
    fn cursor_left(&mut self, _value: u16) {}
    fn cursor_col(&mut self, _col: u16) {}
    fn cursor_row(&mut self, _row: u16) {}
    fn cursor_col_relative(&mut self, _value: u16) {}
    fn cursor_row_relative(&mut self, _value: u16) {}
    fn cursor_position(&mut self, _row: u16, _col: u16) {}
    fn insert_blanks(&mut self, _value: usize) {}
    fn delete_chars(&mut self, _value: usize) {}
    fn erase_chars(&mut self, _value: usize) {}
    fn insert_lines(&mut self, _value: usize) {}
    fn delete_lines(&mut self, _value: usize) {}
    fn scroll_up(&mut self, _value: usize) {}
    fn scroll_down(&mut self, _value: usize) {}
    fn erase_display(&mut self, _mode: EraseDisplay, _protected: bool) {}
    fn erase_line(&mut self, _mode: EraseLine, _protected: bool) {}
    fn set_attribute(&mut self, _attribute: sgr::Attribute<'_>) {}
    fn sgr_sequence_end(&mut self) {}
    fn set_mode(&mut self, _mode: Mode) {}
    fn reset_mode(&mut self, _mode: Mode) {}
    fn save_mode(&mut self, _mode: Mode) {}
    fn restore_mode(&mut self, _mode: Mode) {}
    fn request_mode_report(&mut self, _tag: ModeTag) {}
    fn protected_mode(&mut self, _mode: ProtectedMode) {}
    fn cursor_style(&mut self, _style: CursorStyle) {}
    fn mouse_shift_capture(&mut self, _enabled: bool) {}
    fn modify_other_keys_2(&mut self, _enabled: bool) {}
    fn kitty_keyboard_query(&mut self) {}
    fn kitty_keyboard_push(&mut self, _flags: KittyFlags) {}
    fn kitty_keyboard_pop(&mut self, _count: u16) {}
    fn kitty_keyboard_set(&mut self, _flags: KittyFlags) {}
    fn kitty_keyboard_set_or(&mut self, _flags: KittyFlags) {}
    fn kitty_keyboard_set_not(&mut self, _flags: KittyFlags) {}
    fn left_and_right_margin(&mut self, _left: u16, _right: u16) {}
    fn left_and_right_margin_ambiguous(&mut self) {}
    fn top_and_bottom_margin(&mut self, _top: u16, _bottom: u16) {}
    fn restore_cursor(&mut self) {}
    fn save_cursor(&mut self) {}
    fn size_report(&mut self, _style: SizeReportStyle) {}
    fn title_push(&mut self, _index: u16) {}
    fn title_pop(&mut self, _index: u16) {}
    fn tab_set(&mut self) {}
    fn horizontal_tab(&mut self, _count: usize) {}
    fn horizontal_tab_back(&mut self, _count: usize) {}
    fn tab_clear_current(&mut self) {}
    fn tab_clear_all(&mut self) {}
    fn tab_reset(&mut self) {}
    fn configure_charset(&mut self, _slot: CharsetSlots, _charset: Charset) {}
    fn invoke_charset(&mut self, _active: ActiveSlot, _slot: CharsetSlots, _single: bool) {}
    fn decaln(&mut self) {}
    fn full_reset(&mut self) {}
    fn start_hyperlink(&mut self, _id: Option<&[u8]>, _uri: &[u8]) {}
    fn end_hyperlink(&mut self) {}
    fn semantic_prompt(&mut self, _cmd: crate::osc::SemanticPrompt<'_>) {}
    fn mouse_shape(&mut self, _shape: &[u8]) {}
    fn color_operation(
        &mut self,
        _kind: ColorOperationKind,
        _requests: &[ColorRequest],
        _terminator: Terminator,
    ) {
    }
    fn kitty_color_protocol(&mut self, _requests: &[KittyColorRequest], _terminator: Terminator) {}
    fn report_pwd(&mut self, _value: &[u8]) {}
    fn xtversion(&mut self) {}
    fn device_status(&mut self, _request: device_status::Request) {}
    fn device_attributes(&mut self, _req: device_attributes::Req) {}
    fn enquiry(&mut self) {}
    fn window_title(&mut self, _title: &str) {}
    fn window_icon(&mut self, _title: &str) {}
    fn dcs_hook(&mut self, _dcs: Dcs<'_>) {}
    fn dcs_put(&mut self, _byte: u8) {}
    fn dcs_unhook(&mut self) {}
    fn apc_start(&mut self) {}
    fn apc_put(&mut self, _byte: u8) {}
    fn apc_end(&mut self) {}
}

fn simple_sgr_attribute(value: u16) -> Option<sgr::Attribute<'static>> {
    match value {
        0 => Some(sgr::Attribute::Unset),
        1 => Some(sgr::Attribute::Bold),
        2 => Some(sgr::Attribute::Faint),
        3 => Some(sgr::Attribute::Italic),
        4 => Some(sgr::Attribute::Underline(sgr::Underline::Single)),
        5 | 6 => Some(sgr::Attribute::Blink),
        7 => Some(sgr::Attribute::Inverse),
        8 => Some(sgr::Attribute::Invisible),
        9 => Some(sgr::Attribute::Strikethrough),
        21 => Some(sgr::Attribute::Underline(sgr::Underline::Double)),
        22 => Some(sgr::Attribute::ResetBold),
        23 => Some(sgr::Attribute::ResetItalic),
        24 => Some(sgr::Attribute::Underline(sgr::Underline::None)),
        25 => Some(sgr::Attribute::ResetBlink),
        27 => Some(sgr::Attribute::ResetInverse),
        28 => Some(sgr::Attribute::ResetInvisible),
        29 => Some(sgr::Attribute::ResetStrikethrough),
        30..=37 => Some(sgr::Attribute::Fg8(crate::color::Name((value - 30) as u8))),
        39 => Some(sgr::Attribute::ResetFg),
        40..=47 => Some(sgr::Attribute::Bg8(crate::color::Name((value - 40) as u8))),
        49 => Some(sgr::Attribute::ResetBg),
        53 => Some(sgr::Attribute::Overline),
        55 => Some(sgr::Attribute::ResetOverline),
        59 => Some(sgr::Attribute::ResetUnderlineColor),
        90..=97 => Some(sgr::Attribute::BrightFg8(crate::color::Name(
            (value - 82) as u8,
        ))),
        100..=107 => Some(sgr::Attribute::BrightBg8(crate::color::Name(
            (value - 92) as u8,
        ))),
        _ => None,
    }
}

fn parse_sgr_decimal(bytes: &[u8]) -> Option<u16> {
    if bytes.is_empty() {
        return Some(0);
    }
    bytes.iter().try_fold(0u16, |value, byte| {
        byte.is_ascii_digit()
            .then_some(())
            .and_then(|()| value.checked_mul(10))
            .and_then(|value| value.checked_add(u16::from(*byte - b'0')))
    })
}

fn fast_sgr_prefix(bytes: &[u8]) -> Option<(usize, sgr::Attribute<'static>)> {
    let body = bytes.strip_prefix(b"\x1B[")?;
    let end = body.iter().take(12).position(|&byte| byte == b'm')?;
    let params = &body[..end];
    let attribute = if params.contains(&b';') {
        let mut parts = params.split(|&byte| byte == b';');
        let kind = parse_sgr_decimal(parts.next()?)?;
        let mode = parse_sgr_decimal(parts.next()?)?;
        let value = parse_sgr_decimal(parts.next()?)?;
        if parts.next().is_some() || mode != 5 || value > u16::from(u8::MAX) {
            return None;
        }
        match kind {
            38 => sgr::Attribute::Fg256(value as u8),
            48 => sgr::Attribute::Bg256(value as u8),
            58 => sgr::Attribute::UnderlineColor256(value as u8),
            _ => return None,
        }
    } else {
        simple_sgr_attribute(parse_sgr_decimal(params)?)?
    };
    Some((2 + end + 1, attribute))
}

#[derive(Debug)]
pub struct Stream<H> {
    parser: Parser,
    utf8: Utf8Decoder,
    pub handler: H,
}

impl<H: Handler> Stream<H> {
    pub fn new(handler: H) -> Self {
        Self {
            parser: Parser::new(),
            utf8: Utf8Decoder::default(),
            handler,
        }
    }

    pub fn next_slice(&mut self, bytes: &[u8]) {
        let mut index = 0;
        while index < bytes.len() {
            if self.parser.state() == crate::parser::State::Ground && !self.utf8.is_pending() {
                if let Some((consumed, attribute)) = fast_sgr_prefix(&bytes[index..]) {
                    self.handler.interrupt_grapheme_run();
                    self.handler.set_attribute(attribute);
                    self.handler.sgr_sequence_end();
                    index += consumed;
                    continue;
                }
                let run_start = index;
                while index < bytes.len() && matches!(bytes[index], 0x20..=0x7E) {
                    index += 1;
                }
                if index - run_start >= 2 {
                    self.handler.print_run(&bytes[run_start..index]);
                    continue;
                }
                index = run_start;
            }

            // ghostty: stream.zig:520 — decode complete Ground-state UTF-8
            // spans together. Invalid or slice-split sequences retain the
            // scalar decoder's retry and pending-byte behavior unchanged.
            if self.parser.state() == crate::parser::State::Ground
                && !self.utf8.is_pending()
                && bytes[index] >= 0x80
            {
                let utf8_start = index;
                while index < bytes.len() && bytes[index] >= 0x80 {
                    index += 1;
                }
                let span_end = index;
                let mut cursor = utf8_start;
                while cursor < span_end {
                    if self.utf8.is_pending() {
                        self.next(bytes[cursor]);
                        cursor += 1;
                        continue;
                    }
                    match std::str::from_utf8(&bytes[cursor..span_end]) {
                        Ok(text) => {
                            for cp in text.chars() {
                                self.handle_codepoint(cp);
                            }
                            cursor = span_end;
                        }
                        Err(error) => {
                            let valid_end = cursor + error.valid_up_to();
                            if valid_end > cursor {
                                if let Ok(valid) = std::str::from_utf8(&bytes[cursor..valid_end]) {
                                    for cp in valid.chars() {
                                        self.handle_codepoint(cp);
                                    }
                                }
                            }
                            cursor = valid_end;
                            let invalid_len = error
                                .error_len()
                                .unwrap_or_else(|| span_end.saturating_sub(cursor));
                            let invalid_end = cursor.saturating_add(invalid_len).min(span_end);
                            while cursor < invalid_end {
                                self.next(bytes[cursor]);
                                cursor += 1;
                            }
                        }
                    }
                }
                continue;
            }

            self.next(bytes[index]);
            index += 1;
        }
    }

    pub fn next(&mut self, byte: u8) {
        if self.parser.state() == crate::parser::State::Ground
            && (self.utf8.is_pending() || byte >= 0x80)
        {
            self.feed_utf8(byte);
            return;
        }
        self.feed_parser(byte);
    }

    fn feed_utf8(&mut self, byte: u8) {
        // ghostty: stream.zig:596 — a rejected byte is retried against the
        // UTF-8 decoder exactly once; it must not go to the parser directly.
        let (decoded, consumed) = self.utf8.next(byte);
        if let Some(decoded) = decoded {
            self.handle_codepoint(decoded);
        }
        if !consumed {
            let (retry_decoded, retry_consumed) = self.utf8.next(byte);
            debug_assert!(retry_consumed, "utf8 decoder must consume a byte on retry");
            if let Some(decoded) = retry_decoded {
                self.handle_codepoint(decoded);
            }
        }
    }

    /// ghostty: stream.zig:624 — rejected UTF-8 can surface C0/ESC as
    /// codepoints, so route those through terminal control handling.
    fn handle_codepoint(&mut self, cp: char) {
        let value = cp as u32;
        if value <= 0xF {
            self.handler.execute(value as u8);
        } else if value == 0x1B {
            self.feed_parser(0x1B);
        } else {
            self.handler.print(cp);
        }
    }

    fn feed_parser(&mut self, byte: u8) {
        let actions = self.parser.next(byte);
        let handler = &mut self.handler;
        for action in actions.into_iter().flatten() {
            Self::dispatch_action(handler, action);
        }
    }

    fn dispatch_action(handler: &mut H, action: ParserAction<'_>) {
        if !matches!(action, ParserAction::Print(_)) {
            handler.interrupt_grapheme_run();
        }
        match action {
            ParserAction::Print(cp) => handler.print(cp),
            ParserAction::Execute(byte) => handler.execute(byte),
            ParserAction::CsiDispatch(csi) => Self::dispatch_csi(handler, csi),
            ParserAction::EscDispatch(esc) => Self::dispatch_esc(handler, esc),
            ParserAction::OscDispatch(command) => Self::dispatch_osc(handler, command),
            ParserAction::DcsHook(dcs) => handler.dcs_hook(dcs),
            ParserAction::DcsPut(byte) => handler.dcs_put(byte),
            ParserAction::DcsUnhook => handler.dcs_unhook(),
            ParserAction::ApcStart => handler.apc_start(),
            ParserAction::ApcPut(byte) => handler.apc_put(byte),
            ParserAction::ApcEnd => handler.apc_end(),
        }
    }

    fn dispatch_osc(handler: &mut H, command: crate::osc::Command<'_>) {
        match command {
            crate::osc::Command::ChangeWindowTitle(value) => {
                if let Ok(title) = std::str::from_utf8(value) {
                    handler.window_title(title);
                }
            }
            crate::osc::Command::ChangeWindowIcon(value) => {
                if let Ok(title) = std::str::from_utf8(value) {
                    handler.window_icon(title);
                }
            }
            crate::osc::Command::SemanticPrompt(cmd) => handler.semantic_prompt(cmd),
            crate::osc::Command::ReportPwd { value } => handler.report_pwd(value),
            crate::osc::Command::MouseShape { value } => handler.mouse_shape(value),
            crate::osc::Command::ColorOperation {
                kind,
                requests,
                terminator,
            } => handler.color_operation(kind, requests, terminator),
            crate::osc::Command::KittyColorProtocol {
                requests,
                terminator,
            } => handler.kitty_color_protocol(requests, terminator),
            crate::osc::Command::HyperlinkStart { id, uri } => {
                handler.start_hyperlink(id, uri);
            }
            crate::osc::Command::HyperlinkEnd => handler.end_hyperlink(),
            _ => {}
        }
    }

    fn dispatch_esc(handler: &mut H, esc: Esc<'_>) {
        match (esc.intermediates, esc.final_byte) {
            (b"", b'7') => handler.save_cursor(),
            (b"", b'8') => handler.restore_cursor(),
            (b"", b'D') => handler.index(),
            (b"", b'E') => handler.next_line(),
            (b"", b'M') => handler.reverse_index(),
            (b"", b'H') => handler.tab_set(),
            // ghostty: stream.zig:2227 (SS2 — single shift G2 into GL for one char)
            (b"", b'N') => handler.invoke_charset(ActiveSlot::Gl, CharsetSlots::G2, true),
            // ghostty: stream.zig:2241 (SS3 — single shift G3 into GL for one char)
            (b"", b'O') => handler.invoke_charset(ActiveSlot::Gl, CharsetSlots::G3, true),
            // ghostty: stream.zig:2351 (DECKPAM — application keypad)
            (b"", b'=') => handler.set_mode(Mode::KeypadKeys),
            // ghostty: stream.zig:2360 (DECKPNM — normal keypad)
            (b"", b'>') => handler.reset_mode(Mode::KeypadKeys),
            (b"", b'c') => handler.full_reset(),
            (b"#", b'8') => handler.decaln(),
            (b"(", final_byte) => Self::dispatch_charset(handler, CharsetSlots::G0, final_byte),
            (b")", final_byte) => Self::dispatch_charset(handler, CharsetSlots::G1, final_byte),
            (b"*", final_byte) => Self::dispatch_charset(handler, CharsetSlots::G2, final_byte),
            (b"+", final_byte) => Self::dispatch_charset(handler, CharsetSlots::G3, final_byte),
            (b"%", b'G') => handler.configure_charset(CharsetSlots::G0, Charset::Utf8),
            // ghostty: stream.zig:2281 (LS2 — locking shift, not single)
            (b"", b'n') => handler.invoke_charset(ActiveSlot::Gl, CharsetSlots::G2, false),
            // ghostty: stream.zig:2295 (LS3 — locking shift, not single)
            (b"", b'o') => handler.invoke_charset(ActiveSlot::Gl, CharsetSlots::G3, false),
            _ => {}
        }
    }

    fn dispatch_csi(handler: &mut H, csi: Csi<'_>) {
        match csi.final_byte {
            b'@' => Self::dispatch_insert_blanks(handler, csi),
            // ghostty: stream.zig:810 (`k` is a CUU alias)
            b'A' | b'k' => {
                Self::dispatch_single_count(handler, csi, |handler, value| handler.cursor_up(value))
            }
            b'B' => Self::dispatch_single_count(handler, csi, |handler, value| {
                handler.cursor_down(value)
            }),
            b'C' => Self::dispatch_single_count(handler, csi, |handler, value| {
                handler.cursor_right(value)
            }),
            // ghostty: stream.zig:876 (`j` is a CUB alias)
            b'D' | b'j' => Self::dispatch_single_count(handler, csi, |handler, value| {
                handler.cursor_left(value)
            }),
            b'E' => Self::dispatch_single_count(handler, csi, |handler, value| {
                // ghostty: stream.zig:896 — CNL is cursor_down + carriage_return;
                // it clamps at the scroll region bottom instead of scrolling.
                handler.cursor_down(value);
                handler.execute(b'\r');
            }),
            b'F' => Self::dispatch_single_count(handler, csi, |handler, value| {
                // ghostty: stream.zig:919 — CPL is cursor_up + carriage_return.
                handler.cursor_up(value);
                handler.execute(b'\r');
            }),
            b'G' | b'`' => Self::dispatch_single_count(handler, csi, |handler, value| {
                handler.cursor_col(value)
            }),
            b'H' | b'f' => Self::dispatch_cursor_position(handler, csi),
            b'I' => Self::dispatch_usize_count_raw(handler, csi, |handler, value| {
                // ghostty: stream.zig:989 (CHT); count loop mirrors
                // termio/stream_handler.zig:586.
                handler.horizontal_tab(value)
            }),
            b'J' => Self::dispatch_erase_display(handler, csi),
            b'K' => Self::dispatch_erase_line(handler, csi),
            b'L' => Self::dispatch_usize_count_raw(handler, csi, |handler, value| {
                // ghostty: stream.zig:1079 (IL)
                handler.insert_lines(value)
            }),
            b'M' => Self::dispatch_usize_count_raw(handler, csi, |handler, value| {
                // ghostty: stream.zig:1097 (DL)
                handler.delete_lines(value)
            }),
            b'P' => Self::dispatch_usize_count_raw(handler, csi, |handler, value| {
                // ghostty: stream.zig:1114 (DCH)
                handler.delete_chars(value)
            }),
            b'S' => {
                Self::dispatch_usize_count_raw(handler, csi, |handler, value| {
                    // ghostty: stream.zig:1132 (SU)
                    handler.scroll_up(value)
                })
            }
            b'T' => Self::dispatch_usize_count_raw(handler, csi, |handler, value| {
                // ghostty: stream.zig:1149 (SD)
                handler.scroll_down(value)
            }),
            b'W' => Self::dispatch_tab_set_clear(handler, csi),
            b'X' => Self::dispatch_usize_count(handler, csi, |handler, value| {
                handler.erase_chars(value)
            }),
            b'Z' => Self::dispatch_usize_count_raw(handler, csi, |handler, value| {
                // ghostty: stream.zig:1230 (CBT)
                handler.horizontal_tab_back(value)
            }),
            b'a' => Self::dispatch_single_count(handler, csi, |handler, value| {
                handler.cursor_col_relative(value)
            }),
            b'b' => Self::dispatch_usize_count(handler, csi, |handler, value| {
                handler.print_repeat(value)
            }),
            b'c' => Self::dispatch_device_attributes(handler, csi),
            b'd' => Self::dispatch_single_count(handler, csi, |handler, value| {
                handler.cursor_row(value)
            }),
            b'e' => Self::dispatch_single_count(handler, csi, |handler, value| {
                handler.cursor_row_relative(value)
            }),
            b'g' => Self::dispatch_tab_clear(handler, csi),
            b'h' => Self::dispatch_mode_set_reset(handler, csi, true),
            b'l' => Self::dispatch_mode_set_reset(handler, csi, false),
            b'm' => Self::dispatch_sgr(handler, csi),
            b'n' => Self::dispatch_device_status(handler, csi),
            b'p' => Self::dispatch_decrqm(handler, csi),
            b'q' => Self::dispatch_q(handler, csi),
            b'r' => Self::dispatch_r(handler, csi),
            b's' => Self::dispatch_s(handler, csi),
            b't' => Self::dispatch_t(handler, csi),
            b'u' => Self::dispatch_u(handler, csi),
            _ => {}
        }
    }

    fn dispatch_charset(handler: &mut H, slot: CharsetSlots, final_byte: u8) {
        let charset = match final_byte {
            b'B' => Charset::Ascii,
            b'0' => Charset::DecSpecial,
            b'A' => Charset::British,
            _ => return,
        };
        handler.configure_charset(slot, charset);
    }

    fn dispatch_single_count(handler: &mut H, csi: Csi<'_>, action: fn(&mut H, u16)) {
        if !csi.intermediates.is_empty() || csi.params.len() > 1 {
            return;
        }
        action(handler, count_param(csi.params.first().copied()));
    }

    fn dispatch_usize_count(handler: &mut H, csi: Csi<'_>, action: fn(&mut H, usize)) {
        if !csi.intermediates.is_empty() || csi.params.len() > 1 {
            return;
        }
        action(
            handler,
            usize::from(count_param(csi.params.first().copied())),
        );
    }

    fn dispatch_usize_count_raw(handler: &mut H, csi: Csi<'_>, action: fn(&mut H, usize)) {
        if !csi.intermediates.is_empty() || csi.params.len() > 1 {
            return;
        }
        action(
            handler,
            usize::from(raw_count_param(csi.params.first().copied())),
        );
    }

    fn dispatch_insert_blanks(handler: &mut H, csi: Csi<'_>) {
        if !csi.intermediates.is_empty() || csi.params.len() > 1 {
            return;
        }
        handler.insert_blanks(usize::from(count_param(csi.params.first().copied())));
    }

    fn dispatch_cursor_position(handler: &mut H, csi: Csi<'_>) {
        if !csi.intermediates.is_empty() || csi.params.len() > 2 {
            return;
        }
        let row = count_param(csi.params.first().copied());
        let col = count_param(csi.params.get(1).copied());
        handler.cursor_position(row, col);
    }

    fn dispatch_erase_display(handler: &mut H, csi: Csi<'_>) {
        let protected = match csi.intermediates {
            b"" => false,
            b"?" => true,
            _ => return,
        };
        if csi.params.len() > 1 {
            return;
        }
        let mode = match csi.params.first().copied().unwrap_or(0) {
            0 => EraseDisplay::Below,
            1 => EraseDisplay::Above,
            2 => EraseDisplay::Complete,
            3 => EraseDisplay::Scrollback,
            _ => return,
        };
        handler.erase_display(mode, protected);
    }

    fn dispatch_erase_line(handler: &mut H, csi: Csi<'_>) {
        let protected = match csi.intermediates {
            b"" => false,
            b"?" => true,
            _ => return,
        };
        if csi.params.len() > 1 {
            return;
        }
        let mode = match csi.params.first().copied().unwrap_or(0) {
            0 => EraseLine::Right,
            1 => EraseLine::Left,
            2 => EraseLine::Complete,
            _ => return,
        };
        handler.erase_line(mode, protected);
    }

    fn dispatch_mode_set_reset(handler: &mut H, csi: Csi<'_>, set: bool) {
        let ansi = match csi.intermediates {
            b"" => true,
            b"?" => false,
            _ => return,
        };
        for value in csi.params {
            if let Some(mode) = mode_from_int(*value, ansi) {
                if set {
                    handler.set_mode(mode);
                } else {
                    handler.reset_mode(mode);
                }
            }
        }
    }

    fn dispatch_sgr(handler: &mut H, csi: Csi<'_>) {
        if csi.intermediates == b">" {
            if csi.params.len() == 2 && csi.params[0] == 4 {
                match csi.params[1] {
                    0 => handler.modify_other_keys_2(false),
                    2 => handler.modify_other_keys_2(true),
                    _ => {}
                }
            }
            return;
        }
        if !csi.intermediates.is_empty() {
            return;
        }
        if csi.params_sep.is_empty() {
            let fast_attribute = match csi.params {
                [] | [0] => Some(sgr::Attribute::Unset),
                [1] => Some(sgr::Attribute::Bold),
                [2] => Some(sgr::Attribute::Faint),
                [3] => Some(sgr::Attribute::Italic),
                [4] => Some(sgr::Attribute::Underline(sgr::Underline::Single)),
                [5 | 6] => Some(sgr::Attribute::Blink),
                [7] => Some(sgr::Attribute::Inverse),
                [8] => Some(sgr::Attribute::Invisible),
                [9] => Some(sgr::Attribute::Strikethrough),
                [21] => Some(sgr::Attribute::Underline(sgr::Underline::Double)),
                [22] => Some(sgr::Attribute::ResetBold),
                [23] => Some(sgr::Attribute::ResetItalic),
                [24] => Some(sgr::Attribute::Underline(sgr::Underline::None)),
                [25] => Some(sgr::Attribute::ResetBlink),
                [27] => Some(sgr::Attribute::ResetInverse),
                [28] => Some(sgr::Attribute::ResetInvisible),
                [29] => Some(sgr::Attribute::ResetStrikethrough),
                [value @ 30..=37] => {
                    Some(sgr::Attribute::Fg8(crate::color::Name((*value - 30) as u8)))
                }
                [39] => Some(sgr::Attribute::ResetFg),
                [value @ 40..=47] => {
                    Some(sgr::Attribute::Bg8(crate::color::Name((*value - 40) as u8)))
                }
                [49] => Some(sgr::Attribute::ResetBg),
                [53] => Some(sgr::Attribute::Overline),
                [55] => Some(sgr::Attribute::ResetOverline),
                [59] => Some(sgr::Attribute::ResetUnderlineColor),
                [value @ 90..=97] => Some(sgr::Attribute::BrightFg8(crate::color::Name(
                    (*value - 82) as u8,
                ))),
                [value @ 100..=107] => Some(sgr::Attribute::BrightBg8(crate::color::Name(
                    (*value - 92) as u8,
                ))),
                [38, 5, value] => Some(sgr::Attribute::Fg256(*value as u8)),
                [48, 5, value] => Some(sgr::Attribute::Bg256(*value as u8)),
                [58, 5, value] => Some(sgr::Attribute::UnderlineColor256(*value as u8)),
                _ => None,
            };
            if let Some(attribute) = fast_attribute {
                handler.set_attribute(attribute);
                handler.sgr_sequence_end();
                return;
            }
        }
        let mut parser = sgr::Parser::new(csi.params, csi.params_sep);
        while let Some(attribute) = parser.next() {
            handler.set_attribute(attribute);
        }
        handler.sgr_sequence_end();
    }

    fn dispatch_decrqm(handler: &mut H, csi: Csi<'_>) {
        if csi.params.len() != 1 {
            return;
        }
        let tag = match csi.intermediates {
            b"$" => ModeTag::new(csi.params[0], true),
            b"?$" => ModeTag::new(csi.params[0], false),
            _ => return,
        };
        handler.request_mode_report(tag);
    }

    fn dispatch_q(handler: &mut H, csi: Csi<'_>) {
        match csi.intermediates {
            b">" => {
                if csi.params.len() > 1 || csi.params.first().copied().unwrap_or(0) != 0 {
                    return;
                }
                handler.xtversion();
            }
            b"\"" => {
                if csi.params.len() > 1 {
                    return;
                }
                let mode = match csi.params.first().copied().unwrap_or(0) {
                    0 | 2 => ProtectedMode::Off,
                    1 => ProtectedMode::Dec,
                    3 => ProtectedMode::Iso,
                    _ => return,
                };
                handler.protected_mode(mode);
            }
            b" " => {
                if csi.params.len() > 1 {
                    return;
                }
                let style = match csi.params.first().copied().unwrap_or(0) {
                    0 => CursorStyle::Default,
                    1 => CursorStyle::BlinkingBlock,
                    2 => CursorStyle::SteadyBlock,
                    3 => CursorStyle::BlinkingUnderline,
                    4 => CursorStyle::SteadyUnderline,
                    5 => CursorStyle::BlinkingBar,
                    6 => CursorStyle::SteadyBar,
                    _ => return,
                };
                handler.cursor_style(style);
            }
            _ => {}
        }
    }

    fn dispatch_device_status(handler: &mut H, csi: Csi<'_>) {
        if csi.params.len() != 1 {
            return;
        }
        let question = match csi.intermediates {
            b"" => false,
            b"?" => true,
            _ => return,
        };
        if let Some(request) = device_status::Request::from_int(csi.params[0], question) {
            handler.device_status(request);
        }
    }

    fn dispatch_device_attributes(handler: &mut H, csi: Csi<'_>) {
        if csi.params.len() > 1 || csi.params.first().copied().unwrap_or(0) != 0 {
            return;
        }
        let req = match csi.intermediates {
            b"" => device_attributes::Req::Primary,
            b">" => device_attributes::Req::Secondary,
            b"=" => device_attributes::Req::Tertiary,
            _ => return,
        };
        handler.device_attributes(req);
    }

    fn dispatch_r(handler: &mut H, csi: Csi<'_>) {
        match csi.intermediates {
            b"?" => {
                for value in csi.params {
                    if let Some(mode) = mode_from_int(*value, false) {
                        handler.restore_mode(mode);
                    }
                }
            }
            b"" => {
                if csi.params.len() > 2 {
                    return;
                }
                // ghostty: stream.zig:1656 — DECSTBM params pass through raw
                // and default to 0 when missing, so the setter's bottom==0
                // reset path handles `ESC[r` (full reset).
                let top = csi.params.first().copied().unwrap_or(0);
                let bottom = csi.params.get(1).copied().unwrap_or(0);
                handler.top_and_bottom_margin(top, bottom);
            }
            _ => {}
        }
    }

    fn dispatch_s(handler: &mut H, csi: Csi<'_>) {
        match csi.intermediates {
            b"" => match csi.params.len() {
                // ghostty: stream.zig:1698 — zero params is ambiguous between
                // DECSLRM and SCOSC; the handler resolves it via mode 69.
                0 => handler.left_and_right_margin_ambiguous(),
                1 => handler.left_and_right_margin(csi.params[0], 0),
                2 => handler.left_and_right_margin(csi.params[0], csi.params[1]),
                _ => {}
            },
            b"?" => {
                for value in csi.params {
                    if let Some(mode) = mode_from_int(*value, false) {
                        handler.save_mode(mode);
                    }
                }
            }
            b">" => {
                if csi.params.len() > 1 {
                    return;
                }
                match csi.params.first().copied().unwrap_or(0) {
                    0 => handler.mouse_shift_capture(false),
                    1 => handler.mouse_shift_capture(true),
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn dispatch_t(handler: &mut H, csi: Csi<'_>) {
        if !csi.intermediates.is_empty() || csi.params.is_empty() {
            return;
        }
        match csi.params[0] {
            14 if csi.params.len() == 1 => handler.size_report(SizeReportStyle::Csi14T),
            16 if csi.params.len() == 1 => handler.size_report(SizeReportStyle::Csi16T),
            18 if csi.params.len() == 1 => handler.size_report(SizeReportStyle::Csi18T),
            21 if csi.params.len() == 1 => handler.size_report(SizeReportStyle::Csi21T),
            22 => {
                if let Some(index) = title_stack_index(csi.params) {
                    handler.title_push(index);
                }
            }
            23 => {
                if let Some(index) = title_stack_index(csi.params) {
                    handler.title_pop(index);
                }
            }
            _ => {}
        }
    }

    fn dispatch_u(handler: &mut H, csi: Csi<'_>) {
        match csi.intermediates {
            b"" if csi.params.is_empty() => handler.restore_cursor(),
            // ghostty: stream.zig:1832-1883
            b"?" if csi.params.is_empty() => handler.kitty_keyboard_query(),
            b">" if csi.params.len() <= 1 => {
                let flags = csi.params.first().copied().unwrap_or(0);
                if flags <= 0x1f {
                    handler.kitty_keyboard_push(KittyFlags::from_bits(flags as u8));
                }
            }
            b"<" if csi.params.len() <= 1 => {
                handler.kitty_keyboard_pop(count_param(csi.params.first().copied()));
            }
            b"=" if csi.params.len() <= 2 => {
                let flags = csi.params.first().copied().unwrap_or(0);
                if flags > 0x1f {
                    return;
                }
                let flags = KittyFlags::from_bits(flags as u8);
                match csi.params.get(1).copied().unwrap_or(1) {
                    1 => handler.kitty_keyboard_set(flags),
                    2 => handler.kitty_keyboard_set_or(flags),
                    3 => handler.kitty_keyboard_set_not(flags),
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn dispatch_tab_set_clear(handler: &mut H, csi: Csi<'_>) {
        match csi.intermediates {
            b"" if csi.params.len() <= 1 => match csi.params.first().copied().unwrap_or(0) {
                0 => handler.tab_set(),
                2 => handler.tab_clear_current(),
                5 => handler.tab_clear_all(),
                _ => {}
            },
            b"?" if csi.params.len() == 1 && csi.params[0] == 5 => handler.tab_reset(),
            _ => {}
        }
    }

    fn dispatch_tab_clear(handler: &mut H, csi: Csi<'_>) {
        if !csi.intermediates.is_empty() || csi.params.len() > 1 {
            return;
        }
        match csi.params.first().copied().unwrap_or(0) {
            0 => handler.tab_clear_current(),
            3 => handler.tab_clear_all(),
            _ => {}
        }
    }
}

fn count_param(value: Option<u16>) -> u16 {
    match value {
        Some(0) | None => 1,
        Some(value) => value,
    }
}

/// ghostty: stream.zig:1114 and sibling raw-count CSI dispatches pass
/// params[0] through raw (missing → 1). An explicit 0 must reach the terminal
/// layer so its own zero guards apply (e.g. `CSI 0 P` is a no-op).
fn raw_count_param(value: Option<u16>) -> u16 {
    value.unwrap_or(1)
}

fn title_stack_index(params: &[u16]) -> Option<u16> {
    let target = params.get(1).copied().unwrap_or(0);
    if target == 1 {
        return None;
    }
    if target != 0 && target != 2 {
        return None;
    }
    Some(params.get(2).copied().unwrap_or(0))
}

impl<H: Handler + Default> Default for Stream<H> {
    fn default() -> Self {
        Self::new(H::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::modes::Mode;
    use std::time::{Duration, Instant};

    fn chunked_printed(bytes: &[u8], chunk_size: usize) -> (Vec<char>, Duration) {
        let started = Instant::now();
        let mut stream = Stream::new(RecordingHandler::default());
        for chunk in bytes.chunks(chunk_size) {
            stream.next_slice(chunk);
        }
        (stream.handler.printed, started.elapsed())
    }

    fn bytewise_printed(bytes: &[u8]) -> Vec<char> {
        let mut stream = Stream::new(RecordingHandler::default());
        for byte in bytes {
            stream.next(*byte);
        }
        stream.handler.printed
    }

    #[test]
    fn fast_sgr_prefix_accepts_only_complete_unambiguous_sequences() {
        assert_eq!(
            fast_sgr_prefix(b"\x1B[31mtext"),
            Some((5, sgr::Attribute::Fg8(crate::color::Name(1))))
        );
        assert_eq!(
            fast_sgr_prefix(b"\x1B[38;5;196mtext"),
            Some((11, sgr::Attribute::Fg256(196)))
        );
        assert_eq!(fast_sgr_prefix(b"\x1B[38;5;196"), None);
        assert_eq!(fast_sgr_prefix(b"\x1B[1;31m"), None);
        assert_eq!(fast_sgr_prefix(b"\x1B[38:5:196m"), None);
    }

    #[derive(Default)]
    struct RecordingHandler {
        printed: Vec<char>,
        cursor_right: u16,
        cursor_down_calls: usize,
        mode: Option<Mode>,
        reset_mode_seen: bool,
        restore_mode_seen: bool,
        kitty_pop: u16,
        protected: Option<ProtectedMode>,
        erase_display: Option<(EraseDisplay, bool)>,
        erase_line: Option<(EraseLine, bool)>,
        cursor_style: Option<CursorStyle>,
        mouse_shift_capture: Option<bool>,
        window_title_seen: bool,
        insert_blanks: Option<usize>,
        delete_chars: Option<usize>,
        left_right_margin: Vec<(u16, u16)>,
        left_right_ambiguous: bool,
        top_bottom_margin: Vec<(u16, u16)>,
        restore_cursor: bool,
        size_report: Option<SizeReportStyle>,
        title_push: Option<u16>,
        title_pop: Option<u16>,
        invoke_charset: Vec<(ActiveSlot, CharsetSlots, bool)>,
        tab_action: Option<&'static str>,
        set_attribute_called: bool,
        dcs_hooked: bool,
        dcs_bytes: Vec<u8>,
        dcs_unhooked: bool,
        apc_started: bool,
        apc_bytes: Vec<u8>,
        apc_ended: bool,
    }

    impl Handler for RecordingHandler {
        fn print(&mut self, cp: char) {
            self.printed.push(cp);
        }

        fn cursor_right(&mut self, value: u16) {
            self.cursor_right = value;
        }

        fn cursor_down(&mut self, _value: u16) {
            self.cursor_down_calls += 1;
        }

        fn set_mode(&mut self, mode: Mode) {
            self.mode = Some(mode);
        }

        fn reset_mode(&mut self, mode: Mode) {
            self.mode = Some(mode);
            self.reset_mode_seen = true;
        }

        fn restore_mode(&mut self, mode: Mode) {
            self.mode = Some(mode);
            self.restore_mode_seen = true;
        }

        fn kitty_keyboard_pop(&mut self, count: u16) {
            self.kitty_pop = count;
        }

        fn protected_mode(&mut self, mode: ProtectedMode) {
            self.protected = Some(mode);
        }

        fn erase_display(&mut self, mode: EraseDisplay, protected: bool) {
            self.erase_display = Some((mode, protected));
        }

        fn erase_line(&mut self, mode: EraseLine, protected: bool) {
            self.erase_line = Some((mode, protected));
        }

        fn cursor_style(&mut self, style: CursorStyle) {
            self.cursor_style = Some(style);
        }

        fn mouse_shift_capture(&mut self, enabled: bool) {
            self.mouse_shift_capture = Some(enabled);
        }

        fn window_title(&mut self, _title: &str) {
            self.window_title_seen = true;
        }

        fn insert_blanks(&mut self, value: usize) {
            self.insert_blanks = Some(value);
        }

        fn delete_chars(&mut self, value: usize) {
            self.delete_chars = Some(value);
        }

        fn left_and_right_margin(&mut self, left: u16, right: u16) {
            self.left_right_margin.push((left, right));
        }

        fn left_and_right_margin_ambiguous(&mut self) {
            self.left_right_ambiguous = true;
        }

        fn top_and_bottom_margin(&mut self, top: u16, bottom: u16) {
            self.top_bottom_margin.push((top, bottom));
        }

        fn restore_cursor(&mut self) {
            self.restore_cursor = true;
        }

        fn size_report(&mut self, style: SizeReportStyle) {
            self.size_report = Some(style);
        }

        fn title_push(&mut self, index: u16) {
            self.title_push = Some(index);
        }

        fn title_pop(&mut self, index: u16) {
            self.title_pop = Some(index);
        }

        fn tab_set(&mut self) {
            self.tab_action = Some("set");
        }

        fn tab_clear_current(&mut self) {
            self.tab_action = Some("clear_current");
        }

        fn tab_clear_all(&mut self) {
            self.tab_action = Some("clear_all");
        }

        fn tab_reset(&mut self) {
            self.tab_action = Some("reset");
        }

        fn invoke_charset(&mut self, active: ActiveSlot, slot: CharsetSlots, single: bool) {
            self.invoke_charset.push((active, slot, single));
        }

        fn set_attribute(&mut self, _attribute: sgr::Attribute<'_>) {
            self.set_attribute_called = true;
        }

        fn dcs_hook(&mut self, _dcs: Dcs<'_>) {
            self.dcs_hooked = true;
        }

        fn dcs_put(&mut self, byte: u8) {
            self.dcs_bytes.push(byte);
        }

        fn dcs_unhook(&mut self) {
            self.dcs_unhooked = true;
        }

        fn apc_start(&mut self) {
            self.apc_started = true;
        }

        fn apc_put(&mut self, byte: u8) {
            self.apc_bytes.push(byte);
        }

        fn apc_end(&mut self) {
            self.apc_ended = true;
        }
    }

    // ghostty: "Action" (stream.zig:2380)
    #[test]
    fn stream_handler_symbols_are_reified() {
        fn accepts_handler<T: Handler>() {}
        accepts_handler::<RecordingHandler>();
        let stream = Stream::new(RecordingHandler::default());
        assert!(stream.handler.printed.is_empty());
    }

    // ghostty: "stream: print" (stream.zig:2386)
    #[test]
    fn stream_print() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next(b'x');
        assert_eq!(stream.handler.printed, ['x']);
    }

    // ghostty: "simd: print invalid utf-8" (stream.zig:2407)
    #[test]
    fn stream_print_invalid_utf8() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(&[0xFF]);
        assert_eq!(stream.handler.printed, [char::REPLACEMENT_CHARACTER]);
    }

    // ghostty: "simd: complete incomplete utf-8" (stream.zig:2428)
    #[test]
    fn stream_completes_incomplete_utf8_across_slices() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(&[0xE0]);
        assert!(stream.handler.printed.is_empty());
        stream.next_slice(&[0xA0]);
        assert!(stream.handler.printed.is_empty());
        stream.next_slice(&[0x80]);
        assert_eq!(stream.handler.printed, ['\u{800}']);
    }

    #[test]
    fn utf8_span_split_across_chunks_is_linear() {
        fn japanese_bytes(size: usize) -> Vec<u8> {
            "日".as_bytes().iter().copied().cycle().take(size).collect()
        }

        let small = japanese_bytes(64 * 1024);
        let large = japanese_bytes(256 * 1024);
        let (small_printed, small_elapsed) = chunked_printed(&small, 4096);
        let (large_printed, large_elapsed) = chunked_printed(&large, 4096);

        assert_eq!(small_printed, bytewise_printed(&small));
        assert_eq!(large_printed, bytewise_printed(&large));
        assert!(
            large_elapsed < small_elapsed.saturating_mul(6),
            "4x input took {large_elapsed:?} after {small_elapsed:?}"
        );
    }

    #[test]
    fn utf8_invalid_run_matches_bytewise() {
        let bytes = vec![0xAA; 64 * 1024];
        let (chunked, _) = chunked_printed(&bytes, 4096);
        assert_eq!(chunked, bytewise_printed(&bytes));
    }

    #[test]
    fn mless_csi_stream_is_linear() {
        fn run(sequence_count: usize) -> (usize, Duration) {
            let bytes = b"\x1B[B".repeat(sequence_count);
            let started = Instant::now();
            let mut stream = Stream::new(RecordingHandler::default());
            for chunk in bytes.chunks(4096) {
                stream.next_slice(chunk);
            }
            (stream.handler.cursor_down_calls, started.elapsed())
        }

        let (small_calls, small_elapsed) = run(64 * 1024);
        let (large_calls, large_elapsed) = run(256 * 1024);
        assert!(small_calls > 0);
        assert_eq!(large_calls, small_calls * 4);
        assert!(
            large_elapsed < small_elapsed.saturating_mul(6),
            "4x input took {large_elapsed:?} after {small_elapsed:?}"
        );
    }

    // ghostty: "stream: cursor right (CUF)" (stream.zig:2453)
    #[test]
    fn stream_cursor_right_cuf() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[C");
        assert_eq!(stream.handler.cursor_right, 1);
        stream.next_slice(b"\x1B[5C");
        assert_eq!(stream.handler.cursor_right, 5);
        stream.handler.cursor_right = 0;
        stream.next_slice(b"\x1B[5;4C");
        assert_eq!(stream.handler.cursor_right, 0);
        stream.next_slice(b"\x1B[?3C");
        assert_eq!(stream.handler.cursor_right, 0);
    }

    // ghostty: "stream: dec set mode (SM) and reset mode (RM)" (stream.zig:2485)
    #[test]
    fn stream_dec_set_and_reset_mode() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[?6h");
        assert_eq!(stream.handler.mode, Some(Mode::Origin));
        stream.next_slice(b"\x1B[?6l");
        assert_eq!(stream.handler.mode, Some(Mode::Origin));
        assert!(stream.handler.reset_mode_seen);
        stream.handler.mode = None;
        stream.next_slice(b"\x1B[6 h");
        assert_eq!(stream.handler.mode, None);
    }

    // ghostty: "stream: ansi set mode (SM) and reset mode (RM)" (stream.zig:2514)
    #[test]
    fn stream_ansi_set_and_reset_mode() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[4h");
        assert_eq!(stream.handler.mode, Some(Mode::Insert));
        stream.next_slice(b"\x1B[4l");
        assert!(stream.handler.reset_mode_seen);
        stream.handler.mode = None;
        stream.next_slice(b"\x1B[>5h");
        assert_eq!(stream.handler.mode, None);
    }

    // ghostty: "stream: ansi set mode (SM) and reset mode (RM) with unknown value" (stream.zig:2543)
    #[test]
    fn stream_ansi_unknown_mode_is_ignored() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[6h");
        assert_eq!(stream.handler.mode, None);
        stream.next_slice(b"\x1B[6l");
        assert_eq!(stream.handler.mode, None);
    }

    // ghostty: "stream: restore mode" (stream.zig:2570)
    #[test]
    fn stream_restore_mode_ignores_unknown_without_margin_dispatch() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[?42r");
        assert!(!stream.handler.restore_mode_seen);
        assert_eq!(stream.handler.mode, None);
    }

    // ghostty: "stream: pop kitty keyboard with no params defaults to 1" (stream.zig:2593)
    #[test]
    fn stream_pop_kitty_keyboard_defaults_to_one() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[<u");
        assert_eq!(stream.handler.kitty_pop, 1);
    }

    // ghostty: "stream: DECSCA" (stream.zig:2615)
    #[test]
    fn stream_decsca_protected_mode() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[\"q");
        assert_eq!(stream.handler.protected, Some(ProtectedMode::Off));
        stream.next_slice(b"\x1B[0\"q");
        assert_eq!(stream.handler.protected, Some(ProtectedMode::Off));
        stream.next_slice(b"\x1B[2\"q");
        assert_eq!(stream.handler.protected, Some(ProtectedMode::Off));
        stream.next_slice(b"\x1B[1\"q");
        assert_eq!(stream.handler.protected, Some(ProtectedMode::Dec));
    }

    // ghostty: "stream: DECED, DECSED" (stream.zig:2654)
    #[test]
    fn stream_deced_decsed() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[?J");
        assert_eq!(
            stream.handler.erase_display,
            Some((EraseDisplay::Below, true))
        );
        stream.next_slice(b"\x1B[?1J");
        assert_eq!(
            stream.handler.erase_display,
            Some((EraseDisplay::Above, true))
        );
        stream.next_slice(b"\x1B[?2J");
        assert_eq!(
            stream.handler.erase_display,
            Some((EraseDisplay::Complete, true))
        );
        stream.next_slice(b"\x1B[?3J");
        assert_eq!(
            stream.handler.erase_display,
            Some((EraseDisplay::Scrollback, true))
        );
        stream.next_slice(b"\x1B[J");
        assert_eq!(
            stream.handler.erase_display,
            Some((EraseDisplay::Below, false))
        );
        stream.next_slice(b"\x1B[>0J");
        assert_eq!(
            stream.handler.erase_display,
            Some((EraseDisplay::Below, false))
        );
    }

    // ghostty: "stream: DECEL, DECSEL" (stream.zig:2751)
    #[test]
    fn stream_decel_decsel() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[?K");
        assert_eq!(stream.handler.erase_line, Some((EraseLine::Right, true)));
        stream.next_slice(b"\x1B[?1K");
        assert_eq!(stream.handler.erase_line, Some((EraseLine::Left, true)));
        stream.next_slice(b"\x1B[?2K");
        assert_eq!(stream.handler.erase_line, Some((EraseLine::Complete, true)));
        stream.next_slice(b"\x1B[K");
        assert_eq!(stream.handler.erase_line, Some((EraseLine::Right, false)));
        stream.next_slice(b"\x1B[<1K");
        assert_eq!(stream.handler.erase_line, Some((EraseLine::Right, false)));
    }

    // ghostty: "stream: DECSCUSR" (stream.zig:2834)
    #[test]
    fn stream_decscusr() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[ q");
        assert_eq!(stream.handler.cursor_style, Some(CursorStyle::Default));
        stream.next_slice(b"\x1B[1 q");
        assert_eq!(
            stream.handler.cursor_style,
            Some(CursorStyle::BlinkingBlock)
        );
        stream.next_slice(b"\x1B[?0 q");
        assert_eq!(
            stream.handler.cursor_style,
            Some(CursorStyle::BlinkingBlock)
        );
    }

    // ghostty: "stream: DECSCUSR without space" (stream.zig:2862)
    #[test]
    fn stream_decscusr_without_space_is_ignored() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[q");
        assert_eq!(stream.handler.cursor_style, None);
        stream.next_slice(b"\x1B[1q");
        assert_eq!(stream.handler.cursor_style, None);
    }

    // ghostty: "stream: XTSHIFTESCAPE" (stream.zig:2886)
    #[test]
    fn stream_xtshiftescape() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[>2s");
        assert_eq!(stream.handler.mouse_shift_capture, None);
        stream.next_slice(b"\x1B[>s");
        assert_eq!(stream.handler.mouse_shift_capture, Some(false));
        stream.next_slice(b"\x1B[>0s");
        assert_eq!(stream.handler.mouse_shift_capture, Some(false));
        stream.next_slice(b"\x1B[>1s");
        assert_eq!(stream.handler.mouse_shift_capture, Some(true));
        stream.next_slice(b"\x1B[1 s");
        assert_eq!(stream.handler.mouse_shift_capture, Some(true));
    }

    // ghostty: "stream: change window title with invalid utf-8" (stream.zig:2920)
    #[test]
    fn stream_change_window_title_with_invalid_utf8() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B]2;abc\x1B\\");
        assert!(stream.handler.window_title_seen);

        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B]2;abc\xC0\x1B\\");
        assert!(!stream.handler.window_title_seen);
    }

    // ghostty: "stream: insert characters" (stream.zig:2950)
    #[test]
    fn stream_insert_characters() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[42@");
        assert_eq!(stream.handler.insert_blanks, Some(42));
        stream.handler.insert_blanks = None;
        stream.next_slice(b"\x1B[?42@");
        assert_eq!(stream.handler.insert_blanks, None);
    }

    // ghostty: "stream: insert characters explicit zero clamps to 1" (stream.zig:2977)
    #[test]
    fn stream_insert_characters_zero_clamps_to_one() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[0@");
        assert_eq!(stream.handler.insert_blanks, Some(1));
    }

    // ghostty: "stream: SCOSC" (stream.zig:2999)
    #[test]
    fn stream_scosc_is_ambiguous_left_right_margin() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[s");
        assert!(stream.handler.left_right_ambiguous);
    }

    // ghostty: "stream: SCORC" (stream.zig:3023)
    #[test]
    fn stream_scorc_restores_cursor() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[u");
        assert!(stream.handler.restore_cursor);
    }

    // ghostty: "stream: too many csi params" (stream.zig:3046)
    #[test]
    fn stream_too_many_csi_params_drops_dispatch() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1C");
        assert_eq!(stream.handler.cursor_right, 0);
    }

    // ghostty: "stream: csi param too long" (stream.zig:3066)
    #[test]
    fn stream_csi_param_too_long_does_not_panic() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(
            b"\x1B[111111111111111111111111111111111111111111111111111111111111111111111C",
        );
    }

    // ghostty: "stream: send report with CSI t" (stream.zig:3083)
    #[test]
    fn stream_send_report_with_csi_t() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[14t");
        assert_eq!(stream.handler.size_report, Some(SizeReportStyle::Csi14T));
        stream.next_slice(b"\x1B[16t");
        assert_eq!(stream.handler.size_report, Some(SizeReportStyle::Csi16T));
        stream.next_slice(b"\x1B[18t");
        assert_eq!(stream.handler.size_report, Some(SizeReportStyle::Csi18T));
        stream.next_slice(b"\x1B[21t");
        assert_eq!(stream.handler.size_report, Some(SizeReportStyle::Csi21T));
    }

    // ghostty: "stream: invalid CSI t" (stream.zig:3114)
    #[test]
    fn stream_invalid_csi_t_is_ignored() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[19t");
        assert_eq!(stream.handler.size_report, None);
    }

    // ghostty: "stream: CSI t push title" (stream.zig:3139)
    #[test]
    fn stream_csi_t_push_title() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[22;0t");
        assert_eq!(stream.handler.title_push, Some(0));
    }

    // ghostty: "stream: CSI t push title with explicit window" (stream.zig:3161)
    #[test]
    fn stream_csi_t_push_title_with_explicit_window() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[22;2t");
        assert_eq!(stream.handler.title_push, Some(0));
    }

    // ghostty: "stream: CSI t push title with explicit icon" (stream.zig:3183)
    #[test]
    fn stream_csi_t_push_title_with_explicit_icon_ignored() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[22;1t");
        assert_eq!(stream.handler.title_push, None);
    }

    // ghostty: "stream: CSI t push title with index" (stream.zig:3205)
    #[test]
    fn stream_csi_t_push_title_with_index() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[22;0;5t");
        assert_eq!(stream.handler.title_push, Some(5));
    }

    // ghostty: "stream: CSI t pop title" (stream.zig:3227)
    #[test]
    fn stream_csi_t_pop_title() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[23;0t");
        assert_eq!(stream.handler.title_pop, Some(0));
    }

    // ghostty: "stream: CSI t pop title with explicit window" (stream.zig:3249)
    #[test]
    fn stream_csi_t_pop_title_with_explicit_window() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[23;2t");
        assert_eq!(stream.handler.title_pop, Some(0));
    }

    // ghostty: "stream: CSI t pop title with explicit icon" (stream.zig:3271)
    #[test]
    fn stream_csi_t_pop_title_with_explicit_icon_ignored() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[23;1t");
        assert_eq!(stream.handler.title_pop, None);
    }

    // ghostty: "stream: CSI t pop title with index" (stream.zig:3293)
    #[test]
    fn stream_csi_t_pop_title_with_index() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[23;0;5t");
        assert_eq!(stream.handler.title_pop, Some(5));
    }

    // ghostty: "stream CSI W clear tab stops" (stream.zig:3315)
    #[test]
    fn stream_csi_w_clear_tab_stops() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[2W");
        assert_eq!(stream.handler.tab_action, Some("clear_current"));
        stream.next_slice(b"\x1B[5W");
        assert_eq!(stream.handler.tab_action, Some("clear_all"));
    }

    // ghostty: "stream CSI W tab set" (stream.zig:3338)
    #[test]
    fn stream_csi_w_tab_set() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[W");
        assert_eq!(stream.handler.tab_action, Some("set"));
        stream.handler.tab_action = None;
        stream.next_slice(b"\x1B[0W");
        assert_eq!(stream.handler.tab_action, Some("set"));
        stream.handler.tab_action = None;
        stream.next_slice(b"\x1B[>W");
        assert_eq!(stream.handler.tab_action, None);
        stream.next_slice(b"\x1B[99W");
        assert_eq!(stream.handler.tab_action, None);
    }

    // ghostty: "stream CSI ? W reset tab stops" (stream.zig:3370)
    #[test]
    fn stream_csi_question_w_reset_tab_stops() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[?2W");
        assert_eq!(stream.handler.tab_action, None);
        stream.next_slice(b"\x1B[?5W");
        assert_eq!(stream.handler.tab_action, Some("reset"));
        stream.handler.tab_action = None;
        stream.next_slice(b"\x1B[?1;2;3W");
        assert_eq!(stream.handler.tab_action, None);
    }

    // ghostty: "stream: SGR with 17+ parameters for underline color" (stream.zig:3398)
    #[test]
    fn stream_sgr_with_17_parameters_for_underline_color() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136;0m");
        assert!(stream.handler.set_attribute_called);
    }

    // ghostty: "stream: tab clear with overflowing param" (stream.zig:3426)
    #[test]
    fn stream_tab_clear_with_overflowing_param_does_not_panic() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[388888888888888888888888888888888888g\x1B[0m");
    }

    // port-added: DCS and APC bytes pass through the parser-owned state machine.
    #[test]
    fn stream_forwards_dcs_and_apc_passthrough() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1BP+qabc\x1B\\");
        assert!(stream.handler.dcs_hooked);
        assert_eq!(stream.handler.dcs_bytes, b"abc");
        assert!(stream.handler.dcs_unhooked);

        stream.next_slice(b"\x1B_XYZ\x1B\\");
        assert!(stream.handler.apc_started);
        assert_eq!(stream.handler.apc_bytes, b"XYZ");
        assert!(stream.handler.apc_ended);
    }

    // port-added: DECSTBM must pass missing parameters through as raw 0 so the terminal reset path runs.
    #[test]
    fn csi_r_dispatches_raw_margins() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[r");
        assert_eq!(stream.handler.top_bottom_margin, [(0, 0)]);

        stream.next_slice(b"\x1B[2;4r");
        assert_eq!(stream.handler.top_bottom_margin, [(0, 0), (2, 4)]);
    }

    // port-added: CSI s has three distinct forms; zero params is ambiguous, params are DECSLRM.
    #[test]
    fn csi_s_dispatches_margin_forms() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[2;4s");
        stream.next_slice(b"\x1B[3s");
        stream.next_slice(b"\x1B[s");

        assert_eq!(stream.handler.left_right_margin, [(2, 4), (3, 0)]);
        assert!(stream.handler.left_right_ambiguous);
    }

    // port-added: explicit zero counts must reach the terminal layer; missing counts still default to one.
    #[test]
    fn csi_zero_count_dispatches_raw() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1B[0P");
        assert_eq!(stream.handler.delete_chars, Some(0));

        stream.next_slice(b"\x1B[P");
        assert_eq!(stream.handler.delete_chars, Some(1));
    }

    // port-added: missing ESC charset shift and keypad dispatches are terminal compatibility basics.
    #[test]
    fn esc_charset_shift_and_keypad_dispatch() {
        let mut stream = Stream::new(RecordingHandler::default());
        stream.next_slice(b"\x1BN\x1Bn\x1BO\x1Bo");
        stream.next_slice(b"\x1B=");
        stream.next_slice(b"\x1B>");

        assert_eq!(
            stream.handler.invoke_charset,
            [
                (ActiveSlot::Gl, CharsetSlots::G2, true),
                (ActiveSlot::Gl, CharsetSlots::G2, false),
                (ActiveSlot::Gl, CharsetSlots::G3, true),
                (ActiveSlot::Gl, CharsetSlots::G3, false),
            ]
        );
        assert_eq!(stream.handler.mode, Some(Mode::KeypadKeys));
        assert!(stream.handler.reset_mode_seen);
    }
}
