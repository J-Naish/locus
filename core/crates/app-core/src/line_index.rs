//! Read-only, line-indexed view over a byte source read in windows rather than
//! held whole in memory. Backs the large-file viewer: a file too large to load
//! into an editable buffer is opened read-only, and only the lines in (or near)
//! the viewport are read on demand.
//!
//! The index is sparse — it stores the byte offset of every Nth line plus the
//! total line count — so its memory is bounded regardless of how many lines the
//! file has. Resolving a line range seeks to the nearest checkpoint at or before
//! the range and scans forward within a bounded span.
//!
//! Line semantics match [`crate::text_buffer`]: line count is `newlines + 1`
//! (an empty source is one empty line; a trailing newline yields a final empty
//! line), and the text of a line range is the contiguous bytes from the start of
//! the first line up to the start of the line after the last (or end of input),
//! including the separating newlines. Windows are cut at line starts, which sit
//! right after a `\n` (a single ASCII byte that never falls inside a multi-byte
//! UTF-8 sequence), so a window never splits a code point. Bytes are decoded
//! lossily, so even a stray non-UTF-8 byte renders as a replacement character
//! rather than failing the read.

use std::io;

/// Random-access, read-only source of bytes (e.g. a file read via `pread`).
///
/// Reads return an error or a short slice rather than faulting, so a concurrent
/// truncation surfaces as a recoverable error instead of `SIGBUS`.
pub trait ByteSource {
    /// Total length of the source in bytes.
    fn len(&self) -> u64;

    /// Reads up to `len` bytes starting at `offset`. The returned vector may be
    /// shorter than `len` at end of input (or if the source shrank).
    fn read_at(&self, offset: u64, len: usize) -> io::Result<Vec<u8>>;

    /// Whether the source holds no bytes.
    fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// The index records the start offset of every `CHECKPOINT_LINES`-th line, so
/// its memory is `~8 * (line_count / CHECKPOINT_LINES)` bytes regardless of how
/// many (possibly tiny) lines the file has.
const CHECKPOINT_LINES: usize = 1024;

/// Read granularity while scanning the source to build the index or to walk
/// from a checkpoint to a requested line.
const SCAN_CHUNK_BYTES: usize = 256 * 1024;

const NEWLINE: u8 = b'\n';

/// A sparse line index over a [`ByteSource`], serving line-range text by reading
/// only the needed window from the source.
pub struct LineIndex<S> {
    source: S,
    /// `checkpoints[i]` is the byte offset of the start of line
    /// `i * checkpoint_lines`. Always begins with `0` (the start of line 0).
    checkpoints: Vec<u64>,
    checkpoint_lines: usize,
    line_count: usize,
    byte_len: u64,
    max_line_byte_count: u64,
}

impl<S: ByteSource> LineIndex<S> {
    /// Builds an index over `source`, scanning it once.
    pub fn build(source: S) -> io::Result<Self> {
        Self::build_with_checkpoint(source, CHECKPOINT_LINES)
    }

    /// Total number of lines (`newlines + 1`; an empty source is one line).
    pub fn line_count(&self) -> usize {
        self.line_count
    }

    /// Total length of the underlying source in bytes.
    pub fn byte_len(&self) -> u64 {
        self.byte_len
    }

    /// Length in bytes of the longest line (including its terminator). Lets the
    /// platform refuse a file with a pathologically long single line instead of
    /// reading a multi-gigabyte window to render one row.
    pub fn max_line_byte_count(&self) -> u64 {
        self.max_line_byte_count
    }

    /// The text of lines `start..end`, decoded lossily as UTF-8: the contiguous
    /// bytes from the start of line `start` up to the start of line `end` (or end
    /// of input). `start` and `end` are clamped to `line_count`, and an empty or
    /// reversed range yields an empty string.
    pub fn text_for_line_range(&self, start: usize, end: usize) -> io::Result<String> {
        let start = start.min(self.line_count);
        let end = end.min(self.line_count).max(start);

        let start_offset = self.line_start_offset(start)?;
        let end_offset = self.line_start_offset(end)?;
        if end_offset <= start_offset {
            return Ok(String::new());
        }

        let len = (end_offset - start_offset) as usize;
        let bytes = self.source.read_at(start_offset, len)?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    fn build_with_checkpoint(source: S, checkpoint_lines: usize) -> io::Result<Self> {
        let checkpoint_lines = checkpoint_lines.max(1);
        let byte_len = source.len();

        let mut checkpoints = vec![0u64]; // line 0 starts at offset 0
        let mut newlines: usize = 0;
        // Newlines since the last recorded checkpoint. Counting up to the cadence
        // (rather than `newlines % checkpoint_lines`) keeps the intent obvious and
        // avoids a modulo lint that varies by toolchain.
        let mut since_checkpoint: usize = 0;
        let mut offset: u64 = 0;
        // Start of the line currently being scanned, and the longest line seen so
        // far (start-of-line to start-of-next-line, terminator included).
        let mut line_start: u64 = 0;
        let mut max_line_byte_count: u64 = 0;

        while offset < byte_len {
            let want = (byte_len - offset).min(SCAN_CHUNK_BYTES as u64) as usize;
            let chunk = source.read_at(offset, want)?;
            if chunk.is_empty() {
                break; // source shrank or reported EOF early; stop scanning
            }
            for (i, &byte) in chunk.iter().enumerate() {
                if byte == NEWLINE {
                    newlines += 1;
                    let next_line_start = offset + i as u64 + 1;
                    max_line_byte_count = max_line_byte_count.max(next_line_start - line_start);
                    line_start = next_line_start;
                    // The line starting here has index `newlines`; record its
                    // start every `checkpoint_lines` lines.
                    since_checkpoint += 1;
                    if since_checkpoint == checkpoint_lines {
                        since_checkpoint = 0;
                        checkpoints.push(next_line_start);
                    }
                }
            }
            offset += chunk.len() as u64;
        }
        // The final line carries no trailing newline; include its length too.
        max_line_byte_count = max_line_byte_count.max(byte_len - line_start);

        Ok(Self {
            source,
            checkpoints,
            checkpoint_lines,
            line_count: newlines + 1,
            byte_len,
            max_line_byte_count,
        })
    }

    /// Byte offset of the start of `line`, clamped: line `0` is `0`, and any line
    /// at or past `line_count` is `byte_len`.
    fn line_start_offset(&self, line: usize) -> io::Result<u64> {
        if line == 0 {
            return Ok(0);
        }
        if line >= self.line_count {
            return Ok(self.byte_len);
        }

        let checkpoint_index = line / self.checkpoint_lines;
        let mut offset = self.checkpoints[checkpoint_index];
        let mut current_line = checkpoint_index * self.checkpoint_lines;

        while current_line < line && offset < self.byte_len {
            let want = (self.byte_len - offset).min(SCAN_CHUNK_BYTES as u64) as usize;
            let chunk = self.source.read_at(offset, want)?;
            if chunk.is_empty() {
                break;
            }
            for (i, &byte) in chunk.iter().enumerate() {
                if byte == NEWLINE {
                    current_line += 1;
                    if current_line == line {
                        return Ok(offset + i as u64 + 1);
                    }
                }
            }
            offset += chunk.len() as u64;
        }

        Ok(offset)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// In-memory [`ByteSource`] for tests; `read_at` clamps to the available
    /// bytes, mirroring a short read at end of input.
    struct VecSource(Vec<u8>);

    impl ByteSource for VecSource {
        fn len(&self) -> u64 {
            self.0.len() as u64
        }

        fn read_at(&self, offset: u64, len: usize) -> io::Result<Vec<u8>> {
            let start = (offset as usize).min(self.0.len());
            let end = start.saturating_add(len).min(self.0.len());
            Ok(self.0[start..end].to_vec())
        }
    }

    fn index(text: &str, checkpoint_lines: usize) -> LineIndex<VecSource> {
        LineIndex::build_with_checkpoint(VecSource(text.as_bytes().to_vec()), checkpoint_lines)
            .expect("build index")
    }

    #[test]
    fn empty_source_is_one_empty_line() {
        let idx = index("", 1024);
        assert_eq!(idx.line_count(), 1);
        assert_eq!(idx.byte_len(), 0);
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "");
    }

    #[test]
    fn single_line_without_newline() {
        let idx = index("abc", 1024);
        assert_eq!(idx.line_count(), 1);
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "abc");
    }

    #[test]
    fn counts_lines_and_returns_whole_range() {
        let idx = index("alpha\nbeta\ngamma", 1024);
        assert_eq!(idx.line_count(), 3);
        assert_eq!(idx.text_for_line_range(0, 3).unwrap(), "alpha\nbeta\ngamma");
    }

    #[test]
    fn returns_individual_lines_with_their_terminators() {
        let idx = index("a\nb\nc", 1024);
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "a\n");
        assert_eq!(idx.text_for_line_range(1, 2).unwrap(), "b\n");
        assert_eq!(idx.text_for_line_range(2, 3).unwrap(), "c"); // last line, no terminator
    }

    #[test]
    fn trailing_newline_yields_a_final_empty_line() {
        let idx = index("a\n", 1024);
        assert_eq!(idx.line_count(), 2);
        assert_eq!(idx.text_for_line_range(0, 2).unwrap(), "a\n");
        assert_eq!(idx.text_for_line_range(1, 2).unwrap(), "");
    }

    #[test]
    fn resolves_ranges_across_sparse_checkpoints() {
        // checkpoint every 2 lines exercises the checkpoint + forward-scan path.
        let idx = index("L0\nL1\nL2\nL3\nL4", 2);
        assert_eq!(idx.line_count(), 5);
        assert_eq!(idx.text_for_line_range(3, 5).unwrap(), "L3\nL4");
        assert_eq!(idx.text_for_line_range(2, 3).unwrap(), "L2\n");
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "L0\n");
        // A range spanning several checkpoints returns the full span.
        assert_eq!(idx.text_for_line_range(1, 4).unwrap(), "L1\nL2\nL3\n");
    }

    #[test]
    fn clamps_out_of_range_requests() {
        let idx = index("a\nb\nc", 1024);
        assert_eq!(idx.text_for_line_range(0, 99).unwrap(), "a\nb\nc");
        assert_eq!(idx.text_for_line_range(5, 9).unwrap(), "");
        assert_eq!(idx.text_for_line_range(2, 1).unwrap(), ""); // reversed
    }

    #[test]
    fn windows_never_split_multibyte_code_points() {
        let idx = index("あ\nい\nう", 1);
        assert_eq!(idx.line_count(), 3);
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "あ\n");
        assert_eq!(idx.text_for_line_range(1, 2).unwrap(), "い\n");
        assert_eq!(idx.text_for_line_range(2, 3).unwrap(), "う");
    }

    #[test]
    fn decodes_invalid_utf8_lossily_without_failing() {
        let source = VecSource(vec![b'a', 0xFF, NEWLINE, b'b']);
        let idx = LineIndex::build_with_checkpoint(source, 1024).expect("build index");
        assert_eq!(idx.line_count(), 2);
        let first = idx.text_for_line_range(0, 1).unwrap();
        assert!(first.starts_with('a') && first.ends_with('\n'));
        assert!(first.contains('\u{FFFD}')); // 0xFF rendered as replacement char
        assert_eq!(idx.text_for_line_range(1, 2).unwrap(), "b");
    }

    #[test]
    fn default_checkpoint_build_reads_correctly() {
        let idx = LineIndex::build(VecSource(b"one\ntwo\nthree".to_vec())).expect("build index");
        assert_eq!(idx.line_count(), 3);
        assert_eq!(idx.text_for_line_range(1, 2).unwrap(), "two\n");
    }

    #[test]
    fn scans_across_read_chunk_boundaries() {
        use std::fmt::Write as _;
        // More than one SCAN_CHUNK_BYTES worth of data forces multi-chunk scans
        // during both index build and line resolution.
        let line_count = 5000usize;
        let mut text = String::new();
        for i in 0..line_count {
            writeln!(text, "line-{i}").unwrap();
        }
        let idx = LineIndex::build(VecSource(text.into_bytes())).expect("build index");
        assert_eq!(idx.line_count(), line_count + 1); // trailing newline → empty last line
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "line-0\n");
        assert_eq!(idx.text_for_line_range(4999, 5000).unwrap(), "line-4999\n");
        assert_eq!(
            idx.text_for_line_range(2500, 2502).unwrap(),
            "line-2500\nline-2501\n"
        );
    }

    #[test]
    fn tracks_the_longest_line_including_a_single_huge_line() {
        // Longest line is "bb\n" or the final "ccc": both 3 bytes.
        assert_eq!(index("a\nbb\nccc", 1024).max_line_byte_count(), 3);
        // A trailing newline's empty final line never exceeds the real line.
        assert_eq!(index("a\n", 1024).max_line_byte_count(), 2);
        // An empty source has no bytes in its single line.
        assert_eq!(index("", 1024).max_line_byte_count(), 0);
        // One unterminated line: the whole content counts as that line — this is
        // the case the average-length heuristic missed.
        let one_huge_line = "x".repeat(5000);
        assert_eq!(index(&one_huge_line, 1024).max_line_byte_count(), 5000);
    }
}
