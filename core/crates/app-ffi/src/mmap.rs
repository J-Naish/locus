//! Read-only file memory mapping, used as a zero-copy [`ContentBytes`] source
//! for large files so opening a multi-gigabyte file does not allocate its bytes
//! on the heap (the OS page cache backs the mapping and can reclaim pages).
//!
//! This is the one place the raw `mmap`/`munmap` syscalls live. They are
//! declared directly (rather than pulling in a crate) to keep the workspace
//! free of third-party dependencies; the `unsafe` is confined to this module
//! and `app-core` stays `unsafe`-free behind the [`ContentBytes`] trait.
//!
//! Unix only for now (macOS is the first target). A future Windows core would
//! add its own mapping behind the same trait.

#![cfg(unix)]

use std::ffi::c_void;
use std::fs::File;
use std::io;
use std::os::unix::io::AsRawFd;
use std::path::Path;
use std::ptr::NonNull;

use app_core::text_buffer::ContentBytes;

// POSIX values, identical on macOS and Linux. Kept local to avoid a `libc`
// dependency for two constants and two function declarations.
const PROT_READ: i32 = 0x01;
const MAP_PRIVATE: i32 = 0x0002;

extern "C" {
    fn mmap(
        addr: *mut c_void,
        len: usize,
        prot: i32,
        flags: i32,
        fd: i32,
        offset: i64,
    ) -> *mut c_void;
    fn munmap(addr: *mut c_void, len: usize) -> i32;
}

/// A read-only memory map of a file's bytes, owned by Rust and unmapped on drop.
///
/// SIGBUS caveat: if the underlying file is truncated or replaced while it is
/// mapped, touching a now-missing page faults the process. The platform's
/// file-change monitor detects external edits and reloads the document, which
/// matches the read-only, review-oriented use of large files; full SIGBUS
/// trapping is out of scope.
pub(crate) struct MmapBytes {
    ptr: NonNull<u8>,
    len: usize,
}

impl MmapBytes {
    /// Maps `path` read-only.
    ///
    /// Returns `Ok(None)` only when the file is empty (there is nothing to map),
    /// so the caller can fall back to a cheap owned read. A mapping failure is
    /// returned as `Err`, never as `None`: the caller must not silently fall
    /// back to an owned read of a file large enough to have been mapped, which
    /// could exhaust memory.
    pub(crate) fn open(path: &Path) -> io::Result<Option<Self>> {
        let file = File::open(path)?;
        let len = usize::try_from(file.metadata()?.len())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "file is too large to map"))?;
        if len == 0 {
            return Ok(None);
        }
        // `slice::from_raw_parts` (in `as_bytes`) requires the length to fit in
        // `isize`; reject anything larger at the boundary rather than risk UB.
        if len > isize::MAX as usize {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "file is too large to map safely",
            ));
        }

        // SAFETY: `fd` is a live descriptor for the duration of this call. A
        // null address hint lets the kernel choose the location; the mapping is
        // read-only and private over exactly `len` bytes. The result is checked
        // against MAP_FAILED / null before any use.
        let addr = unsafe {
            mmap(
                std::ptr::null_mut(),
                len,
                PROT_READ,
                MAP_PRIVATE,
                file.as_raw_fd(),
                0,
            )
        };

        // mmap reports failure as MAP_FAILED, defined as `(void *) -1`. Capture
        // the OS error before dropping `file`, since `close` may overwrite errno.
        let result = if addr.is_null() || addr == (-1_isize as *mut c_void) {
            Err(io::Error::last_os_error())
        } else {
            match NonNull::new(addr.cast::<u8>()) {
                Some(ptr) => Ok(Some(Self { ptr, len })),
                None => Err(io::Error::last_os_error()),
            }
        };
        // The mapping holds its own reference to the file, so the descriptor can
        // be closed now without affecting it.
        drop(file);
        result
    }
}

impl ContentBytes for MmapBytes {
    fn as_bytes(&self) -> &[u8] {
        // SAFETY: `ptr` addresses `len` bytes of a valid read-only mapping that
        // lives as long as `self`, and nothing ever writes through it.
        unsafe { std::slice::from_raw_parts(self.ptr.as_ptr(), self.len) }
    }
}

impl Drop for MmapBytes {
    fn drop(&mut self) {
        // SAFETY: `ptr`/`len` are exactly the region returned by `mmap` in
        // `open` and have not been unmapped before, so unmapping once is correct.
        unsafe {
            munmap(self.ptr.as_ptr().cast::<c_void>(), self.len);
        }
    }
}

// SAFETY: the mapping is read-only with no interior mutability, so a shared
// `&MmapBytes` is safe to use from multiple threads and the value is safe to
// move between threads.
unsafe impl Send for MmapBytes {}
unsafe impl Sync for MmapBytes {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    fn unique_temp_path(label: &str) -> std::path::PathBuf {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "locus-mmap-{}-{}-{}",
            std::process::id(),
            id,
            label
        ))
    }

    #[test]
    fn maps_file_bytes_read_only() {
        let path = unique_temp_path("hello.txt");
        std::fs::write(&path, "hello\nworld").unwrap();
        let mapped = MmapBytes::open(&path).unwrap().expect("mapping");
        assert_eq!(mapped.as_bytes(), b"hello\nworld");
        // Drop unmaps; reading again through a fresh map still works.
        drop(mapped);
        let again = MmapBytes::open(&path).unwrap().expect("mapping");
        assert_eq!(again.as_bytes().len(), 11);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn empty_file_maps_to_none() {
        let path = unique_temp_path("empty.txt");
        std::fs::write(&path, "").unwrap();
        assert!(MmapBytes::open(&path).unwrap().is_none());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn missing_file_is_an_error() {
        let path = unique_temp_path("missing.txt");
        let _ = std::fs::remove_file(&path);
        assert!(MmapBytes::open(&path).is_err());
    }
}
