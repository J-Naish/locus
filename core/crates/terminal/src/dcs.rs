//! Device Control String handler.

pub const DEFAULT_MAX_BYTES: usize = 1024 * 1024;

pub struct Handler {
    state: State,
    max_bytes: usize,
}

enum State {
    Inactive,
    Ignore,
    XtGetTcap(Vec<u8>),
    Decrqss { data: [u8; 2], len: usize },
}

#[derive(Debug)]
pub enum Command {
    XtGetTcap(XtGetTcap),
    Decrqss(Decrqss),
    // Ghostty's tmux-control-mode command is deliberately omitted in this
    // phase; it is the last Zig variant, so tag order for the ported commands
    // remains stable for future phases.
}

#[derive(Debug)]
pub struct XtGetTcap {
    data: Vec<u8>,
    index: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decrqss {
    None,
    Sgr,
    Decscusr,
    Decstbm,
    Decslrm,
}

impl Default for Handler {
    fn default() -> Self {
        Self {
            state: State::Inactive,
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

impl Handler {
    pub fn hook(&mut self, dcs: &crate::parser::Dcs<'_>) -> Option<Command> {
        debug_assert!(matches!(self.state, State::Inactive));
        self.state = State::Ignore;

        match (dcs.intermediates, dcs.final_byte) {
            (b"+", b'q') => {
                self.state = State::XtGetTcap(Vec::with_capacity(128));
            }
            (b"$", b'q') => {
                self.state = State::Decrqss {
                    data: [0; 2],
                    len: 0,
                };
            }
            _ => {}
        }
        None
    }

    pub fn put(&mut self, byte: u8) -> Option<Command> {
        match &mut self.state {
            State::Inactive | State::Ignore => {}
            State::XtGetTcap(data) => {
                if data.len() >= self.max_bytes {
                    self.discard();
                    self.state = State::Ignore;
                    return None;
                }
                data.push(byte);
            }
            State::Decrqss { data, len } => {
                if *len >= data.len() {
                    self.discard();
                    self.state = State::Ignore;
                    return None;
                }
                data[*len] = byte;
                *len += 1;
            }
        }
        None
    }

    pub fn unhook(&mut self) -> Option<Command> {
        match std::mem::replace(&mut self.state, State::Inactive) {
            State::Inactive | State::Ignore => None,
            State::XtGetTcap(mut data) => {
                data.make_ascii_uppercase();
                Some(Command::XtGetTcap(XtGetTcap { data, index: 0 }))
            }
            State::Decrqss { data, len } => {
                let value = match len {
                    0 => Decrqss::None,
                    1 => match data[0] {
                        b'm' => Decrqss::Sgr,
                        b'r' => Decrqss::Decstbm,
                        b's' => Decrqss::Decslrm,
                        _ => Decrqss::None,
                    },
                    2 => match data {
                        [b' ', b'q'] => Decrqss::Decscusr,
                        _ => Decrqss::None,
                    },
                    _ => unreachable!("DECRQSS buffer is two bytes"),
                };
                Some(Command::Decrqss(value))
            }
        }
    }

    fn discard(&mut self) {
        self.state = State::Inactive;
    }
}

impl XtGetTcap {
    #[allow(clippy::should_implement_trait)]
    pub fn next(&mut self) -> Option<&[u8]> {
        if self.index >= self.data.len() {
            return None;
        }

        let rem = &self.data[self.index..];
        let pos = rem
            .iter()
            .position(|byte| *byte == b';')
            .unwrap_or(rem.len());
        self.index += pos + 1;
        Some(&rem[..pos])
    }
}

#[cfg(test)]
mod tests {
    use super::{Command, Decrqss, Handler, State};
    use crate::parser::Dcs;

    fn dcs(intermediates: &'static [u8], final_byte: u8) -> Dcs<'static> {
        Dcs {
            intermediates,
            params: &[],
            final_byte,
        }
    }

    // ghostty: "unknown DCS command" (dcs.zig:298)
    #[test]
    fn unknown_dcs_command_is_ignored() {
        let mut handler = Handler::default();
        assert!(handler.hook(&dcs(b"", b'A')).is_none());
        assert!(matches!(handler.state, State::Ignore));
        assert!(handler.unhook().is_none());
        assert!(matches!(handler.state, State::Inactive));
    }

    // ghostty: "XTGETTCAP command" (dcs.zig:310)
    #[test]
    fn xtgettcap_command() {
        let mut handler = Handler::default();
        assert!(handler.hook(&dcs(b"+", b'q')).is_none());
        for byte in b"536D756C78" {
            assert!(handler.put(*byte).is_none());
        }
        let Some(Command::XtGetTcap(mut command)) = handler.unhook() else {
            panic!("expected XTGETTCAP command");
        };
        assert_eq!(command.next(), Some(&b"536D756C78"[..]));
        assert_eq!(command.next(), None);
    }

    // ghostty: "XTGETTCAP mixed case" (dcs.zig:325)
    #[test]
    fn xtgettcap_mixed_case_is_uppercased() {
        let mut handler = Handler::default();
        assert!(handler.hook(&dcs(b"+", b'q')).is_none());
        for byte in b"536d756C78" {
            assert!(handler.put(*byte).is_none());
        }
        let Some(Command::XtGetTcap(mut command)) = handler.unhook() else {
            panic!("expected XTGETTCAP command");
        };
        assert_eq!(command.next(), Some(&b"536D756C78"[..]));
        assert_eq!(command.next(), None);
    }

    // ghostty: "XTGETTCAP command multiple keys" (dcs.zig:340)
    #[test]
    fn xtgettcap_multiple_keys() {
        let mut handler = Handler::default();
        assert!(handler.hook(&dcs(b"+", b'q')).is_none());
        for byte in b"536D756C78;536D756C78" {
            assert!(handler.put(*byte).is_none());
        }
        let Some(Command::XtGetTcap(mut command)) = handler.unhook() else {
            panic!("expected XTGETTCAP command");
        };
        assert_eq!(command.next(), Some(&b"536D756C78"[..]));
        assert_eq!(command.next(), Some(&b"536D756C78"[..]));
        assert_eq!(command.next(), None);
    }

    // ghostty: "XTGETTCAP command invalid data" (dcs.zig:356)
    #[test]
    fn xtgettcap_invalid_data_is_still_split() {
        let mut handler = Handler::default();
        assert!(handler.hook(&dcs(b"+", b'q')).is_none());
        for byte in b"who;536D756C78" {
            assert!(handler.put(*byte).is_none());
        }
        let Some(Command::XtGetTcap(mut command)) = handler.unhook() else {
            panic!("expected XTGETTCAP command");
        };
        assert_eq!(command.next(), Some(&b"WHO"[..]));
        assert_eq!(command.next(), Some(&b"536D756C78"[..]));
        assert_eq!(command.next(), None);
    }

    // ghostty: "DECRQSS command" (dcs.zig:372)
    #[test]
    fn decrqss_command() {
        let mut handler = Handler::default();
        assert!(handler.hook(&dcs(b"$", b'q')).is_none());
        assert!(handler.put(b'm').is_none());
        assert!(matches!(
            handler.unhook(),
            Some(Command::Decrqss(Decrqss::Sgr))
        ));
    }

    // ghostty: "DECRQSS invalid command" (dcs.zig:386)
    #[test]
    fn decrqss_invalid_command_and_overflow() {
        let mut handler = Handler::default();
        assert!(handler.hook(&dcs(b"$", b'q')).is_none());
        assert!(handler.put(b'z').is_none());
        assert!(matches!(
            handler.unhook(),
            Some(Command::Decrqss(Decrqss::None))
        ));

        handler.discard();
        assert!(handler.hook(&dcs(b"$", b'q')).is_none());
        assert!(handler.put(b'"').is_none());
        assert!(handler.put(b' ').is_none());
        assert!(handler.put(b'q').is_none());
        assert!(handler.unhook().is_none());
    }

    // Ghostty's tmux DCS tests are deferred with the tmux-control-mode port.
}
