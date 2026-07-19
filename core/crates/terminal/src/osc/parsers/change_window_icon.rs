use crate::osc::Pending;

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    Some(Pending::ChangeWindowIcon(0..data.len()))
}

#[cfg(test)]
mod tests {
    use crate::osc::{parsers::parse_body, Command};

    // ghostty: "OSC 1: change_window_icon" (change_window_icon.zig:22)
    #[test]
    fn osc_1_change_window_icon() {
        let parser = parse_body(b"1;ab", None);
        assert_eq!(parser.command(), Some(Command::ChangeWindowIcon(b"ab")));
    }
}
