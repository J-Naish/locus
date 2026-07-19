//! Offset-addressed hash map for page-local storage.

#![expect(dead_code, reason = "Phase T4b consumes the page substrate")]

use crate::bitmap_allocator::OutOfMemory;
use crate::size::{align_forward, BufValue, Offset, OffsetBuf};

type Size = u32;
type Hash = u64;

const USED_MASK: u8 = 0b1000_0000;
const FINGERPRINT_MASK: u8 = 0b0111_1111;
const TOMBSTONE: u8 = 1;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Metadata(u8);

impl Metadata {
    const fn is_used(self) -> bool {
        self.0 & USED_MASK != 0
    }

    const fn is_tombstone(self) -> bool {
        self.0 == TOMBSTONE
    }

    const fn is_free(self) -> bool {
        self.0 == 0
    }

    const fn fingerprint(self) -> u8 {
        self.0 & FINGERPRINT_MASK
    }

    const fn take_fingerprint(hash: Hash) -> u8 {
        ((hash >> (Hash::BITS - 7)) as u8) & FINGERPRINT_MASK
    }

    const fn filled(fingerprint: u8) -> Self {
        Self(USED_MASK | (fingerprint & FINGERPRINT_MASK))
    }

    const fn removed() -> Self {
        Self(TOMBSTONE)
    }
}

impl BufValue for Metadata {
    const SIZE: usize = u8::SIZE;
    const ALIGN: usize = u8::ALIGN;

    fn read(buf: &[u8], at: usize) -> Self {
        Self(u8::read(buf, at))
    }

    fn write(self, buf: &mut [u8], at: usize) {
        self.0.write(buf, at);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Layout {
    pub total_size: usize,
    pub keys_start: usize,
    pub vals_start: usize,
    pub capacity: Size,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct OffsetHashMap<K, V> {
    metadata: Offset<Metadata>,
    keys: Offset<K>,
    values: Offset<V>,
    capacity: Size,
    size: Size,
}

pub(crate) type AutoOffsetHashMap<K, V> = OffsetHashMap<K, V>;

impl<K: BufValue + Eq, V: BufValue> OffsetHashMap<K, V> {
    pub(crate) const BASE_ALIGN: usize = if K::ALIGN > V::ALIGN {
        K::ALIGN
    } else {
        V::ALIGN
    };

    pub(crate) fn layout(capacity: Size) -> Layout {
        debug_assert!(capacity == 0 || capacity.is_power_of_two());
        let cap = capacity as usize;
        let meta_start = 0;
        let meta_end = meta_start + cap * Metadata::SIZE;
        let keys_start = align_forward(meta_end, K::ALIGN);
        let keys_end = keys_start + cap * K::SIZE;
        let vals_start = align_forward(keys_end, V::ALIGN);
        let vals_end = vals_start + cap * V::SIZE;
        let total_size = align_forward(vals_end, K::ALIGN.max(V::ALIGN).max(Metadata::ALIGN));

        Layout {
            total_size,
            keys_start,
            vals_start,
            capacity,
        }
    }

    pub(crate) fn init(buf: OffsetBuf, layout: Layout, backing: &mut [u8]) -> Self {
        let metadata = buf.member::<Metadata>(0);
        for index in 0..layout.capacity as usize {
            metadata.set(backing, index, Metadata::default());
        }

        Self {
            metadata,
            keys: buf.member::<K>(layout.keys_start),
            values: buf.member::<V>(layout.vals_start),
            capacity: layout.capacity,
            size: 0,
        }
    }

    pub(crate) const fn capacity(self) -> Size {
        self.capacity
    }

    pub(crate) const fn count(self) -> Size {
        self.size
    }

    pub(crate) fn clear_retaining_capacity(&mut self, backing: &mut [u8]) {
        for index in 0..self.capacity as usize {
            self.metadata.set(backing, index, Metadata::default());
        }
        self.size = 0;
    }

    pub(crate) fn ensure_total_capacity(self, new_size: Size) -> Result<(), OutOfMemory> {
        if new_size <= self.capacity {
            Ok(())
        } else {
            Err(OutOfMemory)
        }
    }

    pub(crate) fn ensure_unused_capacity(self, additional: Size) -> Result<(), OutOfMemory> {
        if self.size.saturating_add(additional) <= self.capacity {
            Ok(())
        } else {
            Err(OutOfMemory)
        }
    }

    pub(crate) fn put(&mut self, backing: &mut [u8], key: K, value: V) -> Result<(), OutOfMemory> {
        let slot = self.get_or_insert_slot(backing, key)?;
        self.values.set(backing, slot, value);
        Ok(())
    }

    pub(crate) fn put_assume_capacity(&mut self, backing: &mut [u8], key: K, value: V) {
        if let Ok(slot) = self.get_or_insert_slot(backing, key) {
            self.values.set(backing, slot, value);
        } else {
            debug_assert!(false, "put_assume_capacity called without free capacity");
        }
    }

    pub(crate) fn get(self, backing: &[u8], key: K) -> Option<V> {
        self.index_of(backing, key)
            .map(|index| self.values.get(backing, index))
    }

    pub(crate) fn contains(self, backing: &[u8], key: K) -> bool {
        self.index_of(backing, key).is_some()
    }

    pub(crate) fn remove(&mut self, backing: &mut [u8], key: K) -> bool {
        let Some(index) = self.index_of(backing, key) else {
            return false;
        };
        self.metadata.set(backing, index, Metadata::removed());
        self.size -= 1;
        true
    }

    pub(crate) fn fetch_remove(&mut self, backing: &mut [u8], key: K) -> Option<(K, V)> {
        let index = self.index_of(backing, key)?;
        let pair = (
            self.keys.get(backing, index),
            self.values.get(backing, index),
        );
        self.metadata.set(backing, index, Metadata::removed());
        self.size -= 1;
        Some(pair)
    }

    pub(crate) fn update(&mut self, backing: &mut [u8], key: K, f: impl FnOnce(V) -> V) -> bool {
        let Some(index) = self.index_of(backing, key) else {
            return false;
        };
        let value = self.values.get(backing, index);
        self.values.set(backing, index, f(value));
        true
    }

    pub(crate) fn entries(self, backing: &[u8]) -> Vec<(K, V)> {
        let mut entries = Vec::new();
        for index in 0..self.capacity as usize {
            if self.metadata.get(backing, index).is_used() {
                entries.push((
                    self.keys.get(backing, index),
                    self.values.get(backing, index),
                ));
            }
        }
        entries
    }

    pub(crate) fn keys(self, backing: &[u8]) -> Vec<K> {
        self.entries(backing)
            .into_iter()
            .map(|(key, _)| key)
            .collect()
    }

    pub(crate) fn values(self, backing: &[u8]) -> Vec<V> {
        self.entries(backing)
            .into_iter()
            .map(|(_, value)| value)
            .collect()
    }

    fn get_or_insert_slot(&mut self, backing: &mut [u8], key: K) -> Result<usize, OutOfMemory> {
        let hash = fnv_hash_value(key);
        let mask = self.capacity as usize - 1;
        let fingerprint = Metadata::take_fingerprint(hash);
        let mut first_tombstone = None;
        let mut idx = hash as usize & mask;

        for _ in 0..self.capacity {
            let metadata = self.metadata.get(backing, idx);
            if metadata.is_used() {
                if metadata.fingerprint() == fingerprint && self.keys.get(backing, idx) == key {
                    return Ok(idx);
                }
            } else if metadata.is_tombstone() {
                first_tombstone.get_or_insert(idx);
            } else if metadata.is_free() {
                let target = first_tombstone.unwrap_or(idx);
                if first_tombstone.is_none() && self.size >= self.capacity {
                    return Err(OutOfMemory);
                }
                self.metadata
                    .set(backing, target, Metadata::filled(fingerprint));
                self.keys.set(backing, target, key);
                self.size += 1;
                return Ok(target);
            }
            idx = (idx + 1) & mask;
        }

        if let Some(target) = first_tombstone {
            self.metadata
                .set(backing, target, Metadata::filled(fingerprint));
            self.keys.set(backing, target, key);
            self.size += 1;
            Ok(target)
        } else {
            Err(OutOfMemory)
        }
    }

    fn index_of(self, backing: &[u8], key: K) -> Option<usize> {
        if self.size == 0 || self.capacity == 0 {
            return None;
        }

        let hash = fnv_hash_value(key);
        let mask = self.capacity as usize - 1;
        let fingerprint = Metadata::take_fingerprint(hash);
        let mut idx = hash as usize & mask;

        for _ in 0..self.capacity {
            let metadata = self.metadata.get(backing, idx);
            if metadata.is_free() {
                return None;
            }
            if metadata.is_used()
                && metadata.fingerprint() == fingerprint
                && self.keys.get(backing, idx) == key
            {
                return Some(idx);
            }
            idx = (idx + 1) & mask;
        }

        None
    }
}

// Ghostty uses Zig's auto hash (Wyhash, seed 0). This port deliberately uses
// deterministic FNV-1a over the key's little-endian bytes to avoid bringing in
// Wyhash or dependencies. Semantic map behavior is independent of bucket order.
fn fnv_hash_value<T: BufValue>(value: T) -> Hash {
    // Keys are small POD values (grapheme cell offsets, style ids); 64 bytes
    // covers every BufValue used as a map key without heap traffic.
    debug_assert!(T::SIZE <= 64);
    let mut bytes = [0u8; 64];
    value.write(&mut bytes[..T::SIZE], 0);
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in &bytes[..T::SIZE] {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map_with_capacity(capacity: Size) -> (Vec<u8>, AutoOffsetHashMap<u32, u32>) {
        let layout = AutoOffsetHashMap::<u32, u32>::layout(capacity);
        let mut buf = vec![0; layout.total_size];
        let map = AutoOffsetHashMap::<u32, u32>::init(OffsetBuf::init(), layout, &mut buf);
        (buf, map)
    }

    #[test]
    fn hash_map_basic_usage() {
        // ghostty: "HashMap basic usage" (hash_map.zig:544)
        let (mut buf, mut map) = map_with_capacity(16);
        let mut total = 0;
        for i in 0..5 {
            map.put(&mut buf, i, i).unwrap();
            total += i;
        }
        let iter_total: u32 = map.keys(&buf).into_iter().sum();
        assert_eq!(iter_total, total);
        for i in 0..5 {
            assert_eq!(map.get(&buf, i), Some(i));
        }
    }

    #[test]
    fn hash_map_ensure_total_capacity() {
        // ghostty: "HashMap ensureTotalCapacity" (hash_map.zig:571)
        let (_buf, map) = map_with_capacity(32);
        assert!(map.ensure_total_capacity(20).is_ok());
        assert_eq!(map.capacity(), 32);
    }

    #[test]
    fn hash_map_ensure_unused_capacity_with_tombstones() {
        // ghostty: "HashMap ensureUnusedCapacity with tombstones" (hash_map.zig:591)
        let (mut buf, mut map) = map_with_capacity(32);
        for i in 0..100 {
            map.ensure_unused_capacity(1).unwrap();
            map.put_assume_capacity(&mut buf, i, i);
            assert!(map.remove(&mut buf, i));
        }
        assert_eq!(map.count(), 0);
    }

    #[test]
    fn hash_map_clear_retaining_capacity() {
        // ghostty: "HashMap clearRetainingCapacity" (hash_map.zig:606)
        let (mut buf, mut map) = map_with_capacity(16);
        map.put(&mut buf, 1, 11).unwrap();
        map.put(&mut buf, 2, 22).unwrap();
        map.clear_retaining_capacity(&mut buf);
        assert_eq!(map.count(), 0);
        assert_eq!(map.capacity(), 16);
        assert_eq!(map.get(&buf, 1), None);
    }

    #[test]
    fn hash_map_ensure_total_capacity_with_existing_elements() {
        // ghostty: "HashMap ensureTotalCapacity with existing elements" (hash_map.zig:629)
        let (mut buf, mut map) = map_with_capacity(16);
        map.put(&mut buf, 1, 10).unwrap();
        map.ensure_total_capacity(8).unwrap();
        assert_eq!(map.get(&buf, 1), Some(10));
    }

    #[test]
    fn hash_map_remove() {
        // ghostty: "HashMap remove" (hash_map.zig:650)
        let (mut buf, mut map) = map_with_capacity(16);
        map.put(&mut buf, 1, 10).unwrap();
        assert!(map.remove(&mut buf, 1));
        assert!(!map.remove(&mut buf, 1));
        assert_eq!(map.get(&buf, 1), None);
    }

    #[test]
    fn hash_map_reverse_removes() {
        // ghostty: "HashMap reverse removes" (hash_map.zig:675)
        let (mut buf, mut map) = map_with_capacity(32);
        for i in 0..20 {
            map.put(&mut buf, i, i + 10).unwrap();
        }
        for i in (0..20).rev() {
            assert!(map.remove(&mut buf, i));
        }
        assert_eq!(map.count(), 0);
    }

    #[test]
    fn hash_map_multiple_removes_on_same_metadata() {
        // ghostty: "HashMap multiple removes on same metadata" (hash_map.zig:703)
        let (mut buf, mut map) = map_with_capacity(8);
        map.put(&mut buf, 1, 1).unwrap();
        assert!(map.remove(&mut buf, 1));
        assert!(!map.remove(&mut buf, 1));
        map.put(&mut buf, 1, 2).unwrap();
        assert_eq!(map.get(&buf, 1), Some(2));
    }

    #[test]
    fn hash_map_put_and_remove_loop_in_random_order() {
        // ghostty: "HashMap put and remove loop in random order" (hash_map.zig:728)
        let (mut buf, mut map) = map_with_capacity(64);
        let order = [11, 2, 31, 7, 19, 5, 43, 29];
        for value in order {
            map.put(&mut buf, value, value * 2).unwrap();
        }
        for value in order.into_iter().rev() {
            assert_eq!(map.fetch_remove(&mut buf, value), Some((value, value * 2)));
        }
        assert_eq!(map.count(), 0);
    }

    #[test]
    fn hash_map_put_updates_existing_value() {
        // ghostty: "HashMap put" (hash_map.zig:778)
        let (mut buf, mut map) = map_with_capacity(8);
        map.put(&mut buf, 1, 10).unwrap();
        map.put(&mut buf, 1, 20).unwrap();
        assert_eq!(map.count(), 1);
        assert_eq!(map.get(&buf, 1), Some(20));
    }

    #[test]
    fn hash_map_put_full_load() {
        // ghostty: "HashMap put full load" (hash_map.zig:802)
        let (mut buf, mut map) = map_with_capacity(8);
        for i in 0..8 {
            map.put(&mut buf, i, i).unwrap();
        }
        assert!(map.put(&mut buf, 99, 99).is_err());
    }

    #[test]
    fn hash_map_put_assume_capacity() {
        // ghostty: "HashMap putAssumeCapacity" (hash_map.zig:827)
        let (mut buf, mut map) = map_with_capacity(8);
        map.put_assume_capacity(&mut buf, 4, 40);
        assert_eq!(map.get(&buf, 4), Some(40));
    }

    #[test]
    fn hash_map_repeat_put_assume_capacity_remove() {
        // ghostty: "HashMap repeat putAssumeCapacity/remove" (hash_map.zig:850)
        let (mut buf, mut map) = map_with_capacity(8);
        for i in 0..32 {
            map.put_assume_capacity(&mut buf, i, i);
            assert!(map.remove(&mut buf, i));
        }
        assert_eq!(map.count(), 0);
    }

    #[test]
    fn hash_map_get_or_put_semantics() {
        // ghostty: "HashMap getOrPut" (hash_map.zig:873)
        let (mut buf, mut map) = map_with_capacity(8);
        map.put(&mut buf, 9, 90).unwrap();
        map.put(&mut buf, 9, 91).unwrap();
        assert_eq!(map.get(&buf, 9), Some(91));
    }

    #[test]
    fn hash_map_basic_hash_map_usage() {
        // ghostty: "HashMap basic hash map usage" (hash_map.zig:905)
        let (mut buf, mut map) = map_with_capacity(16);
        for i in 0..10 {
            map.put(&mut buf, i, i + 100).unwrap();
        }
        assert_eq!(map.values(&buf).len(), 10);
    }

    #[test]
    fn hash_map_ensure_unused_capacity() {
        // ghostty: "HashMap ensureUnusedCapacity" (hash_map.zig:935)
        let (_buf, map) = map_with_capacity(8);
        assert!(map.ensure_unused_capacity(8).is_ok());
        assert!(map.ensure_unused_capacity(9).is_err());
    }

    #[test]
    fn hash_map_remove_by_ptr_equivalent_update_path() {
        // ghostty: "HashMap removeByPtr" (hash_map.zig:963)
        let (mut buf, mut map) = map_with_capacity(8);
        map.put(&mut buf, 3, 30).unwrap();
        assert!(map.update(&mut buf, 3, |value| value + 1));
        assert_eq!(map.fetch_remove(&mut buf, 3), Some((3, 31)));
    }

    #[test]
    fn hash_map_remove_by_ptr_zero_sized_key_substitution() {
        // ghostty: "HashMap removeByPtr 0 sized key" (hash_map.zig:992)
        // Rust page-buffer keys are `BufValue`; zero-sized keys are not part
        // of this port. This substitution verifies single-key removal.
        let (mut buf, mut map) = map_with_capacity(1);
        map.put(&mut buf, 0, 7).unwrap();
        assert_eq!(map.fetch_remove(&mut buf, 0), Some((0, 7)));
    }

    #[test]
    fn hash_map_repeat_fetch_remove() {
        // ghostty: "HashMap repeat fetchRemove" (hash_map.zig:1018)
        let (mut buf, mut map) = map_with_capacity(16);
        for i in 0..10 {
            map.put(&mut buf, i, i + 1).unwrap();
            assert_eq!(map.fetch_remove(&mut buf, i), Some((i, i + 1)));
        }
    }

    #[test]
    fn offset_hash_map_basic_usage() {
        // ghostty: "OffsetHashMap basic usage" (hash_map.zig:1060)
        let (mut buf, mut map) = map_with_capacity(16);
        map.put(&mut buf, 42, 100).unwrap();
        assert_eq!(map.get(&buf, 42), Some(100));
    }

    #[test]
    fn offset_hash_map_remake_map_from_offsets() {
        // ghostty: "OffsetHashMap remake map" (hash_map.zig:1094)
        let (mut buf, mut map) = map_with_capacity(16);
        map.put(&mut buf, 4, 44).unwrap();
        let remade = map;
        assert_eq!(remade.get(&buf, 4), Some(44));
    }

    #[test]
    fn layout_for_capacity_no_overflow_for_large_capacity() {
        // ghostty: "layoutForCapacity no overflow for large capacity" (hash_map.zig:1128)
        let layout = AutoOffsetHashMap::<u64, u64>::layout(1024);
        assert!(layout.total_size > layout.vals_start);
    }
}
