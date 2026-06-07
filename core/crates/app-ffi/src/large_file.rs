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
    LocusTextSnapshot, LOCUS_TEXT_STATUS_INVALID_ARGUMENT, LOCUS_TEXT_STATUS_IO,
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

/// Length in bytes of the file's longest line (including its terminator). Lets
/// the platform refuse a file with a pathologically long single line. Returns 0
/// for a NULL handle.
///
/// # Safety
///
/// `file` must be NULL or a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_large_file_max_line_byte_length(file: *const LocusLargeFile) -> u64 {
    // SAFETY: file is NULL or a live handle the caller still owns.
    match unsafe { file.as_ref() } {
        Some(file) => file.index.max_line_byte_count(),
        None => 0,
    }
}

/// Snapshots the text of lines `[start_line, start_line + count)` (clamped) by
/// reading only that window from the file. On success writes a borrowed snapshot
/// the caller releases with `locus_text_snapshot_free`.
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
    let end_line = start_line.saturating_add(count);
    let text = match handle.index.text_for_line_range(start_line, end_line) {
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

    unsafe fn snapshot_text(handle: *const LocusLargeFile, start: usize, count: usize) -> String {
        let mut snapshot: *mut LocusTextSnapshot = std::ptr::null_mut();
        assert_eq!(
            locus_large_file_snapshot_line_range(handle, start, count, &mut snapshot),
            LOCUS_STATUS_OK
        );
        let len = locus_text_snapshot_byte_length(snapshot);
        let ptr = locus_text_snapshot_text(snapshot).cast::<u8>();
        let bytes = std::slice::from_raw_parts(ptr, len).to_vec();
        locus_text_snapshot_free(snapshot);
        String::from_utf8(bytes).unwrap()
    }

    #[test]
    fn opens_and_reads_windowed_line_ranges() {
        let path = temp_file(b"alpha\nbeta\ngamma");
        unsafe {
            let handle = open(&path);
            assert_eq!(locus_large_file_line_count(handle), 3);
            assert_eq!(locus_large_file_byte_length(handle), 16);
            assert_eq!(locus_large_file_max_line_byte_length(handle), 6); // "alpha\n"
            assert_eq!(snapshot_text(handle, 0, 3), "alpha\nbeta\ngamma");
            assert_eq!(snapshot_text(handle, 1, 1), "beta\n");
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
}
