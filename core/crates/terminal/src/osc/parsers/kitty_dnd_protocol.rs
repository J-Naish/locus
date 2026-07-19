use crate::osc::{Pending, Terminator};

use super::kitty_options::find_option_value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KittyDnd<'a> {
    pub metadata: &'a [u8],
    pub payload: Option<&'a [u8]>,
    pub terminator: Terminator,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyDndEventType {
    AcceptDrops,
    StopAcceptingDrops,
    DropMove,
    DropDropped,
    RequestData,
    RequestError,
    OfferDrag,
    PresentData,
    ChangeDragImage,
    DragOfferEvent,
    DragOfferError,
    UriListData,
    Query,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KittyDndIntOption {
    M,
    I,
    O,
    LowerX,
    LowerY,
    UpperX,
    UpperY,
}

impl KittyDndIntOption {
    fn key(self) -> &'static [u8] {
        match self {
            Self::M => b"m",
            Self::I => b"i",
            Self::O => b"o",
            Self::LowerX => b"x",
            Self::LowerY => b"y",
            Self::UpperX => b"X",
            Self::UpperY => b"Y",
        }
    }
}

impl<'a> KittyDnd<'a> {
    pub fn read_event_type(self) -> Option<KittyDndEventType> {
        let value = find_option_value(self.metadata, b"t")?;
        if value.len() != 1 {
            return None;
        }
        Some(match value[0] {
            b'a' => KittyDndEventType::AcceptDrops,
            b'A' => KittyDndEventType::StopAcceptingDrops,
            b'm' => KittyDndEventType::DropMove,
            b'M' => KittyDndEventType::DropDropped,
            b'r' => KittyDndEventType::RequestData,
            b'R' => KittyDndEventType::RequestError,
            b'o' => KittyDndEventType::OfferDrag,
            b'p' => KittyDndEventType::PresentData,
            b'P' => KittyDndEventType::ChangeDragImage,
            b'e' => KittyDndEventType::DragOfferEvent,
            b'E' => KittyDndEventType::DragOfferError,
            b'k' => KittyDndEventType::UriListData,
            b'q' => KittyDndEventType::Query,
            _ => return None,
        })
    }

    pub fn read_int(self, option: KittyDndIntOption) -> Option<i32> {
        std::str::from_utf8(find_option_value(self.metadata, option.key())?)
            .ok()?
            .parse::<i32>()
            .ok()
    }
}

pub(crate) fn parse(data: &[u8], terminator: Terminator) -> Pending {
    let separator = data.iter().position(|byte| *byte == b';');
    let (metadata, payload) = if let Some(separator) = separator {
        (0..separator, Some(separator + 1..data.len()))
    } else {
        (0..data.len(), None)
    };
    Pending::KittyDndProtocol {
        metadata,
        payload,
        terminator,
    }
}

#[cfg(test)]
mod tests {
    use super::{KittyDnd, KittyDndEventType, KittyDndIntOption};
    use crate::osc::{Command, Terminator};

    fn dnd_for(input: &[u8], terminator: Option<u8>) -> (crate::osc::Parser, KittyDnd<'static>) {
        let parser = super::super::parse_body(input, terminator);
        let Some(Command::KittyDndProtocol(dnd)) = parser.command() else {
            panic!("expected kitty dnd command");
        };
        let owned = KittyDnd {
            metadata: Box::leak(dnd.metadata.to_vec().into_boxed_slice()),
            payload: dnd
                .payload
                .map(|payload| Box::leak(payload.to_vec().into_boxed_slice()) as &'static [u8]),
            terminator: dnd.terminator,
        };
        (parser, owned)
    }

    // ghostty: "OSC 72: metadata only, no payload" (kitty_dnd_protocol.zig:150)
    #[test]
    fn osc72_metadata_only_has_no_payload() {
        let (_, dnd) = dnd_for(b"72;t=a", Some(0x1b));
        assert_eq!(dnd.metadata, b"t=a");
        assert_eq!(dnd.payload, None);
    }

    // ghostty: "OSC 72: metadata and empty payload" (kitty_dnd_protocol.zig:164)
    #[test]
    fn osc72_metadata_and_empty_payload() {
        let (_, dnd) = dnd_for(b"72;t=a;", Some(0x1b));
        assert_eq!(dnd.metadata, b"t=a");
        assert_eq!(dnd.payload, Some(&b""[..]));
    }

    // ghostty: "OSC 72: metadata and non-empty payload" (kitty_dnd_protocol.zig:178)
    #[test]
    fn osc72_metadata_and_non_empty_payload() {
        let (_, dnd) = dnd_for(b"72;t=a:i=5;text/plain text/uri-list", Some(0x1b));
        assert_eq!(dnd.metadata, b"t=a:i=5");
        assert_eq!(dnd.payload, Some(&b"text/plain text/uri-list"[..]));
    }

    // ghostty: "OSC 72: readOption .t valid event types" (kitty_dnd_protocol.zig:192)
    #[test]
    fn osc72_reads_all_valid_event_types() {
        let cases = [
            (b"72;t=a".as_slice(), KittyDndEventType::AcceptDrops),
            (b"72;t=A".as_slice(), KittyDndEventType::StopAcceptingDrops),
            (b"72;t=m".as_slice(), KittyDndEventType::DropMove),
            (b"72;t=M".as_slice(), KittyDndEventType::DropDropped),
            (b"72;t=r".as_slice(), KittyDndEventType::RequestData),
            (b"72;t=R".as_slice(), KittyDndEventType::RequestError),
            (b"72;t=o".as_slice(), KittyDndEventType::OfferDrag),
            (b"72;t=p".as_slice(), KittyDndEventType::PresentData),
            (b"72;t=P".as_slice(), KittyDndEventType::ChangeDragImage),
            (b"72;t=e".as_slice(), KittyDndEventType::DragOfferEvent),
            (b"72;t=E".as_slice(), KittyDndEventType::DragOfferError),
            (b"72;t=k".as_slice(), KittyDndEventType::UriListData),
            (b"72;t=q".as_slice(), KittyDndEventType::Query),
        ];
        for (input, expected) in cases {
            let (_, dnd) = dnd_for(input, Some(0x1b));
            assert_eq!(dnd.read_event_type(), Some(expected));
        }
    }

    // ghostty: "OSC 72: readOption .t unknown value returns null" (kitty_dnd_protocol.zig:219)
    #[test]
    fn osc72_unknown_event_type_returns_none() {
        let (_, dnd) = dnd_for(b"72;t=z", Some(0x1b));
        assert_eq!(dnd.read_event_type(), None);
    }

    // ghostty: "OSC 72: readOption integer keys" (kitty_dnd_protocol.zig:233)
    #[test]
    fn osc72_reads_integer_keys() {
        let (_, dnd) = dnd_for(b"72;t=m:i=3:x=10:y=5:X=320:Y=200:o=1:m=0", Some(0x1b));
        assert_eq!(dnd.read_int(KittyDndIntOption::I), Some(3));
        assert_eq!(dnd.read_int(KittyDndIntOption::LowerX), Some(10));
        assert_eq!(dnd.read_int(KittyDndIntOption::LowerY), Some(5));
        assert_eq!(dnd.read_int(KittyDndIntOption::UpperX), Some(320));
        assert_eq!(dnd.read_int(KittyDndIntOption::UpperY), Some(200));
        assert_eq!(dnd.read_int(KittyDndIntOption::O), Some(1));
        assert_eq!(dnd.read_int(KittyDndIntOption::M), Some(0));
    }

    // ghostty: "OSC 72: readOption negative sentinel (-1 for drag leave)" (kitty_dnd_protocol.zig:255)
    #[test]
    fn osc72_reads_negative_drag_leave_sentinel() {
        let (_, dnd) = dnd_for(b"72;t=m:x=-1:y=-1", Some(0x1b));
        assert_eq!(dnd.read_int(KittyDndIntOption::LowerX), Some(-1));
        assert_eq!(dnd.read_int(KittyDndIntOption::LowerY), Some(-1));
    }

    // ghostty: "OSC 72: readOption case-sensitive key matching" (kitty_dnd_protocol.zig:271)
    #[test]
    fn osc72_reads_case_sensitive_integer_keys() {
        let (_, dnd) = dnd_for(b"72;x=10:Y=200", Some(0x1b));
        assert_eq!(dnd.read_int(KittyDndIntOption::LowerX), Some(10));
        assert_eq!(dnd.read_int(KittyDndIntOption::UpperX), None);
        assert_eq!(dnd.read_int(KittyDndIntOption::UpperY), Some(200));
        assert_eq!(dnd.read_int(KittyDndIntOption::LowerY), None);
    }

    // ghostty: "OSC 72: readOption absent key returns null" (kitty_dnd_protocol.zig:290)
    #[test]
    fn osc72_absent_integer_keys_return_none() {
        let (_, dnd) = dnd_for(b"72;t=a", Some(0x1b));
        assert_eq!(dnd.read_int(KittyDndIntOption::I), None);
        assert_eq!(dnd.read_int(KittyDndIntOption::LowerX), None);
        assert_eq!(dnd.read_int(KittyDndIntOption::UpperX), None);
        assert_eq!(dnd.read_int(KittyDndIntOption::M), None);
    }

    // ghostty: "OSC 72: readOption malformed integer returns null" (kitty_dnd_protocol.zig:307)
    #[test]
    fn osc72_malformed_integer_returns_none() {
        let (_, dnd) = dnd_for(b"72;x=notanumber", Some(0x1b));
        assert_eq!(dnd.read_int(KittyDndIntOption::LowerX), None);
    }

    // ghostty: "OSC 72: BEL terminator recorded" (kitty_dnd_protocol.zig:321)
    #[test]
    fn osc72_records_bel_terminator() {
        let (_, dnd) = dnd_for(b"72;t=q", Some(0x07));
        assert_eq!(dnd.terminator, Terminator::Bel);
    }
}
