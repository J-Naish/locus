//! Unicode properties and grapheme segmentation for the terminal print path.
//!
//! Runtime classification uses a generated two-level lookup table derived from
//! the vendored Unicode 16.0.0 data. The break engine follows UAX #29 with the
//! same isolated emoji-modifier tailoring as Ghostty.

mod tables;

#[cfg(test)]
use unicode_width::UnicodeWidthChar;

/// UAX #29 grapheme cluster break property plus Ghostty's emoji and Indic
/// tailoring classes. The terminal filters controls before printing, while the
/// classifier retains them so the official conformance suite can exercise the
/// break engine independently.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphemeBreak {
    Other,
    Cr,
    Lf,
    Control,
    Prepend,
    Extend,
    Zwj,
    RegionalIndicator,
    SpacingMark,
    L,
    V,
    T,
    Lv,
    Lvt,
    ExtendedPictographic,
    /// Emoji modifier (Fitzpatrick skin tone). These are `Extend`-like but only
    /// join a preceding extended-pictographic base; after any other base they
    /// begin a new cluster. Ghostty's precomputed table reflects this behavior
    /// (a skin tone does not attach to, e.g., a quote character).
    EmojiModifier,
    /// Emoji base allowed to accept an immediately following skin-tone
    /// modifier under Ghostty's UTS #51 tailoring.
    EmojiModifierBase,
    /// Indic conjunct "linker" (e.g. virama). This is an `Extend` code point
    /// that additionally participates in the Indic conjunct break rule
    /// (UAX #29 GB9c). Ghostty folds the InCB=Linker information into the
    /// break-state machine; we surface it as its own class for clarity.
    ExtendLinker,
    /// InCB=Extend. It behaves as GCB=Extend and also advances GB9c state.
    IndicConjunctExtend,
    /// Indic conjunct "consonant" (InCB=Consonant). These are `Other` for every
    /// rule except GB9c.
    ConsonantConjunct,
}

impl GraphemeBreak {
    /// True if this class counts as `Extend` for the purposes of continuing an
    /// extended-pictographic (GB11) or Indic-conjunct (GB9c) run.
    const fn is_grapheme_extend(self) -> bool {
        matches!(
            self,
            Self::Extend | Self::ExtendLinker | Self::IndicConjunctExtend
        )
    }

    /// True if this class continues an existing cluster's "extend" run without
    /// itself forcing a break decision here (used to thread the GB11/GB9c run
    /// state). Emoji modifiers count so that a skin tone extends an emoji run.
    const fn continues_extend_run(self) -> bool {
        self.is_grapheme_extend() || matches!(self, Self::EmojiModifier)
    }

    pub(crate) const fn is_extended_pictographic(self) -> bool {
        matches!(self, Self::ExtendedPictographic | Self::EmojiModifierBase)
    }
}

/// The properties the terminal cares about for a single code point. Mirrors
/// Ghostty's `unicode.Properties`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Properties {
    /// Display width clamped to `[0, 2]`.
    pub width: u8,
    /// Whether the code point does not contribute width when it is part of a
    /// grapheme cluster (i.e. combining/zero-width members).
    pub width_zero_in_grapheme: bool,
    /// Grapheme break class.
    pub grapheme_break: GraphemeBreak,
    /// Whether the code point is a valid base for an emoji variation selector
    /// (VS15/VS16), per `emoji-variation-sequences.txt`.
    pub emoji_vs_base: bool,
}

/// Look up the [`Properties`] for a code point.
pub fn props(cp: u32) -> Properties {
    let packed = tables::packed(cp);
    Properties {
        width: packed_width(packed),
        width_zero_in_grapheme: packed & (1 << 6) != 0,
        grapheme_break: packed_grapheme_break(packed),
        emoji_vs_base: emoji_vs_base(cp),
    }
}

/// Width-only lookup for the print hot path: identical to
/// [`props`]`.width` by construction, without computing grapheme and emoji
/// properties that the caller does not use.
#[inline]
pub fn width(cp: u32) -> u8 {
    packed_width(tables::packed(cp))
}

#[inline]
const fn packed_width(packed: u16) -> u8 {
    ((packed >> 4) & 0b11) as u8
}

/// Classify a code point into its UAX #29 grapheme-break class (no control).
#[inline]
pub(crate) fn grapheme_break_class(cp: u32) -> GraphemeBreak {
    packed_grapheme_break(tables::packed(cp))
}

#[inline]
fn packed_grapheme_break(packed: u16) -> GraphemeBreak {
    let grapheme = packed & 0b1111;
    if grapheme == 5 {
        return GraphemeBreak::Zwj;
    }
    if packed & (1 << 8) != 0 {
        return GraphemeBreak::EmojiModifier;
    }
    if packed & (1 << 11) != 0 {
        return GraphemeBreak::EmojiModifierBase;
    }
    match (packed >> 9) & 0b11 {
        1 => return GraphemeBreak::ConsonantConjunct,
        2 => return GraphemeBreak::ExtendLinker,
        3 => return GraphemeBreak::IndicConjunctExtend,
        _ => {}
    }
    if packed & (1 << 7) != 0 {
        return GraphemeBreak::ExtendedPictographic;
    }
    match grapheme {
        0 => GraphemeBreak::Other,
        1 => GraphemeBreak::Cr,
        2 => GraphemeBreak::Lf,
        3 => GraphemeBreak::Control,
        4 => GraphemeBreak::Extend,
        5 => GraphemeBreak::Zwj,
        6 => GraphemeBreak::RegionalIndicator,
        7 => GraphemeBreak::Prepend,
        8 => GraphemeBreak::SpacingMark,
        9 => GraphemeBreak::L,
        10 => GraphemeBreak::V,
        11 => GraphemeBreak::T,
        12 => GraphemeBreak::Lv,
        13 => GraphemeBreak::Lvt,
        _ => GraphemeBreak::Other,
    }
}

/// Whether a code point is a valid base for an emoji presentation variation
/// selector (VS15/VS16). Derived from `emoji-variation-sequences.txt`; scoped
/// to the bases the terminal's tests distinguish. Notably this is `false` for
/// emoji that already have a fixed presentation (e.g. most `U+1Fxxx` faces),
/// which is why an invalid VS is dropped rather than resizing the cell.
fn emoji_vs_base(cp: u32) -> bool {
    matches!(cp,
        // Digits/number sign/asterisk keycap bases.
        0x0023 | 0x002A | 0x0030..=0x0039
        // Assorted dingbats and symbols with both text and emoji presentation.
        | 0x00A9 | 0x00AE
        | 0x203C | 0x2049 | 0x2122 | 0x2139
        | 0x2194..=0x2199 | 0x21A9..=0x21AA
        | 0x231A..=0x231B | 0x2328 | 0x23CF
        | 0x23E9..=0x23EA | 0x23ED..=0x23EF | 0x23F1..=0x23F2 | 0x23F8..=0x23FA
        | 0x24C2
        | 0x25AA..=0x25AB | 0x25B6 | 0x25C0 | 0x25FB..=0x25FE
        | 0x2600..=0x2604 | 0x260E | 0x2611 | 0x2614..=0x2615 | 0x2618 | 0x261D
        | 0x2620 | 0x2622..=0x2623 | 0x2626 | 0x262A | 0x262E..=0x262F | 0x2638..=0x263A
        | 0x2640 | 0x2642 | 0x2648..=0x2653 | 0x265F | 0x2660 | 0x2663 | 0x2665..=0x2666
        | 0x2668 | 0x267B | 0x267E..=0x267F | 0x2692..=0x2697 | 0x2699 | 0x269B..=0x269C
        | 0x26A0..=0x26A1 | 0x26A7 | 0x26AA..=0x26AB | 0x26B0..=0x26B1 | 0x26BD..=0x26BE
        | 0x26C4..=0x26C5 | 0x26C8 | 0x26CE..=0x26CF | 0x26D1 | 0x26D3..=0x26D4
        | 0x26E9..=0x26EA | 0x26F0..=0x26F5 | 0x26F7..=0x26FA | 0x26FD
        | 0x2702 | 0x2708..=0x2709 | 0x270C..=0x270D | 0x270F | 0x2712 | 0x2714 | 0x2716
        | 0x271D | 0x2721 | 0x2733..=0x2734 | 0x2744 | 0x2747 | 0x2757 | 0x2763..=0x2764
        | 0x27A1 | 0x2934..=0x2935 | 0x2B05..=0x2B07 | 0x2B1B..=0x2B1C | 0x2B50 | 0x2B55
        | 0x3030 | 0x303D | 0x3297 | 0x3299
        | 0x1F004 | 0x1F170..=0x1F171 | 0x1F17E..=0x1F17F | 0x1F202
        | 0x1F237 | 0x1F321 | 0x1F324..=0x1F32C | 0x1F336 | 0x1F37D
        | 0x1F396..=0x1F397 | 0x1F399..=0x1F39B | 0x1F39E..=0x1F39F | 0x1F3CB..=0x1F3CE
        | 0x1F3D4..=0x1F3DF | 0x1F3F3 | 0x1F3F5 | 0x1F3F7 | 0x1F43F | 0x1F441
        | 0x1F4FD | 0x1F549..=0x1F54A | 0x1F56F..=0x1F570 | 0x1F573..=0x1F579 | 0x1F587
        | 0x1F58A..=0x1F58D | 0x1F590 | 0x1F5A5 | 0x1F5A8 | 0x1F5B1..=0x1F5B2 | 0x1F5BC
        | 0x1F5C2..=0x1F5C4 | 0x1F5D1..=0x1F5D3 | 0x1F5DC..=0x1F5DE | 0x1F5E1 | 0x1F5E3
        | 0x1F5E8 | 0x1F5EF | 0x1F5F3 | 0x1F5FA | 0x1F6CB | 0x1F6CD..=0x1F6CF
        | 0x1F6E0..=0x1F6E5 | 0x1F6E9 | 0x1F6F0 | 0x1F6F3
    )
}

/// Grapheme-break state carried between calls to [`grapheme_break`]. Mirrors
/// `uucode.grapheme.BreakState`: it remembers just enough history to evaluate
/// the multi-code-point rules (GB11 extended pictographic, GB12/13 regional
/// indicators, GB9c Indic conjuncts).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct BreakState {
    /// GB11: we saw `ExtendedPictographic Extend*` and are waiting to see if a
    /// ZWJ + ExtendedPictographic continues the sequence.
    extended_pictographic: u8,
    /// GB12/GB13: parity of an unbroken run of regional indicators.
    regional_indicator: bool,
    /// GB9c: we are inside `Consonant [Extend Linker]*` and have seen at least
    /// one Linker, so a following Consonant does not break.
    incb_linker: bool,
    /// GB9c: we are inside `Consonant [Extend Linker]*` (a Linker may or may
    /// not have been seen yet).
    incb_consonant: bool,
}

/// Determine whether there is a grapheme cluster boundary between `cp1` and
/// `cp2`, updating `state`. Must be called sequentially over a run of code
/// points, threading `state` through each call, exactly like Ghostty's
/// `unicode.graphemeBreak`.
///
/// Returns `true` if there IS a break (the code points belong to different
/// clusters), `false` if `cp2` extends the same cluster as `cp1`.
///
/// This must not be called with control characters, carriage returns, or line
/// feeds; the terminal filters those out first.
pub fn grapheme_break(cp1: u32, cp2: u32, state: &mut BreakState) -> bool {
    let gb1 = grapheme_break_class(cp1);
    let gb2 = grapheme_break_class(cp2);
    grapheme_break_classified(gb1, gb2, state)
}

pub(crate) fn grapheme_break_classified(
    gb1: GraphemeBreak,
    gb2: GraphemeBreak,
    state: &mut BreakState,
) -> bool {
    use GraphemeBreak::*;

    // Track whether the sequence ending at gb1 is Extended_Pictographic
    // Extend* (1) or Extended_Pictographic Extend* ZWJ (2).
    state.extended_pictographic = match gb1 {
        _ if gb1.is_extended_pictographic() => 1,
        Zwj if state.extended_pictographic == 1 => 2,
        _ if gb1.continues_extend_run() && state.extended_pictographic == 1 => 1,
        _ => 0,
    };

    // Track regional-indicator parity for GB12/GB13.
    let prev_ri = state.regional_indicator;
    state.regional_indicator = matches!(gb1, RegionalIndicator) && !prev_ri;

    // Track the Indic-conjunct run for GB9c:
    //   Consonant [Extend Linker]* Linker [Extend Linker]* × Consonant
    match gb1 {
        ConsonantConjunct => {
            state.incb_consonant = true;
            state.incb_linker = false;
        }
        ExtendLinker => {
            state.incb_linker = state.incb_consonant;
        }
        IndicConjunctExtend | Zwj if state.incb_consonant => {}
        _ => {
            state.incb_consonant = false;
            state.incb_linker = false;
        }
    }

    // GB3-GB5: controls are normally consumed by the terminal before this
    // function, but retaining the rules makes the classifier independently
    // conformant to the official Unicode suite.
    if matches!((gb1, gb2), (Cr, Lf)) {
        return false;
    }
    if matches!(gb1, Control | Cr | Lf) || matches!(gb2, Control | Cr | Lf) {
        return true;
    }

    // GB6-GB8: Hangul syllable sequences.
    match (gb1, gb2) {
        (L, L | V | Lv | Lvt) => return false,
        (Lv | V, V | T) => return false,
        (Lvt | T, T) => return false,
        _ => {}
    }

    // GB9a: × SpacingMark.
    if matches!(gb2, SpacingMark) {
        return false;
    }

    // GB9b: Prepend ×.
    if matches!(gb1, Prepend) {
        return false;
    }

    // GB9c: Indic conjunct. Consonant [Extend Linker]* Linker [Extend Linker]*
    // × Consonant.
    if state.incb_linker && matches!(gb2, ConsonantConjunct) {
        return false;
    }

    // Ghostty tailors Emoji_Modifier away from GCB=Extend: a modifier only
    // joins an immediately preceding Emoji_Modifier_Base. See
    // `.external/ghostty/src/unicode/grapheme.zig:686-704`.
    if matches!(gb2, EmojiModifier) {
        return !matches!(gb1, EmojiModifierBase);
    }

    // GB11: ExtendedPictographic Extend* ZWJ × ExtendedPictographic.
    if state.extended_pictographic == 2 && gb2.is_extended_pictographic() {
        return false;
    }

    // GB12/GB13: do not break between regional indicators if the number of RIs
    // before this point is even (i.e. this pair forms a flag).
    if matches!(gb1, RegionalIndicator) && matches!(gb2, RegionalIndicator) {
        return !state.regional_indicator;
    }

    // GB9: × (Extend | ZWJ). Do not break before extending characters.
    if gb2.is_grapheme_extend() || matches!(gb2, Zwj) {
        return false;
    }

    // GB999: otherwise, break.
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use unicode_segmentation::UnicodeSegmentation;

    const GRAPHEME_BREAK_TEST: &str = include_str!("../ucd/GraphemeBreakTest.txt");
    // Ghostty tailors Emoji_Modifier so it only joins Emoji_Modifier_Base.
    // Unicode 16 conformance lines 1100-1101 deliberately test the standard
    // `Any × Emoji_Modifier` behavior. See Ghostty grapheme.zig:686-704.
    const GHOSTTY_EMOJI_MODIFIER_EXCEPTIONS: [usize; 2] = [1100, 1101];
    // `unicode-width` applies extra terminal tailoring to these assigned
    // scalars. The generated table intentionally follows the pinned UCD/EAW
    // recipe instead.
    const UNICODE_WIDTH_ORACLE_TAILORING: [u32; 9] = [
        0x00AD, 0x17A4, 0x17D8, 0x20E3, 0x2E3A, 0x2E3B, 0xA8FA, 0xFF9E, 0xFF9F,
    ];

    fn cluster_starts(text: &str) -> Vec<usize> {
        let codepoints: Vec<(usize, u32)> = text
            .char_indices()
            .map(|(offset, character)| (offset, character as u32))
            .collect();
        let mut starts = vec![0];
        let mut state = BreakState::default();
        for pair in codepoints.windows(2) {
            if grapheme_break(pair[0].1, pair[1].1, &mut state) {
                starts.push(pair[1].0);
            }
        }
        starts
    }

    fn parse_conformance_line(line: &str) -> Option<(Vec<u32>, Vec<bool>)> {
        let body = line.split('#').next()?.trim();
        if body.is_empty() {
            return None;
        }
        let tokens: Vec<&str> = body.split_whitespace().collect();
        let codepoints = tokens
            .iter()
            .skip(1)
            .step_by(2)
            .map(|value| u32::from_str_radix(value, 16).ok())
            .collect::<Option<Vec<_>>>()?;
        let breaks = tokens
            .iter()
            .skip(2)
            .step_by(2)
            .take(codepoints.len().saturating_sub(1))
            .map(|marker| *marker == "÷")
            .collect();
        Some((codepoints, breaks))
    }

    #[test]
    fn tables_version_and_shape() {
        assert_eq!(tables::UCD_VERSION, "16.0.0");
        let leaf_count = tables::LEAF_COUNT;
        assert!(leaf_count > 1);
        assert_eq!(tables::packed(0x0E31) & 0b1111, 4);
        assert_eq!(
            grapheme_break_class(0x0E31),
            GraphemeBreak::IndicConjunctExtend
        );
        assert_eq!(
            grapheme_break_class(0x1F1E6),
            GraphemeBreak::RegionalIndicator
        );
        assert_eq!(grapheme_break_class(0x11A8), GraphemeBreak::T);
        assert_eq!(tables::packed(0x0300) & 0b1111, 4);
        assert_eq!(
            grapheme_break_class(0x0300),
            GraphemeBreak::IndicConjunctExtend
        );
        assert_eq!(grapheme_break_class(0x200D), GraphemeBreak::Zwj);
    }

    #[test]
    fn ucd_grapheme_break_conformance() {
        let mut exceptions = Vec::new();
        let mut unexpected = Vec::new();
        for (line_index, line) in GRAPHEME_BREAK_TEST.lines().enumerate() {
            let Some((codepoints, expected)) = parse_conformance_line(line) else {
                continue;
            };
            let actual = brk(&codepoints);
            if actual != expected {
                let line_number = line_index + 1;
                if GHOSTTY_EMOJI_MODIFIER_EXCEPTIONS.contains(&line_number) {
                    exceptions.push(line_number);
                } else {
                    unexpected.push((line_number, codepoints, expected, actual));
                }
            }
        }
        assert!(unexpected.is_empty(), "grapheme failures: {unexpected:#X?}");
        assert_eq!(exceptions, GHOSTTY_EMOJI_MODIFIER_EXCEPTIONS);
    }

    #[test]
    fn classifier_matches_unicode_segmentation_oracle() {
        let corpus = [
            "日本語かなカナ",
            "กำลังทดสอบ",
            "हिन्दी क्ष",
            "اَلْعَرَبِيَّةُ",
            "한글 한글",
            "👨‍👩‍👧 👩🏽‍💻",
            "🇯🇵🇺🇸",
            "1️⃣ #️⃣",
            "©️ ♥️",
        ];
        for text in corpus {
            let expected: Vec<usize> = text
                .grapheme_indices(true)
                .map(|(offset, _)| offset)
                .collect();
            assert_eq!(cluster_starts(text), expected, "text {text:?}");
        }

        // Same Ghostty tailoring exception as conformance lines 1100-1101.
        assert_ne!(
            cluster_starts("a🏿👶"),
            "a🏿👶"
                .grapheme_indices(true)
                .map(|(offset, _)| offset)
                .collect::<Vec<_>>()
        );
    }

    fn brk(seq: &[u32]) -> Vec<bool> {
        let mut state = BreakState::default();
        let mut out = Vec::new();
        for pair in seq.windows(2) {
            out.push(grapheme_break(pair[0], pair[1], &mut state));
        }
        out
    }

    #[test]
    fn combining_mark_does_not_break() {
        // o + combining grave accent.
        assert_eq!(brk(&[0x006F, 0x0300]), vec![false]);
        // n + combining tilde.
        assert_eq!(brk(&[0x006E, 0x0303]), vec![false]);
    }

    #[test]
    fn zwj_emoji_sequence_does_not_break() {
        // 👨‍👩‍👧 family sequence stays one cluster.
        assert_eq!(
            brk(&[0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467]),
            vec![false, false, false, false]
        );
    }

    #[test]
    fn pirate_flag_sequence_does_not_break() {
        // 🏴 + ZWJ + ☠ + VS16.
        assert_eq!(
            brk(&[0x1F3F4, 0x200D, 0x2620, 0xFE0F]),
            vec![false, false, false]
        );
    }

    #[test]
    fn skin_tone_modifier_does_not_break() {
        // 👋🏿 waving hand + dark skin tone.
        assert_eq!(brk(&[0x1F44B, 0x1F3FF]), vec![false]);
    }

    #[test]
    fn skin_tone_breaks_from_non_base() {
        // " + 🏿 must break (a quote is not an emoji base).
        assert_eq!(brk(&[0x0022, 0x1F3FF]), vec![true]);
    }

    #[test]
    fn devanagari_conjunct_does_not_break() {
        // क + ् (virama) + ZWJ + ष -> single conjunct cluster.
        assert_eq!(
            brk(&[0x0915, 0x094D, 0x200D, 0x0937]),
            vec![false, false, false]
        );
    }

    #[test]
    fn variation_selectors_do_not_break() {
        assert_eq!(brk(&[0x0023, 0xFE0E]), vec![false]);
        assert_eq!(brk(&[0x0023, 0xFE0F]), vec![false]);
        assert_eq!(brk(&[0x2764, 0xFE0F]), vec![false]);
    }

    #[test]
    fn emoji_vs_base_classification() {
        assert!(props(0x2764).emoji_vs_base); // heart
        assert!(props(0x0023).emoji_vs_base); // number sign
        assert!(props(0x2614).emoji_vs_base); // umbrella
        assert!(props(0x26C8).emoji_vs_base); // thunder cloud
        assert!(!props(0x1F9E0).emoji_vs_base); // brain
        assert!(!props(0x1F469).emoji_vs_base); // woman
        assert!(!props(0x0078).emoji_vs_base); // 'x'
        assert!(!props(0x006E).emoji_vs_base); // 'n'
    }

    #[test]
    fn widths_match_expectations() {
        assert_eq!(props(0x1F600).width, 2); // emoji
        assert_eq!(props(0x2764).width, 1); // heart (narrow base)
        assert_eq!(props(0x2614).width, 2); // umbrella
        assert_eq!(props(0x26C8).width, 1); // thunder cloud (narrow)
        assert_eq!(props(0x0915).width, 1); // devanagari consonant
        assert_eq!(props(0x094D).width, 0); // virama
        assert_eq!(props(0x093E).width, 0); // spacing matra follows wcwidth
        assert!(props(0x094D).width_zero_in_grapheme);
        assert!(props(0x093E).width_zero_in_grapheme);
        assert!(props(0x200D).width_zero_in_grapheme); // ZWJ
        assert!(!props(0x0937).width_zero_in_grapheme); // consonant
        assert_eq!(props(0x1F3FB).width, 2); // modifier is visible alone
        assert!(props(0x1F3FB).width_zero_in_grapheme);
        assert_eq!(props(0x0600).width, 1); // prepend is visible alone
        assert!(props(0x0600).width_zero_in_grapheme);
    }

    #[test]
    fn width_matches_props_width() {
        let representative = [
            0x20, 0x61, 0x0300, 0x3042, 0x4E00, 0x1F600, 0x200D, 0xFE0F, 0x1F1EF, 0xE0100,
        ];
        for cp in (0x00..=0x2FF).chain(representative) {
            assert_eq!(width(cp), props(cp).width, "code point U+{cp:04X}");
        }
    }

    #[test]
    fn common_cjk_width_ranges_match_unicode_width() {
        let ranges = [
            0x3041..=0x3096,
            0x30A1..=0x30FA,
            0x3400..=0x4DBF,
            0x4E00..=0x9FFF,
        ];
        for range in ranges {
            for cp in range {
                let ch = char::from_u32(cp).expect("range contains valid Unicode scalars");
                assert_eq!(
                    UnicodeWidthChar::width(ch),
                    Some(2),
                    "code point U+{cp:04X}"
                );
            }
        }
    }

    #[test]
    fn width_diverges_from_unicode_width_only_where_intended() {
        let mut unexpected = Vec::new();
        for cp in 0..=0x30000 {
            let Some(character) = char::from_u32(cp) else {
                continue;
            };
            let oracle = UnicodeWidthChar::width(character).unwrap_or(0).min(2) as u8;
            let properties = props(cp);
            if properties.width == oracle {
                continue;
            }
            let raw_grapheme = tables::packed(cp) & 0b1111;
            let assigned_in_unicode_16 = tables::packed(cp) & (1 << 12) != 0;
            let intended = properties.width_zero_in_grapheme
                || !assigned_in_unicode_16
                || raw_grapheme == 6
                || UNICODE_WIDTH_ORACLE_TAILORING.contains(&cp);
            if !intended {
                unexpected.push((cp, oracle, properties));
                if unexpected.len() == 32 {
                    break;
                }
            }
        }
        assert!(
            unexpected.is_empty(),
            "unexpected wcwidth divergences: {unexpected:#X?}"
        );
    }

    #[test]
    fn grapheme_break_classified_matches_grapheme_break() {
        let sequences: &[&[u32]] = &[
            &[0x4E00, 0x4E8C],
            &[0x0061, 0x0300],
            &[0x1F600, 0x200D],
            &[0x1F600, 0x200D, 0x1F469],
            &[0x1F1EF, 0x1F1F5, 0x1F1FA],
            &[0x2764, 0xFE0F],
        ];

        for sequence in sequences {
            let mut expected_state = BreakState::default();
            let mut classified_state = BreakState::default();
            for pair in sequence.windows(2) {
                let expected = grapheme_break(pair[0], pair[1], &mut expected_state);
                let classified = grapheme_break_classified(
                    grapheme_break_class(pair[0]),
                    grapheme_break_class(pair[1]),
                    &mut classified_state,
                );
                assert_eq!(classified, expected, "sequence {sequence:X?}");
                assert_eq!(classified_state, expected_state, "sequence {sequence:X?}");
            }
        }
    }
}
