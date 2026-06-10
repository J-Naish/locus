//! Differential parity between the two text engines.
//!
//! The platform picks an engine by file size: small files load into the
//! editable [`TextBuffer`] (rope), large files open read-only through
//! [`LineIndex`] (sparse checkpoints + windowed reads). A user crossing that
//! threshold must see the same document either way, so this test feeds the
//! same randomized content — CRLF, lone `\r`, multi-byte and astral characters,
//! embedded NUL, long lines — to both engines and checks that every read agrees:
//! metrics, line ranges, capped line ranges, UTF-16 ranges, and position
//! mappings.
//!
//! The two engines deliberately differ in *rejection* style (`TextBuffer`
//! errors on an out-of-range line or a mid-surrogate offset where `LineIndex`
//! clamps and floors); those cases are compared against the documented
//! clamp/floor target instead of being skipped.
//!
//! The generator is a fixed-seed xorshift, so a failure reproduces exactly.

use app_core::line_index::{ByteSource, LineIndex};
use app_core::text_buffer::TextBuffer;

/// In-memory byte source: `LineIndex` is generic over positioned reads, so the
/// parity corpus never touches the filesystem.
struct MemorySource(Vec<u8>);

impl ByteSource for MemorySource {
    fn len(&self) -> u64 {
        self.0.len() as u64
    }

    fn read_at(&self, offset: u64, len: usize) -> std::io::Result<Vec<u8>> {
        let start = (offset as usize).min(self.0.len());
        let end = start.saturating_add(len).min(self.0.len());
        Ok(self.0[start..end].to_vec())
    }
}

/// Fixed-seed xorshift64 (same shape as the rope oracle test) so the corpus is
/// deterministic without a dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    fn below(&mut self, bound: usize) -> usize {
        (self.next() % bound.max(1) as u64) as usize
    }
}

/// Line contents that exercise every semantic the engines must agree on. A
/// trailing `\r` forms a CRLF once lines are joined with `\n`; a lone `\r`
/// inside a line is content; the 300-char line crosses checkpoint/leaf
/// boundaries.
fn random_line(rng: &mut Rng) -> String {
    match rng.below(10) {
        0 => String::new(),
        1 => "a".into(),
        2 => "hello world".into(),
        3 => "héllo".into(),
        4 => "日本語のテキスト".into(),
        5 => "😀x😀".into(),
        6 => "pre\rpost".into(),    // lone \r is line content
        7 => "ends-in-cr\r".into(), // becomes \r\n when joined
        8 => "nul\u{0}inside".into(),
        _ => "x".repeat(300),
    }
}

fn random_document(rng: &mut Rng) -> String {
    let line_count = rng.below(30) + 1;
    let mut document = (0..line_count)
        .map(|_| random_line(rng))
        .collect::<Vec<_>>()
        .join("\n");
    if rng.below(2) == 0 {
        document.push('\n');
    }
    document
}

#[test]
fn line_index_matches_text_buffer_over_random_documents() {
    let mut rng = Rng(0x5eed_cafe_f00d_0001);

    for document_index in 0..120 {
        let document = random_document(&mut rng);
        let context = format!("document #{document_index}: {document:?}");

        let buffer = TextBuffer::from_utf8_bytes(document.clone().into_bytes())
            .unwrap_or_else(|error| panic!("{context}: buffer rejected content: {error:?}"));
        let index = LineIndex::build(MemorySource(document.clone().into_bytes()))
            .unwrap_or_else(|error| panic!("{context}: index rejected content: {error:?}"));

        // Metrics.
        assert_eq!(
            index.line_count(),
            buffer.line_count(),
            "{context}: line_count"
        );
        assert_eq!(
            index.byte_len(),
            buffer.byte_len() as u64,
            "{context}: byte_len"
        );
        assert_eq!(
            index.utf16_len(),
            buffer.utf16_len() as u64,
            "{context}: utf16_len"
        );

        let line_count = buffer.line_count();
        let utf16_len = buffer.utf16_len();

        // Line ranges, including the full document, a past-the-end start, and
        // random interior windows.
        let mut line_ranges = vec![(0, line_count), (0, usize::MAX), (line_count + 3, 2)];
        for _ in 0..6 {
            line_ranges.push((rng.below(line_count + 2), rng.below(line_count + 2)));
        }
        for (start, count) in line_ranges {
            assert_eq!(
                index.text_for_line_range(start, count).unwrap(),
                buffer.text_for_line_range(start, count),
                "{context}: text_for_line_range({start}, {count})"
            );
            for cap in [0, 1, 3, 7, usize::MAX] {
                assert_eq!(
                    index.text_for_line_range_capped(start, count, cap).unwrap(),
                    buffer.text_for_line_range_capped(start, count, cap),
                    "{context}: text_for_line_range_capped({start}, {count}, {cap})"
                );
            }
        }

        // UTF-16 ranges, including inverted and past-the-end (both clamp).
        let mut utf16_ranges = vec![(0, utf16_len), (utf16_len + 5, utf16_len + 9), (4, 1)];
        for _ in 0..6 {
            utf16_ranges.push((rng.below(utf16_len + 2), rng.below(utf16_len + 2)));
        }
        for (start, end) in utf16_ranges {
            assert_eq!(
                index
                    .text_for_utf16_range(start as u64, end as u64)
                    .unwrap(),
                buffer.text_for_utf16_range(start, end),
                "{context}: text_for_utf16_range({start}, {end})"
            );
        }

        // Line/column positions. Both engines clamp the column to the line's
        // content end. The line itself is only compared in the range the
        // editable buffer accepts (the index clamps out-of-range lines instead),
        // and a column that lands inside a surrogate pair is rejected by the
        // buffer but floored by the index — mirroring `position_for_utf16`.
        for line in 0..line_count {
            for column in [0, 1, rng.below(20), usize::MAX] {
                let actual = index.position_for_line_column(line, column).unwrap();
                match buffer.position_for_line_column(line, column) {
                    Ok(expected) => {
                        assert_eq!(
                            actual, expected,
                            "{context}: position_for_line_column({line}, {column})"
                        );
                    }
                    Err(_) => {
                        // Mid-surrogate column: the floor target is the previous
                        // unit (a pair is exactly two units wide; column 0 never
                        // splits one, so `column - 1` cannot underflow).
                        let floored = buffer.position_for_line_column(line, column - 1).unwrap();
                        assert_eq!(
                            actual, floored,
                            "{context}: position_for_line_column({line}, {column}) floors into the pair"
                        );
                    }
                }
            }
        }

        // UTF-16 offsets. Where the editable buffer accepts the offset the two
        // must agree exactly; where it rejects (past the end, mid-surrogate)
        // the index documents clamp/floor behavior, so compare against the
        // buffer's position at the clamped/floored offset.
        for offset in 0..=utf16_len + 2 {
            let actual = index.position_for_utf16(offset as u64).unwrap();
            match buffer.position_for_utf16(offset) {
                Ok(expected) => {
                    assert_eq!(actual, expected, "{context}: position_for_utf16({offset})");
                }
                Err(_) if offset > utf16_len => {
                    let clamped = buffer.position_for_utf16(utf16_len).unwrap();
                    assert_eq!(
                        actual, clamped,
                        "{context}: position_for_utf16({offset}) clamps to end"
                    );
                }
                Err(_) => {
                    // Mid-surrogate: the floor target is the previous unit (a
                    // surrogate pair is exactly two units wide).
                    let floored = buffer.position_for_utf16(offset - 1).unwrap();
                    assert_eq!(
                        actual, floored,
                        "{context}: position_for_utf16({offset}) floors into the pair"
                    );
                }
            }
        }
    }
}
