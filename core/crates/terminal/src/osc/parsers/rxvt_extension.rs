use crate::osc::Pending;

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    let first = data.iter().position(|byte| *byte == b';')?;
    if &data[..first] != b"notify" {
        return None;
    }
    let second = data[first + 1..].iter().position(|byte| *byte == b';')? + first + 1;
    Some(Pending::ShowDesktopNotification {
        title: first + 1..second,
        body: second + 1..data.len(),
    })
}

#[cfg(test)]
mod tests {
    use crate::osc::{parsers::parse_body, Command};

    // ghostty: "OSC: OSC 777 show desktop notification with title" (rxvt_extension.zig:47)
    #[test]
    fn osc_777_show_desktop_notification_with_title() {
        let parser = parse_body(b"777;notify;Title;Body", Some(0x1B));
        let Some(Command::ShowDesktopNotification { title, body }) = parser.command() else {
            panic!("expected desktop notification, got {:?}", parser.command());
        };
        assert_eq!(title, b"Title");
        assert_eq!(body, b"Body");
    }
}
