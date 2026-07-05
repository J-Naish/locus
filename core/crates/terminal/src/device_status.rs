//! Device status report request classifier.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorScheme {
    Light,
    Dark,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Request {
    OperatingStatus,
    CursorPosition,
    ColorScheme,
}

impl Request {
    pub fn from_int(value: u16, question: bool) -> Option<Self> {
        match (value, question) {
            (5, false) => Some(Self::OperatingStatus),
            (6, false) => Some(Self::CursorPosition),
            (996, true) => Some(Self::ColorScheme),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Request;

    #[test]
    fn request_from_int_requires_matching_question_prefix() {
        assert_eq!(Request::from_int(5, false), Some(Request::OperatingStatus));
        assert_eq!(Request::from_int(6, false), Some(Request::CursorPosition));
        assert_eq!(Request::from_int(996, true), Some(Request::ColorScheme));
        assert_eq!(Request::from_int(5, true), None);
        assert_eq!(Request::from_int(996, false), None);
        assert_eq!(Request::from_int(999, false), None);
    }
}
