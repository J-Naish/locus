#![allow(unsafe_code)] // app-ffi is the only crate that owns raw C ABI boundaries.

use std::cell::RefCell;
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::UNIX_EPOCH;

use app_core::file_type::FileType;
use app_core::workspace::{
    list_directory_with_options, WorkspaceEntry, WorkspaceEntryKind, WorkspaceError,
    WorkspaceListOptions,
};

pub mod large_file;
pub mod text_buffer;

// Version 3 dropped the unused `locus_large_file_max_line_byte_length` export;
// removing a symbol is a breaking change, so the version is bumped per the
// contract in `locus_core.h`.
pub const ABI_VERSION: u32 = 3;

static VERSION: &[u8] = concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes();

thread_local! {
    static LAST_ERROR_MESSAGE: RefCell<CString> =
        RefCell::new(CString::new("").expect("empty strings never contain NUL bytes"));
}

pub const LOCUS_STATUS_OK: u32 = 0;
pub const LOCUS_STATUS_INVALID_ARGUMENT: u32 = 1;
pub const LOCUS_STATUS_NOT_FOUND: u32 = 2;
pub const LOCUS_STATUS_NOT_DIRECTORY: u32 = 3;
pub const LOCUS_STATUS_READ_DIRECTORY: u32 = 4;
pub const LOCUS_STATUS_READ_ENTRY: u32 = 5;
pub const LOCUS_STATUS_READ_METADATA: u32 = 6;

pub const LOCUS_WORKSPACE_ENTRY_DIRECTORY: u32 = 1;
pub const LOCUS_WORKSPACE_ENTRY_FILE: u32 = 2;
pub const LOCUS_WORKSPACE_ENTRY_SYMLINK: u32 = 3;
pub const LOCUS_WORKSPACE_ENTRY_OTHER: u32 = 4;
pub const LOCUS_WORKSPACE_ENTRY_SYMLINK_DIRECTORY: u32 = 5;
pub const LOCUS_WORKSPACE_ENTRY_SYMLINK_FILE: u32 = 6;

pub const LOCUS_FILE_TYPE_MARKDOWN: u32 = 1;
pub const LOCUS_FILE_TYPE_STRUCTURED_TEXT: u32 = 2;
pub const LOCUS_FILE_TYPE_PDF: u32 = 3;
pub const LOCUS_FILE_TYPE_OFFICE: u32 = 4;
pub const LOCUS_FILE_TYPE_IMAGE: u32 = 5;
pub const LOCUS_FILE_TYPE_AUDIO: u32 = 6;
pub const LOCUS_FILE_TYPE_VIDEO: u32 = 7;
pub const LOCUS_FILE_TYPE_PLAIN_TEXT: u32 = 8;
pub const LOCUS_FILE_TYPE_CODE: u32 = 9;
pub const LOCUS_FILE_TYPE_UNKNOWN: u32 = 10;

#[repr(C)]
pub struct LocusWorkspaceEntry {
    pub path: *const c_char,
    pub name: *const c_char,
    pub kind: u32,
    pub file_type: u32,
    pub has_size_bytes: bool,
    pub size_bytes: u64,
    pub has_modified_unix_seconds: bool,
    pub modified_unix_seconds: i64,
    pub readonly: bool,
}

#[repr(C)]
pub struct LocusWorkspacePartialError {
    pub status: u32,
    pub message: *const c_char,
}

pub struct LocusWorkspaceSnapshot {
    entries: Vec<LocusWorkspaceEntry>,
    partial_errors: Vec<LocusWorkspacePartialError>,
    _strings: Vec<CString>,
}

#[no_mangle]
pub extern "C" fn locus_core_abi_version() -> u32 {
    ABI_VERSION
}

#[no_mangle]
pub extern "C" fn locus_core_is_abi_compatible(expected: u32) -> bool {
    expected == ABI_VERSION
}

#[no_mangle]
pub extern "C" fn locus_core_version() -> *const c_char {
    VERSION.as_ptr().cast()
}

#[no_mangle]
pub extern "C" fn locus_last_error_message() -> *const c_char {
    LAST_ERROR_MESSAGE.with_borrow(|message| message.as_ptr())
}

/// # Safety
///
/// `path` must be NULL or a valid NUL-terminated UTF-8 C string that remains
/// valid for the duration of the call. `out_snapshot` must be NULL or point to
/// caller-owned writable storage for a `*mut LocusWorkspaceSnapshot`. On
/// success the caller is responsible for releasing the snapshot exactly once
/// with `locus_workspace_snapshot_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_core_list_directory(
    path: *const c_char,
    include_ignored: bool,
    out_snapshot: *mut *mut LocusWorkspaceSnapshot,
) -> u32 {
    // SAFETY: this function has the same caller contract as
    // list_directory_impl and forwards its raw pointers unchanged.
    unsafe { list_directory_impl(path, include_ignored, false, out_snapshot) }
}

/// # Safety
///
/// `path` must be NULL or a valid NUL-terminated UTF-8 C string that remains
/// valid for the duration of the call. `out_snapshot` must be NULL or point to
/// caller-owned writable storage for a `*mut LocusWorkspaceSnapshot`. On
/// success the caller is responsible for releasing the snapshot exactly once
/// with `locus_workspace_snapshot_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_core_list_directory_with_options(
    path: *const c_char,
    include_ignored: bool,
    include_extended_metadata: bool,
    out_snapshot: *mut *mut LocusWorkspaceSnapshot,
) -> u32 {
    // SAFETY: this function has the same caller contract as
    // list_directory_impl and forwards its raw pointers unchanged.
    unsafe {
        list_directory_impl(
            path,
            include_ignored,
            include_extended_metadata,
            out_snapshot,
        )
    }
}

unsafe fn list_directory_impl(
    path: *const c_char,
    include_ignored: bool,
    include_extended_metadata: bool,
    out_snapshot: *mut *mut LocusWorkspaceSnapshot,
) -> u32 {
    clear_last_error_message();

    if out_snapshot.is_null() {
        set_last_error_message("out_snapshot must not be NULL");
        return LOCUS_STATUS_INVALID_ARGUMENT;
    }

    // SAFETY: out_snapshot was checked for null and the caller guarantees it
    // points to writable storage for the duration of this synchronous call.
    unsafe {
        *out_snapshot = ptr::null_mut();
    }

    // string_from_c_str itself validates `path` for NULL and only dereferences
    // it inside its own SAFETY-justified unsafe block; the caller's contract is
    // documented at the function level above.
    let Some(path) = string_from_c_str(path) else {
        set_last_error_message("path must be non-NULL UTF-8");
        return LOCUS_STATUS_INVALID_ARGUMENT;
    };

    let options = WorkspaceListOptions::new()
        .include_ignored(include_ignored)
        .include_extended_metadata(include_extended_metadata);
    match list_directory_with_options(path, options) {
        Ok(snapshot) => {
            let ffi_snapshot = LocusWorkspaceSnapshot::from_core_snapshot(snapshot);
            // SAFETY: out_snapshot was checked for null above. Ownership of the
            // Box is intentionally transferred to the caller and later reclaimed
            // by locus_workspace_snapshot_free().
            unsafe {
                *out_snapshot = Box::into_raw(Box::new(ffi_snapshot));
            }
            LOCUS_STATUS_OK
        }
        Err(error) => {
            set_last_error_message(error.to_string());
            status_from_workspace_error(&error)
        }
    }
}

/// # Safety
///
/// `snapshot` must be NULL or a live handle returned by
/// `locus_core_list_directory` that has not yet been freed.
#[no_mangle]
pub unsafe extern "C" fn locus_workspace_snapshot_entry_count(
    snapshot: *const LocusWorkspaceSnapshot,
) -> usize {
    if snapshot.is_null() {
        return 0;
    }

    // SAFETY: snapshot is non-null and the caller guarantees it refers to a
    // live snapshot that has not been freed.
    unsafe { (*snapshot).entries.len() }
}

/// # Safety
///
/// `snapshot` must be NULL or a live handle returned by
/// `locus_core_list_directory` that has not yet been freed. The returned
/// pointer is borrowed from the snapshot and is invalidated by
/// `locus_workspace_snapshot_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_workspace_snapshot_entries(
    snapshot: *const LocusWorkspaceSnapshot,
) -> *const LocusWorkspaceEntry {
    if snapshot.is_null() {
        return ptr::null();
    }

    // SAFETY: snapshot is non-null and the returned slice pointer is borrowed
    // from the live Rust-owned snapshot the caller still owns.
    let entries = unsafe { &(*snapshot).entries };
    if entries.is_empty() {
        ptr::null()
    } else {
        entries.as_ptr()
    }
}

/// # Safety
///
/// `snapshot` must be NULL or a live handle returned by
/// `locus_core_list_directory` that has not yet been freed.
#[no_mangle]
pub unsafe extern "C" fn locus_workspace_snapshot_partial_error_count(
    snapshot: *const LocusWorkspaceSnapshot,
) -> usize {
    if snapshot.is_null() {
        return 0;
    }

    // SAFETY: snapshot is non-null and the caller guarantees it refers to a
    // live snapshot that has not been freed.
    unsafe { (*snapshot).partial_errors.len() }
}

/// # Safety
///
/// `snapshot` must be NULL or a live handle returned by
/// `locus_core_list_directory` that has not yet been freed. The returned
/// pointer is borrowed from the snapshot and is invalidated by
/// `locus_workspace_snapshot_free`.
#[no_mangle]
pub unsafe extern "C" fn locus_workspace_snapshot_partial_errors(
    snapshot: *const LocusWorkspaceSnapshot,
) -> *const LocusWorkspacePartialError {
    if snapshot.is_null() {
        return ptr::null();
    }

    // SAFETY: snapshot is non-null and the returned slice pointer is borrowed
    // from the live Rust-owned snapshot the caller still owns.
    let partial_errors = unsafe { &(*snapshot).partial_errors };
    if partial_errors.is_empty() {
        ptr::null()
    } else {
        partial_errors.as_ptr()
    }
}

/// # Safety
///
/// `snapshot` must be NULL or a live handle returned by
/// `locus_core_list_directory` that has not yet been freed. After this call
/// returns, all borrowed pointers obtained from the snapshot become invalid.
#[no_mangle]
pub unsafe extern "C" fn locus_workspace_snapshot_free(snapshot: *mut LocusWorkspaceSnapshot) {
    if snapshot.is_null() {
        return;
    }

    // SAFETY: snapshot was created by Box::into_raw in locus_core_list_directory.
    // Rebuilding the Box here gives Rust ownership back exactly once.
    unsafe {
        drop(Box::from_raw(snapshot));
    }
}

impl LocusWorkspaceSnapshot {
    fn from_core_snapshot(snapshot: app_core::workspace::WorkspaceSnapshot) -> Self {
        let app_core::workspace::WorkspaceSnapshot {
            entries,
            partial_errors,
        } = snapshot;

        let mut strings = Vec::with_capacity(entries.len() * 2 + partial_errors.len());
        let entries = entries
            .into_iter()
            .map(|entry| ffi_entry(entry, &mut strings))
            .collect();
        let partial_errors = partial_errors
            .into_iter()
            .map(|error| ffi_partial_error(error, &mut strings))
            .collect();

        Self {
            entries,
            partial_errors,
            _strings: strings,
        }
    }
}

pub(crate) fn string_from_c_str(value: *const c_char) -> Option<String> {
    if value.is_null() {
        return None;
    }

    // SAFETY: value is non-null and must point to a NUL-terminated C string for
    // the duration of this call. Invalid UTF-8 is rejected.
    unsafe { CStr::from_ptr(value).to_str().ok().map(ToOwned::to_owned) }
}

pub(crate) fn clear_last_error_message() {
    set_last_error_message("");
}

pub(crate) fn set_last_error_message(message: impl AsRef<str>) {
    LAST_ERROR_MESSAGE.with_borrow_mut(|stored| {
        *stored = sanitized_cstring(message.as_ref());
    });
}

fn ffi_entry(entry: WorkspaceEntry, strings: &mut Vec<CString>) -> LocusWorkspaceEntry {
    let kind = entry_kind_code(entry.kind);
    let file_type = match entry.kind {
        WorkspaceEntryKind::File(file_type) | WorkspaceEntryKind::SymlinkToFile(file_type) => {
            file_type_code(file_type)
        }
        _ => LOCUS_FILE_TYPE_UNKNOWN,
    };
    let path = push_string(strings, entry.path.to_string_lossy());
    let name = push_string(strings, entry.name);
    let modified_unix_seconds = entry.modified.map(system_time_to_unix_seconds);

    LocusWorkspaceEntry {
        path,
        name,
        kind,
        file_type,
        has_size_bytes: entry.size_bytes.is_some(),
        size_bytes: entry.size_bytes.unwrap_or(0),
        has_modified_unix_seconds: modified_unix_seconds.is_some(),
        modified_unix_seconds: modified_unix_seconds.unwrap_or(0),
        readonly: entry.readonly,
    }
}

fn ffi_partial_error(
    error: WorkspaceError,
    strings: &mut Vec<CString>,
) -> LocusWorkspacePartialError {
    let status = status_from_workspace_error(&error);
    let message = push_string(strings, error.to_string());

    LocusWorkspacePartialError { status, message }
}

fn push_string(strings: &mut Vec<CString>, value: impl AsRef<str>) -> *const c_char {
    // CString owns its buffer on the heap, so these pointers stay valid even if
    // the Vec itself reallocates while building the snapshot.
    let string = sanitized_cstring(value.as_ref());
    let ptr = string.as_ptr();
    strings.push(string);
    ptr
}

fn sanitized_cstring(value: &str) -> CString {
    if value.contains('\0') {
        CString::new(value.replace('\0', "\u{FFFD}"))
            .expect("sanitized strings do not contain NUL bytes")
    } else {
        CString::new(value).expect("strings without NUL bytes are valid C strings")
    }
}

fn system_time_to_unix_seconds(time: std::time::SystemTime) -> i64 {
    match time.duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs().min(i64::MAX as u64) as i64,
        Err(error) => -(error.duration().as_secs().min(i64::MAX as u64) as i64),
    }
}

fn entry_kind_code(kind: WorkspaceEntryKind) -> u32 {
    match kind {
        WorkspaceEntryKind::Directory => LOCUS_WORKSPACE_ENTRY_DIRECTORY,
        WorkspaceEntryKind::File(_) => LOCUS_WORKSPACE_ENTRY_FILE,
        WorkspaceEntryKind::Symlink => LOCUS_WORKSPACE_ENTRY_SYMLINK,
        WorkspaceEntryKind::SymlinkToDirectory => LOCUS_WORKSPACE_ENTRY_SYMLINK_DIRECTORY,
        WorkspaceEntryKind::SymlinkToFile(_) => LOCUS_WORKSPACE_ENTRY_SYMLINK_FILE,
        WorkspaceEntryKind::Other => LOCUS_WORKSPACE_ENTRY_OTHER,
    }
}

fn file_type_code(file_type: FileType) -> u32 {
    match file_type {
        FileType::Markdown => LOCUS_FILE_TYPE_MARKDOWN,
        FileType::StructuredText => LOCUS_FILE_TYPE_STRUCTURED_TEXT,
        FileType::Pdf => LOCUS_FILE_TYPE_PDF,
        FileType::Office => LOCUS_FILE_TYPE_OFFICE,
        FileType::Image => LOCUS_FILE_TYPE_IMAGE,
        FileType::Audio => LOCUS_FILE_TYPE_AUDIO,
        FileType::Video => LOCUS_FILE_TYPE_VIDEO,
        FileType::PlainText => LOCUS_FILE_TYPE_PLAIN_TEXT,
        FileType::Code => LOCUS_FILE_TYPE_CODE,
        FileType::Unknown => LOCUS_FILE_TYPE_UNKNOWN,
    }
}

fn status_from_workspace_error(error: &WorkspaceError) -> u32 {
    match error {
        WorkspaceError::NotFound(_) => LOCUS_STATUS_NOT_FOUND,
        WorkspaceError::NotDirectory(_) => LOCUS_STATUS_NOT_DIRECTORY,
        WorkspaceError::ReadDirectory { .. } => LOCUS_STATUS_READ_DIRECTORY,
        WorkspaceError::ReadEntry { .. } => LOCUS_STATUS_READ_ENTRY,
        WorkspaceError::ReadMetadata { .. } => LOCUS_STATUS_READ_METADATA,
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::{CStr, CString};
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn exposes_expected_abi_version() {
        assert_eq!(super::locus_core_abi_version(), super::ABI_VERSION);
    }

    #[test]
    fn abi_version_is_never_zero() {
        assert_ne!(super::locus_core_abi_version(), 0);
    }

    #[test]
    fn reports_matching_abi_version_as_compatible() {
        assert!(super::locus_core_is_abi_compatible(super::ABI_VERSION));
    }

    #[test]
    fn reports_mismatched_abi_version_as_incompatible() {
        assert!(!super::locus_core_is_abi_compatible(super::ABI_VERSION + 1));
    }

    #[test]
    fn exposes_null_terminated_core_version() {
        let version = super::locus_core_version();

        assert!(!version.is_null());

        let version = unsafe { CStr::from_ptr(version) };
        assert_eq!(version.to_str().unwrap(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn lists_directory_entries_in_owned_snapshot() {
        let workspace = TestWorkspace::new();
        workspace.create_dir("Drafts");
        workspace.create_file_with_contents("notes.md", "hello");

        let mut snapshot = std::ptr::null_mut();
        let path = CString::new(workspace.path().to_string_lossy().as_ref()).unwrap();
        // SAFETY: every FFI call below sees a live snapshot handle owned by
        // this test until locus_workspace_snapshot_free runs at the end.
        unsafe {
            let status = super::locus_core_list_directory(path.as_ptr(), false, &mut snapshot);

            assert_eq!(status, super::LOCUS_STATUS_OK);
            assert!(!snapshot.is_null());
            assert_eq!(super::locus_workspace_snapshot_entry_count(snapshot), 2);

            let entries_ptr = super::locus_workspace_snapshot_entries(snapshot);
            assert!(!entries_ptr.is_null());

            let entries = std::slice::from_raw_parts(
                entries_ptr,
                super::locus_workspace_snapshot_entry_count(snapshot),
            );
            let names = entries
                .iter()
                .map(|entry| CStr::from_ptr(entry.name).to_str().unwrap())
                .collect::<Vec<_>>();

            assert_eq!(names, ["Drafts", "notes.md"]);
            assert_eq!(entries[0].kind, super::LOCUS_WORKSPACE_ENTRY_DIRECTORY);
            assert_eq!(entries[1].kind, super::LOCUS_WORKSPACE_ENTRY_FILE);
            assert_eq!(entries[1].file_type, super::LOCUS_FILE_TYPE_MARKDOWN);
            assert!(!entries[1].has_size_bytes);
            assert_eq!(entries[1].size_bytes, 0);
            assert!(!entries[1].has_modified_unix_seconds);
            assert_eq!(entries[1].modified_unix_seconds, 0);
            assert_eq!(
                super::locus_workspace_snapshot_partial_error_count(snapshot),
                0
            );

            super::locus_workspace_snapshot_free(snapshot);
        }
    }

    #[test]
    fn list_directory_can_include_ignored_entries() {
        let workspace = TestWorkspace::new();
        workspace.create_dir(".git");
        workspace.create_file("notes.md");

        let mut snapshot = std::ptr::null_mut();
        let path = CString::new(workspace.path().to_string_lossy().as_ref()).unwrap();
        // SAFETY: snapshot ownership is held by this test until the free call.
        unsafe {
            let status = super::locus_core_list_directory(path.as_ptr(), true, &mut snapshot);

            assert_eq!(status, super::LOCUS_STATUS_OK);

            let entries = std::slice::from_raw_parts(
                super::locus_workspace_snapshot_entries(snapshot),
                super::locus_workspace_snapshot_entry_count(snapshot),
            );
            let names = entries
                .iter()
                .map(|entry| CStr::from_ptr(entry.name).to_str().unwrap())
                .collect::<Vec<_>>();

            assert_eq!(names, [".git", "notes.md"]);

            super::locus_workspace_snapshot_free(snapshot);
        }
    }

    #[test]
    fn list_directory_with_options_can_include_extended_metadata() {
        let workspace = TestWorkspace::new();
        workspace.create_file_with_contents("notes.md", "hello");

        let mut snapshot = std::ptr::null_mut();
        let path = CString::new(workspace.path().to_string_lossy().as_ref()).unwrap();
        // SAFETY: snapshot ownership is held by this test until the free call.
        unsafe {
            let status = super::locus_core_list_directory_with_options(
                path.as_ptr(),
                false,
                true,
                &mut snapshot,
            );

            assert_eq!(status, super::LOCUS_STATUS_OK);

            let entries = std::slice::from_raw_parts(
                super::locus_workspace_snapshot_entries(snapshot),
                super::locus_workspace_snapshot_entry_count(snapshot),
            );

            assert!(entries[0].has_size_bytes);
            assert_eq!(entries[0].size_bytes, 5);
            assert!(entries[0].has_modified_unix_seconds);

            super::locus_workspace_snapshot_free(snapshot);
        }
    }

    #[test]
    fn list_directory_returns_error_for_file_path_without_snapshot() {
        let workspace = TestWorkspace::new();
        let file_path = workspace.create_file("notes.md");

        let mut snapshot = std::ptr::null_mut();
        let path = CString::new(file_path.to_string_lossy().as_ref()).unwrap();
        // SAFETY: path/out_snapshot are valid for the call; the FFI sets
        // snapshot back to NULL on failure so no release is needed.
        let status =
            unsafe { super::locus_core_list_directory(path.as_ptr(), false, &mut snapshot) };

        assert_eq!(status, super::LOCUS_STATUS_NOT_DIRECTORY);
        assert!(snapshot.is_null());

        let message = super::locus_last_error_message();
        let message = unsafe { CStr::from_ptr(message).to_str().unwrap() };
        assert!(message.contains("workspace path is not a folder"));
    }

    #[test]
    fn core_snapshot_partial_errors_are_exposed_through_ffi_snapshot() {
        let core_snapshot = app_core::workspace::WorkspaceSnapshot {
            entries: Vec::new(),
            partial_errors: vec![app_core::workspace::WorkspaceError::ReadMetadata {
                path: PathBuf::from("blocked.md"),
                source: std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "metadata blocked for test",
                ),
            }],
        };
        let snapshot = super::LocusWorkspaceSnapshot::from_core_snapshot(core_snapshot);

        // SAFETY: snapshot lives on the test stack and is borrowed by the FFI
        // accessors only for the duration of each call below.
        unsafe {
            assert_eq!(
                super::locus_workspace_snapshot_partial_error_count(&snapshot),
                1
            );

            let partial_errors = super::locus_workspace_snapshot_partial_errors(&snapshot);
            assert!(!partial_errors.is_null());

            let partial_error = &*partial_errors;
            assert_eq!(partial_error.status, super::LOCUS_STATUS_READ_METADATA);
            let message = CStr::from_ptr(partial_error.message).to_str().unwrap();
            assert!(message.contains("blocked.md"));
        }
    }

    #[test]
    fn list_directory_rejects_null_arguments() {
        let workspace = TestWorkspace::new();
        let path = CString::new(workspace.path().to_string_lossy().as_ref()).unwrap();
        let mut snapshot = std::ptr::null_mut();

        // SAFETY: arguments are either NULL or owned by this test for the call.
        unsafe {
            assert_eq!(
                super::locus_core_list_directory(std::ptr::null(), false, &mut snapshot),
                super::LOCUS_STATUS_INVALID_ARGUMENT
            );
            let message = super::locus_last_error_message();
            let message = CStr::from_ptr(message).to_str().unwrap();
            assert_eq!(message, "path must be non-NULL UTF-8");

            assert_eq!(
                super::locus_core_list_directory(path.as_ptr(), false, std::ptr::null_mut()),
                super::LOCUS_STATUS_INVALID_ARGUMENT
            );
            let message = super::locus_last_error_message();
            let message = CStr::from_ptr(message).to_str().unwrap();
            assert_eq!(message, "out_snapshot must not be NULL");
        }
    }

    #[test]
    fn snapshot_accessors_tolerate_null() {
        // SAFETY: every accessor below documents that NULL is a valid input.
        unsafe {
            assert_eq!(
                super::locus_workspace_snapshot_entry_count(std::ptr::null()),
                0
            );
            assert!(super::locus_workspace_snapshot_entries(std::ptr::null()).is_null());
            assert_eq!(
                super::locus_workspace_snapshot_partial_error_count(std::ptr::null()),
                0
            );
            assert!(super::locus_workspace_snapshot_partial_errors(std::ptr::null()).is_null());
            super::locus_workspace_snapshot_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn sanitized_cstring_replaces_embedded_nul_bytes() {
        let string = super::sanitized_cstring("alpha\0beta");

        assert_eq!(string.to_str().unwrap(), "alpha\u{FFFD}beta");
    }

    #[test]
    fn system_time_to_unix_seconds_handles_pre_epoch_values() {
        let time = UNIX_EPOCH - std::time::Duration::from_secs(42);

        assert_eq!(super::system_time_to_unix_seconds(time), -42);
    }

    #[test]
    fn system_time_to_unix_seconds_handles_future_values() {
        let time = UNIX_EPOCH + std::time::Duration::from_secs(9_000_000_000);

        assert_eq!(super::system_time_to_unix_seconds(time), 9_000_000_000);
    }

    #[test]
    fn core_snapshot_exposes_multiple_partial_errors_through_ffi_snapshot() {
        let core_snapshot = app_core::workspace::WorkspaceSnapshot {
            entries: Vec::new(),
            partial_errors: vec![
                app_core::workspace::WorkspaceError::ReadEntry {
                    source: std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "entry blocked for test",
                    ),
                },
                app_core::workspace::WorkspaceError::ReadMetadata {
                    path: PathBuf::from("blocked.md"),
                    source: std::io::Error::new(
                        std::io::ErrorKind::PermissionDenied,
                        "metadata blocked for test",
                    ),
                },
            ],
        };
        let snapshot = super::LocusWorkspaceSnapshot::from_core_snapshot(core_snapshot);

        // SAFETY: snapshot lives on the test stack and is borrowed by the FFI
        // accessors only for the duration of each call below.
        unsafe {
            assert_eq!(
                super::locus_workspace_snapshot_partial_error_count(&snapshot),
                2
            );

            let partial_errors = std::slice::from_raw_parts(
                super::locus_workspace_snapshot_partial_errors(&snapshot),
                super::locus_workspace_snapshot_partial_error_count(&snapshot),
            );
            assert_eq!(partial_errors[0].status, super::LOCUS_STATUS_READ_ENTRY);
            assert_eq!(partial_errors[1].status, super::LOCUS_STATUS_READ_METADATA);
        }
    }

    struct TestWorkspace {
        path: PathBuf,
    }

    static NEXT_TEST_WORKSPACE_ID: AtomicU64 = AtomicU64::new(0);

    impl TestWorkspace {
        fn new() -> Self {
            let mut path = std::env::temp_dir();
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let id = NEXT_TEST_WORKSPACE_ID.fetch_add(1, Ordering::Relaxed);
            path.push(format!(
                "locus-ffi-test-{}-{nanos}-{id}",
                std::process::id()
            ));
            fs::create_dir(&path).unwrap();

            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }

        fn create_dir(&self, name: &str) -> PathBuf {
            let path = self.path.join(name);
            fs::create_dir(&path).unwrap();
            path
        }

        fn create_file(&self, name: &str) -> PathBuf {
            self.create_file_with_contents(name, "")
        }

        fn create_file_with_contents(&self, name: &str, contents: &str) -> PathBuf {
            let path = self.path.join(name);
            fs::write(&path, contents).unwrap();
            path
        }
    }

    impl Drop for TestWorkspace {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
