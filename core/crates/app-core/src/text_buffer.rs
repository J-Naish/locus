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
//! referenced by pieces. Edits never touch the original; they trim pieces and
//! append inserted text to the add buffer.
//!
//! The pieces live in a balanced binary tree (a treap) whose nodes cache
//! subtree aggregates (`bytes`, `chars`, `utf16`, `line_breaks`). That makes
//! every offset/line conversion and every edit `O(log n)` in the number of
//! pieces, instead of walking the whole content. The original is split into
//! bounded chunks at construction so a within-piece scan is bounded too.
//!
//! The buffer never copies content to support undo: each [`EditRecord`] holds
//! piece *references* (into the immutable original / append-only add buffer),
//! so undoing even a multi-megabyte delete only re-links pieces.

use std::error;
use std::fmt;

/// Maximum bytes per original-buffer piece. Splitting the immutable original
/// into bounded chunks keeps every within-piece scan bounded; the tree then
/// makes navigation across chunks `O(log n)`. 64 KiB matches the order of
/// magnitude VS Code uses for its buffer chunks.
const ORIGINAL_CHUNK_BYTES: usize = 64 * 1024;

/// Seed for the deterministic treap priority generator. A fixed, non-zero seed
/// keeps tree shapes reproducible across runs (so tests are deterministic)
/// while still giving the balance properties of randomized priorities.
const PRIORITY_SEED: u64 = 0x9E37_79B9_7F4A_7C15;

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

/// A contiguous slice of one of the two byte stores, with its own cached
/// counts. Counts are computed once when the piece is created (a bounded scan)
/// and then summed through the tree, so neither edits nor queries rescan the
/// whole content.
#[derive(Debug, Clone, Copy)]
struct Piece {
    source: PieceSource,
    start: usize,
    len: usize,
    chars: usize,
    utf16: usize,
    line_breaks: usize,
}

/// Node identity in the arena (`TextBuffer::nodes`). Freed slots are recycled
/// through `TextBuffer::free`, so the arena stays bounded by the live node
/// count rather than the total number of edits.
type NodeId = usize;

/// A treap node owning one [`Piece`] plus the aggregates of its whole subtree
/// (including this node). The aggregates let navigation descend in `O(log n)`.
#[derive(Debug, Clone, Copy)]
struct Node {
    piece: Piece,
    left: Option<NodeId>,
    right: Option<NodeId>,
    priority: u64,
    sub_bytes: usize,
    sub_chars: usize,
    sub_utf16: usize,
    sub_line_breaks: usize,
}

/// One reversible edit, modeled uniformly as "at `at_byte`, the pieces
/// `removed` were replaced by the pieces `inserted`". A pure insert has an
/// empty `removed`; a pure delete has an empty `inserted`. Both sides hold
/// piece *references* — never copied content — so reverting a large delete is
/// as cheap as a small one. `seq` identifies the edit across undo/redo so the
/// dirty flag can tell when the buffer returns to its saved state.
#[derive(Debug, Clone)]
struct EditRecord {
    seq: u64,
    at_byte: usize,
    removed: Vec<Piece>,
    inserted: Vec<Piece>,
}

impl EditRecord {
    fn removed_len(&self) -> usize {
        self.removed.iter().map(|piece| piece.len).sum()
    }

    fn inserted_len(&self) -> usize {
        self.inserted.iter().map(|piece| piece.len).sum()
    }
}

/// Where a UTF-16 offset lands: the `piece` containing it, the byte/char/
/// line-break prefixes of everything before that piece, and the offset within
/// the piece (`utf16_in`).
#[derive(Debug, Clone, Copy)]
struct Utf16Descent {
    piece: Piece,
    prefix_byte: usize,
    prefix_char: usize,
    prefix_breaks: usize,
    utf16_in: usize,
}

/// A line-indexed, editable UTF-8 text buffer backed by a balanced piece tree.
pub struct TextBuffer {
    original: Box<dyn ContentBytes>,
    add: Vec<u8>,
    nodes: Vec<Node>,
    free: Vec<NodeId>,
    root: Option<NodeId>,
    priority_state: u64,
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
        Self::from_source_with_chunk(source, ORIGINAL_CHUNK_BYTES)
    }

    fn from_source_with_chunk(
        source: Box<dyn ContentBytes>,
        chunk: usize,
    ) -> Result<Self, TextBufferError> {
        let bytes = source.as_bytes();
        if std::str::from_utf8(bytes).is_err() {
            return Err(TextBufferError::NotUtf8);
        }

        // A zero chunk would make `next_chunk_end` stall; keep progress guaranteed.
        let chunk = chunk.max(1);

        // Split the original into bounded, char-aligned chunks so within-piece
        // scans stay bounded. This borrow of `source` ends before it is moved.
        let mut pieces = Vec::new();
        let len = bytes.len();
        let mut start = 0;
        while start < len {
            let end = next_chunk_end(bytes, start, chunk);
            let (chars, utf16, line_breaks) = count_text(&bytes[start..end]);
            pieces.push(Piece {
                source: PieceSource::Original,
                start,
                len: end - start,
                chars,
                utf16,
                line_breaks,
            });
            start = end;
        }

        let mut buffer = Self {
            original: source,
            add: Vec::new(),
            nodes: Vec::new(),
            free: Vec::new(),
            root: None,
            priority_state: PRIORITY_SEED,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            seq_counter: 0,
            saved_seq: None,
            revision: 0,
        };

        let mut root = None;
        for piece in pieces {
            let node = buffer.alloc_node(piece);
            root = buffer.merge(root, Some(node));
        }
        buffer.root = root;
        Ok(buffer)
    }

    // MARK: - Read queries

    /// Total bytes of UTF-8 content.
    pub fn byte_len(&self) -> usize {
        self.sub_bytes(self.root)
    }

    /// Total UTF-16 code units (the unit AppKit/`NSRange` speak in).
    pub fn utf16_len(&self) -> usize {
        self.sub_utf16(self.root)
    }

    /// Number of logical lines. A trailing newline counts a final empty line.
    pub fn line_count(&self) -> usize {
        self.sub_line_breaks(self.root) + 1
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
        // Two line lookups bound the byte range; one forward read assembles it.
        // (A per-line loop would re-descend the tree for every line — fine for a
        // small viewport but needlessly quadratic over the chunk scans.)
        let start_byte = self.line_start_prefix(start_line).byte;
        let end_byte = if end_line < total {
            self.line_start_prefix(end_line).byte
        } else {
            self.byte_len()
        };
        self.format_band(
            start_byte,
            end_byte,
            end_line - start_line,
            end_line < total,
            None,
        )
    }

    /// Like [`text_for_line_range`](Self::text_for_line_range), but never returns
    /// more than `max_bytes_per_line` bytes of any single line's content. This
    /// keeps a file that is one enormous line (e.g. minified JSON) from
    /// materializing that whole line: a viewer only needs the visible prefix.
    pub fn text_for_line_range_capped(
        &self,
        start_line: usize,
        count: usize,
        max_bytes_per_line: usize,
    ) -> String {
        let total = self.line_count();
        if start_line >= total || count == 0 {
            return String::new();
        }
        let end_line = start_line.saturating_add(count).min(total);
        let line_count = end_line - start_line;
        let start_byte = self.line_start_prefix(start_line).byte;
        let end_byte = if end_line < total {
            self.line_start_prefix(end_line).byte
        } else {
            self.byte_len()
        };

        // Fast path: when the whole band fits in roughly the cap budget, read it
        // in one shot and cap each line in the assembled string (no per-line tree
        // descents). The single read is bounded to `~line_count * cap`, and the
        // per-line cap is still enforced — the budget check alone would not, since
        // it bounds the total, not any one line.
        let budget = line_count
            .saturating_mul(max_bytes_per_line.saturating_add(2))
            .saturating_add(2);
        if end_byte - start_byte <= budget {
            return self.format_band(
                start_byte,
                end_byte,
                line_count,
                end_line < total,
                Some(max_bytes_per_line),
            );
        }

        // Slow path: at least one line is very long. Read each line's content
        // capped on a char boundary, so the giant line never fully materializes.
        // Per-line descents are bounded by chunk size even across a huge line.
        let mut out = String::new();
        for line in start_line..end_line {
            if line > start_line {
                out.push('\n');
            }
            let (start, end) = self.line_bounds(line);
            let content_end = self.strip_terminator(start, end);
            let capped = self.char_boundary_at_or_before(
                content_end.min(start.saturating_add(max_bytes_per_line)),
            );
            out.push_str(&self.read_logical(start, capped));
        }
        out
    }

    /// Formats the byte range of a band (already located) into the public line
    /// shape: `line_count` lines joined by `\n`, each terminator stripped. When
    /// `cap` is `Some`, each line's content is also truncated to that many bytes
    /// on a char boundary.
    fn format_band(
        &self,
        start_byte: usize,
        end_byte: usize,
        line_count: usize,
        strip_final: bool,
        cap: Option<usize>,
    ) -> String {
        let raw = self.read_logical(start_byte, end_byte);
        // The range holds exactly `line_count` lines, each followed by its
        // terminator — except the buffer's final line, which has none. Splitting
        // on '\n' yields those lines; a '\r' immediately before a '\n' is part of
        // the terminator and is stripped, while a trailing '\r' on the buffer's
        // last line (no following '\n') is genuine content and is kept.
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

    // MARK: - Edits

    /// Inserts `text` at UTF-16 offset `at_utf16`. Consecutive single-run
    /// inserts at the advancing caret coalesce into one undo step.
    pub fn insert(&mut self, at_utf16: usize, text: &str) -> Result<(), TextBufferError> {
        if text.is_empty() {
            return Ok(());
        }
        let at_byte = self.utf16_to_byte(at_utf16)?;
        let inserted = self.apply_replace(at_byte, 0, text);
        self.redo_stack.clear();

        // Extend the previous typed run, but never coalesce into the saved
        // baseline record: doing so would hide the new edit from dirty tracking.
        let saved_seq = self.saved_seq;
        if let Some(top) = self.undo_stack.last_mut() {
            if top.removed.is_empty()
                && top.at_byte + top.inserted_len() == at_byte
                && Some(top.seq) != saved_seq
            {
                coalesce_inserted(&mut top.inserted, &inserted);
                return Ok(());
            }
        }

        let seq = self.next_seq();
        self.undo_stack.push(EditRecord {
            seq,
            at_byte,
            removed: Vec::new(),
            inserted,
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

        // `replace_range` returns the pieces it removed — references into the
        // existing stores, so even a huge delete copies only piece descriptors.
        let removed = self.replace_range(start_byte, end_byte - start_byte, &[]);
        self.redo_stack.clear();

        let seq = self.next_seq();
        self.undo_stack.push(EditRecord {
            seq,
            at_byte: start_byte,
            removed,
            inserted: Vec::new(),
        });
        Ok(())
    }

    /// Replaces the UTF-16 range `[start_utf16, end_utf16)` with `text` in a
    /// single splice recorded as one undo step (the record holds both the removed
    /// and inserted pieces), so undoing a typed-over selection restores it in one
    /// step rather than two. Unlike `insert`, a replace never coalesces with a
    /// previous edit.
    pub fn replace(
        &mut self,
        start_utf16: usize,
        end_utf16: usize,
        text: &str,
    ) -> Result<(), TextBufferError> {
        if end_utf16 < start_utf16 {
            return Err(TextBufferError::InvalidRange {
                start: start_utf16,
                end: end_utf16,
            });
        }
        let start_byte = self.utf16_to_byte(start_utf16)?;
        let end_byte = self.utf16_to_byte(end_utf16)?;
        if start_byte == end_byte && text.is_empty() {
            return Ok(());
        }

        let inserted = self.build_inserted(text);
        // One splice: drop the old range and put the new pieces in its place,
        // capturing the removed pieces for a single undo record.
        let removed = self.replace_range(start_byte, end_byte - start_byte, &inserted);
        self.redo_stack.clear();

        let seq = self.next_seq();
        self.undo_stack.push(EditRecord {
            seq,
            at_byte: start_byte,
            removed,
            inserted,
        });
        Ok(())
    }

    /// Reverts the most recent edit. Returns `false` if there is nothing to undo.
    pub fn undo(&mut self) -> bool {
        let Some(record) = self.undo_stack.pop() else {
            return false;
        };
        // The inserted pieces currently occupy `[at_byte, at_byte + inserted)`;
        // put the removed pieces back in their place.
        self.replace_range(record.at_byte, record.inserted_len(), &record.removed);
        self.redo_stack.push(record);
        true
    }

    /// Re-applies the most recently undone edit. Returns `false` if there is
    /// nothing to redo.
    pub fn redo(&mut self) -> bool {
        let Some(record) = self.redo_stack.pop() else {
            return false;
        };
        self.replace_range(record.at_byte, record.removed_len(), &record.inserted);
        self.undo_stack.push(record);
        true
    }

    // MARK: - Edit internals

    /// Appends `text` to the add buffer and returns the piece(s) representing it
    /// (an empty vec for empty text). Does not splice it into the tree.
    fn build_inserted(&mut self, text: &str) -> Vec<Piece> {
        if text.is_empty() {
            return Vec::new();
        }
        let start = self.add.len();
        self.add.extend_from_slice(text.as_bytes());
        let (chars, utf16, line_breaks) = count_text(text.as_bytes());
        vec![Piece {
            source: PieceSource::Add,
            start,
            len: text.len(),
            chars,
            utf16,
            line_breaks,
        }]
    }

    /// Appends `insert` to the add buffer and splices it in at `at_byte`,
    /// returning the inserted pieces for the undo record. Used by `insert`,
    /// which never removes (`remove_len` is always 0 here); `delete` and
    /// `replace` call [`replace_range`](Self::replace_range) directly to capture
    /// removed pieces.
    fn apply_replace(&mut self, at_byte: usize, remove_len: usize, insert: &str) -> Vec<Piece> {
        let inserted = self.build_inserted(insert);
        self.replace_range(at_byte, remove_len, &inserted);
        inserted
    }

    /// Splits out `[at_byte, at_byte + remove_len)`, returns the pieces that
    /// occupied it (in order, by reference — no content copy), and splices
    /// `pieces` into the gap. Every mutation path funnels through here so the
    /// revision counter advances exactly once per edit.
    fn replace_range(&mut self, at_byte: usize, remove_len: usize, pieces: &[Piece]) -> Vec<Piece> {
        let (left, rest) = self.split(self.root, at_byte);
        let (mid, right) = self.split(rest, remove_len);

        let mut removed = Vec::new();
        self.collect_pieces(mid, &mut removed);
        self.free_subtree(mid);

        let mut built = None;
        for &piece in pieces {
            if piece.len == 0 {
                continue;
            }
            let node = self.alloc_node(piece);
            built = self.merge(built, Some(node));
        }

        let left = self.merge(left, built);
        self.root = self.merge(left, right);
        self.revision += 1;
        removed
    }

    fn current_top_seq(&self) -> Option<u64> {
        self.undo_stack.last().map(|record| record.seq)
    }

    fn next_seq(&mut self) -> u64 {
        self.seq_counter += 1;
        self.seq_counter
    }

    fn next_priority(&mut self) -> u64 {
        // xorshift64 — deterministic given the fixed seed.
        let mut state = self.priority_state;
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        self.priority_state = state;
        state
    }

    // MARK: - Arena / tree primitives

    fn alloc_node(&mut self, piece: Piece) -> NodeId {
        let priority = self.next_priority();
        let node = Node {
            piece,
            left: None,
            right: None,
            priority,
            sub_bytes: piece.len,
            sub_chars: piece.chars,
            sub_utf16: piece.utf16,
            sub_line_breaks: piece.line_breaks,
        };
        if let Some(id) = self.free.pop() {
            self.nodes[id] = node;
            id
        } else {
            self.nodes.push(node);
            self.nodes.len() - 1
        }
    }

    fn free_subtree(&mut self, id: Option<NodeId>) {
        let Some(start) = id else {
            return;
        };
        let mut stack = vec![start];
        while let Some(id) = stack.pop() {
            if let Some(left) = self.nodes[id].left {
                stack.push(left);
            }
            if let Some(right) = self.nodes[id].right {
                stack.push(right);
            }
            self.free.push(id);
        }
    }

    fn sub_bytes(&self, id: Option<NodeId>) -> usize {
        id.map_or(0, |id| self.nodes[id].sub_bytes)
    }

    fn sub_chars(&self, id: Option<NodeId>) -> usize {
        id.map_or(0, |id| self.nodes[id].sub_chars)
    }

    fn sub_utf16(&self, id: Option<NodeId>) -> usize {
        id.map_or(0, |id| self.nodes[id].sub_utf16)
    }

    fn sub_line_breaks(&self, id: Option<NodeId>) -> usize {
        id.map_or(0, |id| self.nodes[id].sub_line_breaks)
    }

    fn update(&mut self, id: NodeId) {
        let node = self.nodes[id];
        let bytes = self.sub_bytes(node.left) + node.piece.len + self.sub_bytes(node.right);
        let chars = self.sub_chars(node.left) + node.piece.chars + self.sub_chars(node.right);
        let utf16 = self.sub_utf16(node.left) + node.piece.utf16 + self.sub_utf16(node.right);
        let line_breaks = self.sub_line_breaks(node.left)
            + node.piece.line_breaks
            + self.sub_line_breaks(node.right);
        let node = &mut self.nodes[id];
        node.sub_bytes = bytes;
        node.sub_chars = chars;
        node.sub_utf16 = utf16;
        node.sub_line_breaks = line_breaks;
    }

    /// Merges two order-adjacent subtrees (all of `left` precedes all of
    /// `right`) into one treap. Recursion depth is the tree height (`O(log n)`).
    fn merge(&mut self, left: Option<NodeId>, right: Option<NodeId>) -> Option<NodeId> {
        match (left, right) {
            (None, other) | (other, None) => other,
            (Some(left), Some(right)) => {
                if self.nodes[left].priority >= self.nodes[right].priority {
                    let left_right = self.nodes[left].right;
                    let merged = self.merge(left_right, Some(right));
                    self.nodes[left].right = merged;
                    self.update(left);
                    Some(left)
                } else {
                    let right_left = self.nodes[right].left;
                    let merged = self.merge(Some(left), right_left);
                    self.nodes[right].left = merged;
                    self.update(right);
                    Some(right)
                }
            }
        }
    }

    /// Splits a subtree at byte offset `at` into `(< at, >= at)`. A piece that
    /// straddles `at` is split in two (at a char boundary — every edit offset is
    /// char-validated, so `at` always lands on one).
    fn split(&mut self, id: Option<NodeId>, at: usize) -> (Option<NodeId>, Option<NodeId>) {
        let Some(id) = id else {
            return (None, None);
        };
        let left = self.nodes[id].left;
        let left_bytes = self.sub_bytes(left);
        let piece_len = self.nodes[id].piece.len;

        if at <= left_bytes {
            let (ll, lr) = self.split(left, at);
            self.nodes[id].left = lr;
            self.update(id);
            (ll, Some(id))
        } else if at >= left_bytes + piece_len {
            let right = self.nodes[id].right;
            let (rl, rr) = self.split(right, at - left_bytes - piece_len);
            self.nodes[id].right = rl;
            self.update(id);
            (Some(id), rr)
        } else {
            // `at` falls inside this node's piece: split the piece, recycle the
            // node, and rebuild the two sides.
            let within = at - left_bytes;
            let piece = self.nodes[id].piece;
            let left_child = self.nodes[id].left;
            let right_child = self.nodes[id].right;
            let (left_piece, right_piece) = self.split_piece(piece, within);
            self.free.push(id);
            let left_node = self.alloc_node(left_piece);
            let right_node = self.alloc_node(right_piece);
            let left_tree = self.merge(left_child, Some(left_node));
            let right_tree = self.merge(Some(right_node), right_child);
            (left_tree, right_tree)
        }
    }

    /// Splits a piece at byte offset `within` (a char boundary), recomputing the
    /// two halves' counts from the smaller side.
    fn split_piece(&self, piece: Piece, within: usize) -> (Piece, Piece) {
        let bytes = self.piece_bytes(piece.source, piece.start, piece.len);
        let (chars, utf16, line_breaks) = count_text(&bytes[..within]);
        let left = Piece {
            source: piece.source,
            start: piece.start,
            len: within,
            chars,
            utf16,
            line_breaks,
        };
        let right = Piece {
            source: piece.source,
            start: piece.start + within,
            len: piece.len - within,
            chars: piece.chars - chars,
            utf16: piece.utf16 - utf16,
            line_breaks: piece.line_breaks - line_breaks,
        };
        (left, right)
    }

    fn collect_pieces(&self, id: Option<NodeId>, out: &mut Vec<Piece>) {
        let Some(id) = id else {
            return;
        };
        self.collect_pieces(self.nodes[id].left, out);
        out.push(self.nodes[id].piece);
        self.collect_pieces(self.nodes[id].right, out);
    }

    fn piece_bytes(&self, source: PieceSource, start: usize, len: usize) -> &[u8] {
        let buffer = match source {
            PieceSource::Original => self.original.as_bytes(),
            PieceSource::Add => &self.add,
        };
        &buffer[start..start + len]
    }

    /// Writes the full document content to `writer` in document order, walking the
    /// tree in place and writing each piece's bytes as it is visited. No
    /// full-document buffer and no piece list are materialized, so save memory is
    /// O(tree height) regardless of document or edit-history size.
    pub fn write_to(&self, writer: &mut dyn std::io::Write) -> std::io::Result<()> {
        self.write_subtree(self.root, writer)
    }

    fn write_subtree(
        &self,
        id: Option<NodeId>,
        writer: &mut dyn std::io::Write,
    ) -> std::io::Result<()> {
        let Some(id) = id else {
            return Ok(());
        };
        self.write_subtree(self.nodes[id].left, writer)?;
        let piece = self.nodes[id].piece;
        writer.write_all(self.piece_bytes(piece.source, piece.start, piece.len))?;
        self.write_subtree(self.nodes[id].right, writer)
    }

    // MARK: - Navigation

    /// Logical byte range of a line including its trailing terminator.
    fn line_bounds(&self, line: usize) -> (usize, usize) {
        let start = self.line_start_prefix(line).byte;
        let end = if line + 1 < self.line_count() {
            self.line_start_prefix(line + 1).byte
        } else {
            self.byte_len()
        };
        (start, end)
    }

    /// The byte at logical offset `at`, if it is in range.
    fn logical_byte(&self, at: usize) -> Option<u8> {
        let (piece, within) = self.descend_byte(at)?;
        Some(self.piece_bytes(piece.source, piece.start, piece.len)[within])
    }

    /// End of a line's *content* — the terminating `\n` and a preceding `\r` are
    /// excluded — so a caret can never be placed inside a CRLF terminator.
    fn line_content_end(&self, line: usize) -> usize {
        let (start, end) = self.line_bounds(line);
        self.strip_terminator(start, end)
    }

    /// Given a line's byte bounds, returns the end of its content with a
    /// trailing `\n` and a preceding `\r` excluded.
    fn strip_terminator(&self, start: usize, end: usize) -> usize {
        let mut content_end = end;
        if content_end > start && self.logical_byte(content_end - 1) == Some(b'\n') {
            content_end -= 1;
            if content_end > start && self.logical_byte(content_end - 1) == Some(b'\r') {
                content_end -= 1;
            }
        }
        content_end
    }

    /// The largest byte offset `<= at` that lies on a UTF-8 char boundary, so a
    /// capped read never splits a multi-byte character.
    fn char_boundary_at_or_before(&self, at: usize) -> usize {
        let mut at = at.min(self.byte_len());
        // A continuation byte (`0b10xxxxxx`) is mid-character; back off past it.
        while at > 0
            && self
                .logical_byte(at)
                .is_some_and(|byte| byte & 0xC0 == 0x80)
        {
            at -= 1;
        }
        at
    }

    /// Assembles the UTF-8 text for a logical byte range, visiting only the
    /// overlapping pieces (`O(log n + range)`). The endpoints are always on
    /// character boundaries, so slicing each piece is safe.
    fn read_logical(&self, start: usize, end: usize) -> String {
        let mut out = String::with_capacity(end.saturating_sub(start));
        self.collect_text(self.root, 0, start, end, &mut out);
        out
    }

    fn collect_text(
        &self,
        id: Option<NodeId>,
        base: usize,
        start: usize,
        end: usize,
        out: &mut String,
    ) {
        let Some(id) = id else {
            return;
        };
        let node = self.nodes[id];
        let piece_start = base + self.sub_bytes(node.left);
        let piece_end = piece_start + node.piece.len;

        if start < piece_start {
            self.collect_text(node.left, base, start, end, out);
        }
        if start < piece_end && end > piece_start {
            let from = start.max(piece_start) - piece_start;
            let to = end.min(piece_end) - piece_start;
            let bytes = self.piece_bytes(node.piece.source, node.piece.start, node.piece.len);
            out.push_str(
                std::str::from_utf8(&bytes[from..to])
                    .expect("piece content is validated UTF-8 on char boundaries"),
            );
        }
        if end > piece_end {
            self.collect_text(node.right, piece_end, start, end, out);
        }
    }

    /// Descends to the piece containing byte `at`, returning it and the offset
    /// within it. Returns `None` for `at >= byte_len`.
    fn descend_byte(&self, at: usize) -> Option<(Piece, usize)> {
        let mut id = self.root;
        let mut acc = 0;
        while let Some(node_id) = id {
            let node = self.nodes[node_id];
            let left_bytes = self.sub_bytes(node.left);
            if at < acc + left_bytes {
                id = node.left;
                continue;
            }
            let piece_start = acc + left_bytes;
            let piece_end = piece_start + node.piece.len;
            if at < piece_end {
                return Some((node.piece, at - piece_start));
            }
            acc = piece_end;
            id = node.right;
        }
        None
    }

    /// Prefix aggregates (byte/char/utf16) at the first byte of `line`. Line 0
    /// is the origin; line `L > 0` begins just after the `L`-th `\n`.
    fn line_start_prefix(&self, line: usize) -> Position {
        let mut prefix = Position::default();
        if line == 0 {
            return prefix;
        }
        let mut id = self.root;
        let mut breaks_before = 0;
        while let Some(node_id) = id {
            let node = self.nodes[node_id];
            let left_breaks = self.sub_line_breaks(node.left);
            if line <= breaks_before + left_breaks {
                id = node.left;
                continue;
            }
            // The target newline is at or after this node's piece. Fold the
            // whole left subtree into the prefix.
            let left_bytes = self.sub_bytes(node.left);
            let left_chars = self.sub_chars(node.left);
            let left_utf16 = self.sub_utf16(node.left);
            let breaks_before_piece = breaks_before + left_breaks;
            if line <= breaks_before_piece + node.piece.line_breaks {
                // The (line - breaks_before_piece)-th newline lands in this piece.
                let nth = line - breaks_before_piece;
                let (byte, chars, utf16) = self.scan_after_nth_newline(node.piece, nth);
                return Position {
                    byte: prefix.byte + left_bytes + byte,
                    char: prefix.char + left_chars + chars,
                    utf16: prefix.utf16 + left_utf16 + utf16,
                    line,
                    column_utf16: 0,
                };
            }
            prefix.byte += left_bytes + node.piece.len;
            prefix.char += left_chars + node.piece.chars;
            prefix.utf16 += left_utf16 + node.piece.utf16;
            breaks_before = breaks_before_piece + node.piece.line_breaks;
            id = node.right;
        }
        // Fewer newlines than requested: clamp to the end of the content.
        Position {
            byte: self.byte_len(),
            char: self.sub_chars(self.root),
            utf16: self.utf16_len(),
            line,
            column_utf16: 0,
        }
    }

    /// Scans a piece for the `nth` (1-based) `\n`, returning the byte/char/utf16
    /// counts up to and including it (i.e. the start of the following line).
    fn scan_after_nth_newline(&self, piece: Piece, nth: usize) -> (usize, usize, usize) {
        let bytes = self.piece_bytes(piece.source, piece.start, piece.len);
        let text = std::str::from_utf8(bytes).expect("piece content is validated UTF-8");
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

    /// Maps a UTF-16 offset to a full [`Position`]. The end-of-buffer offset is
    /// valid; an offset inside a surrogate pair or past the end is rejected.
    pub fn position_for_utf16(&self, target_utf16: usize) -> Result<Position, TextBufferError> {
        let total = self.utf16_len();
        if target_utf16 > total {
            return Err(TextBufferError::InvalidUtf16Offset {
                offset: target_utf16,
                limit: total,
            });
        }
        if target_utf16 == total {
            let line = self.sub_line_breaks(self.root);
            let line_start = self.line_start_prefix(line);
            return Ok(Position {
                byte: self.byte_len(),
                char: self.sub_chars(self.root),
                utf16: total,
                line,
                column_utf16: total - line_start.utf16,
            });
        }

        let Some(Utf16Descent {
            piece,
            prefix_byte,
            prefix_char,
            prefix_breaks,
            utf16_in,
        }) = self.descend_utf16(target_utf16)
        else {
            return Err(TextBufferError::InvalidUtf16Offset {
                offset: target_utf16,
                limit: total,
            });
        };

        let bytes = self.piece_bytes(piece.source, piece.start, piece.len);
        let text = std::str::from_utf8(bytes).expect("piece content is validated UTF-8");
        let mut byte = 0;
        let mut chars = 0;
        let mut utf16 = 0;
        let mut breaks_in = 0;
        for character in text.chars() {
            if utf16 == utf16_in {
                break;
            }
            let next = utf16 + character.len_utf16();
            if next > utf16_in {
                // The target fell between the two code units of a surrogate pair.
                return Err(TextBufferError::InvalidUtf16Offset {
                    offset: target_utf16,
                    limit: total,
                });
            }
            byte += character.len_utf8();
            chars += 1;
            utf16 = next;
            if character == '\n' {
                breaks_in += 1;
            }
        }

        let line = prefix_breaks + breaks_in;
        let line_start = self.line_start_prefix(line);
        Ok(Position {
            byte: prefix_byte + byte,
            char: prefix_char + chars,
            utf16: target_utf16,
            line,
            column_utf16: target_utf16 - line_start.utf16,
        })
    }

    /// Descends to the piece whose UTF-16 span contains `target` (which the
    /// caller guarantees is `< utf16_len`).
    fn descend_utf16(&self, target: usize) -> Option<Utf16Descent> {
        let mut id = self.root;
        let mut acc_byte = 0;
        let mut acc_char = 0;
        let mut acc_utf16 = 0;
        let mut acc_breaks = 0;
        while let Some(node_id) = id {
            let node = self.nodes[node_id];
            let left_utf16 = self.sub_utf16(node.left);
            if target < acc_utf16 + left_utf16 {
                id = node.left;
                continue;
            }
            let left_bytes = self.sub_bytes(node.left);
            let left_chars = self.sub_chars(node.left);
            let left_breaks = self.sub_line_breaks(node.left);
            let before_piece_utf16 = acc_utf16 + left_utf16;
            if target < before_piece_utf16 + node.piece.utf16 {
                return Some(Utf16Descent {
                    piece: node.piece,
                    prefix_byte: acc_byte + left_bytes,
                    prefix_char: acc_char + left_chars,
                    prefix_breaks: acc_breaks + left_breaks,
                    utf16_in: target - before_piece_utf16,
                });
            }
            acc_byte += left_bytes + node.piece.len;
            acc_char += left_chars + node.piece.chars;
            acc_utf16 = before_piece_utf16 + node.piece.utf16;
            acc_breaks += left_breaks + node.piece.line_breaks;
            id = node.right;
        }
        None
    }

    /// Maps a 0-based `line` and UTF-16 `column_utf16` (from the line start) to
    /// a full [`Position`]. A column past the line's content is clamped to the
    /// end of the line, so clicking past the last character places the caret
    /// there (and never inside a `\r\n`).
    pub fn position_for_line_column(
        &self,
        line: usize,
        column_utf16: usize,
    ) -> Result<Position, TextBufferError> {
        let total = self.line_count();
        if line >= total {
            return Err(TextBufferError::InvalidLine { line, total });
        }
        let line_start = self.line_start_prefix(line);
        let content_end_byte = self.line_content_end(line);
        // Take the UTF-16 count at the line's content end directly from the
        // tree. Materializing the line (`read_logical`) would allocate the whole
        // line, which is catastrophic for a giant single line (minified JSON, a
        // log line); this descent is bounded by one piece scan instead.
        let content_utf16 = self.utf16_before_byte(content_end_byte);
        // `column_utf16` is untrusted (it comes from AppKit `NSRange`): clamp it
        // before adding the line-start offset so a hostile column cannot overflow.
        let target = line_start
            .utf16
            .saturating_add(column_utf16)
            .min(content_utf16);
        self.position_for_utf16(target)
    }

    /// UTF-16 code units before byte offset `at` (which must lie on a char
    /// boundary). One `O(log n)` descent plus a scan bounded by a single piece —
    /// it never assembles the spanned text.
    fn utf16_before_byte(&self, at: usize) -> usize {
        if at >= self.byte_len() {
            return self.utf16_len();
        }
        let mut id = self.root;
        let mut acc_byte = 0;
        let mut acc_utf16 = 0;
        while let Some(node_id) = id {
            let node = self.nodes[node_id];
            let left_bytes = self.sub_bytes(node.left);
            if at < acc_byte + left_bytes {
                id = node.left;
                continue;
            }
            let before_piece_byte = acc_byte + left_bytes;
            let piece_end_byte = before_piece_byte + node.piece.len;
            let before_piece_utf16 = acc_utf16 + self.sub_utf16(node.left);
            if at < piece_end_byte {
                let within = at - before_piece_byte;
                let bytes = self.piece_bytes(node.piece.source, node.piece.start, node.piece.len);
                let text = std::str::from_utf8(&bytes[..within])
                    .expect("piece content is validated UTF-8");
                return before_piece_utf16 + utf16_len_of(text);
            }
            acc_byte = piece_end_byte;
            acc_utf16 = before_piece_utf16 + node.piece.utf16;
            id = node.right;
        }
        self.utf16_len()
    }

    /// Converts a UTF-16 offset to a logical byte offset.
    fn utf16_to_byte(&self, target_utf16: usize) -> Result<usize, TextBufferError> {
        Ok(self.position_for_utf16(target_utf16)?.byte)
    }
}

/// Counts (chars, utf16 code units, `\n` count) of a char-aligned UTF-8 slice.
fn count_text(bytes: &[u8]) -> (usize, usize, usize) {
    let text = std::str::from_utf8(bytes).expect("piece content is validated UTF-8");
    let mut chars = 0;
    let mut utf16 = 0;
    let mut line_breaks = 0;
    for character in text.chars() {
        chars += 1;
        utf16 += character.len_utf16();
        if character == '\n' {
            line_breaks += 1;
        }
    }
    (chars, utf16, line_breaks)
}

fn utf16_len_of(text: &str) -> usize {
    text.chars().map(char::len_utf16).sum()
}

/// Picks a chunk end `> start` on a UTF-8 char boundary, aiming for `chunk`
/// bytes. It backs off to the boundary at or before the target; if the target
/// splits a char wider than the whole chunk (only reachable with the tiny chunk
/// sizes used in tests), it extends forward instead so progress is guaranteed.
fn next_chunk_end(bytes: &[u8], start: usize, chunk: usize) -> usize {
    let len = bytes.len();
    let target = (start + chunk).min(len);
    if target >= len {
        return len;
    }
    let mut end = target;
    while end > start && !is_char_boundary(bytes[end]) {
        end -= 1;
    }
    if end > start {
        return end;
    }
    let mut end = target;
    while end < len && !is_char_boundary(bytes[end]) {
        end += 1;
    }
    end
}

/// Whether `byte` begins a UTF-8 code point (i.e. is not a continuation byte).
fn is_char_boundary(byte: u8) -> bool {
    byte & 0xC0 != 0x80
}

/// Extends a coalesced insert run's piece list with the just-inserted piece.
/// Consecutive caret inserts append contiguous bytes to the add buffer, so the
/// new piece extends the previous one in place; otherwise it is appended.
fn coalesce_inserted(run: &mut Vec<Piece>, inserted: &[Piece]) {
    for &piece in inserted {
        if let Some(last) = run.last_mut() {
            if last.source == piece.source && last.start + last.len == piece.start {
                last.len += piece.len;
                last.chars += piece.chars;
                last.utf16 += piece.utf16;
                last.line_breaks += piece.line_breaks;
                continue;
            }
        }
        run.push(piece);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer(text: &str) -> TextBuffer {
        TextBuffer::from_utf8_bytes(text.as_bytes().to_vec()).expect("valid utf-8")
    }

    fn chunked(text: &str, chunk: usize) -> TextBuffer {
        TextBuffer::from_source_with_chunk(
            Box::new(OwnedBytes::new(text.as_bytes().to_vec())),
            chunk,
        )
        .expect("valid utf-8")
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
    fn replace_swaps_a_range_in_one_undo_step() {
        let mut buffer = buffer("hello");
        buffer.replace(0, 5, "bye").expect("replace");
        assert_eq!(contents(&buffer), "bye");
        // A single undo restores the whole replaced range (not just the insert).
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "hello");
        assert!(buffer.redo());
        assert_eq!(contents(&buffer), "bye");
    }

    #[test]
    fn replace_in_the_middle_keeps_surrounding_text() {
        let mut buffer = buffer("abcdef");
        buffer.replace(2, 4, "XY").expect("replace");
        assert_eq!(contents(&buffer), "abXYef");
    }

    #[test]
    fn replace_with_empty_text_deletes_the_range() {
        let mut buffer = buffer("hello");
        buffer.replace(1, 3, "").expect("replace");
        assert_eq!(contents(&buffer), "hlo");
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "hello");
    }

    #[test]
    fn replace_rejects_a_reversed_range() {
        let mut buffer = buffer("hello");
        assert_eq!(
            buffer.replace(3, 1, "x").err(),
            Some(TextBufferError::InvalidRange { start: 3, end: 1 })
        );
    }

    #[test]
    fn write_to_streams_full_content_after_edits() {
        let mut buffer = buffer("hello world");
        buffer.replace(0, 5, "goodbye").expect("replace");
        buffer.insert(13, "!").expect("insert");
        let mut out = Vec::new();
        buffer.write_to(&mut out).expect("write");
        assert_eq!(String::from_utf8(out).unwrap(), "goodbye world!");
    }

    #[test]
    fn write_to_empty_buffer_writes_nothing() {
        let buffer = buffer("");
        let mut out = Vec::new();
        buffer.write_to(&mut out).expect("write");
        assert!(out.is_empty());
    }

    #[test]
    fn write_to_preserves_crlf_bytes() {
        // The buffer stores raw bytes, so a CRLF document round-trips exactly.
        let buffer = buffer("a\r\nb\r\n");
        let mut out = Vec::new();
        buffer.write_to(&mut out).expect("write");
        assert_eq!(out, b"a\r\nb\r\n");
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
    fn position_for_line_column_clamps_hostile_column_without_overflow() {
        // `column_utf16` is untrusted FFI input; a huge value on a non-zero line
        // must clamp to the line end, never overflow `usize`.
        let buffer = buffer("aa\nbb");
        let position = buffer
            .position_for_line_column(1, usize::MAX)
            .expect("clamped");
        assert_eq!(position.line, 1);
        assert_eq!(position.column_utf16, 2);
        assert_eq!(position.utf16, 5);
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

    // MARK: - Balanced tree / chunking (O(log n) representation)

    #[test]
    fn multi_chunk_original_reads_and_counts_correctly() {
        // A tiny chunk forces many pieces over a small input.
        let text = "alpha\nbeta\ngamma\ndelta\nepsilon";
        let buffer = chunked(text, 3);
        assert_eq!(buffer.line_count(), 5);
        assert_eq!(buffer.byte_len(), text.len());
        assert_eq!(contents(&buffer), text);
        assert_eq!(buffer.text_for_line_range(1, 2), "beta\ngamma");
        assert_eq!(buffer.text_for_line_range(4, 1), "epsilon");
    }

    // MARK: - Capped viewport reads

    #[test]
    fn capped_read_matches_uncapped_for_short_lines() {
        let buffer = buffer("alpha\nbeta\ngamma");
        assert_eq!(
            buffer.text_for_line_range_capped(0, 3, 1000),
            buffer.text_for_line_range(0, 3)
        );
    }

    #[test]
    fn capped_read_truncates_a_long_line_but_keeps_neighbors() {
        let long = "x".repeat(10_000);
        let buffer = buffer(&format!("a\n{long}\nb"));
        // The middle line is capped to 5 bytes; its neighbors stay intact.
        assert_eq!(buffer.text_for_line_range_capped(0, 3, 5), "a\nxxxxx\nb");
    }

    #[test]
    fn capped_read_on_a_single_huge_line_returns_only_the_prefix() {
        let buffer = buffer(&"y".repeat(100_000));
        assert_eq!(buffer.line_count(), 1);
        assert_eq!(buffer.text_for_line_range_capped(0, 1, 8), "yyyyyyyy");
    }

    #[test]
    fn capped_read_does_not_split_multibyte_chars() {
        // A long line of 3-byte chars forces the capped path; a 4-byte cap must
        // back off to 3 (one whole "あ") rather than split the next character.
        let buffer = buffer(&format!("{}\nb", "あ".repeat(1_000)));
        assert_eq!(buffer.text_for_line_range_capped(0, 1, 4), "あ");
    }

    #[test]
    fn capped_read_clamps_past_the_end() {
        let buffer = buffer("a\nb");
        assert_eq!(buffer.text_for_line_range_capped(5, 3, 100), "");
        assert_eq!(buffer.text_for_line_range_capped(0, 0, 100), "");
    }

    #[test]
    fn capped_read_caps_a_line_even_on_the_fast_path() {
        // A small band stays on the fast path, but an over-long line must still
        // be capped — the budget check bounds the total, not any single line.
        let buffer = buffer("1234567890\n\n");
        assert_eq!(buffer.text_for_line_range_capped(0, 3, 5), "12345\n\n");
    }

    #[test]
    fn crlf_split_across_chunk_boundary_is_still_one_terminator() {
        // chunk=4 places "\r" at the end of one piece and "\n" at the start of
        // the next for "abc\r\ndef".
        let buffer = chunked("abc\r\ndef", 4);
        assert_eq!(buffer.line_count(), 2);
        assert_eq!(buffer.text_for_line_range(0, 1), "abc");
        assert_eq!(buffer.text_for_line_range(0, 2), "abc\ndef");
        let position = buffer.position_for_line_column(0, 99).expect("clamped");
        assert_eq!(position.byte, 3);
    }

    #[test]
    fn multibyte_chars_are_never_split_across_chunks() {
        // "あ" is 3 bytes; with chunk=2 the boundary cannot fall mid-char.
        let text = "あいうえお\nかきくけこ";
        let buffer = chunked(text, 2);
        assert_eq!(buffer.line_count(), 2);
        assert_eq!(contents(&buffer), text);
        // Round-trip a position that sits across several chunks.
        let position = buffer.position_for_utf16(7).expect("position");
        assert_eq!(position.line, 1);
        assert_eq!(position.column_utf16, 1);
    }

    #[test]
    fn editing_across_chunk_boundaries_stays_consistent() {
        let mut buffer = chunked("0123456789", 3);
        buffer.insert(5, "ABC").expect("insert");
        assert_eq!(contents(&buffer), "01234ABC56789");
        // Remove utf16 [2, 9) = "234ABC5", spanning original and add pieces.
        buffer.delete(2, 9).expect("delete");
        assert_eq!(contents(&buffer), "016789");
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "01234ABC56789");
        assert!(buffer.undo());
        assert_eq!(contents(&buffer), "0123456789");
    }

    #[test]
    fn many_inserts_remain_correct_and_fully_undoable() {
        let mut buffer = buffer("");
        let mut expected = String::new();
        for index in 0..500 {
            // Insert at the front every few steps to break caret contiguity and
            // exercise tree rebalancing at varied offsets.
            let at = if index % 7 == 0 {
                0
            } else {
                buffer.utf16_len()
            };
            let token = format!("{}", index % 10);
            buffer.insert(at, &token).expect("insert");
            if at == 0 {
                expected.insert_str(0, &token);
            } else {
                expected.push_str(&token);
            }
        }
        assert_eq!(contents(&buffer), expected);
        assert_eq!(buffer.utf16_len(), expected.chars().count());
        // Unwind everything back to empty.
        while buffer.undo() {}
        assert_eq!(contents(&buffer), "");
    }

    #[test]
    fn large_delete_records_pieces_without_copying_content() {
        // The deleted text lives in the original buffer; undo must not re-append
        // it to the add buffer (the whole point of piece references).
        let text = "x".repeat(50_000);
        let mut buffer = chunked(&text, 64);
        let add_before = buffer.add.len();
        buffer.delete(10, 49_990).expect("delete");
        assert_eq!(buffer.add.len(), add_before, "delete must not grow add");
        assert_eq!(buffer.byte_len(), 20);
        assert!(buffer.undo());
        assert_eq!(buffer.add.len(), add_before, "undo must not grow add");
        assert_eq!(buffer.byte_len(), 50_000);
        assert!(buffer.redo());
        assert_eq!(buffer.byte_len(), 20);
    }

    #[test]
    fn freed_nodes_are_recycled_across_edits() {
        // Repeated insert/undo cycles must not grow the arena without bound.
        let mut buffer = buffer("seed");
        for _ in 0..200 {
            buffer.insert(0, "ABCDE").expect("insert");
            buffer.undo();
        }
        // A loose bound: a leak would push the arena into the thousands.
        assert!(
            buffer.nodes.len() < 64,
            "arena grew to {}",
            buffer.nodes.len()
        );
        assert_eq!(contents(&buffer), "seed");
    }

    #[test]
    fn line_column_on_a_long_single_line_maps_via_tree_not_materialization() {
        // One line, no '\n', spanning many original chunks, with an astral char
        // so UTF-16 counting matters. The query must not assemble the line.
        let head = "a".repeat(100_000);
        let tail = "b".repeat(100_000);
        let text = format!("{head}𝄞{tail}");
        let buffer = buffer(&text);
        assert_eq!(buffer.line_count(), 1);

        // Column at the astral char's UTF-16 start (after `head`).
        let at_astral = buffer
            .position_for_line_column(0, 100_000)
            .expect("position");
        assert_eq!(at_astral.byte, head.len());
        assert_eq!(at_astral.char, 100_000);

        // A column past the end clamps to the content end (total UTF-16), and the
        // astral char counts as two UTF-16 units.
        let total_utf16 = 100_000 + 2 + 100_000;
        let clamped = buffer
            .position_for_line_column(0, usize::MAX)
            .expect("clamped");
        assert_eq!(clamped.utf16, total_utf16);
        assert_eq!(clamped.byte, text.len());
    }

    #[test]
    fn zero_chunk_size_does_not_stall_and_builds_correctly() {
        // The chunk guard (`chunk.max(1)`) keeps `next_chunk_end` progressing.
        let buffer = chunked("ab\ncd\n", 0);
        assert_eq!(buffer.line_count(), 3);
        assert_eq!(contents(&buffer), "ab\ncd\n");
        assert_eq!(buffer.text_for_line_range(1, 1), "cd");
    }
}
