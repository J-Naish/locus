//! Focus event encoder.

pub const MAX_ENCODE_SIZE: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Event {
    Gained,
    Lost,
}

pub fn encode<W: std::fmt::Write>(writer: &mut W, event: Event) -> std::fmt::Result {
    match event {
        Event::Gained => writer.write_str("\x1B[I"),
        Event::Lost => writer.write_str("\x1B[O"),
    }
}

#[cfg(test)]
mod tests {
    use super::{encode, Event};

    // ghostty: "encode focus gained" (focus.zig:27)
    #[test]
    fn encode_focus_gained() {
        let mut output = String::new();
        encode(&mut output, Event::Gained).unwrap();
        assert_eq!(output, "\x1B[I");
    }

    // ghostty: "encode focus lost" (focus.zig:34)
    #[test]
    fn encode_focus_lost() {
        let mut output = String::new();
        encode(&mut output, Event::Lost).unwrap();
        assert_eq!(output, "\x1B[O");
    }
}
