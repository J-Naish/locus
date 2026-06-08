//! Text semantics over the rope: coordinate conversions (UTF-16 ↔ byte ↔
//! line/column) and viewport reads (line ranges, capped reads, UTF-16 windows).
//!
//! These functions treat a [`Node`] as an ordered byte sequence carrying a
//! cached [`TextSummary`]; they know nothing about copy-on-write or balancing.
//! Each conversion descends the tree guided by the summary (`O(log n)` nodes)
//! and then scans within at most one bounded leaf — so a position query never
//! materializes a line, even a multi-megabyte one. The line model is the
//! buffer's: `'\n'` is the only break, a `'\r'` before a `'\n'` is part of the
//! terminator, and a lone trailing `'\r'` on the final line is content.

use super::rope::Node;
use super::{Position, TextBufferError};

/// Where a UTF-16 offset lands: the leaf containing it, the byte/char/line-break
/// prefixes of everything before that leaf, and the UTF-16 offset within it.
struct Utf16Descent<'a> {
    leaf: &'a [u8],
    prefix_byte: usize,
    prefix_char: usize,
    prefix_breaks: usize,
    utf16_in: usize,
}

// MARK: - Byte-level reads

/// Assembles the UTF-8 text for a logical byte range, visiting only the
/// overlapping leaves. Endpoints are always on char boundaries, so every leaf
/// slice is valid UTF-8.
fn read_range(root: &Node, start: usize, end: usize) -> String {
    let mut out = String::with_capacity(end.saturating_sub(start));
    collect(root, 0, start, end, &mut out);
    out
}

fn collect(node: &Node, base: usize, start: usize, end: usize, out: &mut String) {
    if node.is_leaf() {
        let node_end = base + node.byte_len();
        let from = start.max(base);
        let to = end.min(node_end);
        if from < to {
            let bytes = node.leaf_bytes();
            out.push_str(
                std::str::from_utf8(&bytes[from - base..to - base])
                    .expect("leaf is validated UTF-8 sliced on char boundaries"),
            );
        }
        return;
    }
    let mut child_base = base;
    for child in node.children() {
        let child_end = child_base + child.byte_len();
        if start < child_end && end > child_base {
            collect(child, child_base, start, end, out);
        }
        child_base = child_end;
        if child_base >= end {
            break;
        }
    }
}

/// The byte at logical offset `at`, if it is in range.
fn logical_byte(root: &Node, at: usize) -> Option<u8> {
    if at >= root.byte_len() {
        return None;
    }
    Some(byte_at(root, at))
}

fn byte_at(node: &Node, at: usize) -> u8 {
    if node.is_leaf() {
        return node.leaf_bytes()[at];
    }
    let mut offset = at;
    for child in node.children() {
        let child_bytes = child.byte_len();
        if offset < child_bytes {
            return byte_at(child, offset);
        }
        offset -= child_bytes;
    }
    unreachable!("at < byte_len guarantees a child contains it")
}

/// The largest byte offset `<= at` on a char boundary, so a capped read never
/// splits a multi-byte character.
fn char_boundary_at_or_before(root: &Node, at: usize) -> usize {
    let mut at = at.min(root.byte_len());
    while at > 0 && logical_byte(root, at).is_some_and(|byte| byte & 0xC0 == 0x80) {
        at -= 1;
    }
    at
}

// MARK: - Line navigation

/// Prefix aggregates (byte/char/utf16) at the first byte of `line`. Line 0 is
/// the origin; line `L > 0` begins just after the `L`-th `'\n'`.
fn line_start_prefix(root: &Node, line: usize) -> Position {
    if line == 0 {
        return Position::default();
    }
    let total = root.summary();
    if line > total.line_breaks {
        // Fewer newlines than requested: clamp to the end of the content.
        return Position {
            byte: total.bytes,
            char: total.chars,
            utf16: total.utf16,
            line,
            column_utf16: 0,
        };
    }
    let mut acc = Position::default();
    let mut breaks_before = 0;
    line_start_descend(root, line, &mut breaks_before, &mut acc);
    Position {
        line,
        column_utf16: 0,
        ..acc
    }
}

fn line_start_descend(node: &Node, line: usize, breaks_before: &mut usize, acc: &mut Position) {
    if node.is_leaf() {
        // The (line - breaks_before)-th newline lands in this leaf.
        let nth = line - *breaks_before;
        let (byte, chars, utf16) = scan_after_nth_newline(node.leaf_bytes(), nth);
        acc.byte += byte;
        acc.char += chars;
        acc.utf16 += utf16;
        *breaks_before = line;
        return;
    }
    for child in node.children() {
        let child_breaks = child.summary().line_breaks;
        if line <= *breaks_before + child_breaks {
            line_start_descend(child, line, breaks_before, acc);
            return;
        }
        let summary = child.summary();
        acc.byte += summary.bytes;
        acc.char += summary.chars;
        acc.utf16 += summary.utf16;
        *breaks_before += child_breaks;
    }
}

/// Scans a leaf for the `nth` (1-based) `'\n'`, returning the byte/char/utf16
/// counts up to and including it (i.e. the start of the following line).
fn scan_after_nth_newline(bytes: &[u8], nth: usize) -> (usize, usize, usize) {
    let text = std::str::from_utf8(bytes).expect("leaf is validated UTF-8");
    let mut byte = 0;
    let mut chars = 0;
    let mut utf16 = 0;
    let mut found = 0;
    for character in text.chars() {
        byte += character.len_utf8();
        chars += 1;
        utf16 += character.len_utf16();
        if character == '\n' {
            found += 1;
            if found == nth {
                break;
            }
        }
    }
    (byte, chars, utf16)
}

/// Logical byte range of a line including its trailing terminator.
fn line_bounds(root: &Node, line: usize) -> (usize, usize) {
    let start = line_start_prefix(root, line).byte;
    let total_lines = root.summary().line_breaks + 1;
    let end = if line + 1 < total_lines {
        line_start_prefix(root, line + 1).byte
    } else {
        root.byte_len()
    };
    (start, end)
}

/// End of a line's *content* — the terminating `'\n'` and a preceding `'\r'` are
/// excluded — so a caret can never be placed inside a CRLF terminator. Works in
/// global byte offsets, so a `'\r\n'` split across two leaves is still handled.
fn line_content_end(root: &Node, line: usize) -> usize {
    let (start, end) = line_bounds(root, line);
    strip_terminator(root, start, end)
}

fn strip_terminator(root: &Node, start: usize, end: usize) -> usize {
    let mut content_end = end;
    if content_end > start && logical_byte(root, content_end - 1) == Some(b'\n') {
        content_end -= 1;
        if content_end > start && logical_byte(root, content_end - 1) == Some(b'\r') {
            content_end -= 1;
        }
    }
    content_end
}

// MARK: - Position conversions

/// Maps a UTF-16 offset to a full [`Position`]. The end-of-buffer offset is
/// valid; an offset inside a surrogate pair or past the end is rejected.
pub(super) fn position_for_utf16(
    root: &Node,
    target_utf16: usize,
) -> Result<Position, TextBufferError> {
    let total = root.summary();
    if target_utf16 > total.utf16 {
        return Err(TextBufferError::InvalidUtf16Offset {
            offset: target_utf16,
            limit: total.utf16,
        });
    }
    if target_utf16 == total.utf16 {
        let line = total.line_breaks;
        let line_start = line_start_prefix(root, line);
        return Ok(Position {
            byte: total.bytes,
            char: total.chars,
            utf16: total.utf16,
            line,
            column_utf16: total.utf16 - line_start.utf16,
        });
    }

    let descent = descend_utf16(root, target_utf16, 0, 0, 0, 0);
    let text = std::str::from_utf8(descent.leaf).expect("leaf is validated UTF-8");
    let mut byte = 0;
    let mut chars = 0;
    let mut utf16 = 0;
    let mut breaks_in = 0;
    for character in text.chars() {
        if utf16 == descent.utf16_in {
            break;
        }
        let next = utf16 + character.len_utf16();
        if next > descent.utf16_in {
            // The target fell between the two code units of a surrogate pair.
            return Err(TextBufferError::InvalidUtf16Offset {
                offset: target_utf16,
                limit: total.utf16,
            });
        }
        byte += character.len_utf8();
        chars += 1;
        utf16 = next;
        if character == '\n' {
            breaks_in += 1;
        }
    }

    let line = descent.prefix_breaks + breaks_in;
    let line_start = line_start_prefix(root, line);
    Ok(Position {
        byte: descent.prefix_byte + byte,
        char: descent.prefix_char + chars,
        utf16: target_utf16,
        line,
        column_utf16: target_utf16 - line_start.utf16,
    })
}

fn descend_utf16(
    node: &Node,
    target: usize,
    mut prefix_byte: usize,
    mut prefix_char: usize,
    mut prefix_breaks: usize,
    acc_utf16: usize,
) -> Utf16Descent<'_> {
    if node.is_leaf() {
        return Utf16Descent {
            leaf: node.leaf_bytes(),
            prefix_byte,
            prefix_char,
            prefix_breaks,
            utf16_in: target - acc_utf16,
        };
    }
    let mut acc = acc_utf16;
    for child in node.children() {
        let child_utf16 = child.summary().utf16;
        if target < acc + child_utf16 {
            return descend_utf16(child, target, prefix_byte, prefix_char, prefix_breaks, acc);
        }
        let summary = child.summary();
        prefix_byte += summary.bytes;
        prefix_char += summary.chars;
        prefix_breaks += summary.line_breaks;
        acc += child_utf16;
    }
    unreachable!("target < utf16_len guarantees a child contains it")
}

/// Maps a 0-based `line` and UTF-16 `column_utf16` (from the line start) to a
/// full [`Position`]. A column past the line's content is clamped to the end of
/// the line (and never inside a `'\r\n'`); a hostile `usize::MAX` cannot overflow.
pub(super) fn position_for_line_column(
    root: &Node,
    line: usize,
    column_utf16: usize,
) -> Result<Position, TextBufferError> {
    let total = root.summary().line_breaks + 1;
    if line >= total {
        return Err(TextBufferError::InvalidLine { line, total });
    }
    let line_start = line_start_prefix(root, line);
    let content_end_byte = line_content_end(root, line);
    // Take the UTF-16 count at the line's content end from the tree (descent +
    // one bounded leaf scan) — materializing the line would be catastrophic for
    // a giant single line.
    let content_utf16 = utf16_before_byte(root, content_end_byte);
    let target = line_start
        .utf16
        .saturating_add(column_utf16)
        .min(content_utf16);
    position_for_utf16(root, target)
}

/// UTF-16 code units before byte offset `at` (which must lie on a char
/// boundary). One descent plus a scan bounded by a single leaf.
fn utf16_before_byte(root: &Node, at: usize) -> usize {
    if at >= root.byte_len() {
        return root.summary().utf16;
    }
    descend_utf16_before(root, at, 0)
}

fn descend_utf16_before(node: &Node, within: usize, acc_utf16: usize) -> usize {
    if node.is_leaf() {
        let prefix = &node.leaf_bytes()[..within];
        let text = std::str::from_utf8(prefix).expect("leaf is validated UTF-8");
        return acc_utf16 + text.chars().map(char::len_utf16).sum::<usize>();
    }
    let mut within = within;
    let mut acc = acc_utf16;
    for child in node.children() {
        let child_bytes = child.byte_len();
        if within < child_bytes {
            return descend_utf16_before(child, within, acc);
        }
        within -= child_bytes;
        acc += child.summary().utf16;
    }
    acc
}

// MARK: - Viewport reads

/// Lines `[start_line, start_line + count)` joined by `'\n'`, each line's own
/// terminator stripped. Out-of-range requests are clamped.
pub(super) fn text_for_line_range(root: &Node, start_line: usize, count: usize) -> String {
    let total = root.summary().line_breaks + 1;
    if start_line >= total || count == 0 {
        return String::new();
    }
    let end_line = start_line.saturating_add(count).min(total);
    let start_byte = line_start_prefix(root, start_line).byte;
    let end_byte = if end_line < total {
        line_start_prefix(root, end_line).byte
    } else {
        root.byte_len()
    };
    format_band(
        root,
        start_byte,
        end_byte,
        end_line - start_line,
        end_line < total,
        None,
    )
}

/// Like [`text_for_line_range`] but never returns more than `max_bytes_per_line`
/// bytes of any single line's content, so one enormous line never materializes.
pub(super) fn text_for_line_range_capped(
    root: &Node,
    start_line: usize,
    count: usize,
    max_bytes_per_line: usize,
) -> String {
    let total = root.summary().line_breaks + 1;
    if start_line >= total || count == 0 {
        return String::new();
    }
    let end_line = start_line.saturating_add(count).min(total);
    let line_count = end_line - start_line;
    let start_byte = line_start_prefix(root, start_line).byte;
    let end_byte = if end_line < total {
        line_start_prefix(root, end_line).byte
    } else {
        root.byte_len()
    };

    // Fast path: when the whole band fits the cap budget, read it once and cap
    // each line in the assembled string (no per-line descents). The per-line cap
    // is still enforced — the budget bounds the total, not any single line.
    let budget = line_count
        .saturating_mul(max_bytes_per_line.saturating_add(2))
        .saturating_add(2);
    if end_byte - start_byte <= budget {
        return format_band(
            root,
            start_byte,
            end_byte,
            line_count,
            end_line < total,
            Some(max_bytes_per_line),
        );
    }

    // Slow path: at least one line is very long. Read each line's content capped
    // on a char boundary, so the giant line never fully materializes.
    let mut out = String::new();
    for line in start_line..end_line {
        if line > start_line {
            out.push('\n');
        }
        let (start, end) = line_bounds(root, line);
        let content_end = strip_terminator(root, start, end);
        let capped = char_boundary_at_or_before(
            root,
            content_end.min(start.saturating_add(max_bytes_per_line)),
        );
        out.push_str(&read_range(root, start, capped));
    }
    out
}

/// Raw text of the UTF-16 range `[start_utf16, end_utf16)` with no terminator
/// stripping. Clamps past-end offsets, floors mid-surrogate endpoints to the
/// character start, and yields empty for an inverted range.
pub(super) fn text_for_utf16_range(root: &Node, start_utf16: usize, end_utf16: usize) -> String {
    let total = root.summary().utf16;
    let start = utf16_to_byte_floor(root, start_utf16.min(total));
    let end = utf16_to_byte_floor(root, end_utf16.min(total));
    if start >= end {
        return String::new();
    }
    read_range(root, start, end)
}

/// Byte offset of a UTF-16 offset, floored to the enclosing character's start
/// when it lands between a surrogate pair's two code units. Assumes
/// `target <= utf16_len`.
fn utf16_to_byte_floor(root: &Node, target: usize) -> usize {
    match position_for_utf16(root, target) {
        Ok(position) => position.byte,
        Err(_) => position_for_utf16(root, target.saturating_sub(1))
            .map(|position| position.byte)
            .unwrap_or_else(|_| root.byte_len()),
    }
}

/// Formats the byte range of a located band into the public line shape:
/// `line_count` lines joined by `'\n'`, each terminator stripped. With `cap`,
/// each line's content is also truncated to that many bytes on a char boundary.
fn format_band(
    root: &Node,
    start_byte: usize,
    end_byte: usize,
    line_count: usize,
    strip_final: bool,
    cap: Option<usize>,
) -> String {
    let raw = read_range(root, start_byte, end_byte);
    let mut out = String::with_capacity(raw.len());
    for (index, segment) in raw.split('\n').take(line_count).enumerate() {
        if index > 0 {
            out.push('\n');
        }
        let is_final = index + 1 == line_count;
        let mut content = if is_final && !strip_final {
            segment
        } else {
            segment.strip_suffix('\r').unwrap_or(segment)
        };
        if let Some(cap) = cap {
            if content.len() > cap {
                let mut end = cap;
                while end > 0 && !content.is_char_boundary(end) {
                    end -= 1;
                }
                content = &content[..end];
            }
        }
        out.push_str(content);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text_buffer::rope::Node;
    use std::sync::Arc;

    struct Bytes(Vec<u8>);

    impl crate::text_buffer::ContentBytes for Bytes {
        fn as_bytes(&self) -> &[u8] {
            &self.0
        }
    }

    /// Builds a rope over `text` with a tiny leaf cap, forcing many leaves so the
    /// cross-leaf descent/read paths are exercised.
    fn rope(text: &str, cap: usize) -> Node {
        let backing: Arc<dyn crate::text_buffer::ContentBytes> =
            Arc::new(Bytes(text.as_bytes().to_vec()));
        Node::from_backing(backing, cap)
    }

    #[test]
    fn reads_lines_with_crlf_stripped_across_leaves() {
        // cap=4 splits "abc\r\ndef" so '\r' ends one leaf and '\n' starts the next.
        let node = rope("abc\r\ndef", 4);
        assert_eq!(text_for_line_range(&node, 0, 1), "abc");
        assert_eq!(text_for_line_range(&node, 0, 2), "abc\ndef");
        // A column past the content clamps before the '\r', never inside "\r\n".
        let clamped = position_for_line_column(&node, 0, 99).expect("clamped");
        assert_eq!(clamped.byte, 3);
    }

    #[test]
    fn positions_track_multibyte_across_leaves() {
        let node = rope("あいうえお\nかきくけこ", 2);
        let position = position_for_utf16(&node, 7).expect("position");
        assert_eq!(position.line, 1);
        assert_eq!(position.column_utf16, 1);
    }

    #[test]
    fn rejects_mid_surrogate_and_past_end() {
        let node = rope("𝄞", 1);
        assert!(matches!(
            position_for_utf16(&node, 1),
            Err(TextBufferError::InvalidUtf16Offset { .. })
        ));
        assert!(matches!(
            position_for_utf16(&node, 99),
            Err(TextBufferError::InvalidUtf16Offset { .. })
        ));
        // The end offset is valid.
        assert_eq!(position_for_utf16(&node, 2).expect("end").utf16, 2);
    }

    #[test]
    fn utf16_range_floors_and_clamps() {
        let node = rope("𝄞", 2);
        assert_eq!(text_for_utf16_range(&node, 2, 1), ""); // inverted
        assert_eq!(text_for_utf16_range(&node, 0, 99), "𝄞"); // clamped
        assert_eq!(text_for_utf16_range(&node, 0, 1), ""); // mid-surrogate end floors
        assert_eq!(text_for_utf16_range(&node, 1, 2), "𝄞"); // mid-surrogate start floors
    }

    #[test]
    fn capped_read_truncates_a_long_line_on_a_char_boundary() {
        let node = rope(&format!("{}\nb", "あ".repeat(1_000)), 64);
        // A 4-byte cap backs off to one whole 3-byte "あ".
        assert_eq!(text_for_line_range_capped(&node, 0, 1, 4), "あ");
        assert_eq!(text_for_line_range_capped(&node, 1, 1, 4), "b");
    }

    #[test]
    fn line_column_on_a_long_single_line_does_not_materialize() {
        let head = "a".repeat(100_000);
        let tail = "b".repeat(100_000);
        let text = format!("{head}𝄞{tail}");
        let node = rope(&text, 4096);
        let at_astral = position_for_line_column(&node, 0, 100_000).expect("position");
        assert_eq!(at_astral.byte, head.len());
        assert_eq!(at_astral.char, 100_000);
        let clamped = position_for_line_column(&node, 0, usize::MAX).expect("clamped");
        assert_eq!(clamped.utf16, 100_000 + 2 + 100_000);
        assert_eq!(clamped.byte, text.len());
    }

    #[test]
    fn round_trips_line_column_with_utf16() {
        let node = rope("ab\ncde\n𝄞z", 3);
        for offset in [0, 1, 4, 7, 9] {
            let position = position_for_utf16(&node, offset).expect("by utf16");
            let round = position_for_line_column(&node, position.line, position.column_utf16)
                .expect("by line/column");
            assert_eq!(round.utf16, offset, "offset {offset}");
            assert_eq!(round.byte, position.byte, "offset {offset}");
        }
    }
}
