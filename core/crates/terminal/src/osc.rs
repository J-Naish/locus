//! OSC (Operating System Command) parsing.
//!
//! This module ports Ghostty's OSC trie and dispatch model. Ghostty stores
//! command payload slices inside its parser buffer; Rust splits that into
//! `end` storing non-borrowing `Pending` ranges and `command` materializing the
//! borrowed public command view.

pub(crate) mod encoding;
pub(crate) mod parsers;

use std::ops::Range;

use crate::color::{Dynamic, Special};
use parsers::color_operation::{ColorOperationKind, ColorRequest};
use parsers::context_signal::ContextSignal;
use parsers::kitty_clipboard_protocol::KittyClipboard;
use parsers::kitty_color::{KittyColorRequest, KittySpecial};
use parsers::kitty_dnd_protocol::KittyDnd;
use parsers::kitty_text_sizing::KittyTextSizing;
use parsers::osc9::{ConemuTabTitle, ProgressState};
use parsers::semantic_prompt::{SemanticPrompt, SemanticPromptAction};

pub const MAX_BUF: usize = 2048;
pub(crate) const FIXED_CAPTURE_MAX: usize = MAX_BUF - 1;
pub(crate) const ALLOCATING_CAPTURE_MAX: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Terminator {
    St,
    Bel,
}

impl Terminator {
    pub fn from_byte(byte: Option<u8>) -> Self {
        if byte == Some(0x07) {
            Self::Bel
        } else {
            Self::St
        }
    }

    pub fn string(self) -> &'static str {
        match self {
            Self::St => "\x1b\\",
            Self::Bel => "\x07",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorTarget {
    Palette(u8),
    Special(Special),
    Dynamic(Dynamic),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyColorKind {
    Palette(u8),
    Special(KittySpecial),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyTextVAlign {
    Top = 0,
    Bottom = 1,
    Center = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyTextHAlign {
    Left = 0,
    Right = 1,
    Center = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConemuXtermMode {
    Both(bool),
    KeyboardUnchangedOutput(bool),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command<'a> {
    ChangeWindowTitle(&'a [u8]),
    ChangeWindowIcon(&'a [u8]),
    SemanticPrompt(SemanticPrompt<'a>),
    ClipboardContents {
        kind: u8,
        data: &'a [u8],
    },
    ReportPwd {
        value: &'a [u8],
    },
    MouseShape {
        value: &'a [u8],
    },
    ColorOperation {
        kind: ColorOperationKind,
        requests: &'a [ColorRequest],
        terminator: Terminator,
    },
    KittyColorProtocol {
        requests: &'a [KittyColorRequest],
        terminator: Terminator,
    },
    ShowDesktopNotification {
        title: &'a [u8],
        body: &'a [u8],
    },
    HyperlinkStart {
        id: Option<&'a [u8]>,
        uri: &'a [u8],
    },
    HyperlinkEnd,
    ConemuSleep {
        duration_ms: u16,
    },
    ConemuShowMessageBox(&'a [u8]),
    ConemuChangeTabTitle(ConemuTabTitle<'a>),
    ConemuProgressReport {
        state: ProgressState,
        progress: Option<u8>,
    },
    ConemuWaitInput,
    ConemuGuimacro(&'a [u8]),
    ConemuRunProcess(&'a [u8]),
    ConemuOutputEnvironmentVariable(&'a [u8]),
    ConemuXtermEmulation {
        keyboard: Option<bool>,
        output: Option<bool>,
    },
    ConemuComment(&'a [u8]),
    KittyTextSizing(KittyTextSizing<'a>),
    KittyClipboardProtocol(KittyClipboard<'a>),
    KittyDndProtocol(KittyDnd<'a>),
    ContextSignal(ContextSignal<'a>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Pending {
    ChangeWindowTitle(Range<usize>),
    ChangeWindowIcon(Range<usize>),
    SemanticPrompt {
        action: SemanticPromptAction,
        options: Range<usize>,
    },
    ClipboardContents {
        kind: u8,
        data: Range<usize>,
    },
    ReportPwd {
        value: Range<usize>,
    },
    MouseShape {
        value: Range<usize>,
    },
    ColorOperation {
        kind: ColorOperationKind,
        requests: Vec<ColorRequest>,
        terminator: Terminator,
    },
    KittyColorProtocol {
        requests: Vec<KittyColorRequest>,
        terminator: Terminator,
    },
    ShowDesktopNotification {
        title: Range<usize>,
        body: Range<usize>,
    },
    HyperlinkStart {
        id: Option<Range<usize>>,
        uri: Range<usize>,
    },
    HyperlinkEnd,
    ConemuSleep {
        duration_ms: u16,
    },
    ConemuShowMessageBox(Range<usize>),
    ConemuChangeTabTitle(parsers::osc9::PendingTabTitle),
    ConemuProgressReport {
        state: ProgressState,
        progress: Option<u8>,
    },
    ConemuWaitInput,
    ConemuGuimacro(Range<usize>),
    ConemuRunProcess(Range<usize>),
    ConemuOutputEnvironmentVariable(Range<usize>),
    ConemuXtermEmulation {
        keyboard: Option<bool>,
        output: Option<bool>,
    },
    ConemuComment(Range<usize>),
    KittyTextSizing(parsers::kitty_text_sizing::PendingKittyTextSizing),
    KittyClipboardProtocol {
        metadata: Range<usize>,
        payload: Option<Range<usize>>,
        terminator: Terminator,
    },
    KittyDndProtocol {
        metadata: Range<usize>,
        payload: Option<Range<usize>>,
        terminator: Terminator,
    },
    ContextSignal(parsers::context_signal::PendingContextSignal),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CaptureMode {
    Fixed,
    Allocating,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
enum State {
    #[default]
    Start,
    Invalid,
    P0,
    P1,
    P2,
    P3,
    P4,
    P5,
    P6,
    P7,
    P8,
    P9,
    P10,
    P11,
    P12,
    P13,
    P14,
    P15,
    P16,
    P17,
    P18,
    P19,
    P21,
    P22,
    P30,
    P52,
    P55,
    P66,
    P72,
    P77,
    P104,
    P110,
    P111,
    P112,
    P113,
    P114,
    P115,
    P116,
    P117,
    P118,
    P119,
    P133,
    P300,
    P552,
    P777,
    P1337,
    P3008,
    P5522,
}

#[derive(Debug, Default)]
pub struct Parser {
    state: State,
    buffer: Vec<u8>,
    capture: Option<CaptureMode>,
    pending: Option<Pending>,
}

impl Parser {
    pub fn reset(&mut self) {
        self.state = State::Start;
        self.buffer.clear();
        self.capture = None;
        self.pending = None;
    }

    pub fn next(&mut self, byte: u8) {
        if self.state == State::Invalid {
            return;
        }

        if let Some(mode) = self.capture {
            let cap = match mode {
                CaptureMode::Fixed => FIXED_CAPTURE_MAX,
                CaptureMode::Allocating => ALLOCATING_CAPTURE_MAX,
            };
            if self.buffer.len() >= cap {
                self.state = State::Invalid;
                return;
            }
            self.buffer.push(byte);
            return;
        }

        self.state = match (self.state, byte) {
            (State::Start, b'0') => State::P0,
            (State::Start, b'1') => State::P1,
            (State::Start, b'2') => State::P2,
            (State::Start, b'3') => State::P3,
            (State::Start, b'4') => State::P4,
            (State::Start, b'5') => State::P5,
            (State::Start, b'6') => State::P6,
            (State::Start, b'7') => State::P7,
            (State::Start, b'8') => State::P8,
            (State::Start, b'9') => State::P9,
            (State::P0, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P1, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P1, b'0') => State::P10,
            (State::P1, b'1') => State::P11,
            (State::P1, b'2') => State::P12,
            (State::P1, b'3') => State::P13,
            (State::P1, b'4') => State::P14,
            (State::P1, b'5') => State::P15,
            (State::P1, b'6') => State::P16,
            (State::P1, b'7') => State::P17,
            (State::P1, b'8') => State::P18,
            (State::P1, b'9') => State::P19,
            (State::P2, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P2, b'1') => State::P21,
            (State::P2, b'2') => State::P22,
            (State::P3, b'0') => State::P30,
            (State::P30, b'0') => State::P300,
            (State::P300, b'8') => State::P3008,
            (State::P3008, b';') => return self.start_capture(CaptureMode::Fixed),
            // Ghostty allocator gates collapse: Rust always has an allocator.
            (State::P4, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P5, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P5, b'2') => State::P52,
            (State::P5, b'5') => State::P55,
            (State::P6, b'6') => State::P66,
            (State::P7, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P7, b'2') => State::P72,
            (State::P7, b'7') => State::P77,
            (State::P8, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P9, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P10, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P10, b'4') => State::P104,
            (State::P11, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P11, b'0') => State::P110,
            (State::P11, b'1') => State::P111,
            (State::P11, b'2') => State::P112,
            (State::P11, b'3') => State::P113,
            (State::P11, b'4') => State::P114,
            (State::P11, b'5') => State::P115,
            (State::P11, b'6') => State::P116,
            (State::P11, b'7') => State::P117,
            (State::P11, b'8') => State::P118,
            (State::P11, b'9') => State::P119,
            (State::P12, b';')
            | (State::P14, b';')
            | (State::P15, b';')
            | (State::P16, b';')
            | (State::P17, b';')
            | (State::P18, b';')
            | (State::P19, b';')
            | (State::P21, b';')
            | (State::P22, b';')
            | (State::P104, b';')
            | (State::P110, b';')
            | (State::P111, b';')
            | (State::P112, b';')
            | (State::P113, b';')
            | (State::P114, b';')
            | (State::P115, b';')
            | (State::P116, b';')
            | (State::P117, b';')
            | (State::P118, b';')
            | (State::P119, b';')
            | (State::P133, b';')
            | (State::P777, b';')
            | (State::P1337, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P13, b';') => return self.start_capture(CaptureMode::Fixed),
            (State::P13, b'3') => State::P133,
            (State::P133, b'7') => State::P1337,
            (State::P52, b';') => return self.start_capture(CaptureMode::Allocating),
            (State::P55, b'2') => State::P552,
            (State::P66, b';') => return self.start_capture(CaptureMode::Allocating),
            (State::P72, b';') => return self.start_capture(CaptureMode::Allocating),
            (State::P77, b'7') => State::P777,
            (State::P552, b'2') => State::P5522,
            (State::P5522, b';') => return self.start_capture(CaptureMode::Allocating),
            _ => State::Invalid,
        };
    }

    pub fn end(&mut self, terminator_byte: Option<u8>) {
        self.pending = None;
        let terminator = Terminator::from_byte(terminator_byte);
        let data = self.capture.map(|_| self.buffer.as_slice());

        self.pending = match self.state {
            State::Start
            | State::Invalid
            | State::P3
            | State::P30
            | State::P300
            | State::P55
            | State::P552
            | State::P6
            | State::P77 => None,
            State::P0 | State::P2 => parse_captured(data, parsers::change_window_title::parse),
            State::P1 => parse_captured(data, parsers::change_window_icon::parse),
            State::P4
            | State::P5
            | State::P10
            | State::P11
            | State::P12
            | State::P13
            | State::P14
            | State::P15
            | State::P16
            | State::P17
            | State::P18
            | State::P19
            | State::P104
            | State::P110
            | State::P111
            | State::P112
            | State::P113
            | State::P114
            | State::P115
            | State::P116
            | State::P117
            | State::P118
            | State::P119 => color_kind_for_state(self.state).map(|kind| Pending::ColorOperation {
                kind,
                requests: parsers::color_operation::parse_requests(kind, data.unwrap_or_default()),
                terminator,
            }),
            State::P7 => parse_captured(data, parsers::report_pwd::parse),
            State::P8 => parse_captured(data, parsers::hyperlink::parse),
            State::P9 => parse_captured(data, parsers::osc9::parse),
            State::P21 => {
                if let Some(data) = data {
                    match parsers::kitty_color::parse(data, terminator) {
                        Some(pending) => Some(pending),
                        None => {
                            self.state = State::Invalid;
                            None
                        }
                    }
                } else {
                    self.state = State::Invalid;
                    None
                }
            }
            State::P22 => parse_captured(data, parsers::mouse_shape::parse),
            State::P52 => parse_captured(data, parsers::clipboard_operation::parse),
            State::P66 => {
                if let Some(data) = data {
                    match parsers::kitty_text_sizing::parse(data) {
                        Some(pending) => Some(pending),
                        None => {
                            self.state = State::Invalid;
                            None
                        }
                    }
                } else {
                    self.state = State::Invalid;
                    None
                }
            }
            State::P72 => data.map(|data| parsers::kitty_dnd_protocol::parse(data, terminator)),
            State::P133 => parse_captured(data, parsers::semantic_prompt::parse),
            State::P777 => parse_captured(data, parsers::rxvt_extension::parse),
            State::P1337 => parse_captured(data, parsers::iterm2::parse),
            State::P3008 => parse_captured(data, parsers::context_signal::parse),
            State::P5522 => {
                data.map(|data| parsers::kitty_clipboard_protocol::parse(data, terminator))
            }
        };
    }

    pub fn command(&self) -> Option<Command<'_>> {
        let buffer = self.buffer.as_slice();
        self.pending.as_ref().map(|pending| match pending {
            Pending::ChangeWindowTitle(range) => Command::ChangeWindowTitle(&buffer[range.clone()]),
            Pending::ChangeWindowIcon(range) => Command::ChangeWindowIcon(&buffer[range.clone()]),
            Pending::SemanticPrompt { action, options } => {
                Command::SemanticPrompt(SemanticPrompt {
                    action: *action,
                    options_unvalidated: &buffer[options.clone()],
                })
            }
            Pending::ClipboardContents { kind, data } => Command::ClipboardContents {
                kind: *kind,
                data: &buffer[data.clone()],
            },
            Pending::ReportPwd { value } => Command::ReportPwd {
                value: &buffer[value.clone()],
            },
            Pending::MouseShape { value } => Command::MouseShape {
                value: &buffer[value.clone()],
            },
            Pending::ColorOperation {
                kind,
                requests,
                terminator,
            } => Command::ColorOperation {
                kind: *kind,
                requests,
                terminator: *terminator,
            },
            Pending::KittyColorProtocol {
                requests,
                terminator,
            } => Command::KittyColorProtocol {
                requests,
                terminator: *terminator,
            },
            Pending::ShowDesktopNotification { title, body } => Command::ShowDesktopNotification {
                title: &buffer[title.clone()],
                body: &buffer[body.clone()],
            },
            Pending::HyperlinkStart { id, uri } => Command::HyperlinkStart {
                id: id.as_ref().map(|range| &buffer[range.clone()]),
                uri: &buffer[uri.clone()],
            },
            Pending::HyperlinkEnd => Command::HyperlinkEnd,
            Pending::ConemuSleep { duration_ms } => Command::ConemuSleep {
                duration_ms: *duration_ms,
            },
            Pending::ConemuShowMessageBox(range) => {
                Command::ConemuShowMessageBox(&buffer[range.clone()])
            }
            Pending::ConemuChangeTabTitle(title) => Command::ConemuChangeTabTitle(match title {
                parsers::osc9::PendingTabTitle::Reset => ConemuTabTitle::Reset,
                parsers::osc9::PendingTabTitle::Value(range) => {
                    ConemuTabTitle::Value(&buffer[range.clone()])
                }
            }),
            Pending::ConemuProgressReport { state, progress } => Command::ConemuProgressReport {
                state: *state,
                progress: *progress,
            },
            Pending::ConemuWaitInput => Command::ConemuWaitInput,
            Pending::ConemuGuimacro(range) => Command::ConemuGuimacro(&buffer[range.clone()]),
            Pending::ConemuRunProcess(range) => Command::ConemuRunProcess(&buffer[range.clone()]),
            Pending::ConemuOutputEnvironmentVariable(range) => {
                Command::ConemuOutputEnvironmentVariable(&buffer[range.clone()])
            }
            Pending::ConemuXtermEmulation { keyboard, output } => Command::ConemuXtermEmulation {
                keyboard: *keyboard,
                output: *output,
            },
            Pending::ConemuComment(range) => Command::ConemuComment(&buffer[range.clone()]),
            Pending::KittyTextSizing(value) => Command::KittyTextSizing(KittyTextSizing {
                scale: value.scale,
                width: value.width,
                numerator: value.numerator,
                denominator: value.denominator,
                valign: value.valign,
                halign: value.halign,
                text: &buffer[value.text.clone()],
            }),
            Pending::KittyClipboardProtocol {
                metadata,
                payload,
                terminator,
            } => Command::KittyClipboardProtocol(KittyClipboard {
                metadata: &buffer[metadata.clone()],
                payload: payload.as_ref().map(|range| &buffer[range.clone()]),
                terminator: *terminator,
            }),
            Pending::KittyDndProtocol {
                metadata,
                payload,
                terminator,
            } => Command::KittyDndProtocol(KittyDnd {
                metadata: &buffer[metadata.clone()],
                payload: payload.as_ref().map(|range| &buffer[range.clone()]),
                terminator: *terminator,
            }),
            Pending::ContextSignal(value) => Command::ContextSignal(ContextSignal {
                action: value.action,
                id: &buffer[value.id.clone()],
                metadata: &buffer[value.metadata.clone()],
            }),
        })
    }

    fn start_capture(&mut self, mode: CaptureMode) {
        self.buffer.clear();
        self.capture = Some(mode);
    }
}

fn parse_captured(data: Option<&[u8]>, parse: fn(&[u8]) -> Option<Pending>) -> Option<Pending> {
    data.and_then(parse)
}

fn color_kind_for_state(state: State) -> Option<ColorOperationKind> {
    Some(match state {
        State::P4 => ColorOperationKind::Osc4,
        State::P5 => ColorOperationKind::Osc5,
        State::P10 => ColorOperationKind::Osc10,
        State::P11 => ColorOperationKind::Osc11,
        State::P12 => ColorOperationKind::Osc12,
        State::P13 => ColorOperationKind::Osc13,
        State::P14 => ColorOperationKind::Osc14,
        State::P15 => ColorOperationKind::Osc15,
        State::P16 => ColorOperationKind::Osc16,
        State::P17 => ColorOperationKind::Osc17,
        State::P18 => ColorOperationKind::Osc18,
        State::P19 => ColorOperationKind::Osc19,
        State::P104 => ColorOperationKind::Osc104,
        State::P110 => ColorOperationKind::Osc110,
        State::P111 => ColorOperationKind::Osc111,
        State::P112 => ColorOperationKind::Osc112,
        State::P113 => ColorOperationKind::Osc113,
        State::P114 => ColorOperationKind::Osc114,
        State::P115 => ColorOperationKind::Osc115,
        State::P116 => ColorOperationKind::Osc116,
        State::P117 => ColorOperationKind::Osc117,
        State::P118 => ColorOperationKind::Osc118,
        State::P119 => ColorOperationKind::Osc119,
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::{Command, Parser, ALLOCATING_CAPTURE_MAX};

    fn parse(body: &[u8]) -> Parser {
        let mut parser = Parser::default();
        for byte in body {
            parser.next(*byte);
        }
        parser.end(None);
        parser
    }

    #[test]
    fn invalid_prefix_discards_the_rest() {
        assert!(parse(b"6;x").command().is_none());
        assert!(parse(b"98").command().is_none());
    }

    #[test]
    fn allocating_capture_is_capped() {
        let mut parser = Parser::default();
        parser.next(b'5');
        parser.next(b'2');
        parser.next(b';');
        for _ in 0..=ALLOCATING_CAPTURE_MAX {
            parser.next(b'a');
        }
        parser.end(None);
        assert!(parser.command().is_none());
    }

    #[test]
    fn title_materializes_from_pending_range() {
        let parser = parse(b"0;abc");
        assert_eq!(parser.command(), Some(Command::ChangeWindowTitle(b"abc")));
    }
}
