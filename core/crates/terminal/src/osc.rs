//! OSC (Operating System Command) parsing seam.
//!
//! Stub: phase T3 replaces this with the full port of ghostty's osc.zig.
//! The `Parser` surface (reset/next/end) is final — Parser.zig depends on
//! exactly these three calls (reset on osc_string entry, next per byte,
//! end on exit with the terminating byte).

/// Parsed OSC command. No variants yet — populated in phase T3.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {}

#[derive(Debug, Default)]
pub struct Parser {}

impl Parser {
    pub fn reset(&mut self) {}

    pub fn next(&mut self, _byte: u8) {}

    pub fn end(&mut self, _terminator_byte: u8) -> Option<Command> {
        None
    }
}
