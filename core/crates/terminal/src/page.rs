//! Terminal page storage.
//!
//! This is a safe Rust port of Ghostty's single-buffer page substrate. The
//! Row/Cell bit layouts are pinned because these values are copied in flat page
//! buffers and later phases depend on their exact representation.

#![allow(dead_code, unused_imports)]

use crate::bitmap_allocator::{BitmapAllocator, OutOfMemory};
use crate::color::Rgb;
use crate::hash_map::{AutoOffsetHashMap, OffsetHashMap};
use crate::hyperlink::{HyperlinkId, HyperlinkMap, HyperlinkSet, PageEntry, PageEntryId};
use crate::ref_counted_set::{self, Layout as SetLayout};
use crate::size::{
    align_backward, align_forward, BufValue, CellCountInt, GraphemeBytesInt, Offset, OffsetBuf,
    OffsetSlice, StringBytesInt, StyleCountInt,
};
use crate::style::{PackedStyle, StyleContext, StyleSet};

#[allow(dead_code)]
pub(crate) const STRING_CHUNK: usize = 32;
#[allow(dead_code)]
pub(crate) type StringAlloc = BitmapAllocator<STRING_CHUNK>;

pub(crate) const GRAPHEME_CHUNK_LEN: usize = 4;
pub(crate) const GRAPHEME_CHUNK: usize = GRAPHEME_CHUNK_LEN * u32::SIZE;
pub(crate) type GraphemeAlloc = BitmapAllocator<GRAPHEME_CHUNK>;
pub(crate) type GraphemeMap = AutoOffsetHashMap<Offset<Cell>, OffsetSlice<u32>>;
pub(crate) const GRAPHEME_BYTES_DEFAULT: GraphemeBytesInt = 1024;
pub(crate) const STRING_BYTES_DEFAULT: StringBytesInt = 2048;
pub(crate) const HYPERLINK_COUNT_DEFAULT: usize = 4;
pub(crate) const HYPERLINK_CELL_MULTIPLIER: usize = 16;
pub(crate) const HYPERLINK_BYTES_DEFAULT: usize =
    HYPERLINK_COUNT_DEFAULT * ref_counted_set::item_byte_size::<crate::hyperlink::PageEntry>();
pub(crate) const PAGE_SIZE_MIN: usize = 4096;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SemanticPrompt {
    None = 0,
    Prompt = 1,
    PromptContinuation = 2,
}

impl SemanticPrompt {
    const fn from_bits(bits: u8) -> Self {
        match bits {
            1 => Self::Prompt,
            2 => Self::PromptContinuation,
            _ => Self::None,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Row(u64);

impl Row {
    #[allow(dead_code)]
    const CELLS_MASK: u64 = 0xFFFF_FFFF;
    const WRAP_BIT: u64 = 1 << 32;
    const WRAP_CONTINUATION_BIT: u64 = 1 << 33;
    const GRAPHEME_BIT: u64 = 1 << 34;
    const STYLED_BIT: u64 = 1 << 35;
    const HYPERLINK_BIT: u64 = 1 << 36;
    const SEMANTIC_PROMPT_SHIFT: u64 = 37;
    const SEMANTIC_PROMPT_MASK: u64 = 0b11 << Self::SEMANTIC_PROMPT_SHIFT;
    const KITTY_VIRTUAL_PLACEHOLDER_BIT: u64 = 1 << 39;
    const DIRTY_BIT: u64 = 1 << 40;

    pub const fn raw(self) -> u64 {
        self.0
    }

    #[allow(dead_code)]
    pub(crate) const fn cells(self) -> Offset<Cell> {
        Offset::new((self.0 & Self::CELLS_MASK) as u32)
    }

    #[allow(dead_code)]
    pub(crate) fn set_cells(&mut self, cells: Offset<Cell>) {
        self.0 = (self.0 & !Self::CELLS_MASK) | u64::from(cells.offset);
    }

    pub const fn wrap(self) -> bool {
        self.0 & Self::WRAP_BIT != 0
    }

    pub fn set_wrap(&mut self, value: bool) {
        self.set_bit(Self::WRAP_BIT, value);
    }

    pub const fn wrap_continuation(self) -> bool {
        self.0 & Self::WRAP_CONTINUATION_BIT != 0
    }

    pub fn set_wrap_continuation(&mut self, value: bool) {
        self.set_bit(Self::WRAP_CONTINUATION_BIT, value);
    }

    pub const fn grapheme(self) -> bool {
        self.0 & Self::GRAPHEME_BIT != 0
    }

    pub fn set_grapheme(&mut self, value: bool) {
        self.set_bit(Self::GRAPHEME_BIT, value);
    }

    pub const fn styled(self) -> bool {
        self.0 & Self::STYLED_BIT != 0
    }

    pub fn set_styled(&mut self, value: bool) {
        self.set_bit(Self::STYLED_BIT, value);
    }

    pub const fn hyperlink(self) -> bool {
        self.0 & Self::HYPERLINK_BIT != 0
    }

    pub fn set_hyperlink(&mut self, value: bool) {
        self.set_bit(Self::HYPERLINK_BIT, value);
    }

    pub const fn semantic_prompt(self) -> SemanticPrompt {
        SemanticPrompt::from_bits(
            ((self.0 & Self::SEMANTIC_PROMPT_MASK) >> Self::SEMANTIC_PROMPT_SHIFT) as u8,
        )
    }

    pub fn set_semantic_prompt(&mut self, value: SemanticPrompt) {
        self.0 = (self.0 & !Self::SEMANTIC_PROMPT_MASK)
            | ((value as u64) << Self::SEMANTIC_PROMPT_SHIFT);
    }

    /// Ghostty keeps this bit for kitty virtual placeholders. The feature is
    /// not ported in Locus yet, so the helper intentionally always reports
    /// false even though the storage bit is reserved.
    pub const fn kitty_virtual_placeholder(self) -> bool {
        let _ = self.0 & Self::KITTY_VIRTUAL_PLACEHOLDER_BIT;
        false
    }

    pub const fn dirty(self) -> bool {
        self.0 & Self::DIRTY_BIT != 0
    }

    pub fn set_dirty(&mut self, value: bool) {
        self.set_bit(Self::DIRTY_BIT, value);
    }

    pub const fn managed_memory(self) -> bool {
        self.styled() || self.hyperlink() || self.grapheme()
    }

    fn set_bit(&mut self, bit: u64, value: bool) {
        if value {
            self.0 |= bit;
        } else {
            self.0 &= !bit;
        }
    }
}

impl BufValue for Row {
    const SIZE: usize = u64::SIZE;
    const ALIGN: usize = u64::ALIGN;

    fn read(buf: &[u8], at: usize) -> Self {
        Self(u64::read(buf, at))
    }

    fn write(self, buf: &mut [u8], at: usize) {
        self.0.write(buf, at);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CellContentTag {
    Codepoint = 0,
    CodepointGrapheme = 1,
    BgColorPalette = 2,
    BgColorRgb = 3,
}

impl CellContentTag {
    const fn from_bits(bits: u8) -> Self {
        match bits & 0b11 {
            1 => Self::CodepointGrapheme,
            2 => Self::BgColorPalette,
            3 => Self::BgColorRgb,
            _ => Self::Codepoint,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum CellWide {
    Narrow = 0,
    Wide = 1,
    SpacerTail = 2,
    SpacerHead = 3,
}

impl CellWide {
    const fn from_bits(bits: u8) -> Self {
        match bits & 0b11 {
            1 => Self::Wide,
            2 => Self::SpacerTail,
            3 => Self::SpacerHead,
            _ => Self::Narrow,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SemanticContent {
    Output = 0,
    Input = 1,
    Prompt = 2,
}

impl SemanticContent {
    const fn from_bits(bits: u8) -> Self {
        match bits & 0b11 {
            1 => Self::Input,
            2 => Self::Prompt,
            _ => Self::Output,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Cell(u64);

impl Cell {
    const CONTENT_TAG_MASK: u64 = 0b11;
    const CONTENT_SHIFT: u64 = 2;
    const CODEPOINT_MASK: u64 = 0x1F_FFFF;
    const STYLE_ID_SHIFT: u64 = 26;
    const STYLE_ID_MASK: u64 = 0xFFFF << Self::STYLE_ID_SHIFT;
    const WIDE_SHIFT: u64 = 42;
    const WIDE_MASK: u64 = 0b11 << Self::WIDE_SHIFT;
    const PROTECTED_BIT: u64 = 1 << 44;
    const HYPERLINK_BIT: u64 = 1 << 45;
    const SEMANTIC_CONTENT_SHIFT: u64 = 46;
    const SEMANTIC_CONTENT_MASK: u64 = 0b11 << Self::SEMANTIC_CONTENT_SHIFT;

    pub const fn raw(self) -> u64 {
        self.0
    }

    pub const fn new(codepoint: char) -> Self {
        let mut cell = Self(0);
        cell.0 = ((codepoint as u32 as u64) & Self::CODEPOINT_MASK) << Self::CONTENT_SHIFT;
        cell
    }

    pub const fn bg_palette(index: u8) -> Self {
        Self((CellContentTag::BgColorPalette as u64) | (index as u64) << Self::CONTENT_SHIFT)
    }

    pub const fn bg_rgb(rgb: Rgb) -> Self {
        Self(
            (CellContentTag::BgColorRgb as u64)
                | (rgb.r as u64) << Self::CONTENT_SHIFT
                | (rgb.g as u64) << (Self::CONTENT_SHIFT + 8)
                | (rgb.b as u64) << (Self::CONTENT_SHIFT + 16),
        )
    }

    pub const fn is_zero(self) -> bool {
        self.0 == 0
    }

    pub const fn content_tag(self) -> CellContentTag {
        CellContentTag::from_bits((self.0 & Self::CONTENT_TAG_MASK) as u8)
    }

    pub const fn codepoint(self) -> u32 {
        match self.content_tag() {
            CellContentTag::Codepoint | CellContentTag::CodepointGrapheme => {
                ((self.0 >> Self::CONTENT_SHIFT) & Self::CODEPOINT_MASK) as u32
            }
            CellContentTag::BgColorPalette | CellContentTag::BgColorRgb => 0,
        }
    }

    pub const fn palette_index(self) -> u8 {
        ((self.0 >> Self::CONTENT_SHIFT) & 0xFF) as u8
    }

    pub const fn rgb(self) -> Rgb {
        Rgb {
            r: ((self.0 >> Self::CONTENT_SHIFT) & 0xFF) as u8,
            g: ((self.0 >> (Self::CONTENT_SHIFT + 8)) & 0xFF) as u8,
            b: ((self.0 >> (Self::CONTENT_SHIFT + 16)) & 0xFF) as u8,
        }
    }

    pub const fn has_text(self) -> bool {
        matches!(
            self.content_tag(),
            CellContentTag::Codepoint | CellContentTag::CodepointGrapheme
        ) && self.codepoint() != 0
    }

    pub const fn style_id(self) -> StyleCountInt {
        ((self.0 & Self::STYLE_ID_MASK) >> Self::STYLE_ID_SHIFT) as StyleCountInt
    }

    pub fn set_style_id(&mut self, id: StyleCountInt) {
        self.0 = (self.0 & !Self::STYLE_ID_MASK) | ((u64::from(id)) << Self::STYLE_ID_SHIFT);
    }

    pub const fn wide(self) -> CellWide {
        CellWide::from_bits(((self.0 & Self::WIDE_MASK) >> Self::WIDE_SHIFT) as u8)
    }

    pub fn set_wide(&mut self, wide: CellWide) {
        self.0 = (self.0 & !Self::WIDE_MASK) | ((wide as u64) << Self::WIDE_SHIFT);
    }

    pub const fn grid_width(self) -> u8 {
        if matches!(self.wide(), CellWide::Wide) {
            2
        } else {
            1
        }
    }

    pub const fn protected(self) -> bool {
        self.0 & Self::PROTECTED_BIT != 0
    }

    pub fn set_protected(&mut self, value: bool) {
        self.set_bit(Self::PROTECTED_BIT, value);
    }

    pub const fn hyperlink(self) -> bool {
        self.0 & Self::HYPERLINK_BIT != 0
    }

    pub fn set_hyperlink(&mut self, value: bool) {
        self.set_bit(Self::HYPERLINK_BIT, value);
    }

    pub const fn semantic_content(self) -> SemanticContent {
        SemanticContent::from_bits(
            ((self.0 & Self::SEMANTIC_CONTENT_MASK) >> Self::SEMANTIC_CONTENT_SHIFT) as u8,
        )
    }

    pub fn set_semantic_content(&mut self, value: SemanticContent) {
        self.0 = (self.0 & !Self::SEMANTIC_CONTENT_MASK)
            | ((value as u64) << Self::SEMANTIC_CONTENT_SHIFT);
    }

    pub const fn has_styling(self) -> bool {
        self.style_id() != 0
    }

    pub const fn has_grapheme(self) -> bool {
        matches!(self.content_tag(), CellContentTag::CodepointGrapheme)
    }

    pub const fn is_empty(self) -> bool {
        match self.content_tag() {
            CellContentTag::BgColorPalette | CellContentTag::BgColorRgb => false,
            CellContentTag::Codepoint | CellContentTag::CodepointGrapheme => {
                self.codepoint() == 0 && self.style_id() == 0 && !self.hyperlink()
            }
        }
    }

    fn set_bit(&mut self, bit: u64, value: bool) {
        if value {
            self.0 |= bit;
        } else {
            self.0 &= !bit;
        }
    }
}

impl BufValue for Cell {
    const SIZE: usize = u64::SIZE;
    const ALIGN: usize = u64::ALIGN;

    fn read(buf: &[u8], at: usize) -> Self {
        Self(u64::read(buf, at))
    }

    fn write(self, buf: &mut [u8], at: usize) {
        self.0.write(buf, at);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PageSize {
    pub cols: CellCountInt,
    pub rows: CellCountInt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Capacity {
    pub cols: CellCountInt,
    pub rows: CellCountInt,
    pub styles: StyleCountInt,
    pub hyperlink_bytes: u16,
    pub grapheme_bytes: GraphemeBytesInt,
    pub string_bytes: StringBytesInt,
}

impl Capacity {
    pub const fn new(cols: CellCountInt, rows: CellCountInt) -> Self {
        Self {
            cols,
            rows,
            styles: 16,
            hyperlink_bytes: HYPERLINK_BYTES_DEFAULT as u16,
            grapheme_bytes: GRAPHEME_BYTES_DEFAULT,
            string_bytes: STRING_BYTES_DEFAULT,
        }
    }
}

pub const STD_CAPACITY: Capacity = Capacity {
    cols: 215,
    rows: 215,
    styles: 128,
    hyperlink_bytes: HYPERLINK_BYTES_DEFAULT as u16,
    // Keep Page/PageList tests inline in this crate. Integration tests would
    // observe a different cfg(test) value and break the layout pin.
    grapheme_bytes: if cfg!(test) { 512 } else { 8192 },
    string_bytes: STRING_BYTES_DEFAULT,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Layout {
    pub(crate) capacity: Capacity,
    pub(crate) rows_start: usize,
    pub(crate) cells_start: usize,
    pub(crate) styles_start: usize,
    pub(crate) styles: SetLayout,
    pub(crate) grapheme_alloc_start: usize,
    pub(crate) grapheme_alloc: crate::bitmap_allocator::Layout,
    pub(crate) grapheme_map_start: usize,
    pub(crate) grapheme_map: crate::hash_map::Layout,
    pub(crate) string_alloc_start: usize,
    pub(crate) string_alloc: crate::bitmap_allocator::Layout,
    pub(crate) hyperlink_set_start: usize,
    pub(crate) hyperlink_set: SetLayout,
    pub(crate) hyperlink_map_start: usize,
    pub(crate) hyperlink_map: crate::hash_map::Layout,
    pub(crate) total_size: usize,
}

#[derive(Debug, Clone)]
pub struct Page {
    memory: Vec<u8>,
    rows: Offset<Row>,
    cells: Offset<Cell>,
    dirty: bool,
    string_alloc: StringAlloc,
    grapheme_alloc: GraphemeAlloc,
    grapheme_map: GraphemeMap,
    styles: StyleSet,
    hyperlink_map: HyperlinkMap,
    hyperlink_set: HyperlinkSet,
    size: PageSize,
    capacity: Capacity,
    pause_integrity_checks: usize,
}

impl Page {
    pub fn layout(capacity: Capacity) -> Layout {
        let rows_start = 0;
        let rows_end = rows_start + capacity.rows as usize * Row::SIZE;
        let cells_start = align_forward(rows_end, Cell::ALIGN);
        let cell_count = capacity.cols as usize * capacity.rows as usize;
        let cells_end = cells_start + cell_count * Cell::SIZE;

        let styles = StyleSet::layout_for_page(capacity.styles as usize);
        let styles_start =
            align_forward(cells_end, ref_counted_set::item_base_align::<PackedStyle>());
        let styles_end = styles_start + styles.total_size;

        let grapheme_alloc = GraphemeAlloc::layout(capacity.grapheme_bytes as usize);
        let grapheme_alloc_start = align_forward(styles_end, GraphemeAlloc::BASE_ALIGN);
        let grapheme_alloc_end = grapheme_alloc_start + grapheme_alloc.total_size;

        let grapheme_map_capacity =
            map_capacity_for_bytes(capacity.grapheme_bytes as usize, GRAPHEME_CHUNK);
        let grapheme_map = GraphemeMap::layout(grapheme_map_capacity);
        let grapheme_map_start = align_forward(grapheme_alloc_end, GraphemeMap::BASE_ALIGN);
        let grapheme_map_end = grapheme_map_start + grapheme_map.total_size;

        let string_alloc = StringAlloc::layout(capacity.string_bytes as usize);
        let string_alloc_start = align_forward(grapheme_map_end, StringAlloc::BASE_ALIGN);
        let string_alloc_end = string_alloc_start + string_alloc.total_size;

        let hyperlink_count = capacity.hyperlink_bytes as usize
            / ref_counted_set::item_byte_size::<crate::hyperlink::PageEntry>();
        let hyperlink_set = HyperlinkSet::layout_for_page(hyperlink_count);
        let hyperlink_set_start = align_forward(
            string_alloc_end,
            ref_counted_set::item_base_align::<crate::hyperlink::PageEntry>(),
        );
        let hyperlink_set_end = hyperlink_set_start + hyperlink_set.total_size;

        let hyperlink_map_capacity = hyperlink_map_capacity(hyperlink_count);
        let hyperlink_map = HyperlinkMap::layout(hyperlink_map_capacity);
        let hyperlink_map_start = align_forward(hyperlink_set_end, HyperlinkMap::BASE_ALIGN);
        let hyperlink_map_end = hyperlink_map_start + hyperlink_map.total_size;
        let total_size = align_forward(hyperlink_map_end, PAGE_SIZE_MIN);

        Layout {
            capacity,
            rows_start,
            cells_start,
            styles_start,
            styles,
            grapheme_alloc_start,
            grapheme_alloc,
            grapheme_map_start,
            grapheme_map,
            string_alloc_start,
            string_alloc,
            hyperlink_set_start,
            hyperlink_set,
            hyperlink_map_start,
            hyperlink_map,
            total_size,
        }
    }

    pub fn init(capacity: Capacity) -> Self {
        let layout = Self::layout(capacity);
        let memory = vec![0; layout.total_size];
        Self::init_buf(memory, layout)
    }

    pub fn init_buf(mut memory: Vec<u8>, layout: Layout) -> Self {
        debug_assert_eq!(memory.len(), layout.total_size);
        let rows = OffsetBuf::init_offset(layout.rows_start).member::<Row>(0);
        let cells = OffsetBuf::init_offset(layout.cells_start).member::<Cell>(0);
        for y in 0..layout.capacity.rows as usize {
            let mut row = Row::default();
            row.set_cells(Offset::new(
                (layout.cells_start + y * layout.capacity.cols as usize * Cell::SIZE) as u32,
            ));
            rows.set(&mut memory, y, row);
        }

        let styles = StyleSet::init(
            OffsetBuf::init_offset(layout.styles_start),
            layout.styles,
            &mut memory,
            StyleContext,
        );
        let grapheme_alloc = GraphemeAlloc::init(
            OffsetBuf::init_offset(layout.grapheme_alloc_start),
            layout.grapheme_alloc,
            &mut memory,
        );
        let grapheme_map = GraphemeMap::init(
            OffsetBuf::init_offset(layout.grapheme_map_start),
            layout.grapheme_map,
            &mut memory,
        );
        let string_alloc = StringAlloc::init(
            OffsetBuf::init_offset(layout.string_alloc_start),
            layout.string_alloc,
            &mut memory,
        );
        let hyperlink_set = HyperlinkSet::init(
            OffsetBuf::init_offset(layout.hyperlink_set_start),
            layout.hyperlink_set,
            &mut memory,
            crate::hyperlink::HyperlinkContext { string_alloc },
        );
        let hyperlink_map = HyperlinkMap::init(
            OffsetBuf::init_offset(layout.hyperlink_map_start),
            layout.hyperlink_map,
            &mut memory,
        );

        Self {
            memory,
            rows,
            cells,
            dirty: false,
            string_alloc,
            grapheme_alloc,
            grapheme_map,
            styles,
            hyperlink_map,
            hyperlink_set,
            size: PageSize {
                cols: layout.capacity.cols,
                rows: layout.capacity.rows,
            },
            capacity: layout.capacity,
            pause_integrity_checks: 0,
        }
    }

    pub fn reinit(&mut self) {
        let layout = Self::layout(self.capacity);
        self.memory.fill(0);
        let replacement = Self::init_buf(std::mem::take(&mut self.memory), layout);
        *self = replacement;
    }

    pub(crate) fn reinit_with_layout(&mut self, layout: Layout) {
        debug_assert_eq!(self.memory.len(), layout.total_size);
        self.memory.fill(0);
        let replacement = Self::init_buf(std::mem::take(&mut self.memory), layout);
        *self = replacement;
    }

    pub fn size(&self) -> PageSize {
        self.size
    }

    pub(crate) fn set_size(&mut self, size: PageSize) {
        debug_assert!(size.cols <= self.capacity.cols);
        debug_assert!(size.rows <= self.capacity.rows);
        self.size = size;
    }

    pub(crate) fn set_size_rows(&mut self, rows: CellCountInt) {
        debug_assert!(rows <= self.capacity.rows);
        self.size.rows = rows;
    }

    pub(crate) fn set_size_cols(&mut self, cols: CellCountInt) {
        debug_assert!(cols <= self.capacity.cols);
        self.size.cols = cols;
    }

    pub fn capacity(&self) -> Capacity {
        self.capacity
    }

    pub(crate) fn memory_len(&self) -> usize {
        self.memory.len()
    }

    pub(crate) fn memory_ptr(&self) -> *const u8 {
        self.memory.as_ptr()
    }

    pub(crate) fn into_memory(self) -> Vec<u8> {
        self.memory
    }

    pub(crate) fn page_dirty(&self) -> bool {
        self.dirty
    }

    pub(crate) fn set_page_dirty(&mut self, dirty: bool) {
        self.dirty = dirty;
    }

    pub(crate) fn row_dirty(&self, y: CellCountInt) -> bool {
        self.row(y).dirty()
    }

    pub(crate) fn mark_row_dirty(&mut self, y: CellCountInt) {
        let mut row = self.row(y);
        row.set_dirty(true);
        self.set_row(y, row);
    }

    pub fn row(&self, y: CellCountInt) -> Row {
        debug_assert!(y < self.size.rows);
        self.rows.get(&self.memory, y as usize)
    }

    pub fn set_row(&mut self, y: CellCountInt, row: Row) {
        debug_assert!(y < self.size.rows);
        self.rows.set(&mut self.memory, y as usize, row);
    }

    pub fn cell(&self, y: CellCountInt, x: CellCountInt) -> Cell {
        debug_assert!(y < self.size.rows);
        debug_assert!(x < self.size.cols);
        self.row(y).cells().get(&self.memory, x as usize)
    }

    pub fn set_cell(&mut self, y: CellCountInt, x: CellCountInt, cell: Cell) {
        debug_assert!(y < self.size.rows);
        debug_assert!(x < self.size.cols);
        self.row(y).cells().set(&mut self.memory, x as usize, cell);
        let mut row = self.row(y);
        row.set_dirty(true);
        if cell.has_styling() {
            row.set_styled(true);
        }
        if cell.has_grapheme() {
            row.set_grapheme(true);
        }
        if cell.hyperlink() {
            row.set_hyperlink(true);
        }
        self.set_row(y, row);
    }

    pub fn is_dirty(&self, y: CellCountInt) -> bool {
        self.dirty || self.row(y).dirty()
    }

    pub fn clear_dirty(&mut self) {
        self.dirty = false;
        for y in 0..self.size.rows {
            let mut row = self.row(y);
            row.set_dirty(false);
            self.set_row(y, row);
        }
    }

    pub fn clear_cells(&mut self, y: CellCountInt, start: CellCountInt, end: CellCountInt) {
        for x in start..end.min(self.size.cols) {
            self.clear_cell(y, x);
        }
        self.update_row_flags(y);
    }

    pub fn move_cells(
        &mut self,
        src_y: CellCountInt,
        src_start: CellCountInt,
        dst_y: CellCountInt,
        dst_start: CellCountInt,
        len: CellCountInt,
    ) {
        if len == 0 || (src_y == dst_y && dst_start == src_start) {
            return;
        }

        let src_end = src_start.saturating_add(len).min(self.size.cols);
        let dst_end = dst_start.saturating_add(len).min(self.size.cols);
        let count = (src_end - src_start).min(dst_end - dst_start);
        if count == 0 {
            return;
        }

        let mut moved = Vec::with_capacity(count as usize);
        for index in 0..count {
            let src_x = src_start + index;
            let cell = self.cell(src_y, src_x);
            let grapheme = self.detach_grapheme(src_y, src_x);
            let hyperlink = self.detach_hyperlink(src_y, src_x);
            moved.push((cell, grapheme, hyperlink));
        }

        self.clear_cells(dst_y, dst_start, dst_start.saturating_add(count));

        for (index, (cell, grapheme, hyperlink)) in moved.into_iter().enumerate() {
            let dst_x = dst_start + index as CellCountInt;
            self.write_cell_raw(dst_y, dst_x, cell);
            if let Some(slice) = grapheme {
                let key = self.cell_offset(dst_y, dst_x);
                self.grapheme_map
                    .put_assume_capacity(&mut self.memory, key, slice);
            }
            if let Some(id) = hyperlink {
                let key = self.cell_offset(dst_y, dst_x);
                self.hyperlink_map
                    .put_assume_capacity(&mut self.memory, key, id);
            }
        }

        for index in 0..count {
            self.write_cell_raw(src_y, src_start + index, Cell::default());
        }

        let mut src_row = self.row(src_y);
        src_row.set_dirty(true);
        self.set_row(src_y, src_row);
        let mut dst_row = self.row(dst_y);
        dst_row.set_dirty(true);
        self.set_row(dst_y, dst_row);

        if src_start == 0 && count >= self.size.cols {
            let mut row = self.row(src_y);
            row.set_grapheme(false);
            row.set_hyperlink(false);
            row.set_styled(false);
            self.set_row(src_y, row);
        } else {
            self.update_row_flags(src_y);
        }
        self.update_row_flags(dst_y);
    }

    pub fn clone_partial_row_from(
        &mut self,
        source: CloneSource<'_>,
        dst_y: CellCountInt,
        src_y: CellCountInt,
        x_start: CellCountInt,
        x_end: CellCountInt,
    ) {
        let source_page = match source {
            CloneSource::SamePage => self.clone(),
            CloneSource::Other(page) => page.clone(),
        };
        self.clear_cells(dst_y, x_start, x_end);
        for x in x_start..x_end.min(self.size.cols).min(source_page.size.cols) {
            self.clone_cell_from(&source_page, src_y, x, dst_y, x);
        }
        if x_start == 0 && x_end >= self.size.cols {
            let mut row = source_page.row(src_y);
            row.set_cells(self.row(dst_y).cells());
            row.set_dirty(true);
            self.set_row(dst_y, row);
        } else {
            let mut row = self.row(dst_y);
            row.set_dirty(true);
            self.set_row(dst_y, row);
            self.update_row_flags(dst_y);
        }
    }

    pub(crate) fn clone_rows_from(
        &mut self,
        source: &Page,
        start_y: CellCountInt,
        end_y: CellCountInt,
    ) {
        let count = end_y.saturating_sub(start_y);
        for offset in 0..count {
            self.clone_partial_row_from(
                CloneSource::Other(source),
                offset,
                start_y + offset,
                0,
                source.size.cols.min(self.size.cols),
            );
        }
    }

    pub(crate) fn clone_row_from_page(
        &mut self,
        dst_y: CellCountInt,
        source: &Page,
        src_y: CellCountInt,
    ) {
        self.clone_partial_row_from(
            CloneSource::Other(source),
            dst_y,
            src_y,
            0,
            source.size.cols.min(self.size.cols),
        );
    }

    pub(crate) fn clear_row(&mut self, y: CellCountInt) {
        self.clear_cells(y, 0, self.size.cols);
    }

    pub(crate) fn rotate_rows_left_once(&mut self, start: CellCountInt, end: CellCountInt) {
        debug_assert!(start < end);
        debug_assert!(end <= self.size.rows);
        if end.saturating_sub(start) <= 1 {
            return;
        }
        let first = self.row(start);
        for y in start..end - 1 {
            let next = self.row(y + 1);
            self.set_row(y, next);
        }
        self.set_row(end - 1, first);
    }

    pub(crate) fn swap_rows(&mut self, left: CellCountInt, right: CellCountInt) {
        debug_assert!(left < self.size.rows);
        debug_assert!(right < self.size.rows);
        if left == right {
            return;
        }
        let left_row = self.row(left);
        let right_row = self.row(right);
        self.set_row(left, right_row);
        self.set_row(right, left_row);
    }

    pub(crate) fn has_text_any(&self, y: CellCountInt) -> bool {
        (0..self.size.cols).any(|x| self.cell(y, x).has_text())
    }

    pub(crate) fn set_row_dirty(&mut self, y: CellCountInt, dirty: bool) {
        let mut row = self.row(y);
        row.set_dirty(dirty);
        self.set_row(y, row);
    }

    pub fn exact_row_capacity(&self, y: CellCountInt) -> Capacity {
        self.exact_row_capacity_range(y, 1)
    }

    pub fn exact_row_capacity_range(&self, start_y: CellCountInt, rows: CellCountInt) -> Capacity {
        let mut style_ids = Vec::<StyleCountInt>::new();
        let mut hyperlink_ids = Vec::<HyperlinkId>::new();
        let mut hyperlink_cells = 0usize;
        let mut grapheme_bytes = 0usize;
        for y in start_y..start_y.saturating_add(rows).min(self.size.rows) {
            for x in 0..self.size.cols {
                let cell = self.cell(y, x);
                if cell.has_styling() && !style_ids.contains(&cell.style_id()) {
                    style_ids.push(cell.style_id());
                }
                if cell.hyperlink() {
                    hyperlink_cells += 1;
                    if let Some(id) = self.hyperlink_id(y, x) {
                        if !hyperlink_ids.contains(&id) {
                            hyperlink_ids.push(id);
                        }
                    }
                }
                if let Some(slice) = self.grapheme_slice(y, x) {
                    grapheme_bytes += GraphemeAlloc::bytes_required::<u32>(slice.len);
                } else if cell.has_grapheme() {
                    grapheme_bytes += GraphemeAlloc::bytes_required::<u32>(GRAPHEME_CHUNK_LEN);
                }
            }
        }
        let hyperlink_count = hyperlink_ids
            .len()
            .max(hyperlink_cells.div_ceil(HYPERLINK_CELL_MULTIPLIER));
        let string_bytes = hyperlink_ids
            .iter()
            .filter_map(|&id| self.hyperlink_set.get(&self.memory, id))
            .map(|entry| self.hyperlink_entry_string_bytes(entry))
            .sum::<usize>();
        Capacity {
            cols: self.size.cols,
            rows: rows.min(self.size.rows.saturating_sub(start_y)),
            styles: StyleSet::capacity_for_count(style_ids.len()) as StyleCountInt,
            hyperlink_bytes: (HyperlinkSet::capacity_for_count(hyperlink_count)
                * ref_counted_set::item_byte_size::<crate::hyperlink::PageEntry>())
                as u16,
            grapheme_bytes: grapheme_bytes as GraphemeBytesInt,
            string_bytes: string_bytes as StringBytesInt,
        }
    }

    pub fn verify_integrity(&self) -> Result<(), IntegrityError> {
        if self.size.rows == 0 {
            return Err(IntegrityError::ZeroRowCount);
        }
        if self.size.cols == 0 {
            return Err(IntegrityError::ZeroColCount);
        }
        let mut style_refs = Vec::<(StyleCountInt, ref_counted_set::RefCountInt)>::new();
        for y in 0..self.size.rows {
            let row = self.row(y);
            if row.cells().offset as usize >= self.memory.len() {
                return Err(IntegrityError::InvalidRowCells);
            }
            let mut has_grapheme = false;
            let mut has_styled = false;
            let mut has_hyperlink = false;
            for x in 0..self.size.cols {
                let cell = self.cell(y, x);
                if matches!(cell.wide(), CellWide::SpacerTail) && x == 0 {
                    return Err(IntegrityError::SpacerTailAtColumnZero);
                }
                if matches!(cell.wide(), CellWide::SpacerHead)
                    && (x + 1 != self.size.cols || !row.wrap())
                {
                    return Err(IntegrityError::InvalidSpacerHead);
                }
                if cell.has_grapheme() {
                    has_grapheme = true;
                    if self.grapheme_slice(y, x).is_none() {
                        return Err(IntegrityError::MissingGraphemeEntry);
                    }
                }
                if cell.has_styling() {
                    has_styled = true;
                    if self.styles.get(&self.memory, cell.style_id()).is_none() {
                        return Err(IntegrityError::MissingStyleEntry);
                    }
                    if let Some((_, count)) =
                        style_refs.iter_mut().find(|(id, _)| *id == cell.style_id())
                    {
                        *count += 1;
                    } else {
                        style_refs.push((cell.style_id(), 1));
                    }
                }
                if cell.hyperlink() {
                    has_hyperlink = true;
                    if self.hyperlink_id(y, x).is_none() {
                        return Err(IntegrityError::MissingHyperlinkEntry);
                    }
                }
            }
            if has_grapheme != row.grapheme() {
                return Err(IntegrityError::UnmarkedGraphemeRow);
            }
            if has_styled != row.styled() {
                return Err(IntegrityError::StyledRowFlagMismatch);
            }
            if has_hyperlink != row.hyperlink() {
                return Err(IntegrityError::HyperlinkRowFlagMismatch);
            }
        }
        for (id, count) in style_refs {
            if self.styles.ref_count(&self.memory, id) != count {
                return Err(IntegrityError::MismatchedStyleRef);
            }
        }
        Ok(())
    }

    pub fn max_cols(total_size: usize, rows: CellCountInt) -> CellCountInt {
        if rows == 0 || total_size <= PAGE_SIZE_MIN {
            return 0;
        }
        let meta = PAGE_SIZE_MIN;
        let available = total_size.saturating_sub(meta);
        let per_col = rows as usize * Cell::SIZE;
        (available / per_col).min(CellCountInt::MAX as usize) as CellCountInt
    }

    pub fn max_cols_for_capacity(capacity: Capacity) -> Option<CellCountInt> {
        for cols in (1..=CellCountInt::MAX).rev() {
            if matches!(Self::try_adjust(capacity, cols), Some(adjusted) if adjusted.rows == 1) {
                return Some(cols);
            }
        }
        None
    }

    pub fn try_adjust(mut capacity: Capacity, cols: CellCountInt) -> Option<Capacity> {
        if cols == 0 {
            return None;
        }
        let total = Self::layout(capacity).total_size;
        capacity.cols = cols;

        while Self::layout(Capacity {
            rows: 1,
            ..capacity
        })
        .total_size
            > total
        {
            if capacity.grapheme_bytes > 0 {
                capacity.grapheme_bytes = align_backward(
                    capacity.grapheme_bytes.saturating_sub(1) as usize,
                    GRAPHEME_CHUNK,
                ) as GraphemeBytesInt;
                continue;
            }
            if capacity.string_bytes > 0 {
                capacity.string_bytes = align_backward(
                    capacity.string_bytes.saturating_sub(1) as usize,
                    STRING_CHUNK,
                ) as StringBytesInt;
                continue;
            }
            if capacity.styles > 0 {
                capacity.styles -= 1;
                continue;
            }
            if capacity.hyperlink_bytes > 0 {
                let item = ref_counted_set::item_byte_size::<crate::hyperlink::PageEntry>() as u16;
                capacity.hyperlink_bytes = capacity
                    .hyperlink_bytes
                    .saturating_sub(item)
                    .saturating_sub(0);
                capacity.hyperlink_bytes = capacity.hyperlink_bytes / item.max(1) * item.max(1);
                continue;
            }
            return None;
        }

        let mut lo: CellCountInt = 1;
        let mut hi: CellCountInt = CellCountInt::MAX;
        let mut best: CellCountInt = 1;
        while lo <= hi {
            let mid = lo + (hi - lo) / 2;
            let candidate = Capacity {
                rows: mid,
                ..capacity
            };
            if Self::layout(candidate).total_size <= total {
                best = mid;
                lo = mid.saturating_add(1);
            } else if mid == 0 {
                break;
            } else {
                hi = mid - 1;
            }
        }

        capacity.rows = best;
        if Self::layout(capacity).total_size != total {
            return None;
        }
        Some(capacity)
    }

    pub fn adjust(capacity: Capacity, cols: CellCountInt) -> Capacity {
        Self::try_adjust(capacity, cols).unwrap_or(Capacity { cols, ..capacity })
    }

    fn hyperlink_entry_string_bytes(&self, entry: PageEntry) -> usize {
        let uri = StringAlloc::bytes_required::<u8>(entry.uri().len);
        let id = match entry.id() {
            PageEntryId::Explicit(slice) => StringAlloc::bytes_required::<u8>(slice.len),
            PageEntryId::Implicit(_) => 0,
        };
        uri + id
    }

    fn update_row_flags(&mut self, y: CellCountInt) {
        let mut row = self.row(y);
        let mut styled = false;
        let mut hyperlink = false;
        let mut grapheme = false;
        for x in 0..self.size.cols {
            let cell = self.cell(y, x);
            styled |= cell.has_styling();
            hyperlink |= cell.hyperlink();
            grapheme |= cell.has_grapheme();
        }
        row.set_styled(styled);
        row.set_hyperlink(hyperlink);
        row.set_grapheme(grapheme);
        self.set_row(y, row);
    }

    fn cell_offset(&self, y: CellCountInt, x: CellCountInt) -> Offset<Cell> {
        Offset::new(self.row(y).cells().offset + u32::from(x) * Cell::SIZE as u32)
    }

    fn write_cell_raw(&mut self, y: CellCountInt, x: CellCountInt, cell: Cell) {
        self.row(y).cells().set(&mut self.memory, x as usize, cell);
    }

    fn clear_cell(&mut self, y: CellCountInt, x: CellCountInt) {
        let cell = self.cell(y, x);
        if cell.has_grapheme() {
            self.clear_grapheme(y, x);
        }
        if cell.hyperlink() {
            self.clear_hyperlink(y, x);
        }
        if cell.has_styling() && self.styles.get(&self.memory, cell.style_id()).is_some() {
            self.styles.release(&mut self.memory, cell.style_id());
        }
        self.write_cell_raw(y, x, Cell::default());
        let mut row = self.row(y);
        row.set_dirty(true);
        self.set_row(y, row);
    }

    pub(crate) fn append_grapheme(
        &mut self,
        y: CellCountInt,
        x: CellCountInt,
        codepoint: u32,
    ) -> Result<(), OutOfMemory> {
        let key = self.cell_offset(y, x);
        let mut current = self
            .detach_grapheme(y, x)
            .map(|slice| {
                let values = self.read_grapheme_slice(slice);
                self.grapheme_alloc.free(&mut self.memory, slice);
                values
            })
            .unwrap_or_default();
        current.push(codepoint);
        let slice = self
            .grapheme_alloc
            .alloc::<u32>(&mut self.memory, current.len())?;
        for (index, value) in current.into_iter().enumerate() {
            slice.offset.set(&mut self.memory, index, value);
        }
        self.grapheme_map.put(&mut self.memory, key, slice)?;
        let mut cell = self.cell(y, x);
        cell.0 = (cell.0 & !Cell::CONTENT_TAG_MASK) | CellContentTag::CodepointGrapheme as u64;
        self.write_cell_raw(y, x, cell);
        self.update_row_flags(y);
        Ok(())
    }

    pub(crate) fn clear_grapheme(&mut self, y: CellCountInt, x: CellCountInt) {
        if let Some(slice) = self.detach_grapheme(y, x) {
            self.grapheme_alloc.free(&mut self.memory, slice);
        }
        let mut cell = self.cell(y, x);
        if cell.has_grapheme() {
            cell.0 = (cell.0 & !Cell::CONTENT_TAG_MASK) | CellContentTag::Codepoint as u64;
            self.write_cell_raw(y, x, cell);
        }
        self.update_row_flags(y);
    }

    pub(crate) fn grapheme(&self, y: CellCountInt, x: CellCountInt) -> Option<Vec<u32>> {
        self.grapheme_slice(y, x)
            .map(|slice| self.read_grapheme_slice(slice))
    }

    pub(crate) fn grapheme_count(&self) -> usize {
        self.grapheme_map.count() as usize
    }

    pub(crate) fn set_style(
        &mut self,
        y: CellCountInt,
        x: CellCountInt,
        style: PackedStyle,
    ) -> Result<StyleCountInt, OutOfMemory> {
        let id = self
            .styles
            .add(&mut self.memory, style)
            .map_err(|_| OutOfMemory)?;
        let mut cell = self.cell(y, x);
        cell.set_style_id(id);
        self.write_cell_raw(y, x, cell);
        self.update_row_flags(y);
        Ok(id)
    }

    pub(crate) fn add_style(&mut self, style: PackedStyle) -> Result<StyleCountInt, OutOfMemory> {
        self.styles
            .add(&mut self.memory, style)
            .map_err(|_| OutOfMemory)
    }

    pub(crate) fn use_style(&mut self, id: StyleCountInt) {
        self.styles.use_ref(&mut self.memory, id);
    }

    pub(crate) fn release_style(&mut self, id: StyleCountInt) {
        self.styles.release(&mut self.memory, id);
    }

    pub(crate) fn set_style_id_raw(&mut self, y: CellCountInt, x: CellCountInt, id: StyleCountInt) {
        let mut cell = self.cell(y, x);
        cell.set_style_id(id);
        self.write_cell_raw(y, x, cell);
        self.update_row_flags(y);
    }

    pub(crate) fn style_count(&self) -> usize {
        self.styles.count()
    }

    pub(crate) fn set_hyperlink_implicit(
        &mut self,
        y: CellCountInt,
        x: CellCountInt,
        id: u32,
        uri: &[u8],
    ) -> Result<HyperlinkId, OutOfMemory> {
        let uri = self.copy_bytes(uri)?;
        let entry = PageEntry::implicit(id, uri);
        self.set_hyperlink_entry(y, x, entry)
    }

    pub(crate) fn insert_hyperlink_implicit(
        &mut self,
        id: u32,
        uri: &[u8],
    ) -> Result<HyperlinkId, OutOfMemory> {
        let uri = self.copy_bytes(uri)?;
        self.hyperlink_set
            .add(&mut self.memory, PageEntry::implicit(id, uri))
            .map_err(|_| OutOfMemory)
    }

    pub(crate) fn insert_hyperlink_explicit(
        &mut self,
        id: &[u8],
        uri: &[u8],
    ) -> Result<HyperlinkId, OutOfMemory> {
        let id = self.copy_bytes(id)?;
        let uri = self.copy_bytes(uri)?;
        self.hyperlink_set
            .add(&mut self.memory, PageEntry::explicit(id, uri))
            .map_err(|_| OutOfMemory)
    }

    pub(crate) fn set_hyperlink_id(
        &mut self,
        y: CellCountInt,
        x: CellCountInt,
        id: HyperlinkId,
    ) -> Result<(), OutOfMemory> {
        self.hyperlink_set.use_ref(&mut self.memory, id);
        let key = self.cell_offset(y, x);
        if let Err(err) = self.hyperlink_map.put(&mut self.memory, key, id) {
            self.hyperlink_set.release(&mut self.memory, id);
            return Err(err);
        }
        let mut cell = self.cell(y, x);
        cell.set_hyperlink(true);
        self.write_cell_raw(y, x, cell);
        self.update_row_flags(y);
        Ok(())
    }

    pub(crate) fn hyperlink_capacity(&self) -> usize {
        self.hyperlink_map.capacity() as usize
    }

    pub(crate) fn hyperlink_count(&self) -> usize {
        self.hyperlink_map.count() as usize
    }

    pub(crate) fn hyperlink_id(&self, y: CellCountInt, x: CellCountInt) -> Option<HyperlinkId> {
        self.hyperlink_map.get(&self.memory, self.cell_offset(y, x))
    }

    fn set_hyperlink_entry(
        &mut self,
        y: CellCountInt,
        x: CellCountInt,
        entry: PageEntry,
    ) -> Result<HyperlinkId, OutOfMemory> {
        let id = self
            .hyperlink_set
            .add(&mut self.memory, entry)
            .map_err(|_| OutOfMemory)?;
        let key = self.cell_offset(y, x);
        if let Err(err) = self.hyperlink_map.put(&mut self.memory, key, id) {
            self.hyperlink_set.release(&mut self.memory, id);
            return Err(err);
        }
        let mut cell = self.cell(y, x);
        cell.set_hyperlink(true);
        self.write_cell_raw(y, x, cell);
        self.update_row_flags(y);
        Ok(id)
    }

    fn clear_hyperlink(&mut self, y: CellCountInt, x: CellCountInt) {
        if let Some(id) = self.detach_hyperlink(y, x) {
            self.hyperlink_set.release(&mut self.memory, id);
        }
        let mut cell = self.cell(y, x);
        cell.set_hyperlink(false);
        self.write_cell_raw(y, x, cell);
    }

    fn clone_cell_from(
        &mut self,
        source: &Page,
        src_y: CellCountInt,
        src_x: CellCountInt,
        dst_y: CellCountInt,
        dst_x: CellCountInt,
    ) {
        let mut cell = source.cell(src_y, src_x);
        if let Some(style) = source.style_for_cell(src_y, src_x) {
            if let Ok(id) = self.styles.add(&mut self.memory, style) {
                cell.set_style_id(id);
            }
        }
        if source.grapheme(src_y, src_x).is_some() {
            cell.0 = (cell.0 & !Cell::CONTENT_TAG_MASK) | CellContentTag::Codepoint as u64;
        }
        if let Some(entry) = source.hyperlink_entry(src_y, src_x) {
            cell.set_hyperlink(false);
            self.write_cell_raw(dst_y, dst_x, cell);
            if let Some(id) =
                self.hyperlink_set
                    .lookup_with_probe(&self.memory, &source.memory, entry)
            {
                let _ = self.set_hyperlink_id(dst_y, dst_x, id);
            } else if let Some(copied) = self.copy_hyperlink_entry(source, entry) {
                let _ = self.set_hyperlink_entry(dst_y, dst_x, copied);
            }
        } else {
            self.write_cell_raw(dst_y, dst_x, cell);
        }
        if let Some(grapheme) = source.grapheme(src_y, src_x) {
            for codepoint in grapheme {
                let _ = self.append_grapheme(dst_y, dst_x, codepoint);
            }
        }
        self.update_row_flags(dst_y);
    }

    fn style_for_cell(&self, y: CellCountInt, x: CellCountInt) -> Option<PackedStyle> {
        let id = self.cell(y, x).style_id();
        self.styles.get(&self.memory, id)
    }

    fn hyperlink_entry(&self, y: CellCountInt, x: CellCountInt) -> Option<PageEntry> {
        let id = self.hyperlink_id(y, x)?;
        self.hyperlink_set.get(&self.memory, id)
    }

    fn copy_hyperlink_entry(&mut self, source: &Page, entry: PageEntry) -> Option<PageEntry> {
        let uri = self.copy_bytes(source.bytes(entry.uri())).ok()?;
        Some(match entry.id() {
            PageEntryId::Explicit(id) => {
                let id = self.copy_bytes(source.bytes(id)).ok()?;
                PageEntry::explicit(id, uri)
            }
            PageEntryId::Implicit(id) => PageEntry::implicit(id, uri),
        })
    }

    fn copy_bytes(&mut self, bytes: &[u8]) -> Result<OffsetSlice<u8>, OutOfMemory> {
        let slice = self
            .string_alloc
            .alloc::<u8>(&mut self.memory, bytes.len())?;
        for (index, byte) in bytes.iter().copied().enumerate() {
            slice.offset.set(&mut self.memory, index, byte);
        }
        Ok(slice)
    }

    fn bytes(&self, slice: OffsetSlice<u8>) -> &[u8] {
        let start = slice.offset.offset as usize;
        &self.memory[start..start + slice.len]
    }

    fn grapheme_slice(&self, y: CellCountInt, x: CellCountInt) -> Option<OffsetSlice<u32>> {
        self.grapheme_map.get(&self.memory, self.cell_offset(y, x))
    }

    fn detach_grapheme(&mut self, y: CellCountInt, x: CellCountInt) -> Option<OffsetSlice<u32>> {
        let key = self.cell_offset(y, x);
        self.grapheme_map
            .fetch_remove(&mut self.memory, key)
            .map(|(_, slice)| slice)
    }

    fn detach_hyperlink(&mut self, y: CellCountInt, x: CellCountInt) -> Option<HyperlinkId> {
        let key = self.cell_offset(y, x);
        self.hyperlink_map
            .fetch_remove(&mut self.memory, key)
            .map(|(_, id)| id)
    }

    fn read_grapheme_slice(&self, slice: OffsetSlice<u32>) -> Vec<u32> {
        (0..slice.len)
            .map(|index| slice.offset.get(&self.memory, index))
            .collect()
    }
}

#[derive(Clone, Copy)]
pub enum CloneSource<'a> {
    SamePage,
    Other(&'a Page),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IntegrityError {
    ZeroRowCount,
    ZeroColCount,
    InvalidRowCells,
    SpacerTailAtColumnZero,
    InvalidSpacerHead,
    MissingGraphemeEntry,
    UnmarkedGraphemeRow,
    MissingStyleEntry,
    MismatchedStyleRef,
    StyledRowFlagMismatch,
    MissingHyperlinkEntry,
    HyperlinkRowFlagMismatch,
}

fn map_capacity_for_bytes(bytes: usize, chunk: usize) -> u32 {
    if bytes == 0 {
        return 0;
    }
    ceil_power_of_two(bytes.div_ceil(chunk))
}

fn hyperlink_map_capacity(hyperlink_count: usize) -> u32 {
    if hyperlink_count == 0 {
        return 0;
    }
    let target = hyperlink_count.saturating_mul(HYPERLINK_CELL_MULTIPLIER);
    // Ghostty's unreachable overflow fallback is maxInt(u32). Our hash map
    // requires power-of-two capacity, so the equivalent unreachable fallback is
    // the largest u32 power of two.
    ceil_power_of_two(target).max(1)
}

fn ceil_power_of_two(value: usize) -> u32 {
    if value <= 1 {
        1
    } else {
        match value.checked_next_power_of_two() {
            Some(next) if next <= (1usize << 31) => next as u32,
            _ => 1u32 << 31,
        }
    }
}

trait RefCountedSetPageLayout<T: BufValue, Ctx> {
    fn layout_for_page(capacity: usize) -> SetLayout;
}

impl<T: BufValue, Ctx> RefCountedSetPageLayout<T, Ctx>
    for crate::ref_counted_set::RefCountedSet<T, Ctx>
{
    fn layout_for_page(capacity: usize) -> SetLayout {
        SetLayout::init::<T>(capacity)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_adjusted_capacity_fills_page(original: Capacity, adjusted: Capacity) {
        let original_size = Page::layout(original).total_size;
        assert_eq!(Page::layout(adjusted).total_size, original_size);
        let bigger = Capacity {
            rows: adjusted.rows + 1,
            ..adjusted
        };
        assert!(Page::layout(bigger).total_size > original_size);
    }

    #[test]
    fn row_buf_value_is_u64_little_endian() {
        let mut row = Row::default();
        row.set_cells(Offset::new(0x1122_3344));
        row.set_wrap(true);
        row.set_grapheme(true);
        row.set_styled(true);
        row.set_hyperlink(true);
        row.set_semantic_prompt(SemanticPrompt::PromptContinuation);
        row.set_dirty(true);

        let mut buf = [0u8; Row::SIZE];
        row.write(&mut buf, 0);
        assert_eq!(Row::read(&buf, 0), row);
        assert_eq!(row.cells().offset, 0x1122_3344);
        assert!(row.wrap());
        assert!(!row.wrap_continuation());
        assert!(row.grapheme());
        assert!(row.styled());
        assert!(row.hyperlink());
        assert_eq!(row.semantic_prompt(), SemanticPrompt::PromptContinuation);
        assert!(!row.kitty_virtual_placeholder());
        assert!(row.dirty());
        assert!(row.managed_memory());
    }

    #[test]
    fn row_reserved_bits_remain_zero_through_helpers() {
        let mut row = Row::default();
        row.set_cells(Offset::new(1));
        row.set_wrap(true);
        row.set_wrap_continuation(true);
        row.set_grapheme(true);
        row.set_styled(true);
        row.set_hyperlink(true);
        row.set_semantic_prompt(SemanticPrompt::Prompt);
        row.set_dirty(true);
        assert_eq!(row.raw() >> 41, 0);
    }

    #[test]
    fn cell_zero_is_valid_empty_cell() {
        let cell = Cell::default();
        assert!(cell.is_zero());
        assert!(cell.is_empty());
        assert_eq!(cell.content_tag(), CellContentTag::Codepoint);
        assert_eq!(cell.codepoint(), 0);
        assert_eq!(cell.grid_width(), 1);
    }

    #[test]
    fn cell_codepoint_lane_zeros_unused_bits() {
        let cell = Cell::new(char::from_u32(0x10_FFFF).unwrap());
        assert_eq!(cell.codepoint(), 0x10_FFFF);
        assert!(cell.has_text());
        assert_eq!((cell.raw() >> 23) & 0b111, 0);
    }

    #[test]
    fn cell_color_content_encodes_palette_and_rgb() {
        let palette = Cell::bg_palette(12);
        assert_eq!(palette.content_tag(), CellContentTag::BgColorPalette);
        assert_eq!(palette.palette_index(), 12);
        assert!(!palette.is_empty());

        let rgb = Cell::bg_rgb(Rgb { r: 1, g: 2, b: 3 });
        assert_eq!(rgb.content_tag(), CellContentTag::BgColorRgb);
        assert_eq!(rgb.rgb(), Rgb { r: 1, g: 2, b: 3 });
        assert_eq!(rgb.codepoint(), 0);
        assert!(!rgb.is_empty());
    }

    #[test]
    fn cell_flags_and_ids_have_pinned_bit_positions() {
        let mut cell = Cell::new('A');
        cell.set_style_id(0xBEEF);
        cell.set_wide(CellWide::SpacerHead);
        cell.set_protected(true);
        cell.set_hyperlink(true);
        cell.set_semantic_content(SemanticContent::Prompt);

        assert_eq!(cell.style_id(), 0xBEEF);
        assert_eq!(cell.wide(), CellWide::SpacerHead);
        assert!(cell.protected());
        assert!(cell.hyperlink());
        assert_eq!(cell.semantic_content(), SemanticContent::Prompt);
        assert_eq!((cell.raw() >> 48), 0);
    }

    #[test]
    fn cell_grapheme_and_width_helpers_match_ghostty_shape() {
        let mut cell = Cell::new('x');
        assert!(!cell.has_grapheme());
        assert_eq!(cell.grid_width(), 1);
        cell.0 = (cell.0 & !Cell::CONTENT_TAG_MASK) | CellContentTag::CodepointGrapheme as u64;
        cell.set_wide(CellWide::Wide);
        assert!(cell.has_grapheme());
        assert_eq!(cell.grid_width(), 2);
    }

    #[test]
    fn layout_of_std_capacity_is_stable() {
        // Replaces Ghostty's commented 512KiB pin with this port's exact
        // self-consistent byte layout.
        let layout = Page::layout(STD_CAPACITY);
        assert_eq!(layout.total_size, 450_560);
        assert_eq!(layout.total_size % PAGE_SIZE_MIN, 0);
    }

    #[test]
    fn capacity_new_applies_defaults() {
        let capacity = Capacity::new(80, 24);
        assert_eq!(capacity.cols, 80);
        assert_eq!(capacity.rows, 24);
        assert_eq!(capacity.styles, 16);
        assert_eq!(capacity.grapheme_bytes, GRAPHEME_BYTES_DEFAULT);
        assert_eq!(capacity.string_bytes, STRING_BYTES_DEFAULT);
        assert_eq!(
            usize::from(capacity.hyperlink_bytes),
            HYPERLINK_BYTES_DEFAULT
        );
    }

    #[test]
    fn layout_orders_rows_before_cells() {
        let layout = Page::layout(Capacity::new(10, 3));
        assert_eq!(layout.rows_start, 0);
        assert!(layout.cells_start >= 3 * Row::SIZE);
        assert_eq!(layout.cells_start % Cell::ALIGN, 0);
    }

    #[test]
    fn layout_orders_styles_after_cells() {
        let cap = Capacity::new(10, 3);
        let layout = Page::layout(cap);
        let cells_end = layout.cells_start + cap.cols as usize * cap.rows as usize * Cell::SIZE;
        assert!(layout.styles_start >= cells_end);
        assert_eq!(
            layout.styles_start % ref_counted_set::item_base_align::<PackedStyle>(),
            0
        );
    }

    #[test]
    fn layout_orders_grapheme_allocator_after_styles() {
        let layout = Page::layout(Capacity::new(10, 3));
        assert!(layout.grapheme_alloc_start >= layout.styles_start + layout.styles.total_size);
        assert_eq!(layout.grapheme_alloc_start % GraphemeAlloc::BASE_ALIGN, 0);
    }

    #[test]
    fn layout_orders_grapheme_map_after_grapheme_allocator() {
        let layout = Page::layout(Capacity::new(10, 3));
        assert!(
            layout.grapheme_map_start
                >= layout.grapheme_alloc_start + layout.grapheme_alloc.total_size
        );
        assert_eq!(layout.grapheme_map.capacity, 64);
    }

    #[test]
    fn layout_orders_string_allocator_after_grapheme_map() {
        let layout = Page::layout(Capacity::new(10, 3));
        assert!(
            layout.string_alloc_start >= layout.grapheme_map_start + layout.grapheme_map.total_size
        );
        assert_eq!(layout.string_alloc_start % StringAlloc::BASE_ALIGN, 0);
    }

    #[test]
    fn layout_orders_hyperlink_set_before_hyperlink_map() {
        let layout = Page::layout(Capacity::new(10, 3));
        assert!(
            layout.hyperlink_set_start
                >= layout.string_alloc_start + layout.string_alloc.total_size
        );
        assert!(
            layout.hyperlink_map_start
                >= layout.hyperlink_set_start + layout.hyperlink_set.total_size
        );
    }

    #[test]
    fn layout_zero_optional_sections_have_zero_map_capacity() {
        let cap = Capacity {
            grapheme_bytes: 0,
            string_bytes: 0,
            hyperlink_bytes: 0,
            ..Capacity::new(5, 2)
        };
        let layout = Page::layout(cap);
        assert_eq!(layout.grapheme_map.capacity, 0);
        assert_eq!(layout.hyperlink_map.capacity, 0);
    }

    #[test]
    fn hyperlink_map_capacity_uses_cell_multiplier_power_of_two() {
        assert_eq!(hyperlink_map_capacity(1), 16);
        assert_eq!(hyperlink_map_capacity(4), 64);
        assert_eq!(hyperlink_map_capacity(5), 128);
    }

    #[test]
    fn map_capacity_for_bytes_rounds_to_power_of_two() {
        assert_eq!(map_capacity_for_bytes(0, GRAPHEME_CHUNK), 0);
        assert_eq!(map_capacity_for_bytes(1, GRAPHEME_CHUNK), 1);
        assert_eq!(
            map_capacity_for_bytes(GRAPHEME_CHUNK * 3, GRAPHEME_CHUNK),
            4
        );
    }

    #[test]
    fn page_init_sets_size_to_full_capacity() {
        let page = Page::init(Capacity::new(12, 4));
        assert_eq!(page.size(), PageSize { cols: 12, rows: 4 });
        assert_eq!(page.capacity().cols, 12);
        assert_eq!(page.capacity().rows, 4);
    }

    #[test]
    fn page_init_initializes_each_row_cell_offset() {
        let page = Page::init(Capacity::new(6, 3));
        assert_eq!(
            page.row(0).cells().offset as usize,
            Page::layout(page.capacity()).cells_start
        );
        assert_eq!(
            page.row(1).cells().offset as usize,
            Page::layout(page.capacity()).cells_start + 6 * Cell::SIZE
        );
    }

    #[test]
    fn page_cells_are_zero_by_default() {
        let page = Page::init(Capacity::new(3, 2));
        for y in 0..2 {
            for x in 0..3 {
                assert_eq!(page.cell(y, x), Cell::default());
            }
        }
    }

    #[test]
    fn set_cell_writes_cell_and_marks_row_dirty() {
        let mut page = Page::init(Capacity::new(3, 1));
        page.set_cell(0, 1, Cell::new('A'));
        assert_eq!(page.cell(0, 1).codepoint(), 'A' as u32);
        assert!(page.is_dirty(0));
    }

    #[test]
    fn clear_dirty_resets_page_and_row_dirty_flags() {
        let mut page = Page::init(Capacity::new(3, 1));
        page.set_cell(0, 0, Cell::new('x'));
        page.dirty = true;
        page.clear_dirty();
        assert!(!page.is_dirty(0));
    }

    #[test]
    fn styled_cell_sets_row_styled_flag() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut cell = Cell::new('x');
        cell.set_style_id(1);
        page.set_cell(0, 0, cell);
        assert!(page.row(0).styled());
    }

    #[test]
    fn hyperlink_cell_sets_row_hyperlink_flag() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut cell = Cell::new('x');
        cell.set_hyperlink(true);
        page.set_cell(0, 0, cell);
        assert!(page.row(0).hyperlink());
    }

    #[test]
    fn grapheme_cell_sets_row_grapheme_flag() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut cell = Cell::new('x');
        cell.0 = (cell.0 & !Cell::CONTENT_TAG_MASK) | CellContentTag::CodepointGrapheme as u64;
        page.set_cell(0, 0, cell);
        assert!(page.row(0).grapheme());
    }

    #[test]
    fn clear_cells_zeros_range_and_recomputes_flags() {
        let mut page = Page::init(Capacity::new(4, 1));
        let mut cell = Cell::new('x');
        cell.set_style_id(1);
        page.set_cell(0, 1, cell);
        page.clear_cells(0, 1, 2);
        assert_eq!(page.cell(0, 1), Cell::default());
        assert!(!page.row(0).styled());
    }

    #[test]
    fn move_cells_moves_values_and_clears_source() {
        let mut page = Page::init(Capacity::new(5, 1));
        page.set_cell(0, 0, Cell::new('a'));
        page.set_cell(0, 1, Cell::new('b'));
        page.move_cells(0, 0, 0, 3, 2);
        assert_eq!(page.cell(0, 3).codepoint(), 'a' as u32);
        assert_eq!(page.cell(0, 4).codepoint(), 'b' as u32);
        assert!(page.cell(0, 0).is_empty());
    }

    #[test]
    fn clone_same_page_partial_row_copies_requested_range() {
        let mut page = Page::init(Capacity::new(4, 2));
        page.set_cell(0, 1, Cell::new('q'));
        page.clone_partial_row_from(CloneSource::SamePage, 1, 0, 1, 2);
        assert_eq!(page.cell(1, 1).codepoint(), 'q' as u32);
        assert!(page.cell(1, 0).is_empty());
    }

    #[test]
    fn clone_other_page_partial_row_copies_requested_range() {
        let mut src = Page::init(Capacity::new(4, 1));
        src.set_cell(0, 2, Cell::new('z'));
        let mut dst = Page::init(Capacity::new(4, 1));
        dst.clone_partial_row_from(CloneSource::Other(&src), 0, 0, 2, 3);
        assert_eq!(dst.cell(0, 2).codepoint(), 'z' as u32);
    }

    #[test]
    fn clone_full_width_row_preserves_wrap_flags() {
        let mut src = Page::init(Capacity::new(3, 1));
        let mut row = src.row(0);
        row.set_wrap(true);
        row.set_wrap_continuation(true);
        src.set_row(0, row);
        let mut dst = Page::init(Capacity::new(3, 1));
        dst.clone_partial_row_from(CloneSource::Other(&src), 0, 0, 0, 3);
        assert!(dst.row(0).wrap());
        assert!(dst.row(0).wrap_continuation());
    }

    #[test]
    fn exact_row_capacity_counts_styled_cells() {
        let mut page = Page::init(Capacity::new(3, 1));
        let mut cell = Cell::new('x');
        cell.set_style_id(9);
        page.set_cell(0, 0, cell);
        assert_eq!(
            page.exact_row_capacity(0).styles,
            StyleSet::capacity_for_count(1) as StyleCountInt
        );
    }

    #[test]
    fn exact_row_capacity_counts_hyperlink_cells_by_multiplier() {
        let mut page = Page::init(Capacity::new(20, 1));
        for x in 0..17 {
            let mut cell = Cell::new('x');
            cell.set_hyperlink(true);
            page.set_cell(0, x, cell);
        }
        let cap = page.exact_row_capacity(0);
        let item = ref_counted_set::item_byte_size::<crate::hyperlink::PageEntry>();
        assert_eq!(
            usize::from(cap.hyperlink_bytes),
            HyperlinkSet::capacity_for_count(2) * item
        );
    }

    #[test]
    fn exact_row_capacity_counts_grapheme_bytes() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut cell = Cell::new('x');
        cell.0 = (cell.0 & !Cell::CONTENT_TAG_MASK) | CellContentTag::CodepointGrapheme as u64;
        page.set_cell(0, 0, cell);
        assert_eq!(
            page.exact_row_capacity(0).grapheme_bytes as usize,
            GraphemeAlloc::bytes_required::<u32>(GRAPHEME_CHUNK_LEN)
        );
    }

    #[test]
    fn verify_integrity_accepts_fresh_page() {
        let page = Page::init(Capacity::new(4, 2));
        assert!(page.verify_integrity().is_ok());
    }

    #[test]
    fn verify_integrity_rejects_spacer_tail_at_column_zero() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut cell = Cell::new('x');
        cell.set_wide(CellWide::SpacerTail);
        page.set_cell(0, 0, cell);
        assert_eq!(
            page.verify_integrity(),
            Err(IntegrityError::SpacerTailAtColumnZero)
        );
    }

    #[test]
    fn verify_integrity_rejects_spacer_head_without_wrap() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut cell = Cell::new('x');
        cell.set_wide(CellWide::SpacerHead);
        page.set_cell(0, 1, cell);
        assert_eq!(
            page.verify_integrity(),
            Err(IntegrityError::InvalidSpacerHead)
        );
    }

    #[test]
    fn verify_integrity_accepts_spacer_head_at_wrapped_row_end() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut row = page.row(0);
        row.set_wrap(true);
        page.set_row(0, row);
        let mut cell = Cell::new('x');
        cell.set_wide(CellWide::SpacerHead);
        page.set_cell(0, 1, cell);
        assert!(page.verify_integrity().is_ok());
    }

    #[test]
    fn max_cols_returns_zero_for_tiny_sizes() {
        assert_eq!(Page::max_cols(PAGE_SIZE_MIN, 24), 0);
        assert_eq!(Page::max_cols(PAGE_SIZE_MIN * 2, 0), 0);
    }

    #[test]
    fn max_cols_scales_with_available_grid_bytes() {
        let cols = Page::max_cols(PAGE_SIZE_MIN * 3, 10);
        assert!(cols > 0);
    }

    #[test]
    fn adjust_sets_requested_columns() {
        let adjusted = Page::adjust(Capacity::new(80, 24), 120);
        assert_eq!(adjusted.cols, 120);
    }

    #[test]
    fn reinit_clears_cells_and_dirty_flags() {
        let mut page = Page::init(Capacity::new(3, 1));
        page.set_cell(0, 0, Cell::new('x'));
        page.reinit();
        assert_eq!(page.cell(0, 0), Cell::default());
        assert!(!page.is_dirty(0));
    }

    #[test]
    fn page_clone_copies_flat_buffer_offsets() {
        let mut page = Page::init(Capacity::new(3, 1));
        page.set_cell(0, 2, Cell::new('c'));
        let cloned = page.clone();
        assert_eq!(cloned.cell(0, 2), page.cell(0, 2));
        assert_eq!(cloned.row(0).cells().offset, page.row(0).cells().offset);
    }

    #[test]
    fn init_buf_uses_supplied_layout_size() {
        let layout = Page::layout(Capacity::new(3, 2));
        let memory = vec![0; layout.total_size];
        let page = Page::init_buf(memory, layout);
        assert_eq!(page.memory.len(), layout.total_size);
    }

    #[test]
    fn clear_cells_clamps_to_page_width() {
        let mut page = Page::init(Capacity::new(2, 1));
        page.set_cell(0, 1, Cell::new('x'));
        page.clear_cells(0, 1, 10);
        assert!(page.cell(0, 1).is_empty());
    }

    #[test]
    fn cell_buf_value_round_trips_in_page_memory() {
        let mut page = Page::init(Capacity::new(1, 1));
        let mut cell = Cell::new('R');
        cell.set_style_id(3);
        page.set_cell(0, 0, cell);
        assert_eq!(page.cell(0, 0), cell);
    }

    #[test]
    fn row_buf_value_round_trips_in_page_memory() {
        let mut page = Page::init(Capacity::new(1, 1));
        let mut row = page.row(0);
        row.set_semantic_prompt(SemanticPrompt::Prompt);
        page.set_row(0, row);
        assert_eq!(page.row(0).semantic_prompt(), SemanticPrompt::Prompt);
    }

    #[test]
    fn ghostty_layout_maxed_capacity_remains_page_aligned() {
        // ghostty: "layout maxed capacity" (page.zig:2225)
        let layout = Page::layout(STD_CAPACITY);
        assert_eq!(layout.total_size % PAGE_SIZE_MIN, 0);
    }

    #[test]
    fn ghostty_cell_zero_default_is_empty() {
        // ghostty: "Cell zero default" (page.zig:2240)
        assert_eq!(Cell::default(), Cell(0));
    }

    #[test]
    fn ghostty_capacity_adjust_cols_down() {
        // ghostty: "Page capacity adjust cols down" (page.zig:2250)
        let original = STD_CAPACITY;
        let adjusted = Page::try_adjust(original, original.cols / 2).unwrap();
        assert_adjusted_capacity_fills_page(original, adjusted);
    }

    #[test]
    fn ghostty_capacity_adjust_cols_down_to_one() {
        // ghostty: "Page capacity adjust cols down to 1" (page.zig:2264)
        let original = STD_CAPACITY;
        let adjusted = Page::try_adjust(original, 1).unwrap();
        assert_adjusted_capacity_fills_page(original, adjusted);
    }

    #[test]
    fn ghostty_capacity_adjust_cols_up() {
        // ghostty: "Page capacity adjust cols up" (page.zig:2278)
        let original = STD_CAPACITY;
        let adjusted = Page::try_adjust(original, original.cols * 2).unwrap();
        assert_adjusted_capacity_fills_page(original, adjusted);
    }

    #[test]
    fn ghostty_capacity_adjust_cols_sweep() {
        // ghostty: "Page capacity adjust cols sweep" (page.zig:2292)
        let original = STD_CAPACITY;
        let original_size = Page::layout(original).total_size;
        let mut cap = original;
        for cols in 1..(original.cols * 2) {
            cap = Page::try_adjust(cap, cols).unwrap();
            assert_eq!(Page::layout(cap).total_size, original_size);
            let bigger = Capacity {
                rows: cap.rows + 1,
                ..cap
            };
            assert!(Page::layout(bigger).total_size > original_size);
        }
    }

    #[test]
    fn ghostty_capacity_adjust_cols_too_high() {
        // ghostty: "Page capacity adjust cols too high" (page.zig:2309)
        assert!(Page::try_adjust(STD_CAPACITY, CellCountInt::MAX).is_none());
    }

    #[test]
    fn ghostty_capacity_max_cols_basic() {
        // ghostty: "Capacity maxCols basic" (page.zig:2317)
        let max = Page::max_cols_for_capacity(STD_CAPACITY).unwrap();
        assert!(max >= STD_CAPACITY.cols);
        let adjusted = Page::try_adjust(STD_CAPACITY, max).unwrap();
        assert!(adjusted.rows >= 1);
        assert!(Page::try_adjust(STD_CAPACITY, max + 1).is_none());
    }

    #[test]
    fn ghostty_capacity_max_cols_preserves_total_size() {
        // ghostty: "Capacity maxCols preserves total size" (page.zig:2335)
        let max = Page::max_cols_for_capacity(STD_CAPACITY).unwrap();
        let adjusted = Page::try_adjust(STD_CAPACITY, max).unwrap();
        assert_eq!(
            Page::layout(adjusted).total_size,
            Page::layout(STD_CAPACITY).total_size
        );
    }

    #[test]
    fn ghostty_capacity_max_cols_with_one_row_exactly() {
        // ghostty: "Capacity maxCols with 1 row exactly" (page.zig:2344)
        let max = Page::max_cols_for_capacity(STD_CAPACITY).unwrap();
        let adjusted = Page::try_adjust(STD_CAPACITY, max).unwrap();
        assert_eq!(adjusted.rows, 1);
    }

    #[test]
    fn ghostty_init_sets_all_rows_readable() {
        // ghostty: "init" (page.zig:2351)
        let page = Page::init(Capacity::new(4, 3));
        assert_eq!(
            page.row(2).cells().offset,
            page.row(0).cells().offset + 8 * Cell::SIZE as u32
        );
    }

    #[test]
    fn ghostty_read_write_cell_by_index() {
        // ghostty: "read/write" (page.zig:2360)
        let mut page = Page::init(Capacity::new(2, 1));
        page.set_cell(0, 1, Cell::new('W'));
        assert_eq!(page.cell(0, 1).codepoint(), 'W' as u32);
    }

    #[test]
    fn ghostty_append_grapheme_marks_cell_and_row() {
        // ghostty: "appendGrapheme first" (page.zig:2383)
        let mut page = Page::init(Capacity::new(2, 1));
        page.set_cell(0, 0, Cell::new('a'));
        page.append_grapheme(0, 0, '́' as u32).unwrap();
        assert!(page.cell(0, 0).has_grapheme() && page.row(0).grapheme());
    }

    #[test]
    fn ghostty_append_grapheme_grows_existing_sequence() {
        // ghostty: "appendGrapheme grow" (page.zig:2413)
        let mut page = Page::init(Capacity::new(2, 1));
        page.set_cell(0, 0, Cell::new('a'));
        page.append_grapheme(0, 0, 0x0301).unwrap();
        page.append_grapheme(0, 0, 0x0308).unwrap();
        assert_eq!(page.grapheme(0, 0), Some(vec![0x0301, 0x0308]));
    }

    #[test]
    fn ghostty_clear_grapheme_releases_map_entry() {
        // ghostty: "clearGrapheme" (page.zig:2436)
        let mut page = Page::init(Capacity::new(2, 1));
        page.set_cell(0, 0, Cell::new('a'));
        page.append_grapheme(0, 0, 0x0301).unwrap();
        page.clear_grapheme(0, 0);
        assert_eq!(page.grapheme_count(), 0);
    }

    #[test]
    fn ghostty_clone_copies_cells_independently() {
        // ghostty: "clone independence" (page.zig:2460)
        let mut page = Page::init(Capacity::new(2, 1));
        page.set_cell(0, 0, Cell::new('a'));
        let mut cloned = page.clone();
        cloned.set_cell(0, 0, Cell::new('b'));
        assert_eq!(page.cell(0, 0).codepoint(), 'a' as u32);
    }

    #[test]
    fn ghostty_clone_keeps_graphemes_independent() {
        // ghostty: "clone graphemes" (page.zig:2510)
        let mut page = Page::init(Capacity::new(2, 1));
        page.set_cell(0, 0, Cell::new('a'));
        page.append_grapheme(0, 0, 0x0301).unwrap();
        let mut cloned = page.clone();
        cloned.clear_grapheme(0, 0);
        assert_eq!(page.grapheme(0, 0), Some(vec![0x0301]));
    }

    #[test]
    fn ghostty_clone_keeps_styles_independent() {
        // ghostty: "clone styles" (page.zig:2537)
        let mut page = Page::init(Capacity::new(2, 1));
        page.set_style(0, 0, PackedStyle(7)).unwrap();
        let mut cloned = page.clone();
        cloned.clear_cells(0, 0, 1);
        assert_eq!(page.style_count(), 1);
    }

    #[test]
    fn ghostty_clone_from_copies_full_page_independently() {
        // ghostty: "Page cloneFrom" (page.zig:2588)
        let mut src = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for y in 0..src.capacity.rows {
            src.set_cell(
                y,
                1,
                Cell::new(char::from_u32(u32::from(y)).unwrap_or('\0')),
            );
        }

        let mut dst = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        clone_rows(&mut dst, &src, 0, src.size.rows);

        for y in 0..dst.capacity.rows {
            assert_eq!(dst.cell(y, 1).codepoint(), u32::from(y));
        }

        for y in 0..src.capacity.rows {
            src.set_cell(y, 1, Cell::new('\0'));
        }

        for y in 0..dst.capacity.rows {
            assert_eq!(dst.cell(y, 1).codepoint(), u32::from(y));
        }
        for y in 0..src.capacity.rows {
            assert_eq!(src.cell(y, 1).codepoint(), 0);
        }
    }

    #[test]
    fn ghostty_clone_from_shrink_columns_copies_intersection() {
        // ghostty: "Page cloneFrom shrink columns" (page.zig:2642)
        let mut src = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for y in 0..src.capacity.rows {
            src.set_cell(
                y,
                1,
                Cell::new(char::from_u32(u32::from(y)).unwrap_or('\0')),
            );
        }

        let mut dst = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(5, 10)
        });
        clone_rows(&mut dst, &src, 0, src.size.rows);
        assert_eq!(dst.size.cols, 5);
        for y in 0..dst.capacity.rows {
            assert_eq!(dst.cell(y, 1).codepoint(), u32::from(y));
        }
    }

    #[test]
    fn ghostty_clone_from_partial_copies_only_requested_rows() {
        // ghostty: "Page cloneFrom partial" (page.zig:2676)
        let mut src = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for y in 0..src.capacity.rows {
            src.set_cell(
                y,
                1,
                Cell::new(char::from_u32(u32::from(y)).unwrap_or('\0')),
            );
        }

        let mut dst = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        clone_rows(&mut dst, &src, 0, 5);
        for y in 0..5 {
            assert_eq!(dst.cell(y, 1).codepoint(), u32::from(y));
        }
        for y in 5..dst.size.rows {
            assert_eq!(dst.cell(y, 1).codepoint(), 0);
        }
    }

    #[test]
    fn ghostty_clone_from_hyperlinks_exact_capacity() {
        // ghostty: "Page cloneFrom hyperlinks exact capacity" (page.zig:2713)
        let mut src = Page::init(Capacity::new(50, 50));
        assert!(
            src.hyperlink_capacity() <= usize::from(src.size.cols) * usize::from(src.size.rows)
        );
        let id = src
            .insert_hyperlink_implicit(0, b"https://example.com")
            .unwrap();
        'fill: for x in 0..src.size.cols {
            for y in 0..src.size.rows {
                src.set_cell(y, x, Cell::new('*'));
                src.set_hyperlink_id(y, x, id).unwrap();
                if src.hyperlink_count() == src.hyperlink_capacity() {
                    break 'fill;
                }
            }
        }
        assert_eq!(src.hyperlink_count(), src.hyperlink_capacity());

        let mut dst = Page::init(src.capacity);
        clone_rows(&mut dst, &src, 0, src.size.rows);
        assert_eq!(dst.hyperlink_count(), src.hyperlink_count());
    }

    #[test]
    fn ghostty_clone_from_copies_graphemes_independently() {
        // ghostty: "Page cloneFrom graphemes" (page.zig:2757)
        let mut src = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for y in 0..src.capacity.rows {
            src.set_cell(y, 1, Cell::new(char::from_u32(u32::from(y + 1)).unwrap()));
            src.append_grapheme(y, 1, 0x0A).unwrap();
        }

        let mut dst = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        clone_rows(&mut dst, &src, 0, src.size.rows);
        for y in 0..dst.capacity.rows {
            assert_eq!(dst.cell(y, 1).codepoint(), u32::from(y + 1));
            assert!(dst.row(y).grapheme());
            assert!(dst.cell(y, 1).has_grapheme());
            assert_eq!(dst.grapheme(y, 1), Some(vec![0x0A]));
        }

        for y in 0..src.capacity.rows {
            src.clear_grapheme(y, 1);
            src.set_cell(y, 1, Cell::new('\0'));
        }
        for y in 0..dst.capacity.rows {
            assert_eq!(dst.cell(y, 1).codepoint(), u32::from(y + 1));
            assert_eq!(dst.grapheme(y, 1), Some(vec![0x0A]));
        }
        for y in 0..src.capacity.rows {
            assert_eq!(src.cell(y, 1).codepoint(), 0);
        }
    }

    #[test]
    fn ghostty_clone_from_frees_dst_graphemes() {
        // ghostty: "Page cloneFrom frees dst graphemes" (page.zig:2820)
        let mut src = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        let mut dst = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for y in 0..src.capacity.rows {
            src.set_cell(y, 1, Cell::new(char::from_u32(u32::from(y + 1)).unwrap()));
            dst.set_cell(y, 1, Cell::new(char::from_u32(u32::from(y + 1)).unwrap()));
            dst.append_grapheme(y, 1, 0x0A).unwrap();
        }
        clone_rows(&mut dst, &src, 0, src.size.rows);
        for y in 0..dst.capacity.rows {
            assert_eq!(dst.cell(y, 1).codepoint(), u32::from(y + 1));
            assert!(!dst.row(y).grapheme());
            assert!(!dst.cell(y, 1).has_grapheme());
        }
        assert_eq!(dst.grapheme_count(), 0);
    }

    #[test]
    fn ghostty_clone_row_from_partial_keeps_neighbors() {
        // ghostty: "Page cloneRowFrom partial" (page.zig:2864)
        let mut src = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        let mut dst = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for x in 0..src.size.cols {
            src.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
        }
        dst.clone_partial_row_from(CloneSource::Other(&src), 0, 0, 2, 8);
        for x in 0..dst.size.cols {
            let expected = if (2..8).contains(&x) {
                u32::from(x + 1)
            } else {
                0
            };
            assert_eq!(dst.cell(0, x).codepoint(), expected);
        }
    }

    #[test]
    fn ghostty_partial_clone_omits_src_grapheme_outside_range() {
        // ghostty: "Page cloneRowFrom partial grapheme in non-copied source region" (page.zig:2910)
        let mut src = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        let mut dst = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for x in 0..src.size.cols {
            src.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
        }
        src.append_grapheme(0, 0, 0x0A).unwrap();
        src.append_grapheme(0, 9, 0x0A).unwrap();
        assert_eq!(src.grapheme_count(), 2);
        dst.clone_partial_row_from(CloneSource::Other(&src), 0, 0, 2, 8);
        for x in 0..dst.size.cols {
            let expected = if (2..8).contains(&x) {
                u32::from(x + 1)
            } else {
                0
            };
            assert_eq!(dst.cell(0, x).codepoint(), expected);
            assert!(!dst.cell(0, x).has_grapheme());
        }
        assert!(!dst.row(0).grapheme());
        assert_eq!(dst.grapheme_count(), 0);
    }

    #[test]
    fn ghostty_partial_clone_frees_dst_grapheme_in_range() {
        // ghostty: "Page cloneRowFrom partial grapheme in non-copied dest region" (page.zig:2971)
        let mut src = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        let mut dst = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for x in 0..src.size.cols {
            src.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
            dst.set_cell(0, x, Cell::new(char::from_u32(0xBB).unwrap()));
        }
        dst.append_grapheme(0, 0, 0x0A).unwrap();
        dst.append_grapheme(0, 9, 0x0A).unwrap();
        dst.clone_partial_row_from(CloneSource::Other(&src), 0, 0, 2, 8);
        for x in 0..dst.size.cols {
            let expected = if (2..8).contains(&x) {
                u32::from(x + 1)
            } else {
                0xBB
            };
            assert_eq!(dst.cell(0, x).codepoint(), expected);
        }
        assert!(dst.row(0).grapheme());
        assert_eq!(dst.grapheme(0, 0), Some(vec![0x0A]));
        assert_eq!(dst.grapheme(0, 9), Some(vec![0x0A]));
        assert_eq!(dst.grapheme_count(), 2);
    }

    #[test]
    fn ghostty_partial_clone_same_page_copies_hyperlink_cell() {
        // ghostty: "Page cloneRowFrom partial hyperlink in same page copy" (page.zig:3041)
        let mut page = Page::init(Capacity::new(10, 10));
        let id = page
            .insert_hyperlink_implicit(0, b"https://example.com")
            .unwrap();
        for x in 0..page.size.cols {
            page.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
        }
        page.set_hyperlink_id(0, 7, id).unwrap();
        assert_eq!(page.hyperlink_count(), 1);
        page.clone_partial_row_from(CloneSource::SamePage, 1, 0, 2, 8);
        for x in 0..page.size.cols {
            let expected = if (2..8).contains(&x) {
                u32::from(x + 1)
            } else {
                0
            };
            assert_eq!(page.cell(1, x).codepoint(), expected);
        }
        assert!(page.row(1).hyperlink());
        assert!(page.cell(1, 7).hyperlink());
        assert_eq!(page.hyperlink_count(), 2);
    }

    #[test]
    fn ghostty_partial_clone_same_page_omit_keeps_hyperlink_count() {
        // ghostty: "Page cloneRowFrom partial hyperlink in same page omit" (page.zig:3097)
        let mut page = Page::init(Capacity::new(10, 10));
        let id = page
            .insert_hyperlink_implicit(0, b"https://example.com")
            .unwrap();
        for x in 0..page.size.cols {
            page.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
        }
        page.set_hyperlink_id(0, 7, id).unwrap();
        assert_eq!(page.hyperlink_count(), 1);
        page.clone_partial_row_from(CloneSource::SamePage, 1, 0, 2, 6);
        for x in 0..page.size.cols {
            let expected = if (2..6).contains(&x) {
                u32::from(x + 1)
            } else {
                0
            };
            assert_eq!(page.cell(1, x).codepoint(), expected);
        }
        assert!(!page.row(1).hyperlink());
        assert!(!page.cell(1, 7).hyperlink());
        assert_eq!(page.hyperlink_count(), 1);
    }

    #[test]
    fn ghostty_move_cells_text_only_cross_row() {
        // ghostty: "Page moveCells text-only" (page.zig:3153)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for x in 0..page.capacity.cols {
            page.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
        }
        page.move_cells(0, 0, 1, 0, page.capacity.cols);
        for x in 0..page.capacity.cols {
            assert_eq!(page.cell(1, x).codepoint(), u32::from(x + 1));
            assert_eq!(page.cell(0, x).codepoint(), 0);
        }
    }

    #[test]
    fn ghostty_move_cells_graphemes_keep_count() {
        // ghostty: "Page moveCells graphemes" (page.zig:3193)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for x in 0..page.size.cols {
            page.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
            page.append_grapheme(0, x, 0x0A).unwrap();
        }
        let original_count = page.grapheme_count();
        page.move_cells(0, 0, 1, 0, page.size.cols);
        assert_eq!(page.grapheme_count(), original_count);
        for x in 0..page.size.cols {
            assert_eq!(page.cell(1, x).codepoint(), u32::from(x + 1));
            assert_eq!(page.grapheme(1, x), Some(vec![0x0A]));
            assert_eq!(page.cell(0, x).codepoint(), 0);
        }
    }

    #[test]
    fn ghostty_verify_integrity_graphemes_good() {
        // ghostty: "verifyIntegrity graphemes good" (page.zig:3241)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for x in 0..page.size.cols {
            page.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
            page.append_grapheme(0, x, 0x0A).unwrap();
        }
        assert!(page.verify_integrity().is_ok());
    }

    #[test]
    fn ghostty_verify_integrity_unmarked_grapheme_row_errors() {
        // ghostty: "verifyIntegrity grapheme row not marked" (page.zig:3266)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        for x in 0..page.size.cols {
            page.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
            page.append_grapheme(0, x, 0x0A).unwrap();
        }
        let mut row = page.row(0);
        row.set_grapheme(false);
        page.set_row(0, row);
        assert_eq!(
            page.verify_integrity(),
            Err(IntegrityError::UnmarkedGraphemeRow)
        );
    }

    #[test]
    fn ghostty_verify_integrity_styles_good() {
        // ghostty: "verifyIntegrity styles good" (page.zig:3297)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        let id = page.add_style(PackedStyle(11)).unwrap();
        for x in 0..page.size.cols {
            page.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
            page.use_style(id);
            page.set_style_id_raw(0, x, id);
        }
        page.release_style(id);
        assert!(page.verify_integrity().is_ok());
    }

    #[test]
    fn ghostty_verify_integrity_style_ref_mismatch_errors() {
        // ghostty: "verifyIntegrity styles ref count mismatch" (page.zig:3333)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        let id = page.add_style(PackedStyle(11)).unwrap();
        for x in 0..page.size.cols {
            page.set_cell(0, x, Cell::new(char::from_u32(u32::from(x + 1)).unwrap()));
            page.use_style(id);
            page.set_style_id_raw(0, x, id);
        }
        page.release_style(id);
        page.release_style(id);
        assert_eq!(
            page.verify_integrity(),
            Err(IntegrityError::MismatchedStyleRef)
        );
    }

    #[test]
    fn ghostty_verify_integrity_zero_rows_errors() {
        // ghostty: "verifyIntegrity zero rows" (page.zig:3375)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        page.size.rows = 0;
        assert_eq!(page.verify_integrity(), Err(IntegrityError::ZeroRowCount));
    }

    #[test]
    fn ghostty_verify_integrity_zero_cols_errors() {
        // ghostty: "verifyIntegrity zero cols" (page.zig:3393)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        page.size.cols = 0;
        assert_eq!(page.verify_integrity(), Err(IntegrityError::ZeroColCount));
    }

    #[test]
    fn ghostty_exact_row_capacity_empty_rows() {
        // ghostty: "Page exactRowCapacity empty rows" (page.zig:3411)
        let page = Page::init(Capacity {
            styles: 8,
            hyperlink_bytes: (32 * ref_counted_set::item_byte_size::<PageEntry>()) as u16,
            string_bytes: 512,
            ..Capacity::new(10, 10)
        });
        let cap = page.exact_row_capacity_range(0, 5);
        assert_eq!(cap.cols, 10);
        assert_eq!(cap.rows, 5);
        assert_eq!(cap.styles, 0);
        assert_eq!(cap.grapheme_bytes, 0);
        assert_eq!(cap.hyperlink_bytes, 0);
        assert_eq!(cap.string_bytes, 0);
    }

    #[test]
    fn ghostty_exact_row_capacity_styles_progression() {
        // ghostty: "Page exactRowCapacity styles" (page.zig:3431)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        assert_eq!(page.exact_row_capacity_range(0, 5).styles, 0);

        let style1 = page.add_style(PackedStyle(1)).unwrap();
        page.set_style_id_raw(0, 0, style1);
        let cap_one = page.exact_row_capacity_range(0, 5);
        assert_eq!(
            cap_one.styles,
            StyleSet::capacity_for_count(1) as StyleCountInt
        );

        page.set_style_id_raw(0, 1, style1);
        assert_eq!(page.exact_row_capacity_range(0, 5).styles, cap_one.styles);

        let style2 = page.add_style(PackedStyle(2)).unwrap();
        page.set_style_id_raw(0, 2, style2);
        let cap_two = page.exact_row_capacity_range(0, 5);
        assert_eq!(
            cap_two.styles,
            StyleSet::capacity_for_count(2) as StyleCountInt
        );
        assert!(cap_two.styles > cap_one.styles);

        let style3 = page.add_style(PackedStyle(3)).unwrap();
        page.set_style_id_raw(7, 0, style3);
        assert_eq!(page.exact_row_capacity_range(0, 5).styles, cap_two.styles);
        assert_eq!(
            page.exact_row_capacity_range(0, 10).styles,
            StyleSet::capacity_for_count(3) as StyleCountInt
        );

        let cap = page.exact_row_capacity_range(0, 5);
        let mut cloned = Page::init(cap);
        clone_rows(&mut cloned, &page, 0, 5);
        assert_eq!(cloned.exact_row_capacity_range(0, 5), cap);
    }

    #[test]
    fn ghostty_exact_row_capacity_single_style_clone_round_trip() {
        // ghostty: "Page exactRowCapacity single style clone" (page.zig:3515)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 2)
        });
        page.set_style(0, 0, PackedStyle(5)).unwrap();
        let cap = page.exact_row_capacity(0);
        assert_eq!(cap.styles, StyleSet::capacity_for_count(1) as StyleCountInt);
        let mut dst = Page::init(cap);
        dst.clone_partial_row_from(CloneSource::Other(&page), 0, 0, 0, page.size.cols);
        assert_eq!(dst.style_for_cell(0, 0), Some(PackedStyle(5)));
    }

    #[test]
    fn ghostty_exact_row_capacity_styles_max_single_row() {
        // ghostty: "Page exactRowCapacity styles max single row" (page.zig:3552)
        let mut page = Page::init(Capacity {
            styles: StyleCountInt::MAX,
            ..Capacity::new(CellCountInt::MAX, 1)
        });
        let mut count = 0usize;
        for x in 0..page.size.cols {
            if count >= 1000 {
                break;
            }
            let style = PackedStyle(u128::from(x) + 1);
            if page.set_style(0, x, style).is_err() {
                break;
            }
            count += 1;
        }
        assert!(count > 0);
        assert_eq!(
            page.exact_row_capacity(0).styles,
            StyleSet::capacity_for_count(count) as StyleCountInt
        );
    }

    #[test]
    fn ghostty_exact_row_capacity_grapheme_bytes() {
        // ghostty: "Page exactRowCapacity grapheme_bytes" (page.zig:3590)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        assert_eq!(page.exact_row_capacity_range(0, 5).grapheme_bytes, 0);

        page.set_cell(0, 0, Cell::new('a'));
        page.append_grapheme(0, 0, 0x0301).unwrap();
        assert_eq!(
            page.exact_row_capacity_range(0, 5).grapheme_bytes as usize,
            GRAPHEME_CHUNK
        );

        page.set_cell(0, 1, Cell::new('e'));
        page.append_grapheme(0, 1, 0x0300).unwrap();
        assert_eq!(
            page.exact_row_capacity_range(0, 5).grapheme_bytes as usize,
            GRAPHEME_CHUNK * 2
        );

        page.set_cell(0, 2, Cell::new('o'));
        page.append_grapheme(0, 2, 0x0301).unwrap();
        page.append_grapheme(0, 2, 0x0302).unwrap();
        page.append_grapheme(0, 2, 0x0303).unwrap();
        assert_eq!(
            page.exact_row_capacity_range(0, 5).grapheme_bytes as usize,
            GRAPHEME_CHUNK * 3
        );

        page.set_cell(7, 0, Cell::new('x'));
        page.append_grapheme(7, 0, 0x0304).unwrap();
        assert_eq!(
            page.exact_row_capacity_range(0, 5).grapheme_bytes as usize,
            GRAPHEME_CHUNK * 3
        );
        assert_eq!(
            page.exact_row_capacity_range(0, 10).grapheme_bytes as usize,
            GRAPHEME_CHUNK * 4
        );

        let cap = page.exact_row_capacity_range(0, 5);
        let mut cloned = Page::init(cap);
        clone_rows(&mut cloned, &page, 0, 5);
        assert_eq!(cloned.exact_row_capacity_range(0, 5), cap);
    }

    #[test]
    fn ghostty_exact_row_capacity_grapheme_bytes_larger_than_chunk() {
        // ghostty: "Page exactRowCapacity grapheme_bytes larger than chunk" (page.zig:3675)
        let mut page = Page::init(Capacity {
            styles: 8,
            ..Capacity::new(10, 10)
        });
        page.set_cell(0, 0, Cell::new('a'));
        for codepoint in 0..6 {
            page.append_grapheme(0, 0, 0x0300 + codepoint).unwrap();
        }
        let cap = page.exact_row_capacity(0);
        assert_eq!(cap.grapheme_bytes as usize, 32);
        let mut cloned = Page::init(cap);
        cloned.clone_partial_row_from(CloneSource::Other(&page), 0, 0, 0, page.size.cols);
        assert_eq!(cloned.exact_row_capacity(0), cap);
    }

    #[test]
    fn ghostty_exact_row_capacity_hyperlinks_count_cells() {
        // ghostty: "Page exactRowCapacity hyperlinks" (page.zig:3706)
        let item = ref_counted_set::item_byte_size::<crate::hyperlink::PageEntry>();
        let mut page = Page::init(Capacity {
            styles: 8,
            hyperlink_bytes: (32 * item) as u16,
            string_bytes: 512,
            ..Capacity::new(10, 10)
        });
        assert_eq!(page.exact_row_capacity_range(0, 5).hyperlink_bytes, 0);
        assert_eq!(page.exact_row_capacity_range(0, 5).string_bytes, 0);

        let id1 = page
            .insert_hyperlink_implicit(1, b"https://example.com")
            .unwrap();
        page.set_cell(0, 0, Cell::new('h'));
        page.set_hyperlink_id(0, 0, id1).unwrap();
        let cap_one = page.exact_row_capacity_range(0, 5);
        assert_eq!(
            cap_one.hyperlink_bytes as usize,
            HyperlinkSet::capacity_for_count(1) * item
        );
        assert_eq!(cap_one.string_bytes as usize, STRING_CHUNK);

        page.set_cell(0, 1, Cell::new('h'));
        page.set_hyperlink_id(0, 1, id1).unwrap();
        assert_eq!(page.exact_row_capacity_range(0, 5), cap_one);

        let id2 = page
            .insert_hyperlink_explicit(b"my-link-id", b"https://other.example.org/path")
            .unwrap();
        page.set_cell(0, 2, Cell::new('h'));
        page.set_hyperlink_id(0, 2, id2).unwrap();
        let cap_two = page.exact_row_capacity_range(0, 5);
        assert_eq!(
            cap_two.hyperlink_bytes as usize,
            HyperlinkSet::capacity_for_count(2) * item
        );
        assert_eq!(cap_two.string_bytes as usize, STRING_CHUNK * 3);

        let outside = page
            .insert_hyperlink_implicit(99, b"https://outside.example.com")
            .unwrap();
        page.set_cell(7, 0, Cell::new('h'));
        page.set_hyperlink_id(7, 0, outside).unwrap();
        assert_eq!(page.exact_row_capacity_range(0, 5), cap_two);
        let full = page.exact_row_capacity_range(0, 10);
        assert_eq!(
            full.hyperlink_bytes as usize,
            HyperlinkSet::capacity_for_count(3) * item
        );
        assert_eq!(full.string_bytes as usize, STRING_CHUNK * 4);

        let cap = page.exact_row_capacity_range(0, 5);
        let mut cloned = Page::init(cap);
        clone_rows(&mut cloned, &page, 0, 5);
        assert_eq!(cloned.exact_row_capacity_range(0, 5), cap);
    }

    #[test]
    fn ghostty_exact_row_capacity_single_hyperlink_clone_round_trip() {
        // ghostty: "Page exactRowCapacity single hyperlink clone" (page.zig:3817)
        let mut page = Page::init(Capacity {
            styles: 8,
            hyperlink_bytes: (32 * ref_counted_set::item_byte_size::<PageEntry>()) as u16,
            string_bytes: 512,
            ..Capacity::new(10, 2)
        });
        page.set_cell(0, 0, Cell::new('h'));
        let id = page
            .insert_hyperlink_implicit(7, b"https://example.com")
            .unwrap();
        page.set_hyperlink_id(0, 0, id).unwrap();
        let cap = page.exact_row_capacity(0);
        let item = ref_counted_set::item_byte_size::<PageEntry>();
        assert_eq!(
            cap.hyperlink_bytes as usize,
            HyperlinkSet::capacity_for_count(1) * item
        );
        let mut dst = Page::init(cap);
        dst.clone_partial_row_from(CloneSource::Other(&page), 0, 0, 0, page.size.cols);
        assert_eq!(dst.hyperlink_count(), 1);
        assert!(dst.cell(0, 0).hyperlink());
    }

    #[test]
    fn ghostty_exact_row_capacity_many_hyperlink_cells_map_capacity() {
        // ghostty: "Page exactRowCapacity hyperlink map capacity for many cells" (page.zig:3861)
        let item = ref_counted_set::item_byte_size::<crate::hyperlink::PageEntry>();
        let cols = 50;
        let mut page = Page::init(Capacity {
            styles: 8,
            hyperlink_bytes: (32 * item) as u16,
            string_bytes: 512,
            ..Capacity::new(cols, 2)
        });
        let id = page
            .insert_hyperlink_implicit(1, b"https://example.com")
            .unwrap();
        for x in 0..cols {
            page.set_cell(0, x, Cell::new('h'));
            page.set_hyperlink_id(0, x, id).unwrap();
        }
        let cap = page.exact_row_capacity(0);
        let min_map_items = cols.div_ceil(HYPERLINK_CELL_MULTIPLIER as u16) as usize;
        assert!(cap.hyperlink_bytes as usize >= min_map_items * item);
        let mut dst = Page::init(cap);
        dst.clone_partial_row_from(CloneSource::Other(&page), 0, 0, 0, page.size.cols);
        for x in 0..cols {
            assert!(dst.cell(0, x).hyperlink());
        }
    }

    fn clone_rows(dst: &mut Page, src: &Page, start: CellCountInt, rows: CellCountInt) {
        for y in start..start + rows {
            dst.clone_partial_row_from(CloneSource::Other(src), y, y, 0, src.size.cols);
        }
    }
}
