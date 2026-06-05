//! C ABI for the arbitrary-size text buffer (see `app_core::text_buffer`).
//!
//! Mirrors the workspace-snapshot conventions: opaque Rust-owned handles via
//! `Box::into_raw`/`Box::from_raw`, null-safe accessors, borrowed snapshot text
//! that the caller copies before `*_free`, a thread-local last-error message,
//! and `u32` status codes. Text-buffer statuses live in a 100+ band so a Swift
//! `switch` never confuses them with workspace statuses.
//!
//! `open` currently reads the whole file into memory; memory mapping for huge
//! files lands next behind the `ContentBytes` seam, with no ABI change.

use std::ffi::{c_char, CString};

use app_core::text_buffer::{Position, TextBuffer, TextBufferError};

use crate::{
    clear_last_error_message, sanitized_cstring, set_last_error_message, string_from_c_str,
    LOCUS_STATUS_OK,
};

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

/// Opaque Rust-owned snapshot of a line range's text. The text pointer is
/// borrowed and is invalidated by `locus_text_snapshot_free`.
pub struct LocusTextSnapshot {
    text: CString,
    first_line: usize,
    line_count: usize,
}

fn status_from_error(error: &TextBufferError) -> u32 {
    match error {
        TextBufferError::NotUtf8 => LOCUS_TEXT_STATUS_NOT_UTF8,
        TextBufferError::InvalidUtf16Offset { .. } => LOCUS_TEXT_STATUS_INVALID_OFFSET,
        TextBufferError::InvalidRange { .. } => LOCUS_TEXT_STATUS_INVALID_RANGE,
        TextBufferError::InvalidLine { .. } => LOCUS_TEXT_STATUS_INVALID_LINE,
    }
}

fn ffi_position(position: Position) -> LocusTextPosition {
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

    // Reads the whole file for now; memory mapping for huge files follows.
    let bytes = match std::fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) => {
            set_last_error_message(format!("failed to read {path}: {error}"));
            return LOCUS_TEXT_STATUS_IO;
        }
    };
    finish_open(bytes, out_buffer)
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
    finish_open(owned, out_buffer)
}

fn finish_open(bytes: Vec<u8>, out_buffer: *mut *mut LocusTextBuffer) -> u32 {
    match TextBuffer::from_utf8_bytes(bytes) {
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
    let text = handle.buffer.text_for_line_range(start_line, count);
    let returned = if start_line >= total {
        0
    } else {
        count.min(total - start_line)
    };
    let snapshot = LocusTextSnapshot {
        text: sanitized_cstring(&text),
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
        Some(snapshot) => snapshot.text.as_ptr(),
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
        Some(snapshot) => snapshot.text.as_bytes().len(),
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

    fn snapshot_all(handle: *mut LocusTextBuffer) -> String {
        let line_count = unsafe { locus_text_buffer_line_count(handle) };
        let mut snapshot: *mut LocusTextSnapshot = ptr::null_mut();
        let status =
            unsafe { locus_text_buffer_snapshot_line_range(handle, 0, line_count, &mut snapshot) };
        assert_eq!(status, LOCUS_STATUS_OK);
        let text = unsafe {
            std::ffi::CStr::from_ptr(locus_text_snapshot_text(snapshot))
                .to_str()
                .unwrap()
                .to_owned()
        };
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
    fn embedded_nul_is_sanitized_in_snapshot_text() {
        // NUL is valid UTF-8 content, but cannot cross as a C string, so the
        // snapshot replaces it with U+FFFD.
        let handle = open("a\u{0}b");
        assert_eq!(snapshot_all(handle), "a\u{FFFD}b");
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
        // The buffer keeps the NUL; the snapshot sanitizes it to U+FFFD.
        assert_eq!(snapshot_all(handle), "aX\u{FFFD}Yc");
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
