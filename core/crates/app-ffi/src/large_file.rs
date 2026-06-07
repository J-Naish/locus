//! C ABI for the read-only, line-indexed large-file viewer (see
//! [`app_core::line_index`]).
//!
//! A file too large to load into an editable buffer is opened here: it is
//! scanned once to build a sparse line index, then line ranges are served by
//! reading only the needed window via positioned reads (`pread`). An external
//! truncation surfaces as a short read, never a fault, so a concurrent rewrite
//! can never crash the process with `SIGBUS`.
//!
//! Positioned reads are Unix-only; macOS is the first target. A Windows core
//! would supply a `seek_read`-backed source behind the same trait.

#![cfg(unix)]

use std::ffi::c_char;
use std::fs::File;
use std::io;
use std::os::unix::fs::FileExt;

use app_core::line_index::{ByteSource, LineIndex};

use crate::text_buffer::{
    ffi_position, LocusTextPosition, LocusTextSnapshot, LOCUS_TEXT_STATUS_INVALID_ARGUMENT,
    LOCUS_TEXT_STATUS_IO,
};
use crate::{clear_last_error_message, set_last_error_message, string_from_c_str, LOCUS_STATUS_OK};

/// A file read through positioned reads. `read_at` returns however many bytes
/// are present (a short slice at end of input or if the file shrank) rather than
/// faulting, so a concurrent truncation is a recoverable short read.
struct FileByteSource {
    file: File,
    len: u64,
}

impl FileByteSource {
    fn open(path: &str) -> io::Result<Self> {
        let file = File::open(path)?;
        let len = file.metadata()?.len();
        Ok(Self { file, len })
    }
}

impl ByteSource for FileByteSource {
    fn len(&self) -> u64 {
        self.len
    }

    fn read_at(&self, offset: u64, len: usize) -> io::Result<Vec<u8>> {
        if offset >= self.len || len == 0 {
            return Ok(Vec::new());
        }
        let want = (self.len - offset).min(len as u64) as usize;
        let mut buffer = vec![0u8; want];
        let mut filled = 0;
        while filled < want {
            match self
                .file
                .read_at(&mut buffer[filled..], offset + filled as u64)
            {
                Ok(0) => break, // end of input / file shrank under us
                Ok(read) => filled += read,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        buffer.truncate(filled);
        Ok(buffer)
    }
}

/// Opaque, Rust-owned handle to a read-only line-indexed file.
pub struct LocusLargeFile {
    index: LineIndex<FileByteSource>,
}

/// Opens `path` as a read-only, line-indexed large file: scans it once to build a
/// sparse line index, then serves line ranges by reading only the needed window.
/// Use this for files too large to load into an editable buffer.
///
/// # Safety
///
/// `path` must be NULL or a valid NUL-terminated UTF-8 C string valid for the
/// call. `out_file` must point to caller-owned writable storage for a
/// `*mut LocusLargeFile`; on success the caller releases it exactly once with
/// `locus_large_file_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_open(
    path: *const c_char,
    out_file: *mut *mut LocusLargeFile,
) -> u32 {
    clear_last_error_message();
    if out_file.is_null() {
        set_last_error_message("out_file must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: out_file is non-null (checked above). Clear it so the caller's
    // pointer is never left stale on any failure path below.
    unsafe {
        *out_file = std::ptr::null_mut();
    }
    let Some(path) = string_from_c_str(path) else {
        set_last_error_message("path must be non-NULL UTF-8");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };

    let source = match FileByteSource::open(&path) {
        Ok(source) => source,
        Err(error) => {
            set_last_error_message(format!("failed to open {path}: {error}"));
            return LOCUS_TEXT_STATUS_IO;
        }
    };
    let index = match LineIndex::build(source) {
        Ok(index) => index,
        Err(error) => {
            set_last_error_message(format!("failed to index {path}: {error}"));
            return LOCUS_TEXT_STATUS_IO;
        }
    };
    // SAFETY: out_file was checked non-null; ownership transfers to the caller.
    unsafe {
        *out_file = Box::into_raw(Box::new(LocusLargeFile { index }));
    }
    LOCUS_STATUS_OK
}

/// Releases a large-file handle. NULL is a no-op.
///
/// # Safety
///
/// `file` must be NULL or a live handle created by `locus_large_file_open` that
/// has not already been freed.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_free(file: *mut LocusLargeFile) {
    if file.is_null() {
        return;
    }
    // SAFETY: file was created by Box::into_raw in locus_large_file_open.
    unsafe {
        drop(Box::from_raw(file));
    }
}

/// Total number of lines. Returns 0 for a NULL handle.
///
/// # Safety
///
/// `file` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_line_count(file: *const LocusLargeFile) -> usize {
    // SAFETY: file is NULL or a live handle the caller still owns.
    match unsafe { file.as_ref() } {
        Some(file) => file.index.line_count(),
        None => 0,
    }
}

/// Total length of the file in bytes. Returns 0 for a NULL handle.
///
/// # Safety
///
/// `file` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_byte_length(file: *const LocusLargeFile) -> u64 {
    // SAFETY: file is NULL or a live handle the caller still owns.
    match unsafe { file.as_ref() } {
        Some(file) => file.index.byte_len(),
        None => 0,
    }
}

/// Total number of UTF-16 code units in the file. Returned as `usize` to mirror
/// `locus_text_buffer_utf16_length`, so a viewer maps selections the same way
/// regardless of backend. Returns 0 for a NULL handle.
///
/// # Safety
///
/// `file` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_utf16_length(file: *const LocusLargeFile) -> usize {
    // SAFETY: file is NULL or a live handle the caller still owns.
    match unsafe { file.as_ref() } {
        Some(file) => file.index.utf16_len() as usize,
        None => 0,
    }
}

/// Snapshots the text of lines `[start_line, start_line + count)` (clamped) by
/// reading only that window from the file, lines joined by `\n`. On success
/// writes a borrowed snapshot the caller releases with `locus_text_snapshot_free`.
///
/// # Safety
///
/// `file` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextSnapshot`.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_snapshot_line_range(
    file: *const LocusLargeFile,
    start_line: usize,
    count: usize,
    out_snapshot: *mut *mut LocusTextSnapshot,
) -> u32 {
    // SAFETY: forwards the caller's pointers unchanged; see the impl's contract.
    unsafe { snapshot_line_range_impl(file, start_line, count, None, out_snapshot) }
}

/// Like `locus_large_file_snapshot_line_range`, but returns at most
/// `max_bytes_per_line` bytes of any one line's content, so a file that is one
/// enormous line is not materialized just to paint a band. A viewer passes a cap
/// comfortably larger than what it can display.
///
/// # Safety
///
/// `file` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextSnapshot`.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_snapshot_line_range_capped(
    file: *const LocusLargeFile,
    start_line: usize,
    count: usize,
    max_bytes_per_line: usize,
    out_snapshot: *mut *mut LocusTextSnapshot,
) -> u32 {
    // SAFETY: forwards the caller's pointers unchanged; see the impl's contract.
    unsafe {
        snapshot_line_range_impl(
            file,
            start_line,
            count,
            Some(max_bytes_per_line),
            out_snapshot,
        )
    }
}

/// Shared body for the windowed line-range reads. `max_bytes_per_line` selects
/// the capped read when `Some`.
///
/// # Safety
///
/// `file` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextSnapshot`.
unsafe fn snapshot_line_range_impl(
    file: *const LocusLargeFile,
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
    // SAFETY: file is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { file.as_ref() }) else {
        set_last_error_message("file must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };

    let total = handle.index.line_count();
    let text = match max_bytes_per_line {
        Some(cap) => handle
            .index
            .text_for_line_range_capped(start_line, count, cap),
        None => handle.index.text_for_line_range(start_line, count),
    };
    let text = match text {
        Ok(text) => text,
        Err(error) => {
            set_last_error_message(format!("failed to read line range: {error}"));
            return LOCUS_TEXT_STATUS_IO;
        }
    };
    let returned = if start_line >= total {
        0
    } else {
        count.min(total - start_line)
    };
    let snapshot = LocusTextSnapshot::new(
        text.into_bytes().into_boxed_slice(),
        start_line.min(total),
        returned,
    );
    // SAFETY: out_snapshot was checked non-null; ownership transfers to caller.
    unsafe {
        *out_snapshot = Box::into_raw(Box::new(snapshot));
    }
    LOCUS_STATUS_OK
}

/// Snapshots the raw text of the UTF-16 range `[start_utf16, end_utf16)`, with no
/// line-terminator stripping — used to copy a selection within or across lines.
/// The endpoints are mapped by scanning forward from the nearest line checkpoint
/// (the index is checkpointed by line, not by byte), so a within-line seek is
/// linear in the enclosing line's length; the platform refuses a file with a
/// pathologically long single line, which keeps that bound small. As a viewport
/// read it clamps rather than erroring: offsets past the end are clamped, an
/// endpoint inside a surrogate pair is floored to that character's start, and an
/// inverted range yields empty text. The snapshot's line metadata is not
/// meaningful here and is reported as zero.
///
/// # Safety
///
/// `file` must be NULL or a live handle. `out_snapshot` must point to
/// caller-owned writable storage for a `*mut LocusTextSnapshot`.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_snapshot_utf16_range(
    file: *const LocusLargeFile,
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
    // SAFETY: file is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { file.as_ref() }) else {
        set_last_error_message("file must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };

    let text = match handle
        .index
        .text_for_utf16_range(start_utf16 as u64, end_utf16 as u64)
    {
        Ok(text) => text,
        Err(error) => {
            set_last_error_message(format!("failed to read utf16 range: {error}"));
            return LOCUS_TEXT_STATUS_IO;
        }
    };
    let snapshot = LocusTextSnapshot::new(text.into_bytes().into_boxed_slice(), 0, 0);
    // SAFETY: out_snapshot was checked non-null; ownership transfers to caller.
    unsafe {
        *out_snapshot = Box::into_raw(Box::new(snapshot));
    }
    LOCUS_STATUS_OK
}

/// Maps a UTF-16 offset to a full position. Unlike the editable text buffer's
/// equivalent, this is a viewport read and never rejects the offset: an offset
/// past the end is clamped to the end, and an offset inside a surrogate pair is
/// floored to that character's start. Only a NULL handle/`out_position` or an
/// underlying read error is reported. Writes `*out_position` on success.
///
/// # Safety
///
/// `file` must be NULL or a live handle. `out_position` must point to
/// caller-owned writable storage for a `LocusTextPosition`.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_position_for_utf16(
    file: *const LocusLargeFile,
    utf16: usize,
    out_position: *mut LocusTextPosition,
) -> u32 {
    clear_last_error_message();
    if out_position.is_null() {
        set_last_error_message("out_position must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: file is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { file.as_ref() }) else {
        set_last_error_message("file must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    match handle.index.position_for_utf16(utf16 as u64) {
        Ok(position) => {
            // SAFETY: out_position was checked non-null above.
            unsafe {
                *out_position = ffi_position(position);
            }
            LOCUS_STATUS_OK
        }
        Err(error) => {
            set_last_error_message(format!("failed to map utf16 offset: {error}"));
            LOCUS_TEXT_STATUS_IO
        }
    }
}

/// Maps a 0-based line and UTF-16 column (from the line start) to a full
/// position. Like the UTF-16 mapping above, this is clamp-safe: a column past the
/// line content is clamped to the line end, and a line past the last line is
/// clamped to the last line rather than rejected (the platform bounds the line
/// before calling in). Only a NULL handle/`out_position` or an underlying read
/// error is reported. Writes `*out_position` on success.
///
/// # Safety
///
/// `file` must be NULL or a live handle. `out_position` must point to
/// caller-owned writable storage for a `LocusTextPosition`.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_position_for_line_column(
    file: *const LocusLargeFile,
    line: usize,
    column_utf16: usize,
    out_position: *mut LocusTextPosition,
) -> u32 {
    clear_last_error_message();
    if out_position.is_null() {
        set_last_error_message("out_position must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: file is NULL or a live handle the caller still owns.
    let Some(handle) = (unsafe { file.as_ref() }) else {
        set_last_error_message("file must not be NULL");
        return LOCUS_TEXT_STATUS_INVALID_ARGUMENT;
    };
    match handle.index.position_for_line_column(line, column_utf16) {
        Ok(position) => {
            // SAFETY: out_position was checked non-null above.
            unsafe {
                *out_position = ffi_position(position);
            }
            LOCUS_STATUS_OK
        }
        Err(error) => {
            set_last_error_message(format!("failed to map line/column: {error}"));
            LOCUS_TEXT_STATUS_IO
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text_buffer::{
        locus_text_snapshot_byte_length, locus_text_snapshot_free, locus_text_snapshot_text,
    };
    use std::ffi::CString;
    use std::io::Write;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_file(contents: &[u8]) -> std::path::PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("locus-large-file-{}-{}", std::process::id(), id));
        let mut file = File::create(&path).unwrap();
        file.write_all(contents).unwrap();
        path
    }

    unsafe fn open(path: &std::path::Path) -> *mut LocusLargeFile {
        let c_path = CString::new(path.to_string_lossy().as_bytes()).unwrap();
        let mut handle: *mut LocusLargeFile = std::ptr::null_mut();
        assert_eq!(
            locus_large_file_open(c_path.as_ptr(), &mut handle),
            LOCUS_STATUS_OK
        );
        assert!(!handle.is_null());
        handle
    }

    /// Reads a snapshot's bytes length-counted (an embedded NUL is preserved),
    /// then frees it.
    unsafe fn read_snapshot(snapshot: *mut LocusTextSnapshot) -> String {
        let len = locus_text_snapshot_byte_length(snapshot);
        let ptr = locus_text_snapshot_text(snapshot).cast::<u8>();
        let bytes = std::slice::from_raw_parts(ptr, len).to_vec();
        locus_text_snapshot_free(snapshot);
        String::from_utf8(bytes).unwrap()
    }

    unsafe fn snapshot_text(handle: *const LocusLargeFile, start: usize, count: usize) -> String {
        let mut snapshot: *mut LocusTextSnapshot = std::ptr::null_mut();
        assert_eq!(
            locus_large_file_snapshot_line_range(handle, start, count, &mut snapshot),
            LOCUS_STATUS_OK
        );
        read_snapshot(snapshot)
    }

    unsafe fn snapshot_text_capped(
        handle: *const LocusLargeFile,
        start: usize,
        count: usize,
        cap: usize,
    ) -> String {
        let mut snapshot: *mut LocusTextSnapshot = std::ptr::null_mut();
        assert_eq!(
            locus_large_file_snapshot_line_range_capped(handle, start, count, cap, &mut snapshot),
            LOCUS_STATUS_OK
        );
        read_snapshot(snapshot)
    }

    unsafe fn snapshot_text_utf16(
        handle: *const LocusLargeFile,
        start: usize,
        end: usize,
    ) -> String {
        let mut snapshot: *mut LocusTextSnapshot = std::ptr::null_mut();
        assert_eq!(
            locus_large_file_snapshot_utf16_range(handle, start, end, &mut snapshot),
            LOCUS_STATUS_OK
        );
        read_snapshot(snapshot)
    }

    unsafe fn utf16_position(handle: *const LocusLargeFile, utf16: usize) -> LocusTextPosition {
        let mut position = ZERO_POSITION;
        assert_eq!(
            locus_large_file_position_for_utf16(handle, utf16, &mut position),
            LOCUS_STATUS_OK
        );
        position
    }

    unsafe fn line_column_position(
        handle: *const LocusLargeFile,
        line: usize,
        column: usize,
    ) -> LocusTextPosition {
        let mut position = ZERO_POSITION;
        assert_eq!(
            locus_large_file_position_for_line_column(handle, line, column, &mut position),
            LOCUS_STATUS_OK
        );
        position
    }

    const ZERO_POSITION: LocusTextPosition = LocusTextPosition {
        byte: 0,
        char_index: 0,
        utf16: 0,
        line: 0,
        column_utf16: 0,
    };

    // "ab\n😀x\ncd": 😀 is 4 UTF-8 bytes = 1 char = 2 UTF-16 units. Mirrors the
    // line-index fixture so the FFI is checked against the same coordinates.
    const MIXED: &str = "ab\n😀x\ncd";

    #[test]
    fn opens_and_reads_windowed_line_ranges() {
        let path = temp_file(b"alpha\nbeta\ngamma");
        unsafe {
            let handle = open(&path);
            assert_eq!(locus_large_file_line_count(handle), 3);
            assert_eq!(locus_large_file_byte_length(handle), 16);
            assert_eq!(snapshot_text(handle, 0, 3), "alpha\nbeta\ngamma");
            assert_eq!(snapshot_text(handle, 1, 1), "beta"); // terminator stripped
            assert_eq!(snapshot_text(handle, 2, 9), "gamma"); // clamped past the end
            locus_large_file_free(handle);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn open_missing_file_reports_io_and_leaves_handle_null() {
        let c_path = CString::new("/nonexistent/locus-large-file-missing").unwrap();
        let mut handle: *mut LocusLargeFile = std::ptr::null_mut();
        let status = unsafe { locus_large_file_open(c_path.as_ptr(), &mut handle) };
        assert_eq!(status, LOCUS_TEXT_STATUS_IO);
        assert!(handle.is_null());
    }

    #[test]
    fn open_null_path_reports_invalid_argument() {
        let mut handle: *mut LocusLargeFile = std::ptr::null_mut();
        let status = unsafe { locus_large_file_open(std::ptr::null(), &mut handle) };
        assert_eq!(status, LOCUS_TEXT_STATUS_INVALID_ARGUMENT);
        assert!(handle.is_null());
    }

    #[test]
    fn null_handle_queries_are_safe() {
        unsafe {
            assert_eq!(locus_large_file_line_count(std::ptr::null()), 0);
            assert_eq!(locus_large_file_byte_length(std::ptr::null()), 0);
            locus_large_file_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn reports_utf16_length() {
        let path = temp_file(MIXED.as_bytes());
        unsafe {
            let handle = open(&path);
            assert_eq!(locus_large_file_utf16_length(handle), 9);
            locus_large_file_free(handle);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn capped_snapshot_truncates_long_lines_on_a_char_boundary() {
        let path = temp_file("short\nthis-is-a-much-longer-line\nx".as_bytes());
        unsafe {
            let handle = open(&path);
            assert_eq!(snapshot_text_capped(handle, 0, 3, 4), "shor\nthis\nx");
            locus_large_file_free(handle);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn utf16_range_snapshot_reads_a_window_and_clamps() {
        let path = temp_file(MIXED.as_bytes());
        unsafe {
            let handle = open(&path);
            // [3, 6) spans the emoji and the following 'x' (bytes [3, 8)).
            assert_eq!(snapshot_text_utf16(handle, 3, 6), "😀x");
            assert_eq!(snapshot_text_utf16(handle, 0, 2), "ab");
            // Inverted and past-the-end ranges clamp to empty rather than erroring.
            assert_eq!(snapshot_text_utf16(handle, 6, 3), "");
            assert_eq!(snapshot_text_utf16(handle, 9, 99), "");
            locus_large_file_free(handle);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn position_for_utf16_maps_clamps_and_floors() {
        let path = temp_file(MIXED.as_bytes());
        unsafe {
            let handle = open(&path);
            // Offset 5 is just after the emoji on line 1.
            let p = utf16_position(handle, 5);
            assert_eq!((p.byte, p.line, p.column_utf16, p.utf16), (7, 1, 2, 5));
            // An offset inside the emoji's surrogate pair floors to its start.
            let mid = utf16_position(handle, 4);
            assert_eq!(
                (mid.byte, mid.line, mid.column_utf16, mid.utf16),
                (3, 1, 0, 3)
            );
            // Past the end clamps to the final position.
            let end = utf16_position(handle, 999);
            assert_eq!((end.byte, end.line, end.utf16), (11, 2, 9));
            locus_large_file_free(handle);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn position_for_line_column_clamps_column_and_line() {
        let path = temp_file(MIXED.as_bytes());
        unsafe {
            let handle = open(&path);
            // Column 2 into line 1 lands just after the emoji.
            let p = line_column_position(handle, 1, 2);
            assert_eq!((p.byte, p.line, p.column_utf16, p.utf16), (7, 1, 2, 5));
            // A column past the content clamps to the line's end (before the \n).
            let clamped = line_column_position(handle, 1, 99);
            assert_eq!((clamped.byte, clamped.column_utf16), (8, 3));
            // A line past the last line clamps to the last line, never a phantom.
            let last = line_column_position(handle, 99, 0);
            assert_eq!((last.line, last.byte), (2, 9));
            locus_large_file_free(handle);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn position_queries_reject_null_arguments() {
        let path = temp_file(b"abc");
        unsafe {
            let handle = open(&path);
            let mut position = ZERO_POSITION;
            // A NULL handle is rejected.
            assert_eq!(
                locus_large_file_position_for_utf16(std::ptr::null(), 0, &mut position),
                LOCUS_TEXT_STATUS_INVALID_ARGUMENT
            );
            // A NULL out_position is rejected.
            assert_eq!(
                locus_large_file_position_for_utf16(handle, 0, std::ptr::null_mut()),
                LOCUS_TEXT_STATUS_INVALID_ARGUMENT
            );
            assert_eq!(
                locus_large_file_position_for_line_column(handle, 0, 0, std::ptr::null_mut()),
                LOCUS_TEXT_STATUS_INVALID_ARGUMENT
            );
            locus_large_file_free(handle);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn null_handle_length_query_is_safe() {
        unsafe {
            assert_eq!(locus_large_file_utf16_length(std::ptr::null()), 0);
        }
    }
}
