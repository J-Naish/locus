use crate::osc::{Pending, Terminator};

use super::kitty_options::find_option_value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KittyClipboard<'a> {
    pub metadata: &'a [u8],
    pub payload: Option<&'a [u8]>,
    pub terminator: Terminator,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyClipboardLocation {
    Primary,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyClipboardStatus {
    Data,
    Done,
    Ebusy,
    Einval,
    Eio,
    Enosys,
    Eperm,
    Ok,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyClipboardOperation {
    Read,
    Walias,
    Wdata,
    Write,
}

impl<'a> KittyClipboard<'a> {
    pub fn read_id(self) -> Option<&'a [u8]> {
        let value = find_option_value(self.metadata, b"id")?;
        if !value.is_empty()
            && value.iter().all(|byte| {
                byte.is_ascii_alphanumeric() || matches!(*byte, b'-' | b'_' | b'+' | b'.')
            })
        {
            Some(value)
        } else {
            None
        }
    }

    pub fn read_mime(self) -> Option<&'a [u8]> {
        find_option_value(self.metadata, b"mime")
    }

    pub fn read_name(self) -> Option<&'a [u8]> {
        find_option_value(self.metadata, b"name")
    }

    pub fn read_password(self) -> Option<&'a [u8]> {
        find_option_value(self.metadata, b"password")
    }

    pub fn read_pw(self) -> Option<&'a [u8]> {
        find_option_value(self.metadata, b"pw")
    }

    pub fn read_loc(self) -> Option<KittyClipboardLocation> {
        match find_option_value(self.metadata, b"loc")? {
            b"primary" => Some(KittyClipboardLocation::Primary),
            _ => None,
        }
    }

    pub fn read_status(self) -> Option<KittyClipboardStatus> {
        Some(match find_option_value(self.metadata, b"status")? {
            b"DATA" => KittyClipboardStatus::Data,
            b"DONE" => KittyClipboardStatus::Done,
            b"EBUSY" => KittyClipboardStatus::Ebusy,
            b"EINVAL" => KittyClipboardStatus::Einval,
            b"EIO" => KittyClipboardStatus::Eio,
            b"ENOSYS" => KittyClipboardStatus::Enosys,
            b"EPERM" => KittyClipboardStatus::Eperm,
            b"OK" => KittyClipboardStatus::Ok,
            _ => return None,
        })
    }

    pub fn read_type(self) -> Option<KittyClipboardOperation> {
        Some(match find_option_value(self.metadata, b"type")? {
            b"read" => KittyClipboardOperation::Read,
            b"walias" => KittyClipboardOperation::Walias,
            b"wdata" => KittyClipboardOperation::Wdata,
            b"write" => KittyClipboardOperation::Write,
            _ => return None,
        })
    }
}

pub(crate) fn parse(data: &[u8], terminator: Terminator) -> Pending {
    let separator = data.iter().position(|byte| *byte == b';');
    let (metadata, payload) = if let Some(separator) = separator {
        (0..separator, Some(separator + 1..data.len()))
    } else {
        (0..data.len(), None)
    };
    Pending::KittyClipboardProtocol {
        metadata,
        payload,
        terminator,
    }
}

#[cfg(test)]
mod tests {
    use super::{
        KittyClipboard, KittyClipboardLocation, KittyClipboardOperation, KittyClipboardStatus,
    };
    use crate::osc::{Command, Terminator};

    #[derive(Default)]
    struct Expected<'a> {
        metadata: &'a [u8],
        payload: Option<&'a [u8]>,
        id: Option<&'a [u8]>,
        loc: Option<KittyClipboardLocation>,
        mime: Option<&'a [u8]>,
        name: Option<&'a [u8]>,
        password: Option<&'a [u8]>,
        pw: Option<&'a [u8]>,
        status: Option<KittyClipboardStatus>,
        operation: Option<KittyClipboardOperation>,
    }

    fn assert_clipboard(input: &[u8], expected: Expected<'_>) {
        let parser = super::super::parse_body(input, Some(0x1b));
        let Some(Command::KittyClipboardProtocol(clipboard)) = parser.command() else {
            panic!("expected kitty clipboard command");
        };
        assert_eq!(clipboard.terminator, Terminator::St);
        assert_eq!(clipboard.metadata, expected.metadata);
        assert_eq!(clipboard.payload, expected.payload);
        assert_clipboard_options(clipboard, expected);
    }

    fn assert_clipboard_options(clipboard: KittyClipboard<'_>, expected: Expected<'_>) {
        assert_eq!(clipboard.read_id(), expected.id);
        assert_eq!(clipboard.read_loc(), expected.loc);
        assert_eq!(clipboard.read_mime(), expected.mime);
        assert_eq!(clipboard.read_name(), expected.name);
        assert_eq!(clipboard.read_password(), expected.password);
        assert_eq!(clipboard.read_pw(), expected.pw);
        assert_eq!(clipboard.read_status(), expected.status);
        assert_eq!(clipboard.read_type(), expected.operation);
    }

    // ghostty: "OSC: 5522: empty metadata and missing payload" (kitty_clipboard_protocol.zig:178)
    #[test]
    fn osc5522_empty_metadata_and_missing_payload() {
        assert_clipboard(b"5522;", Expected::default());
    }

    // ghostty: "OSC: 5522: empty metadata and empty payload" (kitty_clipboard_protocol.zig:201)
    #[test]
    fn osc5522_empty_metadata_and_empty_payload() {
        assert_clipboard(
            b"5522;;",
            Expected {
                payload: Some(b""),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: non-empty metadata and payload" (kitty_clipboard_protocol.zig:224)
    #[test]
    fn osc5522_non_empty_metadata_and_payload() {
        assert_clipboard(
            b"5522;type=read;dGV4dC9wbGFpbg==",
            Expected {
                metadata: b"type=read",
                payload: Some(b"dGV4dC9wbGFpbg=="),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: empty id" (kitty_clipboard_protocol.zig:247)
    #[test]
    fn osc5522_empty_id_is_invalid() {
        assert_clipboard(
            b"5522;id=",
            Expected {
                metadata: b"id=",
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: valid id" (kitty_clipboard_protocol.zig:261)
    #[test]
    fn osc5522_valid_id_is_read() {
        assert_clipboard(
            b"5522;id=5c076ad9-d36f-4705-847b-d4dbf356cc0d",
            Expected {
                metadata: b"id=5c076ad9-d36f-4705-847b-d4dbf356cc0d",
                id: Some(b"5c076ad9-d36f-4705-847b-d4dbf356cc0d"),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: invalid id" (kitty_clipboard_protocol.zig:275)
    #[test]
    fn osc5522_invalid_id_is_rejected() {
        assert_clipboard(
            b"5522;id=*42*",
            Expected {
                metadata: b"id=*42*",
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: invalid status" (kitty_clipboard_protocol.zig:289)
    #[test]
    fn osc5522_invalid_status_is_rejected() {
        assert_clipboard(
            b"5522;status=BOBR",
            Expected {
                metadata: b"status=BOBR",
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: valid status" (kitty_clipboard_protocol.zig:303)
    #[test]
    fn osc5522_valid_status_is_read() {
        assert_clipboard(
            b"5522;status=DONE",
            Expected {
                metadata: b"status=DONE",
                status: Some(KittyClipboardStatus::Done),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: invalid location" (kitty_clipboard_protocol.zig:317)
    #[test]
    fn osc5522_invalid_location_is_rejected() {
        assert_clipboard(
            b"5522;loc=bobr",
            Expected {
                metadata: b"loc=bobr",
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: valid location" (kitty_clipboard_protocol.zig:331)
    #[test]
    fn osc5522_valid_location_is_read() {
        assert_clipboard(
            b"5522;loc=primary",
            Expected {
                metadata: b"loc=primary",
                loc: Some(KittyClipboardLocation::Primary),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: password 1" (kitty_clipboard_protocol.zig:345)
    #[test]
    fn osc5522_short_password_and_name_are_read() {
        assert_clipboard(
            b"5522;pw=R2hvc3R0eQ==:name=Qk9CUiBLVVJXQQ==",
            Expected {
                metadata: b"pw=R2hvc3R0eQ==:name=Qk9CUiBLVVJXQQ==",
                name: Some(b"Qk9CUiBLVVJXQQ=="),
                pw: Some(b"R2hvc3R0eQ=="),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: password 2" (kitty_clipboard_protocol.zig:360)
    #[test]
    fn osc5522_long_password_is_read() {
        assert_clipboard(
            b"5522;password=R2hvc3R0eQ==",
            Expected {
                metadata: b"password=R2hvc3R0eQ==",
                password: Some(b"R2hvc3R0eQ=="),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 1" (kitty_clipboard_protocol.zig:374)
    #[test]
    fn osc5522_example_1() {
        assert_clipboard(
            b"5522;type=read:status=OK",
            Expected {
                metadata: b"type=read:status=OK",
                status: Some(KittyClipboardStatus::Ok),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 2" (kitty_clipboard_protocol.zig:396)
    #[test]
    fn osc5522_example_2() {
        assert_clipboard(
            b"5522;type=read:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==",
            Expected {
                metadata: b"type=read:mime=dGV4dC9wbGFpbg==",
                payload: Some(b"R2hvc3R0eQ=="),
                mime: Some(b"dGV4dC9wbGFpbg=="),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 3" (kitty_clipboard_protocol.zig:418)
    #[test]
    fn osc5522_example_3() {
        assert_clipboard(
            b"5522;type=read:status=OK",
            Expected {
                metadata: b"type=read:status=OK",
                status: Some(KittyClipboardStatus::Ok),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 4" (kitty_clipboard_protocol.zig:440)
    #[test]
    fn osc5522_example_4() {
        assert_clipboard(
            b"5522;type=write",
            Expected {
                metadata: b"type=write",
                operation: Some(KittyClipboardOperation::Write),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 5" (kitty_clipboard_protocol.zig:462)
    #[test]
    fn osc5522_example_5() {
        assert_clipboard(
            b"5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==",
            Expected {
                metadata: b"type=wdata:mime=dGV4dC9wbGFpbg==",
                payload: Some(b"R2hvc3R0eQ=="),
                mime: Some(b"dGV4dC9wbGFpbg=="),
                operation: Some(KittyClipboardOperation::Wdata),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 6" (kitty_clipboard_protocol.zig:484)
    #[test]
    fn osc5522_example_6() {
        assert_clipboard(
            b"5522;type=wdata",
            Expected {
                metadata: b"type=wdata",
                operation: Some(KittyClipboardOperation::Wdata),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 7" (kitty_clipboard_protocol.zig:506)
    #[test]
    fn osc5522_example_7() {
        assert_clipboard(
            b"5522;type=write:status=DONE",
            Expected {
                metadata: b"type=write:status=DONE",
                status: Some(KittyClipboardStatus::Done),
                operation: Some(KittyClipboardOperation::Write),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 8" (kitty_clipboard_protocol.zig:528)
    #[test]
    fn osc5522_example_8() {
        assert_clipboard(
            b"5522;type=write:status=EPERM",
            Expected {
                metadata: b"type=write:status=EPERM",
                status: Some(KittyClipboardStatus::Eperm),
                operation: Some(KittyClipboardOperation::Write),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 9" (kitty_clipboard_protocol.zig:550)
    #[test]
    fn osc5522_example_9() {
        assert_clipboard(
            b"5522;type=walias:mime=dGV4dC9wbGFpbg==;dGV4dC9odG1sIGFwcGxpY2F0aW9uL2pzb24=",
            Expected {
                metadata: b"type=walias:mime=dGV4dC9wbGFpbg==",
                payload: Some(b"dGV4dC9odG1sIGFwcGxpY2F0aW9uL2pzb24="),
                mime: Some(b"dGV4dC9wbGFpbg=="),
                operation: Some(KittyClipboardOperation::Walias),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 10" (kitty_clipboard_protocol.zig:572)
    #[test]
    fn osc5522_example_10() {
        assert_clipboard(
            b"5522;type=read:status=OK:password=Qk9CUiBLVVJXQQ==",
            Expected {
                metadata: b"type=read:status=OK:password=Qk9CUiBLVVJXQQ==",
                password: Some(b"Qk9CUiBLVVJXQQ=="),
                status: Some(KittyClipboardStatus::Ok),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 11" (kitty_clipboard_protocol.zig:594)
    #[test]
    fn osc5522_example_11() {
        assert_clipboard(
            b"5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==",
            Expected {
                metadata: b"type=read:status=DATA:mime=dGV4dC9wbGFpbg==",
                mime: Some(b"dGV4dC9wbGFpbg=="),
                status: Some(KittyClipboardStatus::Data),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 12" (kitty_clipboard_protocol.zig:616)
    #[test]
    fn osc5522_example_12() {
        assert_clipboard(
            b"5522;type=read:mime=dGV4dC9wbGFpbg==:password=Qk9CUiBLVVJXQQ==",
            Expected {
                metadata: b"type=read:mime=dGV4dC9wbGFpbg==:password=Qk9CUiBLVVJXQQ==",
                mime: Some(b"dGV4dC9wbGFpbg=="),
                password: Some(b"Qk9CUiBLVVJXQQ=="),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 13" (kitty_clipboard_protocol.zig:638)
    #[test]
    fn osc5522_example_13() {
        assert_clipboard(
            b"5522;type=read:status=OK",
            Expected {
                metadata: b"type=read:status=OK",
                status: Some(KittyClipboardStatus::Ok),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 14" (kitty_clipboard_protocol.zig:660)
    #[test]
    fn osc5522_example_14() {
        assert_clipboard(
            b"5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;Qk9CUiBLVVJXQQ==",
            Expected {
                metadata: b"type=read:status=DATA:mime=dGV4dC9wbGFpbg==",
                payload: Some(b"Qk9CUiBLVVJXQQ=="),
                mime: Some(b"dGV4dC9wbGFpbg=="),
                status: Some(KittyClipboardStatus::Data),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }

    // ghostty: "OSC: 5522: example 15" (kitty_clipboard_protocol.zig:682)
    #[test]
    fn osc5522_example_15() {
        assert_clipboard(
            b"5522;type=read:status=OK",
            Expected {
                metadata: b"type=read:status=OK",
                status: Some(KittyClipboardStatus::Ok),
                operation: Some(KittyClipboardOperation::Read),
                ..Expected::default()
            },
        );
    }
}
