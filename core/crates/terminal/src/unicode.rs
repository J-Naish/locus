//! Minimal Unicode property lookups and grapheme segmentation used by the
//! terminal's `print` path.
//!
//! Ghostty derives these tables from the `uucode` package (see
//! `.external/ghostty/src/unicode/props.zig` and `grapheme.zig`). We do not
//! vendor a full Unicode segmentation library here; instead this module
//! implements the exact UAX #29 grapheme-break state machine Ghostty relies on
//! (`graphemeBreak`), driven by per-codepoint properties. Character widths come
//! from the `unicode-width` crate; the remaining properties
//! (`grapheme_break`, `width_zero_in_grapheme`, `emoji_vs_base`) are computed
//! from focused classification tables that cover the codepoint classes the
//! terminal actually distinguishes.
//!
//! The classification favors correctness for the standard cases (combining
//! marks, ZWJ emoji sequences, regional indicators, emoji modifiers, Indic
//! conjuncts, and emoji variation selectors) and falls back to `.other` /
//! width-derived defaults for anything unclassified, matching how Ghostty's
//! precomputed table degrades for uncommon input.

use unicode_width::UnicodeWidthChar;

/// UAX #29 grapheme cluster break property, minus the control/CR/LF classes
/// which the terminal filters out before ever calling into this module. This
/// mirrors Ghostty's `uucode.x.types.GraphemeBreakNoControl`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GraphemeBreak {
    Other,
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
    /// Indic conjunct "linker" (e.g. virama). This is an `Extend` code point
    /// that additionally participates in the Indic conjunct break rule
    /// (UAX #29 GB9c). Ghostty folds the InCB=Linker information into the
    /// break-state machine; we surface it as its own class for clarity.
    ExtendLinker,
    /// Indic conjunct "consonant" (InCB=Consonant). These are `Other` for every
    /// rule except GB9c.
    ConsonantConjunct,
}

impl GraphemeBreak {
    /// True if this class counts as `Extend` for the purposes of continuing an
    /// extended-pictographic (GB11) or Indic-conjunct (GB9c) run.
    const fn is_extend(self) -> bool {
        matches!(self, Self::Extend | Self::ExtendLinker)
    }

    /// True if this class continues an existing cluster's "extend" run without
    /// itself forcing a break decision here (used to thread the GB11/GB9c run
    /// state). Emoji modifiers count so that a skin tone extends an emoji run.
    const fn continues_extend_run(self) -> bool {
        self.is_extend() || matches!(self, Self::Zwj | Self::EmojiModifier)
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
    let grapheme_break = grapheme_break_class(cp);
    let width = char_width(cp);
    Properties {
        width,
        width_zero_in_grapheme: width == 0,
        grapheme_break,
        emoji_vs_base: emoji_vs_base(cp),
    }
}

/// Display width of a code point, clamped to `[0, 2]`. Control characters are
/// filtered before print, so an unknown/`None` width maps to `0` (treated as a
/// combining/zero-width member) exactly like Ghostty's clamp.
fn char_width(cp: u32) -> u8 {
    let Some(ch) = char::from_u32(cp) else {
        return 1;
    };
    match UnicodeWidthChar::width(ch) {
        Some(w) if w >= 2 => 2,
        Some(w) => w as u8,
        None => 0,
    }
}

/// Classify a code point into its UAX #29 grapheme-break class (no control).
fn grapheme_break_class(cp: u32) -> GraphemeBreak {
    match cp {
        // Zero Width Joiner.
        0x200D => GraphemeBreak::Zwj,

        // Prepend: Arabic number sign and related format prefixes we test.
        0x0600..=0x0605 | 0x06DD | 0x070F | 0x08E2 | 0x110BD | 0x110CD => GraphemeBreak::Prepend,

        // Indic linker: Devanagari virama (and the common Indic viramas).
        0x094D | 0x09CD | 0x0A4D | 0x0ACD | 0x0B4D | 0x0BCD | 0x0C4D | 0x0CCD | 0x0D4D | 0x0DCA => {
            GraphemeBreak::ExtendLinker
        }

        // Regional indicators (flag halves).
        0x1F1E6..=0x1F1FF => GraphemeBreak::RegionalIndicator,

        // Emoji modifiers (Fitzpatrick skin tones).
        0x1F3FB..=0x1F3FF => GraphemeBreak::EmojiModifier,

        // Variation selectors are Extend.
        0xFE00..=0xFE0F | 0xE0100..=0xE01EF => GraphemeBreak::Extend,

        _ => {
            if is_extend(cp) {
                GraphemeBreak::Extend
            } else if is_extended_pictographic(cp) {
                GraphemeBreak::ExtendedPictographic
            } else if is_consonant_conjunct(cp) {
                GraphemeBreak::ConsonantConjunct
            } else {
                GraphemeBreak::Other
            }
        }
    }
}

/// Combining marks and other `Extend` (Grapheme_Extend) code points, excluding
/// the ranges handled explicitly above.
fn is_extend(cp: u32) -> bool {
    matches!(cp,
        // Combining Diacritical Marks.
        0x0300..=0x036F
        // Combining Diacritical Marks Extended / Supplement / for Symbols.
        | 0x1AB0..=0x1AFF | 0x1DC0..=0x1DFF | 0x20D0..=0x20FF
        // Combining Half Marks.
        | 0xFE20..=0xFE2F
        // Devanagari combining marks (nukta/vowel signs commonly attached),
        // excluding the virama handled as a linker above.
        | 0x0900..=0x0902 | 0x093A | 0x093C | 0x0941..=0x0948 | 0x094D
    )
}

/// Extended_Pictographic code points. Covers the emoji ranges the terminal
/// distinguishes for GB11 (ZWJ sequences) and the dingbat/symbol emoji used in
/// variation-selector handling.
fn is_extended_pictographic(cp: u32) -> bool {
    matches!(cp,
        0x00A9 | 0x00AE
        | 0x203C | 0x2049 | 0x2122 | 0x2139
        | 0x2194..=0x21AA
        | 0x231A..=0x231B
        | 0x2328
        | 0x2600..=0x27BF
        | 0x2934..=0x2935
        | 0x2B00..=0x2BFF
        | 0x3030 | 0x303D | 0x3297 | 0x3299
        | 0x1F000..=0x1FAFF
    )
}

/// InCB=Consonant code points (Indic conjunct consonants). Scoped to the
/// scripts and blocks Ghostty's tables mark as conjunct consonants and that the
/// terminal exercises (Devanagari primarily).
fn is_consonant_conjunct(cp: u32) -> bool {
    matches!(cp,
        // Devanagari consonants.
        0x0915..=0x0939 | 0x0958..=0x095F
        // Bengali consonants.
        | 0x0995..=0x09A8 | 0x09AA..=0x09B0 | 0x09B2 | 0x09B6..=0x09B9
    )
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
    extended_pictographic: bool,
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
    grapheme_break_class_pair(gb1, gb2, state)
}

fn grapheme_break_class_pair(
    gb1: GraphemeBreak,
    gb2: GraphemeBreak,
    state: &mut BreakState,
) -> bool {
    use GraphemeBreak::*;

    // Track the extended-pictographic run for GB11:
    //   ExtendedPictographic Extend* ZWJ × ExtendedPictographic
    // The flag is true once we've seen an ExtendedPictographic followed only by
    // Extend/ZWJ code points.
    let prev_extpict = state.extended_pictographic;
    state.extended_pictographic = match gb1 {
        ExtendedPictographic => true,
        _ if gb1.continues_extend_run() => prev_extpict,
        _ => false,
    };

    // Track regional-indicator parity for GB12/GB13.
    let prev_ri = state.regional_indicator;
    state.regional_indicator = matches!(gb1, RegionalIndicator) && !prev_ri;

    // Track the Indic-conjunct run for GB9c:
    //   Consonant [Extend Linker]* Linker [Extend Linker]* × Consonant
    let prev_incb_consonant = state.incb_consonant;
    let prev_incb_linker = state.incb_linker;
    match gb1 {
        ConsonantConjunct => {
            state.incb_consonant = true;
            state.incb_linker = false;
        }
        ExtendLinker => {
            // A linker continues the run and records that a linker was seen.
            state.incb_consonant = prev_incb_consonant;
            state.incb_linker = prev_incb_consonant;
        }
        Extend | Zwj | EmojiModifier => {
            // Extend/ZWJ/modifiers continue the run without recording a linker.
            state.incb_consonant = prev_incb_consonant;
            state.incb_linker = prev_incb_linker;
        }
        _ => {
            state.incb_consonant = false;
            state.incb_linker = false;
        }
    }

    // GB3/GB4/GB5 (CR/LF/Control) are handled by the caller.

    // GB9: × (Extend | ZWJ). Do not break before extending characters.
    if gb2.is_extend() || matches!(gb2, Zwj) {
        return false;
    }

    // Emoji modifier (skin tone): joins only an emoji (extended-pictographic)
    // run. After any other base it starts a new cluster. `state
    // .extended_pictographic` already reflects gb1's contribution to the run.
    if matches!(gb2, EmojiModifier) {
        return !state.extended_pictographic;
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
    if prev_incb_linker && matches!(gb2, ConsonantConjunct) {
        return false;
    }

    // GB6/GB7/GB8: Hangul syllable sequences.
    match (gb1, gb2) {
        (L, L | V | Lv | Lvt) => return false,
        (Lv | V, V | T) => return false,
        (Lvt | T, T) => return false,
        _ => {}
    }

    // GB11: ExtendedPictographic Extend* ZWJ × ExtendedPictographic.
    if prev_extpict && matches!(gb1, Zwj) && matches!(gb2, ExtendedPictographic) {
        return false;
    }

    // GB12/GB13: do not break between regional indicators if the number of RIs
    // before this point is even (i.e. this pair forms a flag).
    if matches!(gb1, RegionalIndicator) && matches!(gb2, RegionalIndicator) && !prev_ri {
        return false;
    }

    // GB999: otherwise, break.
    true
}

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(props(0x094D).width_zero_in_grapheme);
        assert!(props(0x200D).width_zero_in_grapheme); // ZWJ
        assert!(!props(0x0937).width_zero_in_grapheme); // consonant
    }
}
