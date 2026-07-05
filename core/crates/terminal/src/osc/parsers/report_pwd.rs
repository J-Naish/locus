use crate::osc::Pending;

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    Some(Pending::ReportPwd {
        value: 0..data.len(),
    })
}

#[cfg(test)]
mod tests {
    use crate::osc::{parsers::parse_body, Command};

    // ghostty: "OSC 7: report pwd" (report_pwd.zig:25)
    #[test]
    fn osc_7_report_pwd() {
        let parser = parse_body(b"7;file:///tmp/example", None);
        assert_eq!(
            parser.command(),
            Some(Command::ReportPwd {
                value: b"file:///tmp/example"
            })
        );
    }

    // ghostty: "OSC 7: report pwd empty" (report_pwd.zig:38)
    #[test]
    fn osc_7_report_pwd_empty() {
        let parser = parse_body(b"7;", None);
        assert_eq!(parser.command(), Some(Command::ReportPwd { value: b"" }));
    }
}
