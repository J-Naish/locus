use crate::osc::Pending;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextAction {
    Start,
    End,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ContextSignal<'a> {
    pub action: ContextAction,
    pub id: &'a [u8],
    pub metadata: &'a [u8],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextType {
    Boot,
    Container,
    Vm,
    Elevate,
    Chpriv,
    Subcontext,
    Remote,
    Shell,
    Command,
    App,
    Service,
    Session,
}

impl ContextType {
    fn parse(value: &[u8]) -> Option<Self> {
        Some(match value {
            b"boot" => Self::Boot,
            b"container" => Self::Container,
            b"vm" => Self::Vm,
            b"elevate" => Self::Elevate,
            b"chpriv" => Self::Chpriv,
            b"subcontext" => Self::Subcontext,
            b"remote" => Self::Remote,
            b"shell" => Self::Shell,
            b"command" => Self::Command,
            b"app" => Self::App,
            b"service" => Self::Service,
            b"session" => Self::Session,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextExitStatus {
    Success,
    Failure,
    Crash,
    Interrupt,
}

impl ContextExitStatus {
    fn parse(value: &[u8]) -> Option<Self> {
        Some(match value {
            b"success" => Self::Success,
            b"failure" => Self::Failure,
            b"crash" => Self::Crash,
            b"interrupt" => Self::Interrupt,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PendingContextSignal {
    pub action: ContextAction,
    pub id: std::ops::Range<usize>,
    pub metadata: std::ops::Range<usize>,
}

impl<'a> ContextSignal<'a> {
    pub fn read_user(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"user")
    }
    pub fn read_hostname(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"hostname")
    }
    pub fn read_machineid(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"machineid")
    }
    pub fn read_bootid(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"bootid")
    }
    pub fn read_comm(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"comm")
    }
    pub fn read_cwd(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"cwd")
    }
    pub fn read_cmdline(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"cmdline")
    }
    pub fn read_vm(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"vm")
    }
    pub fn read_container(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"container")
    }
    pub fn read_targetuser(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"targetuser")
    }
    pub fn read_targethost(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"targethost")
    }
    pub fn read_sessionid(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"sessionid")
    }
    pub fn read_signal(self) -> Option<&'a [u8]> {
        read_non_empty(self.metadata, b"signal")
    }
    pub fn read_pid(self) -> Option<u64> {
        read_u64(self.metadata, b"pid")
    }
    pub fn read_pidfdid(self) -> Option<u64> {
        read_u64(self.metadata, b"pidfdid")
    }
    pub fn read_status(self) -> Option<u64> {
        read_u64(self.metadata, b"status")
    }
    pub fn read_type(self) -> Option<ContextType> {
        ContextType::parse(read_option(self.metadata, b"type")?)
    }
    pub fn read_exit(self) -> Option<ContextExitStatus> {
        ContextExitStatus::parse(read_option(self.metadata, b"exit")?)
    }
}

pub(crate) fn parse(data: &[u8]) -> Option<Pending> {
    let (action, rest) = if let Some(rest) = data.strip_prefix(b"start=") {
        (ContextAction::Start, rest)
    } else if let Some(rest) = data.strip_prefix(b"end=") {
        (ContextAction::End, rest)
    } else {
        return None;
    };
    if rest.is_empty() {
        return None;
    }
    let id_end_in_rest = rest
        .iter()
        .position(|byte| *byte == b';')
        .unwrap_or(rest.len());
    let id = &rest[..id_end_in_rest];
    if id.is_empty() || id.len() > 64 || !id.iter().all(|byte| (0x20..=0x7E).contains(byte)) {
        return None;
    }
    let offset = data.len() - rest.len();
    let id_range = offset..offset + id_end_in_rest;
    let metadata = if id_end_in_rest == rest.len() {
        data.len()..data.len()
    } else {
        offset + id_end_in_rest + 1..data.len()
    };
    Some(Pending::ContextSignal(PendingContextSignal {
        action,
        id: id_range,
        metadata,
    }))
}

fn read_non_empty<'a>(metadata: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    let value = read_option(metadata, key)?;
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

fn read_u64(metadata: &[u8], key: &[u8]) -> Option<u64> {
    let value = read_option(metadata, key)?;
    if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
        return None;
    }
    std::str::from_utf8(value).ok()?.parse::<u64>().ok()
}

fn read_option<'a>(metadata: &'a [u8], key: &[u8]) -> Option<&'a [u8]> {
    for segment in metadata.split(|byte| *byte == b';') {
        let Some(eq) = segment.iter().position(|byte| *byte == b'=') else {
            continue;
        };
        if &segment[..eq] == key {
            return Some(&segment[eq + 1..]);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{ContextAction, ContextExitStatus, ContextSignal, ContextType};
    use crate::osc::Command;

    fn with_context(input: &[u8], check: impl FnOnce(ContextSignal<'_>)) {
        let parser = super::super::parse_body(input, None);
        let Some(Command::ContextSignal(signal)) = parser.command() else {
            panic!("expected context signal command");
        };
        check(signal);
    }

    fn assert_no_context(input: &[u8]) {
        let parser = super::super::parse_body(input, None);
        assert!(parser.command().is_none());
    }

    // ghostty: "OSC 3008: basic start command" (context_signal.zig:280)
    #[test]
    fn osc3008_basic_start_command() {
        with_context(b"3008;start=abc123", |signal| {
            assert_eq!(signal.action, ContextAction::Start);
            assert_eq!(signal.id, b"abc123");
            assert_eq!(signal.metadata, b"");
        });
    }

    // ghostty: "OSC 3008: basic end command" (context_signal.zig:292)
    #[test]
    fn osc3008_basic_end_command() {
        with_context(b"3008;end=abc123", |signal| {
            assert_eq!(signal.action, ContextAction::End);
            assert_eq!(signal.id, b"abc123");
            assert_eq!(signal.metadata, b"");
        });
    }

    // ghostty: "OSC 3008: start with metadata fields" (context_signal.zig:304)
    #[test]
    fn osc3008_start_with_metadata_fields() {
        with_context(
            b"3008;start=bed86fab93af4328bbed0a1224af6d40;type=container;user=lennart;hostname=zeta",
            |signal| {
                assert_eq!(signal.action, ContextAction::Start);
                assert_eq!(signal.id, b"bed86fab93af4328bbed0a1224af6d40");
                assert_eq!(signal.read_type(), Some(ContextType::Container));
                assert_eq!(signal.read_user(), Some(&b"lennart"[..]));
                assert_eq!(signal.read_hostname(), Some(&b"zeta"[..]));
            },
        );
    }

    // ghostty: "OSC 3008: start with all common fields" (context_signal.zig:320)
    #[test]
    fn osc3008_start_with_all_common_fields() {
        with_context(
            b"3008;start=myctx;type=shell;user=root;hostname=myhost;machineid=3deb5353d3ba43d08201c136a47ead7b;bootid=d4a3d0fdf2e24fdea6d971ce73f4fbf2;pid=1062862;pidfdid=1063162;comm=bash",
            |signal| {
                assert_eq!(signal.read_type(), Some(ContextType::Shell));
                assert_eq!(signal.read_user(), Some(&b"root"[..]));
                assert_eq!(signal.read_hostname(), Some(&b"myhost"[..]));
                assert_eq!(signal.read_machineid(), Some(&b"3deb5353d3ba43d08201c136a47ead7b"[..]));
                assert_eq!(signal.read_bootid(), Some(&b"d4a3d0fdf2e24fdea6d971ce73f4fbf2"[..]));
                assert_eq!(signal.read_pid(), Some(1_062_862));
                assert_eq!(signal.read_pidfdid(), Some(1_063_162));
                assert_eq!(signal.read_comm(), Some(&b"bash"[..]));
            },
        );
    }

    // ghostty: "OSC 3008: end with exit metadata" (context_signal.zig:340)
    #[test]
    fn osc3008_end_with_exit_metadata() {
        with_context(b"3008;end=myctx;exit=success;status=0", |signal| {
            assert_eq!(signal.action, ContextAction::End);
            assert_eq!(signal.id, b"myctx");
            assert_eq!(signal.read_exit(), Some(ContextExitStatus::Success));
            assert_eq!(signal.read_status(), Some(0));
        });
    }

    // ghostty: "OSC 3008: end with failure exit" (context_signal.zig:354)
    #[test]
    fn osc3008_end_with_failure_exit() {
        with_context(
            b"3008;end=myctx;exit=failure;status=1;signal=SIGKILL",
            |signal| {
                assert_eq!(signal.read_exit(), Some(ContextExitStatus::Failure));
                assert_eq!(signal.read_status(), Some(1));
                assert_eq!(signal.read_signal(), Some(&b"SIGKILL"[..]));
            },
        );
    }

    // ghostty: "OSC 3008: unknown fields are ignored" (context_signal.zig:367)
    #[test]
    fn osc3008_unknown_fields_are_ignored() {
        with_context(
            b"3008;start=myctx;type=shell;unknownfield=value;user=root",
            |signal| {
                assert_eq!(signal.read_type(), Some(ContextType::Shell));
                assert_eq!(signal.read_user(), Some(&b"root"[..]));
            },
        );
    }

    // ghostty: "OSC 3008: missing field returns null" (context_signal.zig:380)
    #[test]
    fn osc3008_missing_fields_return_none() {
        with_context(b"3008;start=myctx;user=lennart", |signal| {
            assert_eq!(signal.read_type(), None);
            assert_eq!(signal.read_hostname(), None);
            assert_eq!(signal.read_pid(), None);
        });
    }

    // ghostty: "OSC 3008: invalid prefix" (context_signal.zig:393)
    #[test]
    fn osc3008_invalid_prefix_is_rejected() {
        assert_no_context(b"3008;bogus=abc123");
    }

    // ghostty: "OSC 3008: empty data" (context_signal.zig:403)
    #[test]
    fn osc3008_missing_context_id_is_rejected() {
        assert_no_context(b"3008;start=");
    }

    // ghostty: "OSC 3008: max length context ID" (context_signal.zig:414)
    #[test]
    fn osc3008_accepts_max_length_context_id() {
        let id = b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        let mut input = Vec::from(&b"3008;start="[..]);
        input.extend(id);
        with_context(&input, |signal| {
            assert_eq!(signal.action, ContextAction::Start);
            assert_eq!(signal.id, id);
        });
    }

    // ghostty: "OSC 3008: over-length context ID" (context_signal.zig:428)
    #[test]
    fn osc3008_rejects_over_length_context_id() {
        let mut input = Vec::from(&b"3008;start="[..]);
        input.extend(std::iter::repeat_n(b'a', 65));
        assert_no_context(&input);
    }

    // ghostty: "OSC 3008: context type enum coverage" (context_signal.zig:439)
    #[test]
    fn context_type_parse_covers_all_ghostty_values() {
        let cases = [
            (b"boot".as_slice(), ContextType::Boot),
            (b"container".as_slice(), ContextType::Container),
            (b"vm".as_slice(), ContextType::Vm),
            (b"elevate".as_slice(), ContextType::Elevate),
            (b"chpriv".as_slice(), ContextType::Chpriv),
            (b"subcontext".as_slice(), ContextType::Subcontext),
            (b"remote".as_slice(), ContextType::Remote),
            (b"shell".as_slice(), ContextType::Shell),
            (b"command".as_slice(), ContextType::Command),
            (b"app".as_slice(), ContextType::App),
            (b"service".as_slice(), ContextType::Service),
            (b"session".as_slice(), ContextType::Session),
        ];
        for (input, expected) in cases {
            assert_eq!(ContextType::parse(input), Some(expected));
        }
        assert_eq!(ContextType::parse(b"invalid"), None);
    }

    // ghostty: "OSC 3008: exit status enum coverage" (context_signal.zig:464)
    #[test]
    fn context_exit_status_parse_covers_all_ghostty_values() {
        assert_eq!(
            ContextExitStatus::parse(b"success"),
            Some(ContextExitStatus::Success)
        );
        assert_eq!(
            ContextExitStatus::parse(b"failure"),
            Some(ContextExitStatus::Failure)
        );
        assert_eq!(
            ContextExitStatus::parse(b"crash"),
            Some(ContextExitStatus::Crash)
        );
        assert_eq!(
            ContextExitStatus::parse(b"interrupt"),
            Some(ContextExitStatus::Interrupt)
        );
        assert_eq!(ContextExitStatus::parse(b"invalid"), None);
    }

    // ghostty: "OSC 3008: spec example - container start" (context_signal.zig:476)
    #[test]
    fn osc3008_spec_example_container_start() {
        with_context(
            b"3008;start=bed86fab93af4328bbed0a1224af6d40;type=container;user=lennart;hostname=zeta;machineid=3deb5353d3ba43d08201c136a47ead7b;bootid=d4a3d0fdf2e24fdea6d971ce73f4fbf2;pid=1062862;pidfdid=1063162;comm=systemd-nspawn;container=foobar",
            |signal| {
                assert_eq!(signal.action, ContextAction::Start);
                assert_eq!(signal.id, b"bed86fab93af4328bbed0a1224af6d40");
                assert_eq!(signal.read_type(), Some(ContextType::Container));
                assert_eq!(signal.read_user(), Some(&b"lennart"[..]));
                assert_eq!(signal.read_hostname(), Some(&b"zeta"[..]));
                assert_eq!(signal.read_comm(), Some(&b"systemd-nspawn"[..]));
                assert_eq!(signal.read_container(), Some(&b"foobar"[..]));
                assert_eq!(signal.read_pid(), Some(1_062_862));
            },
        );
    }

    // ghostty: "OSC 3008: spec example - context end" (context_signal.zig:498)
    #[test]
    fn osc3008_spec_example_context_end() {
        with_context(b"3008;end=bed86fab93af4328bbed0a1224af6d40", |signal| {
            assert_eq!(signal.action, ContextAction::End);
            assert_eq!(signal.id, b"bed86fab93af4328bbed0a1224af6d40");
        });
    }

    // ghostty: "OSC 3008: cwd and cmdline fields" (context_signal.zig:511)
    #[test]
    fn osc3008_reads_cwd_and_cmdline_fields() {
        with_context(
            b"3008;start=myctx;type=command;cwd=/home/user;cmdline=ls -la",
            |signal| {
                assert_eq!(signal.read_cwd(), Some(&b"/home/user"[..]));
                assert_eq!(signal.read_cmdline(), Some(&b"ls -la"[..]));
            },
        );
    }

    // ghostty: "OSC 3008: start command with no fields" (context_signal.zig:524)
    #[test]
    fn osc3008_start_command_with_no_fields() {
        with_context(b"3008;start=simpleid", |signal| {
            assert_eq!(signal.action, ContextAction::Start);
            assert_eq!(signal.id, b"simpleid");
            assert_eq!(signal.read_type(), None);
            assert_eq!(signal.read_user(), None);
            assert_eq!(signal.read_exit(), None);
        });
    }
}
