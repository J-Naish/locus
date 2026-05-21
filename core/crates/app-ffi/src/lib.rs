use std::ffi::c_char;

pub const ABI_VERSION: u32 = 1;

static VERSION: &[u8] = concat!(env!("CARGO_PKG_VERSION"), "\0").as_bytes();

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

#[cfg(test)]
mod tests {
    use std::ffi::CStr;

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
}
