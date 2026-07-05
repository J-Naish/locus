//! VT-series parser for escape and control sequences.
//!
//! This follows https://vt100.net/emu/dec_ansi_parser and is ported from
//! Ghostty's Parser.zig. The parser is pure state machine logic.

pub mod table;

use table::TABLE;

pub const STATE_COUNT: usize = 14;
pub const MAX_INTERMEDIATE: usize = 4;
pub const MAX_PARAMS: usize = 24;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum State {
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiIntermediate,
    CsiParam,
    CsiIgnore,
    DcsEntry,
    DcsParam,
    DcsIntermediate,
    DcsPassthrough,
    DcsIgnore,
    OscString,
    SosPmApcString,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum TransitionAction {
    None,
    Ignore,
    Print,
    Execute,
    Collect,
    Param,
    EscDispatch,
    CsiDispatch,
    Put,
    OscPut,
    ApcPut,
}

pub(crate) const fn state_from_index(index: usize) -> State {
    match index {
        0 => State::Ground,
        1 => State::Escape,
        2 => State::EscapeIntermediate,
        3 => State::CsiEntry,
        4 => State::CsiIntermediate,
        5 => State::CsiParam,
        6 => State::CsiIgnore,
        7 => State::DcsEntry,
        8 => State::DcsParam,
        9 => State::DcsIntermediate,
        10 => State::DcsPassthrough,
        11 => State::DcsIgnore,
        12 => State::OscString,
        13 => State::SosPmApcString,
        _ => panic!("invalid state index"),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SepList(u32);

impl SepList {
    pub fn set(&mut self, index: usize) {
        if index < MAX_PARAMS {
            self.0 |= 1 << index;
        }
    }

    pub fn is_set(&self, index: usize) -> bool {
        index < MAX_PARAMS && (self.0 & (1 << index)) != 0
    }

    pub fn is_empty(&self) -> bool {
        self.0 == 0
    }

    pub fn clear(&mut self) {
        self.0 = 0;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Csi<'a> {
    pub intermediates: &'a [u8],
    pub params: &'a [u16],
    pub params_sep: SepList,
    pub final_byte: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Esc<'a> {
    pub intermediates: &'a [u8],
    pub final_byte: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Dcs<'a> {
    pub intermediates: &'a [u8],
    pub params: &'a [u16],
    pub final_byte: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action<'a> {
    Print(char),
    Execute(u8),
    CsiDispatch(Csi<'a>),
    EscDispatch(Esc<'a>),
    OscDispatch(crate::osc::Command<'a>),
    DcsHook(Dcs<'a>),
    DcsPut(u8),
    DcsUnhook,
    ApcStart,
    ApcPut(u8),
    ApcEnd,
}

#[derive(Debug)]
pub struct Parser {
    state: State,
    intermediates: [u8; MAX_INTERMEDIATE],
    intermediates_len: usize,
    params: [u16; MAX_PARAMS],
    params_sep: SepList,
    params_len: usize,
    param_acc: u16,
    param_acc_digits: u8,
    osc_parser: crate::osc::Parser,
    suppress_st_final: bool,
}

enum ExitKind {
    None,
    OscEnd,
    DcsUnhook,
    ApcEnd,
}

enum TransitionKind {
    Nothing,
    Print,
    Execute,
    EmitCsi,
    EmitEsc,
    DcsPut,
    ApcPut,
}

enum EntryKind {
    None,
    ApcStart,
    DcsHook,
}

impl Parser {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            intermediates: [0; MAX_INTERMEDIATE],
            intermediates_len: 0,
            params: [0; MAX_PARAMS],
            params_sep: SepList::default(),
            params_len: 0,
            param_acc: 0,
            param_acc_digits: 0,
            osc_parser: crate::osc::Parser::default(),
            suppress_st_final: false,
        }
    }

    pub fn state(&self) -> State {
        self.state
    }

    pub fn clear(&mut self) {
        self.intermediates_len = 0;
        self.params_len = 0;
        self.params_sep.clear();
        self.param_acc = 0;
        self.param_acc_digits = 0;
    }

    pub fn collect(&mut self, byte: u8) {
        if self.intermediates_len < MAX_INTERMEDIATE {
            self.intermediates[self.intermediates_len] = byte;
            self.intermediates_len += 1;
        }
    }

    /// Consumes one byte and returns the exit, transition, and entry actions.
    ///
    /// Slices in returned actions borrow this parser and are valid only until
    /// the next call to `next`; Rust enforces that by tying the return lifetime
    /// to the mutable borrow.
    pub fn next(&mut self, byte: u8) -> [Option<Action<'_>>; 3] {
        let transition = TABLE[byte as usize][self.state as usize];
        let next_state = transition.state;
        let state_changing = next_state != self.state;

        let exit = if state_changing {
            match self.state {
                State::OscString => {
                    self.osc_parser.end(Some(byte));
                    self.suppress_st_final = byte == 0x1B;
                    ExitKind::OscEnd
                }
                State::DcsPassthrough => ExitKind::DcsUnhook,
                State::SosPmApcString => ExitKind::ApcEnd,
                _ => ExitKind::None,
            }
        } else {
            ExitKind::None
        };

        let transition_kind = self.apply_transition_action(transition.action, byte);

        let entry = if state_changing {
            match next_state {
                State::Escape | State::DcsEntry | State::CsiEntry => {
                    self.clear();
                    EntryKind::None
                }
                State::OscString => {
                    self.osc_parser.reset();
                    EntryKind::None
                }
                State::DcsPassthrough => self.finalize_dcs_hook(),
                State::SosPmApcString => EntryKind::ApcStart,
                _ => EntryKind::None,
            }
        } else {
            EntryKind::None
        };

        self.state = next_state;

        [
            self.materialize_exit(exit),
            self.materialize_transition(transition_kind, byte),
            self.materialize_entry(entry, byte),
        ]
    }

    fn apply_transition_action(&mut self, action: TransitionAction, byte: u8) -> TransitionKind {
        match action {
            TransitionAction::None | TransitionAction::Ignore => TransitionKind::Nothing,
            TransitionAction::Print => TransitionKind::Print,
            TransitionAction::Execute => TransitionKind::Execute,
            TransitionAction::Collect => {
                self.collect(byte);
                TransitionKind::Nothing
            }
            TransitionAction::Param => {
                self.apply_param(byte);
                TransitionKind::Nothing
            }
            TransitionAction::OscPut => {
                self.osc_parser.next(byte);
                TransitionKind::Nothing
            }
            TransitionAction::CsiDispatch => {
                if self.params_len >= MAX_PARAMS {
                    return TransitionKind::Nothing;
                }
                self.flush_pending_param();
                // Ghostty only accepts colon/mixed separators for SGR (`m`).
                if byte != b'm' && !self.params_sep.is_empty() {
                    TransitionKind::Nothing
                } else {
                    TransitionKind::EmitCsi
                }
            }
            TransitionAction::EscDispatch => {
                if self.suppress_st_final && byte == b'\\' {
                    self.suppress_st_final = false;
                    TransitionKind::Nothing
                } else {
                    self.suppress_st_final = false;
                    TransitionKind::EmitEsc
                }
            }
            TransitionAction::Put => TransitionKind::DcsPut,
            TransitionAction::ApcPut => TransitionKind::ApcPut,
        }
    }

    fn apply_param(&mut self, byte: u8) {
        if byte == b';' || byte == b':' {
            if self.params_len >= MAX_PARAMS {
                return;
            }
            self.params[self.params_len] = self.param_acc;
            if byte == b':' {
                self.params_sep.set(self.params_len);
            }
            self.params_len += 1;
            self.param_acc = 0;
            self.param_acc_digits = 0;
            return;
        }

        self.param_acc = self
            .param_acc
            .saturating_mul(10)
            .saturating_add(u16::from(byte - b'0'));
        self.param_acc_digits = self.param_acc_digits.saturating_add(1);
    }

    fn flush_pending_param(&mut self) {
        if self.param_acc_digits > 0 && self.params_len < MAX_PARAMS {
            self.params[self.params_len] = self.param_acc;
            self.params_len += 1;
            self.param_acc = 0;
            self.param_acc_digits = 0;
        }
    }

    fn finalize_dcs_hook(&mut self) -> EntryKind {
        if self.params_len >= MAX_PARAMS {
            return EntryKind::None;
        }
        self.flush_pending_param();
        EntryKind::DcsHook
    }

    fn materialize_exit(&self, exit: ExitKind) -> Option<Action<'_>> {
        match exit {
            ExitKind::None => None,
            ExitKind::OscEnd => self.osc_parser.command().map(Action::OscDispatch),
            ExitKind::DcsUnhook => Some(Action::DcsUnhook),
            ExitKind::ApcEnd => Some(Action::ApcEnd),
        }
    }

    fn materialize_transition(&self, transition: TransitionKind, byte: u8) -> Option<Action<'_>> {
        match transition {
            TransitionKind::Nothing => None,
            TransitionKind::Print => Some(Action::Print(byte as char)),
            TransitionKind::Execute => Some(Action::Execute(byte)),
            TransitionKind::EmitCsi => Some(Action::CsiDispatch(Csi {
                intermediates: &self.intermediates[..self.intermediates_len],
                params: &self.params[..self.params_len],
                params_sep: self.params_sep,
                final_byte: byte,
            })),
            TransitionKind::EmitEsc => Some(Action::EscDispatch(Esc {
                intermediates: &self.intermediates[..self.intermediates_len],
                final_byte: byte,
            })),
            TransitionKind::DcsPut => Some(Action::DcsPut(byte)),
            TransitionKind::ApcPut => Some(Action::ApcPut(byte)),
        }
    }

    fn materialize_entry(&self, entry: EntryKind, byte: u8) -> Option<Action<'_>> {
        match entry {
            EntryKind::None => None,
            EntryKind::ApcStart => Some(Action::ApcStart),
            EntryKind::DcsHook => Some(Action::DcsHook(Dcs {
                intermediates: &self.intermediates[..self.intermediates_len],
                params: &self.params[..self.params_len],
                final_byte: byte,
            })),
        }
    }
}

impl Default for Parser {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::{
        state_from_index, Action, Csi, Dcs, Esc, Parser, State, MAX_INTERMEDIATE, MAX_PARAMS,
        STATE_COUNT,
    };

    fn assert_no_actions(actions: [Option<Action<'_>>; 3]) {
        assert!(
            actions[0].is_none(),
            "unexpected exit action: {:?}",
            actions[0]
        );
        assert!(
            actions[1].is_none(),
            "unexpected transition action: {:?}",
            actions[1]
        );
        assert!(
            actions[2].is_none(),
            "unexpected entry action: {:?}",
            actions[2]
        );
    }

    fn feed_no_actions(parser: &mut Parser, bytes: &[u8]) {
        for byte in bytes {
            assert_no_actions(parser.next(*byte));
        }
    }

    fn expect_csi(actions: [Option<Action<'_>>; 3]) -> Csi<'_> {
        assert!(actions[0].is_none());
        assert!(actions[2].is_none());
        let Some(Action::CsiDispatch(csi)) = actions[1] else {
            panic!("expected csi dispatch, got {:?}", actions[1]);
        };
        csi
    }

    fn expect_esc(actions: [Option<Action<'_>>; 3]) -> Esc<'_> {
        assert!(actions[0].is_none());
        assert!(actions[2].is_none());
        let Some(Action::EscDispatch(esc)) = actions[1] else {
            panic!("expected esc dispatch, got {:?}", actions[1]);
        };
        esc
    }

    fn expect_dcs_hook(actions: [Option<Action<'_>>; 3]) -> Dcs<'_> {
        assert!(actions[0].is_none());
        assert!(actions[1].is_none());
        let Some(Action::DcsHook(dcs)) = actions[2] else {
            panic!("expected dcs hook, got {:?}", actions[2]);
        };
        dcs
    }

    // ghostty: unnamed parser smoke test (Parser.zig:417)
    #[test]
    fn c1_controls_reach_apc_state_and_print_and_execute_work_from_ground() {
        let mut parser = Parser::new();
        let _ = parser.next(0x9E);
        assert_eq!(parser.state(), State::SosPmApcString);
        let _ = parser.next(0x9C);
        assert_eq!(parser.state(), State::Ground);

        {
            let actions = parser.next(b'a');
            assert!(actions[0].is_none());
            assert!(matches!(actions[1], Some(Action::Print('a'))));
            assert!(actions[2].is_none());
        }
        assert_eq!(parser.state(), State::Ground);

        {
            let actions = parser.next(0x19);
            assert!(actions[0].is_none());
            assert!(matches!(actions[1], Some(Action::Execute(0x19))));
            assert!(actions[2].is_none());
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "esc: ESC ( B" (Parser.zig:441)
    #[test]
    fn esc_dispatch_captures_intermediate_for_esc_paren_b() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        let _ = parser.next(b'(');

        {
            let esc = expect_esc(parser.next(b'B'));
            assert_eq!(esc.final_byte, b'B');
            assert_eq!(esc.intermediates, b"(");
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: ESC [ H" (Parser.zig:460)
    #[test]
    fn csi_dispatch_with_no_params() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        let _ = parser.next(b'[');

        let actions = parser.next(b'H');
        assert!(actions[0].is_none());
        assert!(actions[2].is_none());
        let Some(Action::CsiDispatch(csi)) = actions[1] else {
            panic!("expected csi dispatch, got {:?}", actions[1]);
        };
        assert_eq!(csi.final_byte, b'H');
        assert!(csi.params.is_empty());
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: ESC [ 1 ; 4 H" (Parser.zig:478)
    #[test]
    fn csi_dispatch_collects_semicolon_separated_params() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        let _ = parser.next(b'[');
        let _ = parser.next(b'1');
        let _ = parser.next(b';');
        let _ = parser.next(b'4');

        {
            let csi = expect_csi(parser.next(b'H'));
            assert_eq!(csi.final_byte, b'H');
            assert_eq!(csi.params, &[1, 4]);
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: SGR ESC [ 38 : 2 m" (Parser.zig:501)
    #[test]
    fn sgr_colon_separator_sets_sep_bit() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[38:2");

        {
            let csi = expect_csi(parser.next(b'm'));
            assert_eq!(csi.final_byte, b'm');
            assert_eq!(csi.params, &[38, 2]);
            assert!(csi.params_sep.is_set(0));
            assert!(!csi.params_sep.is_set(1));
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: SGR colon followed by semicolon" (Parser.zig:527)
    #[test]
    fn sgr_colon_then_new_csi_starts_clean() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[48:2");
        {
            let _ = expect_csi(parser.next(b'm'));
        }
        assert_eq!(parser.state(), State::Ground);

        let _ = parser.next(0x1B);
        let _ = parser.next(b'[');
        {
            let _ = expect_csi(parser.next(b'H'));
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: SGR mixed colon and semicolon" (Parser.zig:556)
    #[test]
    fn sgr_mixed_colon_and_semicolon_dispatches() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[38:5:1;48:5:0");
        {
            let _ = expect_csi(parser.next(b'm'));
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: SGR ESC [ 48 : 2 m" (Parser.zig:575)
    #[test]
    fn sgr_colon_run_sets_all_leading_sep_bits() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[48:2:240:143:104");

        {
            let csi = expect_csi(parser.next(b'm'));
            assert_eq!(csi.final_byte, b'm');
            assert_eq!(csi.params, &[48, 2, 240, 143, 104]);
            for index in 0..4 {
                assert!(csi.params_sep.is_set(index));
            }
            assert!(!csi.params_sep.is_set(4));
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: SGR ESC [4:3m colon" (Parser.zig:608)
    #[test]
    fn sgr_four_colon_three_underline_style() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[4:3");

        {
            let csi = expect_csi(parser.next(b'm'));
            assert_eq!(csi.params, &[4, 3]);
            assert!(csi.params_sep.is_set(0));
            assert!(!csi.params_sep.is_set(1));
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: SGR with many blank and colon" (Parser.zig:633)
    #[test]
    fn sgr_empty_colon_param_stored_as_zero() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[58:2::240:143:104");

        {
            let csi = expect_csi(parser.next(b'm'));
            assert_eq!(csi.params, &[58, 2, 0, 240, 143, 104]);
            for index in 0..5 {
                assert!(csi.params_sep.is_set(index));
            }
            assert!(!csi.params_sep.is_set(5));
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: SGR mixed colon and semicolon with blank" (Parser.zig:669)
    #[test]
    fn sgr_kakoune_mixed_sequence_14_params() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[;4:3;38;2;175;175;215;58:2::190:80:70");

        {
            let csi = expect_csi(parser.next(b'm'));
            assert_eq!(
                csi.params,
                &[0, 4, 3, 38, 2, 175, 175, 215, 58, 2, 0, 190, 80, 70]
            );
            let colon_indices = [1, 8, 9, 10, 11, 12];
            for index in 0..14 {
                assert_eq!(
                    csi.params_sep.is_set(index),
                    colon_indices.contains(&index),
                    "separator bit {index}"
                );
            }
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: SGR mixed colon and semicolon setting underline, bg, fg" (Parser.zig:721)
    #[test]
    fn sgr_kakoune_17_param_sequence() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(
            &mut parser,
            b"[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136",
        );

        {
            let csi = expect_csi(parser.next(b'm'));
            assert_eq!(
                csi.params,
                &[4, 3, 38, 2, 51, 51, 51, 48, 2, 170, 170, 170, 58, 2, 255, 97, 136]
            );
            assert!(csi.params_sep.is_set(0));
            for index in 1..17 {
                assert!(!csi.params_sep.is_set(index), "separator bit {index}");
            }
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: colon for non-m final" (Parser.zig:778)
    #[test]
    fn csi_colon_with_non_m_final_drops_sequence() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[38:2h");
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: request mode decrqm" (Parser.zig:791)
    #[test]
    fn csi_decrqm_collects_two_intermediates() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[?2026$");

        {
            let csi = expect_csi(parser.next(b'p'));
            assert_eq!(csi.final_byte, b'p');
            assert_eq!(csi.intermediates, b"?$");
            assert_eq!(csi.params, &[2026]);
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: change cursor" (Parser.zig:818)
    #[test]
    fn csi_cursor_style_space_intermediate() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[3 ");

        {
            let csi = expect_csi(parser.next(b'q'));
            assert_eq!(csi.final_byte, b'q');
            assert_eq!(csi.intermediates, b" ");
            assert_eq!(csi.params, &[3]);
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: too many params" (Parser.zig:961)
    #[test]
    fn csi_beyond_max_params_drops_sequence() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        let _ = parser.next(b'[');
        for _ in 0..100 {
            let _ = parser.next(b'1');
            let _ = parser.next(b';');
        }
        let _ = parser.next(b'1');
        assert_no_actions(parser.next(b'C'));
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "csi: sgr with up to our max parameters" (Parser.zig:980)
    #[test]
    fn csi_dispatches_at_every_param_count_up_to_max() {
        for max in 1..=MAX_PARAMS {
            let mut parser = Parser::new();
            let _ = parser.next(0x1B);
            let _ = parser.next(b'[');
            for _ in 0..(max - 1) {
                let _ = parser.next(b'1');
                let _ = parser.next(b';');
            }
            let _ = parser.next(b'2');

            {
                let csi = expect_csi(parser.next(b'H'));
                assert_eq!(csi.params.len(), max);
                assert_eq!(csi.params[max - 1], 2);
            }
            assert_eq!(parser.state(), State::Ground);
        }
    }

    // ghostty: "csi: sgr beyond our max drops it" (Parser.zig:1006)
    #[test]
    fn csi_one_past_max_params_drops_sequence() {
        let max = MAX_PARAMS + 2;
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        let _ = parser.next(b'[');
        for _ in 0..(max - 1) {
            let _ = parser.next(b'1');
            let _ = parser.next(b';');
        }
        let _ = parser.next(b'2');

        assert_no_actions(parser.next(b'H'));
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "dcs: XTGETTCAP" (Parser.zig:1029)
    #[test]
    fn dcs_hook_carries_intermediates_for_xtgettcap() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"P+");

        {
            let dcs = expect_dcs_hook(parser.next(b'q'));
            assert_eq!(dcs.intermediates, b"+");
            assert!(dcs.params.is_empty());
            assert_eq!(dcs.final_byte, b'q');
        }
        assert_eq!(parser.state(), State::DcsPassthrough);
    }

    // ghostty: "dcs: params" (Parser.zig:1053)
    #[test]
    fn dcs_hook_carries_params() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"P1000");

        {
            let dcs = expect_dcs_hook(parser.next(b'p'));
            assert_eq!(dcs.params, &[1000]);
            assert_eq!(dcs.final_byte, b'p');
        }
        assert_eq!(parser.state(), State::DcsPassthrough);
    }

    // ghostty: "dcs: too many params" (Parser.zig:1076)
    #[test]
    fn dcs_beyond_max_params_drops_hook_without_oob() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        let _ = parser.next(b'P');
        let _ = parser.next(b'6');
        for _ in 0..MAX_PARAMS {
            let _ = parser.next(b';');
        }
        let _ = parser.next(b'7');

        assert_no_actions(parser.next(b'p'));
    }

    #[test]
    fn any_byte_in_any_state_never_panics_and_lands_in_a_valid_state() {
        for state_index in 0..STATE_COUNT {
            for byte in 0u8..=u8::MAX {
                let mut parser = Parser::new();
                parser.state = state_from_index(state_index);
                let _ = parser.next(byte);
            }
        }
    }

    #[test]
    fn random_byte_stream_never_panics() {
        let mut parser = Parser::new();
        let mut state = 0xC0DEC0DEC0DEC0DEu64;
        for _ in 0..(64 * 1024) {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let byte = (state >> 56) as u8;
            let _ = parser.next(byte);
        }
        let _ = parser.state();
    }

    #[test]
    fn param_accumulator_saturates_at_u16_max() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        feed_no_actions(&mut parser, b"[99999999");

        {
            let csi = expect_csi(parser.next(b'm'));
            assert_eq!(csi.params, &[u16::MAX]);
        }
        assert_eq!(parser.state(), State::Ground);
    }

    #[test]
    fn intermediates_beyond_max_are_dropped_but_sequence_dispatches() {
        let mut parser = Parser::new();
        let _ = parser.next(0x1B);
        for byte in [0x20, 0x21, 0x22, 0x23, 0x24] {
            let _ = parser.next(byte);
        }

        {
            let esc = expect_esc(parser.next(b'0'));
            assert_eq!(esc.intermediates.len(), MAX_INTERMEDIATE);
            assert_eq!(esc.intermediates, &[0x20, 0x21, 0x22, 0x23]);
            assert_eq!(esc.final_byte, b'0');
        }
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "osc: change window title" (Parser.zig:844)
    #[test]
    fn osc_change_window_title_ends_on_bel() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]0;abc");
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::ChangeWindowTitle(title))) = actions[0]
        else {
            panic!("expected title dispatch, got {:?}", actions[0]);
        };
        assert_eq!(title, b"abc");
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "osc: change window title (end in esc)" (Parser.zig:867)
    #[test]
    fn osc_change_window_title_ends_on_esc_st() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]0;abc");
        let actions = parser.next(0x1B);
        let Some(Action::OscDispatch(crate::osc::Command::ChangeWindowTitle(title))) = actions[0]
        else {
            panic!("expected title dispatch, got {:?}", actions[0]);
        };
        assert_eq!(title, b"abc");
        assert_no_actions(parser.next(b'\\'));
        assert_eq!(parser.state(), State::Ground);
    }

    // ghostty: "osc: 112 incomplete sequence" (Parser.zig:893)
    #[test]
    fn osc_112_incomplete_sequence_dispatches_cursor_reset() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]112");
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::ColorOperation {
            kind,
            requests,
            terminator,
        })) = actions[0]
        else {
            panic!("expected color dispatch, got {:?}", actions[0]);
        };
        assert_eq!(
            kind,
            crate::osc::parsers::color_operation::ColorOperationKind::Osc112
        );
        assert_eq!(
            requests,
            &[crate::osc::parsers::color_operation::ColorRequest::Reset(
                crate::osc::ColorTarget::Dynamic(crate::color::Dynamic::Cursor)
            )]
        );
        assert_eq!(terminator, crate::osc::Terminator::Bel);
    }

    // ghostty: "osc: 104 empty" (Parser.zig:929)
    #[test]
    fn osc_104_empty_dispatches_palette_reset() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]104");
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::ColorOperation {
            kind,
            requests,
            terminator,
        })) = actions[0]
        else {
            panic!("expected color dispatch, got {:?}", actions[0]);
        };
        assert_eq!(
            kind,
            crate::osc::parsers::color_operation::ColorOperationKind::Osc104
        );
        assert_eq!(
            requests,
            &[crate::osc::parsers::color_operation::ColorRequest::ResetPalette]
        );
        assert_eq!(terminator, crate::osc::Terminator::Bel);
    }

    #[test]
    fn osc_8_dispatches_hyperlink_start() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]8;id=abc;https://example.test");
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::HyperlinkStart { id, uri })) = actions[0]
        else {
            panic!("expected hyperlink start, got {:?}", actions[0]);
        };
        assert_eq!(id, Some(&b"abc"[..]));
        assert_eq!(uri, b"https://example.test");
    }

    #[test]
    fn osc_8_dispatches_hyperlink_end() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]8;;");
        let actions = parser.next(0x07);
        assert!(matches!(
            actions[0],
            Some(Action::OscDispatch(crate::osc::Command::HyperlinkEnd))
        ));
    }

    #[test]
    fn osc_52_dispatches_clipboard_contents() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]52;c;SGVsbG8=");
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::ClipboardContents { kind, data })) =
            actions[0]
        else {
            panic!("expected clipboard contents, got {:?}", actions[0]);
        };
        assert_eq!(kind, b'c');
        assert_eq!(data, b"SGVsbG8=");
    }

    #[test]
    fn osc_7_dispatches_report_pwd() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]7;file://host/tmp/project");
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::ReportPwd { value })) = actions[0] else {
            panic!("expected report pwd, got {:?}", actions[0]);
        };
        assert_eq!(value, b"file://host/tmp/project");
    }

    #[test]
    fn osc_66_dispatches_kitty_text_sizing() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]66;s=2:w=3:v=2:h=1;wide text");
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::KittyTextSizing(command))) = actions[0]
        else {
            panic!("expected kitty text sizing, got {:?}", actions[0]);
        };
        assert_eq!(command.scale, 2);
        assert_eq!(command.width, 3);
        assert_eq!(command.valign, crate::osc::KittyTextVAlign::Center);
        assert_eq!(command.halign, crate::osc::KittyTextHAlign::Right);
        assert_eq!(command.text, b"wide text");
    }

    #[test]
    fn osc_3008_dispatches_context_signal() {
        let mut parser = Parser::new();
        feed_no_actions(
            &mut parser,
            b"\x1b]3008;start=ctx-1;type=command;cwd=/tmp;pid=42",
        );
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::ContextSignal(command))) = actions[0]
        else {
            panic!("expected context signal, got {:?}", actions[0]);
        };
        assert_eq!(
            command.action,
            crate::osc::parsers::context_signal::ContextAction::Start
        );
        assert_eq!(command.id, b"ctx-1");
        assert_eq!(
            command.read_type(),
            Some(crate::osc::parsers::context_signal::ContextType::Command)
        );
        assert_eq!(command.read_cwd(), Some(&b"/tmp"[..]));
        assert_eq!(command.read_pid(), Some(42));
    }

    #[test]
    fn osc_1337_dispatches_iterm2_copy_as_clipboard_contents() {
        let mut parser = Parser::new();
        feed_no_actions(&mut parser, b"\x1b]1337;Copy=:SGVsbG8=");
        let actions = parser.next(0x07);
        let Some(Action::OscDispatch(crate::osc::Command::ClipboardContents { kind, data })) =
            actions[0]
        else {
            panic!("expected iTerm2 copy, got {:?}", actions[0]);
        };
        assert_eq!(kind, b'c');
        assert_eq!(data, b"SGVsbG8=");
    }
}
