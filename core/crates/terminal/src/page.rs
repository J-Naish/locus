//! Terminal page storage.
//!
//! This is a safe Rust port of Ghostty's single-buffer page substrate. The
//! Row/Cell bit layouts are pinned because these values are copied in flat page
//! buffers and later phases depend on their exact representation.

#![allow(dead_code, unused_imports)]

use crate::bitmap_allocator::{BitmapAllocator, OutOfMemory};
use crate::color::Rgb;
use crate::hash_map::{AutoOffsetHashMap, OffsetHashMap};
use crate::hyperlink::{HyperlinkMap, HyperlinkSet};
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

    pub fn size(&self) -> PageSize {
        self.size
    }

    pub fn capacity(&self) -> Capacity {
        self.capacity
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
            self.set_cell(y, x, Cell::default());
        }
        self.update_row_flags(y);
    }

    pub fn move_cells(
        &mut self,
        y: CellCountInt,
        dst_start: CellCountInt,
        src_start: CellCountInt,
        len: CellCountInt,
    ) {
        if len == 0 || dst_start == src_start {
            return;
        }
        let mut cells = Vec::with_capacity(len as usize);
        for x in src_start..src_start.saturating_add(len).min(self.size.cols) {
            cells.push(self.cell(y, x));
        }
        self.clear_cells(y, dst_start, dst_start.saturating_add(len));
        for (index, cell) in cells.into_iter().enumerate() {
            self.row(y)
                .cells()
                .set(&mut self.memory, dst_start as usize + index, cell);
        }
        for x in src_start..src_start.saturating_add(len).min(self.size.cols) {
            self.row(y)
                .cells()
                .set(&mut self.memory, x as usize, Cell::default());
        }
        let mut row = self.row(y);
        row.set_dirty(true);
        self.set_row(y, row);
        self.update_row_flags(y);
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
            self.set_cell(dst_y, x, source_page.cell(src_y, x));
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

    pub fn exact_row_capacity(&self, y: CellCountInt) -> Capacity {
        let mut styled = 0usize;
        let mut hyperlink_cells = 0usize;
        let mut grapheme_bytes = 0usize;
        for x in 0..self.size.cols {
            let cell = self.cell(y, x);
            if cell.has_styling() {
                styled += 1;
            }
            if cell.hyperlink() {
                hyperlink_cells += 1;
            }
            if cell.has_grapheme() {
                grapheme_bytes += GraphemeAlloc::bytes_required::<u32>(GRAPHEME_CHUNK_LEN);
            }
        }
        let hyperlink_count = hyperlink_cells.div_ceil(HYPERLINK_CELL_MULTIPLIER);
        Capacity {
            cols: self.size.cols,
            rows: 1,
            styles: styled.max(1) as StyleCountInt,
            hyperlink_bytes: (hyperlink_count
                * ref_counted_set::item_byte_size::<crate::hyperlink::PageEntry>())
                as u16,
            grapheme_bytes: grapheme_bytes as GraphemeBytesInt,
            string_bytes: 0,
        }
    }

    pub fn verify_integrity(&self) -> bool {
        for y in 0..self.size.rows {
            let row = self.row(y);
            if row.cells().offset as usize >= self.memory.len() {
                return false;
            }
            for x in 0..self.size.cols {
                let cell = self.cell(y, x);
                if matches!(cell.wide(), CellWide::SpacerTail) && x == 0 {
                    return false;
                }
                if matches!(cell.wide(), CellWide::SpacerHead)
                    && (x + 1 != self.size.cols || !row.wrap())
                {
                    return false;
                }
            }
        }
        true
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

    pub fn adjust(mut capacity: Capacity, cols: CellCountInt) -> Capacity {
        let total = Self::layout(capacity).total_size;
        capacity.cols = cols;
        let adjusted = Self::layout(capacity);
        if adjusted.total_size > total {
            capacity.grapheme_bytes = align_backward(capacity.grapheme_bytes as usize, 256)
                .saturating_sub(256) as GraphemeBytesInt;
        }
        capacity
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
}

#[derive(Clone, Copy)]
pub enum CloneSource<'a> {
    SamePage,
    Other(&'a Page),
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
        page.move_cells(0, 3, 0, 2);
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
        assert_eq!(page.exact_row_capacity(0).styles, 1);
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
        assert_eq!(usize::from(cap.hyperlink_bytes), 2 * item);
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
        assert!(page.verify_integrity());
    }

    #[test]
    fn verify_integrity_rejects_spacer_tail_at_column_zero() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut cell = Cell::new('x');
        cell.set_wide(CellWide::SpacerTail);
        page.set_cell(0, 0, cell);
        assert!(!page.verify_integrity());
    }

    #[test]
    fn verify_integrity_rejects_spacer_head_without_wrap() {
        let mut page = Page::init(Capacity::new(2, 1));
        let mut cell = Cell::new('x');
        cell.set_wide(CellWide::SpacerHead);
        page.set_cell(0, 1, cell);
        assert!(!page.verify_integrity());
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
        assert!(page.verify_integrity());
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
}
