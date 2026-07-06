//! Grid size and page offset primitives.

#![expect(dead_code, reason = "Phase T4b consumes the page substrate")]

use std::fmt;
use std::marker::PhantomData;

/// Maximum page size in bytes (ghostty: `max_page_size`).
pub(crate) const MAX_PAGE_SIZE: usize = u32::MAX as usize;

/// Integer type for byte offsets inside a page buffer.
pub(crate) type OffsetInt = u32;

/// Integer type for row/column counts (ghostty: `CellCountInt = u16`).
pub type CellCountInt = u16;

/// Integer type for style IDs.
///
/// Ghostty keeps this equal to `CellCountInt` because a single-row page can
/// have at most one style per cell. `RefCountedSet` reserves ID 0, so the
/// theoretical maximum is one value short.
pub(crate) type StyleCountInt = CellCountInt;

/// Integer type for hyperlink IDs.
pub(crate) type HyperlinkCountInt = CellCountInt;

/// Maximum byte count for grapheme backing storage.
pub(crate) type GraphemeBytesInt = u32;

/// Maximum byte count for string backing storage.
pub(crate) type StringBytesInt = u32;

/// Values storable inside a page buffer.
///
/// Implementations are fixed-width, little-endian, and fully valid for any bit
/// pattern. Out-of-range access intentionally panics through slice indexing;
/// that is the safe Rust equivalent of Ghostty's checked pointer access.
pub(crate) trait BufValue: Copy {
    const SIZE: usize;
    const ALIGN: usize;

    fn read(buf: &[u8], at: usize) -> Self;
    fn write(self, buf: &mut [u8], at: usize);
}

macro_rules! impl_buf_value_int {
    ($ty:ty, $size:literal, $align:literal) => {
        impl BufValue for $ty {
            const SIZE: usize = $size;
            const ALIGN: usize = $align;

            fn read(buf: &[u8], at: usize) -> Self {
                let mut bytes = [0u8; $size];
                bytes.copy_from_slice(&buf[at..at + $size]);
                <$ty>::from_le_bytes(bytes)
            }

            fn write(self, buf: &mut [u8], at: usize) {
                buf[at..at + $size].copy_from_slice(&self.to_le_bytes());
            }
        }
    };
}

impl BufValue for u8 {
    const SIZE: usize = 1;
    const ALIGN: usize = 1;

    fn read(buf: &[u8], at: usize) -> Self {
        buf[at]
    }

    fn write(self, buf: &mut [u8], at: usize) {
        buf[at] = self;
    }
}

impl_buf_value_int!(u16, 2, 2);
impl_buf_value_int!(u32, 4, 4);
impl_buf_value_int!(u64, 8, 8);
impl_buf_value_int!(u128, 16, 16);

/// Typed byte offset from the page base to an item of type `T`.
pub(crate) struct Offset<T> {
    pub offset: OffsetInt,
    _marker: PhantomData<T>,
}

impl<T> Offset<T> {
    pub(crate) const fn new(offset: OffsetInt) -> Self {
        Self {
            offset,
            _marker: PhantomData,
        }
    }
}

impl<T> Default for Offset<T> {
    fn default() -> Self {
        Self::new(0)
    }
}

impl<T> Copy for Offset<T> {}

impl<T> Clone for Offset<T> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<T> fmt::Debug for Offset<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Offset")
            .field("offset", &self.offset)
            .finish()
    }
}

impl<T> PartialEq for Offset<T> {
    fn eq(&self, other: &Self) -> bool {
        self.offset == other.offset
    }
}

impl<T> Eq for Offset<T> {}

impl<T: BufValue> Offset<T> {
    pub(crate) fn get(self, buf: &[u8], index: usize) -> T {
        let at = self.offset as usize + index * T::SIZE;
        T::read(buf, at)
    }

    pub(crate) fn set(self, buf: &mut [u8], index: usize, value: T) {
        debug_assert_eq!((self.offset as usize) % T::ALIGN, 0);
        let at = self.offset as usize + index * T::SIZE;
        value.write(buf, at);
    }
}

impl<T> BufValue for Offset<T> {
    const SIZE: usize = OffsetInt::SIZE;
    const ALIGN: usize = OffsetInt::ALIGN;

    fn read(buf: &[u8], at: usize) -> Self {
        Self::new(OffsetInt::read(buf, at))
    }

    fn write(self, buf: &mut [u8], at: usize) {
        self.offset.write(buf, at);
    }
}

/// Offset-addressed slice.
pub(crate) struct OffsetSlice<T> {
    pub offset: Offset<T>,
    pub len: usize,
}

impl<T> Copy for OffsetSlice<T> {}

impl<T> Clone for OffsetSlice<T> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<T> OffsetSlice<T> {
    pub(crate) const fn new(offset: Offset<T>, len: usize) -> Self {
        Self { offset, len }
    }
}

/// Offset builder for structures that occupy a region inside one page buffer.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct OffsetBuf {
    base: usize,
    offset: usize,
}

impl OffsetBuf {
    pub(crate) const fn init() -> Self {
        Self { base: 0, offset: 0 }
    }

    pub(crate) const fn init_offset(base_offset: usize) -> Self {
        Self {
            base: 0,
            offset: base_offset,
        }
    }

    pub(crate) const fn start(self) -> usize {
        self.base + self.offset
    }

    pub(crate) fn member<T>(&self, len_position: usize) -> Offset<T> {
        Offset::new((self.offset + len_position) as OffsetInt)
    }

    pub(crate) const fn add(self, offset: usize) -> Self {
        Self {
            base: self.base,
            offset: self.offset + offset,
        }
    }

    pub(crate) const fn rebase(self, offset: usize) -> Self {
        Self {
            base: self.start() + offset,
            offset: 0,
        }
    }
}

/// Align `value` forward to `alignment`.
pub(crate) const fn align_forward(value: usize, alignment: usize) -> usize {
    debug_assert!(alignment > 0);
    let rem = value % alignment;
    if rem == 0 {
        value
    } else {
        value + (alignment - rem)
    }
}

// Ghostty's `getOffset` is pointer-identity based. This Rust port keeps only
// byte offsets; call sites compute indices directly instead of subtracting raw
// pointers.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offset_int_matches_ghostty_width() {
        // ghostty: "Offset" (size.zig:174)
        assert_eq!(std::mem::size_of::<OffsetInt>(), std::mem::size_of::<u32>());
        assert_eq!(MAX_PAGE_SIZE, u32::MAX as usize);
    }

    #[test]
    fn offset_get_set_round_trips_at_index() {
        // ghostty pointer tests are adapted: safe Rust reads/writes through a
        // typed byte offset instead of returning raw pointers.
        let offset = Offset::<u32>::new(8);
        let mut buf = [0u8; 24];
        offset.set(&mut buf, 2, 0xAABB_CCDD);
        assert_eq!(offset.get(&buf, 2), 0xAABB_CCDD);
        assert_eq!(&buf[16..20], &[0xDD, 0xCC, 0xBB, 0xAA]);
    }

    #[test]
    fn offset_buf_member_add_rebase_match_ghostty_arithmetic() {
        // ghostty pointer/getOffset tests are adapted: verify exact byte
        // arithmetic for member/add/rebase without raw pointer identity.
        let root = OffsetBuf::init_offset(32);
        let member = root.member::<u64>(16);
        assert_eq!(member.offset, 48);

        let child = root.add(24);
        assert_eq!(child.start(), 56);
        assert_eq!(child.member::<u16>(10).offset, 66);

        let rebased = child.rebase(8);
        assert_eq!(rebased.start(), 64);
        assert_eq!(rebased.member::<u8>(3).offset, 3);
    }
}
