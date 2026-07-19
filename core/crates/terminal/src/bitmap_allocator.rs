//! Offset-addressed bitmap allocator for page-local backing storage.

#![expect(dead_code, reason = "Phase T4b consumes the page substrate")]

use crate::size::{align_forward, BufValue, Offset, OffsetBuf, OffsetSlice};

pub(crate) const BASE_ALIGN: usize = u64::ALIGN;
const BITMAP_BIT_SIZE: usize = u64::BITS as usize;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct OutOfMemory;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Layout {
    pub total_size: usize,
    pub bitmap_count: usize,
    pub bitmap_start: usize,
    pub chunks_start: usize,
}

/// Bitmap allocator that lives entirely inside a caller-owned page buffer.
///
/// A set bit means the chunk is free. This mirrors Ghostty's allocator so the
/// future page layout can be copied as one flat allocation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct BitmapAllocator<const CHUNK_SIZE: usize> {
    bitmap: Offset<u64>,
    bitmap_count: usize,
    chunks: Offset<u8>,
}

impl<const CHUNK_SIZE: usize> BitmapAllocator<CHUNK_SIZE> {
    pub(crate) const BASE_ALIGN: usize = BASE_ALIGN;
    pub(crate) const BITMAP_BIT_SIZE: usize = BITMAP_BIT_SIZE;

    pub(crate) fn init(buf: OffsetBuf, layout: Layout, backing: &mut [u8]) -> Self {
        debug_assert!(CHUNK_SIZE.is_power_of_two());
        debug_assert_eq!(buf.start() % Self::BASE_ALIGN, 0);

        let bitmap = buf.member::<u64>(layout.bitmap_start);
        for index in 0..layout.bitmap_count {
            bitmap.set(backing, index, u64::MAX);
        }

        Self {
            bitmap,
            bitmap_count: layout.bitmap_count,
            chunks: buf.member::<u8>(layout.chunks_start),
        }
    }

    pub(crate) const fn layout(capacity_bytes: usize) -> Layout {
        let aligned_capacity = align_forward(capacity_bytes, CHUNK_SIZE);
        let chunk_count = aligned_capacity / CHUNK_SIZE;
        let aligned_chunk_count = align_forward(chunk_count, BITMAP_BIT_SIZE);
        let bitmap_count = aligned_chunk_count / BITMAP_BIT_SIZE;
        let bitmap_start = 0;
        let bitmap_end = u64::SIZE * bitmap_count;
        let chunks_start = align_forward(bitmap_end, u8::ALIGN);
        // DEVIATION: Ghostty's bitmap_allocator.zig:222 multiplies the
        // byte-aligned capacity by CHUNK_SIZE again. The bitmap addresses the
        // 64-bit-aligned chunk count, so backing exactly that many chunks both
        // covers its phantom tail bits and avoids reserving unusable space.
        let chunks_end = chunks_start + aligned_chunk_count * CHUNK_SIZE;

        Layout {
            total_size: chunks_end,
            bitmap_count,
            bitmap_start,
            chunks_start,
        }
    }

    pub(crate) const fn bytes_required<T: BufValue>(n: usize) -> usize {
        align_forward(T::SIZE * n, CHUNK_SIZE)
    }

    pub(crate) fn alloc<T: BufValue>(
        &mut self,
        backing: &mut [u8],
        n: usize,
    ) -> Result<OffsetSlice<T>, OutOfMemory> {
        debug_assert_eq!(CHUNK_SIZE % T::ALIGN, 0);
        debug_assert!(n > 0);

        let byte_count = T::SIZE.checked_mul(n).ok_or(OutOfMemory)?;
        let chunk_count = byte_count.div_ceil(CHUNK_SIZE);
        let idx = self
            .find_free_chunks(backing, chunk_count)
            .ok_or(OutOfMemory)?;
        let offset = Offset::new(self.chunks.offset + (idx * CHUNK_SIZE) as u32);
        Ok(OffsetSlice::new(offset, n))
    }

    pub(crate) fn free<T: BufValue>(&mut self, backing: &mut [u8], slice: OffsetSlice<T>) {
        let aligned_len = align_forward(slice.len * T::SIZE, CHUNK_SIZE);
        let chunk_count = aligned_len / CHUNK_SIZE;
        let chunk_idx = (slice.offset.offset - self.chunks.offset) as usize / CHUNK_SIZE;

        let mut bitmap_index = chunk_idx / BITMAP_BIT_SIZE;
        let mut remaining = chunk_count;

        {
            let bit = chunk_idx % BITMAP_BIT_SIZE;
            let bits = remaining.min(BITMAP_BIT_SIZE - bit);
            let mask = (u64::MAX >> (BITMAP_BIT_SIZE - bits)) << bit;
            let bitmap = self.bitmap.get(backing, bitmap_index) | mask;
            self.bitmap.set(backing, bitmap_index, bitmap);
            remaining -= bits;
        }

        bitmap_index += 1;
        while remaining > BITMAP_BIT_SIZE {
            self.bitmap.set(backing, bitmap_index, u64::MAX);
            bitmap_index += 1;
            remaining -= BITMAP_BIT_SIZE;
        }

        if remaining > 0 {
            let mask = u64::MAX >> (BITMAP_BIT_SIZE - remaining);
            let bitmap = self.bitmap.get(backing, bitmap_index) | mask;
            self.bitmap.set(backing, bitmap_index, bitmap);
        }
    }

    pub(crate) const fn capacity_bytes(self) -> usize {
        self.bitmap_count * BITMAP_BIT_SIZE * CHUNK_SIZE
    }

    pub(crate) fn used_bytes(self, backing: &[u8]) -> usize {
        let mut free_chunks = 0usize;
        for index in 0..self.bitmap_count {
            free_chunks += self.bitmap.get(backing, index).count_ones() as usize;
        }
        let total_chunks = self.bitmap_count * BITMAP_BIT_SIZE;
        (total_chunks - free_chunks) * CHUNK_SIZE
    }

    fn is_allocated<T: BufValue>(self, backing: &[u8], slice: OffsetSlice<T>) -> bool {
        let aligned_len = align_forward(slice.len * T::SIZE, CHUNK_SIZE);
        let chunk_count = aligned_len / CHUNK_SIZE;
        let chunk_idx = (slice.offset.offset - self.chunks.offset) as usize / CHUNK_SIZE;

        for chunk in chunk_idx..chunk_idx + chunk_count {
            let bitmap = chunk / BITMAP_BIT_SIZE;
            let bit = chunk % BITMAP_BIT_SIZE;
            if self.bitmap.get(backing, bitmap) & (1u64 << bit) != 0 {
                return false;
            }
        }
        true
    }

    fn bitmaps(self, backing: &[u8]) -> Vec<u64> {
        (0..self.bitmap_count)
            .map(|index| self.bitmap.get(backing, index))
            .collect()
    }

    fn find_free_chunks(self, backing: &mut [u8], n: usize) -> Option<usize> {
        let start = find_free_chunk_start(self.bitmap_count, n, |index| {
            self.bitmap.get(backing, index)
        })?;
        self.mark_chunks_allocated(backing, start, n);
        Some(start)
    }

    fn mark_chunks_allocated(self, backing: &mut [u8], start: usize, n: usize) {
        let mut bitmap_index = start / BITMAP_BIT_SIZE;
        let mut bit = start % BITMAP_BIT_SIZE;
        let mut remaining = n;

        while remaining > 0 {
            let bits = remaining.min(BITMAP_BIT_SIZE - bit);
            let mask = (u64::MAX >> (BITMAP_BIT_SIZE - bits)) << bit;
            let bitmap = self.bitmap.get(backing, bitmap_index) & !mask;
            self.bitmap.set(backing, bitmap_index, bitmap);
            remaining -= bits;
            bitmap_index += 1;
            bit = 0;
        }
    }
}

fn find_free_chunks(bitmaps: &mut [u64], n: usize) -> Option<usize> {
    let start = find_free_chunk_start(bitmaps.len(), n, |index| bitmaps[index])?;
    mark_chunks_allocated(bitmaps, start, n);
    Some(start)
}

fn find_free_chunk_start(
    bitmap_count: usize,
    n: usize,
    mut bitmap_at: impl FnMut(usize) -> u64,
) -> Option<usize> {
    if n > BITMAP_BIT_SIZE {
        let mut i = 0usize;
        'search: while i < bitmap_count {
            let prefix = (!bitmap_at(i)).leading_zeros() as usize;
            if prefix == 0 {
                i += 1;
                continue;
            }

            let start_bitmap = i;
            let start_bit = BITMAP_BIT_SIZE - prefix;
            let mut remaining = n - prefix;

            i += 1;
            while remaining > BITMAP_BIT_SIZE {
                if i >= bitmap_count {
                    return None;
                }
                if bitmap_at(i) != u64::MAX {
                    continue 'search;
                }
                remaining -= BITMAP_BIT_SIZE;
                i += 1;
            }

            if i >= bitmap_count || ((!bitmap_at(i)).trailing_zeros() as usize) < remaining {
                continue;
            }
            return Some(start_bitmap * BITMAP_BIT_SIZE + start_bit);
        }

        return None;
    }

    debug_assert!(n <= BITMAP_BIT_SIZE);
    for idx in 0..bitmap_count {
        let bitmap = bitmap_at(idx);
        let mut shifted = bitmap;
        for shift in 1..n {
            shifted &= bitmap >> shift;
        }
        if shifted == 0 {
            continue;
        }

        let bit = shifted.trailing_zeros() as usize;
        return Some(idx * BITMAP_BIT_SIZE + bit);
    }

    None
}

fn mark_chunks_allocated(bitmaps: &mut [u64], start: usize, n: usize) {
    let mut bitmap_index = start / BITMAP_BIT_SIZE;
    let mut bit = start % BITMAP_BIT_SIZE;
    let mut remaining = n;

    while remaining > 0 {
        let bits = remaining.min(BITMAP_BIT_SIZE - bit);
        let mask = (u64::MAX >> (BITMAP_BIT_SIZE - bits)) << bit;
        bitmaps[bitmap_index] &= !mask;
        remaining -= bits;
        bitmap_index += 1;
        bit = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn backing<const CHUNK_SIZE: usize>(cap: usize) -> (Vec<u8>, BitmapAllocator<CHUNK_SIZE>) {
        let layout = BitmapAllocator::<CHUNK_SIZE>::layout(cap);
        let mut buf = vec![0; layout.total_size];
        let allocator = BitmapAllocator::<CHUNK_SIZE>::init(OffsetBuf::init(), layout, &mut buf);
        (buf, allocator)
    }

    #[test]
    fn find_free_chunks_single_found() {
        // ghostty: "findFreeChunks single found" (bitmap_allocator.zig:335)
        let mut bitmaps =
            [0b10000000_00000000_00000000_00000000_00000000_00000000_00001110_00000000];
        let idx = find_free_chunks(&mut bitmaps, 2);
        assert_eq!(idx, Some(9));
        assert_eq!(
            bitmaps[0],
            0b10000000_00000000_00000000_00000000_00000000_00000000_00001000_00000000
        );
    }

    #[test]
    fn find_free_chunks_single_not_found() {
        // ghostty: "findFreeChunks single not found" (bitmap_allocator.zig:351)
        let mut bitmaps =
            [0b10000111_00000000_00000000_00000000_00000000_00000000_00000000_00000000];
        assert_eq!(find_free_chunks(&mut bitmaps, 4), None);
    }

    #[test]
    fn find_free_chunks_multiple_found() {
        // ghostty: "findFreeChunks multiple found" (bitmap_allocator.zig:359)
        let mut bitmaps = [
            0b10000111_00000000_00000000_00000000_00000000_00000000_00000000_01110000,
            0b10000000_00111110_00000000_00000000_00000000_00000000_00111110_00000000,
        ];
        assert_eq!(find_free_chunks(&mut bitmaps, 4), Some(73));
        assert_eq!(
            bitmaps[1],
            0b10000000_00111110_00000000_00000000_00000000_00000000_00100000_00000000
        );
    }

    #[test]
    fn find_free_chunks_exactly_64_chunks() {
        // ghostty: "findFreeChunks exactly 64 chunks" (bitmap_allocator.zig:376)
        let mut bitmaps = [u64::MAX];
        assert_eq!(find_free_chunks(&mut bitmaps, 64), Some(0));
        assert_eq!(bitmaps[0], 0);
    }

    #[test]
    fn find_free_chunks_larger_than_64_chunks() {
        // ghostty: "findFreeChunks larger than 64 chunks" (bitmap_allocator.zig:390)
        let mut bitmaps = [u64::MAX, u64::MAX];
        assert_eq!(find_free_chunks(&mut bitmaps, 65), Some(0));
        assert_eq!(bitmaps, [0, u64::MAX - 1]);
    }

    #[test]
    fn find_free_chunks_larger_than_64_chunks_not_at_beginning() {
        // ghostty: "findFreeChunks larger than 64 chunks not at beginning" (bitmap_allocator.zig:408)
        let mut bitmaps = [
            0b11111111_00000000_00000000_00000000_00000000_00000000_00000000_00000000,
            u64::MAX,
            u64::MAX,
        ];
        assert_eq!(find_free_chunks(&mut bitmaps, 65), Some(56));
        assert_eq!(bitmaps[0], 0);
        assert_eq!(
            bitmaps[1],
            0b11111110_00000000_00000000_00000000_00000000_00000000_00000000_00000000
        );
        assert_eq!(bitmaps[2], u64::MAX);
    }

    #[test]
    fn find_free_chunks_larger_than_64_chunks_exact() {
        // ghostty: "findFreeChunks larger than 64 chunks exact" (bitmap_allocator.zig:433)
        let mut bitmaps = [u64::MAX, u64::MAX];
        assert_eq!(find_free_chunks(&mut bitmaps, 128), Some(0));
        assert_eq!(bitmaps, [0, 0]);
    }

    #[test]
    fn bitmap_allocator_layout_uses_one_bitmap_for_one_word_capacity() {
        // ghostty: "BitmapAllocator layout" (bitmap_allocator.zig:451)
        let layout = BitmapAllocator::<4>::layout(64 * 4);
        assert_eq!(layout.bitmap_count, 1);
    }

    #[test]
    fn bitmap_allocator_alloc_sequentially() {
        // ghostty: "BitmapAllocator alloc sequentially" (bitmap_allocator.zig:461)
        let (mut buf, mut allocator) = backing::<4>(64);
        let first = allocator.alloc::<u8>(&mut buf, 1).unwrap();
        first.offset.set(&mut buf, 0, b'A');
        let second = allocator.alloc::<u8>(&mut buf, 1).unwrap();
        assert_eq!(second.offset.offset, first.offset.offset + 4);
        allocator.free(&mut buf, first);
        let third = allocator.alloc::<u8>(&mut buf, 1).unwrap();
        assert_eq!(third.offset.offset, first.offset.offset);
    }

    #[test]
    fn bitmap_allocator_alloc_non_byte() {
        // ghostty: "BitmapAllocator alloc non-byte" (bitmap_allocator.zig:484)
        let (mut buf, mut allocator) = backing::<4>(128);
        let first = allocator.alloc::<u32>(&mut buf, 1).unwrap();
        first.offset.set(&mut buf, 0, 0x41);
        let second = allocator.alloc::<u32>(&mut buf, 1).unwrap();
        assert_eq!(second.offset.offset, first.offset.offset + 4);
        allocator.free(&mut buf, first);
        let third = allocator.alloc::<u32>(&mut buf, 1).unwrap();
        assert_eq!(third.offset.offset, first.offset.offset);
    }

    #[test]
    fn bitmap_allocator_alloc_non_byte_multi_chunk() {
        // ghostty: "BitmapAllocator alloc non-byte multi-chunk" (bitmap_allocator.zig:507)
        let (mut buf, mut allocator) = backing::<16>(128);
        let first = allocator.alloc::<u32>(&mut buf, 6).unwrap();
        assert_eq!(first.len, 6);
        let second = allocator.alloc::<u32>(&mut buf, 1).unwrap();
        assert_eq!(second.offset.offset, first.offset.offset + (4 * 4 * 2));
        allocator.free(&mut buf, first);
        let third = allocator.alloc::<u32>(&mut buf, 1).unwrap();
        assert_eq!(third.offset.offset, first.offset.offset);
    }

    #[test]
    fn bitmap_allocator_alloc_large() {
        // ghostty: "BitmapAllocator alloc large" (bitmap_allocator.zig:532)
        let (mut buf, mut allocator) = backing::<2>(256);
        let slice = allocator.alloc::<u8>(&mut buf, 129).unwrap();
        slice.offset.set(&mut buf, 0, b'A');
        allocator.free(&mut buf, slice);
    }

    #[test]
    fn bitmap_allocator_alloc_and_free_one_bitmap() {
        // ghostty: "BitmapAllocator alloc and free one bitmap" (bitmap_allocator.zig:548)
        let (mut buf, mut allocator) = backing::<1>(BitmapAllocator::<1>::BITMAP_BIT_SIZE * 3);
        let slice = allocator
            .alloc::<u8>(&mut buf, BitmapAllocator::<1>::BITMAP_BIT_SIZE)
            .unwrap();
        assert!(allocator.is_allocated(&buf, slice));
        allocator.free(&mut buf, slice);
        assert!(!allocator.is_allocated(&buf, slice));
        assert_eq!(allocator.bitmaps(&buf), vec![u64::MAX; 3]);
    }

    #[test]
    fn bitmap_allocator_alloc_and_free_half_bitmap() {
        // ghostty: "BitmapAllocator alloc and free half bitmap" (bitmap_allocator.zig:587)
        let (mut buf, mut allocator) = backing::<1>(BitmapAllocator::<1>::BITMAP_BIT_SIZE * 3);
        let slice = allocator
            .alloc::<u8>(&mut buf, BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        assert!(allocator.is_allocated(&buf, slice));
        allocator.free(&mut buf, slice);
        assert_eq!(allocator.bitmaps(&buf), vec![u64::MAX; 3]);
    }

    #[test]
    fn bitmap_allocator_alloc_and_free_two_half_bitmaps() {
        // ghostty: "BitmapAllocator alloc and free two half bitmaps" (bitmap_allocator.zig:626)
        let (mut buf, mut allocator) = backing::<1>(BitmapAllocator::<1>::BITMAP_BIT_SIZE * 3);
        let first = allocator
            .alloc::<u8>(&mut buf, BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        let second = allocator
            .alloc::<u8>(&mut buf, BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        assert!(allocator.is_allocated(&buf, second));
        allocator.free(&mut buf, second);
        allocator.free(&mut buf, first);
        assert_eq!(allocator.bitmaps(&buf), vec![u64::MAX; 3]);
    }

    #[test]
    fn bitmap_allocator_alloc_and_free_one_and_a_half_bitmaps() {
        // ghostty: "BitmapAllocator alloc and free 1.5 bitmaps" (bitmap_allocator.zig:678)
        let (mut buf, mut allocator) = backing::<1>(BitmapAllocator::<1>::BITMAP_BIT_SIZE * 3);
        let slice = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        allocator.free(&mut buf, slice);
        assert_eq!(allocator.bitmaps(&buf), vec![u64::MAX; 3]);
    }

    #[test]
    fn bitmap_allocator_alloc_and_free_two_one_and_a_half_bitmaps() {
        // ghostty: "BitmapAllocator alloc and free two 1.5 bitmaps" (bitmap_allocator.zig:717)
        let (mut buf, mut allocator) = backing::<1>(BitmapAllocator::<1>::BITMAP_BIT_SIZE * 3);
        let first = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        let second = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        allocator.free(&mut buf, second);
        allocator.free(&mut buf, first);
        assert_eq!(allocator.bitmaps(&buf), vec![u64::MAX; 3]);
    }

    #[test]
    fn bitmap_allocator_alloc_and_free_one_and_a_half_bitmaps_offset_by_three_quarters() {
        // ghostty: "BitmapAllocator alloc and free 1.5 bitmaps offset by 0.75" (bitmap_allocator.zig:775)
        let (mut buf, mut allocator) = backing::<1>(BitmapAllocator::<1>::BITMAP_BIT_SIZE * 3);
        let first = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 4)
            .unwrap();
        let second = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        allocator.free(&mut buf, second);
        allocator.free(&mut buf, first);
        assert_eq!(allocator.bitmaps(&buf), vec![u64::MAX; 3]);
    }

    #[test]
    fn bitmap_allocator_alloc_and_free_three_three_quarter_bitmaps() {
        // ghostty: "BitmapAllocator alloc and free three 0.75 bitmaps" (bitmap_allocator.zig:835)
        let (mut buf, mut allocator) = backing::<1>(BitmapAllocator::<1>::BITMAP_BIT_SIZE * 3);
        let first = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 4)
            .unwrap();
        let second = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 4)
            .unwrap();
        let third = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 4)
            .unwrap();
        allocator.free(&mut buf, second);
        allocator.free(&mut buf, first);
        allocator.free(&mut buf, third);
        assert_eq!(allocator.bitmaps(&buf), vec![u64::MAX; 3]);
    }

    #[test]
    fn bitmap_allocator_alloc_and_free_two_one_and_a_half_bitmaps_offset_three_quarters() {
        // ghostty: "BitmapAllocator alloc and free two 1.5 bitmaps offset 0.75" (bitmap_allocator.zig:912)
        let (mut buf, mut allocator) = backing::<1>(BitmapAllocator::<1>::BITMAP_BIT_SIZE * 4);
        let first = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 4)
            .unwrap();
        let second = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        let third = allocator
            .alloc::<u8>(&mut buf, 3 * BitmapAllocator::<1>::BITMAP_BIT_SIZE / 2)
            .unwrap();
        allocator.free(&mut buf, second);
        allocator.free(&mut buf, first);
        allocator.free(&mut buf, third);
        assert_eq!(allocator.bitmaps(&buf), vec![u64::MAX; 4]);
    }

    #[test]
    fn bitmap_allocator_bytes_required_rounds_to_chunk_size() {
        // ghostty: "BitmapAllocator bytesRequired" (bitmap_allocator.zig:984)
        assert_eq!(BitmapAllocator::<16>::bytes_required::<u8>(1), 16);
        assert_eq!(BitmapAllocator::<16>::bytes_required::<u8>(16), 16);
        assert_eq!(BitmapAllocator::<16>::bytes_required::<u8>(17), 32);
        assert_eq!(BitmapAllocator::<16>::bytes_required::<u32>(1), 16);
        assert_eq!(BitmapAllocator::<16>::bytes_required::<u32>(4), 16);
        assert_eq!(BitmapAllocator::<16>::bytes_required::<u32>(5), 32);
        assert_eq!(BitmapAllocator::<4>::bytes_required::<u32>(2), 8);
        assert_eq!(BitmapAllocator::<32>::bytes_required::<u8>(33), 64);
    }

    #[test]
    fn bitmap_layout_backs_every_addressable_chunk() {
        for capacity in [1, 15, 16, 17, 1_023, 1_024, 1_025] {
            let layout = BitmapAllocator::<16>::layout(capacity);
            let mut backing = vec![0; layout.total_size];
            let mut allocator =
                BitmapAllocator::<16>::init(OffsetBuf::init(), layout, &mut backing);

            for _ in 0..allocator.bitmap_count * BITMAP_BIT_SIZE {
                let slice = allocator.alloc::<u8>(&mut backing, 1).unwrap();
                let end = slice.offset.offset as usize + 16;
                assert!(end <= layout.total_size);
            }
            assert!(allocator.alloc::<u8>(&mut backing, 1).is_err());
        }
    }

    #[test]
    fn alloc_mutates_only_touched_words() {
        let (mut backing, mut allocator) = backing::<1>(BITMAP_BIT_SIZE * 4);
        allocator.alloc::<u8>(&mut backing, 56).unwrap();
        let before = allocator.bitmaps(&backing);

        allocator.alloc::<u8>(&mut backing, 65).unwrap();

        let after = allocator.bitmaps(&backing);
        let changed: Vec<_> = before
            .iter()
            .zip(&after)
            .enumerate()
            .filter_map(|(index, (before, after))| (before != after).then_some(index))
            .collect();
        assert_eq!(changed, vec![0, 1]);
        assert_eq!(&before[2..], &after[2..]);
    }
}
