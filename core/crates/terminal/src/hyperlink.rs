//! OSC 8 hyperlink storage for terminal pages.
//!
//! Ghostty stores hyperlink IDs and URIs in a page-local string allocator and
//! deduplicates hyperlink entries with a ref-counted set. This port preserves
//! that shape while using deterministic FNV-1a instead of Ghostty's Wyhash; the
//! hash only affects bucket order, not semantic behavior.

use crate::hash_map::AutoOffsetHashMap;
use crate::page::{Cell, StringAlloc};
use crate::ref_counted_set::{RefCountedSet, RefCountedSetContext};
use crate::size::{BufValue, HyperlinkCountInt, Offset, OffsetSlice};

#[allow(dead_code)]
pub type HyperlinkId = HyperlinkCountInt;
#[allow(dead_code)]
pub(crate) type HyperlinkMap = AutoOffsetHashMap<Offset<Cell>, HyperlinkId>;

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hyperlink {
    pub id: HyperlinkIdKind,
    pub uri: Vec<u8>,
}

#[allow(dead_code)]
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HyperlinkIdKind {
    Explicit(Vec<u8>),
    Implicit(u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PageEntryId {
    Explicit(OffsetSlice<u8>),
    Implicit(u32),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PageEntry {
    id: PageEntryId,
    uri: OffsetSlice<u8>,
}

impl PageEntry {
    // Pinned layout:
    // +0: u8 tag (0 explicit, 1 implicit)
    // +1..+3: zero padding
    // +4..+7: implicit id payload
    // +8..+15: explicit id OffsetSlice<u8>
    // +16..+23: uri OffsetSlice<u8>
    pub(crate) const TAG_EXPLICIT: u8 = 0;
    pub(crate) const TAG_IMPLICIT: u8 = 1;
    const IMPLICIT_OFFSET: usize = 4;
    const EXPLICIT_OFFSET: usize = 8;
    const URI_OFFSET: usize = 16;

    pub(crate) const fn explicit(id: OffsetSlice<u8>, uri: OffsetSlice<u8>) -> Self {
        Self {
            id: PageEntryId::Explicit(id),
            uri,
        }
    }

    pub(crate) const fn implicit(id: u32, uri: OffsetSlice<u8>) -> Self {
        Self {
            id: PageEntryId::Implicit(id),
            uri,
        }
    }

    #[allow(dead_code)]
    pub(crate) const fn id(self) -> PageEntryId {
        self.id
    }

    #[allow(dead_code)]
    pub(crate) const fn uri(self) -> OffsetSlice<u8> {
        self.uri
    }
}

impl BufValue for PageEntry {
    const SIZE: usize = 24;
    const ALIGN: usize = 4;

    fn read(buf: &[u8], at: usize) -> Self {
        let tag = u8::read(buf, at);
        let explicit = OffsetSlice::<u8>::read(buf, at + Self::EXPLICIT_OFFSET);
        let implicit = u32::read(buf, at + Self::IMPLICIT_OFFSET);
        let uri = OffsetSlice::<u8>::read(buf, at + Self::URI_OFFSET);
        if tag == Self::TAG_IMPLICIT {
            Self::implicit(implicit, uri)
        } else {
            Self::explicit(explicit, uri)
        }
    }

    fn write(self, buf: &mut [u8], at: usize) {
        for byte in &mut buf[at..at + Self::SIZE] {
            *byte = 0;
        }
        match self.id {
            PageEntryId::Explicit(slice) => {
                Self::TAG_EXPLICIT.write(buf, at);
                slice.write(buf, at + Self::EXPLICIT_OFFSET);
            }
            PageEntryId::Implicit(value) => {
                Self::TAG_IMPLICIT.write(buf, at);
                value.write(buf, at + Self::IMPLICIT_OFFSET);
            }
        }
        self.uri.write(buf, at + Self::URI_OFFSET);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct HyperlinkContext {
    pub(crate) string_alloc: StringAlloc,
}

impl RefCountedSetContext<PageEntry> for HyperlinkContext {
    fn hash(&self, buf: &[u8], value: &PageEntry) -> u64 {
        let mut hash = FNV_OFFSET;
        match value.id {
            PageEntryId::Explicit(slice) => {
                hash = fnv_byte(hash, PageEntry::TAG_EXPLICIT);
                hash = fnv_bytes(hash, slice_bytes(buf, slice));
            }
            PageEntryId::Implicit(value) => {
                hash = fnv_byte(hash, PageEntry::TAG_IMPLICIT);
                hash = fnv_bytes(hash, &value.to_le_bytes());
            }
        }
        fnv_bytes(hash, slice_bytes(buf, value.uri))
    }

    fn eql(&self, buf: &[u8], a: &PageEntry, b: &PageEntry) -> bool {
        entries_equal(buf, buf, a, b)
    }

    fn eql_probe(
        &self,
        probe_buf: &[u8],
        buf: &[u8],
        probe: &PageEntry,
        stored: &PageEntry,
    ) -> bool {
        entries_equal(probe_buf, buf, probe, stored)
    }

    fn deleted(&self, buf: &mut [u8], value: &PageEntry) {
        let mut alloc = self.string_alloc;
        if let PageEntryId::Explicit(slice) = value.id {
            if slice.len > 0 {
                alloc.free(buf, slice);
            }
        }
        if value.uri.len > 0 {
            alloc.free(buf, value.uri);
        }
    }
}

#[allow(dead_code)]
pub(crate) type HyperlinkSet = RefCountedSet<PageEntry, HyperlinkContext>;

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

fn fnv_byte(hash: u64, byte: u8) -> u64 {
    (hash ^ u64::from(byte)).wrapping_mul(FNV_PRIME)
}

fn fnv_bytes(mut hash: u64, bytes: &[u8]) -> u64 {
    for byte in bytes {
        hash = fnv_byte(hash, *byte);
    }
    hash
}

fn slice_bytes<T: BufValue>(buf: &[u8], slice: OffsetSlice<T>) -> &[u8] {
    let start = slice.offset.offset as usize;
    let len = slice.len * T::SIZE;
    &buf[start..start + len]
}

fn entries_equal(
    probe_buf: &[u8],
    stored_buf: &[u8],
    probe: &PageEntry,
    stored: &PageEntry,
) -> bool {
    match (probe.id, stored.id) {
        (PageEntryId::Explicit(a), PageEntryId::Explicit(b)) => {
            if slice_bytes(probe_buf, a) != slice_bytes(stored_buf, b) {
                return false;
            }
        }
        (PageEntryId::Implicit(a), PageEntryId::Implicit(b)) => {
            if a != b {
                return false;
            }
        }
        _ => return false,
    }
    slice_bytes(probe_buf, probe.uri) == slice_bytes(stored_buf, stored.uri)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bitmap_allocator::BitmapAllocator;
    use crate::ref_counted_set::Layout;
    use crate::size::OffsetBuf;

    fn alloc_string(alloc: &mut StringAlloc, buf: &mut [u8], bytes: &[u8]) -> OffsetSlice<u8> {
        let slice = alloc.alloc::<u8>(buf, bytes.len()).unwrap();
        for (index, byte) in bytes.iter().enumerate() {
            slice.offset.set(buf, index, *byte);
        }
        slice
    }

    fn string_alloc() -> (Vec<u8>, StringAlloc) {
        let layout = BitmapAllocator::<32>::layout(256);
        let mut buf = vec![0; layout.total_size];
        let alloc = StringAlloc::init(OffsetBuf::init(), layout, &mut buf);
        (buf, alloc)
    }

    #[test]
    fn page_entry_buf_value_encodes_explicit_and_implicit_layout() {
        let explicit = OffsetSlice::<u8>::new(Offset::new(0x10), 3);
        let uri = OffsetSlice::<u8>::new(Offset::new(0x40), 9);
        let entry = PageEntry::explicit(explicit, uri);
        let mut buf = [0xFF; PageEntry::SIZE];
        entry.write(&mut buf, 0);
        assert_eq!(buf[0], PageEntry::TAG_EXPLICIT);
        assert_eq!(&buf[1..4], &[0, 0, 0]);
        assert_eq!(PageEntry::read(&buf, 0), entry);

        let implicit = PageEntry::implicit(42, uri);
        implicit.write(&mut buf, 0);
        assert_eq!(buf[0], PageEntry::TAG_IMPLICIT);
        assert_eq!(u32::read(&buf, PageEntry::IMPLICIT_OFFSET), 42);
        assert_eq!(PageEntry::read(&buf, 0), implicit);
    }

    #[test]
    fn hyperlink_context_compares_explicit_bytes_and_uri_bytes() {
        let (mut buf, mut alloc) = string_alloc();
        let id = alloc_string(&mut alloc, &mut buf, b"id");
        let uri = alloc_string(&mut alloc, &mut buf, b"https://example.test");
        let same_id = alloc_string(&mut alloc, &mut buf, b"id");
        let same_uri = alloc_string(&mut alloc, &mut buf, b"https://example.test");
        let entry = PageEntry::explicit(id, uri);
        let same = PageEntry::explicit(same_id, same_uri);
        let ctx = HyperlinkContext {
            string_alloc: alloc,
        };
        assert!(ctx.eql(&buf, &entry, &same));
        assert_eq!(ctx.hash(&buf, &entry), ctx.hash(&buf, &same));
    }

    #[test]
    fn lookup_with_probe_compares_probe_buffer_against_stored_buffer() {
        let (mut stored_strings, mut stored_alloc) = string_alloc();
        let stored_uri = alloc_string(&mut stored_alloc, &mut stored_strings, b"https://a.test");
        let stored_entry = PageEntry::implicit(7, stored_uri);
        let layout = Layout::init::<PageEntry>(8);
        let set_start = stored_strings.len();
        stored_strings.resize(set_start + layout.total_size, 0);
        let mut set = HyperlinkSet::init(
            OffsetBuf::init_offset(set_start),
            layout,
            &mut stored_strings,
            HyperlinkContext {
                string_alloc: stored_alloc,
            },
        );
        let id = set.add(&mut stored_strings, stored_entry).unwrap();

        let (mut probe_buf, mut probe_alloc) = string_alloc();
        let probe_uri = alloc_string(&mut probe_alloc, &mut probe_buf, b"https://a.test");
        let probe = PageEntry::implicit(7, probe_uri);
        assert_eq!(
            set.lookup_with_probe(&stored_strings, &probe_buf, probe),
            Some(id)
        );
    }

    #[test]
    fn deleted_frees_uri_and_explicit_id_slices() {
        let (mut buf, mut alloc) = string_alloc();
        let id = alloc_string(&mut alloc, &mut buf, b"id");
        let uri = alloc_string(&mut alloc, &mut buf, b"uri");
        let used_before = alloc.used_bytes(&buf);
        let ctx = HyperlinkContext {
            string_alloc: alloc,
        };
        ctx.deleted(&mut buf, &PageEntry::explicit(id, uri));
        assert!(alloc.used_bytes(&buf) < used_before);
    }
}
