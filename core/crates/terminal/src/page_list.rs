//! Terminal page chains with scrollback, viewport pins, and page growth.
//!
//! This ports the structural subset of Ghostty's `terminal/PageList.zig`.

use crate::page::{Capacity, Cell, Page, Row, SemanticPrompt, STD_CAPACITY};
use crate::point::{Coordinate, Point, Tag};
use crate::size::CellCountInt;

pub const PAGE_PREHEAT: usize = 4;
pub const STD_SIZE: usize = 65_536;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NodeId {
    pub index: u32,
    pub generation: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PinId(pub usize);

#[derive(Debug, Clone)]
struct PageNode {
    prev: Option<NodeId>,
    next: Option<NodeId>,
    page: Page,
    serial: u64,
}

#[derive(Debug, Clone)]
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

#[derive(Debug, Clone)]
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

    fn tracked_pin_mut(&mut self, id: PinId) -> Option<&mut Pin> {
        self.tracked_pins.get_mut(id.0).and_then(Option::as_mut)
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

    // Ghostty's left_wrap/right_wrap are upstream-marked "TODO: Unit tests".
    // They are intentionally deferred until a later phase has coverage.

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
        let mut non_empty = 0usize;
        let mut seen_content = false;
        let mut current = self.last;
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
                if empty {
                    if seen_content {
                        non_empty += 1;
                    }
                } else {
                    seen_content = true;
                    non_empty += 1;
                }
                if non_empty > self.rows as usize {
                    break;
                }
            }
            if non_empty > self.rows as usize {
                break;
            }
            current = node.prev;
        }
        let count = non_empty.min(self.rows as usize);
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

        let cap = Self::initial_capacity(self.cols);
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

                let standard = self
                    .node(first)
                    .map(|node| node.page.memory_len() == Self::standard_size())
                    .unwrap_or(false);
                if standard {
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
                self.destroy_node(first);
            }
        }

        let next = self.create_page(cap);
        if let Some(node) = self.node_mut(next) {
            node.page.set_size_rows(1);
        }
        self.append_node(next);
        self.total_rows += 1;
        Some(next)
    }

    pub fn increase_capacity(
        &mut self,
        id: NodeId,
        adjustment: Option<IncreaseCapacity>,
    ) -> Result<NodeId, IncreaseCapacityError> {
        let Some(old_node) = self.node(id).cloned() else {
            return Err(IncreaseCapacityError::OutOfSpace);
        };
        let mut cap = old_node.page.capacity();
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
        let old_size = old_node.page.size();
        let old_dirty = old_node.page.page_dirty();
        if let Some(new_node) = self.node_mut(new_id) {
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
        let mut memory = node.page.into_memory();
        self.page_size = self.page_size.saturating_sub(memory.len());
        if memory.len() == Self::standard_size() {
            memory.fill(0);
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

    fn node(&self, id: NodeId) -> Option<&PageNode> {
        match self.nodes.get(id.index as usize) {
            Some(NodeSlot::Occupied { generation, node }) if *generation == id.generation => {
                Some(node)
            }
            _ => None,
        }
    }

    fn node_mut(&mut self, id: NodeId) -> Option<&mut PageNode> {
        match self.nodes.get_mut(id.index as usize) {
            Some(NodeSlot::Occupied { generation, node }) if *generation == id.generation => {
                Some(node)
            }
            _ => None,
        }
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
        let Some(node) = self.node(id).cloned() else {
            return;
        };
        if let Some(prev) = node.prev {
            if let Some(prev_node) = self.node_mut(prev) {
                prev_node.next = node.next;
            }
        } else {
            self.first = node.next;
        }
        if let Some(next) = node.next {
            if let Some(next_node) = self.node_mut(next) {
                next_node.prev = node.prev;
            }
        } else {
            self.last = node.prev;
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
        // ghostty: "PageList: jump one prompt" (PageList.zig:6899)
        // ghostty: "PageList: jump prompt skips continuation" (PageList.zig:6968)
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
        // ghostty: "PageList increaseCapacity styles" (PageList.zig:7444)
        // ghostty: "PageList increaseCapacity grapheme bytes" (PageList.zig:7495)
        // ghostty: "PageList increaseCapacity hyperlink bytes" (PageList.zig:7539)
        // ghostty: "PageList increaseCapacity string bytes" (PageList.zig:7583)
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
    fn increase_capacity_retargets_pins_and_preserves_dirty() {
        // ghostty: "PageList increaseCapacity tracked pin" (PageList.zig:7627)
        // ghostty: "PageList increaseCapacity preserves dirty bits" (PageList.zig:7739)
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
        // ghostty: "PageList iterator active no history" (PageList.zig:7770)
        // ghostty: "PageList iterator active with history" (PageList.zig:7793)
        // ghostty: "PageList iterator screen no history" (PageList.zig:7829)
        // ghostty: "PageList iterator reverse active no history" (PageList.zig:7859)
        // ghostty: "PageList iterator reverse active with history" (PageList.zig:7882)
        // ghostty: "PageList iterator reverse screen" (PageList.zig:7922)
        // ghostty: "PageList cell iterator 2x2" (PageList.zig:7952)
        // ghostty: "PageList cell iterator 2x2 reverse" (PageList.zig:8002)
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
        assert_eq!(list.pin_right(pin, 2).x, 7);
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

    // Deferred to T5b: eraseRows/eraseRow/eraseRowBounded viewport-cache tests.
    // ghostty: "PageList eraseRows viewport pin cache row before" (PageList.zig:7196)
    // ghostty: "PageList eraseRows viewport pin cache row after" (PageList.zig:7236)
    // ghostty: "PageList eraseRows viewport pin cache row in range" (PageList.zig:7275)
    // ghostty: "PageList eraseRow viewport pin cache row before" (PageList.zig:7315)
    // ghostty: "PageList eraseRow viewport pin cache row after" (PageList.zig:7356)
    // ghostty: "PageList eraseRowBounded viewport pin cache in range" (PageList.zig:7399)

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
        // ghostty: "PageList reset invalidates refs" (PageList.zig:13640)
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
