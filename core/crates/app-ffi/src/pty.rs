//! C ABI for PTY process management.

use std::ffi::OsString;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::ptr;
use std::str;

use pty::{ExitStatus, Pty, PtyError, PtyOptions};

use crate::{clear_last_error_message, set_last_error_message, LOCUS_STATUS_OK};

pub const LOCUS_PTY_STATUS_INVALID_ARGUMENT: u32 = 400;
pub const LOCUS_PTY_STATUS_IO: u32 = 401;
pub const LOCUS_PTY_STATUS_WOULD_BLOCK: u32 = 402;
pub const LOCUS_PTY_STATUS_CHILD_EXEC: u32 = 403;
pub const LOCUS_PTY_STATUS_TIMEOUT: u32 = 404;
pub const LOCUS_PTY_STATUS_PANIC: u32 = 405;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct LocusPtyString {
    pub ptr: *const u8,
    pub len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct LocusPtyEnvVar {
    pub key: LocusPtyString,
    pub value: LocusPtyString,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct LocusPtyOptions {
    pub cols: u16,
    pub rows: u16,
    pub command: LocusPtyString,
    pub args: *const LocusPtyString,
    pub args_len: usize,
    pub cwd: LocusPtyString,
    pub env: *const LocusPtyEnvVar,
    pub env_len: usize,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LocusPtyExitStatus {
    pub exited: bool,
    pub code: i32,
    pub signal: i32,
}

pub struct LocusPty {
    pty: Pty,
}

/// # Safety
///
/// `options` must be non-null and point to a valid `LocusPtyOptions` for this
/// synchronous call. String and array pointers inside it must remain valid for
/// the duration of the call. All strings are UTF-8 byte sequences without
/// embedded NUL bytes.
#[no_mangle]
pub unsafe extern "C" fn locus_pty_spawn(options: *const LocusPtyOptions) -> *mut LocusPty {
    match catch_unwind(AssertUnwindSafe(|| {
        clear_last_error_message();
        if options.is_null() {
            set_last_error_message("options must not be NULL");
            return ptr::null_mut();
        }
        // SAFETY: options was checked for null and is borrowed only for this
        // synchronous call.
        let options = unsafe { *options };
        let Some(options) = pty_options_from_ffi(options) else {
            return ptr::null_mut();
        };
        match Pty::spawn(options) {
            Ok(pty) => Box::into_raw(Box::new(LocusPty { pty })),
            Err(error) => {
                set_last_error_message(error.to_string());
                ptr::null_mut()
            }
        }
    })) {
        Ok(handle) => handle,
        Err(_) => {
            set_last_error_message("PTY spawn panicked");
            ptr::null_mut()
        }
    }
}

/// # Safety
///
/// `pty` must be NULL or a live handle returned by `locus_pty_spawn`.
#[no_mangle]
pub unsafe extern "C" fn locus_pty_master_fd(pty: *const LocusPty) -> i32 {
    if pty.is_null() {
        set_last_error_message("pty must not be NULL");
        return -1;
    }
    // SAFETY: caller guarantees pty is a live handle for this synchronous call.
    unsafe { (*pty).pty.master_fd() }
}

/// # Safety
///
/// `pty` must be a live handle. `buf` must point to `cap` writable bytes when
/// `cap > 0`; `out_len` must be non-null.
#[no_mangle]
pub unsafe extern "C" fn locus_pty_read(
    pty: *mut LocusPty,
    buf: *mut u8,
    cap: usize,
    out_len: *mut usize,
) -> u32 {
    pty_status(|| {
        if out_len.is_null() {
            set_last_error_message("out_len must not be NULL");
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: out_len is non-null caller-owned writable storage.
        unsafe {
            *out_len = 0;
        }
        let Some(pty) = pty_mut(pty) else {
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        };
        if cap > 0 && buf.is_null() {
            set_last_error_message("buf must not be NULL when cap > 0");
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        }
        let slice = if cap == 0 {
            &mut []
        } else {
            // SAFETY: buf is non-null and points to cap writable bytes for this
            // synchronous call.
            unsafe { std::slice::from_raw_parts_mut(buf, cap) }
        };
        match pty.pty.read(slice) {
            Ok(count) => {
                // SAFETY: out_len remains valid for this synchronous call.
                unsafe {
                    *out_len = count;
                }
                LOCUS_STATUS_OK
            }
            Err(error) => pty_status_from_error(error),
        }
    })
}

/// # Safety
///
/// `pty` must be a live handle. `bytes` must point to `len` readable bytes when
/// `len > 0`; `out_len` must be non-null.
#[no_mangle]
pub unsafe extern "C" fn locus_pty_write(
    pty: *mut LocusPty,
    bytes: *const u8,
    len: usize,
    out_len: *mut usize,
) -> u32 {
    pty_status(|| {
        if out_len.is_null() {
            set_last_error_message("out_len must not be NULL");
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: out_len is non-null caller-owned writable storage.
        unsafe {
            *out_len = 0;
        }
        let Some(pty) = pty_mut(pty) else {
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        };
        if len > 0 && bytes.is_null() {
            set_last_error_message("bytes must not be NULL when len > 0");
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        }
        let slice = if len == 0 {
            &[]
        } else {
            // SAFETY: bytes is non-null and points to len readable bytes for
            // this synchronous call.
            unsafe { std::slice::from_raw_parts(bytes, len) }
        };
        match pty.pty.write(slice) {
            Ok(count) => {
                // SAFETY: out_len remains valid for this synchronous call.
                unsafe {
                    *out_len = count;
                }
                LOCUS_STATUS_OK
            }
            Err(error) => pty_status_from_error(error),
        }
    })
}

/// # Safety
///
/// `pty` must be a live handle.
#[no_mangle]
pub unsafe extern "C" fn locus_pty_resize(pty: *mut LocusPty, cols: u16, rows: u16) -> u32 {
    pty_status(|| {
        let Some(pty) = pty_mut(pty) else {
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        };
        match pty.pty.resize(cols, rows) {
            Ok(()) => LOCUS_STATUS_OK,
            Err(error) => pty_status_from_error(error),
        }
    })
}

/// # Safety
///
/// `pty` must be a live handle. `out_status` must point to writable storage.
#[no_mangle]
pub unsafe extern "C" fn locus_pty_try_wait(
    pty: *mut LocusPty,
    out_status: *mut LocusPtyExitStatus,
) -> u32 {
    pty_status(|| {
        if out_status.is_null() {
            set_last_error_message("out_status must not be NULL");
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: out_status is non-null caller-owned writable storage.
        unsafe {
            *out_status = LocusPtyExitStatus::default();
        }
        let Some(pty) = pty_mut(pty) else {
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        };
        match pty.pty.try_wait() {
            Ok(status) => {
                // SAFETY: out_status remains valid for this synchronous call.
                unsafe {
                    *out_status = status.map_or_else(LocusPtyExitStatus::default, ffi_exit_status);
                }
                LOCUS_STATUS_OK
            }
            Err(error) => pty_status_from_error(error),
        }
    })
}

/// # Safety
///
/// `pty` must be NULL or a live handle returned by `locus_pty_spawn`.
#[no_mangle]
pub unsafe extern "C" fn locus_pty_shutdown(pty: *mut LocusPty) -> u32 {
    pty_status(|| {
        let Some(pty) = pty_mut(pty) else {
            return LOCUS_PTY_STATUS_INVALID_ARGUMENT;
        };
        match pty.pty.shutdown() {
            Ok(_) => LOCUS_STATUS_OK,
            Err(error) => pty_status_from_error(error),
        }
    })
}

/// # Safety
///
/// `pty` must be NULL or a live handle returned by `locus_pty_spawn` that has
/// not already been freed.
#[no_mangle]
pub unsafe extern "C" fn locus_pty_free(pty: *mut LocusPty) {
    if pty.is_null() {
        return;
    }
    // SAFETY: caller guarantees pty came from Box::into_raw in locus_pty_spawn
    // and has not been freed yet.
    unsafe {
        drop(Box::from_raw(pty));
    }
}

fn pty_options_from_ffi(options: LocusPtyOptions) -> Option<PtyOptions> {
    let command = optional_string(options.command)?.map(PathBuf::from);
    let cwd = optional_string(options.cwd)?.map(PathBuf::from);
    let args = ffi_string_array(options.args, options.args_len)?;
    let env = ffi_env_array(options.env, options.env_len)?;
    Some(PtyOptions {
        cols: options.cols,
        rows: options.rows,
        command,
        args,
        cwd,
        env,
    })
}

fn optional_string(value: LocusPtyString) -> Option<Option<OsString>> {
    if value.len == 0 {
        return Some(None);
    }
    ffi_string(value).map(Some)
}

fn ffi_string(value: LocusPtyString) -> Option<OsString> {
    if value.ptr.is_null() {
        set_last_error_message("string pointer must not be NULL when len > 0");
        return None;
    }
    // SAFETY: ptr is non-null and caller promises len readable bytes.
    let bytes = unsafe { std::slice::from_raw_parts(value.ptr, value.len) };
    if bytes.contains(&0) {
        set_last_error_message("PTY string contains embedded NUL byte");
        return None;
    }
    let Ok(text) = str::from_utf8(bytes) else {
        set_last_error_message("PTY string must be UTF-8");
        return None;
    };
    Some(OsString::from(text))
}

fn ffi_string_array(ptr: *const LocusPtyString, len: usize) -> Option<Vec<OsString>> {
    if len == 0 {
        return Some(Vec::new());
    }
    if ptr.is_null() {
        set_last_error_message("args must not be NULL when args_len > 0");
        return None;
    }
    // SAFETY: ptr is non-null and caller promises len readable elements.
    let values = unsafe { std::slice::from_raw_parts(ptr, len) };
    values.iter().copied().map(ffi_string).collect()
}

fn ffi_env_array(ptr: *const LocusPtyEnvVar, len: usize) -> Option<Vec<(OsString, OsString)>> {
    if len == 0 {
        return Some(Vec::new());
    }
    if ptr.is_null() {
        set_last_error_message("env must not be NULL when env_len > 0");
        return None;
    }
    // SAFETY: ptr is non-null and caller promises len readable elements.
    let values = unsafe { std::slice::from_raw_parts(ptr, len) };
    values
        .iter()
        .map(|value| Some((ffi_string(value.key)?, ffi_string(value.value)?)))
        .collect()
}

fn ffi_exit_status(status: ExitStatus) -> LocusPtyExitStatus {
    LocusPtyExitStatus {
        exited: true,
        code: status.code.unwrap_or(-1),
        signal: status.signal.unwrap_or(0),
    }
}

fn pty_status(action: impl FnOnce() -> u32) -> u32 {
    clear_last_error_message();
    match catch_unwind(AssertUnwindSafe(action)) {
        Ok(status) => status,
        Err(_) => {
            set_last_error_message("PTY FFI call panicked");
            LOCUS_PTY_STATUS_PANIC
        }
    }
}

fn pty_status_from_error(error: PtyError) -> u32 {
    set_last_error_message(error.to_string());
    match error {
        PtyError::WouldBlock => LOCUS_PTY_STATUS_WOULD_BLOCK,
        PtyError::Timeout => LOCUS_PTY_STATUS_TIMEOUT,
        PtyError::ChildExecFailed(_) => LOCUS_PTY_STATUS_CHILD_EXEC,
        PtyError::InvalidDimensions
        | PtyError::InvalidCwd(_)
        | PtyError::InvalidEnvKey(_)
        | PtyError::NulByte
        | PtyError::BadCommand(_) => LOCUS_PTY_STATUS_INVALID_ARGUMENT,
        PtyError::Io(_) => LOCUS_PTY_STATUS_IO,
    }
}

fn pty_mut<'a>(pty: *mut LocusPty) -> Option<&'a mut LocusPty> {
    if pty.is_null() {
        set_last_error_message("pty must not be NULL");
        return None;
    }
    // SAFETY: the caller guarantees this is a live unique PTY handle for the
    // duration of the synchronous FFI call.
    Some(unsafe { &mut *pty })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::terminal::{
        locus_term_feed, locus_term_frame_free, locus_term_frame_new, locus_term_free,
        locus_term_new, locus_term_render, LocusTermCell, LOCUS_TERM_STATUS_INVALID_ARGUMENT,
    };
    use std::mem::{align_of, offset_of, size_of};
    use std::thread;
    use std::time::{Duration, Instant};

    fn bytes(value: &[u8]) -> LocusPtyString {
        LocusPtyString {
            ptr: value.as_ptr(),
            len: value.len(),
        }
    }

    fn spawn_echo() -> *mut LocusPty {
        let arg = bytes(b"hello");
        let args = [arg];
        let command = bytes(b"/bin/echo");
        let options = LocusPtyOptions {
            cols: 24,
            rows: 8,
            command,
            args: args.as_ptr(),
            args_len: args.len(),
            cwd: LocusPtyString::default(),
            env: ptr::null(),
            env_len: 0,
        };
        // SAFETY: all pointers in options remain valid for this call.
        unsafe { locus_pty_spawn(&options) }
    }

    #[test]
    fn pty_string_layout_matches_the_hand_written_header() {
        assert_eq!(size_of::<LocusPtyString>(), size_of::<usize>() * 2);
        assert_eq!(align_of::<LocusPtyString>(), align_of::<usize>());
        assert_eq!(offset_of!(LocusPtyString, ptr), 0);
        assert_eq!(offset_of!(LocusPtyString, len), size_of::<usize>());
    }

    #[test]
    fn pty_env_var_layout_matches_the_hand_written_header() {
        assert_eq!(size_of::<LocusPtyEnvVar>(), size_of::<LocusPtyString>() * 2);
        assert_eq!(align_of::<LocusPtyEnvVar>(), align_of::<LocusPtyString>());
        assert_eq!(offset_of!(LocusPtyEnvVar, key), 0);
        assert_eq!(
            offset_of!(LocusPtyEnvVar, value),
            size_of::<LocusPtyString>()
        );
    }

    #[test]
    fn pty_options_layout_matches_the_hand_written_header() {
        assert_eq!(align_of::<LocusPtyOptions>(), align_of::<usize>());
        assert_eq!(offset_of!(LocusPtyOptions, cols), 0);
        assert_eq!(offset_of!(LocusPtyOptions, rows), 2);
        assert!(offset_of!(LocusPtyOptions, command) > offset_of!(LocusPtyOptions, rows));
        assert!(offset_of!(LocusPtyOptions, args) > offset_of!(LocusPtyOptions, command));
        assert!(offset_of!(LocusPtyOptions, args_len) > offset_of!(LocusPtyOptions, args));
        assert!(offset_of!(LocusPtyOptions, cwd) > offset_of!(LocusPtyOptions, args_len));
        assert!(offset_of!(LocusPtyOptions, env) > offset_of!(LocusPtyOptions, cwd));
        assert!(offset_of!(LocusPtyOptions, env_len) > offset_of!(LocusPtyOptions, env));
    }

    #[test]
    fn pty_exit_status_layout_matches_the_hand_written_header() {
        assert_eq!(offset_of!(LocusPtyExitStatus, exited), 0);
        assert_eq!(offset_of!(LocusPtyExitStatus, code), 4);
        assert_eq!(offset_of!(LocusPtyExitStatus, signal), 8);
        assert_eq!(size_of::<LocusPtyExitStatus>(), 12);
    }

    fn read_until_done(handle: *mut LocusPty) -> Vec<u8> {
        let deadline = Instant::now() + Duration::from_secs(2);
        let mut output = Vec::new();
        let mut buf = [0_u8; 512];
        while Instant::now() < deadline {
            let mut count = 0;
            // SAFETY: handle is live; buf/out count are valid.
            let status = unsafe { locus_pty_read(handle, buf.as_mut_ptr(), buf.len(), &mut count) };
            if status == LOCUS_STATUS_OK {
                if count == 0 {
                    break;
                }
                output.extend_from_slice(&buf[..count]);
            } else if status == LOCUS_PTY_STATUS_WOULD_BLOCK {
                thread::sleep(Duration::from_millis(5));
            } else {
                panic!("pty read failed with status {status}");
            }
        }
        output
    }

    #[test]
    fn spawn_rejects_null_options() {
        // SAFETY: null options are explicitly allowed and rejected.
        assert!(unsafe { locus_pty_spawn(ptr::null()) }.is_null());
    }

    #[test]
    fn read_rejects_null_handle() {
        let mut len = 0;
        // SAFETY: null handle is explicitly rejected; output pointer is valid.
        assert_eq!(
            unsafe { locus_pty_read(ptr::null_mut(), ptr::null_mut(), 0, &mut len) },
            LOCUS_PTY_STATUS_INVALID_ARGUMENT
        );
    }

    #[test]
    fn master_fd_rejects_null_handle() {
        // SAFETY: null handle is explicitly rejected.
        assert_eq!(unsafe { locus_pty_master_fd(ptr::null()) }, -1);
    }

    #[test]
    fn write_rejects_null_handle() {
        let mut len = 0;
        // SAFETY: null handle is explicitly rejected; output pointer is valid.
        assert_eq!(
            unsafe { locus_pty_write(ptr::null_mut(), ptr::null(), 0, &mut len) },
            LOCUS_PTY_STATUS_INVALID_ARGUMENT
        );
    }

    #[test]
    fn resize_rejects_null_handle() {
        // SAFETY: null handle is explicitly rejected.
        assert_eq!(
            unsafe { locus_pty_resize(ptr::null_mut(), 80, 24) },
            LOCUS_PTY_STATUS_INVALID_ARGUMENT
        );
    }

    #[test]
    fn try_wait_rejects_null_output() {
        let handle = spawn_echo();
        assert!(!handle.is_null());
        // SAFETY: handle is live; null output is explicitly rejected.
        assert_eq!(
            unsafe { locus_pty_try_wait(handle, ptr::null_mut()) },
            LOCUS_PTY_STATUS_INVALID_ARGUMENT
        );
        // SAFETY: handle is live and being released once.
        unsafe { locus_pty_free(handle) };
    }

    #[test]
    fn free_accepts_null() {
        // SAFETY: null free is explicitly allowed.
        unsafe { locus_pty_free(ptr::null_mut()) };
    }

    #[test]
    fn spawn_rejects_embedded_nul() {
        let command = bytes(b"/bin/echo\0oops");
        let options = LocusPtyOptions {
            cols: 24,
            rows: 8,
            command,
            args: ptr::null(),
            args_len: 0,
            cwd: LocusPtyString::default(),
            env: ptr::null(),
            env_len: 0,
        };
        // SAFETY: all pointers in options remain valid for this call.
        assert!(unsafe { locus_pty_spawn(&options) }.is_null());
    }

    #[test]
    fn spawn_read_try_wait_round_trip() {
        let handle = spawn_echo();
        assert!(!handle.is_null());
        let output = read_until_done(handle);
        let mut status = LocusPtyExitStatus::default();
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            // SAFETY: handle and status pointer are valid.
            assert_eq!(
                unsafe { locus_pty_try_wait(handle, &mut status) },
                LOCUS_STATUS_OK
            );
            if status.exited {
                break;
            }
            thread::sleep(Duration::from_millis(5));
        }
        assert!(String::from_utf8_lossy(&output).contains("hello"));
        assert_eq!(status.code, 0);
        // SAFETY: handle is live and being released once.
        unsafe { locus_pty_free(handle) };
    }

    #[test]
    fn shutdown_is_idempotent_through_ffi() {
        let command = bytes(b"/bin/cat");
        let options = LocusPtyOptions {
            cols: 24,
            rows: 8,
            command,
            args: ptr::null(),
            args_len: 0,
            cwd: LocusPtyString::default(),
            env: ptr::null(),
            env_len: 0,
        };
        // SAFETY: all pointers in options remain valid for this call.
        let handle = unsafe { locus_pty_spawn(&options) };
        assert!(!handle.is_null());
        // SAFETY: handle is live for both calls and is then released once.
        unsafe {
            assert_eq!(locus_pty_shutdown(handle), LOCUS_STATUS_OK);
            assert_eq!(locus_pty_shutdown(handle), LOCUS_STATUS_OK);
            locus_pty_free(handle);
        }
    }

    #[test]
    fn spawn_read_feed_render_through_terminal_ffi() {
        let pty = spawn_echo();
        assert!(!pty.is_null());
        let output = read_until_done(pty);
        let term = locus_term_new(24, 8, 1024);
        let frame = locus_term_frame_new();
        assert!(!term.is_null());
        assert!(!frame.is_null());
        // SAFETY: all handles and byte pointers are valid for the calls.
        unsafe {
            assert_eq!(
                locus_term_feed(term, output.as_ptr(), output.len()),
                LOCUS_STATUS_OK
            );
            assert_eq!(locus_term_render(term, frame, true), LOCUS_STATUS_OK);
            let cells = std::slice::from_raw_parts((*frame).cells_ptr, (*frame).cell_count);
            assert!(cells_to_string(cells).contains("hello"));
            locus_term_frame_free(frame);
            locus_term_free(term);
            locus_pty_free(pty);
        }
    }

    #[test]
    fn terminal_feed_still_rejects_null() {
        // SAFETY: null terminal is explicitly rejected.
        assert_eq!(
            unsafe { locus_term_feed(ptr::null_mut(), ptr::null(), 0) },
            LOCUS_TERM_STATUS_INVALID_ARGUMENT
        );
    }

    fn cells_to_string(cells: &[LocusTermCell]) -> String {
        cells
            .iter()
            .filter_map(|cell| char::from_u32(cell.codepoint))
            .collect()
    }
}
