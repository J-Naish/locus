//! Offset-addressed ref-counted set for page-local style/hyperlink storage.

#![expect(dead_code, reason = "Phase T4b consumes the page substrate")]

use crate::size::{align_forward, BufValue, Offset, OffsetBuf};

pub(crate) type Id = u16;
pub(crate) type RefCountInt = u16;

const LOAD_FACTOR_NUMERATOR: usize = 13;
const LOAD_FACTOR_DENOMINATOR: usize = 16;
const MAX_PSL: usize = 31;
const EMPTY_ID: Id = 0;
const RESERVED_ID_COUNT: usize = 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum AddError {
    OutOfMemory,
    NeedsRehash,
}

pub(crate) trait RefCountedSetContext<T> {
    fn hash(&self, buf: &[u8], value: &T) -> u64;
    fn eql(&self, buf: &[u8], a: &T, b: &T) -> bool;
    fn eql_probe(&self, probe_buf: &[u8], buf: &[u8], probe: &T, stored: &T) -> bool {
        let _ = probe_buf;
        self.eql(buf, probe, stored)
    }
    fn deleted(&self, _buf: &mut [u8], _value: &T) {}
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Layout {
    pub cap: usize,
    pub table_cap: usize,
    pub table_mask: Id,
    pub table_start: usize,
    pub items_start: usize,
    pub total_size: usize,
}

impl Layout {
    pub(crate) fn init<T: BufValue>(cap: usize) -> Self {
        debug_assert!(cap <= usize::from(Id::MAX) + 1);
        if cap == 0 {
            return Self {
                cap: 0,
                table_cap: 0,
                table_mask: 0,
                table_start: 0,
                items_start: 0,
                total_size: 0,
            };
        }

        let table_cap = cap.next_power_of_two();
        let items_cap = table_cap * LOAD_FACTOR_NUMERATOR / LOAD_FACTOR_DENOMINATOR;
        let table_mask = (table_cap - 1) as Id;
        let table_start = 0;
        let table_end = table_start + table_cap * Id::SIZE;
        let items_start = align_forward(table_end, item_align::<T>());
        let total_size = items_start + items_cap * item_size::<T>();

        Self {
            cap: items_cap,
            table_cap,
            table_mask,
            table_start,
            items_start,
            total_size,
        }
    }
}

pub(crate) const fn item_base_align<T: BufValue>() -> usize {
    item_align::<T>()
}

pub(crate) const fn item_byte_size<T: BufValue>() -> usize {
    item_size::<T>()
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RefCountedSet<T, Ctx> {
    table: Offset<Id>,
    items: Offset<u8>,
    max_psl: Id,
    psl_stats: [Id; 32],
    living: usize,
    next_id: Id,
    layout: Layout,
    context: Ctx,
    _marker: std::marker::PhantomData<T>,
}

impl<T: BufValue, Ctx: RefCountedSetContext<T> + Copy> RefCountedSet<T, Ctx> {
    pub(crate) const LOAD_FACTOR: f64 = 0.8125;

    pub(crate) fn capacity_for_count(n: usize) -> usize {
        if n == 0 {
            0
        } else {
            ((n + RESERVED_ID_COUNT) * LOAD_FACTOR_DENOMINATOR).div_ceil(LOAD_FACTOR_NUMERATOR)
        }
    }

    pub(crate) fn init(buf: OffsetBuf, layout: Layout, backing: &mut [u8], context: Ctx) -> Self {
        let table = buf.member::<Id>(layout.table_start);
        for index in 0..layout.table_cap {
            table.set(backing, index, EMPTY_ID);
        }

        let items = buf.member::<u8>(layout.items_start);
        for index in 0..layout.cap {
            clear_item::<T>(backing, items, index as Id);
        }

        Self {
            table,
            items,
            max_psl: 0,
            psl_stats: [0; 32],
            living: 0,
            next_id: 1,
            layout,
            context,
            _marker: std::marker::PhantomData,
        }
    }

    pub(crate) fn add(&mut self, backing: &mut [u8], value: T) -> Result<Id, AddError> {
        self.trim_trailing_dead(backing);

        if let Some(id) = self.lookup(backing, value) {
            let refs = self.ref_count(backing, id);
            write_ref::<T>(backing, self.items, id, refs + 1);
            return Ok(id);
        }

        if self.next_id as usize >= self.layout.cap {
            let rehash_threshold = self.layout.cap * 9 / 10;
            if self.living < rehash_threshold {
                return Err(AddError::NeedsRehash);
            }
            return Err(AddError::OutOfMemory);
        }

        let id = self.insert(backing, value, self.next_id)?;
        write_ref::<T>(backing, self.items, id, 1);
        self.living += 1;
        if id == self.next_id {
            self.next_id += 1;
        }
        Ok(id)
    }

    /// Ghostty names this operation `use`; Rust reserves that keyword.
    pub(crate) fn use_ref(&self, backing: &mut [u8], id: Id) {
        debug_assert!(id > 0);
        let refs = self.ref_count(backing, id);
        debug_assert!(refs > 0);
        write_ref::<T>(backing, self.items, id, refs + 1);
    }

    pub(crate) fn use_multiple(&self, backing: &mut [u8], id: Id, n: RefCountInt) {
        debug_assert!(id > 0);
        let refs = self.ref_count(backing, id);
        debug_assert!(refs > 0);
        write_ref::<T>(backing, self.items, id, refs + n);
    }

    pub(crate) fn add_with_id(
        &mut self,
        backing: &mut [u8],
        value: T,
        id: Id,
    ) -> Result<Option<Id>, AddError> {
        debug_assert!(id > 0);

        if id < self.next_id {
            let refs = self.ref_count(backing, id);
            if refs == 0 {
                self.delete_item(backing, id);
                let added = self.insert(backing, value, id)?;
                let refs = self.ref_count(backing, added);
                write_ref::<T>(backing, self.items, added, refs + 1);
                self.living += 1;
                return Ok((added != id).then_some(added));
            }

            let current = read_value::<T>(backing, self.items, id);
            if self.context.eql(backing, &value, &current) {
                self.context.deleted(backing, &value);
                write_ref::<T>(backing, self.items, id, refs + 1);
                return Ok(None);
            }
        }

        self.add(backing, value).map(Some)
    }

    pub(crate) fn get(self, backing: &[u8], id: Id) -> Option<T> {
        if id == 0 || id as usize >= self.layout.cap || self.ref_count(backing, id) == 0 {
            None
        } else {
            Some(read_value::<T>(backing, self.items, id))
        }
    }

    pub(crate) fn release(&mut self, backing: &mut [u8], id: Id) {
        let refs = self.ref_count(backing, id);
        debug_assert!(refs > 0);
        write_ref::<T>(backing, self.items, id, refs - 1);
        if refs == 1 {
            self.living -= 1;
        }
    }

    pub(crate) fn release_multiple(&mut self, backing: &mut [u8], id: Id, n: RefCountInt) {
        let refs = self.ref_count(backing, id);
        debug_assert!(refs >= n);
        write_ref::<T>(backing, self.items, id, refs - n);
        if refs == n {
            self.living -= 1;
        }
    }

    pub(crate) fn ref_count(self, backing: &[u8], id: Id) -> RefCountInt {
        read_ref::<T>(backing, self.items, id)
    }

    pub(crate) const fn count(self) -> usize {
        self.living
    }

    /// The number of item slots this set can hold before it must be rehashed or
    /// grown. Mirrors reading `styles.layout.cap` in Ghostty (used by tests that
    /// need to fill the set to its true capacity).
    pub(crate) const fn layout_cap(self) -> usize {
        self.layout.cap
    }

    pub(crate) fn lookup(self, backing: &[u8], value: T) -> Option<Id> {
        self.lookup_with_probe(backing, backing, value)
    }

    pub(crate) fn lookup_with_probe(
        self,
        backing: &[u8],
        probe_backing: &[u8],
        value: T,
    ) -> Option<Id> {
        if self.layout.table_cap == 0 {
            return None;
        }
        for bucket in 0..self.layout.table_cap {
            let id = self.table.get(backing, bucket);
            if id == EMPTY_ID {
                continue;
            }
            if self.ref_count(backing, id) > 0 {
                let current = read_value::<T>(backing, self.items, id);
                if self
                    .context
                    .eql_probe(probe_backing, backing, &value, &current)
                {
                    return Some(id);
                }
            }
        }
        None
    }

    /// Insert `value` into the table, allocating `new_id` for it (or reusing a
    /// smaller dead id encountered while probing). Robin-hood open addressing:
    /// while probing, an item with a lower PSL (or equal PSL and lower ref
    /// count) is displaced and re-homed so high-traffic items stay near their
    /// ideal bucket, which lets the table pack to near its full capacity.
    /// Mirrors Ghostty's `RefCountedSet.insert` (ref_counted_set.zig).
    ///
    /// The new item is kept "in hand" (its value/psl tracked locally, ref 0)
    /// until it lands in a bucket; only its final bucket is recorded during the
    /// probe, and its value/psl/ref are written to `items[chosen_id]` at the
    /// end (chosen_id may differ from new_id if a smaller dead id is reused).
    /// Displaced existing items are re-homed in place as we pass them.
    fn insert(&mut self, backing: &mut [u8], value: T, new_id: Id) -> Result<Id, AddError> {
        let hash = self.context.hash(backing, &value);
        let table_cap = self.layout.table_cap;

        // The item currently in hand. When `held_is_new` it is the new value
        // (not yet written to the items array); otherwise it is an existing
        // item identified by `held_id` (already stored in `items[held_id]`).
        let mut held_is_new = true;
        let mut held_id: Id = new_id;
        let mut held_psl: Id = 0;

        // Final resting place of the new item (bucket + psl), and the id it
        // will occupy.
        let mut new_bucket: Option<usize> = None;
        let mut new_psl: Id = 0;
        let mut chosen_id: Id = new_id;

        let mut placed = false;
        for i in 0..table_cap.saturating_sub(1) {
            let p = ((hash.wrapping_add(i as u64)) & u64::from(self.layout.table_mask)) as usize;
            let id = self.table.get(backing, p);

            let stop = if id == EMPTY_ID {
                true
            } else if self.ref_count(backing, id) == 0 {
                // Dead item: reap it, reuse its bucket (and its id if smaller).
                let dead_psl = read_psl::<T>(backing, self.items, id);
                let dead_value = read_value::<T>(backing, self.items, id);
                self.context.deleted(backing, &dead_value);
                self.psl_stats[dead_psl as usize] =
                    self.psl_stats[dead_psl as usize].saturating_sub(1);
                clear_item::<T>(backing, self.items, id);
                if id < new_id {
                    chosen_id = id;
                }
                true
            } else {
                false
            };

            if stop {
                // Drop the held item into this bucket.
                self.table.set(backing, p, held_id);
                if held_is_new {
                    new_bucket = Some(p);
                    new_psl = held_psl;
                } else {
                    write_bucket::<T>(backing, self.items, held_id, p as Id);
                    write_psl::<T>(backing, self.items, held_id, held_psl);
                }
                self.psl_stats[held_psl as usize] += 1;
                self.max_psl = self.max_psl.max(held_psl);
                placed = true;
                break;
            }

            // Robin-hood: displace the occupant if the held item is "poorer"
            // (higher PSL, or equal PSL and higher ref count).
            let item_psl = read_psl::<T>(backing, self.items, id);
            let item_ref = self.ref_count(backing, id);
            let held_ref: RefCountInt = if held_is_new {
                0
            } else {
                self.ref_count(backing, held_id)
            };
            if item_psl < held_psl || (item_psl == held_psl && item_ref < held_ref) {
                // Place the held item here.
                self.table.set(backing, p, held_id);
                if held_is_new {
                    new_bucket = Some(p);
                    new_psl = held_psl;
                } else {
                    write_bucket::<T>(backing, self.items, held_id, p as Id);
                    write_psl::<T>(backing, self.items, held_id, held_psl);
                }
                self.psl_stats[held_psl as usize] += 1;
                self.max_psl = self.max_psl.max(held_psl);
                // Pick up the displaced occupant and keep probing it.
                self.psl_stats[item_psl as usize] =
                    self.psl_stats[item_psl as usize].saturating_sub(1);
                held_is_new = false;
                held_id = id;
                held_psl = item_psl;
            }

            held_psl = held_psl.saturating_add(1);
            if held_psl as usize > MAX_PSL {
                return Err(AddError::OutOfMemory);
            }
        }

        let Some(new_bucket) = new_bucket else {
            // The new item never found a home (table effectively full).
            let _ = placed;
            return Err(AddError::OutOfMemory);
        };

        // The chosen id may differ from new_id (reused dead id), so ensure the
        // new item's bucket points at chosen_id, then write the new item.
        self.table.set(backing, new_bucket, chosen_id);
        write_value::<T>(backing, self.items, chosen_id, value);
        write_bucket::<T>(backing, self.items, chosen_id, new_bucket as Id);
        write_psl::<T>(backing, self.items, chosen_id, new_psl);
        write_ref::<T>(backing, self.items, chosen_id, 0);
        Ok(chosen_id)
    }

    fn trim_trailing_dead(&mut self, backing: &mut [u8]) {
        while self.next_id > 1 && self.ref_count(backing, self.next_id - 1) == 0 {
            self.next_id -= 1;
            self.delete_item(backing, self.next_id);
        }
    }

    fn delete_item(&mut self, backing: &mut [u8], id: Id) {
        let bucket = read_bucket::<T>(backing, self.items, id);
        if usize::from(bucket) >= self.layout.table_cap {
            return;
        }
        if self.table.get(backing, bucket as usize) == id {
            self.table.set(backing, bucket as usize, EMPTY_ID);
        }
        let value = read_value::<T>(backing, self.items, id);
        self.context.deleted(backing, &value);
        let psl = read_psl::<T>(backing, self.items, id);
        self.psl_stats[psl as usize] = self.psl_stats[psl as usize].saturating_sub(1);
        while self.max_psl > 0 && self.psl_stats[self.max_psl as usize] == 0 {
            self.max_psl -= 1;
        }
        clear_item::<T>(backing, self.items, id);
    }
}

const fn item_align<T: BufValue>() -> usize {
    if T::ALIGN > Id::ALIGN {
        T::ALIGN
    } else {
        Id::ALIGN
    }
}

const fn value_size<T: BufValue>() -> usize {
    align_forward(T::SIZE, Id::ALIGN)
}

const fn item_size<T: BufValue>() -> usize {
    value_size::<T>() + Id::SIZE + Id::SIZE + RefCountInt::SIZE
}

fn item_base<T: BufValue>(items: Offset<u8>, id: Id) -> usize {
    items.offset as usize + usize::from(id) * item_size::<T>()
}

fn bucket_offset<T: BufValue>(items: Offset<u8>, id: Id) -> usize {
    item_base::<T>(items, id) + value_size::<T>()
}

fn psl_offset<T: BufValue>(items: Offset<u8>, id: Id) -> usize {
    bucket_offset::<T>(items, id) + Id::SIZE
}

fn ref_offset<T: BufValue>(items: Offset<u8>, id: Id) -> usize {
    psl_offset::<T>(items, id) + Id::SIZE
}

fn read_value<T: BufValue>(buf: &[u8], items: Offset<u8>, id: Id) -> T {
    T::read(buf, item_base::<T>(items, id))
}

fn write_value<T: BufValue>(buf: &mut [u8], items: Offset<u8>, id: Id, value: T) {
    value.write(buf, item_base::<T>(items, id));
}

fn read_bucket<T: BufValue>(buf: &[u8], items: Offset<u8>, id: Id) -> Id {
    Id::read(buf, bucket_offset::<T>(items, id))
}

fn write_bucket<T: BufValue>(buf: &mut [u8], items: Offset<u8>, id: Id, bucket: Id) {
    bucket.write(buf, bucket_offset::<T>(items, id));
}

fn read_psl<T: BufValue>(buf: &[u8], items: Offset<u8>, id: Id) -> Id {
    Id::read(buf, psl_offset::<T>(items, id))
}

fn write_psl<T: BufValue>(buf: &mut [u8], items: Offset<u8>, id: Id, psl: Id) {
    psl.write(buf, psl_offset::<T>(items, id));
}

fn read_ref<T: BufValue>(buf: &[u8], items: Offset<u8>, id: Id) -> RefCountInt {
    RefCountInt::read(buf, ref_offset::<T>(items, id))
}

fn write_ref<T: BufValue>(buf: &mut [u8], items: Offset<u8>, id: Id, refs: RefCountInt) {
    refs.write(buf, ref_offset::<T>(items, id));
}

fn clear_item<T: BufValue>(buf: &mut [u8], items: Offset<u8>, id: Id) {
    let base = item_base::<T>(items, id);
    for byte in &mut buf[base..base + item_size::<T>()] {
        *byte = 0;
    }
    Id::MAX.write(buf, bucket_offset::<T>(items, id));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Copy)]
    struct U64Context;

    impl RefCountedSetContext<u64> for U64Context {
        fn hash(&self, _buf: &[u8], value: &u64) -> u64 {
            value.wrapping_mul(0x9E37_79B9_7F4A_7C15)
        }

        fn eql(&self, _buf: &[u8], a: &u64, b: &u64) -> bool {
            a == b
        }
    }

    fn set_with_capacity(capacity: usize) -> (Vec<u8>, RefCountedSet<u64, U64Context>) {
        let layout = Layout::init::<u64>(capacity);
        let mut buf = vec![0; layout.total_size];
        let set = RefCountedSet::init(OffsetBuf::init(), layout, &mut buf, U64Context);
        (buf, set)
    }

    #[test]
    fn add_deduplicates_and_increments_ref_count() {
        // ghostty: "addContext" (ref_counted_set.zig:241)
        let (mut buf, mut set) = set_with_capacity(8);
        let first = set.add(&mut buf, 42).unwrap();
        let second = set.add(&mut buf, 42).unwrap();
        assert_eq!(first, second);
        assert_eq!(set.ref_count(&buf, first), 2);
        assert_eq!(set.count(), 1);
    }

    #[test]
    fn release_to_zero_then_readd_resurrects_same_id() {
        // ghostty: "release" (ref_counted_set.zig:405)
        let (mut buf, mut set) = set_with_capacity(8);
        let id = set.add(&mut buf, 7).unwrap();
        set.release(&mut buf, id);
        assert_eq!(set.count(), 0);
        let revived = set.add(&mut buf, 7).unwrap();
        assert_eq!(revived, id);
        assert_eq!(set.ref_count(&buf, revived), 1);
    }

    #[test]
    fn distinct_values_get_distinct_nonzero_ids() {
        // ghostty: "addContext" (ref_counted_set.zig:241)
        let (mut buf, mut set) = set_with_capacity(8);
        let first = set.add(&mut buf, 1).unwrap();
        let second = set.add(&mut buf, 2).unwrap();
        assert_ne!(first, EMPTY_ID);
        assert_ne!(second, EMPTY_ID);
        assert_ne!(first, second);
    }

    #[test]
    fn filling_to_capacity_yields_out_of_memory() {
        // ghostty: "AddError.OutOfMemory" (ref_counted_set.zig:224)
        let (mut buf, mut set) = set_with_capacity(3);
        let mut result = Ok(EMPTY_ID);
        for value in 0..16 {
            result = set.add(&mut buf, value);
            if result.is_err() {
                break;
            }
        }
        assert_eq!(result, Err(AddError::OutOfMemory));
    }

    #[test]
    fn add_with_id_preserves_requested_id_when_free_and_reports_replacement_when_not() {
        // ghostty: "addWithIdContext" (ref_counted_set.zig:312)
        let (mut buf, mut set) = set_with_capacity(8);
        let first = set.add(&mut buf, 1).unwrap();
        set.release(&mut buf, first);
        assert_eq!(set.add_with_id(&mut buf, 2, first), Ok(None));
        let replacement = set.add_with_id(&mut buf, 3, first).unwrap();
        assert!(replacement.is_some());
        assert_ne!(replacement, Some(first));
    }

    #[test]
    fn release_use_round_trip_keeps_count_and_lookup_consistent() {
        // ghostty: "useMultiple" (ref_counted_set.zig:371)
        let (mut buf, mut set) = set_with_capacity(8);
        let id = set.add(&mut buf, 9).unwrap();
        set.use_ref(&mut buf, id);
        set.use_multiple(&mut buf, id, 2);
        set.release_multiple(&mut buf, id, 2);
        set.release(&mut buf, id);
        assert_eq!(set.count(), 1);
        assert_eq!(set.lookup(&buf, 9), Some(id));
        set.release(&mut buf, id);
        assert_eq!(set.count(), 0);
        assert_eq!(set.lookup(&buf, 9), None);
    }
}
