//! Default codepoint sets for selection behavior.

pub const DEFAULT_WORD_BOUNDARIES: [char; 20] = [
    '\0', ' ', '\t', '\'', '"', '\u{2502}', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}',
    '<', '>', '$',
];

pub const DEFAULT_LINE_WHITESPACE: [char; 3] = ['\0', ' ', '\t'];

#[cfg(test)]
mod tests {
    use super::{DEFAULT_LINE_WHITESPACE, DEFAULT_WORD_BOUNDARIES};

    #[test]
    fn default_selection_codepoint_sets_match_expected_membership() {
        assert_eq!(DEFAULT_WORD_BOUNDARIES.len(), 20);
        assert_eq!(DEFAULT_LINE_WHITESPACE.len(), 3);
        assert!(DEFAULT_WORD_BOUNDARIES.contains(&'\u{2502}'));
        assert!(DEFAULT_WORD_BOUNDARIES.contains(&'$'));
        assert!(DEFAULT_WORD_BOUNDARIES.contains(&'\0'));
        assert!(!DEFAULT_WORD_BOUNDARIES.contains(&'a'));
        assert!(DEFAULT_LINE_WHITESPACE.contains(&'\0'));
        assert!(DEFAULT_LINE_WHITESPACE.contains(&' '));
        assert!(DEFAULT_LINE_WHITESPACE.contains(&'\t'));
    }
}
