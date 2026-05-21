use std::ffi::c_char;

static VERSION: &[u8] = concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes();

#[no_mangle]
pub extern "C" fn locus_core_version() -> *const c_char {
    VERSION.as_ptr().cast()
}
