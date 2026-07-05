use crate::osc::Pending;

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    Some(Pending::MouseShape {
        value: 0..data.len(),
    })
}

#[cfg(test)]
mod tests {
    use crate::osc::{parsers::parse_body, Command};

    // ghostty: "OSC 22: pointer cursor" (mouse_shape.zig:28)
    #[test]
    fn osc_22_pointer_cursor() {
        let parser = parse_body(b"22;pointer", None);
        assert_eq!(
            parser.command(),
            Some(Command::MouseShape { value: b"pointer" })
        );
    }
}
