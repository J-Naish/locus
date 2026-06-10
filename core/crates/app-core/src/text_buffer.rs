//! Arbitrary-size editable text buffer engine, backed by a persistent rope.
//!
//! The buffer works exclusively in canonical UTF-8. Encoding detection and
//! transcoding for non-UTF-8 files stay on the platform side (Foundation),
//! which hands already-decoded UTF-8 bytes here; this keeps the core free of
//! external encoding dependencies; UTF-8 files (the common case) are read
//! straight into the buffer without transcoding.
//!
//! Content is stored as a [persistent rope](rope): a balanced tree of immutable
//! text leaves with cached aggregates (`bytes`, `chars`, `utf16`, `line_breaks`).
//! Every offset/line conversion is `O(log n)`; an edit is `O(log n)` plus the
//! length of the inserted text (which is split into leaves). An edit rebuilds
//! only the nodes on its path and shares every untouched subtree with the
//! previous version, so taking a *snapshot* of the current content is an `O(1)`,
//! structurally-shared clone of the root — the reason this engine is a rope
//! rather than the in-place arena it replaced.
//!
//! The platform loads a file's bytes into memory and hands them here; the rope's
//! original-document leaves then *view* into those shared, immutable bytes
//! ([`ContentBytes`]) rather than copying them, so building the tree adds no
//! content copy on top of that initial load. Inserted text lives in its own
//! immutable leaves. Coordinate conversions and viewport reads live in
//! [`coords`]; [`rope`] owns the tree shape.
//!
//! Undo/redo store the removed and inserted *sub-ropes* by reference (`Arc`),
//! never copying content, so reverting even a multi-megabyte delete only re-links
//! a handful of nodes.

use std::error;
use std::fmt;
use std::sync::Arc;

mod coords;
mod rope;

use rope::Node;

/// Borrowed access to the buffer's original content bytes.
///
/// Every buffer uses [`OwnedBytes`] (heap-owned) today. Keeping this a trait
/// decouples `TextBuffer` from how those bytes are stored and lets the core
/// stay free of `unsafe`.
///
/// Implementations must return the same bytes for the lifetime of the value:
/// the rope's leaves view into them. `Send + Sync` lets a buffer be built off
/// the main thread and handed to the editor's actor.
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

/// One reversible edit, modeled uniformly as "at `at_byte`, the sub-rope
/// `removed` was replaced by the sub-rope `inserted`". A pure insert has an empty
/// `removed`; a pure delete has an empty `inserted`. Both sides are `Arc`-shared
/// rope nodes — never copied content — so reverting a large delete is as cheap as
/// a small one. `seq` identifies the edit across undo/redo so the dirty flag can
/// tell when the buffer returns to its saved state.
#[derive(Clone)]
struct EditRecord {
    seq: u64,
    at_byte: usize,
    removed: Node,
    inserted: Node,
}

/// The document span one undo or redo step rewrote, in the coordinates of the
/// document that step produced. The content before `start_utf16` is identical
/// on both sides of the step; at that offset the step replaced `old_len_utf16`
/// UTF-16 units with `new_len_utf16` units. Lets the platform update per-line
/// caches (such as a soft-wrap index) for just the rewritten lines instead of
/// rescanning the document.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EditSpan {
    pub start_utf16: usize,
    pub old_len_utf16: usize,
    pub new_len_utf16: usize,
}

/// A line-indexed, editable UTF-8 text buffer backed by a persistent rope.
pub struct TextBuffer {
    /// Never absent: an empty buffer is a single empty leaf.
    root: Node,
    undo_stack: Vec<EditRecord>,
    redo_stack: Vec<EditRecord>,
    seq_counter: u64,
    /// `seq` of the top undo record when the buffer was last saved (or `None`
    /// if saved while empty). The buffer is dirty when the current top differs.
    saved_seq: Option<u64>,
    revision: u64,
    /// Set by [`snapshot_for_save`](Self::snapshot_for_save) so the next insert
    /// starts a fresh undo record instead of coalescing into the snapshotted run.
    /// This keeps the snapshot's captured `seq` a faithful identifier of its
    /// content even if the user keeps typing during the background write.
    seal_coalescing: bool,
}

// A background save reads the buffer (`write_to`, `&self`) on another thread
// while the main thread keeps rendering (also `&self` reads). That is sound only
// because `TextBuffer` is `Sync`; this assertion fails the build if a future
// field breaks that. The rope's nodes are immutable `Arc`s, so reads never
// mutate; mutations stay exclusive (`&mut self`).
const _: fn() = || {
    fn assert_send_sync<T: Send + Sync>() {}
    assert_send_sync::<TextBuffer>();
    // A snapshot may be handed to another thread (e.g. a background diff), so it
    // must be `Send + Sync` too — the immutable rope makes this free.
    assert_send_sync::<TextSnapshot>();
};

impl TextBuffer {
    /// Builds a buffer from owned UTF-8 bytes.
    pub fn from_utf8_bytes(bytes: impl Into<Box<[u8]>>) -> Result<Self, TextBufferError> {
        Self::from_source(Box::new(OwnedBytes::new(bytes)))
    }

    /// Builds a buffer from any content source. The bytes must be valid UTF-8.
    pub fn from_source(source: Box<dyn ContentBytes>) -> Result<Self, TextBufferError> {
        Self::from_source_with_cap(source, rope::LEAF_TARGET_BYTES)
    }

    /// Builds a buffer, splitting the original into leaves of at most `cap` bytes.
    /// A tiny `cap` forces many leaves, which tests use to exercise the cross-leaf
    /// paths cheaply (the rope analogue of the old per-piece chunking).
    fn from_source_with_cap(
        source: Box<dyn ContentBytes>,
        cap: usize,
    ) -> Result<Self, TextBufferError> {
        if std::str::from_utf8(source.as_bytes()).is_err() {
            return Err(TextBufferError::NotUtf8);
        }
        // Move the bytes into a shared, immutable backing — no content copy: only
        // the `Box`'s pointer is relocated into the `Arc` allocation.
        let backing: Arc<dyn ContentBytes> = Arc::from(source);
        let root = Node::from_backing(backing, cap);
        Ok(Self {
            root,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
            seq_counter: 0,
            saved_seq: None,
            revision: 0,
            seal_coalescing: false,
        })
    }

    // MARK: - Read queries

    /// Total bytes of UTF-8 content.
    pub fn byte_len(&self) -> usize {
        self.root.summary().bytes
    }

    /// Total UTF-16 code units (the unit AppKit/`NSRange` speak in).
    pub fn utf16_len(&self) -> usize {
        self.root.summary().utf16
    }

    /// Number of logical lines. A trailing newline counts a final empty line.
    pub fn line_count(&self) -> usize {
        self.root.summary().line_breaks + 1
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
        coords::text_for_line_range(&self.root, start_line, count)
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
        coords::text_for_line_range_capped(&self.root, start_line, count, max_bytes_per_line)
    }

    /// Returns the raw text of the UTF-16 range `[start_utf16, end_utf16)` without
    /// any line-terminator stripping. Used to read just the visible window of a
    /// single enormous line (intra-line virtualization): both endpoints map to
    /// byte offsets in `O(log n)`, so a window deep inside a multi-megabyte line
    /// is read without materializing the line before it.
    ///
    /// This is a viewport read, so it never errors: offsets past the end are
    /// clamped, an endpoint inside a surrogate pair is floored to the character's
    /// start (returning whole characters), and an inverted range yields empty.
    pub fn text_for_utf16_range(&self, start_utf16: usize, end_utf16: usize) -> String {
        coords::text_for_utf16_range(&self.root, start_utf16, end_utf16)
    }

    /// Maps a UTF-16 offset to a full [`Position`]. The end-of-buffer offset is
    /// valid; an offset inside a surrogate pair or past the end is rejected.
    pub fn position_for_utf16(&self, target_utf16: usize) -> Result<Position, TextBufferError> {
        coords::position_for_utf16(&self.root, target_utf16)
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
        coords::position_for_line_column(&self.root, line, column_utf16)
    }

    /// Writes the full document content to `writer` in document order, walking the
    /// tree in place and writing each leaf's bytes as it is visited. No
    /// full-document buffer is materialized, so save memory is `O(tree height)`
    /// regardless of document or edit-history size.
    pub fn write_to(&self, writer: &mut dyn std::io::Write) -> std::io::Result<()> {
        self.root.write_to(writer)
    }

    /// Takes a snapshot of the current content. Because the rope is persistent
    /// (immutable, structurally shared), this is an `O(1)` clone of the root that
    /// shares every node with the live buffer; later edits never change it. This
    /// is the capability the rope exists to provide — cheap baselines for diff,
    /// review, and history.
    pub fn snapshot(&self) -> TextSnapshot {
        TextSnapshot {
            root: self.root.clone(),
            marker: self.current_top_seq(),
        }
    }

    /// Takes a snapshot for a background save and seals the current insert run.
    /// Like [`snapshot`](Self::snapshot) the content clone is `O(1)`, but this
    /// also records the edit-history position being written and makes the next
    /// keystroke start a new undo record, so that position stays accurate even if
    /// the user keeps editing during the write. Pass the returned snapshot to
    /// [`mark_saved_snapshot`](Self::mark_saved_snapshot) once the write finishes.
    pub fn snapshot_for_save(&mut self) -> TextSnapshot {
        self.seal_coalescing = true;
        TextSnapshot {
            root: self.root.clone(),
            marker: self.current_top_seq(),
        }
    }

    /// Marks the content captured by `snapshot` as the saved baseline. Unlike
    /// [`mark_saved`](Self::mark_saved), which marks the *current* content, this
    /// marks exactly what was written: a buffer edited during the write stays
    /// dirty (its newer content is not yet on disk), and undoing back to the saved
    /// content reads clean again. Pair with [`snapshot_for_save`](Self::snapshot_for_save),
    /// whose seal keeps the recorded position faithful.
    pub fn mark_saved_snapshot(&mut self, snapshot: &TextSnapshot) {
        self.saved_seq = snapshot.marker;
    }

    // MARK: - Edits

    /// Inserts `text` at UTF-16 offset `at_utf16`. Consecutive single-run
    /// inserts at the advancing caret coalesce into one undo step.
    pub fn insert(&mut self, at_utf16: usize, text: &str) -> Result<(), TextBufferError> {
        if text.is_empty() {
            return Ok(());
        }
        let at_byte = self.utf16_to_byte(at_utf16)?;
        let inserted = Node::from_str(text);
        self.splice(at_byte, 0, inserted.clone());
        self.redo_stack.clear();

        // A save snapshot seals the current run: the next insert starts a fresh
        // undo record instead of extending it, so the snapshot's captured `seq`
        // stays a faithful identifier of its content even as typing continues
        // during the background write. This one insert consumes the seal.
        let sealed = std::mem::replace(&mut self.seal_coalescing, false);

        // Extend the previous typed run, but never coalesce into the saved
        // baseline record: doing so would hide the new edit from dirty tracking.
        let saved_seq = self.saved_seq;
        if !sealed {
            if let Some(top) = self.undo_stack.last_mut() {
                if top.removed.byte_len() == 0
                    && top.at_byte + top.inserted.byte_len() == at_byte
                    && Some(top.seq) != saved_seq
                {
                    top.inserted = Node::concat(top.inserted.clone(), inserted);
                    return Ok(());
                }
            }
        }

        let seq = self.next_seq();
        self.undo_stack.push(EditRecord {
            seq,
            at_byte,
            removed: Node::empty(),
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

        // The removed sub-rope is `Arc` pointers into the existing leaves, so even
        // a huge delete copies no content.
        let removed = self.splice(start_byte, end_byte - start_byte, Node::empty());
        self.redo_stack.clear();

        let seq = self.next_seq();
        self.undo_stack.push(EditRecord {
            seq,
            at_byte: start_byte,
            removed,
            inserted: Node::empty(),
        });
        Ok(())
    }

    /// Replaces the UTF-16 range `[start_utf16, end_utf16)` with `text` in a
    /// single splice recorded as one undo step (the record holds both the removed
    /// and inserted sub-ropes), so undoing a typed-over selection restores it in
    /// one step rather than two. Unlike `insert`, a replace never coalesces.
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

        let inserted = Node::from_str(text);
        // One splice: drop the old range and put the new sub-rope in its place,
        // capturing the removed sub-rope for a single undo record.
        let removed = self.splice(start_byte, end_byte - start_byte, inserted.clone());
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

    /// Reverts the most recent edit, returning the span it rewrote (in the
    /// reverted document's coordinates), or `None` if there is nothing to undo.
    pub fn undo(&mut self) -> Option<EditSpan> {
        let record = self.undo_stack.pop()?;
        // The inserted sub-rope currently occupies `[at_byte, at_byte + inserted)`;
        // put the removed sub-rope back in its place.
        let old_len_utf16 = record.inserted.summary().utf16;
        let new_len_utf16 = record.removed.summary().utf16;
        self.splice(
            record.at_byte,
            record.inserted.byte_len(),
            record.removed.clone(),
        );
        // Resolved on the post-splice tree: the prefix before the splice point is
        // identical on both sides, so this is the span start either way.
        let start_utf16 = coords::utf16_before_byte(&self.root, record.at_byte);
        self.redo_stack.push(record);
        Some(EditSpan {
            start_utf16,
            old_len_utf16,
            new_len_utf16,
        })
    }

    /// Re-applies the most recently undone edit, returning the span it rewrote
    /// (in the re-applied document's coordinates), or `None` if there is nothing
    /// to redo.
    pub fn redo(&mut self) -> Option<EditSpan> {
        let record = self.redo_stack.pop()?;
        let old_len_utf16 = record.removed.summary().utf16;
        let new_len_utf16 = record.inserted.summary().utf16;
        self.splice(
            record.at_byte,
            record.removed.byte_len(),
            record.inserted.clone(),
        );
        let start_utf16 = coords::utf16_before_byte(&self.root, record.at_byte);
        self.undo_stack.push(record);
        Some(EditSpan {
            start_utf16,
            old_len_utf16,
            new_len_utf16,
        })
    }

    // MARK: - Edit internals

    /// Splits out `[at_byte, at_byte + remove_len)`, returns the removed sub-rope
    /// (by reference — no content copy), and splices `inserted` into the gap.
    /// Every mutation path funnels through here so the revision counter advances
    /// exactly once per edit.
    fn splice(&mut self, at_byte: usize, remove_len: usize, inserted: Node) -> Node {
        let (left, rest) = self.root.split(at_byte);
        let (removed, right) = rest.split(remove_len);
        self.root = Node::concat(Node::concat(left, inserted), right);
        self.revision += 1;
        removed
    }

    /// Converts a UTF-16 offset to a logical byte offset.
    fn utf16_to_byte(&self, target_utf16: usize) -> Result<usize, TextBufferError> {
        Ok(coords::position_for_utf16(&self.root, target_utf16)?.byte)
    }

    fn current_top_seq(&self) -> Option<u64> {
        self.undo_stack.last().map(|record| record.seq)
    }

    fn next_seq(&mut self) -> u64 {
        self.seq_counter += 1;
        self.seq_counter
    }
}

/// An immutable, structurally-shared view of a [`TextBuffer`]'s content at the
/// moment [`snapshot`](TextBuffer::snapshot) was called. Holding one is cheap (it
/// shares the buffer's rope nodes) and isolated (later edits to the buffer never
/// change it), so a background task can read a consistent baseline while the user
/// keeps editing.
pub struct TextSnapshot {
    root: Node,
    /// `seq` of the buffer's top undo record when this snapshot was taken, so
    /// [`TextBuffer::mark_saved_snapshot`] can mark exactly this content saved.
    /// `None` means the buffer had no (or fully undone) edits at snapshot time.
    /// Read-only snapshots carry it too; it only matters when paired with
    /// `mark_saved_snapshot`.
    marker: Option<u64>,
}

impl TextSnapshot {
    /// Writes the snapshot's full content to `writer` in document order without
    /// materializing a full-document buffer (`O(tree height)` memory). This is the
    /// background-save read: the snapshot is immutable, so the write is isolated
    /// from concurrent edits to the originating buffer.
    pub fn write_to(&self, writer: &mut dyn std::io::Write) -> std::io::Result<()> {
        self.root.write_to(writer)
    }

    /// Total bytes of UTF-8 content.
    pub fn byte_len(&self) -> usize {
        self.root.summary().bytes
    }

    /// Total UTF-16 code units.
    pub fn utf16_len(&self) -> usize {
        self.root.summary().utf16
    }

    /// Number of logical lines (a trailing newline counts a final empty line).
    pub fn line_count(&self) -> usize {
        self.root.summary().line_breaks + 1
    }

    /// The full content as a string (raw bytes, terminators preserved).
    pub fn text(&self) -> String {
        let mut out = Vec::with_capacity(self.byte_len());
        self.root
            .write_to(&mut out)
            .expect("writing to a Vec never fails");
        String::from_utf8(out).expect("rope content is validated UTF-8")
    }

    /// Lines `[start_line, start_line + count)` joined by `\n`, each terminator
    /// stripped, matching [`TextBuffer::text_for_line_range`].
    pub fn text_for_line_range(&self, start_line: usize, count: usize) -> String {
        coords::text_for_line_range(&self.root, start_line, count)
    }

    /// Like [`text_for_line_range`](Self::text_for_line_range), but each line is
    /// truncated to at most `max_bytes_per_line` (on a character boundary),
    /// matching [`TextBuffer::text_for_line_range_capped`]. This is the read a
    /// background wrap-measure pass uses, so one enormous line cannot blow up
    /// the chunk fetch.
    pub fn text_for_line_range_capped(
        &self,
        start_line: usize,
        count: usize,
        max_bytes_per_line: usize,
    ) -> String {
        coords::text_for_line_range_capped(&self.root, start_line, count, max_bytes_per_line)
    }

    /// Maps a 0-based `line` and UTF-16 `column_utf16` to a full [`Position`],
    /// matching [`TextBuffer::position_for_line_column`] (column clamps to the
    /// line's content end; an out-of-range line is rejected).
    pub fn position_for_line_column(
        &self,
        line: usize,
        column_utf16: usize,
    ) -> Result<Position, TextBufferError> {
        coords::position_for_line_column(&self.root, line, column_utf16)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn buffer(text: &str) -> TextBuffer {
        TextBuffer::from_utf8_bytes(text.as_bytes().to_vec()).expect("valid utf-8")
    }

    fn chunked(text: &str, chunk: usize) -> TextBuffer {
        TextBuffer::from_source_with_cap(Box::new(OwnedBytes::new(text.as_bytes().to_vec())), chunk)
            .expect("valid utf-8")
    }

    fn contents(buffer: &TextBuffer) -> String {
        buffer.text_for_line_range(0, buffer.line_count())
    }

    // MARK: - Save snapshot (immutable background-save baseline + dirty tracking)

    #[test]
    fn save_snapshot_is_isolated_from_later_edits() {
        let mut buffer = buffer("hello");
        let snapshot = buffer.snapshot_for_save();
        buffer.insert(5, " world").expect("insert");
        // The snapshot keeps the content captured at save start.
        assert_eq!(snapshot.text(), "hello");
        assert_eq!(snapshot.byte_len(), 5);
        assert_eq!(contents(&buffer), "hello world");
    }

    #[test]
    fn save_snapshot_write_to_streams_full_content() {
        let mut buffer = buffer("line1\nline2\n");
        let snapshot = buffer.snapshot_for_save();
        let mut out = Vec::new();
        snapshot.write_to(&mut out).expect("write");
        assert_eq!(out, b"line1\nline2\n");
    }

    #[test]
    fn save_snapshot_seals_the_coalescing_run() {
        let mut buffer = buffer("");
        buffer.insert(0, "a").expect("insert");
        buffer.insert(1, "b").expect("insert"); // coalesces with "a" -> run "ab"
        let _snapshot = buffer.snapshot_for_save(); // seal the run
        buffer.insert(2, "c").expect("insert"); // new record, not coalesced into "ab"
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "ab"); // only "c" undone
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), ""); // "ab" undone in one step
    }

    #[test]
    fn contiguous_inserts_coalesce_without_a_save_snapshot() {
        let mut buffer = buffer("");
        buffer.insert(0, "a").expect("insert");
        buffer.insert(1, "b").expect("insert");
        buffer.insert(2, "c").expect("insert"); // all coalesced into one run
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), ""); // one undo removes "abc"
    }

    #[test]
    fn mark_saved_snapshot_clears_dirty_when_unchanged() {
        let mut buffer = buffer("");
        buffer.insert(0, "hello").expect("insert");
        assert!(buffer.is_dirty());
        let snapshot = buffer.snapshot_for_save();
        buffer.mark_saved_snapshot(&snapshot);
        assert!(!buffer.is_dirty());
    }

    #[test]
    fn mark_saved_snapshot_keeps_buffer_dirty_when_edited_during_save() {
        let mut buffer = buffer("");
        buffer.insert(0, "hello").expect("insert");
        let snapshot = buffer.snapshot_for_save(); // captures "hello"
        buffer.insert(5, "world").expect("insert"); // edited during the write
        buffer.mark_saved_snapshot(&snapshot); // only "hello" reached disk
        assert!(buffer.is_dirty());
        assert_eq!(snapshot.text(), "hello");
    }

    #[test]
    fn mark_saved_snapshot_then_undo_to_saved_content_is_clean() {
        let mut buffer = buffer("");
        buffer.insert(0, "hello").expect("insert");
        let snapshot = buffer.snapshot_for_save();
        buffer.insert(5, "world").expect("insert");
        buffer.mark_saved_snapshot(&snapshot); // disk == "hello"
        assert!(buffer.is_dirty());
        assert!(buffer.undo().is_some()); // back to "hello"
        assert_eq!(contents(&buffer), "hello");
        assert!(!buffer.is_dirty()); // matches disk again
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
    fn utf16_range_reads_a_sub_range_within_a_line() {
        let buffer = buffer("hello world");
        assert_eq!(buffer.text_for_utf16_range(0, 5), "hello");
        assert_eq!(buffer.text_for_utf16_range(6, 11), "world");
        assert_eq!(buffer.text_for_utf16_range(3, 3), "");
    }

    #[test]
    fn utf16_range_handles_multibyte_and_surrogate_pairs() {
        let buffer = buffer("aあ𝄞z"); // utf16: a=0, あ=1, 𝄞=2..4 (pair), z=4
        assert_eq!(buffer.text_for_utf16_range(1, 2), "あ");
        assert_eq!(buffer.text_for_utf16_range(2, 4), "𝄞");
        assert_eq!(buffer.text_for_utf16_range(0, 5), "aあ𝄞z");
    }

    #[test]
    fn utf16_range_clamps_and_floors_instead_of_erroring() {
        let buffer = buffer("𝄞");
        // Inverted range → empty (viewport reads never error).
        assert_eq!(buffer.text_for_utf16_range(2, 1), "");
        // Past the end → clamped.
        assert_eq!(buffer.text_for_utf16_range(0, 99), "𝄞");
        // Offset 1 splits the surrogate pair. A mid-surrogate *end* floors back to
        // the character's start, so [0,1) collapses to empty; a mid-surrogate
        // *start* floors to the same start, so [1,2) covers the whole character.
        assert_eq!(buffer.text_for_utf16_range(0, 1), "");
        assert_eq!(buffer.text_for_utf16_range(1, 2), "𝄞");
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
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "hello");
        assert!(buffer.redo().is_some());
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
        assert!(buffer.undo().is_some());
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
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "ac");
        assert!(buffer.redo().is_some());
        assert_eq!(contents(&buffer), "abc");
    }

    #[test]
    fn undo_and_redo_report_the_rewritten_span_in_utf16() {
        // "😀" is 4 bytes but 2 UTF-16 units, so the reported offsets prove the
        // span is UTF-16, not bytes. Replace "bc" (2 units at offset 3) with
        // "XX\nYY" (5 units).
        let mut buffer = buffer("😀abc");
        buffer.replace(3, 5, "XX\nYY").expect("replace");

        // Undo removes the 5-unit replacement and restores the 2-unit original.
        let undone = buffer.undo().expect("one edit to undo");
        assert_eq!(
            undone,
            EditSpan {
                start_utf16: 3,
                old_len_utf16: 5,
                new_len_utf16: 2,
            }
        );
        assert_eq!(contents(&buffer), "😀abc");

        // Redo is the mirror image: the original span goes back out, the
        // replacement back in.
        let redone = buffer.redo().expect("one edit to redo");
        assert_eq!(
            redone,
            EditSpan {
                start_utf16: 3,
                old_len_utf16: 2,
                new_len_utf16: 5,
            }
        );
        assert_eq!(contents(&buffer), "😀aXX\nYY");
    }

    #[test]
    fn undo_span_covers_a_whole_coalesced_typing_run() {
        // Three coalesced single-character inserts form one record; undoing it
        // reports the run's full span, since that is what left the document.
        let mut buffer = buffer("..");
        buffer.insert(1, "a").expect("insert");
        buffer.insert(2, "b").expect("insert");
        buffer.insert(3, "c").expect("insert");
        let undone = buffer.undo().expect("the typed run undoes as one step");
        assert_eq!(
            undone,
            EditSpan {
                start_utf16: 1,
                old_len_utf16: 3,
                new_len_utf16: 0,
            }
        );
        assert_eq!(contents(&buffer), "..");
    }

    #[test]
    fn undo_and_redo_a_delete() {
        let mut buffer = buffer("abcdef");
        buffer.delete(1, 4).expect("delete");
        assert_eq!(contents(&buffer), "aef");
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "abcdef");
        assert!(buffer.redo().is_some());
        assert_eq!(contents(&buffer), "aef");
    }

    #[test]
    fn undo_on_empty_history_returns_false() {
        let mut buffer = buffer("ab");
        assert!(buffer.undo().is_none());
        assert!(buffer.redo().is_none());
    }

    #[test]
    fn contiguous_typing_coalesces_into_one_undo_step() {
        let mut buffer = buffer("");
        buffer.insert(0, "h").expect("insert");
        buffer.insert(1, "i").expect("insert");
        buffer.insert(2, "!").expect("insert");
        assert_eq!(contents(&buffer), "hi!");
        // A single undo reverts the whole typed run.
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "");
        assert!(buffer.undo().is_none());
    }

    #[test]
    fn non_contiguous_inserts_are_separate_undo_steps() {
        let mut buffer = buffer("..");
        buffer.insert(0, "a").expect("insert");
        // Jump the caret: insert not contiguous with the previous run.
        buffer.insert(3, "b").expect("insert");
        assert_eq!(contents(&buffer), "a..b");
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "a..");
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "..");
    }

    #[test]
    fn a_new_edit_clears_the_redo_stack() {
        let mut buffer = buffer("");
        buffer.insert(0, "a").expect("insert");
        buffer.undo();
        buffer.insert(0, "b").expect("insert");
        // Redo of the original insert is no longer available.
        assert!(buffer.redo().is_none());
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
    fn retyping_the_saved_text_still_reads_dirty() {
        // Dirty tracking is history-based, not a content comparison: undoing past
        // the save and retyping the same characters lands on a different edit
        // record, so the buffer still reads dirty.
        let mut buffer = buffer("ab");
        buffer.insert(2, "c").expect("insert");
        buffer.mark_saved();
        buffer.undo(); // "ab", before the saved edit
        assert!(buffer.is_dirty());
        buffer.insert(2, "c").expect("insert"); // retype the saved content
        assert_eq!(contents(&buffer), "abc");
        assert!(buffer.is_dirty());
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
        assert!(buffer.undo().is_some()); // undo the insert only
        assert_eq!(contents(&buffer), "ab");
        assert!(buffer.undo().is_some()); // undo the delete
        assert_eq!(contents(&buffer), "abc");
    }

    #[test]
    fn delete_spanning_multiple_pieces() {
        let mut buffer = buffer("HELLOWORLD");
        buffer.insert(5, "-").expect("insert"); // "HELLO-WORLD"
        buffer.delete(3, 8).expect("delete"); // remove "LO-WO" across leaves
        assert_eq!(contents(&buffer), "HELRLD");
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "HELLO-WORLD");
    }

    #[test]
    fn redo_after_a_coalesced_run() {
        let mut buffer = buffer("");
        buffer.insert(0, "a").expect("insert");
        buffer.insert(1, "b").expect("insert"); // coalesced
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "");
        assert!(buffer.redo().is_some()); // re-applies the whole run at once
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
        // A tiny leaf cap forces many leaves over a small input.
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
        // cap=4 places "\r" at the end of one leaf and "\n" at the start of the
        // next for "abc\r\ndef".
        let buffer = chunked("abc\r\ndef", 4);
        assert_eq!(buffer.line_count(), 2);
        assert_eq!(buffer.text_for_line_range(0, 1), "abc");
        assert_eq!(buffer.text_for_line_range(0, 2), "abc\ndef");
        let position = buffer.position_for_line_column(0, 99).expect("clamped");
        assert_eq!(position.byte, 3);
    }

    #[test]
    fn multibyte_chars_are_never_split_across_chunks() {
        // "あ" is 3 bytes; with cap=2 the boundary cannot fall mid-char.
        let text = "あいうえお\nかきくけこ";
        let buffer = chunked(text, 2);
        assert_eq!(buffer.line_count(), 2);
        assert_eq!(contents(&buffer), text);
        // Round-trip a position that sits across several leaves.
        let position = buffer.position_for_utf16(7).expect("position");
        assert_eq!(position.line, 1);
        assert_eq!(position.column_utf16, 1);
    }

    #[test]
    fn editing_across_chunk_boundaries_stays_consistent() {
        let mut buffer = chunked("0123456789", 3);
        buffer.insert(5, "ABC").expect("insert");
        assert_eq!(contents(&buffer), "01234ABC56789");
        // Remove utf16 [2, 9) = "234ABC5", spanning original and inserted leaves.
        buffer.delete(2, 9).expect("delete");
        assert_eq!(contents(&buffer), "016789");
        assert!(buffer.undo().is_some());
        assert_eq!(contents(&buffer), "01234ABC56789");
        assert!(buffer.undo().is_some());
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
        while buffer.undo().is_some() {}
        assert_eq!(contents(&buffer), "");
    }

    #[test]
    fn large_delete_shares_content_without_copying() {
        // The deleted text lives in the shared original; the delete and its undo
        // must not copy it into owned (inserted) leaves — the rope analogue of
        // "don't grow the add buffer". Only the tiny seam where the kept head and
        // tail meet may become a small owned leaf.
        let text = "x".repeat(50_000);
        let mut buffer = chunked(&text, 64);
        assert_eq!(
            buffer.root.owned_byte_count(),
            0,
            "fresh buffer owns nothing"
        );
        buffer.delete(10, 49_990).expect("delete");
        assert!(
            buffer.root.owned_byte_count() < 1_024,
            "delete copied {} bytes of content",
            buffer.root.owned_byte_count()
        );
        assert_eq!(buffer.byte_len(), 20);
        assert!(buffer.undo().is_some());
        assert!(
            buffer.root.owned_byte_count() < 1_024,
            "undo copied {} bytes of content",
            buffer.root.owned_byte_count()
        );
        assert_eq!(buffer.byte_len(), 50_000);
        assert!(buffer.redo().is_some());
        assert_eq!(buffer.byte_len(), 20);
    }

    #[test]
    fn undo_cycles_do_not_grow_the_node_graph() {
        // Repeated insert/undo cycles must not grow the live node graph without
        // bound. Each new insert clears the redo stack, dropping the prior record.
        let mut buffer = buffer("seed");
        for _ in 0..200 {
            buffer.insert(0, "ABCDE").expect("insert");
            buffer.undo();
        }
        // A loose bound: a leak would push the graph into the thousands.
        assert!(
            buffer.root.node_count() < 64,
            "node graph grew to {}",
            buffer.root.node_count()
        );
        assert_eq!(contents(&buffer), "seed");
    }

    #[test]
    fn line_column_on_a_long_single_line_maps_via_tree_not_materialization() {
        // One line, no '\n', spanning many leaves, with an astral char so UTF-16
        // counting matters. The query must not assemble the line.
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
        // The leaf-cap guard (`cap.max(1)`) keeps `next_chunk_end` progressing.
        let buffer = chunked("ab\ncd\n", 0);
        assert_eq!(buffer.line_count(), 3);
        assert_eq!(contents(&buffer), "ab\ncd\n");
        assert_eq!(buffer.text_for_line_range(1, 1), "cd");
    }

    // MARK: - Rope structural guarantees

    #[test]
    fn a_giant_single_line_is_stored_in_bounded_leaves() {
        // Why position_for_line_column stays O(log n + leaf) on a giant line
        // instead of materializing it: the line is split across many capped
        // leaves, so any single within-leaf scan is bounded regardless of how
        // long the line is.
        let buffer = buffer(&"x".repeat(1_000_000));
        assert_eq!(buffer.line_count(), 1);
        assert!(
            buffer.root.max_leaf_bytes() <= super::rope::LEAF_MAX_BYTES,
            "a leaf grew to {} bytes",
            buffer.root.max_leaf_bytes()
        );
        // Many leaves, not one giant leaf.
        assert!(buffer.root.node_count() > 16, "the line was not chunked");
    }

    #[test]
    fn a_long_edit_session_keeps_the_live_tree_bounded() {
        // Span-based undo keeps history cheap, but the property that matters is
        // that the *live* tree never bloats with edit count: 2000 edits that net
        // to no change leave the tree as small as the content demands (no
        // retained per-version node graphs, unlike snapshot-based undo).
        let mut buffer = buffer("seed line\n");
        for _ in 0..1000 {
            buffer.insert(5, "abc").expect("insert");
            buffer.delete(5, 8).expect("delete");
        }
        assert_eq!(contents(&buffer), "seed line\n");
        assert!(
            buffer.root.node_count() < 64,
            "the live tree grew to {} nodes",
            buffer.root.node_count()
        );
    }

    // MARK: - Snapshot (the cheap, structurally-shared view the rope enables)

    #[test]
    fn snapshot_is_isolated_from_later_edits() {
        let mut buffer = buffer("hello\nworld");
        let snapshot = buffer.snapshot();
        // Mutate the buffer in every way after taking the snapshot.
        buffer.insert(5, " there").expect("insert");
        buffer.delete(0, 2).expect("delete");
        buffer.replace(0, 1, "X").expect("replace");
        // The snapshot still reflects the original content and metrics.
        assert_eq!(snapshot.text(), "hello\nworld");
        assert_eq!(snapshot.byte_len(), "hello\nworld".len());
        assert_eq!(snapshot.utf16_len(), 11);
        assert_eq!(snapshot.line_count(), 2);
        assert_eq!(snapshot.text_for_line_range(1, 1), "world");
    }

    #[test]
    fn snapshot_reads_match_the_buffer_it_was_taken_from() {
        // The wrap-measure read surface: capped line reads and line/column
        // positions answer from the snapshot exactly like the live buffer at the
        // moment it was taken, and stay isolated from later edits. "😀" makes the
        // byte cap land on a character boundary, not mid-code-point.
        let mut buffer = buffer("😀😀😀😀\nshort\nlast");
        let snapshot = buffer.snapshot();
        let capped_from_buffer = buffer.text_for_line_range_capped(0, 3, 8);
        let position_from_buffer = buffer
            .position_for_line_column(1, 3)
            .expect("line 1 exists");

        buffer
            .replace(0, buffer.utf16_len(), "rewritten")
            .expect("replace");

        assert_eq!(
            snapshot.text_for_line_range_capped(0, 3, 8),
            capped_from_buffer
        );
        assert_eq!(snapshot.text_for_line_range_capped(0, 1, 8), "😀😀"); // 8 bytes = 2 emoji
        let position = snapshot
            .position_for_line_column(1, 3)
            .expect("snapshot keeps line 1");
        assert_eq!(position, position_from_buffer);
        assert_eq!(position.line, 1);
        assert_eq!(position.column_utf16, 3);
        // Out-of-range lines are rejected, mirroring the buffer's contract.
        assert!(snapshot.position_for_line_column(99, 0).is_err());
    }

    // MARK: - Differential model (oracle) test
    //
    // A deterministic, fixed-seed random op stream is applied to both the buffer
    // and a trivial `String` model; after every op their content and every
    // derived metric/position must agree. This is the safety net for the rope
    // rewrite: structural bugs (cross-leaf prefix sums, a CRLF or multibyte
    // sequence split across a boundary) surface here even when the hand-written
    // cases miss them.

    struct XorShift64(u64);

    impl XorShift64 {
        fn new(seed: u64) -> Self {
            Self(seed | 1) // never zero, or the generator sticks at zero
        }

        fn next_u64(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.0 = x;
            x
        }

        fn below(&mut self, bound: usize) -> usize {
            (self.next_u64() % bound as u64) as usize
        }
    }

    fn raw_contents(buffer: &TextBuffer) -> String {
        let mut out = Vec::new();
        buffer.write_to(&mut out).expect("write");
        String::from_utf8(out).expect("utf-8")
    }

    fn utf16_count(text: &str) -> usize {
        text.chars().map(char::len_utf16).sum()
    }

    fn char_to_byte(text: &str, char_index: usize) -> usize {
        text.char_indices()
            .nth(char_index)
            .map(|(byte, _)| byte)
            .unwrap_or(text.len())
    }

    fn char_to_utf16(text: &str, char_index: usize) -> usize {
        text.chars().take(char_index).map(char::len_utf16).sum()
    }

    /// The position the buffer must report for a UTF-16 offset `<= utf16_len`,
    /// computed directly from the model. `Err` marks an offset that splits a
    /// surrogate pair.
    fn model_position(model: &str, utf16_offset: usize) -> Result<Position, ()> {
        let mut acc_utf16 = 0;
        let mut byte = 0;
        let mut chars = 0;
        for character in model.chars() {
            if acc_utf16 == utf16_offset {
                break;
            }
            let next = acc_utf16 + character.len_utf16();
            if next > utf16_offset {
                return Err(()); // between the two units of a surrogate pair
            }
            acc_utf16 = next;
            byte += character.len_utf8();
            chars += 1;
        }
        let prefix = &model[..byte];
        let line = prefix.bytes().filter(|&b| b == b'\n').count();
        let line_start = prefix.rfind('\n').map(|index| index + 1).unwrap_or(0);
        Ok(Position {
            byte,
            char: chars,
            utf16: utf16_offset,
            line,
            column_utf16: utf16_count(&model[line_start..byte]),
        })
    }

    /// Byte range `[start, end)` of `line` in the model, including its terminator.
    fn model_line_bounds(model: &str, line: usize) -> (usize, usize) {
        let bytes = model.as_bytes();
        let mut start = 0;
        if line > 0 {
            let mut seen = 0;
            for (index, &b) in bytes.iter().enumerate() {
                if b == b'\n' {
                    seen += 1;
                    if seen == line {
                        start = index + 1;
                        break;
                    }
                }
            }
        }
        let mut end = start;
        while end < bytes.len() && bytes[end] != b'\n' {
            end += 1;
        }
        if end < bytes.len() {
            end += 1; // include the '\n'
        }
        (start, end)
    }

    fn model_line_start_utf16(model: &str, line: usize) -> usize {
        let (start, _) = model_line_bounds(model, line);
        utf16_count(&model[..start])
    }

    /// Content end (UTF-16) of `line`, with a trailing `\n` and a preceding `\r`
    /// excluded — what `position_for_line_column` clamps a column to.
    fn model_line_content_end_utf16(model: &str, line: usize) -> usize {
        let (start, end) = model_line_bounds(model, line);
        let bytes = model.as_bytes();
        let mut content_end = end;
        if content_end > start && bytes[content_end - 1] == b'\n' {
            content_end -= 1;
            if content_end > start && bytes[content_end - 1] == b'\r' {
                content_end -= 1;
            }
        }
        utf16_count(&model[..content_end])
    }

    #[test]
    fn matches_string_model_over_random_ops() {
        let mut rng = XorShift64::new(0x0DDB_1A5E_5EED_1234);
        let mut buffer = buffer("");
        let mut model = String::new();
        // Fragments span ASCII, multibyte, astral (surrogate pair), the line
        // terminators, embedded NUL, and a multi-line piece.
        let fragments = ["a", "Z", "あ", "𝄞", "\n", "\r\n", "\r", "\0", "ij\nkl"];

        for step in 0..3000 {
            let char_count = model.chars().count();
            let choice = rng.below(100);
            if char_count == 0 || choice < 50 {
                let at = rng.below(char_count + 1);
                let fragment = fragments[rng.below(fragments.len())];
                buffer
                    .insert(char_to_utf16(&model, at), fragment)
                    .expect("insert");
                model.insert_str(char_to_byte(&model, at), fragment);
            } else if choice < 78 {
                let a = rng.below(char_count + 1);
                let b = rng.below(char_count + 1);
                let (lo, hi) = (a.min(b), a.max(b));
                buffer
                    .delete(char_to_utf16(&model, lo), char_to_utf16(&model, hi))
                    .expect("delete");
                model.replace_range(char_to_byte(&model, lo)..char_to_byte(&model, hi), "");
            } else if choice < 90 {
                let a = rng.below(char_count + 1);
                let b = rng.below(char_count + 1);
                let (lo, hi) = (a.min(b), a.max(b));
                let fragment = fragments[rng.below(fragments.len())];
                buffer
                    .replace(
                        char_to_utf16(&model, lo),
                        char_to_utf16(&model, hi),
                        fragment,
                    )
                    .expect("replace");
                model.replace_range(char_to_byte(&model, lo)..char_to_byte(&model, hi), fragment);
            } else if choice < 95 {
                // Undo/redo coalescing is verified precisely by the dedicated
                // tests; here we trust the buffer and re-sync the model, so the
                // checks below validate the resulting tree's self-consistency.
                buffer.undo();
                model = raw_contents(&buffer);
            } else {
                buffer.redo();
                model = raw_contents(&buffer);
            }

            assert_eq!(raw_contents(&buffer), model, "content at step {step}");
            assert_eq!(buffer.byte_len(), model.len(), "byte_len at step {step}");
            assert_eq!(
                buffer.utf16_len(),
                utf16_count(&model),
                "utf16_len at step {step}"
            );
            assert_eq!(
                buffer.line_count(),
                model.bytes().filter(|&b| b == b'\n').count() + 1,
                "line_count at step {step}"
            );

            let total = utf16_count(&model);
            let mut offsets = vec![0, total, total + 3];
            for _ in 0..6 {
                offsets.push(rng.below(total + 2));
            }
            for offset in offsets {
                let actual = buffer.position_for_utf16(offset);
                if offset > total {
                    assert!(
                        actual.is_err(),
                        "offset {offset} past end should err at step {step}"
                    );
                    continue;
                }
                match (actual, model_position(&model, offset)) {
                    (Ok(actual), Ok(expected)) => {
                        assert_eq!(actual, expected, "position {offset} at step {step}")
                    }
                    (Err(_), Err(())) => {}
                    (actual, expected) => panic!(
                        "position {offset} mismatch at step {step}: {actual:?} vs model {expected:?}"
                    ),
                }
            }

            let line_count = buffer.line_count();
            for _ in 0..3 {
                let line = rng.below(line_count);
                let start = buffer
                    .position_for_line_column(line, 0)
                    .expect("line start");
                assert_eq!(
                    start.utf16,
                    model_line_start_utf16(&model, line),
                    "line {line} start at step {step}"
                );
                let clamped = buffer
                    .position_for_line_column(line, usize::MAX)
                    .expect("clamped");
                assert_eq!(
                    clamped.utf16,
                    model_line_content_end_utf16(&model, line),
                    "line {line} content end at step {step}"
                );
            }
        }
    }
}
