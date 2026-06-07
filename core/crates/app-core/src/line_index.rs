//! Read-only, line-indexed view over a byte source read in windows rather than
//! held whole in memory. Backs the large-file viewer: a file too large to load
//! into an editable buffer is opened read-only, and only the lines in (or near)
//! the viewport are read on demand.
//!
//! The index is sparse — it records cumulative byte/char/UTF-16 counts at a
//! checkpoint taken at least every Nth line *and* every Nth byte, plus the totals
//! — so its memory is bounded regardless of how many lines the file has or how
//! long any single line is. A line range, or a byte/char/UTF-16/line/column
//! position, is resolved by seeking to the nearest checkpoint and scanning forward
//! within a bounded span: at most one checkpoint gap (`checkpoint_lines` lines or
//! `checkpoint_bytes` bytes), so even a seek deep inside one enormous line is
//! bounded.
//!
//! Line semantics match [`crate::text_buffer`]: line count is `newlines + 1`
//! (an empty source is one empty line; a trailing newline yields a final empty
//! line), and the text of a line range is the contiguous bytes from the start of
//! the first line up to the start of the line after the last (or end of input),
//! including the separating newlines. Windows are cut at code-point boundaries
//! and bytes are decoded lossily, so a stray non-UTF-8 byte renders as a
//! replacement character rather than failing the read. (Position counts use a
//! per-byte UTF-8 classification, which is exact for valid UTF-8 — the common
//! case for a recognized text file; selection mapping in a file with invalid
//! bytes may drift slightly.)

use std::io;

use crate::text_buffer::Position;

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

/// A checkpoint is recorded at least every `CHECKPOINT_LINES` lines *and* every
/// [`CHECKPOINT_BYTES`] bytes, whichever comes first. The line cadence keeps a
/// file of many short lines cheap to seek; the byte cadence bounds a seek *within*
/// one very long line, so resolving a position inside a multi-megabyte line scans
/// at most one chunk rather than the whole line. Index memory stays bounded:
/// ~40 bytes per checkpoint — `line_count / CHECKPOINT_LINES` checkpoints for
/// normal files, plus `long_line_bytes / CHECKPOINT_BYTES` for long lines.
const CHECKPOINT_LINES: usize = 1024;

/// Read granularity while scanning the source to build the index or to walk from
/// a checkpoint to a requested line/position.
const SCAN_CHUNK_BYTES: usize = 256 * 1024;

/// Byte cadence for checkpoints (see [`CHECKPOINT_LINES`]). One scan chunk, so a
/// within-line seek walks at most one chunk's worth of bytes.
const CHECKPOINT_BYTES: u64 = SCAN_CHUNK_BYTES as u64;

const NEWLINE: u8 = b'\n';

/// Truncates `content` to at most `cap` bytes, ending on a char boundary.
fn floor_to_byte_cap(content: &str, cap: usize) -> &str {
    if content.len() <= cap {
        return content;
    }
    let mut end = cap;
    while end > 0 && !content.is_char_boundary(end) {
        end -= 1;
    }
    &content[..end]
}

/// Cumulative byte/char/UTF-16 counts at a recorded position — a line start, or a
/// point inside a long line. `line` is the line the position sits in and
/// `line_start_utf16` is the UTF-16 count at the start of that line, so a seek that
/// anchors here can report the column (`utf16 - line_start_utf16`) without having
/// scanned from the line start. Checkpoints are sorted ascending by byte (hence by
/// char/UTF-16; `line` is non-decreasing).
#[derive(Clone, Copy)]
struct Checkpoint {
    byte: u64,
    char: u64,
    utf16: u64,
    line: u64,
    line_start_utf16: u64,
}

impl Checkpoint {
    /// A scan cursor starting at this checkpoint, carrying its line and the line's
    /// start so a within-line scan reports the column correctly even mid-line.
    fn cursor(&self) -> Cursor {
        Cursor {
            byte: self.byte,
            char: self.char,
            utf16: self.utf16,
            line: self.line,
            line_start_utf16: self.line_start_utf16,
        }
    }
}

/// A sparse line index over a [`ByteSource`], serving line-range text and
/// byte/char/UTF-16/line/column positions by reading only the needed window.
pub struct LineIndex<S> {
    source: S,
    /// Sorted checkpoints, at least one every `CHECKPOINT_LINES` lines and every
    /// `CHECKPOINT_BYTES` bytes. Always begins with the all-zero start of line 0.
    checkpoints: Vec<Checkpoint>,
    line_count: usize,
    byte_len: u64,
    char_len: u64,
    utf16_len: u64,
    max_line_byte_count: u64,
}

/// A mutable scan position carrying every count the index tracks. `line_start_utf16`
/// is the UTF-16 count at the start of the line `byte` currently sits in, so the
/// column is `utf16 - line_start_utf16`.
#[derive(Clone, Copy)]
struct Cursor {
    byte: u64,
    char: u64,
    utf16: u64,
    line: u64,
    line_start_utf16: u64,
}

/// Where a forward scan should stop.
#[derive(Clone, Copy)]
enum Stop {
    /// Stop at the start of this line (just after its preceding newline).
    AtLine(u64),
    /// Stop at the code-point boundary where the cumulative UTF-16 reaches this.
    AtUtf16(u64),
    /// Stop at this column (UTF-16 units into the current line) or the line's end.
    AtColumnInLine(u64),
}

impl<S: ByteSource> LineIndex<S> {
    /// Builds an index over `source`, scanning it once.
    pub fn build(source: S) -> io::Result<Self> {
        Self::build_with_checkpoints(source, CHECKPOINT_LINES, CHECKPOINT_BYTES)
    }

    /// Total number of lines (`newlines + 1`; an empty source is one line).
    pub fn line_count(&self) -> usize {
        self.line_count
    }

    /// Total length of the underlying source in bytes.
    pub fn byte_len(&self) -> u64 {
        self.byte_len
    }

    /// Total number of Unicode scalar values (chars).
    pub fn char_len(&self) -> u64 {
        self.char_len
    }

    /// Total number of UTF-16 code units.
    pub fn utf16_len(&self) -> u64 {
        self.utf16_len
    }

    /// Length in bytes of the longest line (including its terminator). Lets the
    /// platform refuse a file with a pathologically long single line instead of
    /// reading a multi-gigabyte window to render one row.
    pub fn max_line_byte_count(&self) -> u64 {
        self.max_line_byte_count
    }

    /// The content of lines `[start_line, start_line + count)` joined by `\n`, with
    /// each line's own terminator (`\n` or `\r\n`) stripped — the editor's band
    /// read. Matches [`crate::text_buffer::TextBuffer::text_for_line_range`]; an
    /// out-of-range request is clamped so scrolling never errors.
    pub fn text_for_line_range(&self, start_line: usize, count: usize) -> io::Result<String> {
        let total = self.line_count;
        if start_line >= total || count == 0 {
            return Ok(String::new());
        }
        let end_line = start_line.saturating_add(count).min(total);
        let start_byte = self.cumulative_at_line_start(start_line)?.byte;
        let end_byte = self.band_end_byte(end_line)?;
        self.format_band(
            start_byte,
            end_byte,
            end_line - start_line,
            end_line < total,
            None,
        )
    }

    /// Like [`text_for_line_range`](Self::text_for_line_range), but never returns
    /// more than `max_bytes_per_line` bytes of any single line's content, so one
    /// enormous line is not materialized just to paint a band.
    pub fn text_for_line_range_capped(
        &self,
        start_line: usize,
        count: usize,
        max_bytes_per_line: usize,
    ) -> io::Result<String> {
        let total = self.line_count;
        if start_line >= total || count == 0 {
            return Ok(String::new());
        }
        let end_line = start_line.saturating_add(count).min(total);
        let line_count = end_line - start_line;
        let start_byte = self.cumulative_at_line_start(start_line)?.byte;
        let end_byte = self.band_end_byte(end_line)?;

        // Fast path: the band fits roughly the cap budget — read it once and cap
        // each line in the assembled string (the per-line cap is still enforced;
        // the budget bounds the total, not any one line).
        let budget = line_count
            .saturating_mul(max_bytes_per_line.saturating_add(2))
            .saturating_add(2) as u64;
        if end_byte - start_byte <= budget {
            return self.format_band(
                start_byte,
                end_byte,
                line_count,
                end_line < total,
                Some(max_bytes_per_line),
            );
        }

        // Slow path: at least one line is very long. Read only a capped prefix of
        // each line so the giant line never fully materializes.
        let mut out = String::new();
        for line in start_line..end_line {
            if line > start_line {
                out.push('\n');
            }
            let line_start = self.cumulative_at_line_start(line)?.byte;
            // Cap plus slack for a trailing multi-byte char and a CRLF terminator.
            let want = max_bytes_per_line.saturating_add(4);
            let bytes = self.source.read_at(line_start, want)?;
            let chunk = String::from_utf8_lossy(&bytes);
            let content = match chunk.find('\n') {
                Some(newline) => chunk[..newline]
                    .strip_suffix('\r')
                    .unwrap_or(&chunk[..newline]),
                None => &chunk,
            };
            out.push_str(floor_to_byte_cap(content, max_bytes_per_line));
        }
        Ok(out)
    }

    /// The raw text of the UTF-16 range `[start, end)`, decoded lossily — used to
    /// copy a selection within or across lines, or to read a window inside one long
    /// line. Each endpoint maps to a byte offset by seeking to the nearest
    /// checkpoint and scanning forward; because checkpoints are recorded by byte as
    /// well as by line, that scan is bounded even deep inside a multi-megabyte line.
    pub fn text_for_utf16_range(&self, start: u64, end: u64) -> io::Result<String> {
        let start_byte = self.position_for_utf16(start)?.byte as u64;
        let end_byte = self.position_for_utf16(end)?.byte as u64;
        self.read_window(start_byte, end_byte)
    }

    /// Position (byte/char/UTF-16/line/column) of UTF-16 offset `utf16`, clamped to
    /// `[0, utf16_len]`. Seeks to the nearest checkpoint and scans forward.
    pub fn position_for_utf16(&self, utf16: u64) -> io::Result<Position> {
        let target = utf16.min(self.utf16_len);
        let anchor = self.checkpoints[self.checkpoint_index_for_utf16(target)];
        let mut cursor = anchor.cursor();
        self.advance(&mut cursor, Stop::AtUtf16(target))?;
        Ok(cursor.position())
    }

    /// Position at `column_utf16` UTF-16 units into `line` (both clamped). Maps a
    /// (line, column) caret/selection endpoint to a global offset.
    pub fn position_for_line_column(
        &self,
        line: usize,
        column_utf16: usize,
    ) -> io::Result<Position> {
        // Clamp to a real line — never the phantom `line_count`. (The platform
        // layer rejects a truly out-of-range line before calling in; here the
        // contract is clamp-safe.)
        let line = line.min(self.line_count.saturating_sub(1));
        let start = self.cumulative_at_line_start(line)?;
        let column = column_utf16 as u64;
        // A column at or past the line's content clamps to the content end.
        // Resolve that end directly (next line start minus the terminator) instead
        // of scanning the whole line, so clamping a huge line stays cheap.
        let end = self.line_content_end(line, &start)?;
        if column >= end.column_utf16 as u64 {
            return Ok(end);
        }
        // A column within the content: anchor at the densest checkpoint inside this
        // line at or before the target, then scan the bounded remainder.
        let target_utf16 = start.utf16 + column;
        let anchor = self.checkpoint_inside_line(line as u64, &start, target_utf16);
        let mut cursor = Cursor {
            byte: anchor.byte,
            char: anchor.char,
            utf16: anchor.utf16,
            line: line as u64,
            // The true start of this line, so the column is measured from there
            // even when the anchor sits mid-line.
            line_start_utf16: start.utf16,
        };
        self.advance(&mut cursor, Stop::AtColumnInLine(column))?;
        Ok(cursor.position())
    }

    fn build_with_checkpoints(
        source: S,
        checkpoint_lines: usize,
        checkpoint_bytes: u64,
    ) -> io::Result<Self> {
        let checkpoint_lines = checkpoint_lines.max(1);
        let checkpoint_bytes = checkpoint_bytes.max(1);
        let byte_len = source.len();

        let mut checkpoints = vec![Checkpoint {
            byte: 0,
            char: 0,
            utf16: 0,
            line: 0,
            line_start_utf16: 0,
        }];
        // The current line number (`newlines` so far) and counters for the two
        // cadences: lines since the last checkpoint, and the byte of the last
        // checkpoint (for the byte cadence).
        let mut newlines: u64 = 0;
        let mut lines_since_checkpoint: usize = 0;
        let mut last_checkpoint_byte: u64 = 0;
        let mut offset: u64 = 0;
        let mut char_count: u64 = 0;
        let mut utf16_count: u64 = 0;
        // Start of the line currently being scanned (byte and UTF-16), and the
        // longest line seen so far (start-of-line to start-of-next-line,
        // terminator included).
        let mut line_start_byte: u64 = 0;
        let mut line_start_utf16: u64 = 0;
        let mut max_line_byte_count: u64 = 0;

        while offset < byte_len {
            let want = (byte_len - offset).min(SCAN_CHUNK_BYTES as u64) as usize;
            let chunk = source.read_at(offset, want)?;
            if chunk.is_empty() {
                break; // source shrank or reported EOF early; stop scanning
            }
            for (i, &byte) in chunk.iter().enumerate() {
                let pos = offset + i as u64;
                // A non-continuation byte starts a code point; a 4-byte lead is a
                // non-BMP scalar (two UTF-16 units). Exact for valid UTF-8.
                let is_char_start = (byte & 0xC0) != 0x80;
                // Byte-cadence checkpoint, at a code-point boundary inside a long
                // run, so a within-line seek never scans more than the gap. The
                // counts here are for the content strictly before `pos`.
                if is_char_start && pos - last_checkpoint_byte >= checkpoint_bytes {
                    checkpoints.push(Checkpoint {
                        byte: pos,
                        char: char_count,
                        utf16: utf16_count,
                        line: newlines,
                        line_start_utf16,
                    });
                    last_checkpoint_byte = pos;
                    lines_since_checkpoint = 0;
                }
                if is_char_start {
                    char_count += 1;
                    // A valid 4-byte lead (0xF0..=0xF4) is a non-BMP scalar (two
                    // UTF-16 units). Exact for valid UTF-8; an invalid byte is
                    // counted as one unit, which can drift from lossy display.
                    utf16_count += if (0xF0..=0xF4).contains(&byte) { 2 } else { 1 };
                }
                if byte == NEWLINE {
                    newlines += 1;
                    let next_line_start = pos + 1;
                    max_line_byte_count =
                        max_line_byte_count.max(next_line_start - line_start_byte);
                    line_start_byte = next_line_start;
                    line_start_utf16 = utf16_count;
                    lines_since_checkpoint += 1;
                    // Line-cadence checkpoint, at the new line's start (skipped if a
                    // byte-cadence checkpoint already landed here).
                    if lines_since_checkpoint >= checkpoint_lines
                        && next_line_start > last_checkpoint_byte
                    {
                        checkpoints.push(Checkpoint {
                            byte: next_line_start,
                            char: char_count,
                            utf16: utf16_count,
                            line: newlines,
                            line_start_utf16,
                        });
                        last_checkpoint_byte = next_line_start;
                        lines_since_checkpoint = 0;
                    }
                }
            }
            offset += chunk.len() as u64;
        }
        // The final line carries no trailing newline; include its length too.
        max_line_byte_count = max_line_byte_count.max(byte_len - line_start_byte);

        Ok(Self {
            source,
            checkpoints,
            line_count: (newlines as usize) + 1,
            byte_len,
            char_len: char_count,
            utf16_len: utf16_count,
            max_line_byte_count,
        })
    }

    /// Reads `[start_byte, end_byte)` from the source and decodes it lossily.
    fn read_window(&self, start_byte: u64, end_byte: u64) -> io::Result<String> {
        if end_byte <= start_byte {
            return Ok(String::new());
        }
        let len = (end_byte - start_byte) as usize;
        let bytes = self.source.read_at(start_byte, len)?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    /// Byte offset where a band ending just before `end_line` stops: the start of
    /// `end_line`, or end of input when the band reaches the last line.
    fn band_end_byte(&self, end_line: usize) -> io::Result<u64> {
        if end_line < self.line_count {
            Ok(self.cumulative_at_line_start(end_line)?.byte)
        } else {
            Ok(self.byte_len)
        }
    }

    /// Formats an already-located byte band into `line_count` lines joined by `\n`,
    /// each terminator stripped (a `\r` right before a `\n` is part of the
    /// terminator). The final line keeps a genuine trailing `\r` only when it is
    /// the buffer's last line (`strip_final == false`). `cap`, when set, truncates
    /// each line's content on a char boundary. Mirrors `TextBuffer::format_band`.
    fn format_band(
        &self,
        start_byte: u64,
        end_byte: u64,
        line_count: usize,
        strip_final: bool,
        cap: Option<usize>,
    ) -> io::Result<String> {
        let raw = self.read_window(start_byte, end_byte)?;
        let mut out = String::with_capacity(raw.len());
        for (index, segment) in raw.split('\n').take(line_count).enumerate() {
            if index > 0 {
                out.push('\n');
            }
            let is_final = index + 1 == line_count;
            let content = if is_final && !strip_final {
                segment
            } else {
                segment.strip_suffix('\r').unwrap_or(segment)
            };
            match cap {
                Some(cap) => out.push_str(floor_to_byte_cap(content, cap)),
                None => out.push_str(content),
            }
        }
        Ok(out)
    }

    /// Cumulative counts at the start of `line`; for a line at or past the end, the
    /// "start" is end of input (the totals). The returned checkpoint's `line` is
    /// `line` itself (a line start, so its `line_start_utf16` equals its `utf16`).
    fn cumulative_at_line_start(&self, line: usize) -> io::Result<Checkpoint> {
        if line == 0 {
            return Ok(self.checkpoints[0]);
        }
        if line >= self.line_count {
            return Ok(Checkpoint {
                byte: self.byte_len,
                char: self.char_len,
                utf16: self.utf16_len,
                line: self.line_count.saturating_sub(1) as u64,
                line_start_utf16: self.utf16_len,
            });
        }
        // Anchor at the last checkpoint lying before `line` begins — the one just
        // before the first checkpoint whose line is `line` or greater — then scan
        // forward to the line start. The byte cadence bounds that scan even when an
        // intervening line is enormous.
        let target = line as u64;
        let index = self
            .checkpoints
            .partition_point(|checkpoint| checkpoint.line < target)
            .saturating_sub(1);
        let mut cursor = self.checkpoints[index].cursor();
        self.advance(&mut cursor, Stop::AtLine(target))?;
        Ok(Checkpoint {
            byte: cursor.byte,
            char: cursor.char,
            utf16: cursor.utf16,
            line: target,
            line_start_utf16: cursor.utf16,
        })
    }

    /// The position at the end of `line`'s content (terminator excluded). Derived
    /// from the next line's start minus the terminator — with a tiny read to size
    /// the terminator — so it is cheap even when `line` is enormous. `start` must be
    /// `line`'s start (passed in to avoid recomputing it).
    fn line_content_end(&self, line: usize, start: &Checkpoint) -> io::Result<Position> {
        let next = self.cumulative_at_line_start(line + 1)?;
        let terminator = self.terminator_len(start.byte, next.byte)?;
        // Each terminator unit (`\r`, `\n`) is one byte, one char, and one UTF-16
        // unit, so the same count is subtracted from all three.
        let utf16 = next.utf16 - terminator;
        Ok(Position {
            byte: (next.byte - terminator) as usize,
            char: (next.char - terminator) as usize,
            utf16: utf16 as usize,
            line,
            column_utf16: (utf16 - start.utf16) as usize,
        })
    }

    /// Length (0, 1, or 2) of the terminator ending the line spanning
    /// `[line_start, next)`: `\r\n` is 2, a lone `\n` is 1, and none (the file's
    /// last line) is 0.
    fn terminator_len(&self, line_start: u64, next: u64) -> io::Result<u64> {
        if next <= line_start {
            return Ok(0); // empty line, or end of input
        }
        let want: usize = if next - line_start >= 2 { 2 } else { 1 };
        let bytes = self.source.read_at(next - want as u64, want)?;
        match bytes.last() {
            // A `\r` immediately before the `\n` makes it a two-unit CRLF.
            Some(&NEWLINE) if bytes.len() == 2 && bytes[0] == b'\r' => Ok(2),
            Some(&NEWLINE) => Ok(1),
            _ => Ok(0),
        }
    }

    /// The densest checkpoint inside `line` at or before `target_utf16` (which must
    /// lie within the line's content), or `*start` when none is nearer than the
    /// line's start. Lets a within-line column seek skip ahead instead of scanning
    /// from the line start; either way the remaining scan is bounded by the byte
    /// cadence.
    fn checkpoint_inside_line(
        &self,
        line: u64,
        start: &Checkpoint,
        target_utf16: u64,
    ) -> Checkpoint {
        let anchor = self.checkpoints[self.checkpoint_index_for_utf16(target_utf16)];
        if anchor.line == line {
            anchor
        } else {
            *start
        }
    }

    /// Index of the last checkpoint whose UTF-16 count is `<= utf16`.
    fn checkpoint_index_for_utf16(&self, utf16: u64) -> usize {
        match self.checkpoints.binary_search_by(|c| c.utf16.cmp(&utf16)) {
            Ok(index) => index,
            Err(0) => 0,
            Err(insert) => insert - 1,
        }
    }

    /// Advances `cursor` forward through the source, classifying each byte, until
    /// `stop` is reached or end of input. The cursor always stops on a code-point
    /// boundary.
    fn advance(&self, cursor: &mut Cursor, stop: Stop) -> io::Result<()> {
        match stop {
            Stop::AtLine(target) if cursor.line >= target => return Ok(()),
            Stop::AtUtf16(target) if cursor.utf16 >= target => return Ok(()),
            _ => {}
        }

        // The byte just consumed, so a `\r` immediately before a `\n` can be
        // recognized as part of a CRLF terminator when clamping a column.
        let mut previous: u8 = 0;
        while cursor.byte < self.byte_len {
            let want = (self.byte_len - cursor.byte).min(SCAN_CHUNK_BYTES as u64) as usize;
            let chunk = self.source.read_at(cursor.byte, want)?;
            if chunk.is_empty() {
                break;
            }
            for &byte in &chunk {
                let is_char_start = (byte & 0xC0) != 0x80;
                let width: u64 = if (0xF0..=0xF4).contains(&byte) { 2 } else { 1 };
                // Stop conditions evaluated at the current byte (a boundary).
                match stop {
                    // Floor: stop at the boundary at or below `target`, so a target
                    // inside a surrogate pair resolves to the code point's start.
                    Stop::AtUtf16(target) if is_char_start && cursor.utf16 + width > target => {
                        return Ok(())
                    }
                    Stop::AtColumnInLine(_) if byte == NEWLINE => {
                        // Clamp to the line's content: a `\r` right before this `\n`
                        // is part of a CRLF terminator, so step back over it.
                        if previous == b'\r' {
                            cursor.byte -= 1;
                            cursor.char -= 1;
                            cursor.utf16 -= 1;
                        }
                        return Ok(());
                    }
                    Stop::AtColumnInLine(col)
                        if is_char_start && cursor.utf16 - cursor.line_start_utf16 >= col =>
                    {
                        return Ok(())
                    }
                    _ => {}
                }

                if is_char_start {
                    cursor.char += 1;
                    cursor.utf16 += width;
                }
                cursor.byte += 1;
                previous = byte;
                if byte == NEWLINE {
                    cursor.line += 1;
                    cursor.line_start_utf16 = cursor.utf16;
                    match stop {
                        Stop::AtLine(target) if cursor.line == target => return Ok(()),
                        _ => {}
                    }
                }
            }
        }
        Ok(())
    }
}

impl Cursor {
    fn position(&self) -> Position {
        Position {
            byte: self.byte as usize,
            char: self.char as usize,
            utf16: self.utf16 as usize,
            line: self.line as usize,
            column_utf16: (self.utf16 - self.line_start_utf16) as usize,
        }
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
        // A huge byte cadence keeps these cases on the line cadence alone, matching
        // the original behavior; `index_with_byte_cadence` exercises the byte one.
        LineIndex::build_with_checkpoints(
            VecSource(text.as_bytes().to_vec()),
            checkpoint_lines,
            u64::MAX,
        )
        .expect("build index")
    }

    /// Builds with an explicit byte cadence too, to force intra-line checkpoints so
    /// the within-line seek paths are exercised.
    fn index_with_byte_cadence(
        text: &str,
        checkpoint_lines: usize,
        checkpoint_bytes: u64,
    ) -> LineIndex<VecSource> {
        LineIndex::build_with_checkpoints(
            VecSource(text.as_bytes().to_vec()),
            checkpoint_lines,
            checkpoint_bytes,
        )
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
    fn returns_individual_lines_with_terminators_stripped() {
        let idx = index("a\nb\nc", 1024);
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "a");
        assert_eq!(idx.text_for_line_range(1, 1).unwrap(), "b");
        assert_eq!(idx.text_for_line_range(2, 1).unwrap(), "c");
    }

    #[test]
    fn trailing_newline_yields_a_final_empty_line() {
        let idx = index("a\n", 1024);
        assert_eq!(idx.line_count(), 2);
        assert_eq!(idx.text_for_line_range(0, 2).unwrap(), "a\n");
        assert_eq!(idx.text_for_line_range(1, 1).unwrap(), "");
    }

    #[test]
    fn resolves_ranges_across_sparse_checkpoints() {
        // checkpoint every 2 lines exercises the checkpoint + forward-scan path.
        let idx = index("L0\nL1\nL2\nL3\nL4", 2);
        assert_eq!(idx.line_count(), 5);
        assert_eq!(idx.text_for_line_range(3, 2).unwrap(), "L3\nL4");
        assert_eq!(idx.text_for_line_range(2, 1).unwrap(), "L2");
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "L0");
        // A count spanning several checkpoints returns the joined span.
        assert_eq!(idx.text_for_line_range(1, 3).unwrap(), "L1\nL2\nL3");
    }

    #[test]
    fn clamps_out_of_range_requests() {
        let idx = index("a\nb\nc", 1024);
        assert_eq!(idx.text_for_line_range(0, 99).unwrap(), "a\nb\nc"); // count clamped
        assert_eq!(idx.text_for_line_range(5, 9).unwrap(), ""); // start past the end
        assert_eq!(idx.text_for_line_range(1, 0).unwrap(), ""); // zero count
    }

    #[test]
    fn windows_never_split_multibyte_code_points() {
        let idx = index("あ\nい\nう", 1);
        assert_eq!(idx.line_count(), 3);
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "あ");
        assert_eq!(idx.text_for_line_range(1, 1).unwrap(), "い");
        assert_eq!(idx.text_for_line_range(2, 1).unwrap(), "う");
    }

    #[test]
    fn decodes_invalid_utf8_lossily_without_failing() {
        let source = VecSource(vec![b'a', 0xFF, NEWLINE, b'b']);
        let idx = LineIndex::build_with_checkpoints(source, 1024, u64::MAX).expect("build index");
        assert_eq!(idx.line_count(), 2);
        let first = idx.text_for_line_range(0, 1).unwrap();
        assert!(first.starts_with('a'));
        assert!(first.contains('\u{FFFD}')); // 0xFF rendered as replacement char
        assert!(!first.contains('\n')); // the line's own terminator is stripped
        assert_eq!(idx.text_for_line_range(1, 1).unwrap(), "b");
    }

    #[test]
    fn default_checkpoint_build_reads_correctly() {
        let idx = LineIndex::build(VecSource(b"one\ntwo\nthree".to_vec())).expect("build index");
        assert_eq!(idx.line_count(), 3);
        assert_eq!(idx.text_for_line_range(1, 1).unwrap(), "two");
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
        assert_eq!(idx.text_for_line_range(0, 1).unwrap(), "line-0");
        assert_eq!(idx.text_for_line_range(4999, 1).unwrap(), "line-4999");
        assert_eq!(
            idx.text_for_line_range(2500, 2).unwrap(),
            "line-2500\nline-2501"
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

    // "ab\n😀x\ncd": 😀 is 4 UTF-8 bytes = 1 char = 2 UTF-16 units.
    // line 0 "ab\n" (3 bytes, 3 chars, 3 utf16); line 1 "😀x\n" (6 bytes, 3 chars,
    // 4 utf16); line 2 "cd" (2 bytes, 2 chars, 2 utf16).
    const MIXED: &str = "ab\n😀x\ncd";

    #[test]
    fn counts_total_chars_and_utf16_with_non_bmp() {
        let idx = index(MIXED, 1024);
        assert_eq!(idx.byte_len(), 11);
        assert_eq!(idx.char_len(), 8);
        assert_eq!(idx.utf16_len(), 9);
    }

    #[test]
    fn maps_line_and_column_to_position() {
        let idx = index(MIXED, 1024);
        let at = |line, col| {
            let p = idx.position_for_line_column(line, col).unwrap();
            (p.byte, p.char, p.utf16, p.line, p.column_utf16)
        };
        assert_eq!(at(1, 0), (3, 3, 3, 1, 0)); // line 1 start
        assert_eq!(at(1, 2), (7, 4, 5, 1, 2)); // after 😀 (2 utf16, 4 bytes)
        assert_eq!(at(1, 3), (8, 5, 6, 1, 3)); // after 😀x
        assert_eq!(at(1, 99), (8, 5, 6, 1, 3)); // column clamps to line content
    }

    #[test]
    fn maps_utf16_offset_to_position() {
        let idx = index(MIXED, 1024);
        let at = |utf16| {
            let p = idx.position_for_utf16(utf16).unwrap();
            (p.byte, p.line, p.column_utf16, p.utf16)
        };
        assert_eq!(at(0), (0, 0, 0, 0));
        assert_eq!(at(5), (7, 1, 2, 5)); // line 1, after 😀
        assert_eq!(at(9), (11, 2, 2, 9)); // end of input
        assert_eq!(at(999), (11, 2, 2, 9)); // clamps to utf16_len
    }

    #[test]
    fn reads_text_for_utf16_range() {
        let idx = index(MIXED, 1024);
        assert_eq!(idx.text_for_utf16_range(3, 6).unwrap(), "😀x"); // bytes [3, 8)
        assert_eq!(idx.text_for_utf16_range(0, 2).unwrap(), "ab");
        assert_eq!(idx.text_for_utf16_range(6, 6).unwrap(), ""); // empty
    }

    #[test]
    fn positions_resolve_from_sparse_checkpoints() {
        // cadence 1: each line is a checkpoint, exercising the checkpoint anchors.
        let idx = index("a\nbb\nccc\ndddd", 1);
        let p = idx.position_for_line_column(3, 2).unwrap(); // "dddd", 2 in
        assert_eq!((p.line, p.column_utf16, p.utf16, p.byte), (3, 2, 11, 11));
        let p = idx.position_for_utf16(11).unwrap();
        assert_eq!((p.line, p.column_utf16), (3, 2));
    }

    #[test]
    fn out_of_range_line_clamps_to_the_last_line() {
        let idx = index("a\nb", 1024); // 2 lines (0 and 1)
        let p = idx.position_for_line_column(99, 0).unwrap();
        assert_eq!(p.line, 1); // the last real line, never the phantom line 2
    }

    #[test]
    fn column_clamps_before_a_crlf_terminator() {
        let idx = index("abc\r\ndef", 1024);
        // A column past the content lands at the end of "abc" (before the \r),
        // never between the \r and \n — matching TextBuffer.
        let p = idx.position_for_line_column(0, 99).unwrap();
        assert_eq!((p.byte, p.utf16, p.column_utf16), (3, 3, 3));
    }

    #[test]
    fn lone_carriage_return_stays_line_content() {
        // A \r not immediately before a \n is content, not a terminator.
        let idx = index("a\rb\n", 1024);
        let p = idx.position_for_line_column(0, 99).unwrap();
        assert_eq!((p.byte, p.column_utf16), (3, 3)); // "a\rb" is the content
    }

    #[test]
    fn utf16_offset_inside_a_surrogate_pair_floors() {
        // 𝄞 (U+1D11E) is one non-BMP scalar = 2 UTF-16 units (offsets 0,1).
        let idx = index("𝄞z", 1024);
        assert_eq!(idx.utf16_len(), 3);
        let mid = idx.position_for_utf16(1).unwrap(); // mid-surrogate → floor to start
        assert_eq!((mid.byte, mid.utf16, mid.column_utf16), (0, 0, 0));
        let after = idx.position_for_utf16(2).unwrap(); // boundary after 𝄞 (4 bytes)
        assert_eq!((after.byte, after.utf16), (4, 2));
    }

    #[test]
    fn invalid_utf8_positions_follow_byte_classification() {
        // Documented contract: counts use per-byte UTF-8 classification (exact for
        // valid UTF-8). A lone 0xFF counts as one char/one UTF-16 unit — which here
        // matches lossy display (one replacement char).
        let idx =
            LineIndex::build_with_checkpoints(VecSource(vec![b'a', 0xFF, b'b']), 1024, u64::MAX)
                .expect("build index");
        assert_eq!((idx.char_len(), idx.utf16_len()), (3, 3));
        // A stray 0xF0 looks like a 4-byte lead, so classification counts it as two
        // UTF-16 units (0xF0 + 'a' = 3), while lossy display would show one
        // replacement char (2). This is the documented divergence for invalid bytes.
        let stray = LineIndex::build_with_checkpoints(VecSource(vec![0xF0, b'a']), 1024, u64::MAX)
            .expect("build index");
        assert_eq!(stray.utf16_len(), 3);
    }

    #[test]
    fn band_strips_crlf_terminators_and_keeps_a_final_lone_cr() {
        // CRLF terminators are stripped from each line's content.
        let crlf = index("a\r\nb\r\nc", 1024);
        assert_eq!(crlf.text_for_line_range(0, 3).unwrap(), "a\nb\nc");
        // A trailing \r on the buffer's final line (no following \n) is content.
        let trailing = index("a\nb\r", 1024);
        assert_eq!(trailing.text_for_line_range(0, 2).unwrap(), "a\nb\r");
    }

    #[test]
    fn capped_band_truncates_long_lines_on_a_char_boundary() {
        // Fast path: the band fits the budget; line 0 is capped to 4 bytes.
        let fast = index("abcdef\ng", 1024);
        assert_eq!(fast.text_for_line_range_capped(0, 2, 4).unwrap(), "abcd\ng");
        // A multi-byte char is never split: a 4-byte cap on "あい" floors to "あ".
        let multibyte = index("あい\nz", 1024);
        assert_eq!(multibyte.text_for_line_range_capped(0, 1, 4).unwrap(), "あ");
    }

    #[test]
    fn capped_band_slow_path_caps_a_very_long_line() {
        // The middle line far exceeds the cap, forcing the per-line slow path; it
        // is still capped, and the giant line never fully materializes.
        let idx = index("short\nthis-is-a-much-longer-line\nx", 1024);
        assert_eq!(
            idx.text_for_line_range_capped(0, 3, 4).unwrap(),
            "shor\nthis\nx"
        );
    }

    // --- Intra-line (byte-cadence) checkpoints ---
    //
    // A tiny `checkpoint_bytes` forces many checkpoints *inside* a single line, so
    // these exercise the within-line seek that bounds work on a long line. The
    // results must match what the line-only cadence would produce.

    #[test]
    fn byte_checkpoints_resolve_positions_inside_a_long_line() {
        // Line 0 is 100 'a's; line 1 is "bcd". A checkpoint every 8 bytes lands many
        // checkpoints inside line 0.
        let text = format!("{}\nbcd", "a".repeat(100));
        let idx = index_with_byte_cadence(&text, 1024, 8);
        assert_eq!(idx.line_count(), 2);

        // A UTF-16 offset deep inside the long line resolves correctly.
        let at = idx.position_for_utf16(50).unwrap();
        assert_eq!((at.byte, at.line, at.column_utf16), (50, 0, 50));
        // The offset just past the long line's newline starts line 1.
        let next = idx.position_for_utf16(101).unwrap();
        assert_eq!((next.byte, next.line, next.column_utf16), (101, 1, 0));

        // A (line, column) deep inside the long line, and one clamped past its end.
        let mid = idx.position_for_line_column(0, 50).unwrap();
        assert_eq!((mid.byte, mid.column_utf16), (50, 50));
        let clamped = idx.position_for_line_column(0, 999).unwrap();
        assert_eq!((clamped.byte, clamped.column_utf16), (100, 100));

        // A window read inside the long line.
        assert_eq!(idx.text_for_utf16_range(48, 52).unwrap(), "aaaa");
    }

    #[test]
    fn byte_checkpoints_match_the_line_only_cadence() {
        // The same content under both cadences must resolve identically — the
        // intra-line checkpoints are a transparent optimization. `checkpoint_bytes`
        // of 1 records a checkpoint at every character (the densest case).
        let text = "ab\n😀x\ncd";
        let line_only = index(text, 1024);
        let byte_dense = index_with_byte_cadence(text, 1024, 1);
        let tuple = |p: Position| (p.byte, p.char, p.utf16, p.line, p.column_utf16);

        for utf16 in 0..=line_only.utf16_len() {
            assert_eq!(
                tuple(line_only.position_for_utf16(utf16).unwrap()),
                tuple(byte_dense.position_for_utf16(utf16).unwrap()),
                "utf16 {utf16}"
            );
        }
        for line in 0..line_only.line_count() {
            for col in 0..6 {
                assert_eq!(
                    tuple(line_only.position_for_line_column(line, col).unwrap()),
                    tuple(byte_dense.position_for_line_column(line, col).unwrap()),
                    "line {line} col {col}"
                );
            }
        }
    }

    #[test]
    fn byte_checkpoints_handle_non_bmp_and_crlf_in_a_long_line() {
        // A long line of a non-BMP scalar (😀 = 2 UTF-16 units, 4 bytes) terminated
        // by CRLF, checkpointed every few bytes.
        let text = format!("{}\r\nz", "😀".repeat(50)); // 100 UTF-16 units, 200 bytes
        let idx = index_with_byte_cadence(&text, 1024, 4);

        // A column past the content clamps before the CRLF (100 UTF-16 units).
        let end = idx.position_for_line_column(0, 999).unwrap();
        assert_eq!((end.column_utf16, end.utf16, end.byte), (100, 100, 200));
        // Offset 10 is after five emoji (10 UTF-16 units, 20 bytes).
        let p = idx.position_for_utf16(10).unwrap();
        assert_eq!((p.byte, p.line, p.column_utf16), (20, 0, 10));
        // A mid-surrogate offset floors to the scalar start (still a bounded seek).
        let mid = idx.position_for_utf16(11).unwrap();
        assert_eq!((mid.byte, mid.utf16), (20, 10));
    }

    #[test]
    fn build_resolves_positions_inside_a_line_longer_than_the_byte_cadence() {
        // Built through the production `build` (default cadences) with a single line
        // several `CHECKPOINT_BYTES` long, so the within-line seek is exercised on
        // the real byte-cadence path — the case the removed long-line guard blocked.
        let len = CHECKPOINT_BYTES as usize * 3 + 1234;
        let idx = LineIndex::build(VecSource("x".repeat(len).into_bytes())).expect("build index");
        assert_eq!(idx.line_count(), 1);

        // A position near the end resolves without scanning from the line start.
        let near_end = idx.position_for_line_column(0, len - 5).unwrap();
        assert_eq!((near_end.byte, near_end.column_utf16), (len - 5, len - 5));
        // A column past the end clamps to the content end (the whole line).
        let clamped = idx.position_for_line_column(0, len + 100).unwrap();
        assert_eq!((clamped.byte, clamped.column_utf16), (len, len));
        // A UTF-16 offset and a window read, both deep inside the line.
        let at = idx.position_for_utf16(len as u64 - 10).unwrap();
        assert_eq!((at.byte, at.line, at.column_utf16), (len - 10, 0, len - 10));
        assert_eq!(
            idx.text_for_utf16_range(len as u64 - 4, len as u64)
                .unwrap(),
            "xxxx"
        );
    }

    #[test]
    fn build_resolves_a_line_after_a_huge_line() {
        // The line after a huge line: resolving its start anchors at a byte
        // checkpoint near the huge line's end rather than scanning the whole line.
        let huge = "y".repeat(CHECKPOINT_BYTES as usize * 2);
        let idx =
            LineIndex::build(VecSource(format!("{huge}\ntail").into_bytes())).expect("build index");
        assert_eq!(idx.line_count(), 2);
        assert_eq!(idx.text_for_line_range(1, 1).unwrap(), "tail");
        let p = idx.position_for_line_column(1, 2).unwrap();
        assert_eq!((p.line, p.column_utf16), (1, 2));
    }
}
