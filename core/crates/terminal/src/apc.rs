//! APC dispatcher shell.
//!
//! Kitty graphics and glyph protocols are recognized but discarded in this
//! phase so unsupported and runtime-disabled protocols consume bytes the same
//! way.

pub const KITTY_MAX_BYTES_DEFAULT: usize = 65 * 1024 * 1024;
pub const GLYPH_MAX_BYTES_DEFAULT: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApcProtocol {
    Kitty,
    Glyph,
}

#[derive(Debug)]
pub enum ApcCommand {}

#[derive(Debug)]
enum State {
    Inactive,
    Ignore,
    Identify { buf: [u8; 4], len: u8 },
}

#[derive(Debug)]
pub struct Handler {
    state: State,
    kitty_max_bytes: Option<usize>,
    glyph_max_bytes: Option<usize>,
    kitty_enabled: bool,
    glyph_enabled: bool,
}

impl Default for Handler {
    fn default() -> Self {
        Self {
            state: State::Inactive,
            kitty_max_bytes: None,
            glyph_max_bytes: None,
            kitty_enabled: true,
            glyph_enabled: true,
        }
    }
}

impl Handler {
    pub fn start(&mut self) {
        self.state = State::Identify {
            buf: [0; 4],
            len: 0,
        };
    }

    pub fn feed(&mut self, byte: u8) {
        match &mut self.state {
            State::Inactive => {
                debug_assert!(false, "APC feed called before start");
                self.state = State::Ignore;
            }
            State::Ignore => {}
            State::Identify { buf, len } => {
                if *len == 0 && byte == b'G' && self.kitty_enabled {
                    // Recognized kitty graphics; real parser lands later.
                    self.state = State::Ignore;
                    return;
                }
                if byte == b';' {
                    if &buf[..usize::from(*len)] == b"25a1" && self.glyph_enabled {
                        // Recognized glyph protocol; real parser lands later.
                        self.state = State::Ignore;
                    } else {
                        self.state = State::Ignore;
                    }
                    return;
                }
                if usize::from(*len) >= buf.len() {
                    self.state = State::Ignore;
                    return;
                }
                buf[usize::from(*len)] = byte;
                *len += 1;
            }
        }
    }

    pub fn end(&mut self) -> Option<ApcCommand> {
        self.state = State::Inactive;
        None
    }

    pub fn enable(&mut self, protocol: ApcProtocol, enabled: bool) {
        match protocol {
            ApcProtocol::Kitty => self.kitty_enabled = enabled,
            ApcProtocol::Glyph => self.glyph_enabled = enabled,
        }
    }

    pub fn max_bytes(&self, protocol: ApcProtocol) -> usize {
        match protocol {
            ApcProtocol::Kitty => self.kitty_max_bytes.unwrap_or(KITTY_MAX_BYTES_DEFAULT),
            ApcProtocol::Glyph => self.glyph_max_bytes.unwrap_or(GLYPH_MAX_BYTES_DEFAULT),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ApcProtocol, Handler};

    fn run(input: &[u8]) -> Option<super::ApcCommand> {
        let mut handler = Handler::default();
        handler.start();
        for byte in input {
            handler.feed(*byte);
        }
        handler.end()
    }

    #[test]
    fn unknown_apc_is_ignored_and_resets_on_end() {
        // ghostty: "unknown APC command" (apc.zig:233)
        let mut handler = Handler::default();
        handler.start();
        for byte in b"Xabcdef1234" {
            handler.feed(*byte);
        }
        assert!(handler.end().is_none());
    }

    #[test]
    fn garbage_kitty_command() {
        // ghostty: "garbage Kitty command" (apc.zig:243)
        assert!(run(b"Gabcdef1234").is_none());
    }

    #[test]
    fn kitty_command_with_overflow_u32() {
        // ghostty: "Kitty command with overflow u32" (apc.zig:255)
        assert!(run(b"Ga=p,i=10000000000").is_none());
    }

    #[test]
    fn kitty_command_with_overflow_i32() {
        // ghostty: "Kitty command with overflow i32" (apc.zig:267)
        assert!(run(b"Ga=p,i=1,z=-9999999999").is_none());
    }

    #[test]
    fn kitty_feed_error_deinits_parser() {
        // ghostty: "kitty feed error deinits parser" (apc.zig:279)
        assert!(run(b"Ga=p,i=10000000000;").is_none());
    }

    // ghostty: "kitty max bytes exceeded" (apc.zig:296), "valid Kitty command"
    // (apc.zig:314), and "valid glyph command" (apc.zig:382) are deferred:
    // this phase recognizes kitty/glyph APC prefixes but deliberately discards
    // them until the real protocol parsers land.

    #[test]
    fn identify_with_unrecognized_command() {
        // ghostty: "identify with unrecognized command" (apc.zig:326)
        assert!(run(b"abcd;payload").is_none());
    }

    #[test]
    fn identify_buffer_overflow() {
        // ghostty: "identify buffer overflow" (apc.zig:337)
        assert!(run(b"abcde;payload").is_none());
    }

    #[test]
    fn identify_with_no_input() {
        // ghostty: "identify with no input" (apc.zig:348)
        assert!(run(b"").is_none());
    }

    #[test]
    fn identify_with_unknown_partial_input() {
        // ghostty: "identify with unknown partial input" (apc.zig:356)
        assert!(run(b"25a").is_none());
    }

    #[test]
    fn garbage_glyph_command() {
        // ghostty: "garbage glyph command" (apc.zig:367)
        assert!(run(b"25a1;X").is_none());
    }

    #[test]
    fn disabled_glyph_is_ignored() {
        // ghostty: "disabled glyph command is ignored" (apc.zig:394)
        let mut handler = Handler::default();
        handler.enable(ApcProtocol::Glyph, false);
        handler.start();
        for byte in b"25a1;q;cp=e0a0" {
            handler.feed(*byte);
        }
        assert!(handler.end().is_none());
    }
}
