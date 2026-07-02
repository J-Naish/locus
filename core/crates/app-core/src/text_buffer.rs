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

/// Default retained undo/redo byte budget. This is deliberately much smaller
/// than the editable file-size cap: a document can be large, but history should
/// not grow without bound during a long session.
pub const DEFAULT_HISTORY_BYTE_LIMIT: usize = 64 * 1024 * 1024;

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

impl EditRecord {
    fn retained_byte_len(&self) -> usize {
        self.removed.byte_len() + self.inserted.byte_len()
    }
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
    history_byte_len: usize,
    history_byte_limit: usize,
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
            history_byte_len: 0,
            history_byte_limit: DEFAULT_HISTORY_BYTE_LIMIT,
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

    /// Approximate bytes retained by undo/redo records. This counts the edited
    /// sub-ropes' logical content bytes; shared original backing may make the
    /// process-retained memory higher, but this is stable enough for caps and UI
    /// diagnostics.
    pub fn history_byte_len(&self) -> usize {
        self.history_byte_len
    }

    /// Sets the best-effort retained-history budget and immediately prunes old
    /// records. The latest undo record is kept even if it alone exceeds the
    /// budget, so dirty tracking and one-step undo do not silently disappear.
    pub fn set_history_byte_limit(&mut self, byte_limit: usize) {
        self.history_byte_limit = byte_limit;
        self.prune_history_to_limit();
    }

    /// Marks the current content as the saved baseline.
    pub fn mark_saved(&mut self) {
        self.saved_seq = self.current_top_seq();
    }

    /// Marks the current content as saved and releases undo/redo history. The
    /// platform uses this after a completed save when the live buffer still
    /// matches the saved snapshot, so old rope nodes and original backing bytes
    /// are not pinned for the rest of a long session.
    pub fn mark_saved_and_clear_history(&mut self) {
        self.undo_stack.clear();
        self.redo_stack.clear();
        self.history_byte_len = 0;
        self.saved_seq = None;
        self.seal_coalescing = false;
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
        self.clear_redo_stack();

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
                    self.history_byte_len += inserted.byte_len();
                    top.inserted = Node::concat(top.inserted.clone(), inserted);
                    self.prune_history_to_limit();
                    return Ok(());
                }
            }
        }

        let seq = self.next_seq();
        self.push_undo_record(EditRecord {
            seq,
            at_byte,
            removed: Node::empty(),
            inserted,
        });
        self.prune_history_to_limit();
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
        self.clear_redo_stack();

        let seq = self.next_seq();
        self.push_undo_record(EditRecord {
            seq,
            at_byte: start_byte,
            removed,
            inserted: Node::empty(),
        });
        self.prune_history_to_limit();
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
        self.clear_redo_stack();

        let seq = self.next_seq();
        self.push_undo_record(EditRecord {
            seq,
            at_byte: start_byte,
            removed,
            inserted,
        });
        self.prune_history_to_limit();
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
        self.prune_history_to_limit();
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

    fn push_undo_record(&mut self, record: EditRecord) {
        self.history_byte_len += record.retained_byte_len();
        self.undo_stack.push(record);
    }

    fn clear_redo_stack(&mut self) {
        let redo_byte_len = self
            .redo_stack
            .iter()
            .map(EditRecord::retained_byte_len)
            .sum::<usize>();
        self.history_byte_len -= redo_byte_len;
        self.redo_stack.clear();
    }

    fn prune_history_to_limit(&mut self) {
        while self.history_byte_len > self.history_byte_limit {
            if self.undo_stack.len() > 1 {
                let removed = self.undo_stack.remove(0);
                self.history_byte_len -= removed.retained_byte_len();
                continue;
            }
            if self.redo_stack.len() > 1 {
                let removed = self.redo_stack.remove(0);
                self.history_byte_len -= removed.retained_byte_len();
                continue;
            }
            break;
        }
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
mod tests;
