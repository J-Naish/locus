//! C ABI for the arbitrary-size text buffer (see `app_core::text_buffer`).
//!
//! Mirrors the workspace-snapshot conventions: opaque Rust-owned handles via
//! `Box::into_raw`/`Box::from_raw`, null-safe accessors, borrowed snapshot text
//! that the caller copies before `*_free`, a thread-local last-error message,
//! and `u32` status codes. Text-buffer statuses live in a 100+ band so a Swift
//! `switch` never confuses them with workspace statuses.
//!
//! `open` reads a file into an owned buffer (so the buffer owns its bytes and
//! an external truncation can never fault the process); the platform layer
//! bounds the file size before calling in.

use std::ffi::c_char;
use std::io::Write;

use app_core::text_buffer::{Position, TextBuffer, TextBufferError};

use crate::{clear_last_error_message, set_last_error_message, string_from_c_str, LOCUS_STATUS_OK};

// Status codes, offset from the workspace band (0..=6) so they never collide.
pub const LOCUS_TEXT_STATUS_INVALID_ARGUMENT: u32 = 100;
pub const LOCUS_TEXT_STATUS_IO: u32 = 101;
pub const LOCUS_TEXT_STATUS_NOT_UTF8: u32 = 102;
pub const LOCUS_TEXT_STATUS_INVALID_OFFSET: u32 = 103;
pub const LOCUS_TEXT_STATUS_INVALID_RANGE: u32 = 104;
pub const LOCUS_TEXT_STATUS_INVALID_LINE: u32 = 105;

/// A buffer position in every coordinate the editor needs. `char_index` avoids
/// the C keyword `char`.
#[repr(C)]
pub struct LocusTextPosition {
    pub byte: usize,
    pub char_index: usize,
    pub utf16: usize,
    pub line: usize,
    pub column_utf16: usize,
}

/// Opaque Rust-owned text buffer handle.
pub struct LocusTextBuffer {
    buffer: TextBuffer,
}

/// Opaque Rust-owned snapshot of a line range's text. The text is length-counted
/// (not NUL-terminated) raw UTF-8, so an embedded NUL in the document is
/// preserved; the pointer is borrowed and invalidated by
/// `locus_text_snapshot_free`.
pub struct LocusTextSnapshot {
    text: Box<[u8]>,
    first_line: usize,
    line_count: usize,
}

impl LocusTextSnapshot {
    /// Builds a snapshot from owned UTF-8 bytes. Lets the read-only large-file
    /// FFI ([`crate::large_file`]) return this shared snapshot type so the
    /// platform side has one snapshot to read regardless of the backend.
    pub(crate) fn new(text: Box<[u8]>, first_line: usize, line_count: usize) -> Self {
        Self {
            text,
            first_line,
            line_count,
        }
    }
}

fn status_from_error(error: &TextBufferError) -> u32 {
    match error {
        TextBufferError::NotUtf8 => LOCUS_TEXT_STATUS_NOT_UTF8,
        TextBufferError::InvalidUtf16Offset { .. } => LOCUS_TEXT_STATUS_INVALID_OFFSET,
        TextBufferError::InvalidRange { .. } => LOCUS_TEXT_STATUS_INVALID_RANGE,
        TextBufferError::InvalidLine { .. } => LOCUS_TEXT_STATUS_INVALID_LINE,
    }
}

pub(crate) fn ffi_position(position: Position) -> LocusTextPosition {
    LocusTextPosition {
        byte: position.byte,
        char_index: position.char,
        utf16: position.utf16,
        line: position.line,
        column_utf16: position.column_utf16,
    }
}

// MARK: - Lifecycle

/// Opens a text file into a buffer. The file must be valid UTF-8; non-UTF-8
/// files return `LOCUS_TEXT_STATUS_NOT_UTF8` so the platform can decode the
/// bytes itself and call `locus_text_buffer_open_bytes`.
///
/// # Safety
///
/// `path` must be NULL or a valid NUL-terminated UTF-8 C string valid for the
/// call. `out_buffer` must point to caller-owned writable storage for a
/// `*mut LocusTextBuffer`. On success the caller owns the buffer and must
/// release it exactly once with `locus_text_buffer_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_open(
    path: *const c_char,
    out_buffer: *mut *mut LocusTextBuffer,
) -> u32 {
    clear_last_error_message();
    if out_buffer.is_null() {
        set_last_error_message("out_buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: out_buffer is non-null (checked above). Clear it so the caller's
    // pointer is never left stale on any failure path below.
    unsafe {
        *out_buffer = std::ptr::null_mut();
    }
    let Some(path) = string_from_c_str(path) else {
        set_last_error_message("path must be non-NULL UTF-8");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };

    match open_text_buffer(&path) {
        Ok(buffer) => finish_open(Ok(buffer), out_buffer),
        Err(OpenError::Io(message)) => {
            set_last_error_message(message);
            LOCUS_TEXT_STATUS_IO
        }
        Err(OpenError::Buffer(error)) => finish_open(Err(error), out_buffer),
    }
}

/// Why opening a file as a text buffer failed: a filesystem error (reported as
/// `LOCUS_TEXT_STATUS_IO`) versus the buffer rejecting the content (e.g. not
/// UTF-8), which maps to a specific text status.
#[derive(Debug)]
enum OpenError {
    Io(String),
    Buffer(TextBufferError),
}

/// Reads `path` into an owned buffer. The buffer owns its bytes, so a later
/// external truncation or rewrite of the file cannot fault the process; the
/// platform layer is responsible for bounding the file size before opening.
fn open_text_buffer(path: &str) -> Result<TextBuffer, OpenError> {
    let bytes = std::fs::read(path)
        .map_err(|error| OpenError::Io(format!("failed to read {path}: {error}")))?;
    TextBuffer::from_utf8_bytes(bytes).map_err(OpenError::Buffer)
}

/// Opens a buffer from already-UTF-8 bytes (the platform decodes legacy
/// encodings before calling this).
///
/// # Safety
///
/// `bytes` must point to `len` readable bytes, or be NULL when `len` is 0.
/// `out_buffer` must point to caller-owned writable storage for a
/// `*mut LocusTextBuffer`, released with `locus_text_buffer_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_open_bytes(
    bytes: *const u8,
    len: usize,
    out_buffer: *mut *mut LocusTextBuffer,
) -> u32 {
    clear_last_error_message();
    if out_buffer.is_null() {
        set_last_error_message("out_buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: out_buffer is non-null (checked above). Clear it so the caller's
    // pointer is never left stale on any failure path below.
    unsafe {
        *out_buffer = std::ptr::null_mut();
    }
    let owned = if len == 0 {
        Vec::new()
    } else if bytes.is_null() {
        set_last_error_message("bytes must not be NULL when len > 0");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    } else {
        // SAFETY: the caller guarantees `bytes` points to `len` readable bytes
        // for the duration of the call; we copy them into an owned Vec here.
        unsafe { std::slice::from_raw_parts(bytes, len) }.to_vec()
    };
    finish_open(TextBuffer::from_utf8_bytes(owned), out_buffer)
}

fn finish_open(
    result: Result<TextBuffer, TextBufferError>,
    out_buffer: *mut *mut LocusTextBuffer,
) -> u32 {
    match result {
        Ok(buffer) => {
            // SAFETY: out_buffer was checked non-null by the caller. Ownership
            // of the Box transfers to the caller, reclaimed by
            // locus_text_buffer_free.
            unsafe {
                *out_buffer = Box::into_raw(Box::new(LocusTextBuffer { buffer }));
            }
            LOCUS_STATUS_OK
        }
        Err(error) => {
            set_last_error_message(error.to_string());
            status_from_error(&error)
        }
    }
}

/// Releases a text buffer. Passing NULL is allowed and has no effect.
///
/// # Safety
///
/// `buffer` must be NULL or a live handle from `locus_text_buffer_open`/
/// `locus_text_buffer_open_bytes` that has not yet been freed. All snapshots
/// borrowed from it must already be freed.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_free(buffer: *mut LocusTextBuffer) {
    if buffer.is_null() {
        return;
    }
    // SAFETY: buffer was created by Box::into_raw in finish_open; rebuilding the
    // Box here returns ownership to Rust exactly once.
    unsafe {
        drop(Box::from_raw(buffer));
    }
}

// MARK: - Scalar queries (null-safe)

/// # Safety
/// `buffer` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_line_count(buffer: *const LocusTextBuffer) -> usize {
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    match unsafe { buffer.as_ref() } {
        Some(handle) => handle.buffer.line_count(),
        None => 0,
    }
}

/// # Safety
/// `buffer` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_byte_length(buffer: *const LocusTextBuffer) -> usize {
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    match unsafe { buffer.as_ref() } {
        Some(handle) => handle.buffer.byte_len(),
        None => 0,
    }
}

/// # Safety
/// `buffer` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_utf16_length(buffer: *const LocusTextBuffer) -> usize {
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    match unsafe { buffer.as_ref() } {
        Some(handle) => handle.buffer.utf16_len(),
        None => 0,
    }
}

/// # Safety
/// `buffer` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_revision(buffer: *const LocusTextBuffer) -> u64 {
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    match unsafe { buffer.as_ref() } {
        Some(handle) => handle.buffer.revision(),
        None => 0,
    }
}

/// # Safety
/// `buffer` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_is_dirty(buffer: *const LocusTextBuffer) -> bool {
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    match unsafe { buffer.as_ref() } {
        Some(handle) => handle.buffer.is_dirty(),
        None => false,
    }
}

/// Marks the buffer's current content as saved. NULL is a no-op.
///
/// # Safety
/// `buffer` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_mark_saved(buffer: *mut LocusTextBuffer) {
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    if let Some(handle) = unsafe { buffer.as_mut() } {
        handle.buffer.mark_saved();
    }
}

/// Writes the buffer's full content to the file at `path`, creating or
/// truncating it. The content is streamed through a buffered writer, so even a
/// multi-gigabyte document is written without being assembled in memory. The
/// caller is responsible for any atomic-rename / symlink policy (this writes
/// directly to `path`).
///
/// # Safety
/// `buffer` must be NULL or a live handle. `path` must be a NUL-terminated UTF-8
/// C string.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_write_path(
    buffer: *const LocusTextBuffer,
    path: *const c_char,
) -> u32 {
    clear_last_error_message();
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_ref() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    let Some(path) = string_from_c_str(path) else {
        set_last_error_message("path must be non-NULL UTF-8");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };

    let file = match std::fs::File::create(&path) {
        Ok(file) => file,
        Err(error) => {
            set_last_error_message(error.to_string());
            return LOCUS_TEXT_STATUS_IO;
        }
    };
    let mut writer = std::io::BufWriter::new(file);
    match handle
        .buffer
        .write_to(&mut writer)
        .and_then(|()| writer.flush())
    {
        Ok(()) => LOCUS_STATUS_OK,
        Err(error) => {
            set_last_error_message(error.to_string());
            LOCUS_TEXT_STATUS_IO
        }
    }
}

// MARK: - Save snapshot (immutable, background-writable)

/// Opaque, Rust-owned immutable snapshot of a [`LocusTextBuffer`]'s whole content,
/// taken with `locus_text_buffer_take_save_snapshot` for a background save.
/// Unlike `LocusTextSnapshot` (a borrowed line-range text block for viewport
/// reads), this owns a structurally-shared rope clone of the entire document:
/// cheap to take (`O(1)`, no content copy), isolated from later edits, and
/// `Send + Sync`, so the platform can write it on a background thread while the
/// user keeps editing the live buffer. Release it exactly once with
/// `locus_text_buffer_snapshot_free`.
pub struct LocusTextBufferSnapshot {
    snapshot: app_core::text_buffer::TextSnapshot,
}

/// Takes an immutable snapshot of the buffer's current content for a background
/// save and seals the current insert-coalescing run, so the buffer stays editable
/// during the write while the dirty flag remains correct (see
/// `locus_text_buffer_mark_saved_snapshot`). `O(1)`: a structurally-shared rope
/// clone, no content copy.
///
/// # Safety
/// `buffer` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextBufferSnapshot`. On success
/// the caller owns the snapshot and must release it exactly once with
/// `locus_text_buffer_snapshot_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_take_save_snapshot(
    buffer: *mut LocusTextBuffer,
    out_snapshot: *mut *mut LocusTextBufferSnapshot,
) -> u32 {
    clear_last_error_message();
    if out_snapshot.is_null() {
        set_last_error_message("out_snapshot must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: out_snapshot is non-null (checked above). Clear it so the caller's
    // pointer is never left stale on a failure path.
    unsafe {
        *out_snapshot = std::ptr::null_mut();
    }
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_mut() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    let snapshot = handle.buffer.snapshot_for_save();
    // SAFETY: out_snapshot is non-null (checked above).
    unsafe {
        *out_snapshot = Box::into_raw(Box::new(LocusTextBufferSnapshot { snapshot }));
    }
    LOCUS_STATUS_OK
}

/// Writes a save snapshot's full content to the file at `path`, creating or
/// truncating it, streamed through a buffered writer (no full-document buffer).
/// The snapshot is immutable and `Send + Sync`, so this may run on a background
/// thread while the originating buffer is edited. The caller owns any
/// atomic-rename / symlink policy (this writes directly to `path`).
///
/// # Safety
/// `snapshot` must be NULL or a live handle. `path` must be a NUL-terminated UTF-8
/// C string.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_snapshot_write_path(
    snapshot: *const LocusTextBufferSnapshot,
    path: *const c_char,
) -> u32 {
    clear_last_error_message();
    // SAFETY: snapshot is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { snapshot.as_ref() }) else {
        set_last_error_message("snapshot must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    let Some(path) = string_from_c_str(path) else {
        set_last_error_message("path must be non-NULL UTF-8");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };

    let file = match std::fs::File::create(&path) {
        Ok(file) => file,
        Err(error) => {
            set_last_error_message(error.to_string());
            return LOCUS_TEXT_STATUS_IO;
        }
    };
    let mut writer = std::io::BufWriter::new(file);
    match handle
        .snapshot
        .write_to(&mut writer)
        .and_then(|()| writer.flush())
    {
        Ok(()) => LOCUS_STATUS_OK,
        Err(error) => {
            set_last_error_message(error.to_string());
            LOCUS_TEXT_STATUS_IO
        }
    }
}

/// Marks the content captured by `snapshot` as the saved baseline, so a buffer
/// edited while the snapshot was being written stays dirty (its newer content is
/// not yet on disk) and undoing back to the saved content reads clean again. Pair
/// with `locus_text_buffer_take_save_snapshot`.
///
/// # Safety
/// `buffer` must be NULL or a live handle. `snapshot` must be NULL or a live
/// handle from `locus_text_buffer_take_save_snapshot`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_mark_saved_snapshot(
    buffer: *mut LocusTextBuffer,
    snapshot: *const LocusTextBufferSnapshot,
) -> u32 {
    clear_last_error_message();
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_mut() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    // SAFETY: snapshot is NULL or a live handle the caller still owns.
    let Some(snapshot) = (unsafe { snapshot.as_ref() }) else {
        set_last_error_message("snapshot must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    handle.buffer.mark_saved_snapshot(&snapshot.snapshot);
    LOCUS_STATUS_OK
}

/// Releases a save snapshot. NULL is a no-op.
///
/// # Safety
/// `snapshot` must be NULL or a live handle that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_snapshot_free(snapshot: *mut LocusTextBufferSnapshot) {
    if snapshot.is_null() {
        return;
    }
    // SAFETY: snapshot was created by Box::into_raw in take_save_snapshot.
    unsafe {
        drop(Box::from_raw(snapshot));
    }
}

// MARK: - Viewport read

/// Snapshots the text of lines `[start_line, start_line + count)` (clamped) as
/// one UTF-8 block, lines joined by `\n`.
///
/// # Safety
///
/// `buffer` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextSnapshot`; on success the
/// caller releases it with `locus_text_snapshot_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_snapshot_line_range(
    buffer: *const LocusTextBuffer,
    start_line: usize,
    count: usize,
    out_snapshot: *mut *mut LocusTextSnapshot,
) -> u32 {
    // SAFETY: forwards the caller's pointers unchanged; see the impl's contract.
    unsafe { snapshot_line_range_impl(buffer, start_line, count, None, out_snapshot) }
}

/// Like `locus_text_buffer_snapshot_line_range`, but returns at most
/// `max_bytes_per_line` bytes of any one line's content, so a file that is one
/// enormous line does not materialize that whole line. A viewer passes a cap
/// comfortably larger than what it can display.
///
/// # Safety
///
/// `buffer` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextSnapshot`; on success the
/// caller releases it with `locus_text_snapshot_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_snapshot_line_range_capped(
    buffer: *const LocusTextBuffer,
    start_line: usize,
    count: usize,
    max_bytes_per_line: usize,
    out_snapshot: *mut *mut LocusTextSnapshot,
) -> u32 {
    // SAFETY: forwards the caller's pointers unchanged; see the impl's contract.
    unsafe {
        snapshot_line_range_impl(
            buffer,
            start_line,
            count,
            Some(max_bytes_per_line),
            out_snapshot,
        )
    }
}

/// Snapshots the raw text of the UTF-16 range `[start_utf16, end_utf16)`, with no
/// line-terminator stripping. This reads just the visible window of one enormous
/// line (intra-line virtualization): the endpoints map to byte offsets in
/// `O(log n)`, so a window deep inside a multi-megabyte line is read without
/// materializing the line before it. The snapshot's line metadata is not
/// meaningful for a raw range and is reported as zero.
///
/// # Safety
///
/// `buffer` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextSnapshot`; on success the
/// caller releases it with `locus_text_snapshot_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_snapshot_utf16_range(
    buffer: *const LocusTextBuffer,
    start_utf16: usize,
    end_utf16: usize,
    out_snapshot: *mut *mut LocusTextSnapshot,
) -> u32 {
    clear_last_error_message();
    if out_snapshot.is_null() {
        set_last_error_message("out_snapshot must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: out_snapshot is non-null (checked above). Clear it so the caller's
    // pointer is never left stale on a failure path.
    unsafe {
        *out_snapshot = std::ptr::null_mut();
    }
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_ref() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };

    let text = handle.buffer.text_for_utf16_range(start_utf16, end_utf16);
    let snapshot = LocusTextSnapshot {
        text: text.into_bytes().into_boxed_slice(),
        first_line: 0,
        line_count: 0,
    };
    // SAFETY: out_snapshot was checked non-null; ownership transfers to caller.
    unsafe {
        *out_snapshot = Box::into_raw(Box::new(snapshot));
    }
    LOCUS_STATUS_OK
}

/// Shared body for the snapshot reads. `max_bytes_per_line` selects the capped
/// read when `Some`.
///
/// # Safety
///
/// `buffer` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextSnapshot`.
unsafe fn snapshot_line_range_impl(
    buffer: *const LocusTextBuffer,
    start_line: usize,
    count: usize,
    max_bytes_per_line: Option<usize>,
    out_snapshot: *mut *mut LocusTextSnapshot,
) -> u32 {
    clear_last_error_message();
    if out_snapshot.is_null() {
        set_last_error_message("out_snapshot must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: out_snapshot is non-null (checked above). Clear it so the caller's
    // pointer is never left stale on a failure path.
    unsafe {
        *out_snapshot = std::ptr::null_mut();
    }
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_ref() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };

    let total = handle.buffer.line_count();
    let text = match max_bytes_per_line {
        Some(cap) => handle
            .buffer
            .text_for_line_range_capped(start_line, count, cap),
        None => handle.buffer.text_for_line_range(start_line, count),
    };
    let returned = if start_line >= total {
        0
    } else {
        count.min(total - start_line)
    };
    let snapshot = LocusTextSnapshot {
        // Length-counted raw UTF-8; an embedded NUL stays intact (unlike a
        // sanitized C string), matching the buffer's truth source.
        text: text.into_bytes().into_boxed_slice(),
        first_line: start_line.min(total),
        line_count: returned,
    };
    // SAFETY: out_snapshot was checked non-null; ownership transfers to caller.
    unsafe {
        *out_snapshot = Box::into_raw(Box::new(snapshot));
    }
    LOCUS_STATUS_OK
}

/// Borrowed UTF-8 text of the snapshot. Invalidated by `locus_text_snapshot_free`.
///
/// # Safety
/// `snapshot` must be NULL or a live snapshot handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_snapshot_text(
    snapshot: *const LocusTextSnapshot,
) -> *const c_char {
    // SAFETY: snapshot is NULL or a live handle the caller still owns.
    match unsafe { snapshot.as_ref() } {
        Some(snapshot) => snapshot.text.as_ptr().cast::<c_char>(),
        None => std::ptr::null(),
    }
}

/// # Safety
/// `snapshot` must be NULL or a live snapshot handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_snapshot_byte_length(
    snapshot: *const LocusTextSnapshot,
) -> usize {
    // SAFETY: snapshot is NULL or a live handle the caller still owns.
    match unsafe { snapshot.as_ref() } {
        Some(snapshot) => snapshot.text.len(),
        None => 0,
    }
}

/// # Safety
/// `snapshot` must be NULL or a live snapshot handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_snapshot_first_line(
    snapshot: *const LocusTextSnapshot,
) -> usize {
    // SAFETY: snapshot is NULL or a live handle the caller still owns.
    match unsafe { snapshot.as_ref() } {
        Some(snapshot) => snapshot.first_line,
        None => 0,
    }
}

/// # Safety
/// `snapshot` must be NULL or a live snapshot handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_snapshot_line_count(
    snapshot: *const LocusTextSnapshot,
) -> usize {
    // SAFETY: snapshot is NULL or a live handle the caller still owns.
    match unsafe { snapshot.as_ref() } {
        Some(snapshot) => snapshot.line_count,
        None => 0,
    }
}

/// Releases a snapshot. NULL is a no-op.
///
/// # Safety
/// `snapshot` must be NULL or a live snapshot handle that has not been freed.
#[no_mangle]
pub unsafe extern "C" fn locus_text_snapshot_free(snapshot: *mut LocusTextSnapshot) {
    if snapshot.is_null() {
        return;
    }
    // SAFETY: snapshot was created by Box::into_raw above.
    unsafe {
        drop(Box::from_raw(snapshot));
    }
}

// MARK: - Position conversions

/// # Safety
///
/// `buffer` must be NULL or a live handle. `out_position` must point to
/// caller-owned writable storage for a `LocusTextPosition`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_position_for_utf16(
    buffer: *const LocusTextBuffer,
    utf16: usize,
    out_position: *mut LocusTextPosition,
) -> u32 {
    clear_last_error_message();
    if out_position.is_null() {
        set_last_error_message("out_position must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_ref() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    match handle.buffer.position_for_utf16(utf16) {
        Ok(position) => {
            // SAFETY: out_position was checked non-null above.
            unsafe {
                *out_position = ffi_position(position);
            }
            LOCUS_STATUS_OK
        }
        Err(error) => {
            set_last_error_message(error.to_string());
            status_from_error(&error)
        }
    }
}

/// # Safety
///
/// `buffer` must be NULL or a live handle. `out_position` must point to
/// caller-owned writable storage for a `LocusTextPosition`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_position_for_line_column(
    buffer: *const LocusTextBuffer,
    line: usize,
    column_utf16: usize,
    out_position: *mut LocusTextPosition,
) -> u32 {
    clear_last_error_message();
    if out_position.is_null() {
        set_last_error_message("out_position must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_ref() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    match handle.buffer.position_for_line_column(line, column_utf16) {
        Ok(position) => {
            // SAFETY: out_position was checked non-null above.
            unsafe {
                *out_position = ffi_position(position);
            }
            LOCUS_STATUS_OK
        }
        Err(error) => {
            set_last_error_message(error.to_string());
            status_from_error(&error)
        }
    }
}

// MARK: - Edits

/// Inserts NUL-free UTF-8 `text` at UTF-16 offset `at_utf16`. Because the text
/// is a C string it cannot carry an embedded NUL; use
/// `locus_text_buffer_insert_bytes` to insert arbitrary UTF-8 (including NUL).
///
/// # Safety
///
/// `buffer` must be NULL or a live handle. `text` must be NULL or a valid
/// NUL-terminated UTF-8 C string valid for the call.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_insert(
    buffer: *mut LocusTextBuffer,
    at_utf16: usize,
    text: *const c_char,
) -> u32 {
    clear_last_error_message();
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_mut() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    let Some(text) = string_from_c_str(text) else {
        set_last_error_message("text must be non-NULL UTF-8");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    match handle.buffer.insert(at_utf16, &text) {
        Ok(()) => LOCUS_STATUS_OK,
        Err(error) => {
            set_last_error_message(error.to_string());
            status_from_error(&error)
        }
    }
}

/// Inserts `len` UTF-8 `bytes` at UTF-16 offset `at_utf16`. Unlike
/// `locus_text_buffer_insert`, the bytes may contain embedded NUL. Invalid
/// UTF-8 is rejected with `LOCUS_TEXT_STATUS_NOT_UTF8`.
///
/// # Safety
///
/// `buffer` must be NULL or a live handle. `bytes` must point to `len` readable
/// bytes, or be NULL when `len` is 0.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_insert_bytes(
    buffer: *mut LocusTextBuffer,
    at_utf16: usize,
    bytes: *const u8,
    len: usize,
) -> u32 {
    clear_last_error_message();
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_mut() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    let slice = if len == 0 {
        &[][..]
    } else if bytes.is_null() {
        set_last_error_message("bytes must not be NULL when len > 0");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    } else {
        // SAFETY: the caller guarantees `bytes` points to `len` readable bytes
        // for the duration of the call.
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };
    let Ok(text) = std::str::from_utf8(slice) else {
        set_last_error_message("inserted bytes must be valid UTF-8");
        return LOCUS_TEXT_STATUS_NOT_UTF8;
    };
    match handle.buffer.insert(at_utf16, text) {
        Ok(()) => LOCUS_STATUS_OK,
        Err(error) => {
            set_last_error_message(error.to_string());
            status_from_error(&error)
        }
    }
}

/// Deletes the UTF-16 range `[start_utf16, end_utf16)`.
///
/// # Safety
/// `buffer` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_delete(
    buffer: *mut LocusTextBuffer,
    start_utf16: usize,
    end_utf16: usize,
) -> u32 {
    clear_last_error_message();
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_mut() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    match handle.buffer.delete(start_utf16, end_utf16) {
        Ok(()) => LOCUS_STATUS_OK,
        Err(error) => {
            set_last_error_message(error.to_string());
            status_from_error(&error)
        }
    }
}

/// Replaces the UTF-16 range `[start_utf16, end_utf16)` with `len` UTF-8 `bytes`
/// in one undo step. The bytes may contain embedded NUL; invalid UTF-8 is
/// rejected with `LOCUS_TEXT_STATUS_NOT_UTF8`.
///
/// # Safety
///
/// `buffer` must be NULL or a live handle. `bytes` must point to `len` readable
/// bytes, or be NULL when `len` is 0.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_replace(
    buffer: *mut LocusTextBuffer,
    start_utf16: usize,
    end_utf16: usize,
    bytes: *const u8,
    len: usize,
) -> u32 {
    clear_last_error_message();
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_mut() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    let slice = if len == 0 {
        &[][..]
    } else if bytes.is_null() {
        set_last_error_message("bytes must not be NULL when len > 0");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    } else {
        // SAFETY: the caller guarantees `bytes` points to `len` readable bytes
        // for the duration of the call.
        unsafe { std::slice::from_raw_parts(bytes, len) }
    };
    let Ok(text) = std::str::from_utf8(slice) else {
        set_last_error_message("replacement bytes must be valid UTF-8");
        return LOCUS_TEXT_STATUS_NOT_UTF8;
    };
    match handle.buffer.replace(start_utf16, end_utf16, text) {
        Ok(()) => LOCUS_STATUS_OK,
        Err(error) => {
            set_last_error_message(error.to_string());
            status_from_error(&error)
        }
    }
}

/// Undoes the most recent edit, writing whether anything was undone to
/// `out_did_undo` (which may be NULL).
///
/// # Safety
/// `buffer` must be NULL or a live handle. `out_did_undo` must be NULL or point
/// to caller-owned writable storage for a `bool`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_undo(
    buffer: *mut LocusTextBuffer,
    out_did_undo: *mut bool,
) -> u32 {
    clear_last_error_message();
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_mut() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    let did_undo = handle.buffer.undo();
    // SAFETY: out_did_undo is NULL or caller-owned writable storage.
    if let Some(slot) = unsafe { out_did_undo.as_mut() } {
        *slot = did_undo;
    }
    LOCUS_STATUS_OK
}

/// Redoes the most recently undone edit, writing whether anything was redone to
/// `out_did_redo` (which may be NULL).
///
/// # Safety
/// `buffer` must be NULL or a live handle. `out_did_redo` must be NULL or point
/// to caller-owned writable storage for a `bool`.
#[no_mangle]
pub unsafe extern "C" fn locus_text_buffer_redo(
    buffer: *mut LocusTextBuffer,
    out_did_redo: *mut bool,
) -> u32 {
    clear_last_error_message();
    // SAFETY: buffer is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { buffer.as_mut() }) else {
        set_last_error_message("buffer must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    let did_redo = handle.buffer.redo();
    // SAFETY: out_did_redo is NULL or caller-owned writable storage.
    if let Some(slot) = unsafe { out_did_redo.as_mut() } {
        *slot = did_redo;
    }
    LOCUS_STATUS_OK
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::ptr;

    /// Opens a buffer from bytes for testing, returning the raw handle.
    fn open(text: &str) -> *mut LocusTextBuffer {
        let mut handle: *mut LocusTextBuffer = ptr::null_mut();
        let status =
            unsafe { locus_text_buffer_open_bytes(text.as_ptr(), text.len(), &mut handle) };
        assert_eq!(status, LOCUS_STATUS_OK);
        assert!(!handle.is_null());
        handle
    }

    /// Reads a snapshot length-counted (it is not NUL-terminated), returning the
    /// raw bytes so an embedded NUL is observable.
    fn snapshot_bytes(snapshot: *mut LocusTextSnapshot) -> Vec<u8> {
        let ptr = unsafe { locus_text_snapshot_text(snapshot) };
        let len = unsafe { locus_text_snapshot_byte_length(snapshot) };
        unsafe { std::slice::from_raw_parts(ptr.cast::<u8>(), len) }.to_vec()
    }

    fn snapshot_all(handle: *mut LocusTextBuffer) -> String {
        let line_count = unsafe { locus_text_buffer_line_count(handle) };
        let mut snapshot: *mut LocusTextSnapshot = ptr::null_mut();
        let status =
            unsafe { locus_text_buffer_snapshot_line_range(handle, 0, line_count, &mut snapshot) };
        assert_eq!(status, LOCUS_STATUS_OK);
        let text = String::from_utf8(snapshot_bytes(snapshot)).unwrap();
        unsafe { locus_text_snapshot_free(snapshot) };
        text
    }

    #[test]
    fn opens_bytes_and_reports_metrics() {
        let handle = open("ab\ncde");
        assert_eq!(unsafe { locus_text_buffer_line_count(handle) }, 2);
        assert_eq!(unsafe { locus_text_buffer_byte_length(handle) }, 6);
        assert_eq!(unsafe { locus_text_buffer_utf16_length(handle) }, 6);
        assert_eq!(snapshot_all(handle), "ab\ncde");
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn capped_snapshot_truncates_long_lines() {
        let long = "x".repeat(5_000);
        let handle = open(&format!("a\n{long}\nb"));
        let mut snapshot: *mut LocusTextSnapshot = ptr::null_mut();
        let status =
            unsafe { locus_text_buffer_snapshot_line_range_capped(handle, 0, 3, 5, &mut snapshot) };
        assert_eq!(status, LOCUS_STATUS_OK);
        assert_eq!(snapshot_bytes(snapshot), b"a\nxxxxx\nb");
        unsafe { locus_text_snapshot_free(snapshot) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn utf16_range_snapshot_reads_a_window_within_a_huge_line() {
        // A window deep inside one enormous line, addressed by UTF-16 offsets.
        let huge = "y".repeat(1_000_000);
        let handle = open(&format!("head {huge} tail"));
        let mut snapshot: *mut LocusTextSnapshot = ptr::null_mut();
        // Read 4 UTF-16 units starting 100 units in (well inside the huge run).
        let status =
            unsafe { locus_text_buffer_snapshot_utf16_range(handle, 100, 104, &mut snapshot) };
        assert_eq!(status, LOCUS_STATUS_OK);
        assert_eq!(snapshot_bytes(snapshot), b"yyyy");
        unsafe { locus_text_snapshot_free(snapshot) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn utf16_range_snapshot_clamps_instead_of_erroring() {
        let handle = open("abc");
        // Inverted range → empty; past-the-end → clamped. Viewport reads clamp.
        let mut snapshot: *mut LocusTextSnapshot = ptr::null_mut();
        assert_eq!(
            unsafe { locus_text_buffer_snapshot_utf16_range(handle, 3, 1, &mut snapshot) },
            LOCUS_STATUS_OK
        );
        assert_eq!(snapshot_bytes(snapshot), b"");
        unsafe { locus_text_snapshot_free(snapshot) };

        let mut snapshot2: *mut LocusTextSnapshot = ptr::null_mut();
        assert_eq!(
            unsafe { locus_text_buffer_snapshot_utf16_range(handle, 1, 99, &mut snapshot2) },
            LOCUS_STATUS_OK
        );
        assert_eq!(snapshot_bytes(snapshot2), b"bc");
        unsafe { locus_text_snapshot_free(snapshot2) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn utf16_range_snapshot_rejects_null_buffer() {
        let mut snapshot: *mut LocusTextSnapshot = ptr::null_mut();
        let status =
            unsafe { locus_text_buffer_snapshot_utf16_range(ptr::null(), 0, 1, &mut snapshot) };
        assert_eq!(status, LOCUS_TEXT_STATUS_INVALID_ARGUMENT);
        assert!(snapshot.is_null());
    }

    #[test]
    fn snapshot_preserves_embedded_nul() {
        // A NUL is valid UTF-8 and the buffer keeps it; the length-counted
        // snapshot must not sanitize it away (it is not a C string).
        let bytes = b"a\0b";
        let mut handle: *mut LocusTextBuffer = ptr::null_mut();
        let status =
            unsafe { locus_text_buffer_open_bytes(bytes.as_ptr(), bytes.len(), &mut handle) };
        assert_eq!(status, LOCUS_STATUS_OK);
        let mut snapshot: *mut LocusTextSnapshot = ptr::null_mut();
        let status = unsafe { locus_text_buffer_snapshot_line_range(handle, 0, 1, &mut snapshot) };
        assert_eq!(status, LOCUS_STATUS_OK);
        assert_eq!(snapshot_bytes(snapshot), b"a\0b");
        unsafe { locus_text_snapshot_free(snapshot) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn rejects_invalid_utf8_bytes() {
        let bytes = [0xFFu8, 0xFE, 0x00];
        let mut handle: *mut LocusTextBuffer = ptr::null_mut();
        let status =
            unsafe { locus_text_buffer_open_bytes(bytes.as_ptr(), bytes.len(), &mut handle) };
        assert_eq!(status, LOCUS_TEXT_STATUS_NOT_UTF8);
        assert!(handle.is_null());
    }

    #[test]
    fn open_bytes_rejects_null_out_buffer() {
        let status = unsafe { locus_text_buffer_open_bytes(b"x".as_ptr(), 1, ptr::null_mut()) };
        assert_eq!(status, LOCUS_TEXT_STATUS_INVALID_ARGUMENT);
    }

    #[test]
    fn open_bytes_allows_empty() {
        let mut handle: *mut LocusTextBuffer = ptr::null_mut();
        let status = unsafe { locus_text_buffer_open_bytes(ptr::null(), 0, &mut handle) };
        assert_eq!(status, LOCUS_STATUS_OK);
        assert_eq!(unsafe { locus_text_buffer_line_count(handle) }, 1);
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn opens_a_file_from_disk() {
        let dir = std::env::temp_dir().join(format!("locus-ffi-text-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("doc.txt");
        std::fs::write(&path, "hello\nworld").unwrap();
        let c_path = CString::new(path.to_string_lossy().as_bytes()).unwrap();

        let mut handle: *mut LocusTextBuffer = ptr::null_mut();
        let status = unsafe { locus_text_buffer_open(c_path.as_ptr(), &mut handle) };
        assert_eq!(status, LOCUS_STATUS_OK);
        assert_eq!(snapshot_all(handle), "hello\nworld");
        unsafe { locus_text_buffer_free(handle) };
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn open_missing_file_reports_io() {
        let c_path = CString::new("/nonexistent/locus/does-not-exist.txt").unwrap();
        let mut handle: *mut LocusTextBuffer = ptr::null_mut();
        let status = unsafe { locus_text_buffer_open(c_path.as_ptr(), &mut handle) };
        assert_eq!(status, LOCUS_TEXT_STATUS_IO);
        assert!(handle.is_null());
    }

    fn temp_file(label: &str, contents: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "locus-ffi-open-{}-{}-{}",
            std::process::id(),
            id,
            label
        ));
        std::fs::write(&path, contents).unwrap();
        path
    }

    #[test]
    fn open_reads_a_multiline_file() {
        let path = temp_file("read.txt", "alpha\nbeta\ngamma");
        let buffer = open_text_buffer(&path.to_string_lossy()).expect("opens file");
        assert_eq!(buffer.line_count(), 3);
        assert_eq!(buffer.text_for_line_range(0, 3), "alpha\nbeta\ngamma");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn open_empty_file_yields_a_single_empty_line() {
        let path = temp_file("empty.txt", "");
        let buffer = open_text_buffer(&path.to_string_lossy()).expect("opens empty file");
        assert_eq!(buffer.line_count(), 1);
        assert_eq!(buffer.byte_len(), 0);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn open_rejects_non_utf8() {
        let path = temp_file("binary.bin", "");
        std::fs::write(&path, [0xFFu8, 0xFE, 0x00]).unwrap();
        let result = open_text_buffer(&path.to_string_lossy());
        assert!(
            matches!(result, Err(OpenError::Buffer(TextBufferError::NotUtf8))),
            "expected NotUtf8"
        );
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn inserts_and_deletes_with_dirty_tracking() {
        let handle = open("ac");
        assert!(!unsafe { locus_text_buffer_is_dirty(handle) });

        let text = CString::new("b").unwrap();
        assert_eq!(
            unsafe { locus_text_buffer_insert(handle, 1, text.as_ptr()) },
            LOCUS_STATUS_OK
        );
        assert_eq!(snapshot_all(handle), "abc");
        assert!(unsafe { locus_text_buffer_is_dirty(handle) });

        assert_eq!(
            unsafe { locus_text_buffer_delete(handle, 0, 1) },
            LOCUS_STATUS_OK
        );
        assert_eq!(snapshot_all(handle), "bc");

        unsafe { locus_text_buffer_mark_saved(handle) };
        assert!(!unsafe { locus_text_buffer_is_dirty(handle) });
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn replace_swaps_a_range_in_one_undo_step() {
        let handle = open("hello");
        let bytes = "bye".as_bytes();
        assert_eq!(
            unsafe { locus_text_buffer_replace(handle, 0, 5, bytes.as_ptr(), bytes.len()) },
            LOCUS_STATUS_OK
        );
        assert_eq!(snapshot_all(handle), "bye");

        let mut did = false;
        unsafe { locus_text_buffer_undo(handle, &mut did) };
        assert!(did);
        assert_eq!(snapshot_all(handle), "hello"); // one undo restores the whole range
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn replace_reversed_range_reports_invalid_range() {
        let handle = open("hello");
        let bytes = "x".as_bytes();
        assert_eq!(
            unsafe { locus_text_buffer_replace(handle, 3, 1, bytes.as_ptr(), bytes.len()) },
            LOCUS_TEXT_STATUS_INVALID_RANGE
        );
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn write_path_writes_edited_content_to_disk() {
        let handle = open("hello");
        let bytes = "bye".as_bytes();
        unsafe { locus_text_buffer_replace(handle, 0, 5, bytes.as_ptr(), bytes.len()) };

        let mut path = std::env::temp_dir();
        path.push("locus-ffi-write-path-test.txt");
        let c_path = CString::new(path.to_string_lossy().as_bytes()).unwrap();
        assert_eq!(
            unsafe { locus_text_buffer_write_path(handle, c_path.as_ptr()) },
            LOCUS_STATUS_OK
        );
        assert_eq!(std::fs::read_to_string(&path).expect("read back"), "bye");
        let _ = std::fs::remove_file(&path);
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn save_snapshot_writes_content_to_disk() {
        let handle = open("hello");
        let mut snapshot: *mut LocusTextBufferSnapshot = ptr::null_mut();
        assert_eq!(
            unsafe { locus_text_buffer_take_save_snapshot(handle, &mut snapshot) },
            LOCUS_STATUS_OK
        );
        assert!(!snapshot.is_null());

        let mut path = std::env::temp_dir();
        path.push(format!(
            "locus-ffi-save-snapshot-{}.txt",
            std::process::id()
        ));
        let c_path = CString::new(path.to_string_lossy().as_bytes()).unwrap();
        assert_eq!(
            unsafe { locus_text_buffer_snapshot_write_path(snapshot, c_path.as_ptr()) },
            LOCUS_STATUS_OK
        );
        assert_eq!(std::fs::read_to_string(&path).expect("read back"), "hello");

        let _ = std::fs::remove_file(&path);
        unsafe { locus_text_buffer_snapshot_free(snapshot) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn save_snapshot_is_isolated_from_edits_during_write() {
        let handle = open("hello");
        let mut snapshot: *mut LocusTextBufferSnapshot = ptr::null_mut();
        assert_eq!(
            unsafe { locus_text_buffer_take_save_snapshot(handle, &mut snapshot) },
            LOCUS_STATUS_OK
        );
        // Edit the live buffer after taking the snapshot.
        let world = CString::new("world").unwrap();
        unsafe { locus_text_buffer_insert(handle, 5, world.as_ptr()) };

        let mut path = std::env::temp_dir();
        path.push(format!("locus-ffi-save-iso-{}.txt", std::process::id()));
        let c_path = CString::new(path.to_string_lossy().as_bytes()).unwrap();
        assert_eq!(
            unsafe { locus_text_buffer_snapshot_write_path(snapshot, c_path.as_ptr()) },
            LOCUS_STATUS_OK
        );
        // The snapshot wrote its captured content, not the live "helloworld".
        assert_eq!(std::fs::read_to_string(&path).expect("read back"), "hello");
        assert_eq!(snapshot_all(handle), "helloworld");

        let _ = std::fs::remove_file(&path);
        unsafe { locus_text_buffer_snapshot_free(snapshot) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn mark_saved_snapshot_keeps_buffer_dirty_when_edited_during_save() {
        let handle = open("");
        let hello = CString::new("hello").unwrap();
        unsafe { locus_text_buffer_insert(handle, 0, hello.as_ptr()) };
        assert!(unsafe { locus_text_buffer_is_dirty(handle) });

        let mut snapshot: *mut LocusTextBufferSnapshot = ptr::null_mut();
        assert_eq!(
            unsafe { locus_text_buffer_take_save_snapshot(handle, &mut snapshot) },
            LOCUS_STATUS_OK
        );
        // Edit during the "write".
        let world = CString::new("world").unwrap();
        unsafe { locus_text_buffer_insert(handle, 5, world.as_ptr()) };
        assert_eq!(
            unsafe { locus_text_buffer_mark_saved_snapshot(handle, snapshot) },
            LOCUS_STATUS_OK
        );
        // Only "hello" reached disk, so the live "helloworld" stays dirty.
        assert!(unsafe { locus_text_buffer_is_dirty(handle) });

        unsafe { locus_text_buffer_snapshot_free(snapshot) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn mark_saved_snapshot_clears_dirty_when_unchanged() {
        let handle = open("");
        let hello = CString::new("hello").unwrap();
        unsafe { locus_text_buffer_insert(handle, 0, hello.as_ptr()) };

        let mut snapshot: *mut LocusTextBufferSnapshot = ptr::null_mut();
        assert_eq!(
            unsafe { locus_text_buffer_take_save_snapshot(handle, &mut snapshot) },
            LOCUS_STATUS_OK
        );
        assert_eq!(
            unsafe { locus_text_buffer_mark_saved_snapshot(handle, snapshot) },
            LOCUS_STATUS_OK
        );
        assert!(!unsafe { locus_text_buffer_is_dirty(handle) });

        unsafe { locus_text_buffer_snapshot_free(snapshot) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn save_snapshot_rejects_null_handles() {
        // NULL buffer -> INVALID_ARGUMENT, out pointer cleared.
        let mut snapshot: *mut LocusTextBufferSnapshot = ptr::null_mut();
        assert_eq!(
            unsafe { locus_text_buffer_take_save_snapshot(ptr::null_mut(), &mut snapshot) },
            LOCUS_TEXT_STATUS_INVALID_ARGUMENT
        );
        assert!(snapshot.is_null());

        let handle = open("x");
        // NULL out pointer -> INVALID_ARGUMENT.
        assert_eq!(
            unsafe { locus_text_buffer_take_save_snapshot(handle, ptr::null_mut()) },
            LOCUS_TEXT_STATUS_INVALID_ARGUMENT
        );
        // NULL snapshot to write / mark -> INVALID_ARGUMENT; NULL free is a no-op.
        let c_path = CString::new("/dev/null").unwrap();
        assert_eq!(
            unsafe { locus_text_buffer_snapshot_write_path(ptr::null(), c_path.as_ptr()) },
            LOCUS_TEXT_STATUS_INVALID_ARGUMENT
        );
        assert_eq!(
            unsafe { locus_text_buffer_mark_saved_snapshot(handle, ptr::null()) },
            LOCUS_TEXT_STATUS_INVALID_ARGUMENT
        );
        unsafe { locus_text_buffer_snapshot_free(ptr::null_mut()) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn undo_and_redo_round_trip() {
        let handle = open("ac");
        let text = CString::new("b").unwrap();
        unsafe { locus_text_buffer_insert(handle, 1, text.as_ptr()) };
        assert_eq!(snapshot_all(handle), "abc");

        let mut did = false;
        assert_eq!(
            unsafe { locus_text_buffer_undo(handle, &mut did) },
            LOCUS_STATUS_OK
        );
        assert!(did);
        assert_eq!(snapshot_all(handle), "ac");

        assert_eq!(
            unsafe { locus_text_buffer_redo(handle, &mut did) },
            LOCUS_STATUS_OK
        );
        assert!(did);
        assert_eq!(snapshot_all(handle), "abc");
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn position_for_utf16_fills_struct() {
        let handle = open("ab\ncde");
        let mut position = LocusTextPosition {
            byte: 0,
            char_index: 0,
            utf16: 0,
            line: 0,
            column_utf16: 0,
        };
        let status = unsafe { locus_text_buffer_position_for_utf16(handle, 4, &mut position) };
        assert_eq!(status, LOCUS_STATUS_OK);
        assert_eq!(position.line, 1);
        assert_eq!(position.column_utf16, 1);
        assert_eq!(position.byte, 4);
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn invalid_offset_reports_status() {
        let handle = open("ab");
        let mut position = LocusTextPosition {
            byte: 0,
            char_index: 0,
            utf16: 0,
            line: 0,
            column_utf16: 0,
        };
        let status = unsafe { locus_text_buffer_position_for_utf16(handle, 99, &mut position) };
        assert_eq!(status, LOCUS_TEXT_STATUS_INVALID_OFFSET);
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn null_handle_accessors_are_safe() {
        let null = ptr::null::<LocusTextBuffer>();
        assert_eq!(unsafe { locus_text_buffer_line_count(null) }, 0);
        assert_eq!(unsafe { locus_text_buffer_utf16_length(null) }, 0);
        assert!(!unsafe { locus_text_buffer_is_dirty(null) });
        // Free of NULL is a no-op.
        unsafe { locus_text_buffer_free(ptr::null_mut()) };
        unsafe { locus_text_snapshot_free(ptr::null_mut()) };
    }

    #[test]
    fn delete_reversed_range_reports_invalid_range() {
        let handle = open("abc");
        assert_eq!(
            unsafe { locus_text_buffer_delete(handle, 2, 1) },
            LOCUS_TEXT_STATUS_INVALID_RANGE
        );
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn insert_at_invalid_offset_reports_status() {
        let handle = open("ab");
        let text = CString::new("x").unwrap();
        assert_eq!(
            unsafe { locus_text_buffer_insert(handle, 99, text.as_ptr()) },
            LOCUS_TEXT_STATUS_INVALID_OFFSET
        );
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn position_for_line_column_clamps_and_validates() {
        let handle = open("abc\nde");
        let mut position = LocusTextPosition {
            byte: 0,
            char_index: 0,
            utf16: 0,
            line: 0,
            column_utf16: 0,
        };
        // Column past the line clamps to the line end.
        assert_eq!(
            unsafe { locus_text_buffer_position_for_line_column(handle, 0, 99, &mut position) },
            LOCUS_STATUS_OK
        );
        assert_eq!(position.column_utf16, 3);
        // Line past the last line is rejected.
        assert_eq!(
            unsafe { locus_text_buffer_position_for_line_column(handle, 9, 0, &mut position) },
            LOCUS_TEXT_STATUS_INVALID_LINE
        );
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn snapshot_past_end_is_empty_and_clamps_first_line() {
        let handle = open("a\nb");
        let mut snapshot: *mut LocusTextSnapshot = ptr::null_mut();
        assert_eq!(
            unsafe { locus_text_buffer_snapshot_line_range(handle, 5, 3, &mut snapshot) },
            LOCUS_STATUS_OK
        );
        assert_eq!(unsafe { locus_text_snapshot_first_line(snapshot) }, 2);
        assert_eq!(unsafe { locus_text_snapshot_line_count(snapshot) }, 0);
        assert_eq!(unsafe { locus_text_snapshot_byte_length(snapshot) }, 0);
        unsafe { locus_text_snapshot_free(snapshot) };
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn embedded_nul_is_preserved_in_snapshot_text() {
        // NUL is valid UTF-8 content; the length-counted snapshot keeps it
        // rather than sanitizing to U+FFFD (it is not a C string).
        let handle = open("a\u{0}b");
        assert_eq!(snapshot_all(handle), "a\u{0}b");
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn insert_bytes_allows_embedded_nul() {
        let handle = open("ac");
        let bytes = b"X\0Y"; // valid UTF-8 carrying an embedded NUL
        assert_eq!(
            unsafe { locus_text_buffer_insert_bytes(handle, 1, bytes.as_ptr(), bytes.len()) },
            LOCUS_STATUS_OK
        );
        // The buffer keeps the NUL and so does the length-counted snapshot.
        assert_eq!(snapshot_all(handle), "aX\u{0}Yc");
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn insert_bytes_rejects_invalid_utf8() {
        let handle = open("ab");
        let bad = [0xFFu8];
        assert_eq!(
            unsafe { locus_text_buffer_insert_bytes(handle, 0, bad.as_ptr(), bad.len()) },
            LOCUS_TEXT_STATUS_NOT_UTF8
        );
        unsafe { locus_text_buffer_free(handle) };
    }

    #[test]
    fn open_failure_clears_out_buffer() {
        // A non-null sentinel must be reset to null on failure so the caller
        // never sees a stale pointer.
        let mut handle = std::ptr::NonNull::<LocusTextBuffer>::dangling().as_ptr();
        let bad = [0xFFu8];
        let status = unsafe { locus_text_buffer_open_bytes(bad.as_ptr(), bad.len(), &mut handle) };
        assert_eq!(status, LOCUS_TEXT_STATUS_NOT_UTF8);
        assert!(handle.is_null());
    }
}
