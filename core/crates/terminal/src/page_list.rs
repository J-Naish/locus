//! Terminal page chains with scrollback, viewport pins, and page growth.
//!
//! This ports the structural subset of Ghostty's `terminal/PageList.zig`.

use std::collections::HashMap;

use crate::page::{
    Capacity, Cell, CellSnapshot, CellSnapshotWriteError, CellWide, Page, PageSize, Row,
    SemanticPrompt, STD_CAPACITY,
};
use crate::point::{Coordinate, Point, Tag};
use crate::size::CellCountInt;

pub const PAGE_PREHEAT: usize = 4;
const PAGE_POOL_MAX: usize = 8;
pub const STD_SIZE: usize = 65_536;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId {
    pub index: u32,
    pub generation: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PinId(pub usize);

#[derive(Debug)]
pub(crate) struct PageNode {
    pub(crate) prev: Option<NodeId>,
    pub(crate) next: Option<NodeId>,
    pub(crate) page: Page,
    pub(crate) serial: u64,
}

#[derive(Debug)]
enum NodeSlot {
    Free {
        generation: u32,
    },
    Occupied {
        generation: u32,
        node: Box<PageNode>,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Pin {
    pub node: NodeId,
    pub x: CellCountInt,
    pub y: CellCountInt,
    pub garbage: bool,
}

impl Pin {
    pub const fn new(node: NodeId) -> Self {
        Self {
            node,
            x: 0,
            y: 0,
            garbage: false,
        }
    }

    pub const fn eql(self, other: Self) -> bool {
        self.node.index == other.node.index
            && self.node.generation == other.node.generation
            && self.y == other.y
            && self.x == other.x
    }

    pub fn left(self, n: usize) -> Self {
        debug_assert!(n <= self.x as usize);
        let mut result = self;
        result.x = result.x.saturating_sub(n as CellCountInt);
        result
    }

    pub fn left_clamp(self, n: CellCountInt) -> Self {
        let mut result = self;
        result.x = result.x.saturating_sub(n);
        result
    }

    pub fn right_clamp(self, pages: &PageList, n: CellCountInt) -> Self {
        pages.pin_right_clamp(self, n)
    }

    pub fn before(self, pages: &PageList, other: Self) -> bool {
        pages.pin_before(self, other)
    }

    pub fn left_wrap(self, pages: &PageList, n: usize) -> Option<Self> {
        let mut result = self;
        for _ in 0..n {
            if result.x > 0 {
                result.x -= 1;
                continue;
            }
            let mut prior = pages.pin_up(result, 1)?;
            let cols = pages
                .node(prior.node)
                .map(|node| node.page.size().cols)
                .unwrap_or(1);
            prior.x = cols.saturating_sub(1);
            result = prior;
        }
        Some(result)
    }

    pub fn right_wrap(self, pages: &PageList, n: usize) -> Option<Self> {
        let mut result = self;
        for _ in 0..n {
            let cols = pages.node(result.node)?.page.size().cols;
            if result.x + 1 < cols {
                result.x += 1;
                continue;
            }
            result = pages.pin_down(Pin { x: 0, ..result }, 1)?;
        }
        Some(result)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PinMove {
    Offset(Pin),
    Overflow { end: Pin, remaining: usize },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Viewport {
    Active,
    Top,
    Pin,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scroll {
    Active,
    Top,
    Row(usize),
    DeltaRow(isize),
    DeltaPrompt(isize),
    Pin(Pin),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Scrollbar {
    pub total: usize,
    pub offset: usize,
    pub len: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IncreaseCapacity {
    Styles,
    GraphemeBytes,
    HyperlinkBytes,
    StringBytes,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IncreaseCapacityError {
    OutOfSpace,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CloneRowsError {
    OutOfSpace,
}

pub struct CloneOptions<'a> {
    pub top: Point,
    pub bot: Option<Point>,
    pub tracked_pins: Option<&'a mut HashMap<PinId, PinId>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResizeCursor {
    pub x: CellCountInt,
    pub y: CellCountInt,
    pub pin: Option<PinId>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResizeOptions {
    pub cols: Option<CellCountInt>,
    pub rows: Option<CellCountInt>,
    pub reflow: bool,
    pub cursor: Option<ResizeCursor>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResizeError {
    OutOfSpace,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ReflowCursor {
    node: NodeId,
    x: CellCountInt,
    y: CellCountInt,
    pending_wrap: bool,
    new_rows: usize,
    total_rows: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PreservedCursor {
    pin: PinId,
    untrack: bool,
    remaining_rows: usize,
    wrapped_rows: usize,
}

impl ReflowCursor {
    const fn new(node: NodeId) -> Self {
        Self {
            node,
            x: 0,
            y: 0,
            pending_wrap: false,
            new_rows: 0,
            total_rows: 1,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WriteCellResult {
    Success,
    Repeat,
    SkipNext,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReflowWriteError {
    NeedCapacity(IncreaseCapacity),
}

impl From<CellSnapshotWriteError> for ReflowWriteError {
    fn from(error: CellSnapshotWriteError) -> Self {
        match error {
            CellSnapshotWriteError::Style => Self::NeedCapacity(IncreaseCapacity::Styles),
            CellSnapshotWriteError::GraphemeBytes => {
                Self::NeedCapacity(IncreaseCapacity::GraphemeBytes)
            }
            CellSnapshotWriteError::HyperlinkBytes => {
                Self::NeedCapacity(IncreaseCapacity::HyperlinkBytes)
            }
            CellSnapshotWriteError::StringBytes => {
                Self::NeedCapacity(IncreaseCapacity::StringBytes)
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SplitError {
    OutOfSpace,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    LeftUp,
    RightDown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellSubset {
    All,
    Left,
    Right,
}

#[derive(Debug)]
pub struct PageList {
    nodes: Vec<NodeSlot>,
    free_nodes: Vec<u32>,
    first: Option<NodeId>,
    last: Option<NodeId>,
    page_buffers: Vec<Vec<u8>>,
    tracked_pins: Vec<Option<Pin>>,
    viewport_pin: PinId,
    page_serial: u64,
    page_serial_min: u64,
    page_size: usize,
    explicit_max_size: usize,
    min_max_size: usize,
    total_rows: usize,
    viewport: Viewport,
    viewport_pin_row_offset: Option<usize>,
    pub cols: CellCountInt,
    pub rows: CellCountInt,
}

impl PageList {
    pub fn standard_size() -> usize {
        Page::layout(STD_CAPACITY).total_size
    }

    pub fn initial_capacity(cols: CellCountInt) -> Capacity {
        Page::adjust(STD_CAPACITY, cols)
    }

    pub fn min_max_size(cols: CellCountInt, rows: CellCountInt) -> usize {
        let cap = Self::initial_capacity(cols);
        let pages_exact = if cap.rows >= rows {
            1
        } else {
            (rows as usize).div_ceil(cap.rows as usize)
        };
        let pages = pages_exact.max(1) + 1;
        pages * Self::standard_size()
    }

    pub fn new(cols: CellCountInt, rows: CellCountInt, max_size: Option<usize>) -> Self {
        let mut list = Self {
            nodes: Vec::new(),
            free_nodes: Vec::new(),
            first: None,
            last: None,
            page_buffers: (0..PAGE_PREHEAT)
                .map(|_| vec![0; Self::standard_size()])
                .collect(),
            tracked_pins: Vec::with_capacity(8),
            viewport_pin: PinId(0),
            page_serial: 0,
            page_serial_min: 0,
            page_size: 0,
            explicit_max_size: max_size.unwrap_or(usize::MAX),
            min_max_size: Self::min_max_size(cols, rows),
            total_rows: 0,
            viewport: Viewport::Active,
            viewport_pin_row_offset: None,
            cols,
            rows,
        };
        list.init_pages();
        let first = list.first_or_panic();
        list.tracked_pins.push(Some(Pin::new(first)));
        list.viewport_pin = PinId(0);
        list
    }

    pub fn reset(&mut self) {
        self.page_serial_min = self.page_serial;
        self.destroy_all_nodes();
        self.init_pages();
        self.total_rows = self.rows as usize;
        let first = self.first_or_panic();
        for pin in self.tracked_pins.iter_mut().flatten() {
            *pin = Pin {
                node: first,
                x: 0,
                y: 0,
                garbage: true,
            };
        }
        if let Some(pin) = self.tracked_pin_mut(self.viewport_pin) {
            pin.garbage = false;
        }
        self.viewport = Viewport::Active;
        self.viewport_pin_row_offset = None;
    }

    pub fn max_size(&self) -> usize {
        self.explicit_max_size.max(self.min_max_size)
    }

    pub fn total_rows(&self) -> usize {
        self.total_rows
    }

    pub fn total_pages(&self) -> usize {
        self.iter_node_ids().count()
    }

    pub fn first_node(&self) -> Option<NodeId> {
        self.first
    }

    pub fn last_node(&self) -> Option<NodeId> {
        self.last
    }

    pub fn viewport(&self) -> Viewport {
        self.viewport
    }

    pub fn viewport_pin_id(&self) -> PinId {
        self.viewport_pin
    }

    pub fn tracked_pin(&self, id: PinId) -> Option<Pin> {
        self.tracked_pins.get(id.0).and_then(|pin| *pin)
    }

    pub(crate) fn tracked_pin_mut(&mut self, id: PinId) -> Option<&mut Pin> {
        self.tracked_pins.get_mut(id.0).and_then(Option::as_mut)
    }

    pub(crate) fn set_tracked_pin(&mut self, id: PinId, pin: Pin) -> bool {
        let Some(slot) = self.tracked_pins.get_mut(id.0) else {
            return false;
        };
        if slot.is_none() {
            return false;
        }
        *slot = Some(pin);
        true
    }

    pub fn page_size(&self) -> usize {
        self.page_size
    }

    pub fn node_serial(&self, id: NodeId) -> Option<u64> {
        self.node(id).map(|node| node.serial)
    }

    pub fn page_serial_min(&self) -> u64 {
        self.page_serial_min
    }

    pub fn node_buffer_ptr(&self, id: NodeId) -> Option<*const u8> {
        self.node(id).map(|node| node.page.memory_ptr())
    }

    pub fn node_page_size(&self, id: NodeId) -> Option<crate::page::PageSize> {
        self.node(id).map(|node| node.page.size())
    }

    pub fn node_capacity(&self, id: NodeId) -> Option<Capacity> {
        self.node(id).map(|node| node.page.capacity())
    }

    pub fn set_node_size_rows_for_testing(&mut self, id: NodeId, rows: CellCountInt) {
        if let Some(node) = self.node_mut(id) {
            node.page.set_size_rows(rows);
        }
    }

    pub fn recompute_total_rows_for_testing(&mut self) {
        self.total_rows = self
            .iter_node_ids()
            .filter_map(|id| self.node_rows(id))
            .map(usize::from)
            .sum();
    }

    pub fn get_top_left(&self, tag: Tag) -> Pin {
        match tag {
            Tag::Screen | Tag::History => Pin::new(self.first_or_panic()),
            Tag::Viewport => match self.viewport {
                Viewport::Active => self.get_top_left(Tag::Active),
                Viewport::Top => self.get_top_left(Tag::Screen),
                Viewport::Pin => {
                    let Some(pin) = self.tracked_pin(self.viewport_pin) else {
                        panic!("PageList viewport pin is not tracked");
                    };
                    pin
                }
            },
            Tag::Active => {
                let mut remaining = self.rows as usize;
                let mut current = Some(self.last_or_panic());
                while let Some(id) = current {
                    let Some(node) = self.node(id) else {
                        break;
                    };
                    let rows = node.page.size().rows as usize;
                    if remaining <= rows {
                        return Pin {
                            node: id,
                            x: 0,
                            y: (rows - remaining) as CellCountInt,
                            garbage: false,
                        };
                    }
                    remaining -= rows;
                    current = node.prev;
                }
                panic!("PageList active area has insufficient rows")
            }
        }
    }

    pub fn get_bottom_right(&self, tag: Tag) -> Option<Pin> {
        match tag {
            Tag::Screen | Tag::Active => {
                let node = self.last_or_panic();
                let page = &self.node(node)?.page;
                Some(Pin {
                    node,
                    x: page.size().cols.saturating_sub(1),
                    y: page.size().rows.saturating_sub(1),
                    garbage: false,
                })
            }
            Tag::Viewport => {
                let mut pin =
                    self.pin_down(self.get_top_left(Tag::Viewport), self.rows as usize - 1)?;
                pin.x = self.cols.saturating_sub(1);
                Some(pin)
            }
            Tag::History => {
                let mut pin = self.pin_up(self.get_top_left(Tag::Active), 1)?;
                pin.x = self.cols.saturating_sub(1);
                Some(pin)
            }
        }
    }

    pub fn pin(&self, point: Point) -> Option<Pin> {
        let coordinate = point.coord();
        if coordinate.x >= self.cols {
            return None;
        }
        let mut pin = self.pin_down(self.get_top_left(point.tag()), coordinate.y as usize)?;
        pin.x = coordinate.x;
        Some(pin)
    }

    pub fn point_from_pin(&self, tag: Tag, pin: Pin) -> Option<Point> {
        let top_left = self.get_top_left(tag);
        let mut coordinate = Coordinate { x: pin.x, y: 0 };
        if pin.node == top_left.node {
            if top_left.y > pin.y {
                return None;
            }
            coordinate.y = u32::from(pin.y - top_left.y);
            return Some(Point::with_tag(tag, coordinate));
        }

        coordinate.y += u32::from(self.node(top_left.node)?.page.size().rows - top_left.y);
        let mut current = self.node(top_left.node)?.next;
        while let Some(id) = current {
            let node = self.node(id)?;
            if id == pin.node {
                coordinate.y += u32::from(pin.y);
                return Some(Point::with_tag(tag, coordinate));
            }
            coordinate.y += u32::from(node.page.size().rows);
            current = node.next;
        }
        None
    }

    pub fn pin_is_active(&self, pin: Pin) -> bool {
        let active = self.get_top_left(Tag::Active);
        if pin.node == active.node {
            return pin.y >= active.y;
        }
        let mut current = self.node(active.node).and_then(|node| node.next);
        while let Some(id) = current {
            if id == pin.node {
                return true;
            }
            current = self.node(id).and_then(|node| node.next);
        }
        false
    }

    pub fn pin_is_top(&self, pin: Pin) -> bool {
        pin.node == self.first_or_panic() && pin.y == 0
    }

    pub fn pin_is_valid(&self, pin: Pin) -> bool {
        self.node(pin.node)
            .map(|node| pin.y < node.page.size().rows && pin.x < node.page.size().cols)
            .unwrap_or(false)
    }

    pub fn row_and_cell(&self, pin: Pin) -> Option<(Row, Cell)> {
        let node = self.node(pin.node)?;
        Some((node.page.row(pin.y), node.page.cell(pin.y, pin.x)))
    }

    pub fn cells(&self, pin: Pin, subset: CellSubset) -> Option<Vec<Cell>> {
        let node = self.node(pin.node)?;
        let mut cells = Vec::new();
        let end = match subset {
            CellSubset::All | CellSubset::Right => node.page.size().cols,
            CellSubset::Left => pin.x.saturating_add(1),
        };
        let start = match subset {
            CellSubset::All | CellSubset::Left => 0,
            CellSubset::Right => pin.x,
        };
        for x in start..end {
            cells.push(node.page.cell(pin.y, x));
        }
        Some(cells)
    }

    pub fn pin_is_dirty(&self, pin: Pin) -> bool {
        self.node(pin.node)
            .map(|node| node.page.is_dirty(pin.y))
            .unwrap_or(false)
    }

    pub fn mark_dirty(&mut self, pin: Pin) {
        if let Some(node) = self.node_mut(pin.node) {
            node.page.mark_row_dirty(pin.y);
        }
    }

    /// Clear the dirty bits on every page. Mirrors Ghostty's `PageList
    /// .clearDirty`, used as testing scaffolding by `Terminal.clearDirty`.
    pub fn clear_dirty(&mut self) {
        let mut current = self.first;
        while let Some(id) = current {
            let Some(node) = self.node_mut(id) else {
                break;
            };
            node.page.clear_dirty();
            current = self.node(id).and_then(|node| node.next);
        }
    }

    pub fn get_cell(&self, point: Point) -> Option<Cell> {
        let pin = self.pin(point)?;
        self.node(pin.node).map(|node| node.page.cell(pin.y, pin.x))
    }

    pub fn set_cell(&mut self, point: Point, cell: Cell) -> bool {
        let Some(pin) = self.pin(point) else {
            return false;
        };
        if let Some(node) = self.node_mut(pin.node) {
            node.page.set_cell(pin.y, pin.x, cell);
            return true;
        }
        false
    }

    pub fn set_row_semantic_prompt_for_testing(&mut self, pin: Pin, prompt: SemanticPrompt) {
        if let Some(node) = self.node_mut(pin.node) {
            let mut row = node.page.row(pin.y);
            row.set_semantic_prompt(prompt);
            node.page.set_row(pin.y, row);
        }
    }

    pub fn grow_rows(&mut self, count: usize) {
        for _ in 0..count {
            let _ = self.grow();
        }
    }

    pub fn pin_before(&self, left: Pin, right: Pin) -> bool {
        if left.node == right.node {
            return left.y < right.y || (left.y == right.y && left.x < right.x);
        }
        let mut current = self.node(left.node).and_then(|node| node.next);
        while let Some(id) = current {
            if id == right.node {
                return true;
            }
            current = self.node(id).and_then(|node| node.next);
        }
        false
    }

    pub fn pin_is_between(&self, pin: Pin, top: Pin, bottom: Pin) -> bool {
        if pin.node == top.node {
            if pin.y < top.y {
                return false;
            }
            if pin.y > top.y {
                return if pin.node == bottom.node {
                    pin.y <= bottom.y
                } else {
                    true
                };
            }
            if pin.x < top.x {
                return false;
            }
        }

        if pin.node == bottom.node {
            if pin.y > bottom.y {
                return false;
            }
            if pin.y < bottom.y {
                return true;
            }
            return pin.x <= bottom.x;
        }

        if top.node == bottom.node {
            return false;
        }
        let mut current = self.node(top.node).and_then(|node| node.next);
        while let Some(id) = current {
            if id == bottom.node {
                return false;
            }
            if id == pin.node {
                return true;
            }
            current = self.node(id).and_then(|node| node.next);
        }
        false
    }

    pub fn pin_right(&self, pin: Pin, n: usize) -> Pin {
        let Some(node) = self.node(pin.node) else {
            return pin;
        };
        debug_assert!(pin.x as usize + n < node.page.size().cols as usize);
        let mut result = pin;
        result.x = result.x.saturating_add(n as CellCountInt);
        result
    }

    pub fn pin_right_clamp(&self, pin: Pin, n: CellCountInt) -> Pin {
        let Some(node) = self.node(pin.node) else {
            return pin;
        };
        let mut result = pin;
        result.x = pin
            .x
            .saturating_add(n)
            .min(node.page.size().cols.saturating_sub(1));
        result
    }

    pub fn pin_down(&self, pin: Pin, n: usize) -> Option<Pin> {
        match self.pin_down_overflow(pin, n) {
            PinMove::Offset(pin) => Some(pin),
            PinMove::Overflow { .. } => None,
        }
    }

    pub fn pin_up(&self, pin: Pin, n: usize) -> Option<Pin> {
        match self.pin_up_overflow(pin, n) {
            PinMove::Offset(pin) => Some(pin),
            PinMove::Overflow { .. } => None,
        }
    }

    pub fn pin_down_overflow(&self, pin: Pin, n: usize) -> PinMove {
        let Some(node) = self.node(pin.node) else {
            return PinMove::Overflow {
                end: pin,
                remaining: n,
            };
        };
        let rows_remaining = node.page.size().rows.saturating_sub(pin.y + 1) as usize;
        if n <= rows_remaining {
            return PinMove::Offset(Pin {
                y: pin.y.saturating_add(n as CellCountInt),
                ..pin
            });
        }

        let mut current = pin.node;
        let mut n_left = n - rows_remaining;
        loop {
            let Some(next) = self.node(current).and_then(|node| node.next) else {
                let end_y = self
                    .node(current)
                    .map(|node| node.page.size().rows.saturating_sub(1))
                    .unwrap_or(pin.y);
                return PinMove::Overflow {
                    end: Pin {
                        node: current,
                        y: end_y,
                        x: pin.x,
                        garbage: pin.garbage,
                    },
                    remaining: n_left,
                };
            };
            let rows = self
                .node(next)
                .map(|node| node.page.size().rows as usize)
                .unwrap_or(0);
            if n_left <= rows {
                return PinMove::Offset(Pin {
                    node: next,
                    y: (n_left - 1) as CellCountInt,
                    x: pin.x,
                    garbage: pin.garbage,
                });
            }
            n_left -= rows;
            current = next;
        }
    }

    pub fn pin_up_overflow(&self, pin: Pin, n: usize) -> PinMove {
        if n <= pin.y as usize {
            return PinMove::Offset(Pin {
                y: pin.y.saturating_sub(n as CellCountInt),
                ..pin
            });
        }

        let mut current = pin.node;
        let mut n_left = n - pin.y as usize;
        loop {
            let Some(prev) = self.node(current).and_then(|node| node.prev) else {
                return PinMove::Overflow {
                    end: Pin {
                        node: current,
                        y: 0,
                        x: pin.x,
                        garbage: pin.garbage,
                    },
                    remaining: n_left,
                };
            };
            let rows = self
                .node(prev)
                .map(|node| node.page.size().rows as usize)
                .unwrap_or(0);
            if n_left <= rows {
                return PinMove::Offset(Pin {
                    node: prev,
                    y: (rows - n_left) as CellCountInt,
                    x: pin.x,
                    garbage: pin.garbage,
                });
            }
            n_left -= rows;
            current = prev;
        }
    }

    pub fn track_pin(&mut self, pin: Pin) -> PinId {
        if let Some((index, slot)) = self
            .tracked_pins
            .iter_mut()
            .enumerate()
            .find(|(_, slot)| slot.is_none())
        {
            *slot = Some(pin);
            return PinId(index);
        }
        self.tracked_pins.push(Some(pin));
        PinId(self.tracked_pins.len() - 1)
    }

    pub fn untrack_pin(&mut self, id: PinId) -> bool {
        if id == self.viewport_pin {
            return false;
        }
        match self.tracked_pins.get_mut(id.0) {
            Some(slot @ Some(_)) => {
                *slot = None;
                true
            }
            _ => false,
        }
    }

    pub fn count_tracked_pins(&self) -> usize {
        self.tracked_pins.iter().filter(|pin| pin.is_some()).count()
    }

    pub fn scroll(&mut self, behavior: Scroll) {
        if self.explicit_max_size == 0 {
            self.viewport = Viewport::Active;
            return;
        }

        match behavior {
            Scroll::Active => self.viewport = Viewport::Active,
            Scroll::Top => self.viewport = Viewport::Top,
            Scroll::Pin(pin) => {
                if self.pin_is_active(pin) {
                    self.viewport = Viewport::Active;
                } else if self.pin_is_top(pin) {
                    self.viewport = Viewport::Top;
                } else {
                    if let Some(viewport_pin) = self.tracked_pin_mut(self.viewport_pin) {
                        *viewport_pin = pin;
                    }
                    self.viewport = Viewport::Pin;
                    self.viewport_pin_row_offset = None;
                }
            }
            Scroll::Row(row) => self.scroll_row(row),
            Scroll::DeltaRow(delta) => self.scroll_delta_row(delta),
            Scroll::DeltaPrompt(delta) => self.scroll_delta_prompt(delta),
        }
    }

    fn scroll_row(&mut self, row: usize) {
        if row == 0 {
            self.viewport = Viewport::Top;
            return;
        }
        if row >= self.total_rows.saturating_sub(self.rows as usize) {
            self.viewport = Viewport::Active;
            return;
        }

        if self.viewport == Viewport::Pin {
            if let Some(offset) = self.viewport_pin_row_offset {
                self.scroll(Scroll::DeltaRow(row as isize - offset as isize));
                return;
            }
        }

        self.viewport_pin_row_offset = Some(row);
        self.viewport = Viewport::Pin;
        let midpoint = self.total_rows / 2;
        let target = if row < midpoint {
            let mut current = self.first;
            let mut remaining = row;
            let mut found = None;
            while let Some(id) = current {
                let Some(node) = self.node(id) else {
                    break;
                };
                let rows = node.page.size().rows as usize;
                if remaining < rows {
                    found = Some(Pin {
                        node: id,
                        y: remaining as CellCountInt,
                        x: 0,
                        garbage: false,
                    });
                    break;
                }
                remaining -= rows;
                current = node.next;
            }
            found
        } else {
            let mut current = self.last;
            let mut remaining = self.total_rows - row;
            let mut found = None;
            while let Some(id) = current {
                let Some(node) = self.node(id) else {
                    break;
                };
                let rows = node.page.size().rows as usize;
                if remaining <= rows {
                    found = Some(Pin {
                        node: id,
                        y: (rows - remaining) as CellCountInt,
                        x: 0,
                        garbage: false,
                    });
                    break;
                }
                remaining -= rows;
                current = node.prev;
            }
            found
        };

        if let Some(pin) = target {
            if let Some(viewport_pin) = self.tracked_pin_mut(self.viewport_pin) {
                *viewport_pin = pin;
            }
        } else {
            self.viewport = Viewport::Active;
        }
    }

    fn scroll_delta_row(&mut self, delta: isize) {
        match self.viewport {
            Viewport::Top if delta <= 0 => return,
            Viewport::Active if delta >= 0 => return,
            Viewport::Pin => {
                if delta == 0 {
                    return;
                }
                let Some(current) = self.tracked_pin(self.viewport_pin) else {
                    panic!("PageList viewport pin is not tracked");
                };
                if delta < 0 {
                    match self.pin_up_overflow(current, (-delta) as usize) {
                        PinMove::Offset(pin) => {
                            if let Some(viewport_pin) = self.tracked_pin_mut(self.viewport_pin) {
                                *viewport_pin = pin;
                            }
                            if let Some(offset) = &mut self.viewport_pin_row_offset {
                                *offset = offset.saturating_sub((-delta) as usize);
                            }
                            return;
                        }
                        PinMove::Overflow { .. } => {
                            self.viewport = Viewport::Top;
                            return;
                        }
                    }
                } else {
                    match self.pin_down_overflow(current, delta as usize) {
                        PinMove::Offset(pin) => {
                            if self.pin_is_active(pin) {
                                self.viewport = Viewport::Active;
                            } else {
                                if let Some(viewport_pin) = self.tracked_pin_mut(self.viewport_pin)
                                {
                                    *viewport_pin = pin;
                                }
                                if let Some(offset) = &mut self.viewport_pin_row_offset {
                                    *offset += delta as usize;
                                }
                            }
                            return;
                        }
                        PinMove::Overflow { .. } => {
                            self.viewport = Viewport::Active;
                            return;
                        }
                    }
                }
            }
            _ => {}
        }

        let top = self.get_top_left(Tag::Viewport);
        let pin = if delta < 0 {
            match self.pin_up_overflow(top, (-delta) as usize) {
                PinMove::Offset(pin) => pin,
                PinMove::Overflow { end, .. } => end,
            }
        } else {
            match self.pin_down_overflow(top, delta as usize) {
                PinMove::Offset(pin) => pin,
                PinMove::Overflow { end, .. } => end,
            }
        };

        if self.pin_is_active(pin) {
            self.viewport = Viewport::Active;
        } else if self.pin_is_top(pin) {
            self.viewport = Viewport::Top;
        } else {
            if let Some(viewport_pin) = self.tracked_pin_mut(self.viewport_pin) {
                *viewport_pin = pin;
            }
            self.viewport = Viewport::Pin;
            self.viewport_pin_row_offset = None;
        }
    }

    fn scroll_delta_prompt(&mut self, delta: isize) {
        if delta == 0 {
            return;
        }
        let mut remaining = delta.unsigned_abs();
        let top = self.get_top_left(Tag::Viewport);
        let start = if delta <= 0 {
            match self.pin_up(top, 1) {
                Some(pin) => pin,
                None => return,
            }
        } else {
            let Some(mut adjusted) = self.pin_down(top, 1) else {
                return;
            };
            if self
                .row_and_cell(top)
                .map(|(row, _)| row.semantic_prompt() != SemanticPrompt::None)
                .unwrap_or(false)
            {
                while self
                    .row_and_cell(adjusted)
                    .map(|(row, _)| row.semantic_prompt() == SemanticPrompt::PromptContinuation)
                    .unwrap_or(false)
                {
                    let Some(next) = self.pin_down(adjusted, 1) else {
                        break;
                    };
                    adjusted = next;
                }
            }
            adjusted
        };

        let mut iterator = self.prompt_iterator_from_pin(
            start,
            if delta > 0 {
                Direction::RightDown
            } else {
                Direction::LeftUp
            },
            None,
        );
        let mut found = None;
        while let Some(pin) = iterator.next(self) {
            found = Some(pin);
            remaining -= 1;
            if remaining == 0 {
                break;
            }
        }
        if let Some(pin) = found {
            if self.pin_is_active(pin) {
                self.viewport = Viewport::Active;
            } else {
                if let Some(viewport_pin) = self.tracked_pin_mut(self.viewport_pin) {
                    *viewport_pin = pin;
                }
                self.viewport = Viewport::Pin;
                self.viewport_pin_row_offset = None;
            }
        }
    }

    pub fn scrollbar(&mut self) -> Scrollbar {
        if self.explicit_max_size == 0 {
            return Scrollbar {
                total: self.rows as usize,
                offset: 0,
                len: self.rows as usize,
            };
        }
        Scrollbar {
            total: self.total_rows,
            offset: self.viewport_row_offset(),
            len: self.rows as usize,
        }
    }

    pub fn viewport_row_offset(&mut self) -> usize {
        match self.viewport {
            Viewport::Top => 0,
            Viewport::Active => self.total_rows.saturating_sub(self.rows as usize),
            Viewport::Pin => {
                if let Some(offset) = self.viewport_pin_row_offset {
                    return offset;
                }
                let Some(pin) = self.tracked_pin(self.viewport_pin) else {
                    panic!("PageList viewport pin is not tracked");
                };
                let mut offset = 0usize;
                let mut current = self.last;
                while let Some(id) = current {
                    let Some(node) = self.node(id) else {
                        break;
                    };
                    offset += node.page.size().rows as usize;
                    if id == pin.node {
                        offset -= pin.y as usize;
                        let top_offset = self.total_rows - offset;
                        self.viewport_pin_row_offset = Some(top_offset);
                        return top_offset;
                    }
                    current = node.prev;
                }
                0
            }
        }
    }

    pub fn fixup_viewport(&mut self, removed: usize) {
        match self.viewport {
            Viewport::Active => {}
            Viewport::Pin => {
                let Some(pin) = self.tracked_pin(self.viewport_pin) else {
                    panic!("PageList viewport pin is not tracked");
                };
                if self.pin_is_active(pin) {
                    self.viewport = Viewport::Active;
                } else if let Some(offset) = &mut self.viewport_pin_row_offset {
                    if *offset < removed {
                        self.viewport = Viewport::Top;
                    } else {
                        *offset -= removed;
                    }
                }
            }
            Viewport::Top => {
                let top = Pin::new(self.first_or_panic());
                if self.pin_is_active(top) {
                    self.viewport = Viewport::Active;
                }
            }
        }
    }

    pub fn scroll_clear(&mut self) {
        let mut trailing_empty = 0usize;
        let mut current = self.last;
        let mut rows_to_grow = 0usize;
        while let Some(id) = current {
            let Some(node) = self.node(id) else {
                break;
            };
            let mut y = node.page.size().rows;
            while y > 0 {
                y -= 1;
                let mut empty = true;
                for x in 0..self.cols {
                    if !node.page.cell(y, x).is_empty() {
                        empty = false;
                        break;
                    }
                }
                if !empty {
                    rows_to_grow = (self.rows as usize).saturating_sub(trailing_empty);
                    break;
                }
                trailing_empty += 1;
                if trailing_empty > self.rows as usize {
                    rows_to_grow = 0;
                    break;
                }
            }
            if rows_to_grow > 0 || trailing_empty > self.rows as usize {
                break;
            }
            current = node.prev;
        }
        let count = rows_to_grow.min(self.rows as usize);
        for _ in 0..count {
            let _ = self.grow();
        }
    }

    pub fn grow(&mut self) -> Option<NodeId> {
        let last = self.last_or_panic();
        let can_grow_last = self
            .node(last)
            .map(|node| node.page.capacity().rows > node.page.size().rows)
            .unwrap_or(false);
        if can_grow_last {
            if let Some(node) = self.node_mut(last) {
                let rows = node.page.size().rows.saturating_add(1);
                node.page.set_size_rows(rows);
            }
            self.total_rows += 1;
            return None;
        }

        let mut cap = Self::initial_capacity(self.cols);
        if let Some(last_capacity) = self.node(last).map(|node| node.page.capacity()) {
            // Deliberate Ghostty deviation: managed-data capacity is a
            // session-level high-water mark. New pages inherit it so output
            // does not repeat the same capacity-growth ladder on every page.
            // Grid dimensions remain at their initial values.
            cap.styles = last_capacity.styles;
            cap.grapheme_bytes = last_capacity.grapheme_bytes;
            cap.hyperlink_bytes = last_capacity.hyperlink_bytes;
            cap.string_bytes = last_capacity.string_bytes;
        }
        let cap_layout_size = Page::layout(cap).total_size;
        let mut retired_non_standard_buffer = None;
        if self.first.is_some()
            && self.first != self.last
            && self.page_size + Self::standard_size() > self.max_size()
        {
            let first = self.pop_first()?;
            let first_rows = self.node_rows(first).unwrap_or(0) as usize;
            self.total_rows = self.total_rows.saturating_sub(first_rows);
            if self.total_rows + 1 < self.rows as usize {
                self.prepend_node(first);
                self.total_rows += first_rows;
            } else {
                if self.viewport == Viewport::Pin {
                    if let Some(offset) = &mut self.viewport_pin_row_offset {
                        if *offset < first_rows {
                            self.viewport = Viewport::Top;
                        } else {
                            *offset -= first_rows;
                        }
                    }
                }

                let new_first = self.first_or_panic();
                for pin in self.tracked_pins.iter_mut().flatten() {
                    if pin.node == first {
                        *pin = Pin {
                            node: new_first,
                            x: 0,
                            y: 0,
                            garbage: true,
                        };
                    }
                }
                if let Some(viewport_pin) = self.tracked_pin_mut(self.viewport_pin) {
                    viewport_pin.garbage = false;
                }

                let reusable = self
                    .node(first)
                    .map(|node| {
                        node.page.memory_len() == Self::standard_size()
                            && node.page.memory_len() == cap_layout_size
                    })
                    .unwrap_or(false);
                if reusable {
                    let old_serial = self.node(first).map(|node| node.serial).unwrap_or(0);
                    let new_serial = self.page_serial;
                    self.page_serial = self.page_serial.saturating_add(1);
                    if let Some(node) = self.node_mut(first) {
                        node.page.reinit_with_layout(Page::layout(cap));
                        node.page.set_size_rows(1);
                        node.serial = new_serial;
                    }
                    self.insert_after(last, first);
                    self.total_rows += 1;
                    self.page_serial_min = old_serial.saturating_add(1);
                    return Some(first);
                }
                if let Some(node) = self.take_node(first) {
                    let memory = node.page.into_memory();
                    self.page_size = self.page_size.saturating_sub(memory.len());
                    if memory.len() == Self::standard_size()
                        && self.page_buffers.len() < PAGE_POOL_MAX
                    {
                        // Keep modest resize headroom while returning cleared history to the allocator.
                        self.page_buffers.push(memory);
                    } else {
                        retired_non_standard_buffer = Some(memory);
                    }
                }
            }
        }

        let next = self.create_page(cap);
        drop(retired_non_standard_buffer);
        if let Some(node) = self.node_mut(next) {
            node.page.set_size_rows(1);
        }
        self.append_node(next);
        self.total_rows += 1;
        Some(next)
    }

    pub(crate) fn rotate_rows_right_from_pin_to_end(&mut self, pin: Pin) {
        let cursor_node = pin.node;
        let mut current = self.last;
        while let Some(current_id) = current {
            if current_id == cursor_node {
                break;
            }
            let Some(prev_id) = self.node(current_id).and_then(|node| node.prev) else {
                break;
            };
            let Some(source_y) = self
                .node(prev_id)
                .map(|node| node.page.size().rows.saturating_sub(1))
            else {
                break;
            };
            let snapshots = self.row_snapshots(prev_id, source_y);
            if let Some(node) = self.node_mut(current_id) {
                let rows = node.page.size().rows;
                if rows > 0 {
                    node.page.rotate_rows_right_once(0, rows);
                    write_snapshots_to_row(&mut node.page, 0, &snapshots);
                    node.page.set_page_dirty(true);
                }
            }
            current = Some(prev_id);
        }

        if let Some(node) = self.node_mut(cursor_node) {
            let rows = node.page.size().rows;
            if pin.y < rows {
                node.page.rotate_rows_right_once(pin.y, rows);
                node.page.clear_row(pin.y);
                node.page.set_page_dirty(true);
            }
        }
    }

    fn row_snapshots(&self, id: NodeId, y: CellCountInt) -> Vec<CellSnapshot> {
        let Some(node) = self.node(id) else {
            return Vec::new();
        };
        let size = node.page.size();
        if y >= size.rows {
            return Vec::new();
        }
        (0..size.cols)
            .map(|x| node.page.cell_snapshot(y, x))
            .collect()
    }

    pub fn increase_capacity(
        &mut self,
        id: NodeId,
        adjustment: Option<IncreaseCapacity>,
    ) -> Result<NodeId, IncreaseCapacityError> {
        let Some(old_node) = self.node(id) else {
            return Err(IncreaseCapacityError::OutOfSpace);
        };
        let mut cap = old_node.page.capacity();
        let old_size = old_node.page.size();
        let old_dirty = old_node.page.page_dirty();
        if let Some(adjustment) = adjustment {
            match adjustment {
                IncreaseCapacity::Styles => {
                    cap.styles =
                        double_or_max(cap.styles).ok_or(IncreaseCapacityError::OutOfSpace)?;
                }
                IncreaseCapacity::GraphemeBytes => {
                    cap.grapheme_bytes = double_or_max(cap.grapheme_bytes)
                        .ok_or(IncreaseCapacityError::OutOfSpace)?;
                }
                IncreaseCapacity::HyperlinkBytes => {
                    cap.hyperlink_bytes = double_or_max(cap.hyperlink_bytes)
                        .ok_or(IncreaseCapacityError::OutOfSpace)?;
                }
                IncreaseCapacity::StringBytes => {
                    cap.string_bytes =
                        double_or_max(cap.string_bytes).ok_or(IncreaseCapacityError::OutOfSpace)?;
                }
            }
            if Page::layout(cap).total_size > crate::size::MAX_PAGE_SIZE {
                return Err(IncreaseCapacityError::OutOfSpace);
            }
        }

        let new_id = self.create_page(cap);
        if let Some((old_node, new_node)) = self.nodes_pair_mut(id, new_id) {
            new_node.page.set_size(old_size);
            new_node
                .page
                .clone_rows_from(&old_node.page, 0, old_size.rows);
            new_node.page.set_page_dirty(old_dirty);
            for y in 0..old_size.rows {
                if old_node.page.row_dirty(y) {
                    let mut row = new_node.page.row(y);
                    row.set_dirty(true);
                    new_node.page.set_row(y, row);
                }
            }
        }

        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.node == id {
                pin.node = new_id;
            }
        }

        self.insert_before(id, new_id);
        self.remove_node(id);
        self.destroy_node(id);
        Ok(new_id)
    }

    pub fn erase_history(&mut self, bottom_left: Option<Point>) {
        self.erase_rows(Point::history(0, 0), bottom_left);
    }

    pub fn erase_active(&mut self, y: CellCountInt) {
        debug_assert!(y < self.rows);
        self.erase_rows(Point::active(0, 0), Some(Point::active(0, u32::from(y))));
    }

    pub fn erase_row(&mut self, point: Point) -> Result<(), CloneRowsError> {
        let Some(pin) = self.pin(point) else {
            return Ok(());
        };
        self.erase_row_at_pin(pin)
    }

    pub fn erase_row_bounded(&mut self, point: Point, limit: usize) -> Result<(), CloneRowsError> {
        let Some(pin) = self.pin(point) else {
            return Ok(());
        };
        self.erase_row_bounded_at_pin(pin, limit)
    }

    pub fn clone(&self, mut opts: CloneOptions<'_>) -> Self {
        let mut result = PageList::new(self.cols, self.rows, Some(self.explicit_max_size));
        result.destroy_all_nodes();
        result.page_serial = 0;
        result.page_serial_min = 0;
        result.viewport = Viewport::Active;
        result.viewport_pin_row_offset = None;
        result.tracked_pins.clear();

        let mut chunks = self.page_iterator(Direction::RightDown, opts.top, opts.bot);
        while let Some(chunk) = chunks.next(self) {
            let Some(source_node) = self.node(chunk.node) else {
                continue;
            };
            let id = result.create_page(source_node.page.capacity());
            let row_count = chunk.end.saturating_sub(chunk.start);
            if let Some(node) = result.node_mut(id) {
                node.page.set_size(PageSize {
                    cols: source_node.page.size().cols,
                    rows: row_count,
                });
                node.page
                    .clone_rows_from(&source_node.page, chunk.start, chunk.end);
                node.page.set_page_dirty(source_node.page.page_dirty());
                for y in 0..row_count {
                    node.page
                        .set_row_dirty(y, source_node.page.row_dirty(chunk.start + y));
                }
            }
            result.append_node(id);
            result.total_rows += row_count as usize;

            if let Some(map) = opts.tracked_pins.as_deref_mut() {
                for (source_index, pin) in self.tracked_pins.iter().enumerate() {
                    let Some(pin) = *pin else {
                        continue;
                    };
                    if pin.node == chunk.node && pin.y >= chunk.start && pin.y < chunk.end {
                        let cloned_pin = Pin {
                            node: id,
                            y: pin.y - chunk.start,
                            ..pin
                        };
                        let cloned_id = result.track_pin(cloned_pin);
                        map.insert(PinId(source_index), cloned_id);
                    }
                }
            }
        }

        if result.first.is_none() {
            let id = result.create_page(Self::initial_capacity(self.cols));
            if let Some(node) = result.node_mut(id) {
                node.page.set_size(PageSize {
                    cols: self.cols,
                    rows: 0,
                });
            }
            result.append_node(id);
        }

        while result.total_rows < result.rows as usize {
            let _ = result.grow();
            if let Some(last) = result.last {
                if let Some(node) = result.node_mut(last) {
                    let y = node.page.size().rows.saturating_sub(1);
                    node.page.clear_row(y);
                }
            }
        }

        let first = result.first_or_panic();
        result.viewport_pin = result.track_pin(Pin::new(first));
        result
    }

    pub fn resize(&mut self, opts: ResizeOptions) -> Result<(), ResizeError> {
        debug_assert!(opts.cols.map(|cols| cols > 0).unwrap_or(true));
        debug_assert!(opts.rows.map(|rows| rows > 0).unwrap_or(true));
        self.viewport_pin_row_offset = None;
        if !opts.reflow {
            return self.resize_without_reflow(opts);
        }

        let old_min = self.min_max_size;
        let new_cols = opts.cols.unwrap_or(self.cols);
        let new_rows = opts.rows.unwrap_or(self.rows);
        self.min_max_size = Self::min_max_size(new_cols, new_rows);

        let result = (|| {
            if new_cols == self.cols {
                self.resize_without_reflow(opts)?;
            } else if new_cols > self.cols {
                self.resize_cols(new_cols, opts.cursor)?;
                self.resize_without_reflow(opts)?;
            } else {
                self.resize_without_reflow(ResizeOptions {
                    cols: Some(self.cols),
                    rows: opts.rows,
                    reflow: true,
                    cursor: opts.cursor,
                })?;
                self.resize_cols(new_cols, opts.cursor)?;
            }
            if self.viewport == Viewport::Pin {
                if let Some(pin) = self.tracked_pin(self.viewport_pin) {
                    if self.pin_is_active(pin) {
                        self.viewport = Viewport::Active;
                    }
                }
            }
            Ok(())
        })();

        if result.is_err() {
            self.min_max_size = old_min;
        }
        result
    }

    fn resize_cols(
        &mut self,
        cols: CellCountInt,
        resize_cursor: Option<ResizeCursor>,
    ) -> Result<(), ResizeError> {
        if cols == 0 {
            return Err(ResizeError::OutOfSpace);
        }

        let preserved_cursor = self.capture_preserved_cursor(resize_cursor);
        let mut page_iterator = self.page_iterator(Direction::RightDown, Point::screen(0, 0), None);
        let mut row_iterator = RowIterator::new(self, &mut page_iterator);
        let first_source = self.first_or_panic();
        let first_capacity = self
            .node(first_source)
            .map(|node| node.page.capacity())
            .unwrap_or_else(|| Self::initial_capacity(cols));
        let first_size = self
            .node(first_source)
            .map(|node| node.page.size())
            .unwrap_or(PageSize { cols, rows: 1 });
        let first_capacity = Self::reflow_first_capacity(first_capacity, first_size, cols)?;
        let first_new = self.create_reflow_page(first_capacity);
        self.first = Some(first_new);
        self.last = Some(first_new);
        self.cols = cols;
        self.total_rows = 1;

        let mut reflow_cursor = ReflowCursor::new(first_new);
        while let Some(source_row) = row_iterator.next(self) {
            let destroy_after = self
                .node(source_row.node)
                .map(|node| source_row.y + 1 == node.page.size().rows)
                .unwrap_or(false);
            if let Err(error) = self.reflow_row(
                source_row,
                &mut reflow_cursor,
                preserved_cursor.map(|cursor| cursor.pin),
            ) {
                self.destroy_source_chain(source_row.node);
                if let Some(cursor) = preserved_cursor {
                    if cursor.untrack {
                        self.untrack_pin(cursor.pin);
                    }
                }
                return Err(error);
            }
            if destroy_after {
                self.destroy_node(source_row.node);
            }
        }

        self.total_rows = reflow_cursor.total_rows;
        while self.total_rows < self.rows as usize {
            let _ = self.grow();
        }
        if self.viewport == Viewport::Pin
            && self
                .tracked_pin(self.viewport_pin)
                .map(|pin| self.pin_is_active(pin))
                .unwrap_or(false)
        {
            self.viewport = Viewport::Active;
        }
        if let Some(cursor) = preserved_cursor {
            self.grow_for_preserved_cursor(cursor);
            if cursor.untrack {
                self.untrack_pin(cursor.pin);
            }
        }
        Ok(())
    }

    fn capture_preserved_cursor(
        &mut self,
        resize_cursor: Option<ResizeCursor>,
    ) -> Option<PreservedCursor> {
        let cursor = resize_cursor?;
        let pin = match cursor.pin {
            Some(pin_id) => self.tracked_pin(pin_id)?,
            None => self.pin(Point::active(cursor.x, cursor.y.into()))?,
        };
        let pin_id = cursor.pin.unwrap_or_else(|| self.track_pin(pin));
        Some(PreservedCursor {
            pin: pin_id,
            untrack: cursor.pin.is_none(),
            remaining_rows: (self.rows as usize).saturating_sub(cursor.y as usize + 1),
            wrapped_rows: self.count_wrap_continuations_to_active_top(pin),
        })
    }

    fn count_wrap_continuations_to_active_top(&self, pin: Pin) -> usize {
        if self.point_from_pin(Tag::Active, pin).is_none() {
            return 0;
        }

        let active_top = self.get_top_left(Tag::Active);
        let mut count = 0usize;
        let mut current = pin;
        loop {
            if self
                .node(current.node)
                .map(|node| node.page.row(current.y).wrap_continuation())
                .unwrap_or(false)
            {
                count = count.saturating_add(1);
            }
            if current.node == active_top.node && current.y == active_top.y {
                break;
            }
            let Some(previous) = self.pin_up(current, 1) else {
                break;
            };
            current = previous;
        }
        count
    }

    fn grow_for_preserved_cursor(&mut self, cursor: PreservedCursor) {
        let Some(pin) = self.tracked_pin(cursor.pin) else {
            return;
        };
        let Some(point) = self.point_from_pin(Tag::Active, pin) else {
            return;
        };
        let wrapped_after = self.count_wrap_continuations_to_active_top(pin);
        let current = (self.rows as usize).saturating_sub(point.coord().y as usize + 1);
        let required = cursor
            .remaining_rows
            .saturating_sub(wrapped_after.saturating_sub(cursor.wrapped_rows))
            .saturating_sub(current);
        for _ in 0..required {
            let _ = self.grow();
        }
    }

    fn reflow_first_capacity(
        mut cap: Capacity,
        size: PageSize,
        cols: CellCountInt,
    ) -> Result<Capacity, ResizeError> {
        cap.cols = cols;
        cap.rows = size.rows.clamp(1, cap.rows);
        if Page::layout(cap).total_size <= crate::size::MAX_PAGE_SIZE {
            Ok(cap)
        } else {
            Err(ResizeError::OutOfSpace)
        }
    }

    fn reflow_row_capacity(
        mut cap: Capacity,
        size: PageSize,
        cols: CellCountInt,
    ) -> Result<Capacity, ResizeError> {
        cap.cols = cols;
        cap.rows = size.rows.clamp(1, STD_CAPACITY.rows);
        if Page::layout(cap).total_size <= crate::size::MAX_PAGE_SIZE {
            Ok(cap)
        } else {
            Err(ResizeError::OutOfSpace)
        }
    }

    fn create_reflow_page(&mut self, cap: Capacity) -> NodeId {
        let id = self.create_page(cap);
        if let Some(node) = self.node_mut(id) {
            node.page.set_size(PageSize {
                cols: cap.cols,
                rows: 1,
            });
            node.page.clear_row(0);
        }
        id
    }

    fn reflow_row(
        &mut self,
        source: Pin,
        cursor: &mut ReflowCursor,
        preserved_cursor: Option<PinId>,
    ) -> Result<(), ResizeError> {
        let Some(source_node) = self.node(source.node) else {
            return Ok(());
        };
        let source_size = source_node.page.size();
        let source_cap = source_node.page.capacity();
        let source_row = source_node.page.row(source.y);
        let source_prompt = source_row.semantic_prompt();
        let row_snapshots: Vec<CellSnapshot> = (0..source_size.cols)
            .map(|x| source_node.page.cell_snapshot(source.y, x))
            .collect();
        let cap = Self::reflow_row_capacity(source_cap, source_size, self.cols)?;
        let len = self.source_row_reflow_len(
            source,
            source_row,
            &row_snapshots,
            cursor.x,
            preserved_cursor,
        );

        if len == 0 && !source_row.wrap_continuation() {
            if self.source_row_has_pin(source) {
                self.flush_reflow_pending_rows(cursor, cap)?;
                self.remap_reflow_row_end_pins(source, cursor, 0);
            }
            cursor.new_rows = cursor.new_rows.saturating_add(1);
            return Ok(());
        }

        if !source_row.wrap_continuation() {
            self.flush_reflow_pending_rows(cursor, cap)?;
        }

        let mut x = 0;
        while x < len {
            let Some(snapshot) = row_snapshots.get(x as usize) else {
                break;
            };
            self.set_reflow_row_prompt(cursor, source_prompt);
            match self.reflow_write_cell(cursor, source, x, snapshot, cap)? {
                WriteCellResult::Success => x = x.saturating_add(1),
                WriteCellResult::Repeat => {}
                WriteCellResult::SkipNext => x = x.saturating_add(2),
            }
        }

        self.remap_reflow_row_end_pins(source, cursor, len);
        if !source_row.wrap() {
            self.finish_reflow_line(cursor);
        }
        Ok(())
    }

    fn source_row_reflow_len(
        &mut self,
        source: Pin,
        row: Row,
        snapshots: &[CellSnapshot],
        cursor_x: CellCountInt,
        preserved_cursor: Option<PinId>,
    ) -> CellCountInt {
        let mut len = if row.wrap() {
            snapshots.len() as CellCountInt
        } else {
            snapshots
                .iter()
                .rposition(|snapshot| !snapshot.cell.is_empty())
                .map(|index| index as CellCountInt + 1)
                .unwrap_or(0)
        };
        if len == 0 && row.semantic_prompt() != SemanticPrompt::None {
            len = 1;
        }
        let max_trailing_pin_x = self.cols.saturating_sub(1).saturating_sub(cursor_x);

        // Handle non-cursor tracked pins first (matching Ghostty's ordering).
        // A pin sitting in the trailing blanks past the destination width is
        // clamped to the destination width; the live cursor pin is handled
        // separately below and must NOT be clamped, so it is skipped here. Order
        // matters: clamping a non-cursor pin uses the content-derived `len`
        // before the cursor extends it, otherwise the saved-cursor pin would be
        // dragged onto a wrapped row instead of clamped.
        for (id, pin) in self.tracked_pins.iter_mut().enumerate() {
            let Some(pin) = pin else {
                continue;
            };
            if preserved_cursor == Some(PinId(id)) {
                continue;
            }
            if pin.node == source.node && pin.y == source.y {
                if pin.x >= len {
                    pin.x = pin.x.min(max_trailing_pin_x);
                }
                len = len.max(pin.x.saturating_add(1));
            }
        }

        // The live cursor, if it's after blanks on the right, keeps those cells
        // before the next write so they reflow with it (never clamped).
        if let Some(cursor_id) = preserved_cursor {
            if let Some(Some(pin)) = self.tracked_pins.get(cursor_id.0) {
                if pin.node == source.node && pin.y == source.y {
                    len = len.max(pin.x.saturating_add(1));
                }
            }
        }

        len.min(snapshots.len() as CellCountInt)
    }

    fn source_row_has_pin(&self, source: Pin) -> bool {
        self.tracked_pins
            .iter()
            .flatten()
            .any(|pin| pin.node == source.node && pin.y == source.y && !pin.garbage)
    }

    fn flush_reflow_pending_rows(
        &mut self,
        cursor: &mut ReflowCursor,
        cap: Capacity,
    ) -> Result<(), ResizeError> {
        while cursor.new_rows > 0 {
            self.cursor_scroll_or_new_page(cursor, false, cap)?;
            cursor.new_rows -= 1;
        }
        Ok(())
    }

    fn finish_reflow_line(&mut self, cursor: &mut ReflowCursor) {
        if let Some(node) = self.node_mut(cursor.node) {
            let mut row = node.page.row(cursor.y);
            row.set_wrap(false);
            node.page.set_row(cursor.y, row);
        }
        cursor.x = 0;
        cursor.pending_wrap = false;
        cursor.new_rows = cursor.new_rows.saturating_add(1);
    }

    fn set_reflow_row_prompt(&mut self, cursor: &ReflowCursor, prompt: SemanticPrompt) {
        if prompt == SemanticPrompt::None {
            return;
        }
        if let Some(node) = self.node_mut(cursor.node) {
            let mut row = node.page.row(cursor.y);
            row.set_semantic_prompt(prompt);
            node.page.set_row(cursor.y, row);
        }
    }

    fn cursor_forward(
        &mut self,
        cursor: &mut ReflowCursor,
        _cap: Capacity,
    ) -> Result<(), ResizeError> {
        if cursor.x + 1 >= self.cols {
            if let Some(node) = self.node_mut(cursor.node) {
                let mut row = node.page.row(cursor.y);
                row.set_wrap(true);
                node.page.set_row(cursor.y, row);
            }
            cursor.pending_wrap = true;
            cursor.x = self.cols.saturating_sub(1);
        } else {
            cursor.x += 1;
        }
        Ok(())
    }

    fn flush_reflow_pending_wrap(
        &mut self,
        cursor: &mut ReflowCursor,
        cap: Capacity,
    ) -> Result<(), ResizeError> {
        if cursor.pending_wrap {
            self.cursor_scroll_or_new_page(cursor, true, cap)?;
        }
        Ok(())
    }

    fn cursor_scroll(&mut self, cursor: &mut ReflowCursor, wrap_continuation: bool) {
        let Some(node) = self.node_mut(cursor.node) else {
            return;
        };
        let next_y = node.page.size().rows;
        node.page.set_size_rows(next_y.saturating_add(1));
        node.page.clear_row(next_y);
        let mut row = node.page.row(next_y);
        row.set_wrap_continuation(wrap_continuation);
        node.page.set_row(next_y, row);
        cursor.y = next_y;
        cursor.x = 0;
        cursor.pending_wrap = false;
        cursor.total_rows = cursor.total_rows.saturating_add(1);
    }

    fn cursor_new_page(
        &mut self,
        cursor: &mut ReflowCursor,
        wrap_continuation: bool,
        cap: Capacity,
    ) -> Result<(), ResizeError> {
        let id = self.create_reflow_page(cap);
        self.append_node(id);
        if let Some(node) = self.node_mut(id) {
            let mut row = node.page.row(0);
            row.set_wrap_continuation(wrap_continuation);
            node.page.set_row(0, row);
        }
        cursor.node = id;
        cursor.x = 0;
        cursor.y = 0;
        cursor.pending_wrap = false;
        cursor.total_rows = cursor.total_rows.saturating_add(1);
        Ok(())
    }

    fn cursor_scroll_or_new_page(
        &mut self,
        cursor: &mut ReflowCursor,
        wrap_continuation: bool,
        cap: Capacity,
    ) -> Result<(), ResizeError> {
        let Some(node) = self.node(cursor.node) else {
            return Err(ResizeError::OutOfSpace);
        };
        if node.page.size().rows < node.page.capacity().rows {
            self.cursor_scroll(cursor, wrap_continuation);
            Ok(())
        } else {
            self.cursor_new_page(cursor, wrap_continuation, cap)
        }
    }

    fn move_last_row_to_new_page(&mut self, cursor: &mut ReflowCursor) -> Result<(), ResizeError> {
        debug_assert!(!cursor.pending_wrap);
        let Some(current_node) = self.node(cursor.node) else {
            return Err(ResizeError::OutOfSpace);
        };
        let size = current_node.page.size();
        debug_assert_eq!(cursor.y, size.rows.saturating_sub(1));
        if size.rows == 0 {
            return Ok(());
        }
        let cap = current_node.page.capacity();
        let new_id = self.create_reflow_page(cap);
        if let Some((current_node, new_node)) = self.nodes_pair_mut(cursor.node, new_id) {
            new_node
                .page
                .clone_row_from_page(0, &current_node.page, size.rows - 1);
        }
        self.insert_after(cursor.node, new_id);
        if let Some(node) = self.node_mut(cursor.node) {
            node.page.set_size_rows(size.rows - 1);
        }
        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.node == cursor.node && pin.y == size.rows - 1 {
                pin.node = new_id;
                pin.y = 0;
            }
        }
        cursor.node = new_id;
        cursor.y = 0;
        Ok(())
    }

    fn reflow_write_cell(
        &mut self,
        cursor: &mut ReflowCursor,
        source: Pin,
        source_x: CellCountInt,
        snapshot: &CellSnapshot,
        cap: Capacity,
    ) -> Result<WriteCellResult, ResizeError> {
        self.flush_reflow_pending_wrap(cursor, cap)?;
        match snapshot.cell.wide() {
            CellWide::SpacerHead => Ok(WriteCellResult::Success),
            CellWide::SpacerTail if self.cols == 1 => Ok(WriteCellResult::Success),
            CellWide::Wide if self.cols == 1 => {
                let mut empty = CellSnapshot {
                    cell: Cell::default(),
                    style: None,
                    grapheme: None,
                    hyperlink: None,
                };
                empty.cell.set_wide(CellWide::Narrow);
                self.write_reflow_snapshot(cursor, &empty)?;
                self.remap_reflow_pin(source, source_x, *cursor);
                self.cursor_forward(cursor, cap)?;
                Ok(WriteCellResult::SkipNext)
            }
            CellWide::Wide if cursor.x == self.cols.saturating_sub(1) => {
                let mut spacer = CellSnapshot {
                    cell: Cell::default(),
                    style: None,
                    grapheme: None,
                    hyperlink: None,
                };
                spacer.cell.set_wide(CellWide::SpacerHead);
                self.write_reflow_snapshot(cursor, &spacer)?;
                self.cursor_forward(cursor, cap)?;
                Ok(WriteCellResult::Repeat)
            }
            CellWide::Wide => {
                let head_cursor = *cursor;
                self.write_reflow_snapshot(cursor, snapshot)?;
                self.remap_reflow_pin(source, source_x, head_cursor);
                self.cursor_forward(cursor, cap)?;

                let mut tail = CellSnapshot {
                    cell: Cell::default(),
                    style: None,
                    grapheme: None,
                    hyperlink: None,
                };
                tail.cell.set_wide(CellWide::SpacerTail);
                let tail_cursor = *cursor;
                self.write_reflow_snapshot(cursor, &tail)?;
                self.remap_reflow_pin(source, source_x.saturating_add(1), tail_cursor);
                self.cursor_forward(cursor, cap)?;
                Ok(WriteCellResult::SkipNext)
            }
            CellWide::Narrow | CellWide::SpacerTail => {
                let dst = *cursor;
                self.write_reflow_snapshot(cursor, snapshot)?;
                self.remap_reflow_pin(source, source_x, dst);
                self.cursor_forward(cursor, cap)?;
                Ok(WriteCellResult::Success)
            }
        }
    }

    fn write_reflow_snapshot(
        &mut self,
        cursor: &mut ReflowCursor,
        snapshot: &CellSnapshot,
    ) -> Result<(), ResizeError> {
        loop {
            let Some(node) = self.node_mut(cursor.node) else {
                return Err(ResizeError::OutOfSpace);
            };
            node.page
                .write_cell_unmanaged_snapshot_for_reflow(cursor.y, cursor.x, snapshot);
            match node
                .page
                .write_cell_managed_snapshot_for_reflow(cursor.y, cursor.x, snapshot)
            {
                Ok(()) => return Ok(()),
                Err(error) => match ReflowWriteError::from(error) {
                    ReflowWriteError::NeedCapacity(adjustment) => {
                        match self.increase_capacity(cursor.node, Some(adjustment)) {
                            Ok(id) => cursor.node = id,
                            Err(_) if cursor.y == 0 => return Ok(()),
                            Err(_) => {
                                self.move_last_row_to_new_page(cursor)?;
                            }
                        }
                    }
                },
            }
        }
    }

    fn remap_reflow_pin(&mut self, source: Pin, source_x: CellCountInt, cursor: ReflowCursor) {
        let cols = self.cols;
        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.node == source.node && pin.y == source.y && pin.x == source_x {
                pin.node = cursor.node;
                pin.y = cursor.y;
                pin.x = cursor.x.min(cols.saturating_sub(1));
            }
        }
    }

    fn remap_reflow_row_end_pins(&mut self, source: Pin, cursor: &ReflowCursor, len: CellCountInt) {
        let cols = self.cols;
        let dst_x = cursor.x.min(cols.saturating_sub(1));
        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.node == source.node && pin.y == source.y && pin.x >= len {
                pin.node = cursor.node;
                pin.y = cursor.y;
                pin.x = dst_x;
            }
        }
    }

    fn destroy_source_chain(&mut self, start: NodeId) {
        let mut current = Some(start);
        while let Some(id) = current {
            current = self.node(id).and_then(|node| node.next);
            self.destroy_node(id);
        }
    }

    pub fn resize_without_reflow(&mut self, opts: ResizeOptions) -> Result<(), ResizeError> {
        let old_min = self.min_max_size;
        let new_cols = opts.cols.unwrap_or(self.cols);
        let new_rows = opts.rows.unwrap_or(self.rows);
        if !opts.reflow {
            self.min_max_size = Self::min_max_size(new_cols, new_rows);
        }

        let result = (|| {
            if new_cols < self.cols {
                self.shrink_cols(new_cols);
            } else if new_cols > self.cols {
                self.grow_cols_without_reflow(new_cols)?;
            }

            if new_rows < self.rows {
                let delta = (self.rows - new_rows) as usize;
                let trimmed = self.trim_trailing_blank_rows(delta);
                self.total_rows = self.total_rows.saturating_sub(trimmed);
                self.rows = new_rows;
            } else if new_rows > self.rows {
                let delta = (new_rows - self.rows) as usize;
                let cursor_stays_in_active = opts
                    .cursor
                    .map(|cursor| cursor.y < self.rows.saturating_sub(1))
                    .unwrap_or(false);
                self.rows = new_rows;
                if cursor_stays_in_active {
                    for _ in 0..delta {
                        let _ = self.grow();
                    }
                } else if self.total_rows < self.rows as usize {
                    for _ in 0..self.rows as usize - self.total_rows {
                        let _ = self.grow();
                    }
                }
                if self.viewport == Viewport::Pin
                    && self
                        .tracked_pin(self.viewport_pin)
                        .map(|pin| self.pin_is_active(pin))
                        .unwrap_or(false)
                {
                    self.viewport = Viewport::Active;
                }
            }

            let _ = opts.reflow;
            Ok(())
        })();

        if result.is_err() {
            self.min_max_size = old_min;
        }
        result
    }

    pub fn compact(&mut self, id: NodeId) -> Option<NodeId> {
        let old_node = self.node(id)?;
        let old_memory_len = old_node.page.memory_len();
        if old_memory_len <= Self::standard_size() {
            return None;
        }
        let size = old_node.page.size();
        let cap = old_node.page.exact_row_capacity_range(0, size.rows);
        let old_dirty = old_node.page.page_dirty();
        if Page::layout(cap).total_size >= old_memory_len {
            return None;
        }

        let new_id = self.create_page(cap);
        if let Some((old_node, new_node)) = self.nodes_pair_mut(id, new_id) {
            new_node.page.set_size(size);
            new_node.page.clone_rows_from(&old_node.page, 0, size.rows);
            new_node.page.set_page_dirty(old_dirty);
        }
        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.node == id {
                pin.node = new_id;
            }
        }
        self.insert_before(id, new_id);
        self.remove_node(id);
        self.destroy_node(id);
        Some(new_id)
    }

    pub fn split(&mut self, pin: Pin) -> Result<NodeId, SplitError> {
        let split_pin = pin;
        let Some(old_node) = self.node(split_pin.node) else {
            return Err(SplitError::OutOfSpace);
        };
        let size = old_node.page.size();
        if size.rows <= 1 {
            return Err(SplitError::OutOfSpace);
        }
        if split_pin.y == 0 {
            return Ok(split_pin.node);
        }
        if split_pin.y >= size.rows {
            return Err(SplitError::OutOfSpace);
        }

        let capacity = old_node.page.capacity();
        let old_dirty = old_node.page.page_dirty();
        let new_id = self.create_page(capacity);
        let moved = size.rows - split_pin.y;
        if let Some((old_node, new_node)) = self.nodes_pair_mut(split_pin.node, new_id) {
            new_node.page.set_size(PageSize {
                cols: size.cols,
                rows: moved,
            });
            new_node
                .page
                .clone_rows_from(&old_node.page, split_pin.y, size.rows);
            new_node.page.set_page_dirty(old_dirty);
        }

        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.node == split_pin.node && pin.y >= split_pin.y {
                pin.node = new_id;
                pin.y -= split_pin.y;
            }
        }

        if let Some(node) = self.node_mut(split_pin.node) {
            for y in split_pin.y..size.rows {
                node.page.clear_row(y);
            }
            node.page.set_size_rows(split_pin.y);
        }
        self.insert_after(split_pin.node, new_id);
        Ok(new_id)
    }

    fn erase_row_at_pin(&mut self, pin: Pin) -> Result<(), CloneRowsError> {
        self.erase_row_at_pin_with_behavior(pin, true, true)
    }

    fn erase_row_at_pin_with_behavior(
        &mut self,
        pin: Pin,
        fixup_viewport: bool,
        strict_pin_shift: bool,
    ) -> Result<(), CloneRowsError> {
        let mut current = pin.node;
        if let Some(node) = self.node_mut(current) {
            let rows = node.page.size().rows;
            node.page.rotate_rows_left_once(pin.y, rows);
            node.page.set_page_dirty(true);
        }

        for tracked in self.tracked_pins.iter_mut().flatten() {
            if tracked.node == pin.node {
                let should_shift = if strict_pin_shift {
                    tracked.y > pin.y
                } else {
                    tracked.y >= pin.y
                };
                if should_shift {
                    if tracked.y == 0 {
                        tracked.x = 0;
                    } else {
                        tracked.y -= 1;
                    }
                }
            }
        }
        if fixup_viewport {
            self.fixup_viewport(1);
        }

        // Ghostty's cloneRowFrom can fail mid-cascade and propagate over pages
        // it has already shifted. The Rust page clone operations degrade
        // infallibly on capacity exhaustion, so this cascade cannot tear; the
        // Result is kept to match the ported API shape.
        while let Some(next) = self.node(current).and_then(|node| node.next) {
            {
                let (current_node, next_node) = self
                    .nodes_pair_mut(current, next)
                    .ok_or(CloneRowsError::OutOfSpace)?;
                let last_y = current_node.page.size().rows.saturating_sub(1);
                current_node
                    .page
                    .clone_row_from_page(last_y, &next_node.page, 0);
                let next_rows = next_node.page.size().rows;
                next_node.page.rotate_rows_left_once(0, next_rows);
                next_node.page.set_page_dirty(true);
            }
            let previous = current;
            let previous_last_y = self
                .node(previous)
                .map(|node| node.page.size().rows.saturating_sub(1))
                .unwrap_or(0);
            for tracked in self.tracked_pins.iter_mut().flatten() {
                if tracked.node == next {
                    if tracked.y == 0 {
                        tracked.node = previous;
                        tracked.y = previous_last_y;
                    } else {
                        tracked.y -= 1;
                    }
                }
            }
            current = next;
        }

        if let Some(node) = self.node_mut(current) {
            let last_y = node.page.size().rows.saturating_sub(1);
            node.page.clear_row(last_y);
        }
        Ok(())
    }

    fn erase_row_bounded_at_pin(&mut self, pin: Pin, limit: usize) -> Result<(), CloneRowsError> {
        if limit == 0 {
            if let Some(node) = self.node_mut(pin.node) {
                node.page.clear_row(pin.y);
                node.page.set_page_dirty(true);
            }
            for tracked in self.tracked_pins.iter_mut().flatten() {
                if tracked.node == pin.node && tracked.y == pin.y {
                    tracked.x = 0;
                }
            }
            return Ok(());
        }

        let Some(rows) = self
            .node(pin.node)
            .map(|node| node.page.size().rows as usize)
        else {
            return Ok(());
        };
        let local_remaining = rows.saturating_sub(pin.y as usize);
        if local_remaining > limit {
            let target_y = pin.y.saturating_add(limit as CellCountInt);
            if let Some(node) = self.node_mut(pin.node) {
                node.page
                    .rotate_rows_left_once(pin.y, target_y.saturating_add(1));
                // The erased row's header rotates to the region bottom; clear
                // it there so the former bottom row is not rotated away.
                node.page.clear_row(target_y);
                node.page.set_page_dirty(true);
            }
            self.adjust_viewport_cache_for_bounded_row(pin.node, pin.y, limit);
            self.shift_pins_for_bounded_row(pin.node, pin.y, limit);
            return Ok(());
        }

        let mut current = pin.node;
        let mut shifted = local_remaining;
        if let Some(node) = self.node_mut(current) {
            let rows = node.page.size().rows;
            node.page.rotate_rows_left_once(pin.y, rows);
            node.page.set_page_dirty(true);
        }
        if self.viewport == Viewport::Pin {
            let viewport_pin = self.tracked_pin(self.viewport_pin);
            if let (Some(pin_cache), Some(offset)) =
                (viewport_pin, self.viewport_pin_row_offset.as_mut())
            {
                if pin_cache.node == current && pin_cache.y >= pin.y && pin_cache.y != 0 {
                    *offset = offset.saturating_sub(1);
                }
            }
        }
        for tracked in self.tracked_pins.iter_mut().flatten() {
            if tracked.node == current && tracked.y >= pin.y {
                if tracked.y == 0 {
                    tracked.x = 0;
                } else {
                    tracked.y -= 1;
                }
            }
        }

        while let Some(next) = self.node(current).and_then(|node| node.next) {
            let next_rows = {
                let (current_node, next_node) = self
                    .nodes_pair_mut(current, next)
                    .ok_or(CloneRowsError::OutOfSpace)?;
                let last_y = current_node.page.size().rows.saturating_sub(1);
                current_node
                    .page
                    .clone_row_from_page(last_y, &next_node.page, 0);
                next_node.page.size().rows
            };
            let shifted_limit = limit.saturating_sub(shifted);
            if usize::from(next_rows) > shifted_limit {
                let shifted_limit_y = shifted_limit as CellCountInt;
                if let Some(node) = self.node_mut(next) {
                    node.page.clear_row(0);
                    node.page
                        .rotate_rows_left_once(0, shifted_limit_y.saturating_add(1));
                    node.page.set_page_dirty(true);
                }
                if self.viewport == Viewport::Pin {
                    let viewport_pin = self.tracked_pin(self.viewport_pin);
                    if let (Some(pin_cache), Some(offset)) =
                        (viewport_pin, self.viewport_pin_row_offset.as_mut())
                    {
                        if pin_cache.node == next && pin_cache.y <= shifted_limit_y {
                            *offset = offset.saturating_sub(1);
                        }
                    }
                }
                let previous = current;
                let previous_last_y = self
                    .node(previous)
                    .map(|node| node.page.size().rows.saturating_sub(1))
                    .unwrap_or(0);
                for tracked in self.tracked_pins.iter_mut().flatten() {
                    if tracked.node == next && tracked.y <= shifted_limit_y {
                        if tracked.y == 0 {
                            tracked.node = previous;
                            tracked.y = previous_last_y;
                        } else {
                            tracked.y -= 1;
                        }
                    }
                }
                return Ok(());
            }

            if let Some(node) = self.node_mut(next) {
                node.page.rotate_rows_left_once(0, next_rows);
                node.page.set_page_dirty(true);
            }
            shifted = shifted.saturating_add(next_rows as usize);
            if self.viewport == Viewport::Pin {
                let viewport_pin = self.tracked_pin(self.viewport_pin);
                if let (Some(pin_cache), Some(offset)) =
                    (viewport_pin, self.viewport_pin_row_offset.as_mut())
                {
                    if pin_cache.node == next {
                        *offset = offset.saturating_sub(1);
                    }
                }
            }
            let previous = current;
            let previous_last_y = self
                .node(previous)
                .map(|node| node.page.size().rows.saturating_sub(1))
                .unwrap_or(0);
            for tracked in self.tracked_pins.iter_mut().flatten() {
                if tracked.node == next {
                    if tracked.y == 0 {
                        tracked.node = previous;
                        tracked.y = previous_last_y;
                    } else {
                        tracked.y -= 1;
                    }
                }
            }
            current = next;
        }

        if let Some(node) = self.node_mut(current) {
            let last_y = node.page.size().rows.saturating_sub(1);
            node.page.clear_row(last_y);
        }
        Ok(())
    }

    fn erase_rows(&mut self, top_left: Point, bottom_left: Option<Point>) {
        let mut chunks = Vec::new();
        let mut iterator = self.page_iterator(Direction::RightDown, top_left, bottom_left);
        while let Some(chunk) = iterator.next(self) {
            chunks.push(chunk);
        }

        let mut erased = 0usize;
        for chunk in chunks {
            let Some(size) = self.node(chunk.node).map(|node| node.page.size()) else {
                continue;
            };
            let count = chunk.end.saturating_sub(chunk.start);
            if count == 0 {
                continue;
            }
            erased += count as usize;

            if chunk.start == 0 && chunk.end >= size.rows {
                if self.first == Some(chunk.node) && self.last == Some(chunk.node) {
                    let cols = self.cols;
                    if let Some(node) = self.node_mut(chunk.node) {
                        node.page.reinit();
                        node.page.set_size(PageSize { cols, rows: 0 });
                    }
                    break;
                }
                self.erase_page(chunk.node);
                continue;
            }

            let scroll_amount = size.rows.saturating_sub(chunk.end);
            if let Some(node) = self.node_mut(chunk.node) {
                for y in 0..scroll_amount {
                    let dst = chunk.start + y;
                    let src = chunk.end + y;
                    node.page.swap_rows(dst, src);
                    node.page.set_row_dirty(dst, true);
                }
                let new_rows = size.rows.saturating_sub(count);
                for y in new_rows..size.rows {
                    node.page.clear_row(y);
                }
                node.page.set_size_rows(new_rows);
            }
            for pin in self.tracked_pins.iter_mut().flatten() {
                if pin.node == chunk.node {
                    if pin.y >= chunk.end {
                        pin.y -= count;
                    } else if pin.y >= chunk.start {
                        pin.y = chunk.start;
                        pin.x = 0;
                    }
                }
            }
        }

        self.total_rows = self.total_rows.saturating_sub(erased);
        if top_left.tag() == Tag::Active {
            for _ in 0..erased {
                let _ = self.grow();
            }
        }
        self.fixup_viewport(erased);
    }

    fn erase_page(&mut self, id: NodeId) {
        let Some((prev, next)) = self.node(id).map(|node| (node.prev, node.next)) else {
            return;
        };
        if prev.is_none() && next.is_none() {
            return;
        }
        debug_assert!(prev.is_none() || next.is_none());
        let target = prev.or(next);
        if prev.is_none() {
            if let Some(next) = next {
                if let Some(next_serial) = self.node(next).map(|node| node.serial) {
                    self.page_serial_min = next_serial;
                }
            }
        }
        if let Some(target) = target {
            for pin in self.tracked_pins.iter_mut().flatten() {
                if pin.node == id {
                    pin.node = target;
                    pin.y = 0;
                    pin.x = 0;
                    pin.garbage = false;
                }
            }
        }
        self.remove_node(id);
        self.destroy_node(id);
    }

    fn adjust_viewport_cache_for_bounded_row(
        &mut self,
        node: NodeId,
        erased_y: CellCountInt,
        limit: usize,
    ) {
        if self.viewport != Viewport::Pin {
            return;
        }
        let Some(pin) = self.tracked_pin(self.viewport_pin) else {
            return;
        };
        if pin.node == node
            && pin.y >= erased_y
            && pin.y <= erased_y.saturating_add(limit as CellCountInt)
            && pin.y != 0
        {
            if let Some(offset) = &mut self.viewport_pin_row_offset {
                *offset = offset.saturating_sub(1);
            }
        }
    }

    fn shift_pins_for_bounded_row(&mut self, node: NodeId, erased_y: CellCountInt, limit: usize) {
        let end_y = erased_y.saturating_add(limit as CellCountInt);
        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.node == node && pin.y >= erased_y && pin.y <= end_y {
                if pin.y == 0 {
                    pin.x = 0;
                } else {
                    pin.y -= 1;
                }
            }
        }
    }

    fn shrink_cols(&mut self, cols: CellCountInt) {
        for id in self.iter_node_ids().collect::<Vec<_>>() {
            if let Some(node) = self.node_mut(id) {
                let size = node.page.size();
                for y in 0..size.rows {
                    node.page.clear_cells(y, cols, size.cols);
                }
                node.page.set_size_cols(cols);
            }
        }
        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.x >= cols {
                pin.x = cols.saturating_sub(1);
            }
        }
        self.cols = cols;
    }

    fn grow_cols_without_reflow(&mut self, cols: CellCountInt) -> Result<(), ResizeError> {
        let ids = self.iter_node_ids().collect::<Vec<_>>();
        for id in ids {
            let Some(node) = self.node(id) else {
                continue;
            };
            let size = node.page.size();
            let cap = node.page.capacity();
            let previous = node.prev;
            let page_dirty = node.page.page_dirty();
            let has_spacer_head_at_old_edge = size.cols > 0
                && (0..size.rows).any(|y| {
                    matches!(
                        node.page.cell(y, size.cols - 1).wide(),
                        CellWide::SpacerHead
                    )
                });
            if cap.cols >= cols && !has_spacer_head_at_old_edge {
                if let Some(node) = self.node_mut(id) {
                    node.page.set_size_cols(cols);
                }
                continue;
            }

            let new_cap = Page::adjust(cap, cols);
            let mut start: CellCountInt = 0;
            let mut insert_after_id = previous;

            if let Some(prev_id) = previous {
                let spare = self
                    .node(prev_id)
                    .map(|prev| {
                        let prev_size = prev.page.size();
                        if prev.page.capacity().cols == cols
                            && prev.page.capacity().rows > prev_size.rows
                        {
                            prev.page.capacity().rows - prev_size.rows
                        } else {
                            0
                        }
                    })
                    .unwrap_or(0);
                let take = spare.min(size.rows);
                if take > 0 {
                    let prev_start = self
                        .node(prev_id)
                        .map(|prev| prev.page.size().rows)
                        .unwrap_or(0);
                    if let Some((source, prev)) = self.nodes_pair_mut(id, prev_id) {
                        prev.page.set_size_rows(prev_start + take);
                        for offset in 0..take {
                            prev.page.clone_row_from_page(
                                prev_start + offset,
                                &source.page,
                                offset,
                            );
                            Self::sanitize_grown_row(
                                &mut prev.page,
                                prev_start + offset,
                                size.cols,
                            );
                        }
                    }
                    self.retarget_pins_between(id, 0, take, prev_id, prev_start, cols);
                    start = take;
                    insert_after_id = Some(prev_id);
                }
            }

            while start < size.rows {
                let take = new_cap.rows.min(size.rows - start);
                let new_id = self.create_page(new_cap);
                if let Some((source, new_node)) = self.nodes_pair_mut(id, new_id) {
                    new_node.page.set_size(PageSize { cols, rows: take });
                    new_node
                        .page
                        .clone_rows_from(&source.page, start, start + take);
                    new_node.page.set_page_dirty(page_dirty);
                    for offset in 0..take {
                        Self::sanitize_grown_row(&mut new_node.page, offset, size.cols);
                    }
                }
                self.retarget_pins_between(id, start, start + take, new_id, 0, cols);
                if let Some(after) = insert_after_id {
                    self.insert_after(after, new_id);
                } else {
                    self.insert_before(id, new_id);
                }
                insert_after_id = Some(new_id);
                start += take;
            }

            self.remove_node(id);
            self.destroy_node(id);
        }
        self.cols = cols;
        Ok(())
    }

    fn sanitize_grown_row(page: &mut Page, y: CellCountInt, old_cols: CellCountInt) {
        if old_cols == 0 || old_cols > page.size().cols {
            return;
        }
        let edge = old_cols - 1;
        if matches!(page.cell(y, edge).wide(), CellWide::SpacerHead) {
            page.clear_cells(y, edge, edge.saturating_add(1));
            let mut row = page.row(y);
            row.set_wrap(false);
            page.set_row(y, row);
        }
    }

    fn retarget_pins_between(
        &mut self,
        source_node: NodeId,
        source_start: CellCountInt,
        source_end: CellCountInt,
        target_node: NodeId,
        target_start: CellCountInt,
        cols: CellCountInt,
    ) {
        for pin in self.tracked_pins.iter_mut().flatten() {
            if pin.node == source_node && pin.y >= source_start && pin.y < source_end {
                pin.node = target_node;
                pin.y = target_start + (pin.y - source_start);
                if pin.x >= cols {
                    pin.x = cols.saturating_sub(1);
                }
            }
        }
    }

    fn trim_trailing_blank_rows(&mut self, limit: usize) -> usize {
        let mut trimmed = 0usize;
        while trimmed < limit {
            let Some(last) = self.last else {
                break;
            };
            let Some(size) = self.node(last).map(|node| node.page.size()) else {
                break;
            };
            if size.rows == 0 {
                break;
            }
            let y = size.rows - 1;
            let has_text = self
                .node(last)
                .map(|node| node.page.has_text_any(y))
                .unwrap_or(false);
            let has_pin = self
                .tracked_pins
                .iter()
                .flatten()
                .any(|pin| pin.node == last && pin.y == y);
            if has_text || has_pin {
                break;
            }
            if let Some(node) = self.node_mut(last) {
                node.page.clear_row(y);
                node.page.set_size_rows(y);
            }
            trimmed += 1;
            if y == 0 && self.first != self.last {
                self.erase_page(last);
            }
        }
        trimmed
    }

    pub fn page_iterator(
        &self,
        direction: Direction,
        top_left: Point,
        bottom_left: Option<Point>,
    ) -> PageIterator {
        let Some(top_left_pin) = self.pin(top_left) else {
            return PageIterator::empty(direction);
        };
        let Some(bottom_left_pin) = bottom_left
            .and_then(|point| self.pin(point))
            .or_else(|| self.get_bottom_right(top_left.tag()))
        else {
            return PageIterator::empty(direction);
        };
        match direction {
            Direction::RightDown => PageIterator::row(top_left_pin, direction, bottom_left_pin),
            Direction::LeftUp => PageIterator::row(bottom_left_pin, direction, top_left_pin),
        }
    }

    pub fn row_iterator(
        &self,
        direction: Direction,
        top_left: Point,
        bottom_left: Option<Point>,
    ) -> RowIterator {
        let mut page_iterator = self.page_iterator(direction, top_left, bottom_left);
        RowIterator::new(self, &mut page_iterator)
    }

    pub fn cell_iterator(
        &self,
        direction: Direction,
        top_left: Point,
        bottom_left: Option<Point>,
    ) -> CellIterator {
        let mut row_iterator = self.row_iterator(direction, top_left, bottom_left);
        CellIterator::new(self, &mut row_iterator)
    }

    pub fn prompt_iterator(
        &self,
        direction: Direction,
        top_left: Point,
        bottom_left: Option<Point>,
    ) -> PromptIterator {
        let Some(top_left_pin) = self.pin(top_left) else {
            return PromptIterator::empty(direction);
        };
        let Some(bottom_left_pin) = bottom_left
            .and_then(|point| self.pin(point))
            .or_else(|| self.get_bottom_right(top_left.tag()))
        else {
            return PromptIterator::empty(direction);
        };
        match direction {
            Direction::RightDown => self.prompt_iterator_from_pin(
                top_left_pin,
                Direction::RightDown,
                Some(bottom_left_pin),
            ),
            Direction::LeftUp => self.prompt_iterator_from_pin(
                bottom_left_pin,
                Direction::LeftUp,
                Some(top_left_pin),
            ),
        }
    }

    fn prompt_iterator_from_pin(
        &self,
        current: Pin,
        direction: Direction,
        limit: Option<Pin>,
    ) -> PromptIterator {
        let _ = self;
        PromptIterator {
            current: Some(current),
            limit,
            direction,
        }
    }

    fn init_pages(&mut self) {
        let cap = Self::initial_capacity(self.cols);
        let mut remaining = self.rows as usize;
        while remaining > 0 {
            let id = self.create_page(cap);
            let rows = remaining.min(cap.rows as usize) as CellCountInt;
            if let Some(node) = self.node_mut(id) {
                node.page.set_size_rows(rows);
            }
            self.append_node(id);
            self.total_rows += rows as usize;
            remaining -= rows as usize;
        }
        if self.first.is_none() {
            let id = self.create_page(cap);
            if let Some(node) = self.node_mut(id) {
                node.page.set_size_rows(1);
            }
            self.append_node(id);
            self.total_rows = 1;
        }
    }

    fn destroy_all_nodes(&mut self) {
        let ids: Vec<NodeId> = self.iter_node_ids().collect();
        self.first = None;
        self.last = None;
        for id in ids {
            self.destroy_node(id);
        }
        self.total_rows = 0;
    }

    fn create_page(&mut self, cap: Capacity) -> NodeId {
        let layout = Page::layout(cap);
        debug_assert!(layout.total_size <= crate::size::MAX_PAGE_SIZE);
        let memory = if layout.total_size == Self::standard_size() {
            self.page_buffers
                .pop()
                .map(|mut buffer| {
                    buffer.fill(0);
                    buffer
                })
                .unwrap_or_else(|| vec![0; layout.total_size])
        } else {
            vec![0; layout.total_size]
        };
        self.page_size += memory.len();
        let mut page = Page::init_buf(memory, layout);
        page.set_size_rows(0);
        let serial = self.page_serial;
        self.page_serial = self.page_serial.saturating_add(1);
        self.allocate_node(PageNode {
            prev: None,
            next: None,
            page,
            serial,
        })
    }

    fn allocate_node(&mut self, node: PageNode) -> NodeId {
        if let Some(index) = self.free_nodes.pop() {
            let generation = match self.nodes.get(index as usize) {
                Some(NodeSlot::Free { generation }) => *generation,
                _ => 0,
            };
            self.nodes[index as usize] = NodeSlot::Occupied {
                generation,
                node: Box::new(node),
            };
            return NodeId { index, generation };
        }

        let index = self.nodes.len() as u32;
        let generation = 0;
        self.nodes.push(NodeSlot::Occupied {
            generation,
            node: Box::new(node),
        });
        NodeId { index, generation }
    }

    fn destroy_node(&mut self, id: NodeId) {
        let Some(node) = self.take_node(id) else {
            return;
        };
        let memory = node.page.into_memory();
        self.page_size = self.page_size.saturating_sub(memory.len());
        if memory.len() == Self::standard_size() && self.page_buffers.len() < PAGE_POOL_MAX {
            // Recycled buffers are zeroed once at reuse time in create_page; zeroing
            // again on return would double the memset traffic on the scroll hot path.
            // Cap retained buffers so clearing deep history releases memory.
            self.page_buffers.push(memory);
        }
    }

    fn take_node(&mut self, id: NodeId) -> Option<PageNode> {
        let slot = self.nodes.get_mut(id.index as usize)?;
        let replacement = match slot {
            NodeSlot::Occupied { generation, .. } if *generation == id.generation => {
                NodeSlot::Free {
                    generation: generation.saturating_add(1),
                }
            }
            _ => return None,
        };
        let old = std::mem::replace(slot, replacement);
        self.free_nodes.push(id.index);
        match old {
            NodeSlot::Occupied { node, .. } => Some(*node),
            NodeSlot::Free { .. } => None,
        }
    }

    pub(crate) fn node(&self, id: NodeId) -> Option<&PageNode> {
        match self.nodes.get(id.index as usize) {
            Some(NodeSlot::Occupied { generation, node }) if *generation == id.generation => {
                Some(node)
            }
            _ => None,
        }
    }

    pub(crate) fn node_mut(&mut self, id: NodeId) -> Option<&mut PageNode> {
        match self.nodes.get_mut(id.index as usize) {
            Some(NodeSlot::Occupied { generation, node }) if *generation == id.generation => {
                Some(node)
            }
            _ => None,
        }
    }

    /// Disjoint mutable borrows of two live arena nodes. Full generational
    /// IDs are checked so recycled indices cannot alias stale callers.
    pub(crate) fn nodes_pair_mut(
        &mut self,
        a: NodeId,
        b: NodeId,
    ) -> Option<(&mut PageNode, &mut PageNode)> {
        if a == b {
            return None;
        }
        let a_index = a.index as usize;
        let b_index = b.index as usize;
        let (a_slot, b_slot) = if a_index < b_index {
            let (left, right) = self.nodes.split_at_mut(b_index);
            (left.get_mut(a_index)?, right.first_mut()?)
        } else {
            let (left, right) = self.nodes.split_at_mut(a_index);
            (right.first_mut()?, left.get_mut(b_index)?)
        };
        let a_node = match a_slot {
            NodeSlot::Occupied { generation, node } if *generation == a.generation => node,
            _ => return None,
        };
        let b_node = match b_slot {
            NodeSlot::Occupied { generation, node } if *generation == b.generation => node,
            _ => return None,
        };
        Some((a_node, b_node))
    }

    fn node_rows(&self, id: NodeId) -> Option<CellCountInt> {
        self.node(id).map(|node| node.page.size().rows)
    }

    fn first_or_panic(&self) -> NodeId {
        match self.first {
            Some(id) => id,
            None => panic!("PageList has no first node"),
        }
    }

    fn last_or_panic(&self) -> NodeId {
        match self.last {
            Some(id) => id,
            None => panic!("PageList has no last node"),
        }
    }

    fn append_node(&mut self, id: NodeId) {
        let old_last = self.last;
        if let Some(node) = self.node_mut(id) {
            node.prev = old_last;
            node.next = None;
        }
        if let Some(last) = old_last {
            if let Some(node) = self.node_mut(last) {
                node.next = Some(id);
            }
        } else {
            self.first = Some(id);
        }
        self.last = Some(id);
    }

    fn prepend_node(&mut self, id: NodeId) {
        let old_first = self.first;
        if let Some(node) = self.node_mut(id) {
            node.prev = None;
            node.next = old_first;
        }
        if let Some(first) = old_first {
            if let Some(node) = self.node_mut(first) {
                node.prev = Some(id);
            }
        } else {
            self.last = Some(id);
        }
        self.first = Some(id);
    }

    fn insert_after(&mut self, after: NodeId, id: NodeId) {
        let next = self.node(after).and_then(|node| node.next);
        if let Some(node) = self.node_mut(id) {
            node.prev = Some(after);
            node.next = next;
        }
        if let Some(node) = self.node_mut(after) {
            node.next = Some(id);
        }
        if let Some(next_id) = next {
            if let Some(node) = self.node_mut(next_id) {
                node.prev = Some(id);
            }
        } else {
            self.last = Some(id);
        }
    }

    fn insert_before(&mut self, before: NodeId, id: NodeId) {
        let prev = self.node(before).and_then(|node| node.prev);
        if let Some(node) = self.node_mut(id) {
            node.prev = prev;
            node.next = Some(before);
        }
        if let Some(prev_id) = prev {
            if let Some(node) = self.node_mut(prev_id) {
                node.next = Some(id);
            }
        } else {
            self.first = Some(id);
        }
        if let Some(node) = self.node_mut(before) {
            node.prev = Some(id);
        }
    }

    fn remove_node(&mut self, id: NodeId) {
        let Some((prev, next)) = self.node(id).map(|node| (node.prev, node.next)) else {
            return;
        };
        if let Some(prev) = prev {
            if let Some(prev_node) = self.node_mut(prev) {
                prev_node.next = next;
            }
        } else {
            self.first = next;
        }
        if let Some(next) = next {
            if let Some(next_node) = self.node_mut(next) {
                next_node.prev = prev;
            }
        } else {
            self.last = prev;
        }
        if let Some(removed) = self.node_mut(id) {
            removed.prev = None;
            removed.next = None;
        }
    }

    fn pop_first(&mut self) -> Option<NodeId> {
        let first = self.first?;
        self.remove_node(first);
        Some(first)
    }

    fn iter_node_ids(&self) -> NodeIdIterator<'_> {
        NodeIdIterator {
            list: self,
            next: self.first,
        }
    }
}

fn write_snapshots_to_row(page: &mut Page, y: CellCountInt, snapshots: &[CellSnapshot]) {
    if y >= page.size().rows {
        return;
    }
    page.clear_row(y);
    let cols = page.size().cols as usize;
    for (x, snapshot) in snapshots.iter().take(cols).enumerate() {
        let _ = page.write_cell_snapshot(y, x as CellCountInt, snapshot);
    }
}

struct NodeIdIterator<'a> {
    list: &'a PageList,
    next: Option<NodeId>,
}

impl Iterator for NodeIdIterator<'_> {
    type Item = NodeId;

    fn next(&mut self) -> Option<Self::Item> {
        let current = self.next?;
        self.next = self.list.node(current).and_then(|node| node.next);
        Some(current)
    }
}

fn double_or_max<T>(value: T) -> Option<T>
where
    T: Copy + Eq + Ord + std::ops::Mul<Output = T> + From<u8> + BoundedMax,
{
    if value == T::max_value() {
        return None;
    }
    value.checked_mul_two().or_else(|| Some(T::max_value()))
}

trait BoundedMax {
    fn max_value() -> Self;
    fn checked_mul_two(self) -> Option<Self>
    where
        Self: Sized;
}

impl BoundedMax for u16 {
    fn max_value() -> Self {
        u16::MAX
    }

    fn checked_mul_two(self) -> Option<Self> {
        self.checked_mul(2)
    }
}

impl BoundedMax for u32 {
    fn max_value() -> Self {
        u32::MAX
    }

    fn checked_mul_two(self) -> Option<Self> {
        self.checked_mul(2)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PageIteratorLimit {
    None,
    Row(Pin),
    // Ghostty has a `.count` limb here, but the T5a port intentionally does
    // not include it: upstream marks the count limb as dead/internal-buggy
    // around PageList.zig:4811 and PageList.zig:4891.
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Chunk {
    pub node: NodeId,
    pub start: CellCountInt,
    pub end: CellCountInt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PageIterator {
    row: Option<Pin>,
    limit: PageIteratorLimit,
    direction: Direction,
}

impl PageIterator {
    fn empty(direction: Direction) -> Self {
        Self {
            row: None,
            limit: PageIteratorLimit::None,
            direction,
        }
    }

    fn row(row: Pin, direction: Direction, limit: Pin) -> Self {
        Self {
            row: Some(row),
            limit: PageIteratorLimit::Row(limit),
            direction,
        }
    }

    pub fn next(&mut self, list: &PageList) -> Option<Chunk> {
        match self.direction {
            Direction::RightDown => self.next_down(list),
            Direction::LeftUp => self.next_up(list),
        }
    }

    fn next_down(&mut self, list: &PageList) -> Option<Chunk> {
        let row = self.row?;
        match self.limit {
            PageIteratorLimit::None => {
                let node = list.node(row.node)?;
                self.row = node.next.map(Pin::new);
                Some(Chunk {
                    node: row.node,
                    start: row.y,
                    end: node.page.size().rows,
                })
            }
            PageIteratorLimit::Row(limit) => {
                let node = list.node(row.node)?;
                if limit.node != row.node {
                    self.row = node.next.map(Pin::new);
                    return Some(Chunk {
                        node: row.node,
                        start: row.y,
                        end: node.page.size().rows,
                    });
                }
                self.row = None;
                if row.y > limit.y {
                    return None;
                }
                Some(Chunk {
                    node: row.node,
                    start: row.y,
                    end: limit.y.saturating_add(1),
                })
            }
        }
    }

    fn next_up(&mut self, list: &PageList) -> Option<Chunk> {
        let row = self.row?;
        match self.limit {
            PageIteratorLimit::None => {
                let node = list.node(row.node)?;
                self.row = node.prev.and_then(|prev| {
                    list.node(prev).map(|previous| Pin {
                        node: prev,
                        y: previous.page.size().rows.saturating_sub(1),
                        x: 0,
                        garbage: false,
                    })
                });
                Some(Chunk {
                    node: row.node,
                    start: 0,
                    end: row.y.saturating_add(1),
                })
            }
            PageIteratorLimit::Row(limit) => {
                let node = list.node(row.node)?;
                if limit.node != row.node {
                    self.row = node.prev.and_then(|prev| {
                        list.node(prev).map(|previous| Pin {
                            node: prev,
                            y: previous.page.size().rows.saturating_sub(1),
                            x: 0,
                            garbage: false,
                        })
                    });
                    return Some(Chunk {
                        node: row.node,
                        start: 0,
                        end: row.y.saturating_add(1),
                    });
                }
                self.row = None;
                if row.y < limit.y {
                    return None;
                }
                Some(Chunk {
                    node: row.node,
                    start: limit.y,
                    end: row.y.saturating_add(1),
                })
            }
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RowIterator {
    page_iterator: PageIterator,
    chunk: Option<Chunk>,
    offset: CellCountInt,
}

impl RowIterator {
    fn new(list: &PageList, page_iterator: &mut PageIterator) -> Self {
        let chunk = page_iterator.next(list);
        let offset = match (page_iterator.direction, chunk) {
            (_, None) => 0,
            (Direction::RightDown, Some(chunk)) => chunk.start,
            (Direction::LeftUp, Some(chunk)) => chunk.end.saturating_sub(1),
        };
        Self {
            page_iterator: *page_iterator,
            chunk,
            offset,
        }
    }

    pub fn next(&mut self, list: &PageList) -> Option<Pin> {
        let chunk = self.chunk?;
        let row = Pin {
            node: chunk.node,
            y: self.offset,
            x: 0,
            garbage: false,
        };

        match self.page_iterator.direction {
            Direction::RightDown => {
                self.offset = self.offset.saturating_add(1);
                if self.offset >= chunk.end {
                    self.chunk = self.page_iterator.next(list);
                    if let Some(next) = self.chunk {
                        self.offset = next.start;
                    }
                }
            }
            Direction::LeftUp => {
                if self.offset == 0 {
                    self.chunk = self.page_iterator.next(list);
                    if let Some(next) = self.chunk {
                        self.offset = next.end.saturating_sub(1);
                    }
                } else if self.offset == chunk.start {
                    self.chunk = None;
                } else {
                    self.offset -= 1;
                }
            }
        }
        Some(row)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellIterator {
    row_iterator: RowIterator,
    cell: Option<Pin>,
}

impl CellIterator {
    fn new(list: &PageList, row_iterator: &mut RowIterator) -> Self {
        let mut cell = row_iterator.next(list);
        if matches!(row_iterator.page_iterator.direction, Direction::LeftUp) {
            if let Some(pin) = &mut cell {
                pin.x = list
                    .node(pin.node)
                    .map(|node| node.page.size().cols.saturating_sub(1))
                    .unwrap_or(0);
            }
        }
        Self {
            row_iterator: *row_iterator,
            cell,
        }
    }

    pub fn next(&mut self, list: &PageList) -> Option<Pin> {
        let cell = self.cell?;
        match self.row_iterator.page_iterator.direction {
            Direction::RightDown => {
                let cols = list
                    .node(cell.node)
                    .map(|node| node.page.size().cols)
                    .unwrap_or(0);
                if cell.x + 1 < cols {
                    self.cell = Some(Pin {
                        x: cell.x + 1,
                        ..cell
                    });
                } else {
                    self.cell = self.row_iterator.next(list);
                }
            }
            Direction::LeftUp => {
                if cell.x > 0 {
                    self.cell = Some(Pin {
                        x: cell.x - 1,
                        ..cell
                    });
                } else if let Some(mut next_row) = self.row_iterator.next(list) {
                    let cols = list
                        .node(next_row.node)
                        .map(|node| node.page.size().cols)
                        .unwrap_or(1);
                    next_row.x = cols.saturating_sub(1);
                    self.cell = Some(next_row);
                } else {
                    self.cell = None;
                }
            }
        }
        Some(cell)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PromptIterator {
    current: Option<Pin>,
    limit: Option<Pin>,
    direction: Direction,
}

impl PromptIterator {
    fn empty(direction: Direction) -> Self {
        Self {
            current: None,
            limit: None,
            direction,
        }
    }

    pub fn next(&mut self, list: &PageList) -> Option<Pin> {
        match self.direction {
            Direction::RightDown => self.next_right_down(list),
            Direction::LeftUp => self.next_left_up(list),
        }
    }

    fn next_right_down(&mut self, list: &PageList) -> Option<Pin> {
        let mut current = self.current?;
        loop {
            let at_limit = self.limit.map(|limit| limit.eql(current)).unwrap_or(false);
            match list
                .row_and_cell(current)
                .map(|(row, _)| row.semantic_prompt())
                .unwrap_or(SemanticPrompt::None)
            {
                SemanticPrompt::None => {
                    if at_limit {
                        self.current = None;
                        return None;
                    }
                }
                SemanticPrompt::Prompt | SemanticPrompt::PromptContinuation => {
                    if at_limit {
                        self.current = None;
                        return Some(current.left(current.x as usize));
                    }
                    let prompt = current.left(current.x as usize);
                    let mut end = current;
                    while let Some(next) = list.pin_down(end, 1) {
                        if self.limit.map(|limit| limit.eql(next)).unwrap_or(false) {
                            break;
                        }
                        match list
                            .row_and_cell(next)
                            .map(|(row, _)| row.semantic_prompt())
                            .unwrap_or(SemanticPrompt::None)
                        {
                            SemanticPrompt::PromptContinuation => end = next,
                            SemanticPrompt::Prompt | SemanticPrompt::None => {
                                self.current = Some(next);
                                return Some(prompt);
                            }
                        }
                    }
                    self.current = None;
                    return Some(prompt);
                }
            }
            let Some(next) = list.pin_down(current, 1) else {
                self.current = None;
                return None;
            };
            current = next;
        }
    }

    fn next_left_up(&mut self, list: &PageList) -> Option<Pin> {
        let mut current = self.current?;
        loop {
            let at_limit = self.limit.map(|limit| limit.eql(current)).unwrap_or(false);
            match list
                .row_and_cell(current)
                .map(|(row, _)| row.semantic_prompt())
                .unwrap_or(SemanticPrompt::None)
            {
                SemanticPrompt::None => {
                    if at_limit {
                        self.current = None;
                        return None;
                    }
                }
                SemanticPrompt::Prompt => {
                    self.current = if at_limit {
                        None
                    } else {
                        list.pin_up(current, 1)
                    };
                    return Some(current.left(current.x as usize));
                }
                SemanticPrompt::PromptContinuation => {
                    if at_limit {
                        self.current = None;
                        return Some(current.left(current.x as usize));
                    }
                    let mut end = current;
                    while let Some(prior) = list.pin_up(end, 1) {
                        if self.limit.map(|limit| limit.eql(prior)).unwrap_or(false) {
                            break;
                        }
                        match list
                            .row_and_cell(prior)
                            .map(|(row, _)| row.semantic_prompt())
                            .unwrap_or(SemanticPrompt::None)
                        {
                            SemanticPrompt::None => {
                                self.current = Some(prior);
                                return Some(end.left(end.x as usize));
                            }
                            SemanticPrompt::PromptContinuation => end = prior,
                            SemanticPrompt::Prompt => {
                                self.current = list.pin_up(prior, 1);
                                return Some(prior.left(prior.x as usize));
                            }
                        }
                    }
                    self.current = None;
                    return Some(current.left(current.x as usize));
                }
            }
            let Some(prior) = list.pin_up(current, 1) else {
                self.current = None;
                return None;
            };
            current = prior;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::Rgb;
    use crate::page::{GRAPHEME_CHUNK_LEN, GRAPHEME_MAX_PER_CELL};
    use crate::style::{PackedStyle, Style, StyleColor};

    fn cap_with_rows_below(rows: CellCountInt) -> Capacity {
        let mut cols: CellCountInt = 50;
        loop {
            let cap = PageList::initial_capacity(cols);
            if cap.rows < rows {
                return cap;
            }
            cols = cols.saturating_add(50);
        }
    }

    fn node_rows(list: &PageList, id: NodeId) -> CellCountInt {
        list.node_page_size(id).map(|size| size.rows).unwrap_or(0)
    }

    fn grow_until_second_page(list: &mut PageList) -> (NodeId, NodeId) {
        let first = list.last_node().unwrap();
        let cap_rows = list.node_capacity(first).unwrap().rows;
        while node_rows(list, first) < cap_rows {
            assert_eq!(list.grow(), None);
        }
        let second = list.grow().unwrap();
        (first, second)
    }

    fn grow_by_standard_page_multiples(list: &mut PageList, multiples: usize) {
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        list.grow_rows(cap_rows * multiples);
    }

    fn set_screen_cell(list: &mut PageList, x: CellCountInt, y: u32, ch: char) {
        assert!(list.set_cell(Point::screen(x, y), Cell::new(ch)));
    }

    fn set_screen_wide_pair(list: &mut PageList, x: CellCountInt, y: u32, ch: char) {
        let pin = list.pin(Point::screen(x, y)).unwrap();
        let Some(node) = list.node_mut(pin.node) else {
            return;
        };
        let mut wide = Cell::new(ch);
        wide.set_wide(CellWide::Wide);
        node.page.set_cell(pin.y, pin.x, wide);
        if pin.x + 1 < node.page.size().cols {
            let mut tail = Cell::default();
            tail.set_wide(CellWide::SpacerTail);
            node.page.set_cell(pin.y, pin.x + 1, tail);
        }
    }

    fn set_screen_spacer_head(list: &mut PageList, x: CellCountInt, y: u32) {
        let pin = list.pin(Point::screen(x, y)).unwrap();
        let Some(node) = list.node_mut(pin.node) else {
            return;
        };
        let mut head = Cell::default();
        head.set_wide(CellWide::SpacerHead);
        node.page.set_cell(pin.y, pin.x, head);
    }

    fn set_screen_row_cells(list: &mut PageList, y: u32, chars: &[char]) {
        for (x, ch) in chars.iter().copied().enumerate() {
            set_screen_cell(list, x as CellCountInt, y, ch);
        }
    }

    fn set_screen_row_wrap(list: &mut PageList, y: u32, wrap: bool, continuation: bool) {
        let pin = list.pin(Point::screen(0, y)).unwrap();
        let Some(node) = list.node_mut(pin.node) else {
            return;
        };
        let mut row = node.page.row(pin.y);
        row.set_wrap(wrap);
        row.set_wrap_continuation(continuation);
        node.page.set_row(pin.y, row);
    }

    fn set_screen_row_prompt(list: &mut PageList, y: u32, prompt: SemanticPrompt) {
        let pin = list.pin(Point::screen(0, y)).unwrap();
        let Some(node) = list.node_mut(pin.node) else {
            return;
        };
        let mut row = node.page.row(pin.y);
        row.set_semantic_prompt(prompt);
        node.page.set_row(pin.y, row);
    }

    fn active_row(list: &PageList, y: u32) -> Row {
        let pin = list.pin(Point::active(0, y)).unwrap();
        list.node(pin.node).unwrap().page.row(pin.y)
    }

    fn active_cell(list: &PageList, x: CellCountInt, y: u32) -> Cell {
        list.get_cell(Point::active(x, y)).unwrap()
    }

    fn attach_largest_fitting_hyperlink(
        list: &mut PageList,
        id: NodeId,
        y: CellCountInt,
        x: CellCountInt,
        implicit_id: u32,
    ) -> usize {
        let mut len = list
            .node_capacity(id)
            .map(|cap| (cap.string_bytes as usize).saturating_sub(1))
            .unwrap_or(1)
            .max(1);
        loop {
            let uri = vec![b'a'; len];
            let Some(node) = list.node_mut(id) else {
                return 0;
            };
            if node
                .page
                .set_hyperlink_implicit(y, x, implicit_id, &uri)
                .is_ok()
            {
                return len;
            }
            len /= 2;
            assert!(len > 0, "test could not fit even a small hyperlink");
        }
    }

    fn append_graphemes(
        list: &mut PageList,
        id: NodeId,
        y: CellCountInt,
        x: CellCountInt,
        count: usize,
        start: u32,
    ) {
        let node = list.node_mut(id).unwrap();
        for offset in 0..count {
            node.page
                .append_grapheme(y, x, start + offset as u32)
                .unwrap();
        }
    }

    fn set_style_growing(
        list: &mut PageList,
        mut id: NodeId,
        y: CellCountInt,
        x: CellCountInt,
        style: PackedStyle,
    ) -> NodeId {
        loop {
            let Some(node) = list.node_mut(id) else {
                return id;
            };
            if node.page.set_style(y, x, style).is_ok() {
                return id;
            }
            id = list
                .increase_capacity(id, Some(IncreaseCapacity::Styles))
                .unwrap();
        }
    }

    fn screen_cell(list: &PageList, x: CellCountInt, y: u32) -> Cell {
        list.get_cell(Point::screen(x, y)).unwrap()
    }

    fn node_cell(list: &PageList, id: NodeId, y: CellCountInt, x: CellCountInt) -> Cell {
        list.node(id).unwrap().page.cell(y, x)
    }

    fn write_node_row_marker(list: &mut PageList, id: NodeId, y: CellCountInt, ch: char) {
        if let Some(node) = list.node_mut(id) {
            node.page.set_cell(y, 0, Cell::new(ch));
        }
    }

    fn fill_all_rows_text(list: &mut PageList, ch: char) {
        let ids = list.iter_node_ids().collect::<Vec<_>>();
        for id in ids {
            let size = list.node_page_size(id).unwrap();
            if let Some(node) = list.node_mut(id) {
                for y in 0..size.rows {
                    node.page.set_cell(y, 0, Cell::new(ch));
                }
            }
        }
    }

    fn assert_all_rows_have_cols(list: &PageList, cols: CellCountInt) {
        for id in list.iter_node_ids() {
            let node = list.node(id).unwrap();
            assert_eq!(node.page.size().cols, cols);
        }
    }

    #[test]
    fn page_list_initializes_active_viewport() {
        // ghostty: "PageList" (PageList.zig:5579)
        let mut list = PageList::new(80, 24, None);
        assert_eq!(list.viewport(), Viewport::Active);
        assert_eq!(list.total_rows(), 24);
        assert_eq!(
            list.tracked_pin(list.viewport_pin_id()).unwrap().node,
            list.first_node().unwrap()
        );
        assert_eq!(
            list.get_top_left(Tag::Active),
            Pin::new(list.first_node().unwrap())
        );
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: 24,
                offset: 0,
                len: 24
            }
        );
    }

    #[test]
    fn init_rows_across_two_pages() {
        // ghostty: "PageList init rows across two pages" (PageList.zig:5667)
        let cap = cap_with_rows_below(100);
        let list = PageList::new(cap.cols, 100, None);
        assert_eq!(list.total_rows(), 100);
        assert!(list.total_pages() > 1);
        assert_eq!(node_rows(&list, list.first_node().unwrap()), cap.rows);
    }

    #[test]
    fn init_more_than_max_cols_uses_non_standard_page() {
        // ghostty: "PageList init more than max cols" (PageList.zig:5700)
        let cols = Page::max_cols_for_capacity(STD_CAPACITY).unwrap_or(STD_CAPACITY.cols) + 1;
        let list = PageList::new(cols, 80, None);
        let first = list.first_node().unwrap();
        assert_eq!(list.total_pages(), 1);
        assert!(list.node(first).unwrap().page.memory_len() > PageList::standard_size());
    }

    // ghostty: "PageList init error" (PageList.zig:5611)
    // Skipped: Zig allocator fault injection has no direct equivalent in this
    // Rust port; allocation failure behavior is covered by safe Vec allocation.

    #[test]
    fn point_from_pin_active_no_history() {
        // ghostty: "PageList pointFromPin active no history" (PageList.zig:5732)
        let list = PageList::new(80, 24, None);
        let first = list.first_node().unwrap();
        let point = list
            .point_from_pin(
                Tag::Active,
                Pin {
                    node: first,
                    x: 4,
                    y: 2,
                    garbage: false,
                },
            )
            .unwrap();
        assert_eq!(point, Point::active(4, 2));
    }

    #[test]
    fn point_from_pin_active_with_history() {
        // ghostty: "PageList pointFromPin active with history" (PageList.zig:5765)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(30);
        let first = list.first_node().unwrap();
        assert_eq!(
            list.point_from_pin(
                Tag::Active,
                Pin {
                    node: first,
                    x: 2,
                    y: 30,
                    garbage: false,
                }
            ),
            Some(Point::active(2, 0))
        );
        assert_eq!(
            list.point_from_pin(
                Tag::Active,
                Pin {
                    node: first,
                    x: 2,
                    y: 21,
                    garbage: false,
                }
            ),
            None
        );
    }

    #[test]
    fn point_from_pin_active_from_prior_page() {
        // ghostty: "PageList pointFromPin active from prior page" (PageList.zig:5796)
        let mut list = PageList::new(80, 24, None);
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        list.grow_rows(cap_rows * 5);
        let last = list.last_node().unwrap();
        assert_eq!(
            list.point_from_pin(
                Tag::Active,
                Pin {
                    node: last,
                    x: 2,
                    y: 0,
                    garbage: false,
                }
            ),
            Some(Point::active(2, 0))
        );
        assert!(list
            .point_from_pin(Tag::Active, Pin::new(list.first_node().unwrap()))
            .is_none());
    }

    #[test]
    fn point_from_pin_traverses_pages() {
        // ghostty: "PageList pointFromPin traverse pages" (PageList.zig:5838)
        let mut list = PageList::new(80, 24, None);
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        list.grow_rows(cap_rows * 2);
        let pages = list.total_pages();
        let prior = list.node(list.last_node().unwrap()).unwrap().prev.unwrap();
        assert_eq!(
            list.point_from_pin(
                Tag::Screen,
                Pin {
                    node: prior,
                    x: 2,
                    y: 5,
                    garbage: false,
                }
            ),
            Some(Point::screen(2, (cap_rows * (pages - 2) + 5) as u32))
        );
    }

    #[test]
    fn active_after_grow_updates_viewport_and_scrollbar() {
        // ghostty: "PageList active after grow" (PageList.zig:5884)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(10);
        assert_eq!(list.total_rows(), 34);
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Viewport)),
            Some(Point::screen(0, 10))
        );
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: 34,
                offset: 10,
                len: 24
            }
        );
    }

    #[test]
    fn grow_fit_in_capacity_returns_none() {
        // ghostty: "PageList grow fit in capacity" (PageList.zig:7017)
        let mut list = PageList::new(80, 24, None);
        assert_eq!(list.grow(), None);
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 1))
        );
    }

    #[test]
    fn grow_allocates_when_page_capacity_is_full() {
        // ghostty: "PageList grow allocate" (PageList.zig:7039)
        let mut list = PageList::new(80, 24, None);
        let first = list.last_node().unwrap();
        let cap_rows = list.node_capacity(first).unwrap().rows as usize;
        while node_rows(&list, first) < cap_rows as CellCountInt {
            assert_eq!(list.grow(), None);
        }
        let new_node = list.grow().unwrap();
        assert_eq!(list.node(new_node).unwrap().prev, Some(first));
        let bottom = list.get_bottom_right(Tag::Active).unwrap();
        assert_eq!(bottom.node, new_node);
        assert_eq!(
            list.point_from_pin(Tag::Screen, bottom),
            Some(Point::screen(79, cap_rows as u32))
        );
    }

    #[test]
    fn grow_inherits_style_capacity_from_last_page() {
        // Deliberate Ghostty deviation: once a session has paid to expand its
        // style set, later pages inherit that capacity instead of climbing the
        // same allocation ladder again.
        let mut list = PageList::new(80, 24, None);
        let initial_styles = PageList::initial_capacity(80).styles;
        let last = list.last_node().unwrap();
        let expanded = list
            .increase_capacity(last, Some(IncreaseCapacity::Styles))
            .unwrap();
        let expanded = list
            .increase_capacity(expanded, Some(IncreaseCapacity::GraphemeBytes))
            .unwrap();
        let expanded_capacity = list.node_capacity(expanded).unwrap();
        assert!(expanded_capacity.styles > initial_styles);
        assert!(expanded_capacity.grapheme_bytes > PageList::initial_capacity(80).grapheme_bytes);

        while node_rows(&list, expanded) < expanded_capacity.rows {
            assert_eq!(list.grow(), None);
        }
        let new_last = list.grow().unwrap();

        assert_eq!(
            list.node_capacity(new_last).unwrap().styles,
            expanded_capacity.styles
        );
        assert_eq!(
            list.node_capacity(new_last).unwrap().grapheme_bytes,
            expanded_capacity.grapheme_bytes
        );
    }

    #[test]
    fn grow_allows_exceeding_max_size_for_active_area() {
        // ghostty: "PageList grow allows exceeding max size for active area" (PageList.zig:5926)
        let mut list = PageList::new(80, 24, Some(0));
        let last = list.last_node().unwrap();
        let cap_rows = list.node_capacity(last).unwrap().rows as usize;
        while node_rows(&list, last) < cap_rows as CellCountInt {
            assert_eq!(list.grow(), None);
        }
        let before = list.total_pages();
        assert!(list.grow().is_some());
        assert_eq!(list.total_pages(), before + 1);
        assert!(list.total_rows() >= list.rows as usize);
    }

    #[test]
    fn grow_prune_required_with_single_non_standard_page_keeps_page() {
        // ghostty: "PageList grow prune required with a single page" (PageList.zig:5960)
        let mut list = PageList::new(80, 24, None);
        let mut id = list.first_node().unwrap();
        while list.node(id).unwrap().page.memory_len() <= PageList::standard_size() {
            id = list
                .increase_capacity(id, Some(IncreaseCapacity::GraphemeBytes))
                .unwrap();
        }
        assert_eq!(list.first_node(), list.last_node());
        let rem = list.node_capacity(id).unwrap().rows - node_rows(&list, id);
        for _ in 0..rem {
            assert_eq!(list.grow(), None);
        }
        let new = list.grow().unwrap();
        assert_ne!(new, list.first_node().unwrap());
        assert_eq!(list.viewport(), Viewport::Active);
        assert_eq!(
            list.scrollbar().offset,
            list.total_rows() - list.rows as usize
        );
    }

    #[test]
    fn grow_prunes_scrollback_and_garbages_pins() {
        // ghostty: "PageList grow prune scrollback" (PageList.zig:7067)
        let mut list = PageList::new(80, 24, Some(PageList::standard_size()));
        let first = list.first_node().unwrap();
        let pin_id = list.track_pin(Pin::new(first));
        let cap_rows = list.node_capacity(first).unwrap().rows as usize;
        list.grow_rows(cap_rows * 2 + 1);
        let pin = list.tracked_pin(pin_id).unwrap();
        assert_ne!(pin.node, first);
        assert!(pin.garbage);
        assert_eq!(pin.x, 0);
        assert_eq!(pin.y, 0);
        assert_eq!(list.page_size(), PageList::standard_size() * 2);
    }

    #[test]
    fn grow_prune_viewport_pin_not_in_pruned_page_decrements_cache() {
        // ghostty: "PageList grow prune scrollback with viewport pin not in pruned page" (PageList.zig:7136)
        let mut list = PageList::new(80, 24, Some(PageList::standard_size()));
        let page1 = list.last_node().unwrap();
        let page1_rows = list.node_capacity(page1).unwrap().rows as usize;
        while node_rows(&list, page1) < page1_rows as CellCountInt {
            assert_eq!(list.grow(), None);
        }
        let page2 = list.grow().unwrap();
        let page2_rows = list.node_capacity(page2).unwrap().rows as usize;
        while node_rows(&list, page2) < page2_rows as CellCountInt {
            assert_eq!(list.grow(), None);
        }
        let old_page_size = list.page_size();
        let pin_y = page1_rows + 5;
        let pin = list.pin(Point::screen(0, pin_y as u32)).unwrap();
        list.scroll(Scroll::Pin(pin));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(
            list.tracked_pin(list.viewport_pin_id()).unwrap().node,
            page2
        );
        assert_eq!(list.scrollbar().offset, pin_y);

        let new = list.grow().unwrap();
        assert_eq!(list.last_node(), Some(new));
        assert_eq!(list.first_node(), Some(page2));
        assert_eq!(list.page_size(), old_page_size);
        assert_eq!(
            list.tracked_pin(list.viewport_pin_id()).unwrap().node,
            page2
        );
        assert_eq!(list.scrollbar().offset, pin_y - page1_rows);
    }

    #[test]
    fn grow_reuses_non_standard_page_without_leak_or_alias() {
        // ghostty: "PageList grow reuses non-standard page without leak" (PageList.zig:13868)
        let mut list = PageList::new(80, 24, Some(3 * PageList::standard_size()));
        let mut first = list.first_node().unwrap();
        while list.node(first).unwrap().page.memory_len() <= PageList::standard_size() {
            first = list
                .increase_capacity(first, Some(IncreaseCapacity::GraphemeBytes))
                .unwrap();
        }
        while node_rows(&list, first) < list.node_capacity(first).unwrap().rows {
            let _ = list.grow();
        }
        let _ = list.grow();
        while list.page_size() + PageList::standard_size() <= list.max_size()
            || node_rows(&list, list.last_node().unwrap())
                < list.node_capacity(list.last_node().unwrap()).unwrap().rows
        {
            let _ = list.grow();
        }
        let first_ptr = list.node_buffer_ptr(first).unwrap();
        let tracked = list.track_pin(Pin::new(first));
        let _ = list.grow();
        assert_ne!(list.first_node(), Some(first));
        assert_ne!(
            list.node_buffer_ptr(list.last_node().unwrap()),
            Some(first_ptr)
        );
        let pin = list.tracked_pin(tracked).unwrap();
        assert_eq!(pin.node, list.first_node().unwrap());
        assert!(pin.garbage);
    }

    #[test]
    fn grow_non_standard_page_prune_protection_preserves_active_rows() {
        // ghostty: "PageList grow non-standard page prune protection" (PageList.zig:13941)
        let rows_count = 600;
        let mut list = PageList::new(80, rows_count, Some(PageList::standard_size()));
        let mut first = list.first_node().unwrap();
        while list.node(first).unwrap().page.memory_len() <= PageList::standard_size() {
            first = list
                .increase_capacity(first, Some(IncreaseCapacity::GraphemeBytes))
                .unwrap();
        }
        let first_rows = list.node_capacity(first).unwrap().rows as usize;
        while node_rows(&list, first) < first_rows as CellCountInt {
            let _ = list.grow();
        }
        while list.first_node() == list.last_node() {
            let _ = list.grow();
        }
        let last = list.last_node().unwrap();
        let second_rows = list.node_capacity(last).unwrap().rows as usize;
        while node_rows(&list, last) < second_rows as CellCountInt {
            let _ = list.grow();
        }
        assert!(list.total_rows() - first_rows + 1 < list.rows as usize);
        let _ = list.grow();
        assert!(list.total_rows() >= list.rows as usize);
    }

    #[test]
    fn scroll_max_size_zero_stays_active() {
        // ghostty: "PageList scrollbar with max_size 0 after grow" (PageList.zig:6006)
        // ghostty: "PageList scroll with max_size 0 no history" (PageList.zig:6025)
        let mut list = PageList::new(80, 24, Some(0));
        list.grow_rows(50);
        list.scroll(Scroll::Top);
        assert_eq!(list.viewport(), Viewport::Active);
        list.scroll(Scroll::Row(0));
        assert_eq!(list.viewport(), Viewport::Active);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: 24,
                offset: 0,
                len: 24
            }
        );
    }

    #[test]
    fn scroll_top_stays_pinned_across_growth() {
        // ghostty: "PageList scroll top" (PageList.zig:6047)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(30);
        list.scroll(Scroll::Top);
        assert_eq!(list.viewport(), Viewport::Top);
        list.grow_rows(10);
        assert_eq!(list.viewport(), Viewport::Top);
        assert_eq!(list.scrollbar().offset, 0);
    }

    #[test]
    fn scroll_delta_row_tracks_offsets() {
        // ghostty: "PageList scroll delta row back" (PageList.zig:6110)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(100);
        list.scroll(Scroll::DeltaRow(-1));
        assert_eq!(list.scrollbar().offset, list.total_rows() - 24 - 1);
        list.grow_rows(10);
        assert_eq!(list.scrollbar().offset, list.total_rows() - 24 - 11);
        list.scroll(Scroll::DeltaRow(-1));
        assert_eq!(list.scrollbar().offset, list.total_rows() - 24 - 12);
    }

    #[test]
    fn scroll_delta_row_clamps_to_top() {
        // ghostty: "PageList scroll delta row back overflow" (PageList.zig:6166)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(100);
        list.scroll(Scroll::DeltaRow(-100));
        assert_eq!(list.viewport(), Viewport::Top);
        list.grow_rows(10);
        assert_eq!(list.viewport(), Viewport::Top);
    }

    #[test]
    fn scroll_active_and_forward_noop() {
        // ghostty: "PageList scroll delta row forward" (PageList.zig:6214)
        // ghostty: "PageList scroll delta row forward into active" (PageList.zig:6263)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(40);
        list.scroll(Scroll::Active);
        let before = list.scrollbar().offset;
        list.scroll(Scroll::DeltaRow(10));
        assert_eq!(list.viewport(), Viewport::Active);
        assert_eq!(list.scrollbar().offset, before);
    }

    #[test]
    fn scroll_back_without_space_repins_active() {
        // ghostty: "PageList scroll delta row back without space preserves active" (PageList.zig:6287)
        let mut list = PageList::new(80, 24, None);
        list.scroll(Scroll::DeltaRow(-1));
        assert_eq!(list.viewport(), Viewport::Active);
    }

    #[test]
    fn scroll_pin_ignores_x_and_classifies_top_active() {
        // ghostty: "PageList scroll to pin" (PageList.zig:6312)
        // ghostty: "PageList scroll to pin in active" (PageList.zig:6359)
        // ghostty: "PageList scroll to pin at top" (PageList.zig:6387)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(100);
        let mut top = list.get_top_left(Tag::Screen);
        top.x = 42;
        list.scroll(Scroll::Pin(top));
        assert_eq!(list.viewport(), Viewport::Top);
        let mut active = list.get_top_left(Tag::Active);
        active.x = 42;
        list.scroll(Scroll::Pin(active));
        assert_eq!(list.viewport(), Viewport::Active);
        let mut middle = list.pin(Point::screen(13, 10)).unwrap();
        middle.x = 13;
        list.scroll(Scroll::Pin(middle));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(list.tracked_pin(list.viewport_pin_id()).unwrap().x, 13);
        assert_eq!(list.get_top_left(Tag::Viewport).x, 13);
    }

    #[test]
    fn scroll_row_boundaries_and_cache() {
        // ghostty: "PageList scroll to row 0" (PageList.zig:6417)
        // ghostty: "PageList scroll to row in scrollback" (PageList.zig:6466)
        // ghostty: "PageList scroll to row in middle" (PageList.zig:6514)
        // ghostty: "PageList scroll to row at active boundary" (PageList.zig:6557)
        // ghostty: "PageList scroll to row beyond active" (PageList.zig:6596)
        // ghostty: "PageList scroll to row without scrollback" (PageList.zig:6623)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(100);
        list.scroll(Scroll::Row(0));
        assert_eq!(list.viewport(), Viewport::Top);
        list.grow_rows(5);
        assert_eq!(list.viewport(), Viewport::Top);
        list.scroll(Scroll::Row(5));
        assert_eq!(list.scrollbar().offset, 5);
        let midpoint = list.total_rows() / 2;
        list.scroll(Scroll::Row(midpoint));
        assert_eq!(list.scrollbar().offset, midpoint);
        let active_boundary = list.total_rows() - list.rows as usize;
        list.scroll(Scroll::Row(active_boundary));
        assert_eq!(list.viewport(), Viewport::Active);
        list.scroll(Scroll::Row(1000));
        assert_eq!(list.viewport(), Viewport::Active);

        let mut no_scrollback = PageList::new(80, 24, None);
        no_scrollback.scroll(Scroll::Row(1));
        assert_eq!(no_scrollback.viewport(), Viewport::Active);
    }

    #[test]
    fn scroll_row_cached_delta_both_directions() {
        // ghostty: "PageList scroll to row then delta" (PageList.zig:6649)
        // ghostty: "PageList scroll to row with cache fast path down" (PageList.zig:6712)
        // ghostty: "PageList scroll to row with cache fast path up" (PageList.zig:6775)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(100);
        list.scroll(Scroll::Row(10));
        assert_eq!(list.viewport_pin_row_offset, Some(10));
        list.scroll(Scroll::DeltaRow(5));
        assert_eq!(list.scrollbar().offset, 15);
        list.scroll(Scroll::DeltaRow(-3));
        assert_eq!(list.scrollbar().offset, 12);
        list.scroll(Scroll::Row(30));
        assert_eq!(list.viewport_pin_row_offset, Some(30));
        list.scroll(Scroll::Row(10));
        assert_eq!(list.scrollbar().offset, 10);
    }

    #[test]
    fn scroll_clear_grows_for_non_empty_rows() {
        // ghostty: "PageList scroll clear" (PageList.zig:6838)
        let mut list = PageList::new(80, 24, None);
        assert!(list.set_cell(Point::active(0, 0), Cell::new('a')));
        assert!(list.set_cell(Point::active(0, 1), Cell::new('b')));
        list.scroll_clear();
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 2))
        );
    }

    #[test]
    fn prompt_scrolling_finds_prompt_rows_and_skips_continuations() {
        // ghostty: "PageList: jump zero prompts" (PageList.zig:6871)
        // ghostty: "Screen: jump back one prompt" (PageList.zig:6899)
        // ghostty: "Screen: jump forward prompt skips multiline continuation" (PageList.zig:6968)
        let mut list = PageList::new(5, 3, None);
        list.grow_rows(6);
        let prompt = list.pin(Point::screen(0, 1)).unwrap();
        let continuation = list.pin(Point::screen(0, 2)).unwrap();
        let next_prompt = list.pin(Point::screen(0, 4)).unwrap();
        list.set_row_semantic_prompt_for_testing(prompt, SemanticPrompt::Prompt);
        list.set_row_semantic_prompt_for_testing(continuation, SemanticPrompt::PromptContinuation);
        list.set_row_semantic_prompt_for_testing(next_prompt, SemanticPrompt::Prompt);

        let before = list.scrollbar().offset;
        list.scroll(Scroll::DeltaPrompt(0));
        assert_eq!(list.scrollbar().offset, before);

        list.scroll(Scroll::Top);
        list.scroll(Scroll::DeltaPrompt(1));
        assert_eq!(list.get_top_left(Tag::Viewport).y, 1);
        list.scroll(Scroll::DeltaPrompt(1));
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Viewport)),
            Some(Point::screen(0, 4))
        );
    }

    #[test]
    fn increase_capacity_doubles_dimensions_and_preserves_contents() {
        // ghostty: "PageList increaseCapacity to increase styles" (PageList.zig:7444)
        // ghostty: "PageList increaseCapacity to increase graphemes" (PageList.zig:7495)
        // ghostty: "PageList increaseCapacity to increase hyperlinks" (PageList.zig:7539)
        // ghostty: "PageList increaseCapacity to increase string_bytes" (PageList.zig:7583)
        let mut list = PageList::new(10, 4, None);
        let id = list.first_node().unwrap();
        assert!(list.set_cell(Point::screen(0, 0), Cell::new('x')));
        let old = list.node_capacity(id).unwrap();
        let new_id = list
            .increase_capacity(id, Some(IncreaseCapacity::Styles))
            .unwrap();
        let new = list.node_capacity(new_id).unwrap();
        assert_eq!(new.styles, old.styles * 2);
        assert_eq!(list.get_cell(Point::screen(0, 0)), Some(Cell::new('x')));

        let old = list.node_capacity(new_id).unwrap();
        let new_id = list
            .increase_capacity(new_id, Some(IncreaseCapacity::GraphemeBytes))
            .unwrap();
        assert_eq!(
            list.node_capacity(new_id).unwrap().grapheme_bytes,
            old.grapheme_bytes * 2
        );

        let old = list.node_capacity(new_id).unwrap();
        let new_id = list
            .increase_capacity(new_id, Some(IncreaseCapacity::HyperlinkBytes))
            .unwrap();
        assert_eq!(
            list.node_capacity(new_id).unwrap().hyperlink_bytes,
            old.hyperlink_bytes * 2
        );

        let old = list.node_capacity(new_id).unwrap();
        let new_id = list
            .increase_capacity(new_id, Some(IncreaseCapacity::StringBytes))
            .unwrap();
        assert_eq!(
            list.node_capacity(new_id).unwrap().string_bytes,
            old.string_bytes * 2
        );
    }

    #[test]
    fn hyperlink_capacity_can_grow_past_u16_limit() {
        let mut list = PageList::new(10, 4, None);
        let mut id = list.first_node().unwrap();
        while list.node_capacity(id).unwrap().hyperlink_bytes <= u32::from(u16::MAX) {
            id = list
                .increase_capacity(id, Some(IncreaseCapacity::HyperlinkBytes))
                .unwrap();
        }

        assert!(list.node_capacity(id).unwrap().hyperlink_bytes > u32::from(u16::MAX));
    }

    #[test]
    fn increase_capacity_retargets_pins_and_preserves_dirty() {
        // ghostty: "PageList increaseCapacity tracked pins" (PageList.zig:7627)
        // ghostty: "PageList increaseCapacity preserves dirty flag" (PageList.zig:7739)
        let mut list = PageList::new(10, 4, None);
        let id = list.first_node().unwrap();
        let pin = list.pin(Point::screen(2, 1)).unwrap();
        let pin_id = list.track_pin(pin);
        list.mark_dirty(pin);
        if let Some(node) = list.node_mut(id) {
            node.page.set_page_dirty(true);
        }
        let new_id = list
            .increase_capacity(id, Some(IncreaseCapacity::Styles))
            .unwrap();
        let tracked = list.tracked_pin(pin_id).unwrap();
        assert_eq!(tracked.node, new_id);
        assert_eq!(tracked.x, 2);
        assert_eq!(tracked.y, 1);
        assert!(list.pin_is_dirty(tracked));
        assert!(list.node(new_id).unwrap().page.page_dirty());
    }

    #[test]
    fn page_and_cell_iterators_cover_expected_chunks() {
        // ghostty: "PageList pageIterator single page" (PageList.zig:7770)
        // ghostty: "PageList pageIterator two pages" (PageList.zig:7793)
        // ghostty: "PageList pageIterator history two pages" (PageList.zig:7829)
        // ghostty: "PageList pageIterator reverse single page" (PageList.zig:7859)
        // ghostty: "PageList pageIterator reverse two pages" (PageList.zig:7882)
        // ghostty: "PageList pageIterator reverse history two pages" (PageList.zig:7922)
        // ghostty: "PageList cellIterator" (PageList.zig:7952)
        // ghostty: "PageList cellIterator reverse" (PageList.zig:8002)
        let mut list = PageList::new(2, 2, None);
        let mut cells = Vec::new();
        let mut iter = list.cell_iterator(Direction::RightDown, Point::screen(0, 0), None);
        while let Some(pin) = iter.next(&list) {
            cells.push((pin.x, pin.y));
        }
        assert_eq!(cells, vec![(0, 0), (1, 0), (0, 1), (1, 1)]);

        let mut cells = Vec::new();
        let mut iter = list.cell_iterator(Direction::LeftUp, Point::screen(0, 0), None);
        while let Some(pin) = iter.next(&list) {
            cells.push((pin.x, pin.y));
        }
        assert_eq!(cells, vec![(1, 1), (0, 1), (1, 0), (0, 0)]);

        let rows_to_allocate_one_new_row =
            list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize
                - list.rows as usize
                + 1;
        list.grow_rows(rows_to_allocate_one_new_row);
        let mut chunks = Vec::new();
        let mut pages = list.page_iterator(Direction::RightDown, Point::active(0, 0), None);
        while let Some(chunk) = pages.next(&list) {
            chunks.push((chunk.node, chunk.start, chunk.end));
        }
        assert!(chunks.len() >= 2);
        assert_eq!(chunks.last().unwrap().2, 1);
    }

    #[test]
    fn prompt_iterator_yields_prompt_starts() {
        // ghostty: "PageList promptIterator left_up" (PageList.zig:8052)
        // ghostty: "PageList promptIterator right_down" (PageList.zig:8109)
        // ghostty: "PageList promptIterator right_down continuation at start" (PageList.zig:8166)
        // ghostty: "PageList promptIterator right_down with prompt before continuation" (PageList.zig:8209)
        // ghostty: "PageList promptIterator right_down limit inclusive" (PageList.zig:8248)
        // ghostty: "PageList promptIterator left_up limit inclusive" (PageList.zig:8280)
        let mut list = PageList::new(5, 5, None);
        let first_prompt = list.pin(Point::screen(0, 1)).unwrap();
        let continuation = list.pin(Point::screen(0, 2)).unwrap();
        let second_prompt = list.pin(Point::screen(0, 4)).unwrap();
        list.set_row_semantic_prompt_for_testing(first_prompt, SemanticPrompt::Prompt);
        list.set_row_semantic_prompt_for_testing(continuation, SemanticPrompt::PromptContinuation);
        list.set_row_semantic_prompt_for_testing(second_prompt, SemanticPrompt::Prompt);

        let mut forward = list.prompt_iterator(Direction::RightDown, Point::screen(0, 0), None);
        assert_eq!(forward.next(&list).unwrap().y, 1);
        assert_eq!(forward.next(&list).unwrap().y, 4);
        assert!(forward.next(&list).is_none());

        let mut reverse = list.prompt_iterator(Direction::LeftUp, Point::screen(0, 0), None);
        assert_eq!(reverse.next(&list).unwrap().y, 4);
        assert_eq!(reverse.next(&list).unwrap().y, 1);
        assert!(reverse.next(&list).is_none());
    }

    #[test]
    fn min_max_size_always_keeps_two_standard_pages() {
        let minimum = PageList::min_max_size(80, 1);
        assert!(minimum >= PageList::standard_size() * 2);
    }

    #[test]
    fn initial_capacity_adjusts_to_requested_columns() {
        let cols = 132;
        let cap = PageList::initial_capacity(cols);
        assert_eq!(cap.cols, cols);
        assert!(cap.rows > 0);
    }

    #[test]
    fn reset_moves_tracked_pins_and_marks_them_garbage() {
        // ghostty: "PageList reset moves tracked pins and marks them as garbage" (PageList.zig:13688)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(10);
        let pin_id = list.track_pin(list.pin(Point::screen(0, 5)).unwrap());
        list.reset();
        let pin = list.tracked_pin(pin_id).unwrap();
        assert_eq!(pin.node, list.first_node().unwrap());
        assert!(pin.garbage);
        assert_eq!(pin.x, 0);
        assert_eq!(pin.y, 0);
        assert!(!list.tracked_pin(list.viewport_pin_id()).unwrap().garbage);
    }

    #[test]
    fn reset_across_two_pages_rebuilds_rows() {
        // ghostty: "PageList reset across two pages" (PageList.zig:13664)
        let cap = cap_with_rows_below(100);
        let mut list = PageList::new(cap.cols, 100, None);
        assert!(list.total_pages() > 1);
        list.grow_rows(50);
        list.reset();
        assert_eq!(list.total_rows(), 100);
        assert!(list.total_pages() > 1);
    }

    #[test]
    fn page_pool_is_bounded_after_reset() {
        let mut list = PageList::new(80, 24, None);
        let page_rows = usize::from(list.node_capacity(list.first_node().unwrap()).unwrap().rows);
        list.grow_rows(page_rows * (PAGE_POOL_MAX + 4));
        assert!(list.total_pages() > PAGE_POOL_MAX);

        list.reset();

        assert!(list.page_buffers.len() <= PAGE_POOL_MAX);
    }

    #[test]
    fn get_top_left_history_and_screen_start_at_first_page() {
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(10);
        let first = Pin::new(list.first_node().unwrap());
        assert_eq!(list.get_top_left(Tag::Screen), first);
        assert_eq!(list.get_top_left(Tag::History), first);
    }

    #[test]
    fn get_top_left_active_walks_backward_from_last_page() {
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(30);
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 30))
        );
    }

    #[test]
    fn get_bottom_right_history_is_none_without_scrollback() {
        let list = PageList::new(80, 24, None);
        assert!(list.get_bottom_right(Tag::History).is_none());
    }

    #[test]
    fn get_bottom_right_history_is_row_before_active() {
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(10);
        let history_bottom = list.get_bottom_right(Tag::History).unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Screen, history_bottom),
            Some(Point::screen(79, 9))
        );
    }

    #[test]
    fn pin_rejects_x_outside_columns_before_resolving_y() {
        let list = PageList::new(10, 4, None);
        assert!(list.pin(Point::screen(10, 0)).is_none());
        assert!(list.pin(Point::screen(9, 0)).is_some());
    }

    #[test]
    fn pin_viewport_dispatches_to_current_viewport_top_left() {
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(40);
        list.scroll(Scroll::Row(5));
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.pin(Point::viewport(0, 0)).unwrap()),
            Some(Point::screen(0, 5))
        );
    }

    #[test]
    fn pin_identity_checks_active_and_top() {
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(30);
        assert!(list.pin_is_top(list.get_top_left(Tag::Screen)));
        assert!(list.pin_is_active(list.get_top_left(Tag::Active)));
        assert!(!list.pin_is_active(list.get_top_left(Tag::Screen)));
    }

    #[test]
    fn point_from_pin_viewport_returns_none_outside_region() {
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(30);
        list.scroll(Scroll::Row(10));
        let before_viewport = list.pin(Point::screen(0, 9)).unwrap();
        assert!(list
            .point_from_pin(Tag::Viewport, before_viewport)
            .is_none());
    }

    #[test]
    fn pin_before_orders_same_node_lexicographically() {
        let list = PageList::new(80, 24, None);
        let node = list.first_node().unwrap();
        let left = Pin {
            node,
            y: 1,
            x: 2,
            garbage: true,
        };
        let right = Pin {
            node,
            y: 1,
            x: 3,
            garbage: false,
        };
        assert!(list.pin_before(left, right));
        assert!(!list.pin_before(right, left));
    }

    #[test]
    fn pin_before_orders_nodes_by_list_position_not_slot_index() {
        let mut list = PageList::new(80, 24, None);
        let (first, second) = grow_until_second_page(&mut list);
        assert!(list.pin_before(Pin::new(first), Pin::new(second)));
        assert!(!list.pin_before(Pin::new(second), Pin::new(first)));
    }

    #[test]
    fn pin_is_between_respects_x_on_same_boundary_row() {
        let list = PageList::new(80, 24, None);
        let node = list.first_node().unwrap();
        let top = Pin {
            node,
            y: 2,
            x: 10,
            garbage: false,
        };
        let bottom = Pin {
            node,
            y: 2,
            x: 20,
            garbage: false,
        };
        assert!(list.pin_is_between(
            Pin {
                node,
                y: 2,
                x: 15,
                garbage: true
            },
            top,
            bottom
        ));
        assert!(!list.pin_is_between(
            Pin {
                node,
                y: 2,
                x: 9,
                garbage: false
            },
            top,
            bottom
        ));
    }

    #[test]
    fn pin_is_between_accepts_middle_nodes() {
        let mut list = PageList::new(80, 24, None);
        let (first, second) = grow_until_second_page(&mut list);
        let middle = Pin::new(second);
        assert!(list.pin_is_between(middle, Pin::new(first), middle));
    }

    #[test]
    fn pin_down_enters_following_page_at_remaining_minus_one() {
        let mut list = PageList::new(80, 24, None);
        let (first, second) = grow_until_second_page(&mut list);
        let cap_rows = list.node_capacity(first).unwrap().rows;
        let pin = Pin {
            node: first,
            y: cap_rows - 1,
            x: 7,
            garbage: false,
        };
        let moved = list.pin_down(pin, 1).unwrap();
        assert_eq!(moved.node, second);
        assert_eq!(moved.y, 0);
        assert_eq!(moved.x, 7);
    }

    #[test]
    fn pin_up_enters_previous_page_at_rows_minus_remaining() {
        let mut list = PageList::new(80, 24, None);
        let (first, second) = grow_until_second_page(&mut list);
        let cap_rows = list.node_capacity(first).unwrap().rows;
        let pin = Pin {
            node: second,
            y: 0,
            x: 7,
            garbage: false,
        };
        let moved = list.pin_up(pin, 1).unwrap();
        assert_eq!(moved.node, first);
        assert_eq!(moved.y, cap_rows - 1);
        assert_eq!(moved.x, 7);
    }

    #[test]
    fn pin_down_overflow_reports_end_and_remaining_rows() {
        let list = PageList::new(80, 4, None);
        let start = list.pin(Point::screen(0, 3)).unwrap();
        match list.pin_down_overflow(start, 2) {
            PinMove::Overflow { end, remaining } => {
                assert_eq!(end.y, 3);
                assert_eq!(remaining, 2);
            }
            PinMove::Offset(_) => panic!("expected overflow"),
        }
    }

    #[test]
    fn pin_up_overflow_reports_start_and_remaining_rows() {
        let list = PageList::new(80, 4, None);
        let start = list.pin(Point::screen(0, 0)).unwrap();
        match list.pin_up_overflow(start, 2) {
            PinMove::Overflow { end, remaining } => {
                assert_eq!(end.y, 0);
                assert_eq!(remaining, 2);
            }
            PinMove::Offset(_) => panic!("expected overflow"),
        }
    }

    #[test]
    fn pin_horizontal_clamps_saturate_at_row_edges() {
        let list = PageList::new(10, 4, None);
        let pin = list.pin(Point::screen(5, 0)).unwrap();
        assert_eq!(pin.left_clamp(99).x, 0);
        assert_eq!(list.pin_right_clamp(pin, 99).x, 9);
        assert_eq!(pin.right_clamp(&list, 99).x, 9);
        assert_eq!(list.pin_right(pin, 2).x, 7);
    }

    #[test]
    fn pin_right_wrap_crosses_to_next_row() {
        // port-added: Ghostty left_wrap/right_wrap are upstream TODO-tested; T8b ports them with
        // direct wrap tests.
        let list = PageList::new(3, 2, Some(0));
        let pin = list.pin(Point::screen(2, 0)).unwrap();
        let wrapped = pin.right_wrap(&list, 1).unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Screen, wrapped),
            Some(Point::screen(0, 1))
        );
    }

    #[test]
    fn pin_left_wrap_crosses_to_previous_row() {
        // port-added: Ghostty left_wrap/right_wrap are upstream TODO-tested; T8b ports them with
        // direct wrap tests.
        let list = PageList::new(3, 2, Some(0));
        let pin = list.pin(Point::screen(0, 1)).unwrap();
        let wrapped = pin.left_wrap(&list, 1).unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Screen, wrapped),
            Some(Point::screen(2, 0))
        );
    }

    #[test]
    fn pin_wrap_returns_none_past_document_edges() {
        // port-added: saturating helpers clamp, wrap helpers report overflow at document edges.
        let list = PageList::new(3, 2, Some(0));
        assert!(list
            .pin(Point::screen(0, 0))
            .unwrap()
            .left_wrap(&list, 1)
            .is_none());
        assert!(list
            .pin(Point::screen(2, 1))
            .unwrap()
            .right_wrap(&list, 1)
            .is_none());
    }

    #[test]
    fn pin_cells_subsets_are_inclusive_on_left_and_right() {
        let mut list = PageList::new(4, 1, None);
        for x in 0..4 {
            assert!(list.set_cell(Point::screen(x, 0), Cell::new(char::from(b'a' + x as u8))));
        }
        let pin = list.pin(Point::screen(1, 0)).unwrap();
        assert_eq!(list.cells(pin, CellSubset::All).unwrap().len(), 4);
        assert_eq!(list.cells(pin, CellSubset::Left).unwrap().len(), 2);
        assert_eq!(list.cells(pin, CellSubset::Right).unwrap().len(), 3);
    }

    #[test]
    fn row_dirty_tracks_mark_dirty() {
        let mut list = PageList::new(10, 4, None);
        let pin = list.pin(Point::screen(0, 2)).unwrap();
        assert!(!list.pin_is_dirty(pin));
        list.mark_dirty(pin);
        assert!(list.pin_is_dirty(pin));
    }

    #[test]
    fn track_pin_count_changes_with_slab_reuse() {
        let mut list = PageList::new(80, 24, None);
        let initial = list.count_tracked_pins();
        let first = list.track_pin(Pin::new(list.first_node().unwrap()));
        let second = list.track_pin(Pin::new(list.first_node().unwrap()));
        assert_eq!(list.count_tracked_pins(), initial + 2);
        assert!(list.untrack_pin(first));
        assert_eq!(list.count_tracked_pins(), initial + 1);
        let reused = list.track_pin(Pin::new(list.first_node().unwrap()));
        assert_eq!(reused, first);
        assert!(list.untrack_pin(second));
    }

    #[test]
    fn page_iterator_with_unresolvable_bottom_is_empty() {
        let list = PageList::new(80, 24, None);
        let mut iter = list.page_iterator(
            Direction::RightDown,
            Point::screen(80, 0),
            Some(Point::screen(0, 0)),
        );
        assert!(iter.next(&list).is_none());
    }

    #[test]
    fn row_iterator_left_up_starts_at_bottom_row() {
        let list = PageList::new(4, 3, None);
        let mut iter = list.row_iterator(Direction::LeftUp, Point::screen(0, 0), None);
        assert_eq!(iter.next(&list).unwrap().y, 2);
    }

    #[test]
    fn prompt_iterator_right_down_continuation_at_start_is_yielded() {
        // ghostty: "PageList promptIterator right_down continuation at start" (PageList.zig:8166)
        let mut list = PageList::new(2, 6, None);
        let continuation = list.pin(Point::screen(0, 0)).unwrap();
        let prompt = list.pin(Point::screen(0, 5)).unwrap();
        list.set_row_semantic_prompt_for_testing(continuation, SemanticPrompt::PromptContinuation);
        list.set_row_semantic_prompt_for_testing(prompt, SemanticPrompt::Prompt);
        let mut iter = list.prompt_iterator(Direction::RightDown, Point::screen(0, 0), None);
        assert_eq!(iter.next(&list).unwrap().y, 0);
        assert_eq!(iter.next(&list).unwrap().y, 5);
    }

    #[test]
    fn prompt_iterator_limits_are_inclusive() {
        // ghostty: "PageList promptIterator right_down limit inclusive" (PageList.zig:8248)
        // ghostty: "PageList promptIterator left_up limit inclusive" (PageList.zig:8280)
        let mut list = PageList::new(2, 12, None);
        let first = list.pin(Point::screen(0, 5)).unwrap();
        let second = list.pin(Point::screen(0, 10)).unwrap();
        list.set_row_semantic_prompt_for_testing(first, SemanticPrompt::Prompt);
        list.set_row_semantic_prompt_for_testing(second, SemanticPrompt::Prompt);
        let mut forward = list.prompt_iterator(
            Direction::RightDown,
            Point::screen(0, 0),
            Some(Point::screen(0, 5)),
        );
        assert_eq!(forward.next(&list).unwrap().y, 5);
        assert!(forward.next(&list).is_none());
        let mut reverse = list.prompt_iterator(
            Direction::LeftUp,
            Point::screen(0, 10),
            Some(Point::screen(0, 11)),
        );
        assert_eq!(reverse.next(&list).unwrap().y, 10);
        assert!(reverse.next(&list).is_none());
    }

    #[test]
    fn increase_capacity_reports_out_of_space_at_type_limit() {
        // ghostty: "PageList increaseCapacity returns OutOfSpace at max capacity" (PageList.zig:7650)
        let mut list = PageList::new(2, 2, Some(0));
        let mut id = list.first_node().unwrap();
        loop {
            match list.increase_capacity(id, Some(IncreaseCapacity::Styles)) {
                Ok(new_id) => id = new_id,
                Err(IncreaseCapacityError::OutOfSpace) => {
                    assert_eq!(list.node_capacity(id).unwrap().styles, u16::MAX);
                    break;
                }
            }
        }
    }

    #[test]
    fn increase_capacity_preserves_shrunk_size_cols() {
        // ghostty: "PageList increaseCapacity after col shrink" (PageList.zig:7672)
        let mut list = PageList::new(10, 2, Some(0));
        let id = list.first_node().unwrap();
        if let Some(node) = list.node_mut(id) {
            node.page.set_size_cols(5);
        }
        let new_id = list
            .increase_capacity(id, Some(IncreaseCapacity::Styles))
            .unwrap();
        assert_eq!(list.node_page_size(new_id).unwrap().cols, 5);
    }

    #[test]
    fn increase_capacity_only_changes_target_node() {
        // ghostty: "PageList increaseCapacity multi-page" (PageList.zig:7700)
        let mut list = PageList::new(80, 24, None);
        let (first, second) = grow_until_second_page(&mut list);
        let first_styles = list.node_capacity(first).unwrap().styles;
        let second_styles = list.node_capacity(second).unwrap().styles;
        let new_first = list
            .increase_capacity(first, Some(IncreaseCapacity::Styles))
            .unwrap();
        assert_eq!(
            list.node_capacity(new_first).unwrap().styles,
            first_styles * 2
        );
        assert_eq!(list.node_capacity(second).unwrap().styles, second_styles);
    }

    #[test]
    fn erase_rows_invalidates_viewport_offset_cache() {
        // ghostty: "PageList eraseRows invalidates viewport offset cache" (PageList.zig:7196)
        let mut list = PageList::new(80, 24, None);
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        for _ in 0..cap_rows * 3 {
            let _ = list.grow();
        }
        let pin_y = cap_rows;
        list.scroll(Scroll::Pin(
            list.pin(Point::screen(0, pin_y as u32)).unwrap(),
        ));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y,
                len: 24
            }
        );
        list.erase_history(Some(Point::history(0, (cap_rows / 2 - 1) as u32)));
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y - cap_rows / 2,
                len: 24
            }
        );
    }

    #[test]
    fn erase_row_invalidates_viewport_offset_cache() {
        // ghostty: "PageList eraseRow invalidates viewport offset cache" (PageList.zig:7236)
        let mut list = PageList::new(80, 24, None);
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        for _ in 0..cap_rows * 3 {
            let _ = list.grow();
        }
        let pin_y = cap_rows;
        list.scroll(Scroll::Pin(
            list.pin(Point::screen(0, pin_y as u32)).unwrap(),
        ));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y,
                len: 24
            }
        );
        list.erase_row(Point::history(0, 0)).unwrap();
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y - 1,
                len: 24
            }
        );
    }

    #[test]
    fn erase_row_bounded_invalidates_viewport_offset_cache() {
        // ghostty: "PageList eraseRowBounded invalidates viewport offset cache" (PageList.zig:7275)
        let mut list = PageList::new(80, 24, None);
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        for _ in 0..cap_rows * 3 {
            let _ = list.grow();
        }
        let pin_y = 4;
        list.scroll(Scroll::Pin(
            list.pin(Point::screen(0, pin_y as u32)).unwrap(),
        ));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y,
                len: 24
            }
        );
        list.erase_row_bounded(Point::history(0, 0), 10).unwrap();
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: 3,
                len: 24
            }
        );
    }

    #[test]
    fn erase_row_bounded_multi_page_invalidates_viewport_offset_cache() {
        // ghostty: "PageList eraseRowBounded multi-page invalidates viewport offset cache" (PageList.zig:7315)
        let mut list = PageList::new(80, 24, None);
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        for _ in 0..cap_rows * 3 {
            let _ = list.grow();
        }
        let pin_y = cap_rows + 1;
        list.scroll(Scroll::Pin(
            list.pin(Point::screen(0, pin_y as u32)).unwrap(),
        ));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y,
                len: 24
            }
        );
        list.erase_row_bounded(Point::history(0, 0), cap_rows + 10)
            .unwrap();
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y - 1,
                len: 24
            }
        );
    }

    #[test]
    fn erase_row_bounded_full_page_shift_invalidates_viewport_offset_cache() {
        // ghostty: "PageList eraseRowBounded full page shift invalidates viewport offset cache" (PageList.zig:7356)
        let mut list = PageList::new(80, 24, None);
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        for _ in 0..cap_rows * 4 {
            let _ = list.grow();
        }
        let pin_y = 5;
        list.scroll(Scroll::Pin(
            list.pin(Point::screen(0, pin_y as u32)).unwrap(),
        ));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y,
                len: 24
            }
        );
        list.erase_row_bounded(Point::history(0, 0), cap_rows * 2 + 10)
            .unwrap();
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: 4,
                len: 24
            }
        );
    }

    #[test]
    fn erase_row_bounded_exhausts_pages_invalidates_viewport_offset_cache() {
        // ghostty: "PageList eraseRowBounded exhausts pages invalidates viewport offset cache" (PageList.zig:7399)
        let mut list = PageList::new(80, 24, None);
        let cap_rows = list.node_capacity(list.last_node().unwrap()).unwrap().rows as usize;
        for _ in 0..cap_rows * 3 {
            let _ = list.grow();
        }
        let total_before = list.total_rows();
        assert!(total_before > 24);
        let pin_y = cap_rows * 2 + 10;
        list.scroll(Scroll::Pin(
            list.pin(Point::screen(0, pin_y as u32)).unwrap(),
        ));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y,
                len: 24
            }
        );
        list.erase_row_bounded(Point::history(0, 0), total_before * 2)
            .unwrap();
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: pin_y - 1,
                len: 24
            }
        );
    }

    #[test]
    fn erase_history_removes_scrollback_pages() {
        // ghostty: "PageList erase" (PageList.zig:9376)
        let mut list = PageList::new(80, 24, None);
        grow_by_standard_page_multiples(&mut list, 5);
        assert_eq!(list.total_pages(), 6);
        assert!(list.total_rows() > list.rows as usize);
        list.erase_history(None);
        assert_eq!(list.total_rows(), list.rows as usize);
        assert_eq!(list.total_pages(), 1);
    }

    #[test]
    fn erase_history_reaccounts_page_size() {
        // ghostty: "PageList erase reaccounts page size" (PageList.zig:9410)
        let mut list = PageList::new(80, 24, None);
        let start = list.page_size();
        grow_by_standard_page_multiples(&mut list, 5);
        assert_eq!(list.total_pages(), 6);
        assert!(list.page_size() > start);
        list.erase_history(None);
        assert_eq!(list.page_size(), start);
    }

    #[test]
    fn erase_history_resets_tracked_pin_to_first_page() {
        // ghostty: "PageList erase row with tracked pin resets to top-left" (PageList.zig:9437)
        let mut list = PageList::new(80, 24, None);
        grow_by_standard_page_multiples(&mut list, 5);
        assert_eq!(list.total_pages(), 6);
        let pin = list.track_pin(list.pin(Point::history(0, 0)).unwrap());
        list.erase_history(None);
        let tracked = list.tracked_pin(pin).unwrap();
        assert_eq!(tracked.node, list.first_node().unwrap());
        assert_eq!((tracked.x, tracked.y), (0, 0));
    }

    #[test]
    fn erase_active_shifts_pin_after_erased_rows_preserving_x() {
        // ghostty: "PageList erase row with tracked pin shifts" (PageList.zig:9474)
        let mut list = PageList::new(80, 24, None);
        let pin = list.track_pin(list.pin(Point::active(2, 4)).unwrap());
        list.erase_active(3);
        let tracked = list.tracked_pin(pin).unwrap();
        assert_eq!(tracked.node, list.first_node().unwrap());
        assert_eq!((tracked.x, tracked.y), (2, 0));
    }

    #[test]
    fn erase_active_resets_pin_inside_erased_rows() {
        // ghostty: "PageList erase row with tracked pin is erased" (PageList.zig:9495)
        let mut list = PageList::new(80, 24, None);
        let pin = list.track_pin(list.pin(Point::active(2, 2)).unwrap());
        list.erase_active(3);
        let tracked = list.tracked_pin(pin).unwrap();
        assert_eq!((tracked.x, tracked.y), (0, 0));
    }

    #[test]
    fn erase_history_top_viewport_moves_to_active_when_history_removed() {
        // ghostty: "PageList erase resets viewport to active if moves within active" (PageList.zig:9516)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(80);
        list.scroll(Scroll::Top);
        list.erase_history(None);
        assert_eq!(list.viewport(), Viewport::Active);
    }

    #[test]
    fn erase_partial_history_keeps_top_viewport() {
        // ghostty: "PageList erase resets viewport if inside erased page but not active" (PageList.zig:9545)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(80);
        list.scroll(Scroll::Top);
        list.erase_history(Some(Point::history(0, 2)));
        assert_eq!(list.viewport(), Viewport::Top);
    }

    #[test]
    fn erase_history_top_inside_active_becomes_active() {
        // ghostty: "PageList erase resets viewport to active if top is inside active" (PageList.zig:9574)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(80);
        list.scroll(Scroll::Top);
        list.erase_history(None);
        assert_eq!(list.viewport(), Viewport::Active);
    }

    #[test]
    fn erase_active_regrows_to_full_rows() {
        // ghostty: "PageList erase active regrows automatically" (PageList.zig:9602)
        let mut list = PageList::new(80, 24, None);
        list.erase_active(10);
        assert_eq!(list.total_rows(), list.rows as usize);
    }

    #[test]
    fn erase_active_single_row_reinitializes_and_clears_cell() {
        // ghostty: "PageList erase a one-row active" (PageList.zig:9613)
        let mut list = PageList::new(10, 1, None);
        set_screen_cell(&mut list, 0, 0, 'A');
        list.erase_active(0);
        assert_eq!(list.total_rows(), 1);
        assert_eq!(screen_cell(&list, 0, 0), Cell::default());
    }

    #[test]
    fn erase_row_bounded_moves_pins_at_erased_row_with_asymmetry() {
        // ghostty: "PageList eraseRowBounded less than full row" (PageList.zig:9641)
        let mut list = PageList::new(80, 10, None);
        let first = list.first_node().unwrap();
        let p_top = list.track_pin(list.pin(Point::active(0, 5)).unwrap());
        let p_bot = list.track_pin(list.pin(Point::active(0, 8)).unwrap());
        let p_out = list.track_pin(list.pin(Point::active(0, 9)).unwrap());
        list.erase_row_bounded(Point::active(0, 5), 3).unwrap();
        assert_eq!(list.total_rows(), list.rows as usize);
        let top = list.tracked_pin(p_top).unwrap();
        assert_eq!(top.node, first);
        assert_eq!((top.x, top.y), (0, 4));
        let bottom = list.tracked_pin(p_bot).unwrap();
        assert_eq!(bottom.node, first);
        assert_eq!((bottom.x, bottom.y), (0, 7));
        let outside = list.tracked_pin(p_out).unwrap();
        assert_eq!(outside.node, first);
        assert_eq!((outside.x, outside.y), (0, 9));
        assert!(list.pin_is_dirty(list.pin(Point::active(0, 5)).unwrap()));
        assert!(list.pin_is_dirty(list.pin(Point::active(0, 6)).unwrap()));
        assert!(list.pin_is_dirty(list.pin(Point::active(0, 7)).unwrap()));
    }

    #[test]
    fn erase_row_bounded_pin_at_top_resets_x() {
        // ghostty: "PageList eraseRowBounded with pin at top" (PageList.zig:9678)
        let mut list = PageList::new(80, 10, None);
        let pin = list.track_pin(list.pin(Point::active(5, 0)).unwrap());
        list.erase_row_bounded(Point::active(0, 0), 3).unwrap();
        let tracked = list.tracked_pin(pin).unwrap();
        assert_eq!((tracked.x, tracked.y), (0, 0));
    }

    #[test]
    fn erase_row_bounded_beyond_single_page_shifts_all_pins_after_row() {
        // ghostty: "PageList eraseRowBounded full rows single page" (PageList.zig:9703)
        let mut list = PageList::new(80, 10, None);
        let p_in = list.track_pin(list.pin(Point::active(0, 7)).unwrap());
        let p_out = list.track_pin(list.pin(Point::active(0, 9)).unwrap());
        list.erase_row_bounded(Point::active(0, 5), 10).unwrap();
        assert_eq!(list.tracked_pin(p_in).unwrap().y, 6);
        assert_eq!(list.tracked_pin(p_out).unwrap().y, 8);
    }

    #[test]
    fn erase_row_bounded_two_page_straddle_updates_pins_by_region() {
        // ghostty: "PageList eraseRowBounded full rows two pages" (PageList.zig:9736)
        let mut list = PageList::new(80, 10, None);
        let first = list.last_node().unwrap();
        let cap_rows = list.node_capacity(first).unwrap().rows;
        while node_rows(&list, first) < cap_rows {
            assert_eq!(list.grow(), None);
        }
        list.grow_rows(5);
        assert_eq!(list.total_pages(), 2);
        let second = list.last_node().unwrap();
        let p_first = list.track_pin(list.pin(Point::active(0, 4)).unwrap());
        let p_first_out = list.track_pin(list.pin(Point::active(0, 3)).unwrap());
        let p_in = list.track_pin(list.pin(Point::active(0, 8)).unwrap());
        let p_out = list.track_pin(list.pin(Point::active(0, 9)).unwrap());
        assert_eq!(list.tracked_pin(p_first).unwrap().node, first);
        assert_eq!(list.tracked_pin(p_first).unwrap().y, cap_rows - 1);
        assert_eq!(list.tracked_pin(p_first_out).unwrap().node, first);
        assert_eq!(list.tracked_pin(p_first_out).unwrap().y, cap_rows - 2);
        assert_eq!(list.tracked_pin(p_in).unwrap().node, second);
        assert_eq!(list.tracked_pin(p_in).unwrap().y, 3);
        assert_eq!(list.tracked_pin(p_out).unwrap().node, second);
        assert_eq!(list.tracked_pin(p_out).unwrap().y, 4);

        list.erase_row_bounded(Point::active(0, 4), 4).unwrap();
        assert_eq!(list.tracked_pin(p_first).unwrap().node, first);
        assert_eq!(list.tracked_pin(p_first).unwrap().y, cap_rows - 2);
        assert_eq!(list.tracked_pin(p_first_out).unwrap().node, first);
        assert_eq!(list.tracked_pin(p_first_out).unwrap().y, cap_rows - 2);
        assert_eq!(list.tracked_pin(p_in).unwrap().node, second);
        assert_eq!(list.tracked_pin(p_in).unwrap().y, 2);
        assert_eq!(list.tracked_pin(p_out).unwrap().y, 4);
    }

    #[test]
    fn clone_full_keeps_total_rows() {
        // ghostty: "PageList clone" (PageList.zig:9812)
        let list = PageList::new(80, 24, None);
        let cloned = list.clone(CloneOptions {
            top: Point::screen(0, 0),
            bot: None,
            tracked_pins: None,
        });
        assert_eq!(cloned.total_rows(), list.total_rows());
        assert_eq!(cloned.rows, list.rows);
        assert_eq!(cloned.viewport(), Viewport::Active);
    }

    #[test]
    fn clone_partial_trimmed_right() {
        // ghostty: "PageList clone partial trimmed right" (PageList.zig:9827)
        let mut list = PageList::new(80, 20, None);
        list.grow_rows(30);
        let cloned = list.clone(CloneOptions {
            top: Point::screen(0, 0),
            bot: Some(Point::screen(0, 39)),
            tracked_pins: None,
        });
        assert_eq!(cloned.total_rows(), 40);
    }

    #[test]
    fn clone_partial_trimmed_left() {
        // ghostty: "PageList clone partial trimmed left" (PageList.zig:9844)
        let mut list = PageList::new(80, 20, None);
        list.grow_rows(30);
        let cloned = list.clone(CloneOptions {
            top: Point::screen(0, 10),
            bot: None,
            tracked_pins: None,
        });
        assert_eq!(cloned.total_rows(), 40);
    }

    #[test]
    fn clone_partial_trimmed_left_reclaims_styles() {
        // ghostty: "PageList clone partial trimmed left reclaims styles" (PageList.zig:9860)
        let mut list = PageList::new(80, 20, None);
        list.grow_rows(30);
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            let style = node.page.add_style(PackedStyle(7)).unwrap();
            for y in 0..10 {
                node.page.set_cell(y, 0, Cell::new('A'));
                node.page.set_style_id_raw(y, 0, style);
                node.page.use_style(style);
            }
            node.page.release_style(style);
            assert_eq!(node.page.style_count(), 1);
        }
        let cloned = list.clone(CloneOptions {
            top: Point::screen(0, 10),
            bot: None,
            tracked_pins: None,
        });
        assert_eq!(cloned.total_rows(), 40);
        assert_eq!(
            cloned
                .node(cloned.first_node().unwrap())
                .unwrap()
                .page
                .style_count(),
            0
        );
    }

    #[test]
    fn clone_partial_trimmed_both() {
        // ghostty: "PageList clone partial trimmed both" (PageList.zig:9909)
        let mut list = PageList::new(80, 20, None);
        list.grow_rows(30);
        let cloned = list.clone(CloneOptions {
            top: Point::screen(0, 10),
            bot: Some(Point::screen(0, 35)),
            tracked_pins: None,
        });
        assert_eq!(cloned.total_rows(), 26);
    }

    #[test]
    fn clone_less_than_active_pads_to_active_rows() {
        // ghostty: "PageList clone less than active" (PageList.zig:9926)
        let list = PageList::new(80, 24, None);
        let cloned = list.clone(CloneOptions {
            top: Point::active(0, 5),
            bot: None,
            tracked_pins: None,
        });
        assert_eq!(cloned.total_rows(), 24);
    }

    #[test]
    fn clone_remaps_tracked_pin_inside_region() {
        // ghostty: "PageList clone remap tracked pin" (PageList.zig:9941)
        let mut list = PageList::new(80, 24, None);
        let pin = list.track_pin(list.pin(Point::active(0, 6)).unwrap());
        let mut map = std::collections::HashMap::new();
        let cloned = list.clone(CloneOptions {
            top: Point::active(0, 5),
            bot: None,
            tracked_pins: Some(&mut map),
        });
        let cloned_id = map.get(&pin).copied().unwrap();
        assert_eq!(
            cloned.point_from_pin(Tag::Active, cloned.tracked_pin(cloned_id).unwrap()),
            Some(Point::active(0, 1))
        );
    }

    #[test]
    fn clone_omits_tracked_pin_outside_region() {
        // ghostty: "PageList clone remap tracked pin not in cloned area" (PageList.zig:9969)
        let mut list = PageList::new(80, 24, None);
        let pin = list.track_pin(list.pin(Point::active(0, 3)).unwrap());
        let mut map = std::collections::HashMap::new();
        let _cloned = list.clone(CloneOptions {
            top: Point::active(0, 5),
            bot: None,
            tracked_pins: Some(&mut map),
        });
        assert!(!map.contains_key(&pin));
    }

    #[test]
    fn clone_full_preserves_row_dirty_pattern() {
        // ghostty: "PageList clone full dirty" (PageList.zig:9993)
        let mut list = PageList::new(80, 24, None);
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            for y in 0..24 {
                node.page.set_row_dirty(y, false);
            }
        }
        for y in [0, 12, 23] {
            let pin = list.pin(Point::active(0, y)).unwrap();
            list.mark_dirty(pin);
        }
        let cloned = list.clone(CloneOptions {
            top: Point::screen(0, 0),
            bot: None,
            tracked_pins: None,
        });
        let first = cloned.first_node().unwrap();
        let page = &cloned.node(first).unwrap().page;
        assert!(page.row_dirty(0));
        assert!(!page.row_dirty(1));
        assert!(page.row_dirty(12));
        assert!(!page.row_dirty(14));
        assert!(page.row_dirty(23));
    }

    #[test]
    fn resize_without_reflow_more_rows() {
        // ghostty: "PageList resize (no reflow) more rows" (PageList.zig:10020)
        let mut list = PageList::new(10, 3, Some(0));
        let pin = list.track_pin(list.pin(Point::active(0, 2)).unwrap());
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(10),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 10);
        assert_eq!(list.total_rows(), 10);
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(0, 2))
        );
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 0))
        );
    }

    #[test]
    fn resize_without_reflow_more_rows_with_history_pulls_scrollback_down() {
        // ghostty: "PageList resize (no reflow) more rows with history" (PageList.zig:10053)
        let mut list = PageList::new(10, 3, None);
        list.grow_rows(50);
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 50))
        );
        let pin = list.track_pin(list.pin(Point::active(0, 2)).unwrap());
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(5),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 5);
        assert_eq!(list.total_rows(), 53);
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(0, 4))
        );
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 48))
        );
    }

    #[test]
    fn resize_without_reflow_less_rows_keeps_non_blank_scrollback() {
        // ghostty: "PageList resize (no reflow) less rows" (PageList.zig:10092)
        let mut list = PageList::new(10, 10, Some(0));
        fill_all_rows_text(&mut list, 'A');
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(5),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 5);
        assert_eq!(list.total_rows(), 10);
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 5))
        );
    }

    #[test]
    fn resize_without_reflow_one_row_keeps_non_blank_scrollback() {
        // ghostty: "PageList resize (no reflow) one rows" (PageList.zig:10126)
        let mut list = PageList::new(10, 10, Some(0));
        fill_all_rows_text(&mut list, 'A');
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(1),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 1);
        assert_eq!(list.total_rows(), 10);
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 9))
        );
    }

    #[test]
    fn resize_without_reflow_less_rows_cursor_on_bottom_stays_active_bottom() {
        // ghostty: "PageList resize (no reflow) less rows cursor on bottom" (PageList.zig:10160)
        let mut list = PageList::new(10, 10, Some(0));
        for y in 0..10 {
            set_screen_cell(&mut list, 0, y, char::from(b'0' + y as u8));
        }
        let pin = list.track_pin(list.pin(Point::active(0, 9)).unwrap());
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(5),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(0, 4))
        );
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 5))
        );
    }

    #[test]
    fn resize_without_reflow_less_rows_cursor_in_scrollback() {
        // ghostty: "PageList resize (no reflow) less rows cursor in scrollback" (PageList.zig:10212)
        let mut list = PageList::new(10, 10, Some(0));
        for y in 0..10 {
            set_screen_cell(&mut list, 0, y, char::from(b'0' + y as u8));
        }
        let pin = list.track_pin(list.pin(Point::active(0, 2)).unwrap());
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(5),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        let tracked = list.tracked_pin(pin).unwrap();
        assert_eq!(list.point_from_pin(Tag::Active, tracked), None);
        assert_eq!(
            list.point_from_pin(Tag::Screen, tracked),
            Some(Point::screen(0, 2))
        );
    }

    #[test]
    fn resize_without_reflow_less_rows_trims_bg_only_blank_lines() {
        // ghostty: "PageList resize (no reflow) less rows trims blank lines" (PageList.zig:10266)
        let mut list = PageList::new(10, 5, Some(0));
        set_screen_cell(&mut list, 0, 0, 'A');
        if let Some(node) = list.node_mut(list.first_node().unwrap()) {
            for y in 1..5 {
                node.page.set_cell(
                    y,
                    0,
                    Cell::bg_rgb(Rgb {
                        r: 0xFF,
                        g: 0,
                        b: 0,
                    }),
                );
            }
        }
        let pin = list.track_pin(list.pin(Point::active(0, 0)).unwrap());
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(2),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 2);
        assert_eq!(list.total_rows(), 2);
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(0, 0))
        );
    }

    #[test]
    fn resize_without_reflow_pin_on_blank_row_blocks_trim() {
        // ghostty: "PageList resize (no reflow) less rows trims blank lines cursor in blank line" (PageList.zig:10325)
        let mut list = PageList::new(10, 5, Some(0));
        set_screen_cell(&mut list, 0, 0, 'A');
        let pin = list.track_pin(list.pin(Point::active(0, 3)).unwrap());
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(2),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 2);
        assert_eq!(list.total_rows(), 4);
        assert!(list
            .point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap())
            .is_some());
    }

    #[test]
    fn resize_without_reflow_trim_erases_emptied_second_page() {
        // ghostty: "PageList resize (no reflow) less rows trims blank lines erases pages" (PageList.zig:10368)
        let mut list = PageList::new(100, 5, Some(0));
        let first = list.first_node().unwrap();
        let cap_rows = list.node_capacity(first).unwrap().rows;
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(cap_rows + 10),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_pages(), 2);
        set_screen_cell(&mut list, 0, 0, 'A');
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(5),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 5);
        assert_eq!(list.total_rows(), 5);
        assert_eq!(list.total_pages(), 1);
    }

    #[test]
    fn resize_without_reflow_more_rows_extends_blank_lines() {
        // ghostty: "PageList resize (no reflow) more rows extends blank lines" (PageList.zig:10401)
        let mut list = PageList::new(10, 3, Some(0));
        set_screen_cell(&mut list, 0, 0, 'A');
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(7),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 7);
        assert_eq!(list.total_rows(), 7);
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 0))
        );
    }

    #[test]
    fn resize_without_reflow_more_rows_keeps_top_viewport_contained() {
        // ghostty: "PageList resize (no reflow) more rows contains viewport" (PageList.zig:10441)
        let mut list = PageList::new(5, 5, Some(1));
        let _ = list.grow();
        list.scroll(Scroll::DeltaRow(-1));
        assert_eq!(list.viewport(), Viewport::Top);
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(7),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 7);
        assert_eq!(list.total_rows(), 7);
        assert_eq!(list.viewport(), Viewport::Top);
    }

    #[test]
    fn resize_without_reflow_less_cols() {
        // ghostty: "PageList resize (no reflow) less cols" (PageList.zig:10473)
        let mut list = PageList::new(10, 10, Some(0));
        list.resize_without_reflow(ResizeOptions {
            cols: Some(5),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.cols, 5);
        assert_all_rows_have_cols(&list, 5);
    }

    #[test]
    fn resize_without_reflow_less_cols_clamps_pins() {
        // ghostty: "PageList resize (no reflow) less cols pin in trimmed cols" (PageList.zig:10493)
        let mut list = PageList::new(10, 10, Some(0));
        let pin = list.track_pin(list.pin(Point::active(8, 2)).unwrap());
        list.resize_without_reflow(ResizeOptions {
            cols: Some(5),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.tracked_pin(pin).unwrap().x, 4);
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(4, 2))
        );
    }

    #[test]
    fn resize_without_reflow_less_cols_frees_graphemes() {
        // ghostty: "PageList resize (no reflow) less cols clears graphemes" (PageList.zig:10522)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            node.page.set_cell(0, 9, Cell::new('A'));
            node.page.append_grapheme(0, 9, 'A' as u32).unwrap();
            assert_eq!(node.page.grapheme_count(), 1);
        }
        list.resize_without_reflow(ResizeOptions {
            cols: Some(5),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        for id in list.iter_node_ids() {
            assert_eq!(list.node(id).unwrap().page.grapheme_count(), 0);
        }
    }

    #[test]
    fn resize_without_reflow_more_cols() {
        // ghostty: "PageList resize (no reflow) more cols" (PageList.zig:10552)
        let mut list = PageList::new(5, 3, Some(0));
        list.resize_without_reflow(ResizeOptions {
            cols: Some(10),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.cols, 10);
        assert_eq!(list.total_rows(), 3);
        assert_all_rows_have_cols(&list, 10);
    }

    #[test]
    fn resize_without_reflow_more_cols_with_spacer_head_uses_slow_path() {
        // ghostty: "PageList resize (no reflow) more cols with spacer head" (PageList.zig:10572)
        let mut list = PageList::new(2, 3, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            let mut row0 = node.page.row(0);
            row0.set_wrap(true);
            node.page.set_row(0, row0);
            node.page.set_cell(0, 0, Cell::new('x'));
            let mut head = Cell::default();
            head.set_wide(CellWide::SpacerHead);
            node.page.set_cell(0, 1, head);
            let mut wide = Cell::new('😀');
            wide.set_wide(CellWide::Wide);
            node.page.set_cell(1, 0, wide);
            let mut tail = Cell::default();
            tail.set_wide(CellWide::SpacerTail);
            node.page.set_cell(1, 1, tail);
        }
        list.resize_without_reflow(ResizeOptions {
            cols: Some(3),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        let first = list.first_node().unwrap();
        let page = &list.node(first).unwrap().page;
        assert_eq!(page.cell(0, 0), Cell::new('x'));
        assert_eq!(page.cell(0, 1).wide(), CellWide::Narrow);
        assert!(!page.row(0).wrap());
        assert_eq!(page.cell(1, 0).wide(), CellWide::Wide);
        assert_eq!(page.cell(1, 1).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn resize_without_reflow_grow_cols_fast_path_rejects_spacer_head() {
        // ghostty: "PageList resize (no reflow) grow cols fast path with spacer head" (PageList.zig:10649)
        let mut list = PageList::new(10, 3, Some(0));
        list.resize_without_reflow(ResizeOptions {
            cols: Some(5),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            for y in [0, 1] {
                let mut head = Cell::default();
                head.set_wide(CellWide::SpacerHead);
                node.page.set_cell(y, 4, head);
                let mut row = node.page.row(y);
                row.set_wrap(true);
                node.page.set_row(y, row);
            }
        }
        list.resize_without_reflow(ResizeOptions {
            cols: Some(10),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        let page = &list.node(list.first_node().unwrap()).unwrap().page;
        assert_eq!(page.cell(0, 4).wide(), CellWide::Narrow);
        assert_eq!(page.cell(1, 4).wide(), CellWide::Narrow);
        assert!(!page.row(0).wrap());
        assert!(!page.row(1).wrap());
    }

    #[test]
    fn resize_without_reflow_more_cols_forces_smaller_page_capacity() {
        // ghostty: "PageList resize (no reflow) more cols forces less rows per page" (PageList.zig:10724)
        let rows: CellCountInt = 150;
        let mut list = PageList::new(5, rows, Some(0));
        let mut new_cols: CellCountInt = 50;
        while PageList::initial_capacity(new_cols).rows >= rows {
            new_cols += 50;
        }
        list.resize_without_reflow(ResizeOptions {
            cols: Some(new_cols),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_rows(), rows as usize);
        for id in list.iter_node_ids() {
            if Some(id) != list.last_node() {
                let node = list.node(id).unwrap();
                assert_eq!(node.page.size().rows, node.page.capacity().rows);
            }
        }

        let current_first_size_rows = list
            .node_page_size(list.first_node().unwrap())
            .unwrap()
            .rows;
        let mut new_cols2 = new_cols + 50;
        while PageList::initial_capacity(new_cols2).rows >= current_first_size_rows {
            new_cols2 += 50;
        }
        list.resize_without_reflow(ResizeOptions {
            cols: Some(new_cols2),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.cols, new_cols2);
        assert_eq!(list.total_rows(), rows as usize);
        for id in list.iter_node_ids() {
            if Some(id) != list.last_node() {
                let node = list.node(id).unwrap();
                assert_eq!(node.page.size().rows, node.page.capacity().rows);
            }
        }
    }

    #[test]
    fn resize_without_reflow_less_cols_then_more_cols_fast_path() {
        // ghostty: "PageList resize (no reflow) less cols then more cols" (PageList.zig:10793)
        let mut list = PageList::new(5, 3, Some(0));
        list.resize_without_reflow(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        list.resize_without_reflow(ResizeOptions {
            cols: Some(5),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_rows(), 3);
        assert_all_rows_have_cols(&list, 5);
    }

    #[test]
    fn resize_without_reflow_less_rows_and_cols() {
        // ghostty: "PageList resize (no reflow) less rows and cols" (PageList.zig:10817)
        let mut list = PageList::new(10, 10, Some(0));
        list.resize_without_reflow(ResizeOptions {
            cols: Some(5),
            rows: Some(7),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!((list.cols, list.rows), (5, 7));
        assert_all_rows_have_cols(&list, 5);
    }

    #[test]
    fn resize_less_rows_and_cols_cursor_at_bottom() {
        // ghostty: "PageList resize less rows and cols cursor at bottom" (PageList.zig:10837)
        let mut list = PageList::new(80, 24, Some(0));
        let pin = list.track_pin(list.pin(Point::active(0, 23)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(79),
            rows: Some(20),
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 0,
                y: 23,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!((list.cols, list.rows), (79, 20));
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(0, 19))
        );
    }

    #[test]
    fn resize_less_rows_and_cols_cursor_near_top_pushed_to_scrollback() {
        // ghostty: "PageList resize less rows and cols cursor near top pushed to scrollback" (PageList.zig:10868)
        let mut list = PageList::new(80, 24, None);
        for y in 0..list.rows {
            for x in 0..list.cols {
                set_screen_cell(
                    &mut list,
                    x,
                    u32::from(y),
                    char::from(b'A' + (x % 26) as u8),
                );
            }
        }
        let pin = list.track_pin(list.pin(Point::active(0, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(79),
            rows: Some(20),
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 0,
                y: 0,
                pin: Some(pin),
            }),
        })
        .unwrap();
        let tracked = list.tracked_pin(pin).unwrap();
        assert_eq!((list.cols, list.rows), (79, 20));
        assert_eq!(list.point_from_pin(Tag::Active, tracked), None);
        assert!(list.point_from_pin(Tag::Screen, tracked).is_some());
    }

    #[test]
    fn resize_more_rows_and_cols_does_not_fit_in_single_std_page() {
        // ghostty: "PageList resize more rows and cols doesn't fit in single std page" (PageList.zig:10941)
        let mut list = PageList::new(10, 10, Some(0));
        let new_cols = 600;
        let new_rows = 600;
        assert!(PageList::initial_capacity(new_cols).rows < new_rows);
        list.resize(ResizeOptions {
            cols: Some(new_cols),
            rows: Some(new_rows),
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!((list.cols, list.rows), (new_cols, new_rows));
        assert_eq!(list.total_rows(), new_rows as usize);
    }

    #[test]
    fn reflow_more_cols_no_wrapped_rows() {
        // ghostty: "PageList resize reflow more cols no wrapped rows" (PageList.zig:11094)
        let mut list = PageList::new(5, 3, Some(0));
        for y in 0..3 {
            set_screen_row_cells(&mut list, y, &['A', 'A', 'A', 'A', 'A']);
        }
        list.resize(ResizeOptions {
            cols: Some(10),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!((list.cols, list.total_rows()), (10, 3));
        for y in 0..3 {
            for x in 0..5 {
                assert_eq!(screen_cell(&list, x, y), Cell::new('A'));
            }
            assert_eq!(screen_cell(&list, 5, y), Cell::default());
        }
    }

    #[test]
    fn reflow_more_cols_unwraps_wrapped_rows() {
        // ghostty: "PageList resize reflow more cols wrapped rows" (PageList.zig:11126)
        let mut list = PageList::new(2, 4, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        set_screen_row_cells(&mut list, 1, &['2', '3']);
        set_screen_row_cells(&mut list, 2, &['4', '5']);
        set_screen_row_cells(&mut list, 3, &['6', '7']);
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, false, true);
        set_screen_row_wrap(&mut list, 2, true, false);
        set_screen_row_wrap(&mut list, 3, false, true);
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_rows(), 4);
        assert_eq!(
            [
                screen_cell(&list, 0, 0),
                screen_cell(&list, 1, 0),
                screen_cell(&list, 2, 0),
                screen_cell(&list, 3, 0)
            ],
            [
                Cell::new('0'),
                Cell::new('1'),
                Cell::new('2'),
                Cell::new('3')
            ]
        );
        let row0 = list.pin(Point::screen(0, 0)).unwrap();
        assert!(!list.node(row0.node).unwrap().page.row(row0.y).wrap());
    }

    #[test]
    fn reflow_less_cols_wraps_rows() {
        // ghostty: "PageList resize reflow less cols wrapped rows" (PageList.zig:12562)
        let mut list = PageList::new(4, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1', '2', '3']);
        set_screen_row_cells(&mut list, 1, &['4', '5', '6', '7']);
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_rows(), 4);
        assert_eq!(
            list.point_from_pin(Tag::Screen, list.get_top_left(Tag::Active)),
            Some(Point::screen(0, 2))
        );
        assert_eq!(
            [screen_cell(&list, 0, 0), screen_cell(&list, 1, 0)],
            [Cell::new('0'), Cell::new('1')]
        );
        assert_eq!(
            [screen_cell(&list, 0, 1), screen_cell(&list, 1, 1)],
            [Cell::new('2'), Cell::new('3')]
        );
    }

    #[test]
    fn reflow_less_cols_cursor_in_wrapped_row() {
        // ghostty: "PageList resize reflow less cols cursor in wrapped row" (PageList.zig:12717)
        let mut list = PageList::new(4, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1', '2', '3']);
        set_screen_row_cells(&mut list, 1, &['4', '5', '6', '7']);
        let pin = list.track_pin(list.pin(Point::active(2, 1)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 2,
                y: 1,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(0, 1))
        );
    }

    #[test]
    fn reflow_less_cols_cursor_goes_to_scrollback() {
        // ghostty: "PageList resize reflow less cols cursor goes to scrollback" (PageList.zig:12847)
        let mut list = PageList::new(4, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1', '2', '3']);
        set_screen_row_cells(&mut list, 1, &['4', '5', '6', '7']);
        let pin = list.track_pin(list.pin(Point::active(2, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 2,
                y: 0,
                pin: Some(pin),
            }),
        })
        .unwrap();
        let tracked = list.tracked_pin(pin).unwrap();
        assert_eq!(list.point_from_pin(Tag::Active, tracked), None);
        assert_eq!(
            list.point_from_pin(Tag::Screen, tracked),
            Some(Point::screen(0, 1))
        );
    }

    #[test]
    fn reflow_less_cols_preserves_semantic_prompt_on_wrapped_rows() {
        // ghostty: "PageList resize reflow less cols no reflow preserves semantic prompt" (PageList.zig:12429)
        let mut list = PageList::new(4, 4, Some(0));
        set_screen_row_cells(&mut list, 1, &['0', '1', '2', '3']);
        set_screen_row_prompt(&mut list, 1, SemanticPrompt::Prompt);
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        let row1 = list.pin(Point::screen(0, 1)).unwrap();
        let row2 = list.pin(Point::screen(0, 2)).unwrap();
        assert_eq!(
            list.node(row1.node)
                .unwrap()
                .page
                .row(row1.y)
                .semantic_prompt(),
            SemanticPrompt::Prompt
        );
        assert_eq!(
            list.node(row2.node)
                .unwrap()
                .page
                .row(row2.y)
                .semantic_prompt(),
            SemanticPrompt::Prompt
        );
    }

    #[test]
    fn reflow_less_cols_copies_graphemes() {
        // ghostty: "PageList resize reflow less cols wrapped rows with graphemes" (PageList.zig:12631)
        let mut list = PageList::new(4, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1', '2', '3']);
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            node.page.append_grapheme(0, 2, 'A' as u32).unwrap();
        }
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        let pin = list.pin(Point::screen(0, 1)).unwrap();
        assert_eq!(
            list.node(pin.node).unwrap().page.grapheme(pin.y, pin.x),
            Some(vec!['A' as u32])
        );
    }

    #[test]
    fn reflow_less_cols_copies_style() {
        // ghostty: "PageList resize reflow less cols copy style" (PageList.zig:13210)
        let mut list = PageList::new(4, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1', '2', '3']);
        let style = PackedStyle(7);
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            for x in 0..3 {
                node.page.set_style(0, x, style).unwrap();
            }
        }
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        let row0 = list.pin(Point::screen(0, 0)).unwrap();
        let row1 = list.pin(Point::screen(0, 1)).unwrap();
        let page0 = &list.node(row0.node).unwrap().page;
        let page1 = &list.node(row1.node).unwrap().page;
        assert!(page0.row(row0.y).styled());
        assert!(page1.row(row1.y).styled());
        assert_ne!(page0.cell(row0.y, 0).style_id(), 0);
        assert_ne!(page0.cell(row0.y, 1).style_id(), 0);
        assert_ne!(page1.cell(row1.y, 0).style_id(), 0);
    }

    #[test]
    fn reflow_more_cols_cursor_in_wrapped_row() {
        // ghostty: "PageList resize reflow more cols cursor in wrapped row" (PageList.zig:11688)
        let mut list = PageList::new(2, 4, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        set_screen_row_cells(&mut list, 1, &['2', '3']);
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, false, true);
        let pin = list.track_pin(list.pin(Point::active(1, 1)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(3, 0))
        );
    }

    #[test]
    fn reflow_more_cols_cursor_in_not_wrapped_row() {
        // ghostty: "PageList resize reflow more cols cursor in not wrapped row" (PageList.zig:11739)
        let mut list = PageList::new(2, 4, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        set_screen_row_cells(&mut list, 1, &['2', '3']);
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, false, true);
        let pin = list.track_pin(list.pin(Point::active(1, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 1,
                y: 0,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(1, 0))
        );
    }

    #[test]
    fn reflow_more_cols_cursor_in_wrapped_row_that_isnt_unwrapped() {
        // ghostty: "PageList resize reflow more cols cursor in wrapped row that isn't unwrapped" (PageList.zig:11790)
        let mut list = PageList::new(2, 3, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        set_screen_row_cells(&mut list, 1, &['2', '3']);
        set_screen_row_cells(&mut list, 2, &['4', '5']);
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, true, true);
        set_screen_row_wrap(&mut list, 2, false, true);
        let pin = list.track_pin(list.pin(Point::active(1, 2)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 1,
                y: 2,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(1, 1))
        );
    }

    #[test]
    fn reflow_more_cols_preserves_semantic_prompt_on_blank_row() {
        // ghostty: "PageList resize reflow more cols no reflow preserves semantic prompt" (PageList.zig:11855)
        let mut list = PageList::new(2, 4, Some(0));
        set_screen_row_prompt(&mut list, 1, SemanticPrompt::Prompt);
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        let pin = list.pin(Point::screen(0, 1)).unwrap();
        assert_eq!(
            list.node(pin.node)
                .unwrap()
                .page
                .row(pin.y)
                .semantic_prompt(),
            SemanticPrompt::Prompt
        );
    }

    #[test]
    fn reflow_less_cols_preserves_semantic_prompt_on_first_line() {
        // ghostty: "PageList resize reflow less cols no reflow preserves semantic prompt on first line" (PageList.zig:12472)
        let mut list = PageList::new(4, 4, Some(0));
        set_screen_row_prompt(&mut list, 0, SemanticPrompt::Prompt);
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        let pin = list.pin(Point::screen(0, 0)).unwrap();
        assert_eq!(
            list.node(pin.node)
                .unwrap()
                .page
                .row(pin.y)
                .semantic_prompt(),
            SemanticPrompt::Prompt
        );
    }

    #[test]
    fn reflow_less_cols_no_wrapped_rows() {
        // ghostty: "PageList resize reflow less cols no wrapped rows" (PageList.zig:12524)
        let mut list = PageList::new(10, 3, Some(0));
        for y in 0..3 {
            set_screen_row_cells(&mut list, y, &['0', '1', '2', '3']);
        }
        list.resize(ResizeOptions {
            cols: Some(5),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_rows(), 3);
        for y in 0..3 {
            let pin = list.pin(Point::screen(0, y)).unwrap();
            assert!(!list.node(pin.node).unwrap().page.row(pin.y).wrap());
        }
    }

    #[test]
    fn reflow_less_cols_cursor_in_unchanged_row() {
        // ghostty: "PageList resize reflow less cols cursor in unchanged row" (PageList.zig:12878)
        let mut list = PageList::new(4, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        let pin = list.track_pin(list.pin(Point::active(1, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 1,
                y: 0,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(1, 0))
        );
    }

    #[test]
    fn reflow_less_cols_cursor_in_blank_cell() {
        // ghostty: "PageList resize reflow less cols cursor in blank cell" (PageList.zig:12912)
        let mut list = PageList::new(6, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        let pin = list.track_pin(list.pin(Point::active(2, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 2,
                y: 0,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(2, 0))
        );
    }

    #[test]
    fn reflow_less_cols_cursor_in_final_blank_cell() {
        // ghostty: "PageList resize reflow less cols cursor in final blank cell" (PageList.zig:12946)
        let mut list = PageList::new(6, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        let pin = list.track_pin(list.pin(Point::active(3, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 3,
                y: 0,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(3, 0))
        );
    }

    #[test]
    fn reflow_less_cols_cursor_in_wrapped_blank_cell() {
        // ghostty: "PageList resize reflow less cols cursor in wrapped blank cell" (PageList.zig:12980)
        let mut list = PageList::new(6, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        let pin = list.track_pin(list.pin(Point::active(5, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(3, 0))
        );
    }

    #[test]
    fn reflow_less_cols_to_eliminate_a_wide_char() {
        // ghostty: "PageList resize reflow less cols to eliminate a wide char" (PageList.zig:13264)
        let mut list = PageList::new(2, 1, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            let mut wide = Cell::new('😀');
            wide.set_wide(CellWide::Wide);
            node.page.set_cell(0, 0, wide);
            let mut tail = Cell::default();
            tail.set_wide(CellWide::SpacerTail);
            node.page.set_cell(0, 1, tail);
        }
        list.resize(ResizeOptions {
            cols: Some(1),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 0, 0), Cell::default());
    }

    #[test]
    fn reflow_less_cols_to_wrap_a_wide_char() {
        // ghostty: "PageList resize reflow less cols to wrap a wide char" (PageList.zig:13309)
        let mut list = PageList::new(3, 1, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            node.page.set_cell(0, 0, Cell::new('x'));
            let mut wide = Cell::new('😀');
            wide.set_wide(CellWide::Wide);
            node.page.set_cell(0, 1, wide);
            let mut tail = Cell::default();
            tail.set_wide(CellWide::SpacerTail);
            node.page.set_cell(0, 2, tail);
        }
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 0, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 1, 0).wide(), CellWide::SpacerHead);
        assert_eq!(screen_cell(&list, 0, 1).wide(), CellWide::Wide);
        assert_eq!(screen_cell(&list, 1, 1).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn reflow_more_cols_unwrap_wide_spacer_head() {
        // ghostty: "PageList resize reflow more cols unwrap wide spacer head" (PageList.zig:12171)
        let mut list = PageList::new(2, 2, Some(0));
        set_screen_cell(&mut list, 0, 0, 'x');
        set_screen_spacer_head(&mut list, 1, 0);
        set_screen_wide_pair(&mut list, 0, 1, '😀');
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, false, true);
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 0, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 1, 0).wide(), CellWide::Wide);
        assert_eq!(screen_cell(&list, 2, 0).wide(), CellWide::SpacerTail);
        assert_eq!(screen_cell(&list, 3, 0), Cell::default());
    }

    #[test]
    fn reflow_more_cols_unwrap_still_requires_wide_spacer_head() {
        // ghostty: "PageList resize reflow more cols unwrap still requires wide spacer head" (PageList.zig:12348)
        let mut list = PageList::new(2, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['x', 'x']);
        set_screen_wide_pair(&mut list, 0, 1, '😀');
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, false, true);
        list.resize(ResizeOptions {
            cols: Some(3),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 0, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 1, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 2, 0).wide(), CellWide::SpacerHead);
        assert_eq!(screen_cell(&list, 0, 1).wide(), CellWide::Wide);
        assert_eq!(screen_cell(&list, 1, 1).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn reflow_more_cols_unwrap_wide_spacer_head_across_two_rows() {
        // ghostty: "PageList resize reflow more cols unwrap wide spacer head across two rows" (PageList.zig:12244)
        let mut list = PageList::new(2, 3, Some(0));
        set_screen_row_cells(&mut list, 0, &['x', 'x']);
        set_screen_cell(&mut list, 0, 1, 'x');
        set_screen_spacer_head(&mut list, 1, 1);
        set_screen_wide_pair(&mut list, 0, 2, '😀');
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, true, true);
        set_screen_row_wrap(&mut list, 2, false, true);
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 0, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 1, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 2, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 3, 0).wide(), CellWide::SpacerHead);
        assert_eq!(screen_cell(&list, 0, 1).wide(), CellWide::Wide);
        assert_eq!(screen_cell(&list, 1, 1).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn reflow_less_cols_wraps_spacer_head() {
        // ghostty: "PageList resize reflow less cols wraps spacer head" (PageList.zig:12751)
        let mut list = PageList::new(4, 3, Some(0));
        set_screen_row_cells(&mut list, 0, &['x', 'x', 'x']);
        set_screen_spacer_head(&mut list, 3, 0);
        set_screen_wide_pair(&mut list, 0, 1, '😀');
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, false, true);
        list.resize(ResizeOptions {
            cols: Some(3),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 0, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 1, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 2, 0), Cell::new('x'));
        assert_eq!(screen_cell(&list, 0, 1).wide(), CellWide::Wide);
        assert_eq!(screen_cell(&list, 1, 1).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn reflow_less_cols_preserves_multi_codepoint_grapheme_with_spacer_head() {
        // ghostty: "PageList resize reflow less cols to wrap a multi-codepoint grapheme with a spacer head" (PageList.zig:13377)
        let mut list = PageList::new(4, 2, Some(0));
        set_screen_wide_pair(&mut list, 0, 0, '👨');
        set_screen_wide_pair(&mut list, 2, 0, '👨');
        let first = list.first_node().unwrap();
        let grapheme = [0x200D, 0x1F468, 0x200D, 0x1F466, 0x200D, 0x1F466];
        if let Some(node) = list.node_mut(first) {
            for codepoint in grapheme {
                node.page.append_grapheme(0, 0, codepoint).unwrap();
                node.page.append_grapheme(0, 2, codepoint).unwrap();
            }
        }
        list.resize(ResizeOptions {
            cols: Some(3),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        let row0 = list.pin(Point::screen(0, 0)).unwrap();
        let row1 = list.pin(Point::screen(0, 1)).unwrap();
        assert_eq!(
            list.node(row0.node).unwrap().page.grapheme(row0.y, 0),
            Some(grapheme.to_vec())
        );
        assert_eq!(
            list.node(row1.node).unwrap().page.grapheme(row1.y, 0),
            Some(grapheme.to_vec())
        );
    }

    #[test]
    fn reflow_more_cols_creates_multiple_pages() {
        // ghostty: "PageList resize reflow more cols creates multiple pages" (PageList.zig:11228)
        let rows = 100;
        let new_cols = (1..=CellCountInt::MAX)
            .find(|&cols| PageList::initial_capacity(cols).rows < rows)
            .unwrap();
        assert!(PageList::initial_capacity(new_cols).rows < rows);
        let mut list = PageList::new(10, rows, Some(0));
        for y in 0..rows {
            set_screen_cell(&mut list, 0, u32::from(y), 'A');
        }
        list.resize(ResizeOptions {
            cols: Some(new_cols),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_pages(), 1);
        for id in list.iter_node_ids() {
            assert_eq!(list.node_capacity(id).unwrap().cols, new_cols);
        }
    }

    #[test]
    fn reflow_more_cols_wrap_across_page_boundary() {
        // ghostty: "PageList resize reflow more cols wrap across page boundary" (PageList.zig:11292)
        let cap_rows = PageList::initial_capacity(2).rows;
        let mut list = PageList::new(2, cap_rows + 1, Some(0));
        set_screen_row_cells(&mut list, u32::from(cap_rows - 1), &['0', '1']);
        set_screen_row_cells(&mut list, u32::from(cap_rows), &['2', '3']);
        set_screen_row_wrap(&mut list, u32::from(cap_rows - 1), true, false);
        set_screen_row_wrap(&mut list, u32::from(cap_rows), false, true);
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(
            [
                screen_cell(&list, 0, u32::from(cap_rows - 1)),
                screen_cell(&list, 1, u32::from(cap_rows - 1)),
                screen_cell(&list, 2, u32::from(cap_rows - 1)),
                screen_cell(&list, 3, u32::from(cap_rows - 1)),
            ],
            [
                Cell::new('0'),
                Cell::new('1'),
                Cell::new('2'),
                Cell::new('3')
            ]
        );
    }

    #[test]
    fn reflow_more_cols_wrap_across_page_boundary_cursor_in_second_page() {
        // ghostty: "PageList resize reflow more cols wrap across page boundary cursor in second page" (PageList.zig:11423)
        let cap_rows = PageList::initial_capacity(2).rows;
        let mut list = PageList::new(2, cap_rows + 1, Some(0));
        set_screen_row_cells(&mut list, u32::from(cap_rows - 1), &['0', '1']);
        set_screen_row_cells(&mut list, u32::from(cap_rows), &['2', '3']);
        set_screen_row_wrap(&mut list, u32::from(cap_rows - 1), true, false);
        set_screen_row_wrap(&mut list, u32::from(cap_rows), false, true);
        let pin = list.track_pin(list.pin(Point::active(1, u32::from(cap_rows))).unwrap());
        assert_eq!(
            list.tracked_pin(pin).unwrap().node,
            list.last_node().unwrap()
        );
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 1,
                y: cap_rows,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(3, u32::from(cap_rows - 1)))
        );
    }

    #[test]
    fn resize_reflow_invalidates_viewport_offset_cache() {
        // ghostty: "PageList resize reflow invalidates viewport offset cache" (PageList.zig:11179)
        let mut list = PageList::new(2, 4, None);
        list.grow_rows(20);
        let first = list.first_node().unwrap();
        assert_eq!(list.iter_node_ids().count(), 1);
        if let Some(node) = list.node_mut(first) {
            for y in 0..4 {
                node.page.set_cell(y, 0, Cell::new('A'));
                node.page.set_cell(y, 1, Cell::new('A'));
                let mut row = node.page.row(y);
                row.set_wrap(y % 2 == 0);
                row.set_wrap_continuation(y % 2 == 1);
                node.page.set_row(y, row);
            }
        }
        let pin = list.pin(Point::screen(0, 10)).unwrap();
        list.scroll(Scroll::Pin(pin));
        assert_eq!(list.viewport(), Viewport::Pin);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: 10,
                len: 4,
            }
        );
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.cols, 4);
        assert_eq!(
            list.scrollbar(),
            Scrollbar {
                total: list.total_rows(),
                offset: 5,
                len: 4,
            }
        );
    }

    #[test]
    fn resize_reflow_less_cols_wrap_across_page_boundary_cursor_in_second_page() {
        // ghostty: "PageList resize reflow less cols wrap across page boundary cursor in second page" (PageList.zig:11509)
        let mut list = PageList::new(5, 10, None);
        let cap_rows = list.node_capacity(list.first_node().unwrap()).unwrap().rows;
        while node_rows(&list, list.first_node().unwrap()) < cap_rows {
            let _ = list.grow();
        }
        for _ in 0..5 {
            let _ = list.grow();
        }
        set_screen_row_cells(
            &mut list,
            u32::from(cap_rows - 1),
            &['0', '1', '2', '3', '4'],
        );
        set_screen_row_cells(&mut list, u32::from(cap_rows), &['0', '1', '2', '3', '4']);
        set_screen_row_wrap(&mut list, u32::from(cap_rows - 1), true, false);
        set_screen_row_wrap(&mut list, u32::from(cap_rows), false, true);
        let pin = list.track_pin(list.pin(Point::active(2, 5)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 2,
                y: 5,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(3, 5))
        );
        assert_eq!(
            [
                active_cell(&list, 0, 4),
                active_cell(&list, 1, 4),
                active_cell(&list, 2, 4),
                active_cell(&list, 3, 4),
            ],
            [
                Cell::new('0'),
                Cell::new('1'),
                Cell::new('2'),
                Cell::new('3')
            ]
        );
        assert_eq!(
            [
                active_cell(&list, 0, 5),
                active_cell(&list, 1, 5),
                active_cell(&list, 2, 5),
                active_cell(&list, 3, 5),
            ],
            [
                Cell::new('4'),
                Cell::new('0'),
                Cell::new('1'),
                Cell::new('2')
            ]
        );
        assert_eq!(
            [
                active_cell(&list, 0, 6),
                active_cell(&list, 1, 6),
                active_cell(&list, 2, 6),
                active_cell(&list, 3, 6),
            ],
            [
                Cell::new('3'),
                Cell::new('4'),
                Cell::default(),
                Cell::default()
            ]
        );
        assert!(active_row(&list, 4).wrap());
        assert!(!active_row(&list, 4).wrap_continuation());
        assert!(active_row(&list, 5).wrap());
        assert!(active_row(&list, 5).wrap_continuation());
        assert!(!active_row(&list, 6).wrap());
        assert!(active_row(&list, 6).wrap_continuation());
        assert_eq!(
            [
                active_cell(&list, 0, 7),
                active_cell(&list, 1, 7),
                active_cell(&list, 2, 7),
                active_cell(&list, 3, 7),
            ],
            [
                Cell::default(),
                Cell::default(),
                Cell::default(),
                Cell::default()
            ]
        );
    }

    #[test]
    fn resize_reflow_exceeds_hyperlink_memory_forcing_capacity_increase() {
        // ghostty: "PageList resize reflow exceeds hyperlink memory forcing capacity increase" (PageList.zig:11881)
        let mut list = PageList::new(2, 10, Some(0));
        let (first, second) = grow_until_second_page(&mut list);
        let first_y = list.node_page_size(first).unwrap().rows - 1;
        let original_string_bytes = list.node_capacity(first).unwrap().string_bytes;
        if let Some(node) = list.node_mut(first) {
            node.page.set_cell(first_y, 1, Cell::new('X'));
            let mut row = node.page.row(first_y);
            row.set_wrap(true);
            node.page.set_row(first_y, row);
        }
        if let Some(node) = list.node_mut(second) {
            node.page.set_cell(0, 0, Cell::new('X'));
            let mut row = node.page.row(0);
            row.set_wrap_continuation(true);
            node.page.set_row(0, row);
        }
        let first_len = attach_largest_fitting_hyperlink(&mut list, first, first_y, 1, 0);
        let second_len = attach_largest_fitting_hyperlink(&mut list, second, 0, 0, 1);
        assert!(first_len > 0 && second_len > 0);
        list.resize(ResizeOptions {
            cols: Some(3),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert!(list
            .iter_node_ids()
            .any(|id| list.node_capacity(id).unwrap().string_bytes > original_string_bytes));
    }

    #[test]
    fn resize_reflow_less_cols_wrap_preserves_semantic_prompt() {
        // ghostty: "PageList resize reflow less cols wrap preserves semantic prompt" (PageList.zig:12498)
        let mut list = PageList::new(4, 4, Some(0));
        assert_eq!(list.iter_node_ids().count(), 1);
        set_screen_row_prompt(&mut list, 0, SemanticPrompt::Prompt);
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        let row = list.pin(Point::screen(0, 0)).unwrap();
        assert_eq!(list.cols, 2);
        assert_eq!(list.total_rows(), 4);
        assert_eq!(list.iter_node_ids().count(), 1);
        assert_eq!(
            list.node(row.node)
                .unwrap()
                .page
                .row(row.y)
                .semantic_prompt(),
            SemanticPrompt::Prompt
        );
    }

    #[test]
    fn resize_reflow_less_cols_cursor_not_on_last_line_preserves_location() {
        // ghostty: "PageList resize reflow less cols cursor not on last line preserves location" (PageList.zig:13166)
        let mut list = PageList::new(5, 5, Some(1));
        assert_eq!(list.iter_node_ids().count(), 1);
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            for y in 0..5 {
                node.page.set_cell(y, 0, Cell::new('\0'));
                node.page.set_cell(y, 1, Cell::new('\u{1}'));
            }
        }
        list.grow_rows(5);
        let pin = list.track_pin(list.pin(Point::active(0, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 1,
                y: 1,
                pin: None,
            }),
        })
        .unwrap();
        assert_eq!(list.cols, 4);
        assert_eq!(list.total_rows(), 10);
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(0, 0))
        );
    }

    #[test]
    fn resize_reflow_grapheme_map_capacity_exceeded_across_many_rows() {
        // ghostty: "PageList resize reflow grapheme map capacity exceeded" (PageList.zig:13731)
        let mut list = PageList::new(4, 10, Some(0));
        let (first, second) = grow_until_second_page(&mut list);
        let grapheme_capacity = (list.node_capacity(first).unwrap().grapheme_bytes as usize
            / (std::mem::size_of::<u32>() * 4))
            .min(list.node_page_size(first).unwrap().rows as usize)
            .max(1);
        let gpp = grapheme_capacity / 2 + grapheme_capacity / 4;
        let first_size = list.node_page_size(first).unwrap();
        let first_start = first_size.rows.saturating_sub(gpp as CellCountInt);
        if let Some(node) = list.node_mut(first) {
            for y in first_start..first_size.rows {
                node.page.set_cell(y, 0, Cell::new('A'));
                node.page.append_grapheme(y, 0, 0x0301).unwrap();
            }
        }
        let second_rows = list.node_page_size(second).unwrap().rows;
        if let Some(node) = list.node_mut(second) {
            for y in 0..(gpp as CellCountInt).min(second_rows) {
                node.page.set_cell(y, 0, Cell::new('B'));
                node.page.append_grapheme(y, 0, 0x0302).unwrap();
            }
        }
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.cols, 2);
    }

    #[test]
    fn reflow_less_cols_bg_palette_cell_survives_trailing_trim() {
        // ghostty: Cell.isEmpty follows page.zig:2169-2181 for reflow trailing trim.
        let mut list = PageList::new(4, 1, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            node.page.set_cell(0, 3, Cell::bg_palette(12));
        }
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 1, 1), Cell::bg_palette(12));
    }

    #[test]
    fn reflow_less_cols_bg_rgb_cell_survives_trailing_trim() {
        // ghostty: Cell.isEmpty follows page.zig:2169-2181 for reflow trailing trim.
        let mut list = PageList::new(4, 1, Some(0));
        let rgb = Rgb { r: 1, g: 2, b: 3 };
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            node.page.set_cell(0, 3, Cell::bg_rgb(rgb));
        }
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 1, 1), Cell::bg_rgb(rgb));
    }

    #[test]
    fn reflow_less_cols_style_only_blank_is_trimmed() {
        // ghostty: Cell.isEmpty ignores style_id when trimming (page.zig:2169-2181).
        let mut list = PageList::new(4, 1, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            node.page.set_style(0, 3, PackedStyle(9)).unwrap();
        }
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_rows(), 1);
        assert_eq!(screen_cell(&list, 0, 0), Cell::default());
    }

    #[test]
    fn resize_reflow_exceeds_grapheme_memory_forcing_capacity_increase() {
        // ghostty: "PageList resize reflow exceeds grapheme memory forcing capacity increase" (PageList.zig:11975)
        // Sanctioned deviation from the Zig setup: upstream bulk-loads nearly a
        // full page budget into ONE cell via setGraphemes (unported). Our
        // per-cell hardening cap (GRAPHEME_MAX_PER_CELL) and appendGrapheme's
        // faithful alloc-before-free growth both forbid that shape, so the
        // same over-budget pressure is spread across four wrapped cells, each
        // safely below the cap. The assertion (reflow forces grapheme_bytes to
        // grow) is unchanged and stronger than upstream's error-free resize.
        let mut list = PageList::new(2, 10, Some(0));
        let (first, second) = grow_until_second_page(&mut list);
        let first_y = list.node_page_size(first).unwrap().rows - 1;
        let original_grapheme_bytes = list.node_capacity(first).unwrap().grapheme_bytes;
        let graphemes_per_cell = GRAPHEME_CHUNK_LEN * 17;
        assert!(graphemes_per_cell < GRAPHEME_MAX_PER_CELL);
        if let Some(node) = list.node_mut(first) {
            node.page
                .set_cell(first_y.saturating_sub(1), 0, Cell::new('P'));
            node.page.set_cell(first_y, 0, Cell::new('X'));
            node.page.set_cell(first_y, 1, Cell::new('X'));
            let mut row = node.page.row(first_y);
            row.set_wrap(true);
            node.page.set_row(first_y, row);
        }
        if let Some(node) = list.node_mut(second) {
            node.page.set_cell(0, 0, Cell::new('X'));
            node.page.set_cell(0, 1, Cell::new('X'));
            let mut row = node.page.row(0);
            row.set_wrap_continuation(true);
            node.page.set_row(0, row);
        }
        append_graphemes(&mut list, first, first_y, 0, graphemes_per_cell, 0x0300);
        append_graphemes(&mut list, first, first_y, 1, graphemes_per_cell, 0x0400);
        append_graphemes(&mut list, second, 0, 0, graphemes_per_cell, 0x0500);
        append_graphemes(&mut list, second, 0, 1, graphemes_per_cell, 0x0600);
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert!(list
            .iter_node_ids()
            .any(|id| list.node_capacity(id).unwrap().grapheme_bytes > original_grapheme_bytes));
    }

    #[test]
    fn resize_reflow_exceeds_style_memory_forcing_capacity_increase() {
        // ghostty: "PageList resize reflow exceeds style memory forcing capacity increase" (PageList.zig:12087)
        let cols = STD_CAPACITY.styles - 1;
        let mut list = PageList::new(cols, 10, Some(0));
        let (mut first, mut second) = grow_until_second_page(&mut list);
        let first_y = list.node_page_size(first).unwrap().rows - 1;
        let original_styles = list.node_capacity(first).unwrap().styles;
        if let Some(node) = list.node_mut(first) {
            for x in 0..cols {
                node.page.set_cell(first_y, x, Cell::new('X'));
            }
            let mut row = node.page.row(first_y);
            row.set_wrap(true);
            row.set_styled(true);
            node.page.set_row(first_y, row);
        }
        for x in 0..cols {
            let style = PackedStyle::from(Style {
                fg_color: StyleColor::Rgb(Rgb {
                    r: (x as u8).wrapping_add(1),
                    g: 17,
                    b: 31,
                }),
                ..Style::default()
            });
            first = set_style_growing(&mut list, first, first_y, x, style);
        }
        if let Some(node) = list.node_mut(second) {
            for x in 0..cols {
                node.page.set_cell(0, x, Cell::new('X'));
            }
            let mut row = node.page.row(0);
            row.set_wrap_continuation(true);
            row.set_styled(true);
            node.page.set_row(0, row);
        }
        for x in 0..cols {
            let style = PackedStyle::from(Style {
                fg_color: StyleColor::Rgb(Rgb {
                    r: (x as u8).wrapping_add(129),
                    g: 23,
                    b: 47,
                }),
                ..Style::default()
            });
            second = set_style_growing(&mut list, second, 0, x, style);
        }
        list.resize(ResizeOptions {
            cols: Some(cols.saturating_mul(2)),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert!(list
            .iter_node_ids()
            .any(|id| list.node_capacity(id).unwrap().styles > original_styles));
        let styled_cells = list
            .iter_node_ids()
            .map(|id| {
                let node = list.node(id).unwrap();
                let size = node.page.size();
                let mut count = 0usize;
                for y in 0..size.rows {
                    for x in 0..size.cols {
                        let cell = node.page.cell(y, x);
                        if cell.style_id() != 0 {
                            assert!(node.page.style_for_cell(y, x).is_some());
                            count += 1;
                        }
                    }
                }
                count
            })
            .sum::<usize>();
        assert!(styled_cells >= cols as usize);
    }

    // ghostty: "PageList resize reflow less cols copy kitty placeholder" (PageList.zig:13496)
    // ghostty: "PageList resize reflow more cols clears kitty placeholder" (PageList.zig:13537)
    // ghostty: "PageList resize reflow wrap moves kitty placeholder" (PageList.zig:13580)
    // kitty graphics unsupported in this port; row bit fixed false.

    #[test]
    fn resize_reflow_rows_only_keeps_existing_column_layout() {
        // ghostty: resize() rows-only dispatches through resize_without_reflow (PageList.zig:980-1004).
        let mut list = PageList::new(2, 4, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        set_screen_row_cells(&mut list, 1, &['2', '3']);
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, false, true);
        list.resize(ResizeOptions {
            cols: None,
            rows: Some(3),
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!((list.cols, list.rows), (2, 3));
        assert_eq!(screen_cell(&list, 0, 0), Cell::new('0'));
        assert_eq!(screen_cell(&list, 0, 1), Cell::new('2'));
    }

    #[test]
    fn resize_reflow_grow_cols_then_rows_keeps_unwrapped_content() {
        // ghostty: resize() grow-cols path runs cols first, then rows (PageList.zig:980-1004).
        let mut list = PageList::new(2, 2, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1']);
        set_screen_row_cells(&mut list, 1, &['2', '3']);
        set_screen_row_wrap(&mut list, 0, true, false);
        set_screen_row_wrap(&mut list, 1, false, true);
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: Some(4),
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!((list.cols, list.rows), (4, 4));
        assert_eq!(screen_cell(&list, 3, 0), Cell::new('3'));
    }

    #[test]
    fn resize_reflow_shrink_cols_runs_rows_first() {
        // ghostty: resize() shrink-cols path runs rows first, then cols (PageList.zig:980-1004).
        let mut list = PageList::new(4, 4, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1', '2', '3']);
        let pin = list.track_pin(list.pin(Point::active(2, 0)).unwrap());
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: Some(2),
            reflow: true,
            cursor: Some(ResizeCursor {
                x: 2,
                y: 0,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!((list.cols, list.rows), (2, 2));
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(Point::active(0, 1))
        );
    }

    #[test]
    fn reflow_grow_cols_with_unwrap_fixes_viewport_pin() {
        // ghostty: "PageList resize grow cols with unwrap fixes viewport pin" (PageList.zig:13814)
        let mut list = PageList::new(2, 20, None);
        list.grow_rows(20);
        for y in 0..40 {
            set_screen_row_cells(&mut list, y, &['0', '1']);
            if y % 2 == 0 {
                set_screen_row_wrap(&mut list, y, true, false);
            } else {
                set_screen_row_wrap(&mut list, y, false, true);
            }
        }
        let pin = list.pin(Point::screen(0, 10)).unwrap();
        list.scroll(Scroll::Pin(pin));
        assert_eq!(list.viewport(), Viewport::Pin);
        list.resize(ResizeOptions {
            cols: Some(4),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.viewport(), Viewport::Active);
    }

    #[test]
    fn reflow_less_cols_copy_does_not_create_scrollback_for_empty_screen() {
        // ghostty: "PageList resize reflow less cols blank lines between no scrollback" (PageList.zig:13113)
        let mut list = PageList::new(5, 3, Some(0));
        set_screen_cell(&mut list, 0, 0, 'A');
        set_screen_cell(&mut list, 0, 2, 'C');
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.rows, 3);
        assert_eq!(screen_cell(&list, 0, 0), Cell::new('A'));
        assert_eq!(screen_cell(&list, 0, 1), Cell::default());
        assert_eq!(screen_cell(&list, 0, 2), Cell::new('C'));
    }

    #[test]
    fn reflow_preserves_total_rows_when_rows_already_fit() {
        // ghostty: "PageList resize reflow less cols blank lines" (PageList.zig:13014)
        let mut list = PageList::new(4, 3, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1', '2', '3']);
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_rows(), 3);
    }

    #[test]
    fn reflow_less_cols_copy_keeps_blank_line_between_content() {
        // ghostty: "PageList resize reflow less cols blank lines between" (PageList.zig:13057)
        let mut list = PageList::new(4, 3, Some(0));
        set_screen_row_cells(&mut list, 0, &['0', '1', '2', '3']);
        set_screen_row_cells(&mut list, 2, &['4', '5', '6', '7']);
        list.resize(ResizeOptions {
            cols: Some(2),
            rows: None,
            reflow: true,
            cursor: None,
        })
        .unwrap();
        assert_eq!(screen_cell(&list, 0, 2), Cell::default());
        assert_eq!(screen_cell(&list, 0, 3), Cell::new('4'));
    }

    #[test]
    fn resize_without_reflow_more_rows_and_less_cols() {
        // ghostty: "PageList resize (no reflow) more rows and less cols" (PageList.zig:10920)
        let mut list = PageList::new(10, 10, Some(0));
        list.resize_without_reflow(ResizeOptions {
            cols: Some(5),
            rows: Some(20),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!((list.cols, list.rows), (5, 20));
        assert_eq!(list.total_rows(), 20);
        assert_all_rows_have_cols(&list, 5);
    }

    #[test]
    fn resize_without_reflow_empty_screen() {
        // ghostty: "PageList resize (no reflow) empty screen" (PageList.zig:10960)
        let mut list = PageList::new(5, 5, Some(0));
        list.resize_without_reflow(ResizeOptions {
            cols: Some(10),
            rows: Some(10),
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!((list.cols, list.rows), (10, 10));
        assert_eq!(list.total_rows(), 10);
        assert_all_rows_have_cols(&list, 10);
    }

    #[test]
    fn resize_without_reflow_more_cols_forces_smaller_cap_and_preserves_cells() {
        // ghostty: "PageList resize (no reflow) more cols forces smaller cap" (PageList.zig:10981)
        let cap = PageList::initial_capacity(100);
        let cap2 = PageList::initial_capacity(500);
        assert!(cap2.rows < cap.rows);
        let mut list = PageList::new(cap.cols, cap.rows, None);
        for id in list.iter_node_ids().collect::<Vec<_>>() {
            let size = list.node_page_size(id).unwrap();
            if let Some(node) = list.node_mut(id) {
                for y in 0..size.rows {
                    node.page.set_cell(y, 0, Cell::new('A'));
                }
            }
        }
        let rows = list.total_rows();
        list.resize_without_reflow(ResizeOptions {
            cols: Some(cap2.cols),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        assert_eq!(list.total_rows(), rows);
        assert_all_rows_have_cols(&list, cap2.cols);
        for id in list.iter_node_ids() {
            let size = list.node_page_size(id).unwrap();
            for y in 0..size.rows {
                assert_eq!(node_cell(&list, id, y, 0), Cell::new('A'));
            }
        }
    }

    #[test]
    fn resize_without_reflow_more_rows_with_cursor_exception_keeps_cursor_active() {
        // ghostty: "PageList resize (no reflow) more rows adds blank rows if cursor at bottom" (PageList.zig:11021)
        let mut list = PageList::new(5, 3, None);
        list.grow_rows(2);
        for y in 0..list.total_rows() as u32 {
            set_screen_cell(&mut list, 0, y, char::from(b'0' + y as u8));
        }
        let pin = list.track_pin(
            list.pin(Point::active(0, u32::from(list.rows - 2)))
                .unwrap(),
        );
        let original = list
            .point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap())
            .unwrap();
        list.resize_without_reflow(ResizeOptions {
            cols: None,
            rows: Some(10),
            reflow: false,
            cursor: Some(ResizeCursor {
                x: 0,
                y: list.rows - 2,
                pin: Some(pin),
            }),
        })
        .unwrap();
        assert_eq!(list.rows, 10);
        assert_eq!(list.total_rows(), 12);
        assert_eq!(
            list.point_from_pin(Tag::Active, list.tracked_pin(pin).unwrap()),
            Some(original)
        );
        assert_eq!(list.get_cell(Point::active(0, 0)), Some(Cell::new('2')));
        assert_eq!(list.get_cell(Point::active(0, 1)), Some(Cell::new('3')));
        assert_eq!(list.get_cell(Point::active(0, 2)), Some(Cell::new('4')));
    }

    #[test]
    fn resize_without_reflow_more_cols_backfills_and_remaps_pin() {
        // ghostty: "PageList resize (no reflow) more cols remaps pins in backfill path" (PageList.zig:14011)
        let cols: CellCountInt = 5;
        let cap = PageList::initial_capacity(cols);
        let mut list = PageList::new(cols, cap.rows, None);
        while list.first_node() == list.last_node() {
            let _ = list.grow();
        }
        let first = list.first_node().unwrap();
        let second = list.last_node().unwrap();
        list.erase_history(Some(Point::history(0, 0)));
        assert!(node_rows(&list, first) < list.node_capacity(first).unwrap().rows);
        let pin = list.track_pin(Pin {
            node: second,
            x: 0,
            y: 0,
            garbage: false,
        });
        if let Some(node) = list.node_mut(second) {
            node.page.set_cell(0, 0, Cell::new('X'));
        }
        list.resize_without_reflow(ResizeOptions {
            cols: Some(cols + 1),
            rows: None,
            reflow: false,
            cursor: None,
        })
        .unwrap();
        let tracked = list.tracked_pin(pin).unwrap();
        assert!(list.node(tracked.node).is_some());
        assert!(tracked.y < list.node_page_size(tracked.node).unwrap().rows);
        assert_eq!(
            node_cell(&list, tracked.node, tracked.y, tracked.x),
            Cell::new('X')
        );
    }

    #[test]
    fn compact_standard_page_returns_none() {
        // ghostty: "PageList compact std_size page returns null" (PageList.zig:14074)
        let mut list = PageList::new(80, 24, Some(0));
        let first = list.first_node().unwrap();
        assert!(list.compact(first).is_none());
        assert_eq!(list.first_node(), Some(first));
    }

    #[test]
    fn compact_oversized_page_preserves_content_and_pin() {
        // ghostty: "PageList compact oversized page" (PageList.zig:14093)
        let mut list = PageList::new(80, 24, None);
        let first = list.first_node().unwrap();
        let mut node = first;
        while list.node(node).unwrap().page.memory_len() <= PageList::standard_size() {
            node = list
                .increase_capacity(node, Some(IncreaseCapacity::GraphemeBytes))
                .unwrap();
        }
        write_node_row_marker(&mut list, node, 10, 'C');
        let pin = list.track_pin(Pin {
            node,
            x: 0,
            y: 10,
            garbage: false,
        });
        let old_len = list.node(node).unwrap().page.memory_len();
        let compacted = list.compact(node).unwrap();
        assert!(list.node(compacted).unwrap().page.memory_len() < old_len);
        assert_eq!(list.tracked_pin(pin).unwrap().node, compacted);
        assert_eq!(node_cell(&list, compacted, 10, 0), Cell::new('C'));
    }

    #[test]
    fn compact_insufficient_savings_returns_none() {
        // ghostty: "PageList compact insufficient savings returns null" (PageList.zig:14180)
        let mut list = PageList::new(80, 24, Some(0));
        let first = list.first_node().unwrap();
        let grown = list
            .increase_capacity(first, Some(IncreaseCapacity::GraphemeBytes))
            .unwrap();
        if list.node(grown).unwrap().page.memory_len() <= PageList::standard_size() {
            assert!(list.compact(grown).is_none());
        } else if let Some(compacted) = list.compact(grown) {
            assert!(
                list.node(compacted).unwrap().page.memory_len()
                    < list
                        .node(grown)
                        .map(|node| node.page.memory_len())
                        .unwrap_or(usize::MAX)
            );
        }
    }

    #[test]
    fn split_at_middle_row_moves_rows_to_new_page() {
        // ghostty: "PageList split at middle row" (PageList.zig:14208)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        for y in 0..10 {
            write_node_row_marker(&mut list, first, y, char::from(b'0' + y as u8));
        }
        let new_id = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        assert_eq!(list.node_page_size(first).unwrap().rows, 5);
        assert_eq!(list.node_page_size(new_id).unwrap().rows, 5);
        assert_eq!(node_cell(&list, first, 4, 0), Cell::new('4'));
        assert_eq!(node_cell(&list, new_id, 0, 0), Cell::new('5'));
        assert_eq!(node_cell(&list, new_id, 4, 0), Cell::new('9'));
    }

    #[test]
    fn split_at_row_zero_is_noop() {
        // ghostty: "PageList split at row 0 is no-op" (PageList.zig:14255)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        let result = list
            .split(Pin {
                node: first,
                x: 0,
                y: 0,
                garbage: false,
            })
            .unwrap();
        assert_eq!(result, first);
        assert_eq!(list.total_pages(), 1);
    }

    #[test]
    fn split_at_last_row_makes_one_row_page() {
        // ghostty: "PageList split at last row" (PageList.zig:14289)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        write_node_row_marker(&mut list, first, 9, 'L');
        let new_id = list
            .split(Pin {
                node: first,
                x: 0,
                y: 9,
                garbage: false,
            })
            .unwrap();
        assert_eq!(list.node_page_size(first).unwrap().rows, 9);
        assert_eq!(list.node_page_size(new_id).unwrap().rows, 1);
        assert_eq!(node_cell(&list, new_id, 0, 0), Cell::new('L'));
    }

    #[test]
    fn split_single_row_page_returns_out_of_space() {
        // ghostty: "PageList split single row page returns OutOfSpace" (PageList.zig:14328)
        let mut list = PageList::new(10, 1, Some(0));
        let first = list.first_node().unwrap();
        assert_eq!(
            list.split(Pin {
                node: first,
                x: 0,
                y: 0,
                garbage: false
            }),
            Err(SplitError::OutOfSpace)
        );
    }

    #[test]
    fn split_moves_tracked_pins_in_split_region() {
        // ghostty: "PageList split moves tracked pins" (PageList.zig:14342)
        // ghostty: "PageList split tracked pin before split point unchanged" (PageList.zig:14365)
        // ghostty: "PageList split tracked pin at split point moves to new page" (PageList.zig:14389)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        let before = list.track_pin(Pin {
            node: first,
            x: 5,
            y: 2,
            garbage: false,
        });
        let at = list.track_pin(Pin {
            node: first,
            x: 4,
            y: 5,
            garbage: false,
        });
        let after = list.track_pin(Pin {
            node: first,
            x: 3,
            y: 7,
            garbage: false,
        });
        let new_id = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        assert_eq!(list.tracked_pin(before).unwrap().node, first);
        assert_eq!(
            (
                list.tracked_pin(before).unwrap().x,
                list.tracked_pin(before).unwrap().y
            ),
            (5, 2)
        );
        assert_eq!(list.tracked_pin(at).unwrap().node, new_id);
        assert_eq!(
            (
                list.tracked_pin(at).unwrap().x,
                list.tracked_pin(at).unwrap().y
            ),
            (4, 0)
        );
        assert_eq!(list.tracked_pin(after).unwrap().node, new_id);
        assert_eq!(
            (
                list.tracked_pin(after).unwrap().x,
                list.tracked_pin(after).unwrap().y
            ),
            (3, 2)
        );
    }

    #[test]
    fn split_multiple_tracked_pins_across_regions() {
        // ghostty: "PageList split multiple tracked pins across regions" (PageList.zig:14414)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        let before = list.track_pin(Pin {
            node: first,
            x: 0,
            y: 1,
            garbage: false,
        });
        let at = list.track_pin(Pin {
            node: first,
            x: 2,
            y: 5,
            garbage: false,
        });
        let after_one = list.track_pin(Pin {
            node: first,
            x: 3,
            y: 7,
            garbage: false,
        });
        let after_two = list.track_pin(Pin {
            node: first,
            x: 8,
            y: 9,
            garbage: false,
        });
        let new_id = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();

        let before_pin = list.tracked_pin(before).unwrap();
        assert_eq!(before_pin.node, first);
        assert_eq!((before_pin.x, before_pin.y), (0, 1));
        let at_pin = list.tracked_pin(at).unwrap();
        assert_eq!(at_pin.node, new_id);
        assert_eq!((at_pin.x, at_pin.y), (2, 0));
        let after_one_pin = list.tracked_pin(after_one).unwrap();
        assert_eq!(after_one_pin.node, new_id);
        assert_eq!((after_one_pin.x, after_one_pin.y), (3, 2));
        let after_two_pin = list.tracked_pin(after_two).unwrap();
        assert_eq!(after_two_pin.node, new_id);
        assert_eq!((after_two_pin.x, after_two_pin.y), (8, 4));
    }

    #[test]
    fn split_tracked_viewport_pin_in_split_region_moves() {
        // ghostty: "PageList split tracked viewport_pin in split region moves correctly" (PageList.zig:14460)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        if let Some(pin) = list.tracked_pin_mut(list.viewport_pin_id()) {
            pin.node = first;
            pin.x = 6;
            pin.y = 7;
        }
        let new_id = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        let viewport_pin = list.tracked_pin(list.viewport_pin_id()).unwrap();
        assert_eq!(viewport_pin.node, new_id);
        assert_eq!((viewport_pin.x, viewport_pin.y), (6, 2));
    }

    #[test]
    fn split_middle_page_preserves_linked_list_order() {
        // ghostty: "PageList split middle page preserves linked list order" (PageList.zig:14486)
        let mut list = PageList::new(10, 12, Some(0));
        let first = list.first_node().unwrap();
        let second = list
            .split(Pin {
                node: first,
                x: 0,
                y: 4,
                garbage: false,
            })
            .unwrap();
        let third = list
            .split(Pin {
                node: second,
                x: 0,
                y: 4,
                garbage: false,
            })
            .unwrap();
        assert_eq!(
            list.iter_node_ids().collect::<Vec<_>>(),
            vec![first, second, third]
        );
        assert_eq!(list.node(first).unwrap().prev, None);
        assert_eq!(list.node(first).unwrap().next, Some(second));
        assert_eq!(list.node(second).unwrap().prev, Some(first));
        assert_eq!(list.node(second).unwrap().next, Some(third));
        assert_eq!(list.node(third).unwrap().prev, Some(second));
        assert_eq!(list.node(third).unwrap().next, None);
        assert_eq!(list.last_node(), Some(third));
        assert_eq!(node_rows(&list, first), 4);
        assert_eq!(node_rows(&list, second), 4);
        assert_eq!(node_rows(&list, third), 4);
    }

    #[test]
    fn split_last_page_makes_new_page_last() {
        // ghostty: "PageList split last page makes new page the last" (PageList.zig:14535)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        let second = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        let third = list
            .split(Pin {
                node: second,
                x: 0,
                y: 2,
                garbage: false,
            })
            .unwrap();
        assert_eq!(list.last_node(), Some(third));
        assert_eq!(list.node(second).unwrap().next, Some(third));
        assert_eq!(list.node(third).unwrap().prev, Some(second));
        assert_eq!(node_rows(&list, second), 2);
        assert_eq!(node_rows(&list, third), 3);
    }

    #[test]
    fn split_first_page_keeps_original_first() {
        // ghostty: "PageList split first page keeps original as first" (PageList.zig:14566)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        let second = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        let inserted = list
            .split(Pin {
                node: first,
                x: 0,
                y: 2,
                garbage: false,
            })
            .unwrap();
        assert_eq!(list.first_node(), Some(first));
        assert_eq!(
            list.iter_node_ids().collect::<Vec<_>>(),
            vec![first, inserted, second]
        );
        assert_eq!(node_rows(&list, first), 2);
        assert_eq!(node_rows(&list, inserted), 3);
        assert_eq!(node_rows(&list, second), 5);
    }

    #[test]
    fn split_preserves_wrap_flags() {
        // ghostty: "PageList split preserves wrap flags" (PageList.zig:14600)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            let mut row5 = node.page.row(5);
            row5.set_wrap(true);
            node.page.set_row(5, row5);
            let mut row6 = node.page.row(6);
            row6.set_wrap_continuation(true);
            node.page.set_row(6, row6);
            let mut row7 = node.page.row(7);
            row7.set_wrap(true);
            row7.set_wrap_continuation(true);
            node.page.set_row(7, row7);
        }
        let second = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        let page = &list.node(second).unwrap().page;
        assert!(page.row(0).wrap());
        assert!(!page.row(0).wrap_continuation());
        assert!(!page.row(1).wrap());
        assert!(page.row(1).wrap_continuation());
        assert!(page.row(2).wrap());
        assert!(page.row(2).wrap_continuation());
    }

    #[test]
    fn split_preserves_styled_cells() {
        // ghostty: "PageList split preserves styled cells" (PageList.zig:14654)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            for y in 5..8 {
                node.page.set_cell(y, 0, Cell::new('S'));
                node.page.set_style(y, 0, PackedStyle(7)).unwrap();
            }
            assert_eq!(node.page.style_count(), 1);
        }
        let second = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        assert_eq!(list.node(first).unwrap().page.style_count(), 0);
        let page = &list.node(second).unwrap().page;
        assert_eq!(page.style_count(), 1);
        for y in 0..3 {
            let cell = page.cell(y, 0);
            assert_eq!(cell.codepoint(), 'S' as u32);
            assert_ne!(cell.style_id(), 0);
            assert!(page.row(y).styled());
        }
    }

    #[test]
    fn split_preserves_grapheme_clusters() {
        // ghostty: "PageList split preserves grapheme clusters" (PageList.zig:14705)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            node.page.set_cell(6, 0, Cell::new('👨'));
            node.page.append_grapheme(6, 0, 0x200D).unwrap();
            node.page.append_grapheme(6, 0, '👩' as u32).unwrap();
            assert_eq!(node.page.grapheme_count(), 1);
        }
        let second = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        assert_eq!(list.node(first).unwrap().page.grapheme_count(), 0);
        let page = &list.node(second).unwrap().page;
        assert_eq!(page.grapheme_count(), 1);
        assert!(page.cell(1, 0).has_grapheme());
        assert_eq!(page.grapheme(1, 0), Some(vec![0x200D, '👩' as u32]));
    }

    #[test]
    fn split_preserves_hyperlinks() {
        // ghostty: "PageList split preserves hyperlinks" (PageList.zig:14753)
        let mut list = PageList::new(10, 10, Some(0));
        let first = list.first_node().unwrap();
        if let Some(node) = list.node_mut(first) {
            node.page.set_cell(7, 0, Cell::new('L'));
            node.page
                .set_hyperlink_implicit(7, 0, 0, b"https://example.com")
                .unwrap();
            assert_eq!(node.page.hyperlink_count(), 1);
        }
        let second = list
            .split(Pin {
                node: first,
                x: 0,
                y: 5,
                garbage: false,
            })
            .unwrap();
        assert_eq!(list.node(first).unwrap().page.hyperlink_count(), 0);
        let page = &list.node(second).unwrap().page;
        assert_eq!(page.hyperlink_count(), 1);
        assert_eq!(page.cell(2, 0).codepoint(), 'L' as u32);
        assert!(page.cell(2, 0).hyperlink());
        assert!(page.hyperlink_id(2, 0).is_some());
    }

    #[test]
    fn arena_node_generation_rejects_stale_ids() {
        let mut list = PageList::new(80, 24, None);
        let stale = list.first_node().unwrap();
        list.remove_node(stale);
        list.destroy_node(stale);
        let fresh = list.create_page(PageList::initial_capacity(80));
        assert_eq!(stale.index, fresh.index);
        assert_ne!(stale.generation, fresh.generation);
        assert!(list.node(stale).is_none());
        assert!(list.node(fresh).is_some());
    }

    #[test]
    fn nodes_pair_mut_disjoint_borrows() {
        let mut list = PageList::new(10, 2, None);
        let cap_rows = list
            .node(list.first_node().unwrap())
            .unwrap()
            .page
            .capacity()
            .rows;
        list.grow_rows(usize::from(cap_rows));
        let first = list.first_node().unwrap();
        let last = list.last_node().unwrap();
        assert_ne!(first, last);

        let (first_node, last_node) = list.nodes_pair_mut(first, last).unwrap();
        first_node.page.set_page_dirty(true);
        last_node.page.set_page_dirty(true);

        assert!(list.node(first).unwrap().page.page_dirty());
        assert!(list.node(last).unwrap().page.page_dirty());
    }

    #[test]
    fn nodes_pair_mut_rejects_same_and_stale() {
        let mut list = PageList::new(10, 2, None);
        let first = list.first_node().unwrap();
        let stale = NodeId {
            generation: first.generation.saturating_add(1),
            ..first
        };

        assert!(list.nodes_pair_mut(first, first).is_none());
        assert!(list.nodes_pair_mut(first, stale).is_none());
    }

    #[test]
    fn pin_id_slab_reuses_slots_without_aliasing_viewport() {
        let mut list = PageList::new(80, 24, None);
        let id = list.track_pin(Pin::new(list.first_node().unwrap()));
        assert!(list.untrack_pin(id));
        let reused = list.track_pin(Pin::new(list.first_node().unwrap()));
        assert_eq!(id, reused);
        assert!(!list.untrack_pin(list.viewport_pin_id()));
    }

    #[test]
    fn reset_invalidates_old_serial_floor_and_keeps_viewport_pin_live() {
        // ghostty: "PageList reset invalidates stale untracked refs even if node memory is reused" (PageList.zig:13640)
        let mut list = PageList::new(80, 24, None);
        list.grow_rows(10);
        let old_min = list.page_serial_min();
        let before_reset_serial = list.node_serial(list.first_node().unwrap()).unwrap();
        list.reset();
        assert!(list.page_serial_min() > old_min);
        assert!(before_reset_serial < list.page_serial_min());
        let viewport_pin = list.tracked_pin(list.viewport_pin_id()).unwrap();
        assert!(!viewport_pin.garbage);
        assert_eq!(viewport_pin.node, list.first_node().unwrap());
        assert_eq!(list.viewport(), Viewport::Active);
    }
}
