//! Arbitrary-size text buffer engine.
//!
//! The buffer works exclusively in canonical UTF-8. Encoding detection and
//! transcoding for non-UTF-8 files stay on the platform side (Foundation),
//! which hands already-decoded UTF-8 bytes here; this keeps the core free of
//! external encoding dependencies while still letting UTF-8 files (the common
//! case) be mapped without copying.
//!
//! Content is modeled as a piece table: an immutable original (owned now,
//! memory-mapped from the FFI layer later) plus an append-only add buffer,
//! referenced by an ordered list of pieces. Edits never touch the original;
//! they trim pieces and append inserted text to the add buffer.
//!
//! The line index and offset conversions are currently recomputed by walking
//! the pieces (`O(n)`); a balanced tree with subtree aggregates replaces this
//! with `O(log n)` queries in a later slice, behind the same public API.

use std::error;
use std::fmt;

/// Borrowed access to the buffer's original content bytes.
///
/// The platform bridge supplies a memory-mapped implementation for large
/// files; tests and small files use [`OwnedBytes`]. Keeping this a trait lets
/// the core stay free of `unsafe` (the memory mapping lives in the FFI layer).
///
/// Implementations must return the same bytes for the lifetime of the value:
/// the buffer caches indexes over them. `Send + Sync` lets a buffer be built
/// off the main thread and handed to the editor's actor.
pub trait ContentBytes: Send + Sync {
    fn as_bytes(&self) -> &[u8];
}

/// Heap-owned content bytes.
#[derive(Debug, Clone)]
pub struct OwnedBytes(Box<[u8]>);

impl OwnedBytes {
    pub fn new(bytes: impl Into<Box<[u8]>>) -> Self {
        Self(bytes.into())
    }
}

impl ContentBytes for OwnedBytes {
    fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TextBufferError {
    /// The supplied bytes are not valid UTF-8. The platform side is expected to
    /// decode legacy encodings before handing bytes to the buffer.
    NotUtf8,
    /// A UTF-16 offset was past the end of the content, or fell between the two
    /// code units of a surrogate pair.
    InvalidUtf16Offset { offset: usize, limit: usize },
    /// A range whose end precedes its start.
    InvalidRange { start: usize, end: usize },
    /// A line index past the last line.
    InvalidLine { line: usize, total: usize },
}

impl fmt::Display for TextBufferError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotUtf8 => write!(formatter, "buffer content is not valid UTF-8"),
            Self::InvalidUtf16Offset { offset, limit } => {
                write!(
                    formatter,
                    "utf-16 offset {offset} is out of range (length {limit})"
                )
            }
            Self::InvalidRange { start, end } => {
                write!(formatter, "invalid range: end {end} precedes start {start}")
            }
            Self::InvalidLine { line, total } => {
                write!(
                    formatter,
                    "line {line} is out of range (line count {total})"
                )
            }
        }
    }
}

impl error::Error for TextBufferError {}

/// A position in the buffer expressed in every coordinate the editor needs:
/// the internal `byte` offset, the `char` (Unicode scalar) index, the `utf16`
/// code-unit offset (what AppKit/`NSRange` use), and the 0-based `line` with
/// its UTF-16 `column_utf16` from the line start.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Position {
    pub byte: usize,
    pub char: usize,
    pub utf16: usize,
    pub line: usize,
    pub column_utf16: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PieceSource {
    Original,
    Add,
}

/// A contiguous slice of one of the two byte stores.
#[derive(Debug, Clone, Copy)]
struct Piece {
    source: PieceSource,
    start: usize,
    len: usize,
}

/// One reversible edit, modeled uniformly as "at `at_byte`, the text `before`
/// was replaced by `after`". A pure insert has an empty `before`; a pure delete
/// has an empty `after`. `seq` identifies the edit across undo/redo so the
/// dirty flag can tell when the buffer returns to its saved state.
#[derive(Debug, Clone)]
struct EditRecord {
    seq: u64,
    at_byte: usize,
    before: String,
    after: String,
}

/// A line-indexed, editable UTF-8 text buffer.
pub struct TextBuffer {
    original: Box<dyn ContentBytes>,
    add: Vec<u8>,
    pieces: Vec<Piece>,
    /// Byte offset of the start of each logical line (logical = the assembled
    /// piece content). Always begins with `0`; a trailing newline yields a
    /// final empty line, matching the editor's line-number semantics.
    line_starts: Vec<usize>,
    utf16_len: usize,
    byte_len: usize,
    undo_stack: Vec<EditRecord>,
    redo_stack: Vec<EditRecord>,
    seq_counter: u64,
    /// `seq` of the top undo record when the buffer was last saved (or `None`
    /// if saved while empty). The buffer is dirty when the current top differs.
    saved_seq: Option<u64>,
    revision: u64,
}

impl TextBuffer {
    /// Builds a buffer from owned UTF-8 bytes.
    pub fn from_utf8_bytes(bytes: impl Into<Box<[u8]>>) -> Result<Self, TextBufferError> {
        Self::from_source(Box::new(OwnedBytes::new(bytes)))
    }

    /// Builds a buffer from any content source. The bytes must be valid UTF-8.
    pub fn from_source(source: Box<dyn ContentBytes>) -> Result<Self, TextBufferError> {
        let bytes = source.as_bytes();
        if std::str::from_utf8(bytes).is_err() {
            return Err(TextBufferError::NotUtf8);
        }

        let pieces = if bytes.is_empty() {
            Vec::new()
        } else {
            vec![Piece {
                source: PieceSource::Original,
                start: 0,
                len: bytes.len(),
            }]
        };

        let mut buffer = Self {
            original: source,
            add: Vec::new(),
            pieces,
            line_starts: vec![0],
            utf16_len: 0,
            byte_len: 0,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            seq_counter: 0,
            saved_seq: None,
            revision: 0,
        };
        buffer.recompute_caches();
        Ok(buffer)
    }

    // MARK: - Read queries

    /// Total bytes of UTF-8 content.
    pub fn byte_len(&self) -> usize {
        self.byte_len
    }

    /// Total UTF-16 code units (the unit AppKit/`NSRange` speak in).
    pub fn utf16_len(&self) -> usize {
        self.utf16_len
    }

    /// Number of logical lines. A trailing newline counts a final empty line.
    pub fn line_count(&self) -> usize {
        self.line_starts.len()
    }

    /// A monotonic counter bumped on every content mutation (including undo and
    /// redo). Lets the platform detect "content changed, re-render".
    pub fn revision(&self) -> u64 {
        self.revision
    }

    /// Whether there are unsaved edits relative to the last
    /// [`mark_saved`](Self::mark_saved) point, tracked by edit *history*:
    /// undoing back to the saved edit clears it. This is history-based, not a
    /// content comparison, so manually retyping the saved text still reads
    /// dirty (matching how typical editors treat the undo position).
    pub fn is_dirty(&self) -> bool {
        self.current_top_seq() != self.saved_seq
    }

    /// Marks the current content as the saved baseline.
    pub fn mark_saved(&mut self) {
        self.saved_seq = self.current_top_seq();
    }

    /// Returns the content of lines `[start_line, start_line + count)` joined by
    /// `\n`, with each line's own terminator (`\n` or `\r\n`) stripped. This is
    /// the editor viewport read: one coarse call paints a visible band.
    ///
    /// Out-of-range requests are clamped, so scrolling never errors.
    pub fn text_for_line_range(&self, start_line: usize, count: usize) -> String {
        let total = self.line_count();
        if start_line >= total || count == 0 {
            return String::new();
        }
        let end_line = start_line.saturating_add(count).min(total);

        let mut out = String::new();
        for line in start_line..end_line {
            if line > start_line {
                out.push('\n');
            }
            let (start, end) = self.line_bounds(line);
            let mut content = self.read_logical(start, end);
            if content.ends_with('\n') {
                content.pop();
                if content.ends_with('\r') {
                    content.pop();
                }
            }
            out.push_str(&content);
        }
        out
    }

    // MARK: - Edits

    /// Inserts `text` at UTF-16 offset `at_utf16`. Consecutive single-run
    /// inserts at the advancing caret coalesce into one undo step.
    pub fn insert(&mut self, at_utf16: usize, text: &str) -> Result<(), TextBufferError> {
        if text.is_empty() {
            return Ok(());
        }
        let at_byte = self.utf16_to_byte(at_utf16)?;
        self.apply_replace(at_byte, 0, text);
        self.redo_stack.clear();

        // Extend the previous typed run, but never coalesce into the saved
        // baseline record: doing so would hide the new edit from dirty tracking.
        let saved_seq = self.saved_seq;
        if let Some(top) = self.undo_stack.last_mut() {
            if top.before.is_empty()
                && top.at_byte + top.after.len() == at_byte
                && Some(top.seq) != saved_seq
            {
                top.after.push_str(text);
                return Ok(());
            }
        }

        let seq = self.next_seq();
        self.undo_stack.push(EditRecord {
            seq,
            at_byte,
            before: String::new(),
            after: text.to_string(),
        });
        Ok(())
    }

    /// Deletes the UTF-16 range `[start_utf16, end_utf16)`.
    pub fn delete(&mut self, start_utf16: usize, end_utf16: usize) -> Result<(), TextBufferError> {
        if end_utf16 < start_utf16 {
            return Err(TextBufferError::InvalidRange {
                start: start_utf16,
                end: end_utf16,
            });
        }
        if end_utf16 == start_utf16 {
            return Ok(());
        }
        let start_byte = self.utf16_to_byte(start_utf16)?;
        let end_byte = self.utf16_to_byte(end_utf16)?;
        let before = self.read_logical(start_byte, end_byte);

        self.apply_replace(start_byte, end_byte - start_byte, "");
        self.redo_stack.clear();

        let seq = self.next_seq();
        self.undo_stack.push(EditRecord {
            seq,
            at_byte: start_byte,
            before,
            after: String::new(),
        });
        Ok(())
    }

    /// Reverts the most recent edit. Returns `false` if there is nothing to undo.
    pub fn undo(&mut self) -> bool {
        let Some(record) = self.undo_stack.pop() else {
            return false;
        };
        self.apply_replace(record.at_byte, record.after.len(), &record.before);
        self.redo_stack.push(record);
        true
    }

    /// Re-applies the most recently undone edit. Returns `false` if there is
    /// nothing to redo.
    pub fn redo(&mut self) -> bool {
        let Some(record) = self.redo_stack.pop() else {
            return false;
        };
        self.apply_replace(record.at_byte, record.before.len(), &record.after);
        self.undo_stack.push(record);
        true
    }

    // MARK: - Internals

    fn current_top_seq(&self) -> Option<u64> {
        self.undo_stack.last().map(|record| record.seq)
    }

    fn next_seq(&mut self) -> u64 {
        self.seq_counter += 1;
        self.seq_counter
    }

    fn piece_bytes(&self, piece: &Piece) -> &[u8] {
        let buffer = match piece.source {
            PieceSource::Original => self.original.as_bytes(),
            PieceSource::Add => &self.add,
        };
        &buffer[piece.start..piece.start + piece.len]
    }

    /// Logical byte range of a line including its trailing terminator.
    fn line_bounds(&self, line: usize) -> (usize, usize) {
        let start = self.line_starts[line];
        let end = if line + 1 < self.line_starts.len() {
            self.line_starts[line + 1]
        } else {
            self.byte_len
        };
        (start, end)
    }

    /// The byte at logical offset `at`, if it is in range.
    fn logical_byte(&self, at: usize) -> Option<u8> {
        let mut offset = 0;
        for piece in &self.pieces {
            let piece_end = offset + piece.len;
            if at < piece_end {
                return Some(self.piece_bytes(piece)[at - offset]);
            }
            offset = piece_end;
        }
        None
    }

    /// End of a line's *content* — the terminating `\n` and a preceding `\r` are
    /// excluded — so a caret can never be placed inside a CRLF terminator.
    fn line_content_end(&self, line: usize) -> usize {
        let (start, end) = self.line_bounds(line);
        let mut content_end = end;
        if content_end > start && self.logical_byte(content_end - 1) == Some(b'\n') {
            content_end -= 1;
            if content_end > start && self.logical_byte(content_end - 1) == Some(b'\r') {
                content_end -= 1;
            }
        }
        content_end
    }

    /// Assembles the UTF-8 text for a logical byte range. The range endpoints
    /// are always on character boundaries (line starts follow ASCII `\n`, and
    /// edit positions are validated to char boundaries), so slicing is safe.
    fn read_logical(&self, start: usize, end: usize) -> String {
        let mut out = String::with_capacity(end.saturating_sub(start));
        let mut offset = 0;
        for piece in &self.pieces {
            let piece_end = offset + piece.len;
            if piece_end <= start {
                offset = piece_end;
                continue;
            }
            if offset >= end {
                break;
            }
            let bytes = self.piece_bytes(piece);
            let from = start.max(offset) - offset;
            let to = end.min(piece_end) - offset;
            out.push_str(
                std::str::from_utf8(&bytes[from..to])
                    .expect("piece content is validated UTF-8 on char boundaries"),
            );
            offset = piece_end;
        }
        out
    }

    /// Maps a UTF-16 offset to a full [`Position`]. The end-of-buffer offset is
    /// valid; an offset inside a surrogate pair or past the end is rejected.
    pub fn position_for_utf16(&self, target_utf16: usize) -> Result<Position, TextBufferError> {
        if target_utf16 > self.utf16_len {
            return Err(TextBufferError::InvalidUtf16Offset {
                offset: target_utf16,
                limit: self.utf16_len,
            });
        }
        let mut position = Position::default();
        for piece in &self.pieces {
            let text = std::str::from_utf8(self.piece_bytes(piece))
                .expect("piece content is validated UTF-8");
            for character in text.chars() {
                if position.utf16 == target_utf16 {
                    return Ok(position);
                }
                advance_position(&mut position, character);
            }
        }
        if position.utf16 == target_utf16 {
            Ok(position)
        } else {
            // Landed between the two code units of a surrogate pair.
            Err(TextBufferError::InvalidUtf16Offset {
                offset: target_utf16,
                limit: self.utf16_len,
            })
        }
    }

    /// Maps a 0-based `line` and UTF-16 `column_utf16` (from the line start) to
    /// a full [`Position`]. A column past the line's content is clamped to the
    /// end of the line, so clicking past the last character places the caret
    /// there.
    pub fn position_for_line_column(
        &self,
        line: usize,
        column_utf16: usize,
    ) -> Result<Position, TextBufferError> {
        let total = self.line_count();
        if line >= total {
            return Err(TextBufferError::InvalidLine { line, total });
        }
        // Stop at the line's content end so a column past the last character
        // clamps before any `\r\n`/`\n` terminator rather than inside it.
        let content_end = self.line_content_end(line);
        let mut position = Position::default();
        for piece in &self.pieces {
            let text = std::str::from_utf8(self.piece_bytes(piece))
                .expect("piece content is validated UTF-8");
            for character in text.chars() {
                if position.line == line
                    && (position.column_utf16 >= column_utf16 || position.byte >= content_end)
                {
                    return Ok(position);
                }
                advance_position(&mut position, character);
            }
        }
        // End of buffer: the target line is the final (possibly empty) line.
        Ok(position)
    }

    /// Converts a UTF-16 offset to a logical byte offset.
    fn utf16_to_byte(&self, target_utf16: usize) -> Result<usize, TextBufferError> {
        Ok(self.position_for_utf16(target_utf16)?.byte)
    }

    /// Replaces `remove_len` logical bytes at `at_byte` with `insert`, rewriting
    /// the piece list and recomputing the cached indexes.
    fn apply_replace(&mut self, at_byte: usize, remove_len: usize, insert: &str) {
        let delete_end = at_byte + remove_len;
        let add_start = self.add.len();
        if !insert.is_empty() {
            self.add.extend_from_slice(insert.as_bytes());
        }

        let mut new_pieces = Vec::with_capacity(self.pieces.len() + 2);

        // Fragments before the edit point.
        let mut offset = 0;
        for piece in &self.pieces {
            let piece_end = offset + piece.len;
            if offset < at_byte {
                let keep_end = piece_end.min(at_byte);
                if keep_end > offset {
                    new_pieces.push(Piece {
                        source: piece.source,
                        start: piece.start,
                        len: keep_end - offset,
                    });
                }
            }
            offset = piece_end;
        }

        // The inserted text.
        if !insert.is_empty() {
            new_pieces.push(Piece {
                source: PieceSource::Add,
                start: add_start,
                len: insert.len(),
            });
        }

        // Fragments after the deleted range.
        let mut offset = 0;
        for piece in &self.pieces {
            let piece_end = offset + piece.len;
            if piece_end > delete_end {
                let keep_start = offset.max(delete_end);
                let within = keep_start - offset;
                new_pieces.push(Piece {
                    source: piece.source,
                    start: piece.start + within,
                    len: piece_end - keep_start,
                });
            }
            offset = piece_end;
        }

        self.pieces = new_pieces;
        self.recompute_caches();
        self.revision += 1;
    }

    /// Recomputes the line index and length caches by walking the pieces.
    /// Replaced by an incremental `O(log n)` index in a later slice.
    fn recompute_caches(&mut self) {
        let mut line_starts = vec![0];
        let mut utf16_len = 0;
        let mut byte_len = 0;
        for piece in &self.pieces {
            let bytes = self.piece_bytes(piece);
            for (index, byte) in bytes.iter().enumerate() {
                if *byte == b'\n' {
                    line_starts.push(byte_len + index + 1);
                }
            }
            let text = std::str::from_utf8(bytes).expect("piece content is validated UTF-8");
            utf16_len += text.chars().map(char::len_utf16).sum::<usize>();
            byte_len += bytes.len();
        }
        self.line_starts = line_starts;
        self.utf16_len = utf16_len;
        self.byte_len = byte_len;
    }
}

/// Advances a [`Position`] past `character`, updating every coordinate. A
/// newline moves to the start of the next line.
fn advance_position(position: &mut Position, character: char) {
    position.byte += character.len_utf8();
    position.char += 1;
    position.utf16 += character.len_utf16();
    if character == '\n' {
        position.line += 1;
        position.column_utf16 = 0;
    } else {
        position.column_utf16 += character.len_utf16();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer(text: &str) -> TextBuffer {
        TextBuffer::from_utf8_bytes(text.as_bytes().to_vec()).expect("valid utf-8")
    }

    fn contents(buffer: &TextBuffer) -> String {
        buffer.text_for_line_range(0, buffer.line_count())
    }

    // MARK: - Read (read-only slice behavior, retained)

    #[test]
    fn rejects_invalid_utf8() {
        let invalid = vec![0xFF, 0xFE, 0x00];
        assert_eq!(
            TextBuffer::from_utf8_bytes(invalid).err(),
            Some(TextBufferError::NotUtf8)
        );
    }

    #[test]
    fn empty_buffer_has_single_empty_line() {
        let buffer = buffer("");
        assert_eq!(buffer.line_count(), 1);
        assert_eq!(buffer.byte_len(), 0);
        assert_eq!(buffer.utf16_len(), 0);
        assert_eq!(buffer.text_for_line_range(0, 1), "");
    }

    #[test]
    fn trailing_newline_adds_a_final_empty_line() {
        let buffer = buffer("abc\n");
        assert_eq!(buffer.line_count(), 2);
        assert_eq!(buffer.text_for_line_range(0, 2), "abc\n");
        assert_eq!(buffer.text_for_line_range(1, 1), "");
    }

    #[test]
    fn crlf_line_terminators_are_stripped_from_content() {
        let buffer = buffer("abc\r\ndef\r\n");
        assert_eq!(buffer.line_count(), 3);
        assert_eq!(buffer.text_for_line_range(0, 1), "abc");
        assert_eq!(buffer.text_for_line_range(0, 2), "abc\ndef");
    }

    #[test]
    fn lone_carriage_return_is_not_a_line_break() {
        let buffer = buffer("a\rb\n");
        assert_eq!(buffer.line_count(), 2);
        assert_eq!(buffer.text_for_line_range(0, 1), "a\rb");
    }

    #[test]
    fn line_range_clamps_past_the_end() {
        let buffer = buffer("a\nb");
        assert_eq!(buffer.text_for_line_range(1, 10), "b");
        assert_eq!(buffer.text_for_line_range(5, 3), "");
        assert_eq!(buffer.text_for_line_range(0, 0), "");
    }

    #[test]
    fn utf16_length_counts_surrogate_pairs_and_multibyte() {
        let buffer = buffer("aあ𝄞");
        assert_eq!(buffer.byte_len(), 1 + 3 + 4);
        assert_eq!(buffer.utf16_len(), 1 + 1 + 2);
    }

    #[test]
    fn builds_from_a_content_source() {
        let source: Box<dyn ContentBytes> = Box::new(OwnedBytes::new(b"x\ny".to_vec()));
        let buffer = TextBuffer::from_source(source).expect("valid utf-8");
        assert_eq!(buffer.line_count(), 2);
        assert_eq!(buffer.text_for_line_range(0, 2), "x\ny");
    }

    // MARK: - Edits

    #[test]
    fn insert_into_empty_buffer() {
        let mut buffer = buffer("");
        buffer.insert(0, "hello").expect("insert");
        assert_eq!(contents(&buffer), "hello");
        assert_eq!(buffer.utf16_len(), 5);
    }

    #[test]
    fn insert_in_the_middle() {
        let mut buffer = buffer("ac");
        buffer.insert(1, "b").expect("insert");
        assert_eq!(contents(&buffer), "abc");
    }

    #[test]
    fn insert_at_end() {
        let mut buffer = buffer("ab");
        buffer.insert(2, "c").expect("insert");
        assert_eq!(contents(&buffer), "abc");
    }

    #[test]
    fn insert_newline_increases_line_count() {
        let mut buffer = buffer("ab");
        buffer.insert(1, "\n").expect("insert");
        assert_eq!(buffer.line_count(), 2);
        assert_eq!(buffer.text_for_line_range(0, 1), "a");
        assert_eq!(buffer.text_for_line_range(1, 1), "b");
    }

    #[test]
    fn delete_a_range() {
        let mut buffer = buffer("abcdef");
        buffer.delete(1, 4).expect("delete");
        assert_eq!(contents(&buffer), "aef");
    }

    #[test]
    fn delete_across_a_line_boundary_merges_lines() {
        let mut buffer = buffer("ab\ncd");
        // Delete the newline (utf16 offsets 2..3).
        buffer.delete(2, 3).expect("delete");
        assert_eq!(buffer.line_count(), 1);
        assert_eq!(contents(&buffer), "abcd");
    }

    #[test]
    fn delete_everything() {
        let mut buffer = buffer("abc");
        buffer.delete(0, 3).expect("delete");
        assert_eq!(contents(&buffer), "");
        assert_eq!(buffer.line_count(), 1);
    }

    #[test]
    fn edits_use_utf16_offsets_for_multibyte_text() {
        let mut buffer = buffer("aあb");
        // "あ" occupies one UTF-16 unit at offset 1; insert after it (offset 2).
        buffer.insert(2, "X").expect("insert");
        assert_eq!(contents(&buffer), "aあXb");
    }

    #[test]
    fn edits_handle_surrogate_pair_offsets() {
        let mut buffer = buffer("𝄞z");
        // The astral char spans utf16 offsets 0..2; insert at offset 2 (after it).
        buffer.insert(2, "!").expect("insert");
        assert_eq!(contents(&buffer), "𝄞!z");
    }

    #[test]
    fn rejects_offset_inside_a_surrogate_pair() {
        let mut buffer = buffer("𝄞");
        assert_eq!(
            buffer.insert(1, "x").err(),
            Some(TextBufferError::InvalidUtf16Offset {
                offset: 1,
                limit: 2
            })
        );
    }

    #[test]
    fn rejects_out_of_range_offset() {
        let mut buffer = buffer("ab");
        assert!(matches!(
            buffer.insert(99, "x"),
            Err(TextBufferError::InvalidUtf16Offset { .. })
        ));
    }

    #[test]
    fn rejects_inverted_range() {
        let mut buffer = buffer("abc");
        assert_eq!(
            buffer.delete(2, 1).err(),
            Some(TextBufferError::InvalidRange { start: 2, end: 1 })
        );
    }

    // MARK: - Undo / redo

    #[test]
    fn undo_and_redo_an_insert() {
        let mut buffer = buffer("ac");
        buffer.insert(1, "b").expect("insert");
        assert_eq!(contents(&buffer), "abc");
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "ac");
        assert!(buffer.redo());
        assert_eq!(contents(&buffer), "abc");
    }

    #[test]
    fn undo_and_redo_a_delete() {
        let mut buffer = buffer("abcdef");
        buffer.delete(1, 4).expect("delete");
        assert_eq!(contents(&buffer), "aef");
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "abcdef");
        assert!(buffer.redo());
        assert_eq!(contents(&buffer), "aef");
    }

    #[test]
    fn undo_on_empty_history_returns_false() {
        let mut buffer = buffer("ab");
        assert!(!buffer.undo());
        assert!(!buffer.redo());
    }

    #[test]
    fn contiguous_typing_coalesces_into_one_undo_step() {
        let mut buffer = buffer("");
        buffer.insert(0, "h").expect("insert");
        buffer.insert(1, "i").expect("insert");
        buffer.insert(2, "!").expect("insert");
        assert_eq!(contents(&buffer), "hi!");
        // A single undo reverts the whole typed run.
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "");
        assert!(!buffer.undo());
    }

    #[test]
    fn non_contiguous_inserts_are_separate_undo_steps() {
        let mut buffer = buffer("..");
        buffer.insert(0, "a").expect("insert");
        // Jump the caret: insert not contiguous with the previous run.
        buffer.insert(3, "b").expect("insert");
        assert_eq!(contents(&buffer), "a..b");
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "a..");
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "..");
    }

    #[test]
    fn a_new_edit_clears_the_redo_stack() {
        let mut buffer = buffer("");
        buffer.insert(0, "a").expect("insert");
        buffer.undo();
        buffer.insert(0, "b").expect("insert");
        // Redo of the original insert is no longer available.
        assert!(!buffer.redo());
        assert_eq!(contents(&buffer), "b");
    }

    // MARK: - Dirty tracking

    #[test]
    fn buffer_starts_clean() {
        let buffer = buffer("abc");
        assert!(!buffer.is_dirty());
    }

    #[test]
    fn edit_marks_dirty_and_save_clears_it() {
        let mut buffer = buffer("abc");
        buffer.insert(3, "d").expect("insert");
        assert!(buffer.is_dirty());
        buffer.mark_saved();
        assert!(!buffer.is_dirty());
        buffer.insert(4, "e").expect("insert");
        assert!(buffer.is_dirty());
    }

    #[test]
    fn undo_back_to_saved_state_is_not_dirty() {
        let mut buffer = buffer("abc");
        buffer.insert(3, "X").expect("insert");
        buffer.mark_saved();
        buffer.insert(4, "Y").expect("insert");
        assert!(buffer.is_dirty());
        buffer.undo(); // back to the saved content
        assert!(!buffer.is_dirty());
    }

    #[test]
    fn revision_advances_on_every_mutation() {
        let mut buffer = buffer("");
        let start = buffer.revision();
        buffer.insert(0, "a").expect("insert");
        buffer.undo();
        assert!(buffer.revision() > start + 1);
    }

    #[test]
    fn inserting_empty_string_is_a_noop() {
        let mut buffer = buffer("ab");
        let revision = buffer.revision();
        buffer.insert(1, "").expect("noop");
        assert_eq!(buffer.revision(), revision);
        assert!(!buffer.is_dirty());
        assert_eq!(contents(&buffer), "ab");
    }

    #[test]
    fn deleting_an_empty_range_is_a_noop() {
        let mut buffer = buffer("ab");
        let revision = buffer.revision();
        buffer.delete(1, 1).expect("noop");
        assert_eq!(buffer.revision(), revision);
        assert!(!buffer.is_dirty());
    }

    #[test]
    fn insert_after_delete_does_not_coalesce() {
        let mut buffer = buffer("abc");
        buffer.delete(2, 3).expect("delete"); // "ab"
        buffer.insert(2, "X").expect("insert"); // "abX"
        assert_eq!(contents(&buffer), "abX");
        assert!(buffer.undo()); // undo the insert only
        assert_eq!(contents(&buffer), "ab");
        assert!(buffer.undo()); // undo the delete
        assert_eq!(contents(&buffer), "abc");
    }

    #[test]
    fn delete_spanning_multiple_pieces() {
        let mut buffer = buffer("HELLOWORLD");
        buffer.insert(5, "-").expect("insert"); // "HELLO-WORLD" (3 pieces)
        buffer.delete(3, 8).expect("delete"); // remove "LO-WO" across all 3 pieces
        assert_eq!(contents(&buffer), "HELRLD");
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "HELLO-WORLD");
    }

    #[test]
    fn redo_after_a_coalesced_run() {
        let mut buffer = buffer("");
        buffer.insert(0, "a").expect("insert");
        buffer.insert(1, "b").expect("insert"); // coalesced
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "");
        assert!(buffer.redo()); // re-applies the whole run at once
        assert_eq!(contents(&buffer), "ab");
    }

    #[test]
    fn contiguous_insert_after_save_does_not_coalesce_into_saved_record() {
        let mut buffer = buffer("");
        buffer.insert(0, "a").expect("insert");
        buffer.mark_saved();
        assert!(!buffer.is_dirty());
        // Typing right after the saved character is contiguous, but must start a
        // new undo record so the save point stays reachable.
        buffer.insert(1, "b").expect("insert");
        assert!(buffer.is_dirty());
        assert_eq!(contents(&buffer), "ab");
        buffer.undo(); // removes only "b", back to the saved "a"
        assert_eq!(contents(&buffer), "a");
        assert!(!buffer.is_dirty());
    }

    // MARK: - Position conversions

    #[test]
    fn position_for_utf16_at_start_and_across_lines() {
        let buffer = buffer("ab\ncde");
        let start = buffer.position_for_utf16(0).expect("start");
        assert_eq!(start, Position::default());

        let middle = buffer.position_for_utf16(4).expect("middle");
        assert_eq!(
            middle,
            Position {
                byte: 4,
                char: 4,
                utf16: 4,
                line: 1,
                column_utf16: 1,
            }
        );

        let end = buffer.position_for_utf16(buffer.utf16_len()).expect("end");
        assert_eq!(end.line, 1);
        assert_eq!(end.column_utf16, 3);
    }

    #[test]
    fn position_for_utf16_tracks_multibyte_columns() {
        let buffer = buffer("aあ𝄞");
        // After "aあ" (utf16 offset 2), before the astral "𝄞".
        let position = buffer.position_for_utf16(2).expect("position");
        assert_eq!(position.byte, 1 + 3);
        assert_eq!(position.char, 2);
        assert_eq!(position.column_utf16, 2);
    }

    #[test]
    fn position_for_utf16_rejects_mid_surrogate_and_past_end() {
        let buffer = buffer("𝄞");
        assert!(matches!(
            buffer.position_for_utf16(1),
            Err(TextBufferError::InvalidUtf16Offset { .. })
        ));
        assert!(matches!(
            buffer.position_for_utf16(99),
            Err(TextBufferError::InvalidUtf16Offset { .. })
        ));
    }

    #[test]
    fn position_for_line_column_maps_into_a_line() {
        let buffer = buffer("ab\ncde");
        let position = buffer.position_for_line_column(1, 1).expect("position");
        assert_eq!(position.utf16, 4);
        assert_eq!(position.byte, 4);
        assert_eq!(position.line, 1);
        assert_eq!(position.column_utf16, 1);
    }

    #[test]
    fn position_for_line_column_clamps_past_line_end() {
        let buffer = buffer("abc");
        let position = buffer.position_for_line_column(0, 10).expect("clamped");
        assert_eq!(position.column_utf16, 3);
        assert_eq!(position.utf16, 3);
    }

    #[test]
    fn position_for_line_column_handles_empty_and_final_lines() {
        let doc = buffer("x\n\ny");
        // The middle empty line.
        let empty = doc.position_for_line_column(1, 0).expect("empty line");
        assert_eq!(empty.line, 1);
        assert_eq!(empty.column_utf16, 0);
        assert_eq!(empty.utf16, 2);
        // A column past the empty line clamps to its (zero-length) end.
        let clamped = doc.position_for_line_column(1, 5).expect("clamped");
        assert_eq!(clamped.utf16, 2);

        let trailing = buffer("ab\n");
        let final_line = trailing.position_for_line_column(1, 0).expect("final");
        assert_eq!(final_line.line, 1);
        assert_eq!(final_line.utf16, 3);
    }

    #[test]
    fn position_for_line_column_clamps_before_crlf_terminator() {
        let buffer = buffer("abc\r\ndef");
        // A column past the line content must land at the end of "abc" (before
        // the \r), never between the \r and \n.
        let position = buffer.position_for_line_column(0, 99).expect("clamped");
        assert_eq!(position.utf16, 3);
        assert_eq!(position.byte, 3);
        assert_eq!(position.column_utf16, 3);
    }

    #[test]
    fn position_for_line_column_rejects_out_of_range_line() {
        let buffer = buffer("a\nb");
        assert_eq!(
            buffer.position_for_line_column(2, 0).err(),
            Some(TextBufferError::InvalidLine { line: 2, total: 2 })
        );
    }

    #[test]
    fn line_column_round_trips_with_utf16() {
        let buffer = buffer("ab\ncde\n𝄞z");
        for offset in [0, 1, 4, 7, 9] {
            let position = buffer.position_for_utf16(offset).expect("by utf16");
            let round = buffer
                .position_for_line_column(position.line, position.column_utf16)
                .expect("by line/column");
            assert_eq!(round.utf16, offset, "offset {offset}");
            assert_eq!(round.byte, position.byte, "offset {offset}");
        }
    }
}
