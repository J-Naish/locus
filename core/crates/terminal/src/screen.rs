//! Terminal screen state.
//!
//! This ports the first structural slice of Ghostty's `terminal/Screen.zig`.
//! Kitty-specific behavior is intentionally deferred to later terminal phases.

use unicode_width::UnicodeWidthChar;

use crate::color::Name;
use crate::hyperlink::{Hyperlink, HyperlinkId, HyperlinkIdKind};
use crate::osc::parsers::semantic_prompt::{PromptClick, PromptClickEvents, PromptKind};
use crate::page::{Cell, CellWide, Page, SemanticContent, SemanticPrompt};
use crate::page_list::{
    CloneOptions, Direction, IncreaseCapacity, IncreaseCapacityError, PageList, Pin, PinId,
    ResizeCursor, ResizeError, ResizeOptions, Scroll,
};
use crate::point::{Coordinate, Point, Tag};
use crate::selection::{Adjustment, Bounds, Selection};
use crate::selection_codepoints::DEFAULT_LINE_WHITESPACE;
use crate::sgr::Attribute;
use crate::size::CellCountInt;
use crate::style::{PackedStyle, Style, StyleColor, StyleId, DEFAULT_STYLE_ID};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Dirty {
    pub selection: bool,
    pub hyperlink_hover: bool,
}

/// Faithful port of ghostty's `Screen.SemanticPrompt.SemanticClick`
/// (Screen.zig:114): a tagged union set from `cl`/`click_events` options on
/// the most recent OSC 133 commands.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum SemanticClick {
    #[default]
    None,
    ClickEvents(PromptClickEvents),
    Cl(PromptClick),
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PromptClickMove {
    pub left: usize,
    pub right: usize,
}

impl PromptClickMove {
    pub const ZERO: Self = Self { left: 0, right: 0 };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectionStringOptions {
    pub selection: Selection,
    pub trim: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SelectLineOptions<'a> {
    pub pin: Pin,
    pub whitespace: Option<&'a [char]>,
    pub semantic_prompt_boundary: bool,
}

impl SelectLineOptions<'_> {
    pub const fn new(pin: Pin) -> Self {
        Self {
            pin,
            whitespace: Some(&DEFAULT_LINE_WHITESPACE),
            semantic_prompt_boundary: true,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ScreenSemanticPrompt {
    pub seen: bool,
    pub click: SemanticClick,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CursorStyle {
    #[default]
    Block,
    Bar,
    Underline,
}

/// The set of charsets (ASCII, DEC special graphics, ...) reuses the shared
/// `charsets` module so translation tables are defined once.
pub use crate::charsets::Charset;
/// The four designatable charset slots (G0-G3).
pub use crate::charsets::Slots as CharsetSlot;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CharsetState {
    pub g0: Charset,
    pub g1: Charset,
    pub g2: Charset,
    pub g3: Charset,
    pub gl: CharsetSlot,
    pub gr: CharsetSlot,
    pub single_shift: Option<CharsetSlot>,
}

impl CharsetState {
    /// Charset currently designated in the given slot. Mirrors Ghostty's
    /// `charset.charsets.get(slot)`.
    pub fn get(&self, slot: CharsetSlot) -> Charset {
        match slot {
            CharsetSlot::G0 => self.g0,
            CharsetSlot::G1 => self.g1,
            CharsetSlot::G2 => self.g2,
            CharsetSlot::G3 => self.g3,
        }
    }

    /// Designate `set` into the given slot. Mirrors Ghostty's
    /// `charset.charsets.set(slot, set)`.
    pub fn set(&mut self, slot: CharsetSlot, set: Charset) {
        match slot {
            CharsetSlot::G0 => self.g0 = set,
            CharsetSlot::G1 => self.g1 = set,
            CharsetSlot::G2 => self.g2 = set,
            CharsetSlot::G3 => self.g3 = set,
        }
    }
}

impl Default for CharsetState {
    fn default() -> Self {
        Self {
            g0: Charset::Ascii,
            g1: Charset::Ascii,
            g2: Charset::Ascii,
            g3: Charset::Ascii,
            gl: CharsetSlot::G0,
            gr: CharsetSlot::G1,
            single_shift: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Cursor {
    pub x: CellCountInt,
    pub y: CellCountInt,
    pub cursor_style: CursorStyle,
    pub pending_wrap: bool,
    pub protected: bool,
    pub style: Style,
    pub style_id: StyleId,
    pub hyperlink_id: HyperlinkId,
    pub hyperlink_implicit_id: u32,
    pub hyperlink: Option<Hyperlink>,
    pub semantic_content: SemanticContent,
    pub semantic_content_clear_eol: bool,
    pub pin: PinId,
}

impl Cursor {
    fn new(pin: PinId) -> Self {
        Self {
            x: 0,
            y: 0,
            cursor_style: CursorStyle::Block,
            pending_wrap: false,
            protected: false,
            style: Style::default(),
            style_id: DEFAULT_STYLE_ID,
            hyperlink_id: 0,
            hyperlink_implicit_id: 0,
            hyperlink: None,
            semantic_content: SemanticContent::Output,
            semantic_content_clear_eol: false,
            pin,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SavedCursor {
    pub x: CellCountInt,
    pub y: CellCountInt,
    pub style: Style,
    pub protected: bool,
    pub pending_wrap: bool,
    pub origin: bool,
    pub charset: CharsetState,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PromptRedraw {
    #[default]
    False,
    Last,
    True,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Resize {
    pub cols: CellCountInt,
    pub rows: CellCountInt,
    pub reflow: bool,
    pub prompt_redraw: PromptRedraw,
}

impl Resize {
    pub const fn new(cols: CellCountInt, rows: CellCountInt) -> Self {
        Self {
            cols,
            rows,
            reflow: true,
            prompt_redraw: PromptRedraw::False,
        }
    }

    pub const fn without_reflow(cols: CellCountInt, rows: CellCountInt) -> Self {
        Self {
            cols,
            rows,
            reflow: false,
            prompt_redraw: PromptRedraw::False,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Options {
    pub cols: CellCountInt,
    pub rows: CellCountInt,
    pub max_scrollback: usize,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            cols: 80,
            rows: 24,
            max_scrollback: 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Screen {
    pub pages: PageList,
    pub no_scrollback: bool,
    pub cursor: Cursor,
    pub saved_cursor: Option<SavedCursor>,
    pub charset: CharsetState,
    pub semantic_prompt: ScreenSemanticPrompt,
    pub selection: Option<Selection>,
    pub dirty: Dirty,
}

impl Screen {
    pub fn new(options: Options) -> Self {
        let no_scrollback = options.max_scrollback == 0;
        let mut pages = PageList::new(options.cols, options.rows, Some(options.max_scrollback));
        let cursor_pin = pages
            .pin(Point::active(0, 0))
            .unwrap_or_else(|| pages.get_top_left(Tag::Active));
        let cursor_pin_id = pages.track_pin(cursor_pin);
        let screen = Self {
            pages,
            no_scrollback,
            cursor: Cursor::new(cursor_pin_id),
            saved_cursor: None,
            charset: CharsetState::default(),
            semantic_prompt: ScreenSemanticPrompt::default(),
            selection: None,
            dirty: Dirty::default(),
        };
        screen.assert_integrity();
        screen
    }

    /// Reset the screen to its initial state. Faithful port of ghostty's
    /// `Screen.reset` (Screen.zig): `pages.reset()` preserves tracked pins (so
    /// the cursor pin stays valid at the top-left), then cursor and per-screen
    /// state are reset in place.
    pub fn reset(&mut self) {
        // Release any live cursor refs before the pages are torn down.
        self.release_cursor_refs();

        // Reset our pages. This preserves tracked pins, moving them to the
        // top-left, so the cursor pin remains valid.
        self.pages.reset();

        // The cursor keeps its (preserved) tracked pin, now at (0, 0).
        let cursor_pin = self.cursor.pin;
        self.cursor = Cursor::new(cursor_pin);

        // Reset our basic per-screen state. (Protected mode lives on the
        // `Terminal` in this port, not the `Screen`, so it is reset there.)
        self.saved_cursor = None;
        self.charset = CharsetState::default();
        self.semantic_prompt = ScreenSemanticPrompt::default();
        self.clear_selection();
        self.dirty = Dirty::default();

        self.assert_integrity();
    }

    pub fn cols(&self) -> CellCountInt {
        self.pages.cols
    }

    pub fn rows(&self) -> CellCountInt {
        self.pages.rows
    }

    pub fn assert_integrity(&self) {
        // ghostty: Screen.zig:344 gates the whole body behind
        // build_options.slow_runtime_safety; mirror that with debug_assertions
        // so release builds skip the pin/point recomputation entirely.
        #[cfg(debug_assertions)]
        {
            debug_assert!(self.cursor.x < self.cols());
            debug_assert!(self.cursor.y < self.rows());
            let Some(pin) = self.cursor_pin() else {
                return;
            };
            let Some(point) = self.pages.point_from_pin(Tag::Active, pin) else {
                return;
            };
            debug_assert_eq!(
                point.coord(),
                Coordinate {
                    x: self.cursor.x,
                    y: u32::from(self.cursor.y),
                }
            );
        }
    }

    pub fn cursor_pin(&self) -> Option<Pin> {
        self.pages.tracked_pin(self.cursor.pin)
    }

    pub fn cursor_cell(&self) -> Option<Cell> {
        let pin = self.cursor_pin()?;
        self.pages
            .node(pin.node)
            .map(|node| node.page.cell(pin.y, pin.x))
    }

    /// The cell `n` columns to the left of the cursor on the same row. Mirrors
    /// Ghostty's `Screen.cursorCellLeft`. Saturates at column 0.
    pub(crate) fn cursor_cell_left(&self, n: CellCountInt) -> Option<Cell> {
        let pin = self.cursor_pin()?;
        let x = pin.x.saturating_sub(n);
        self.pages
            .node(pin.node)
            .map(|node| node.page.cell(pin.y, x))
    }

    /// Set the cursor cell's `wide` class and clear its codepoint (to 0),
    /// preserving grapheme data (and its content tag). Used by print's grapheme
    /// wide-wrap path (mirrors `prev.cell.wide = ...; prev.cell.content
    /// .codepoint = 0;` in Ghostty).
    pub(crate) fn set_cursor_cell_wide_and_clear_codepoint(&mut self, wide: CellWide) {
        let Some(pin) = self.cursor_pin() else {
            return;
        };
        if let Some(node) = self.pages.node_mut(pin.node) {
            let mut cell = node.page.cell(pin.y, pin.x);
            cell.set_wide(wide);
            cell.set_codepoint(0);
            node.page.set_cell(pin.y, pin.x, cell);
        }
    }

    /// Append `codepoint` to the grapheme data of the cell `n` columns left of
    /// the cursor.
    pub(crate) fn append_grapheme_cursor_left(&mut self, n: CellCountInt, codepoint: u32) {
        let Some(mut pin) = self.cursor_pin() else {
            return;
        };
        pin.x = pin.x.saturating_sub(n);
        self.append_grapheme_to_pin(pin, codepoint);
    }

    pub fn cursor_copy(&self) -> Cursor {
        self.cursor.clone()
    }

    pub fn cursor_copy_from(&mut self, source: &Cursor, copy_hyperlink: bool) {
        self.release_cursor_refs();
        self.cursor.x = source.x.min(self.cols().saturating_sub(1));
        self.cursor.y = source.y.min(self.rows().saturating_sub(1));
        self.cursor.cursor_style = source.cursor_style;
        self.cursor.pending_wrap = source.pending_wrap;
        self.cursor.protected = source.protected;
        self.cursor.style = source.style;
        self.cursor.style_id = DEFAULT_STYLE_ID;
        self.cursor.semantic_content = source.semantic_content;
        self.cursor.semantic_content_clear_eol = source.semantic_content_clear_eol;
        self.cursor.hyperlink_implicit_id = source.hyperlink_implicit_id;
        self.cursor.hyperlink = copy_hyperlink.then(|| source.hyperlink.clone()).flatten();
        self.cursor.hyperlink_id = 0;

        if let Some(pin) = self
            .pages
            .pin(Point::active(self.cursor.x, u32::from(self.cursor.y)))
        {
            let _ = self.pages.set_tracked_pin(self.cursor.pin, pin);
        }
        self.manual_style_update();
        self.cursor_set_hyperlink();
        self.assert_integrity();
    }

    pub fn cursor_reset_wrap(&mut self) {
        // ghostty: `Screen.cursorResetWrap` (Screen.zig:1231)
        // Reset the cursor's pending wrap state.
        self.cursor.pending_wrap = false;

        let Some(pin) = self.cursor_pin() else {
            return;
        };

        // If this row does not soft-wrap, there is nothing else to do.
        let row_wraps = self
            .pages
            .node(pin.node)
            .map(|node| node.page.row(pin.y).wrap())
            .unwrap_or(false);
        if !row_wraps {
            return;
        }

        // This row no longer wraps, so the next row no longer continues a wrap.
        if let Some(node) = self.pages.node_mut(pin.node) {
            let mut row = node.page.row(pin.y);
            row.set_wrap(false);
            node.page.set_row(pin.y, row);
        }
        if let Some(next) = self.pages.pin_down(pin, 1) {
            if let Some(node) = self.pages.node_mut(next.node) {
                let mut row = node.page.row(next.y);
                row.set_wrap_continuation(false);
                node.page.set_row(next.y, row);
            }
        }

        // If the last cell in the row is a spacer head we need to clear it.
        let cols = self
            .pages
            .node(pin.node)
            .map(|node| node.page.size().cols)
            .unwrap_or(0);
        if cols > 0 {
            let last_x = cols - 1;
            let is_spacer_head = self
                .pages
                .node(pin.node)
                .map(|node| node.page.cell(pin.y, last_x).wide() == CellWide::SpacerHead)
                .unwrap_or(false);
            if is_spacer_head {
                let point = self
                    .pages
                    .point_from_pin(Tag::Active, Pin { x: last_x, ..pin });
                if let Some(point) = point {
                    self.clear_cells(point, point, false);
                }
            }
        }

        self.assert_integrity();
    }

    /// Move the cursor to column `x` on the current row, updating the tracked
    /// pin in place. Mirrors the common body of Ghostty's `cursorLeft`,
    /// `cursorRight`, and `cursorHorizontalAbsolute`: a horizontal move stays on
    /// the same row, so it does NOT go through `cursorChangePin` and therefore
    /// does not mark the row dirty, re-apply the cursor style, or apply the
    /// active hyperlink (those happen only on row changes and in `printCell`).
    fn cursor_set_column_in_row(&mut self, x: CellCountInt) {
        self.cursor.x = x;
        if let Some(pin) = self.pages.tracked_pin_mut(self.cursor.pin) {
            pin.x = x;
        }
        self.assert_integrity();
    }

    pub fn cursor_horizontal_absolute(&mut self, x: CellCountInt) {
        let target_x = x.min(self.cols().saturating_sub(1));
        self.cursor.pending_wrap = false;
        self.cursor_set_column_in_row(target_x);
    }

    pub fn cursor_absolute(&mut self, x: CellCountInt, y: CellCountInt) {
        let target_x = x.min(self.cols().saturating_sub(1));
        let target_y = y.min(self.rows().saturating_sub(1));
        self.cursor.pending_wrap = false;
        self.cursor_change_active_point(target_x, target_y);
    }

    pub fn cursor_up(&mut self, rows: usize) {
        let y = self.cursor.y.saturating_sub(rows as CellCountInt);
        self.cursor_change_active_point(self.cursor.x, y);
    }

    pub fn cursor_down(&mut self, rows: usize) {
        let y = self
            .cursor
            .y
            .saturating_add(rows as CellCountInt)
            .min(self.rows().saturating_sub(1));
        self.cursor_change_active_point(self.cursor.x, y);
    }

    pub fn cursor_left(&mut self, cols: usize) {
        // Mirrors Ghostty's `cursorLeft`: an in-row move that does not dirty the
        // row or touch styles/hyperlinks.
        let x = self.cursor.x.saturating_sub(cols as CellCountInt);
        self.cursor_set_column_in_row(x);
    }

    pub fn cursor_right(&mut self, cols: usize) {
        // Mirrors Ghostty's `cursorRight`: an in-row move that does not dirty the
        // row or touch styles/hyperlinks.
        let x = self
            .cursor
            .x
            .saturating_add(cols as CellCountInt)
            .min(self.cols().saturating_sub(1));
        self.cursor_set_column_in_row(x);
    }

    pub fn cursor_down_or_scroll(&mut self) {
        if self.cursor.y.saturating_add(1) < self.rows() {
            self.cursor_down(1);
        } else {
            self.cursor_down_scroll();
        }
    }

    pub fn cursor_down_scroll(&mut self) {
        let x = self.cursor.x;
        self.cursor.pending_wrap = false;
        if self.no_scrollback {
            if self.rows() <= 1 {
                self.clear_row_at_cursor();
            } else {
                let _ = self.pages.erase_row(Point::active(0, 0));
            }
            self.cursor_absolute(x, self.rows().saturating_sub(1));
            self.fill_cursor_row_background();
            self.assert_integrity();
            return;
        }

        let _ = self.pages.grow();
        // Ghostty snapshots and restores the cursor pin to avoid a cursorChangePin
        // call here. This port stores only a tracked PinId, so resolving the same
        // active coordinate after grow() preserves the cursor refs explicitly.
        self.cursor_absolute(x, self.rows().saturating_sub(1));
        self.fill_cursor_row_background();
        self.assert_integrity();
    }

    pub fn cursor_scroll_above(&mut self) {
        self.cursor_mark_dirty();
        if self.cursor.y == self.rows().saturating_sub(1) {
            self.cursor_down_scroll();
            return;
        }

        let x = self.cursor.x;
        let y = self.cursor.y;
        let _ = self.pages.grow();
        let Some(pin) = self
            .cursor_pin()
            .and_then(|pin| self.pages.pin_down(pin, 1))
        else {
            self.assert_integrity();
            return;
        };
        self.cursor_change_pin(pin);
        self.pages.rotate_rows_right_from_pin_to_end(pin);
        self.cursor.x = x;
        self.cursor.y = y;
        if let Some(current_pin) = self.cursor_pin() {
            self.pages.mark_dirty(current_pin);
        }
        self.fill_cursor_row_background();
        self.assert_integrity();
    }

    pub fn cursor_change_pin(&mut self, pin: Pin) {
        self.release_cursor_refs();
        if self.pages.set_tracked_pin(self.cursor.pin, pin) {
            if let Some(point) = self.pages.point_from_pin(Tag::Active, pin) {
                let coord = point.coord();
                self.cursor.x = coord.x.min(self.cols().saturating_sub(1));
                self.cursor.y = (coord.y as CellCountInt).min(self.rows().saturating_sub(1));
            }
        }
        self.manual_style_update();
        self.cursor_set_hyperlink();
        self.assert_integrity();
    }

    pub fn cursor_reload(&mut self) {
        let Some(pin) = self.cursor_pin() else {
            return;
        };
        if let Some(point) = self.pages.point_from_pin(Tag::Active, pin) {
            let coord = point.coord();
            self.cursor.x = coord.x.min(self.cols().saturating_sub(1));
            self.cursor.y = (coord.y as CellCountInt).min(self.rows().saturating_sub(1));
            self.assert_integrity();
            return;
        }

        if let Some(pin) = self.pages.pin(Point::active(0, 0)) {
            self.cursor_change_pin(pin);
        }
        self.assert_integrity();
    }

    pub fn scroll(&mut self, scroll: Scroll) {
        self.pages.scroll(scroll);
    }

    pub fn scroll_clear(&mut self) {
        self.pages.scroll_clear();
        self.cursor_reload();
    }

    pub fn resize(&mut self, opts: Resize) -> Result<(), ResizeError> {
        // ghostty: Screen.resize releases cursor page-local refs while PageList
        // rebuilds pages, then reloads coordinates from the tracked cursor pin
        // (Screen.zig:1655).
        let cursor_style = self.cursor.style;
        self.cursor.style = Style::default();
        self.manual_style_update();

        let hyperlink = self.detach_cursor_hyperlink_for_resize();
        let saved_cursor_pin = self.track_saved_cursor_pin_for_resize();
        self.clear_prompt_for_resize(opts.prompt_redraw);

        let result = self.pages.resize(ResizeOptions {
            cols: Some(opts.cols),
            rows: Some(opts.rows),
            reflow: opts.reflow,
            cursor: Some(ResizeCursor {
                x: self.cursor.x,
                y: self.cursor.y,
                pin: Some(self.cursor.pin),
            }),
        });

        if result.is_ok() {
            if self.no_scrollback {
                self.pages.erase_history(None);
            }
            self.cursor_reload();
            self.fix_saved_cursor_after_resize(saved_cursor_pin, opts.cols);
            if let Some(link) = hyperlink {
                self.reattach_cursor_hyperlink(link);
            }
        }

        if let Some(pin_id) = saved_cursor_pin {
            let _ = self.pages.untrack_pin(pin_id);
        }

        self.cursor.style = cursor_style;
        self.manual_style_update();
        self.assert_integrity();
        result
    }

    pub fn clear_rows(&mut self, top: Point, bottom: Option<Point>, protected: bool) {
        let Some(mut current) = self.pages.pin(top) else {
            return;
        };
        let bottom_pin = bottom.and_then(|point| self.pages.pin(point));
        loop {
            self.clear_row(current, protected);
            if Some(current.node) == bottom_pin.map(|pin| pin.node)
                && Some(current.y) == bottom_pin.map(|pin| pin.y)
            {
                break;
            }
            let Some(next) = self.pages.pin_down(current, 1) else {
                break;
            };
            current = Pin { x: 0, ..next };
            if let Some(bottom_pin) = bottom_pin {
                if !self.pages.pin_is_between(
                    current,
                    self.pages.pin(top).unwrap_or(current),
                    bottom_pin,
                ) {
                    break;
                }
            }
        }
    }

    /// The cell used to fill newly cleared space. Mirrors Ghostty's
    /// `Screen.blankCell`: an empty cell, except that when the cursor carries a
    /// non-default background color the blank cell adopts that background.
    pub fn blank_cell(&self) -> Cell {
        if self.cursor.style_id == DEFAULT_STYLE_ID {
            return Cell::default();
        }
        match self.cursor.style.bg_color {
            StyleColor::None => Cell::default(),
            StyleColor::Palette(index) => Cell::bg_palette(index),
            StyleColor::Rgb(rgb) => Cell::bg_rgb(rgb),
        }
    }

    pub fn clear_cells(&mut self, start: Point, end: Point, protected: bool) {
        let Some(start_pin) = self.pages.pin(start) else {
            return;
        };
        let Some(end_pin) = self.pages.pin(end) else {
            return;
        };
        if start_pin.node != end_pin.node || start_pin.y != end_pin.y {
            return;
        }
        let start_x = start_pin.x.min(end_pin.x);
        let end_x = start_pin.x.max(end_pin.x).saturating_add(1);
        let fill = self.blank_cell();
        if let Some(node) = self.pages.node_mut(start_pin.node) {
            if protected {
                for x in start_x..end_x {
                    if !node.page.cell(start_pin.y, x).protected() {
                        node.page
                            .fill_cells(start_pin.y, x, x.saturating_add(1), fill);
                    }
                }
            } else {
                node.page.fill_cells(start_pin.y, start_x, end_x, fill);
            }
        }
    }

    pub fn clear_unprotected_cells(&mut self, start: Point, end: Point) {
        self.clear_cells(start, end, true);
    }

    pub fn erase_history(&mut self, bottom_left: Option<Point>) {
        self.pages.erase_history(bottom_left);
    }

    pub fn erase_active(&mut self, y: CellCountInt) {
        self.pages.erase_active(y);
    }

    pub fn split_cell_boundary(&mut self, point: Point) {
        // ghostty: `Screen.splitCellBoundary` (Screen.zig:1524). The boundary
        // column `x` may be up to AND INCLUDING `cols`, which signifies the
        // boundary to the right of the final cell. In all callers the point's
        // row is the cursor's row, so we resolve the row from the point's
        // coordinate rather than an out-of-range pin (x == cols has no pin).
        let x = point.coord().x;
        // Resolve the pin for this row using column 0 (x may be == cols).
        let row_point = match point.tag() {
            Tag::Active => Point::active(0, point.coord().y),
            Tag::Viewport => Point::viewport(0, point.coord().y),
            Tag::Screen => Point::screen(0, point.coord().y),
            Tag::History => Point::history(0, point.coord().y),
        };
        let Some(pin) = self.pages.pin(row_point) else {
            return;
        };
        let cols = self
            .pages
            .node(pin.node)
            .map(|node| node.page.size().cols)
            .unwrap_or(0);
        if cols == 0 || x > cols {
            return;
        }

        // [ A B C D E F|]  Boundary between final cell and row end.
        if x == cols {
            let row_wraps = self
                .pages
                .node(pin.node)
                .map(|node| node.page.row(pin.y).wrap())
                .unwrap_or(false);
            if !row_wraps {
                return;
            }
            // Spacer head at end of wrapped row.
            let last_x = cols - 1;
            let is_spacer_head = self
                .pages
                .node(pin.node)
                .map(|node| node.page.cell(pin.y, last_x).wide() == CellWide::SpacerHead)
                .unwrap_or(false);
            if is_spacer_head {
                if let Some(node) = self.pages.node_mut(pin.node) {
                    node.page.clear_cells(pin.y, last_x, cols);
                }
            }
            return;
        }

        // [|A B C D E F ] or [ A|B C D E F ]  Boundary at the row start or
        // between the first two cells. A wrapped wide first cell may leave a
        // spacer head on the previous row that needs clearing.
        if x == 0 || x == 1 {
            let wrap_continuation = self
                .pages
                .node(pin.node)
                .map(|node| node.page.row(pin.y).wrap_continuation())
                .unwrap_or(false);
            let first_is_wide = self
                .pages
                .node(pin.node)
                .map(|node| node.page.cell(pin.y, 0).wide() == CellWide::Wide)
                .unwrap_or(false);
            if wrap_continuation && first_is_wide {
                if let Some(prev) = self.pages.pin_up(pin, 1) {
                    let prev_cols = self
                        .pages
                        .node(prev.node)
                        .map(|node| node.page.size().cols)
                        .unwrap_or(0);
                    if prev_cols > 0 {
                        let prev_last = prev_cols - 1;
                        let prev_is_spacer_head = self
                            .pages
                            .node(prev.node)
                            .map(|node| {
                                node.page.cell(prev.y, prev_last).wide() == CellWide::SpacerHead
                            })
                            .unwrap_or(false);
                        if prev_is_spacer_head {
                            if let Some(node) = self.pages.node_mut(prev.node) {
                                node.page.clear_cells(prev.y, prev_last, prev_cols);
                            }
                        }
                    }
                }
            }
        }

        // If x is 0 then we're done.
        if x == 0 {
            return;
        }

        // [ ... X|Y ... ]  Boundary between two cells in the middle of the
        // row. A wide char immediately to the left would be split, so clear it.
        let left = x - 1;
        let left_is_wide = self
            .pages
            .node(pin.node)
            .map(|node| node.page.cell(pin.y, left).wide() == CellWide::Wide)
            .unwrap_or(false);
        if left_is_wide {
            if let Some(node) = self.pages.node_mut(pin.node) {
                node.page.clear_cells(pin.y, left, x + 1);
            }
        }
    }

    pub fn set_attribute(&mut self, attribute: Attribute<'_>) {
        match attribute {
            Attribute::Unset => self.cursor.style = Style::default(),
            Attribute::Bold => self.cursor.style.flags.bold = true,
            Attribute::ResetBold => {
                self.cursor.style.flags.bold = false;
                self.cursor.style.flags.faint = false;
            }
            Attribute::Italic => self.cursor.style.flags.italic = true,
            Attribute::ResetItalic => self.cursor.style.flags.italic = false,
            Attribute::Faint => self.cursor.style.flags.faint = true,
            Attribute::Underline(value) => self.cursor.style.flags.underline = value,
            Attribute::UnderlineColor(value) => {
                self.cursor.style.underline_color = StyleColor::Rgb(value);
            }
            Attribute::UnderlineColor256(value) => {
                self.cursor.style.underline_color = StyleColor::Palette(value);
            }
            Attribute::ResetUnderlineColor => self.cursor.style.underline_color = StyleColor::None,
            Attribute::Overline => self.cursor.style.flags.overline = true,
            Attribute::ResetOverline => self.cursor.style.flags.overline = false,
            Attribute::Blink => self.cursor.style.flags.blink = true,
            Attribute::ResetBlink => self.cursor.style.flags.blink = false,
            Attribute::Inverse => self.cursor.style.flags.inverse = true,
            Attribute::ResetInverse => self.cursor.style.flags.inverse = false,
            Attribute::Invisible => self.cursor.style.flags.invisible = true,
            Attribute::ResetInvisible => self.cursor.style.flags.invisible = false,
            Attribute::Strikethrough => self.cursor.style.flags.strikethrough = true,
            Attribute::ResetStrikethrough => self.cursor.style.flags.strikethrough = false,
            Attribute::DirectColorFg(value) => self.cursor.style.fg_color = StyleColor::Rgb(value),
            Attribute::DirectColorBg(value) => self.cursor.style.bg_color = StyleColor::Rgb(value),
            Attribute::Bg8(name) | Attribute::BrightBg8(name) => {
                self.cursor.style.bg_color = palette_color(name);
            }
            Attribute::Fg8(name) | Attribute::BrightFg8(name) => {
                self.cursor.style.fg_color = palette_color(name);
            }
            Attribute::Bg256(value) => self.cursor.style.bg_color = StyleColor::Palette(value),
            Attribute::Fg256(value) => self.cursor.style.fg_color = StyleColor::Palette(value),
            Attribute::ResetFg => self.cursor.style.fg_color = StyleColor::None,
            Attribute::ResetBg => self.cursor.style.bg_color = StyleColor::None,
            Attribute::Unknown(_) => {}
        }
        self.manual_style_update();
    }

    pub fn manual_style_update(&mut self) {
        let _ = self.try_manual_style_update();
    }

    /// Reload `cursor.style_id` from `cursor.style`, acquiring a new style ref
    /// and growing/splitting the page as needed. Returns `false` when the style
    /// could not be stored (capacity exhausted and the page could not be split)
    /// and the cursor was forced back to the default style id — callers that
    /// need to keep terminal state coherent (e.g. `restoreCursor`) should then
    /// reset `cursor.style` to default themselves.
    pub fn try_manual_style_update(&mut self) -> bool {
        let old = self.cursor.style_id;
        if old != DEFAULT_STYLE_ID {
            if let Some(pin) = self.cursor_pin() {
                if let Some(node) = self.pages.node_mut(pin.node) {
                    node.page.release_style(old);
                }
            }
        }

        if self.cursor.style.is_default() {
            self.cursor.style_id = DEFAULT_STYLE_ID;
            return true;
        }

        let style = PackedStyle::from(self.cursor.style);
        loop {
            let Some(pin) = self.cursor_pin() else {
                self.cursor.style_id = DEFAULT_STYLE_ID;
                return false;
            };
            let Some(node) = self.pages.node_mut(pin.node) else {
                self.cursor.style_id = DEFAULT_STYLE_ID;
                return false;
            };
            match node.page.add_style(style) {
                Ok(id) => {
                    self.cursor.style_id = id;
                    return true;
                }
                Err(_) => {
                    if self
                        .pages
                        .increase_capacity(pin.node, Some(IncreaseCapacity::Styles))
                        .is_err()
                        && self
                            .split_for_capacity(pin, IncreaseCapacity::Styles)
                            .is_err()
                    {
                        self.cursor.style_id = DEFAULT_STYLE_ID;
                        return false;
                    }
                }
            }
        }
    }

    pub fn split_for_capacity(
        &mut self,
        pin: Pin,
        dimension: IncreaseCapacity,
    ) -> Result<(), IncreaseCapacityError> {
        let new_node = self
            .pages
            .split(pin)
            .map_err(|_| IncreaseCapacityError::OutOfSpace)?;
        if self
            .pages
            .increase_capacity(new_node, Some(dimension))
            .is_err()
            && new_node == pin.node
        {
            return Err(IncreaseCapacityError::OutOfSpace);
        }
        Ok(())
    }

    pub fn increase_capacity(
        &mut self,
        node: crate::page_list::NodeId,
        dimension: IncreaseCapacity,
    ) -> Result<crate::page_list::NodeId, IncreaseCapacityError> {
        let cursor_on_node = self
            .cursor_pin()
            .map(|pin| pin.node == node)
            .unwrap_or(false);
        if cursor_on_node {
            self.release_cursor_refs();
        }
        let new_node = self.pages.increase_capacity(node, Some(dimension))?;
        if cursor_on_node {
            self.manual_style_update();
            self.cursor_set_hyperlink();
            self.cursor_reload();
        }
        self.assert_integrity();
        Ok(new_node)
    }

    pub fn append_grapheme(&mut self, codepoint: u32) {
        let Some(pin) = self.cursor_pin() else {
            return;
        };
        self.append_grapheme_to_pin(pin, codepoint);
    }

    pub(crate) fn append_grapheme_to_previous_cell(&mut self, codepoint: u32) {
        let target = if self.cursor.x > 0 {
            self.pages
                .pin(Point::active(self.cursor.x - 1, u32::from(self.cursor.y)))
        } else if self.cursor.y > 0 {
            self.pages.pin(Point::active(
                self.cols().saturating_sub(1),
                u32::from(self.cursor.y - 1),
            ))
        } else {
            self.cursor_pin()
        };
        let Some(mut pin) = target else {
            return;
        };
        if let Some((_, cell)) = self.pages.row_and_cell(pin) {
            if matches!(cell.wide(), CellWide::SpacerTail) {
                pin.x = pin.x.saturating_sub(1);
            }
        }
        self.append_grapheme_to_pin(pin, codepoint);
    }

    fn append_grapheme_to_pin(&mut self, pin: Pin, codepoint: u32) {
        loop {
            let Some(node) = self.pages.node_mut(pin.node) else {
                return;
            };
            if node.page.append_grapheme(pin.y, pin.x, codepoint).is_ok() {
                return;
            }
            if self
                .pages
                .increase_capacity(pin.node, Some(IncreaseCapacity::GraphemeBytes))
                .is_err()
            {
                return;
            }
        }
    }

    pub fn start_hyperlink(&mut self, id: Option<&[u8]>, uri: &[u8]) {
        if self.start_hyperlink_once(id, uri) {
            return;
        }
        if let Some(pin) = self.cursor_pin() {
            let _ = self
                .pages
                .increase_capacity(pin.node, Some(IncreaseCapacity::HyperlinkBytes));
            let _ = self.start_hyperlink_once(id, uri);
        }
    }

    pub fn start_hyperlink_once(&mut self, id: Option<&[u8]>, uri: &[u8]) -> bool {
        self.end_hyperlink();
        let Some(pin) = self.cursor_pin() else {
            return false;
        };
        let Some(node) = self.pages.node_mut(pin.node) else {
            return false;
        };
        let inserted = match id {
            Some(id) => node
                .page
                .insert_hyperlink_explicit(id, uri)
                .map(|hyperlink_id| {
                    (
                        hyperlink_id,
                        Hyperlink {
                            id: HyperlinkIdKind::Explicit(id.to_vec()),
                            uri: uri.to_vec(),
                        },
                    )
                }),
            None => {
                self.cursor.hyperlink_implicit_id =
                    self.cursor.hyperlink_implicit_id.saturating_add(1);
                let implicit_id = self.cursor.hyperlink_implicit_id;
                node.page
                    .insert_hyperlink_implicit(implicit_id, uri)
                    .map(|hyperlink_id| {
                        (
                            hyperlink_id,
                            Hyperlink {
                                id: HyperlinkIdKind::Implicit(implicit_id),
                                uri: uri.to_vec(),
                            },
                        )
                    })
            }
        };

        let Ok((hyperlink_id, hyperlink)) = inserted else {
            if id.is_none() {
                self.cursor.hyperlink_implicit_id =
                    self.cursor.hyperlink_implicit_id.saturating_sub(1);
            }
            return false;
        };
        self.cursor.hyperlink_id = hyperlink_id;
        self.cursor.hyperlink = Some(hyperlink);
        true
    }

    pub fn end_hyperlink(&mut self) {
        if self.cursor.hyperlink_id != 0 {
            if let Some(pin) = self.cursor_pin() {
                if let Some(node) = self.pages.node_mut(pin.node) {
                    node.page.release_hyperlink_id(self.cursor.hyperlink_id);
                }
            }
        }
        self.cursor.hyperlink_id = 0;
        self.cursor.hyperlink = None;
    }

    pub fn cursor_set_hyperlink(&mut self) {
        let mut attempts = 0usize;
        self.cursor_set_hyperlink_with_retries(&mut attempts);
    }

    fn cursor_set_hyperlink_with_retries(&mut self, attempts: &mut usize) {
        if self.cursor.hyperlink_id == 0 {
            let Some(link) = self.cursor.hyperlink.clone() else {
                return;
            };
            let Some(pin) = self.cursor_pin() else {
                return;
            };
            let Some(node) = self.pages.node_mut(pin.node) else {
                return;
            };
            let inserted = match link.id {
                HyperlinkIdKind::Explicit(id) => {
                    node.page.insert_hyperlink_explicit(&id, &link.uri)
                }
                HyperlinkIdKind::Implicit(id) => node.page.insert_hyperlink_implicit(id, &link.uri),
            };
            let Ok(id) = inserted else {
                if self.increase_cursor_page_capacity_for_hyperlink(*attempts) {
                    *attempts = attempts.saturating_add(1);
                    self.cursor_set_hyperlink_with_retries(attempts);
                }
                return;
            };
            self.cursor.hyperlink_id = id;
        }
        if self.cursor.hyperlink_id == 0 {
            return;
        }
        let Some(pin) = self.cursor_pin() else {
            return;
        };
        if let Some(node) = self.pages.node_mut(pin.node) {
            if node
                .page
                .set_hyperlink_id(pin.y, pin.x, self.cursor.hyperlink_id)
                .is_err()
                && self.increase_cursor_page_capacity_for_hyperlink(*attempts)
            {
                *attempts = attempts.saturating_add(1);
                self.cursor_set_hyperlink_with_retries(attempts);
            }
        }
    }

    fn increase_cursor_page_capacity_for_hyperlink(&mut self, attempt: usize) -> bool {
        if attempt >= 16 {
            return false;
        }
        let Some(pin) = self.cursor_pin() else {
            return false;
        };
        self.release_cursor_refs();
        let dimension = if attempt.is_multiple_of(2) {
            IncreaseCapacity::StringBytes
        } else {
            IncreaseCapacity::HyperlinkBytes
        };
        if self
            .pages
            .increase_capacity(pin.node, Some(dimension))
            .is_err()
        {
            return false;
        }
        self.manual_style_update();
        self.cursor_reload();
        true
    }

    /// Modify the semantic content type of the cursor. Faithful port of
    /// ghostty's `cursorSetSemanticContent` (Screen.zig:2375). The `prompt`
    /// arm is the only one that marks the cursor's page row; the `input` and
    /// `output` arms touch cursor fields only.
    pub fn cursor_set_semantic_content(&mut self, content: SemanticContent) {
        self.cursor.semantic_content = content;
        self.cursor.semantic_content_clear_eol = false;
        match content {
            SemanticContent::Prompt => {
                self.semantic_prompt.seen = true;
                self.set_cursor_row_semantic_prompt(SemanticPrompt::Prompt);
            }
            // Ghostty's `.input`/`.output` arms only update the cursor; they do
            // NOT write `page_row.semantic_prompt`.
            SemanticContent::Input | SemanticContent::Output => {}
        }
    }

    /// The `.prompt` arm of `cursorSetSemanticContent` with an explicit
    /// `PromptKind`, controlling whether the row is marked `.prompt`
    /// (initial/right) or `.prompt_continuation` (continuation/secondary).
    pub fn cursor_set_semantic_prompt(&mut self, kind: PromptKind) {
        self.semantic_prompt.seen = true;
        self.cursor.semantic_content = SemanticContent::Prompt;
        self.cursor.semantic_content_clear_eol = false;
        let prompt = match kind {
            PromptKind::Initial | PromptKind::Right => SemanticPrompt::Prompt,
            PromptKind::Continuation | PromptKind::Secondary => SemanticPrompt::PromptContinuation,
        };
        self.set_cursor_row_semantic_prompt(prompt);
    }

    /// The `.input`/`.clear_eol` arm of `cursorSetSemanticContent`. Sets the
    /// cursor to input content that terminates at end-of-line. Ghostty does
    /// not mark the row here.
    pub fn cursor_set_semantic_input_clear_eol(&mut self) {
        self.cursor.semantic_content = SemanticContent::Input;
        self.cursor.semantic_content_clear_eol = true;
    }

    pub fn cursor_mark_dirty(&mut self) {
        if let Some(pin) = self.cursor_pin() {
            self.pages.mark_dirty(pin);
        }
    }

    pub fn dump_string(&self) -> String {
        self.dump_string_for_tag(Tag::Screen)
    }

    pub fn dump_string_alloc(&self) -> String {
        self.dump_string_alloc_unwrapped(false)
    }

    pub fn dump_string_alloc_unwrapped(&self, _unwrap: bool) -> String {
        self.dump_string_for_tag_unwrapped(Tag::Screen)
    }

    /// Dump a region, unwrapping soft-wrapped lines (Ghostty's
    /// `dumpString` with `unwrap = true`). Soft-wrapped rows are joined with
    /// no newline; blank cells carry across a wrap continuation. Mirrors the
    /// plaintext path of `formatter.zig`'s `PageFormatter.formatWithState`
    /// (with `trim = false`, matching `Screen.dumpString`).
    pub fn dump_string_for_tag_unwrapped(&self, tag: Tag) -> String {
        let top = self.pages.get_top_left(tag);
        let Some(bottom) = self.pages.get_bottom_right(tag) else {
            return String::new();
        };
        let mut out = String::new();
        let mut blank_rows: usize = 0;
        let mut blank_cells: usize = 0;
        let mut current = Some(top);
        while let Some(pin) = current {
            let is_last = pin.node == bottom.node && pin.y == bottom.y;
            if let Some(node) = self.pages.node(pin.node) {
                let page = &node.page;
                let cols = page.size().cols;
                let row = page.row(pin.y);

                // Does this row have any text at all?
                let has_text = (0..cols).any(|x| page.cell(pin.y, x).has_text());
                if !has_text {
                    blank_rows += 1;
                } else {
                    // Flush any pending blank rows as newlines.
                    for _ in 0..blank_rows {
                        out.push('\n');
                    }
                    blank_rows = 0;

                    // A non-wrapped row always emits a trailing newline later.
                    if !row.wrap() {
                        blank_rows += 1;
                    }
                    // Only continue accumulated blanks across a wrap continuation.
                    if !row.wrap_continuation() {
                        blank_cells = 0;
                    }

                    for x in 0..cols {
                        let cell = page.cell(pin.y, x);
                        match cell.wide() {
                            CellWide::SpacerHead | CellWide::SpacerTail => continue,
                            CellWide::Narrow | CellWide::Wide => {}
                        }
                        if !cell.has_text() {
                            blank_cells += 1;
                            continue;
                        }
                        // Flush accumulated blank cells as spaces.
                        for _ in 0..blank_cells {
                            out.push(' ');
                        }
                        blank_cells = 0;
                        if cell.codepoint() != 0 {
                            if let Some(ch) = char::from_u32(cell.codepoint()) {
                                out.push(ch);
                            }
                        }
                        if cell.has_grapheme() {
                            if let Some(values) = page.grapheme(pin.y, x) {
                                for value in values {
                                    if let Some(ch) = char::from_u32(value) {
                                        out.push(ch);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if is_last {
                break;
            }
            current = self.pages.pin_down(pin, 1);
        }
        out
    }

    pub fn dump_string_for_tag(&self, tag: Tag) -> String {
        let top = self.pages.get_top_left(tag);
        let Some(bottom) = self.pages.get_bottom_right(tag) else {
            return String::new();
        };
        let mut lines = Vec::new();
        let mut current = Some(top);
        while let Some(pin) = current {
            if let Some(node) = self.pages.node(pin.node) {
                lines.push(self.row_to_string(&node.page, pin.y));
            }
            if pin.node == bottom.node && pin.y == bottom.y {
                break;
            }
            current = self.pages.pin_down(pin, 1);
        }
        while lines.last().map(|line| line.is_empty()).unwrap_or(false) {
            let _ = lines.pop();
        }
        lines.join("\n")
    }

    pub fn test_write_string(&mut self, text: &str) {
        for ch in text.chars() {
            self.write_char(ch);
        }
    }

    pub fn clone_region(&self, top: Point, bot: Option<Point>) -> Self {
        let mut tracked = std::collections::HashMap::new();
        let cloned_pages = self.pages.clone(CloneOptions {
            top,
            bot,
            tracked_pins: Some(&mut tracked),
        });
        let mut clone = Self::new(Options {
            cols: self.cols(),
            rows: self.rows(),
            max_scrollback: if self.no_scrollback {
                0
            } else {
                self.pages.max_size()
            },
        });
        clone.pages = cloned_pages;
        if let Some(new_cursor_pin) = tracked.get(&self.cursor.pin).copied() {
            clone.cursor.pin = new_cursor_pin;
            if let Some(pin) = clone.cursor_pin() {
                if let Some(point) = clone.pages.point_from_pin(Tag::Active, pin) {
                    let coord = point.coord();
                    clone.cursor.x = coord.x.min(clone.cols().saturating_sub(1));
                    clone.cursor.y = (coord.y as CellCountInt).min(clone.rows().saturating_sub(1));
                }
            }
        } else {
            let pin = clone.pages.get_top_left(Tag::Active);
            let _ = clone.pages.set_tracked_pin(clone.cursor.pin, pin);
            clone.cursor.x = 0;
            clone.cursor.y = 0;
        }
        clone.cursor.style = self.cursor.style;
        clone.cursor.protected = self.cursor.protected;
        clone.cursor.pending_wrap = self.cursor.pending_wrap;
        clone.selection = self.remap_selection_for_clone(top, bot, &mut clone.pages);
        clone.manual_style_update();
        clone
    }

    fn remap_selection_for_clone(
        &self,
        top: Point,
        bot: Option<Point>,
        clone_pages: &mut PageList,
    ) -> Option<Selection> {
        let selection = self.selection?;
        let source_top_pin = self.pages.pin(top)?;
        let source_bottom_pin = match bot {
            Some(point) => self.pages.pin(point)?,
            None => self.pages.get_bottom_right(top.tag())?,
        };
        let source_top = self
            .pages
            .point_from_pin(Tag::Screen, source_top_pin)?
            .coord();
        let source_bottom = self
            .pages
            .point_from_pin(Tag::Screen, source_bottom_pin)?
            .coord();
        let region_top_y = source_top.y.min(source_bottom.y);
        let region_bottom_y = source_top.y.max(source_bottom.y);

        let top_left = selection.top_left(&self.pages)?;
        let bottom_right = selection.bottom_right(&self.pages)?;
        let top_left_point = self.pages.point_from_pin(Tag::Screen, top_left)?.coord();
        let bottom_right_point = self
            .pages
            .point_from_pin(Tag::Screen, bottom_right)?
            .coord();
        if bottom_right_point.y < region_top_y || top_left_point.y > region_bottom_y {
            return None;
        }

        if !selection.tracked() {
            return None;
        }

        let start = self.remap_selection_pin_for_clone(
            clone_pages,
            top_left,
            top_left_point,
            region_top_y,
            region_bottom_y,
            top.tag(),
            top.coord().y,
            bot.map(Point::coord).map(|coord| coord.y),
            true,
            selection.rectangle,
        )?;
        let end = self.remap_selection_pin_for_clone(
            clone_pages,
            bottom_right,
            bottom_right_point,
            region_top_y,
            region_bottom_y,
            top.tag(),
            top.coord().y,
            bot.map(Point::coord).map(|coord| coord.y),
            false,
            selection.rectangle,
        )?;
        Some(Selection {
            bounds: Bounds::Tracked { start, end },
            rectangle: selection.rectangle,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn remap_selection_pin_for_clone(
        &self,
        clone_pages: &mut PageList,
        source_pin: Pin,
        source_point: Coordinate,
        region_top_y: u32,
        region_bottom_y: u32,
        clone_tag: Tag,
        clone_top_y: u32,
        clone_bottom_y: Option<u32>,
        is_start: bool,
        rectangle: bool,
    ) -> Option<PinId> {
        if source_point.y >= region_top_y && source_point.y <= region_bottom_y {
            let tag_point = self.pages.point_from_pin(clone_tag, source_pin);
            let y = tag_point
                .map(Point::coord)
                .and_then(|coord| {
                    let region_min = clone_top_y.min(clone_bottom_y.unwrap_or(u32::MAX));
                    let region_max = clone_top_y.max(clone_bottom_y.unwrap_or(u32::MAX));
                    if coord.y >= region_min && coord.y <= region_max {
                        Some(coord.y.saturating_sub(region_min))
                    } else {
                        None
                    }
                })
                .unwrap_or_else(|| source_point.y.saturating_sub(region_top_y));
            let pin = clone_pages.pin(Point::active(source_pin.x, y))?;
            return Some(clone_pages.track_pin(pin));
        }

        let (x, y) = if is_start {
            let x = if rectangle { source_pin.x } else { 0 };
            (x, 0)
        } else {
            let x = if rectangle {
                source_pin.x
            } else {
                clone_pages.cols.saturating_sub(1)
            };
            (x, clone_pages.rows.saturating_sub(1) as u32)
        };
        let pin = clone_pages.pin(Point::active(x, y))?;
        Some(clone_pages.track_pin(pin))
    }

    pub fn select(&mut self, selection: Option<Selection>) {
        let Some(selection) = selection else {
            self.clear_selection();
            return;
        };
        let selection = if selection.tracked() {
            selection
        } else {
            selection.track(&mut self.pages)
        };
        if let Some(old) = self.selection.take() {
            old.untrack(&mut self.pages);
        }
        self.selection = Some(selection);
        self.dirty.selection = true;
    }

    pub fn clear_selection(&mut self) {
        if let Some(selection) = self.selection.take() {
            selection.untrack(&mut self.pages);
        }
        self.dirty.selection = true;
    }

    pub fn adjust_selection(&mut self, adjustment: Adjustment) {
        let Some(mut selection) = self.selection.take() else {
            return;
        };
        selection.adjust(&mut self.pages, adjustment);
        self.selection = Some(selection);
        self.dirty.selection = true;
    }

    pub fn selection_string(&self, options: SelectionStringOptions) -> String {
        let Some(top_left) = options.selection.top_left(&self.pages) else {
            return String::new();
        };
        let Some(bottom_right) = options.selection.bottom_right(&self.pages) else {
            return String::new();
        };
        let Some(top_left_point) = self
            .pages
            .point_from_pin(Tag::Screen, top_left)
            .map(Point::coord)
        else {
            return String::new();
        };
        let Some(bottom_right_point) = self
            .pages
            .point_from_pin(Tag::Screen, bottom_right)
            .map(Point::coord)
        else {
            return String::new();
        };

        let mut out = String::new();
        let mut current = top_left;
        let mut seen_row = false;
        while let Some(point) = self
            .pages
            .point_from_pin(Tag::Screen, current)
            .map(Point::coord)
        {
            if point.y > bottom_right_point.y {
                break;
            }
            if let Some(row_selection) = options.selection.contained_row_cached(
                &self.pages,
                top_left,
                bottom_right,
                current,
                top_left_point,
                bottom_right_point,
                point,
            ) {
                if seen_row && !previous_row_wraps(&self.pages, current) {
                    out.push('\n');
                }
                out.push_str(&self.selection_row_string(row_selection, options.trim));
                seen_row = true;
            }
            if current.node == bottom_right.node && current.y == bottom_right.y {
                break;
            }
            let Some(next) = self.pages.pin_down(current, 1) else {
                break;
            };
            current = next.left(next.x as usize);
        }
        if options.trim {
            trim_trailing_newlines_and_spaces(&mut out);
        }
        out
    }

    fn selection_row_string(&self, selection: Selection, trim: bool) -> String {
        let Some(start) = selection.start(&self.pages) else {
            return String::new();
        };
        let Some(end) = selection.end(&self.pages) else {
            return String::new();
        };
        if start.node != end.node || start.y != end.y {
            return String::new();
        }
        let min_x = start.x.min(end.x);
        let max_x = start.x.max(end.x);
        let Some(node) = self.pages.node(start.node) else {
            return String::new();
        };
        let mut out = String::new();
        for x in min_x..=max_x {
            let cell = node.page.cell(start.y, x);
            match cell.wide() {
                CellWide::SpacerTail | CellWide::SpacerHead => continue,
                CellWide::Narrow | CellWide::Wide => {}
            }
            if cell.has_grapheme() {
                if let Some(ch) = char::from_u32(cell.codepoint()) {
                    out.push(ch);
                }
                if let Some(values) = node.page.grapheme(start.y, x) {
                    for value in values {
                        if let Some(ch) = char::from_u32(value) {
                            out.push(ch);
                        }
                    }
                }
            } else if let Some(ch) = char::from_u32(cell.codepoint()) {
                if cell.has_text() {
                    out.push(ch);
                } else {
                    out.push(' ');
                }
            }
        }
        if trim {
            trim_trailing_spaces(&mut out);
        }
        out
    }

    pub fn select_all(&self) -> Option<Selection> {
        let whitespace = ['\0', ' ', '\t'];
        let start = self.first_non_whitespace_text(Direction::RightDown, &whitespace)?;
        let end = self.first_non_whitespace_text(Direction::LeftUp, &whitespace)?;
        Some(Selection::new(start, end, false))
    }

    pub fn select_line(&self, options: SelectLineOptions<'_>) -> Option<Selection> {
        let mut start = options.pin;
        while let Some(prior) = self.pages.pin_up(start, 1) {
            let wraps_from_prior = self
                .pages
                .row_and_cell(start)
                .map(|(row, _)| row.wrap_continuation())
                .unwrap_or(false);
            if !wraps_from_prior {
                break;
            }
            start = prior;
        }
        start.x = 0;

        let mut end = options.pin;
        loop {
            let wraps_to_next = self
                .pages
                .row_and_cell(end)
                .map(|(row, _)| row.wrap())
                .unwrap_or(false);
            let Some(line_end) = line_end_pin(&self.pages, end) else {
                break;
            };
            end = line_end;
            if !wraps_to_next {
                break;
            }
            let Some(next) = self.pages.pin_down(end, 1) else {
                break;
            };
            end = next.left(next.x as usize);
        }

        let whitespace = options.whitespace;
        if let Some(chars) = whitespace {
            start = self.trim_forward_to_text(start, end, chars)?;
            end = self.trim_backward_to_text(end, start, chars)?;
        }
        Some(Selection::new(start, end, false))
    }

    pub fn select_word_between(
        &self,
        start: Pin,
        end: Pin,
        boundaries: &[char],
    ) -> Option<Selection> {
        let direction = if self.pages.pin_before(start, end) {
            Direction::RightDown
        } else {
            Direction::LeftUp
        };
        let mut current = start;
        loop {
            if direction == Direction::RightDown && self.pages.pin_before(end, current) {
                return None;
            }
            if direction == Direction::LeftUp && self.pages.pin_before(current, end) {
                return None;
            }
            if let Some(selection) = self.select_word(current, boundaries) {
                return Some(selection);
            }
            current = match direction {
                Direction::RightDown => step_right(&self.pages, current)?,
                Direction::LeftUp => step_left(&self.pages, current)?,
            };
        }
    }

    pub fn select_word(&self, pin: Pin, boundaries: &[char]) -> Option<Selection> {
        let (_, start_cell) = self.pages.row_and_cell(pin)?;
        if !start_cell.has_text() {
            return None;
        }
        let expect_boundary = is_boundary(start_cell, boundaries);
        let mut end = pin;
        let mut current = pin;
        while let Some(next) = step_right(&self.pages, current) {
            if hard_line_boundary_right(&self.pages, next) {
                end = next;
                break;
            }
            let (_, cell) = self.pages.row_and_cell(next)?;
            if !cell.has_text() || is_boundary(cell, boundaries) != expect_boundary {
                break;
            }
            end = next;
            current = next;
        }

        let mut start = pin;
        current = pin;
        while let Some(prior) = step_left(&self.pages, current) {
            if hard_line_boundary_left(&self.pages, prior) {
                break;
            }
            let (_, cell) = self.pages.row_and_cell(prior)?;
            if !cell.has_text() || is_boundary(cell, boundaries) != expect_boundary {
                break;
            }
            start = prior;
            current = prior;
        }
        Some(Selection::new(start, end, false))
    }

    pub fn select_output(&self, pin: Pin) -> Option<Selection> {
        let (_, cell) = self.pages.row_and_cell(pin)?;
        if cell.semantic_content() != SemanticContent::Output {
            return None;
        }
        let mut start = pin;
        while let Some(prior) = step_left(&self.pages, start) {
            let Some((_, cell)) = self.pages.row_and_cell(prior) else {
                break;
            };
            if cell.semantic_content() != SemanticContent::Output {
                break;
            }
            start = prior;
        }
        let mut end = pin;
        while let Some(next) = step_right(&self.pages, end) {
            let Some((_, cell)) = self.pages.row_and_cell(next) else {
                break;
            };
            if cell.semantic_content() != SemanticContent::Output {
                break;
            }
            end = next;
        }
        Some(Selection::new(start, end, false))
    }

    pub fn line_iterator(&self, start: Pin) -> LineIterator<'_> {
        LineIterator {
            screen: self,
            current: Some(start),
        }
    }

    pub fn prompt_click_move(&self, click_pin: Pin) -> PromptClickMove {
        let Some(cursor_pin) = self.cursor_pin() else {
            return PromptClickMove::ZERO;
        };
        let cursor_input = self.cursor.semantic_content == SemanticContent::Input
            || self
                .cursor_cell()
                .map(|cell| cell.semantic_content() == SemanticContent::Input)
                .unwrap_or(false);
        if !cursor_input
            || matches!(
                self.semantic_prompt.click,
                SemanticClick::None | SemanticClick::ClickEvents(_)
            )
        {
            return PromptClickMove::ZERO;
        }
        self.prompt_click_line(cursor_pin, click_pin)
    }

    /// Determine the inputs required to move from the cursor to the given
    /// click location. If the cursor isn't currently at a prompt input
    /// location, this will return zero.
    ///
    /// This currently only supports moving a single line.
    ///
    /// Faithful port of ghostty's `promptClickLine` (Screen.zig:3012).
    fn prompt_click_line(&self, cursor_pin: Pin, click_pin: Pin) -> PromptClickMove {
        // If our click pin is our cursor pin, no movement is needed.
        // Do this early so we can assume later that they are different.
        if cursor_pin.eql(click_pin) {
            return PromptClickMove::ZERO;
        }

        // If our cursor is before our click, we're only emitting right inputs.
        if self.pages.pin_before(cursor_pin, click_pin) {
            let mut count = 0usize;

            // We go row-by-row because soft-wrapped rows are still a single
            // line to a shell, so we can't just look at our page row.
            let mut row_pin = Some(cursor_pin);
            'row_it: while let Some(row) = row_pin {
                let Some(node) = self.pages.node(row.node) else {
                    break;
                };
                let page_row = node.page.row(row.y);
                let cols = node.page.size().cols;

                // Determine if this row is our cursor.
                let is_cursor_row = row.node == cursor_pin.node && row.y == cursor_pin.y;

                // If this is not the cursor row, verify it's still part of the
                // continuation of our starting prompt.
                if !is_cursor_row
                    && page_row.semantic_prompt() != SemanticPrompt::PromptContinuation
                {
                    break;
                }

                // Determine where our input starts.
                let start_x = if is_cursor_row {
                    // If this is our cursor row then we start after the cursor.
                    cursor_pin.x.saturating_add(1)
                } else {
                    // Otherwise, we start at the first input cell, because
                    // we expect the shell to properly translate arrows across
                    // lines to the start of the input. Some shells indent
                    // where input starts on subsequent lines so we must do
                    // this. If we never find an input cell, we move on to the
                    // next row.
                    (0..cols)
                        .find(|&x| {
                            node.page.cell(row.y, x).semantic_content() == SemanticContent::Input
                        })
                        .unwrap_or(cols)
                };

                // Iterate over the input cells and assume arrow keys only
                // jump to input cells.
                for x in start_x..cols {
                    // Ignore non-input cells, but allow breaks. We assume
                    // the shell will translate arrow keys to only input
                    // areas.
                    if node.page.cell(row.y, x).semantic_content() != SemanticContent::Input {
                        continue;
                    }

                    // Increment our input count
                    count = count.saturating_add(1);

                    // If this is our target, we're done.
                    if row.node == click_pin.node && row.y == click_pin.y && x == click_pin.x {
                        break 'row_it;
                    }
                }

                // If this row isn't soft-wrapped, we need to break out
                // because line based moving only handles single lines.
                // We're done!
                if !page_row.wrap() {
                    // If we never found our pin, that means we clicked further
                    // right/beyond it. If we're already on a non-empty input cell
                    // then we add one so we can move to the newest, empty cell
                    // at the end, matching typical editor behavior.
                    let cursor_on_input = self
                        .cursor_cell()
                        .map(|cell| cell.semantic_content() == SemanticContent::Input)
                        .unwrap_or(false);
                    if cursor_on_input {
                        count = count.saturating_add(1);
                    }

                    break;
                }

                // The row iterator ends at the click row, inclusive.
                row_pin = if row.node == click_pin.node && row.y == click_pin.y {
                    None
                } else {
                    self.pages.pin_down(Pin { x: 0, ..row }, 1)
                };
            }

            return PromptClickMove {
                left: 0,
                right: count,
            };
        }

        // Otherwise, cursor is after click, so we're emitting left inputs.
        let mut count = 0usize;

        // We go row-by-row because soft-wrapped rows are still a single
        // line to a shell, so we can't just look at our page row.
        let mut row_pin = Some(cursor_pin);
        'row_it: while let Some(row) = row_pin {
            let Some(node) = self.pages.node(row.node) else {
                break;
            };
            let page_row = node.page.row(row.y);

            // Determine the length of the cells we look at in this row.
            let end_len = if row.node == cursor_pin.node && row.y == cursor_pin.y {
                // If this is our cursor row then we end before the cursor.
                cursor_pin.x
            } else {
                // Otherwise, we end at the last cell in the row.
                node.page.size().cols
            };

            // Iterate backwards over the input cells.
            for x in (0..end_len).rev() {
                // Ignore non-input cells.
                if node.page.cell(row.y, x).semantic_content() != SemanticContent::Input {
                    continue;
                }

                // Increment our input count
                count = count.saturating_add(1);

                // If this is our target, we're done.
                if row.node == click_pin.node && row.y == click_pin.y && x == click_pin.x {
                    break 'row_it;
                }
            }

            // If this row is not a wrap continuation, then break out
            if !page_row.wrap_continuation() {
                break;
            }

            // The row iterator ends at the click row, inclusive.
            row_pin = if row.node == click_pin.node && row.y == click_pin.y {
                None
            } else {
                self.pages.pin_up(Pin { x: 0, ..row }, 1)
            };
        }

        PromptClickMove {
            left: count,
            right: 0,
        }
    }

    fn first_non_whitespace_text(&self, direction: Direction, whitespace: &[char]) -> Option<Pin> {
        let mut iterator = self
            .pages
            .cell_iterator(direction, Point::screen(0, 0), None);
        while let Some(pin) = iterator.next(&self.pages) {
            let (_, cell) = self.pages.row_and_cell(pin)?;
            if cell.has_text() && !whitespace.contains(&cell_char(cell)) {
                return Some(pin);
            }
        }
        None
    }

    fn trim_forward_to_text(&self, start: Pin, end: Pin, whitespace: &[char]) -> Option<Pin> {
        let mut current = start;
        loop {
            let (_, cell) = self.pages.row_and_cell(current)?;
            if cell.has_text() && !whitespace.contains(&cell_char(cell)) {
                return Some(current);
            }
            if current.eql(end) {
                return None;
            }
            current = step_right(&self.pages, current)?;
        }
    }

    fn trim_backward_to_text(&self, start: Pin, end: Pin, whitespace: &[char]) -> Option<Pin> {
        let mut current = start;
        loop {
            let (_, cell) = self.pages.row_and_cell(current)?;
            if cell.has_text() && !whitespace.contains(&cell_char(cell)) {
                return Some(current);
            }
            if current.eql(end) {
                return None;
            }
            current = step_left(&self.pages, current)?;
        }
    }

    fn write_char(&mut self, ch: char) {
        match ch {
            '\n' => {
                self.cursor_down_or_scroll();
                self.cursor_horizontal_absolute(0);
                self.cursor.pending_wrap = false;
                if self.cursor.semantic_content_clear_eol {
                    self.cursor_set_semantic_content(SemanticContent::Output);
                } else if self.cursor.semantic_content != SemanticContent::Output {
                    self.set_cursor_row_semantic_prompt(SemanticPrompt::PromptContinuation);
                }
                return;
            }
            '\r' => {
                self.cursor_horizontal_absolute(0);
                return;
            }
            _ => {}
        }

        let width = if u32::from(ch) <= 0xFF {
            1
        } else {
            UnicodeWidthChar::width(ch).unwrap_or(0)
        };
        if width == 0 {
            self.append_grapheme_to_previous_cell(u32::from(ch));
            return;
        }

        if self.cursor.pending_wrap {
            self.wrap_to_next_line();
        }

        if width == 2 && self.cursor.x == self.cols().saturating_sub(1) {
            self.write_spacer_head();
            self.wrap_to_next_line();
        }

        self.write_cell(ch, width);
        if width == 2 {
            self.cursor_right(1);
            self.write_spacer_tail();
        }

        if self.cursor.x < self.cols().saturating_sub(1) {
            self.cursor_right(1);
        } else {
            self.cursor.pending_wrap = true;
        }
        self.assert_integrity();
    }

    fn wrap_to_next_line(&mut self) {
        if let Some(pin) = self.cursor_pin() {
            if let Some(node) = self.pages.node_mut(pin.node) {
                let mut row = node.page.row(pin.y);
                row.set_wrap(true);
                node.page.set_row(pin.y, row);
            }
        }
        self.cursor_down_or_scroll();
        self.cursor_horizontal_absolute(0);
        if let Some(pin) = self.cursor_pin() {
            if let Some(node) = self.pages.node_mut(pin.node) {
                let mut row = node.page.row(pin.y);
                row.set_wrap_continuation(true);
                if self.cursor.semantic_content != SemanticContent::Output {
                    row.set_semantic_prompt(SemanticPrompt::PromptContinuation);
                }
                node.page.set_row(pin.y, row);
            }
        }
        self.cursor.pending_wrap = false;
    }

    pub(crate) fn write_cell(&mut self, ch: char, width: usize) {
        let mut cell = Cell::new(ch);
        cell.set_protected(self.cursor.protected);
        cell.set_semantic_content(self.cursor.semantic_content);
        if width == 2 {
            cell.set_wide(CellWide::Wide);
        }
        self.apply_cursor_style(&mut cell);
        self.put_cell_at_cursor(cell);
        self.cursor_set_hyperlink();
    }

    pub(crate) fn write_spacer_tail(&mut self) {
        let mut cell = Cell::default();
        cell.set_wide(CellWide::SpacerTail);
        self.put_cell_at_cursor(cell);
        self.cursor_set_hyperlink();
    }

    pub(crate) fn write_spacer_head(&mut self) {
        let mut cell = Cell::default();
        cell.set_wide(CellWide::SpacerHead);
        self.put_cell_at_cursor(cell);
        self.cursor_set_hyperlink();
    }

    /// Append `codepoint` to the grapheme data of the cell at `pin`, growing
    /// the page's grapheme capacity if needed. Mirrors Ghostty's
    /// `appendGrapheme` for an arbitrary cell.
    pub(crate) fn append_grapheme_pin(&mut self, pin: Pin, codepoint: u32) {
        self.append_grapheme_to_pin(pin, codepoint);
    }

    /// Write a single cell at the cursor after charset translation, matching
    /// Ghostty's `Terminal.printCell`. Handles clearing wide-char spacers when
    /// the cell's width class changes, clearing stale grapheme data, style
    /// reference counting, and hyperlink attachment.
    pub(crate) fn print_cell(&mut self, unmapped_c: u32, wide: CellWide) {
        let c = self.translate_charset(unmapped_c);

        let Some(pin) = self.cursor_pin() else {
            return;
        };
        let cell = self.cursor_cell().unwrap_or_default();

        // If the wide property changes we may need to clear neighboring spacer
        // cells so we don't orphan a wide char.
        if cell.wide() != wide {
            match cell.wide() {
                CellWide::Narrow => {}
                CellWide::Wide => {
                    if self.cursor.x < self.cols().saturating_sub(1) {
                        let spacer_x = self.cursor.x.saturating_add(1);
                        if let Some(node) = self.pages.node_mut(pin.node) {
                            node.page
                                .clear_cells(pin.y, spacer_x, spacer_x.saturating_add(1));
                        }
                        self.clear_stale_spacer_head();
                    }
                }
                CellWide::SpacerTail => {
                    debug_assert!(self.cursor.x > 0);
                    let wide_x = self.cursor.x.saturating_sub(1);
                    if let Some(node) = self.pages.node_mut(pin.node) {
                        node.page
                            .clear_cells(pin.y, wide_x, wide_x.saturating_add(1));
                    }
                    self.clear_stale_spacer_head();
                }
                // Ghostty leaves this case unhandled (see printCell). Match that.
                CellWide::SpacerHead => {}
            }
        }

        // Clear any prior grapheme data on the cell being overwritten.
        if cell.has_grapheme() {
            if let Some(node) = self.pages.node_mut(pin.node) {
                node.page.clear_grapheme(pin.y, pin.x);
            }
        }

        // Release the old style ref if the style is changing.
        let style_changed = cell.style_id() != self.cursor.style_id;
        if style_changed && cell.style_id() != DEFAULT_STYLE_ID {
            if let Some(node) = self.pages.node_mut(pin.node) {
                node.page.release_style(cell.style_id());
            }
        }

        let had_hyperlink = cell.hyperlink();

        // Write the new cell wholesale.
        let mut new_cell = Cell::new(c);
        new_cell.set_style_id(self.cursor.style_id);
        new_cell.set_wide(wide);
        new_cell.set_protected(self.cursor.protected);
        new_cell.set_semantic_content(self.cursor.semantic_content);
        if let Some(node) = self.pages.node_mut(pin.node) {
            node.page.set_cell(pin.y, pin.x, new_cell);
        }

        // Acquire the new style ref if the style changed.
        if style_changed && self.cursor.style_id != DEFAULT_STYLE_ID {
            if let Some(node) = self.pages.node_mut(pin.node) {
                node.page.use_style(self.cursor.style_id);
                let mut row = node.page.row(pin.y);
                row.set_styled(true);
                node.page.set_row(pin.y, row);
            }
        }

        // Hyperlink handling: attach the active hyperlink, or clear a stale one.
        if self.cursor.hyperlink_id > 0 {
            self.cursor_set_hyperlink();
        } else if had_hyperlink {
            if let Some(node) = self.pages.node_mut(pin.node) {
                node.page.clear_hyperlink(pin.y, pin.x);
            }
            self.update_row_hyperlink_flag(pin);
        }

        self.assert_integrity();
    }

    /// When overwriting a wide char near the left edge, a wide char may have
    /// wrapped from the previous row leaving a `spacer_head` at the end of that
    /// row. Clear it so the previous row doesn't keep a stale `spacer_head`.
    fn clear_stale_spacer_head(&mut self) {
        if self.cursor.y == 0 || self.cursor.x > 1 {
            return;
        }
        let Some(pin) = self.cursor_pin() else {
            return;
        };
        let Some(prev) = self.pages.pin_up(pin, 1) else {
            return;
        };
        let last_x = self.cols().saturating_sub(1);
        if let Some(node) = self.pages.node_mut(prev.node) {
            let mut head = node.page.cell(prev.y, last_x);
            if matches!(head.wide(), CellWide::SpacerHead) {
                head.set_wide(CellWide::Narrow);
                node.page.set_cell(prev.y, last_x, head);
            }
        }
    }

    fn update_row_hyperlink_flag(&mut self, pin: Pin) {
        if let Some(node) = self.pages.node_mut(pin.node) {
            node.page.update_row_grapheme_flag(pin.y);
        }
    }

    fn translate_charset(&mut self, unmapped_c: u32) -> char {
        // If we're single shifting, then we use the key exactly once.
        let key = match self.charset.single_shift.take() {
            Some(key_once) => key_once,
            None => self.charset.gl,
        };

        let set = self.charset.get(key);

        // UTF-8 or ASCII is used as-is.
        if matches!(set, Charset::Utf8 | Charset::Ascii) {
            return char::from_u32(unmapped_c).unwrap_or('\u{FFFD}');
        }

        // If we're outside of ASCII range this is an invalid value in this
        // table so we just return space.
        if unmapped_c > u32::from(u8::MAX) {
            return ' ';
        }

        // Get our lookup table and map it.
        let Some(table) = crate::charsets::table(set) else {
            return char::from_u32(unmapped_c).unwrap_or('\u{FFFD}');
        };
        let mapped = u32::from(table[unmapped_c as usize]);
        char::from_u32(mapped).unwrap_or('\u{FFFD}')
    }

    fn put_cell_at_cursor(&mut self, cell: Cell) {
        let Some(pin) = self.cursor_pin() else {
            return;
        };
        if let Some(node) = self.pages.node_mut(pin.node) {
            node.page.clear_cells(pin.y, pin.x, pin.x.saturating_add(1));
            node.page.set_cell(pin.y, pin.x, cell);
            let prompt = match self.cursor.semantic_content {
                SemanticContent::Prompt => SemanticPrompt::Prompt,
                SemanticContent::Input => SemanticPrompt::PromptContinuation,
                SemanticContent::Output => SemanticPrompt::None,
            };
            let mut row = node.page.row(pin.y);
            row.set_semantic_prompt(prompt);
            node.page.set_row(pin.y, row);
            if cell.style_id() != DEFAULT_STYLE_ID {
                node.page.use_style(cell.style_id());
            }
        }
    }

    fn apply_cursor_style(&self, cell: &mut Cell) {
        if self.cursor.style_id != DEFAULT_STYLE_ID {
            cell.set_style_id(self.cursor.style_id);
        }
    }

    pub(crate) fn cursor_change_active_point(&mut self, x: CellCountInt, y: CellCountInt) {
        if let Some(pin) = self.pages.pin(Point::active(x, u32::from(y))) {
            // Moving the cursor affects text run splitting (ligatures) so we
            // mark both the old and new rows dirty when the pin changes.
            // Mirrors Ghostty's `cursorChangePin`.
            let old_pin = self.cursor_pin();
            if old_pin != Some(pin) {
                if let Some(old_pin) = old_pin {
                    self.pages.mark_dirty(old_pin);
                }
                self.pages.mark_dirty(pin);
            }
            self.release_cursor_refs();
            let _ = self.pages.set_tracked_pin(self.cursor.pin, pin);
            self.cursor.x = x;
            self.cursor.y = y;
            self.manual_style_update();
            self.cursor_set_hyperlink();
        }
        self.assert_integrity();
    }

    fn release_cursor_refs(&mut self) {
        if self.cursor.style_id != DEFAULT_STYLE_ID {
            if let Some(pin) = self.cursor_pin() {
                if let Some(node) = self.pages.node_mut(pin.node) {
                    node.page.release_style(self.cursor.style_id);
                }
            }
            self.cursor.style_id = DEFAULT_STYLE_ID;
        }
        if self.cursor.hyperlink_id != 0 {
            if let Some(pin) = self.cursor_pin() {
                if let Some(node) = self.pages.node_mut(pin.node) {
                    node.page.release_hyperlink_id(self.cursor.hyperlink_id);
                }
            }
            self.cursor.hyperlink_id = 0;
        }
    }

    fn detach_cursor_hyperlink_for_resize(&mut self) -> Option<Hyperlink> {
        let hyperlink = self.cursor.hyperlink.clone();
        if self.cursor.hyperlink_id != 0 {
            if let Some(pin) = self.cursor_pin() {
                if let Some(node) = self.pages.node_mut(pin.node) {
                    node.page.release_hyperlink_id(self.cursor.hyperlink_id);
                }
            }
            self.cursor.hyperlink_id = 0;
            self.cursor.hyperlink = None;
        }
        hyperlink
    }

    fn reattach_cursor_hyperlink(&mut self, link: Hyperlink) {
        let explicit_id = match &link.id {
            HyperlinkIdKind::Explicit(id) => Some(id.as_slice()),
            HyperlinkIdKind::Implicit(_) => None,
        };
        self.start_hyperlink(explicit_id, &link.uri);
    }

    fn track_saved_cursor_pin_for_resize(&mut self) -> Option<PinId> {
        let saved = self.saved_cursor.as_ref()?;
        let pin = self.pages.pin(Point::active(saved.x, u32::from(saved.y)))?;
        Some(self.pages.track_pin(pin))
    }

    fn fix_saved_cursor_after_resize(
        &mut self,
        saved_cursor_pin: Option<PinId>,
        new_cols: CellCountInt,
    ) {
        let Some(saved_cursor_pin) = saved_cursor_pin else {
            return;
        };
        let point = self
            .pages
            .tracked_pin(saved_cursor_pin)
            .and_then(|pin| self.pages.point_from_pin(Tag::Active, pin));
        let Some(saved) = self.saved_cursor.as_mut() else {
            return;
        };

        if let Some(point) = point {
            let coord = point.coord();
            saved.x = coord.x.min(new_cols.saturating_sub(1));
            saved.y = coord.y as CellCountInt;
            if saved.pending_wrap && saved.x != new_cols.saturating_sub(1) {
                saved.pending_wrap = false;
                saved.x = saved.x.saturating_add(1);
            }
        } else {
            saved.x = 0;
            saved.y = 0;
            saved.pending_wrap = false;
        }
    }

    fn clear_prompt_for_resize(&mut self, redraw: PromptRedraw) {
        if redraw == PromptRedraw::False || self.cursor.semantic_content == SemanticContent::Output
        {
            return;
        }

        match redraw {
            PromptRedraw::False => {}
            PromptRedraw::Last => self.clear_row_at_cursor(),
            PromptRedraw::True => self.clear_prompt_block_for_resize(),
        }
    }

    fn clear_prompt_block_for_resize(&mut self) {
        let Some(cursor_pin) = self.cursor_pin() else {
            return;
        };
        let Some(cursor_point) = self.pages.point_from_pin(Tag::Active, cursor_pin) else {
            return;
        };
        let coord = cursor_point.coord();
        let mut prompts =
            self.pages
                .prompt_iterator(Direction::LeftUp, Point::active(coord.x, coord.y), None);
        let Some(mut current) = prompts.next(&self.pages) else {
            return;
        };
        current.x = 0;

        loop {
            self.clear_row(current, false);
            if current.node == cursor_pin.node && current.y == cursor_pin.y {
                break;
            }
            let Some(next) = self.pages.pin_down(current, 1) else {
                break;
            };
            current = Pin { x: 0, ..next };
        }
    }

    pub(crate) fn set_cursor_row_semantic_prompt(&mut self, prompt: SemanticPrompt) {
        if let Some(pin) = self.cursor_pin() {
            if let Some(node) = self.pages.node_mut(pin.node) {
                let mut row = node.page.row(pin.y);
                row.set_semantic_prompt(prompt);
                node.page.set_row(pin.y, row);
            }
        }
    }

    /// The semantic-prompt classification of the cursor's page row, mirroring
    /// a read of ghostty's `cursor.page_row.semantic_prompt`.
    pub fn cursor_row_semantic_prompt(&self) -> Option<SemanticPrompt> {
        let pin = self.cursor_pin()?;
        self.pages
            .node(pin.node)
            .map(|node| node.page.row(pin.y).semantic_prompt())
    }

    fn clear_row_at_cursor(&mut self) {
        if let Some(pin) = self.cursor_pin() {
            self.clear_row(pin, false);
        }
    }

    fn clear_row(&mut self, pin: Pin, protected: bool) {
        // Ghostty's `clearRows` fills with `blankCell()`, so a non-default
        // cursor background is preserved across the cleared row.
        let fill = self.blank_cell();
        if let Some(node) = self.pages.node_mut(pin.node) {
            let cols = node.page.size().cols;
            if protected {
                for x in 0..cols {
                    if !node.page.cell(pin.y, x).protected() {
                        node.page.fill_cells(pin.y, x, x.saturating_add(1), fill);
                    }
                }
            } else {
                node.page.fill_cells(pin.y, 0, cols, fill);
            }
        }
    }

    fn fill_cursor_row_background(&mut self) {
        let Some(pin) = self.cursor_pin() else {
            return;
        };
        if let Some(node) = self.pages.node_mut(pin.node) {
            for x in 0..node.page.size().cols {
                // Ghostty has two independent clear paths: one for a local
                // non-empty background color and one for a non-default cursor
                // style whose bgCell() is present. The merged Rust path keeps
                // the boundary pinned by the bold-only scroll test below.
                let cell = match self.cursor.style.bg_color {
                    StyleColor::Rgb(rgb) => Cell::bg_rgb(rgb),
                    StyleColor::Palette(index) => Cell::bg_palette(index),
                    StyleColor::None => return,
                };
                node.page.clear_cells(pin.y, x, x.saturating_add(1));
                node.page.set_cell(pin.y, x, cell);
            }
        }
    }

    fn row_to_string(&self, page: &Page, y: CellCountInt) -> String {
        let last_meaningful = (0..page.size().cols)
            .rev()
            .find(|&x| {
                let cell = page.cell(y, x);
                cell.has_text()
                    || matches!(cell.wide(), CellWide::SpacerHead | CellWide::SpacerTail)
            })
            .map(|x| x.saturating_add(1))
            .unwrap_or(0);
        let mut out = String::new();
        for x in 0..last_meaningful {
            let cell = page.cell(y, x);
            match cell.wide() {
                CellWide::SpacerTail | CellWide::SpacerHead => continue,
                CellWide::Narrow | CellWide::Wide => {}
            }
            if cell.has_grapheme() {
                if cell.codepoint() != 0 {
                    if let Some(ch) = char::from_u32(cell.codepoint()) {
                        out.push(ch);
                    }
                }
                if let Some(values) = page.grapheme(y, x) {
                    for value in values {
                        if let Some(ch) = char::from_u32(value) {
                            out.push(ch);
                        }
                    }
                }
            } else if cell.has_text() {
                if let Some(ch) = char::from_u32(cell.codepoint()) {
                    out.push(ch);
                }
            } else {
                out.push(' ');
            }
        }
        out
    }
}

pub struct LineIterator<'a> {
    screen: &'a Screen,
    current: Option<Pin>,
}

impl Iterator for LineIterator<'_> {
    type Item = Selection;

    fn next(&mut self) -> Option<Self::Item> {
        let current = self.current?;
        let selection = self.screen.select_line(SelectLineOptions {
            pin: current,
            whitespace: None,
            semantic_prompt_boundary: false,
        })?;
        self.current = selection
            .end(&self.screen.pages)
            .and_then(|pin| self.screen.pages.pin_down(pin, 1));
        Some(selection)
    }
}

fn previous_row_wraps(pages: &PageList, row: Pin) -> bool {
    let Some(previous) = pages.pin_up(row, 1) else {
        return false;
    };
    pages
        .row_and_cell(previous)
        .map(|(row, _)| row.wrap())
        .unwrap_or(false)
}

fn trim_trailing_spaces(value: &mut String) {
    while value.ends_with(' ') {
        let _ = value.pop();
    }
}

fn trim_trailing_newlines_and_spaces(value: &mut String) {
    while value.ends_with(' ') || value.ends_with('\n') {
        let _ = value.pop();
    }
}

fn line_end_pin(pages: &PageList, pin: Pin) -> Option<Pin> {
    let cols = pages.node(pin.node)?.page.size().cols;
    Some(Pin {
        x: cols.saturating_sub(1),
        ..pin
    })
}

fn cell_char(cell: Cell) -> char {
    char::from_u32(cell.codepoint()).unwrap_or('\0')
}

fn is_boundary(cell: Cell, boundaries: &[char]) -> bool {
    boundaries.contains(&cell_char(cell))
}

fn hard_line_boundary_right(pages: &PageList, pin: Pin) -> bool {
    let Some((row, _)) = pages.row_and_cell(pin) else {
        return false;
    };
    let Some(node) = pages.node(pin.node) else {
        return false;
    };
    pin.x == node.page.size().cols.saturating_sub(1) && !row.wrap()
}

fn hard_line_boundary_left(pages: &PageList, pin: Pin) -> bool {
    let Some((row, _)) = pages.row_and_cell(pin) else {
        return false;
    };
    let Some(node) = pages.node(pin.node) else {
        return false;
    };
    pin.x == node.page.size().cols.saturating_sub(1) && !row.wrap()
}

fn step_left(pages: &PageList, pin: Pin) -> Option<Pin> {
    if pin.x > 0 {
        return Some(Pin {
            x: pin.x - 1,
            ..pin
        });
    }
    let mut prior = pages.pin_up(pin, 1)?;
    prior.x = pages
        .node(prior.node)
        .map(|node| node.page.size().cols.saturating_sub(1))
        .unwrap_or(0);
    Some(prior)
}

fn step_right(pages: &PageList, pin: Pin) -> Option<Pin> {
    let cols = pages.node(pin.node)?.page.size().cols;
    if pin.x + 1 < cols {
        return Some(Pin {
            x: pin.x + 1,
            ..pin
        });
    }
    pages.pin_down(Pin { x: 0, ..pin }, 1)
}

fn palette_color(name: Name) -> StyleColor {
    StyleColor::Palette(name.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::style::StyleFlags;

    fn active_cell(screen: &Screen, x: CellCountInt, y: CellCountInt) -> Cell {
        screen
            .pages
            .get_cell(Point::active(x, y as u32))
            .unwrap_or_default()
    }

    fn active_pin(screen: &Screen, y: CellCountInt) -> Pin {
        screen.pages.pin(Point::active(0, u32::from(y))).unwrap()
    }

    fn screen_pin(screen: &Screen, x: CellCountInt, y: u32) -> Pin {
        screen.pages.pin(Point::screen(x, y)).unwrap()
    }

    fn active_row(screen: &Screen, y: CellCountInt) -> crate::page::Row {
        let pin = active_pin(screen, y);
        screen.pages.row_and_cell(pin).unwrap().0
    }

    fn set_screen_row_wrap(pages: &mut PageList, y: u32, wrap: bool, continuation: bool) {
        let pin = pages.pin(Point::screen(0, y)).unwrap();
        let node = pages.node_mut(pin.node).unwrap();
        let mut row = node.page.row(pin.y);
        row.set_wrap(wrap);
        row.set_wrap_continuation(continuation);
        node.page.set_row(pin.y, row);
    }

    fn resize(cols: CellCountInt, rows: CellCountInt) -> Resize {
        Resize::new(cols, rows)
    }

    fn resize_no_reflow(cols: CellCountInt, rows: CellCountInt) -> Resize {
        Resize::without_reflow(cols, rows)
    }

    fn clear_all_dirty(screen: &mut Screen) {
        let mut current = screen.pages.first_node();
        while let Some(id) = current {
            let next = screen.pages.node(id).and_then(|node| node.next);
            if let Some(node) = screen.pages.node_mut(id) {
                node.page.clear_dirty();
            }
            current = next;
        }
    }

    fn cursor_page_style_count(screen: &Screen) -> usize {
        let pin = screen.cursor_pin().expect("cursor pin");
        screen.pages.node(pin.node).unwrap().page.style_count()
    }

    fn cursor_page_hyperlink_count(screen: &Screen) -> usize {
        let pin = screen.cursor_pin().expect("cursor pin");
        screen.pages.node(pin.node).unwrap().page.hyperlink_count()
    }

    fn cursor_node(screen: &Screen) -> crate::page_list::NodeId {
        screen.cursor_pin().expect("cursor pin").node
    }

    fn force_cursor_to_next_page(screen: &mut Screen) -> crate::page_list::NodeId {
        let start = cursor_node(screen);
        let rows = screen.pages.node(start).unwrap().page.capacity().rows;
        for _ in 0..rows {
            screen.cursor_down_or_scroll();
        }
        let current = cursor_node(screen);
        assert_ne!(start, current);
        current
    }

    fn active_row_on_different_node(
        screen: &Screen,
        node: crate::page_list::NodeId,
    ) -> CellCountInt {
        for y in 0..screen.rows() {
            let pin = screen.pages.pin(Point::active(0, u32::from(y))).unwrap();
            if pin.node != node {
                return y;
            }
        }
        panic!("expected active area to span multiple pages");
    }

    fn active_row_whose_previous_is_on_different_node(screen: &Screen) -> CellCountInt {
        for y in 1..screen.rows() {
            let pin = screen.pages.pin(Point::active(0, u32::from(y))).unwrap();
            let previous = screen.pages.pin_up(pin, 1).unwrap();
            if previous.node != pin.node {
                return y;
            }
        }
        panic!("expected an active row after a page boundary");
    }

    fn fill_cursor_page_styles(screen: &mut Screen) {
        fill_page_styles(screen, cursor_node(screen));
    }

    fn fill_page_styles(screen: &mut Screen, node_id: crate::page_list::NodeId) {
        let mut index = 1u32;
        loop {
            let style = PackedStyle::from(Style {
                bg_color: StyleColor::Rgb(crate::color::Rgb {
                    r: ((index >> 16) & 0xFF) as u8,
                    g: ((index >> 8) & 0xFF) as u8,
                    b: (index & 0xFF) as u8,
                }),
                ..Style::default()
            });
            let Some(node) = screen.pages.node_mut(node_id) else {
                break;
            };
            if node.page.add_style(style).is_err() {
                break;
            }
            index = index.saturating_add(1);
        }
    }

    #[test]
    fn screen_initializes_with_cursor_pin() {
        // port-added: Rust Screen construction exposes cursor PinId state directly.
        let screen = Screen::new(Options::default());
        assert_eq!(screen.cols(), 80);
        assert_eq!(screen.rows(), 24);
        assert_eq!(screen.cursor.x, 0);
        assert_eq!(screen.cursor.y, 0);
        assert!(screen.cursor_pin().is_some());
    }

    #[test]
    fn screen_reset_clears_history_and_cursor_refs() {
        // port-added: reset is a public Screen-core operation in this slice.
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 10,
        });
        screen.set_attribute(Attribute::Bold);
        screen.start_hyperlink(Some(b"id"), b"https://example.com");
        screen.test_write_string("1\n2\n3\n4");

        screen.reset();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "");
        assert_eq!((screen.cursor.x, screen.cursor.y), (0, 0));
        assert_eq!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(screen.cursor.hyperlink_id, 0);
        assert!(screen.cursor_pin().is_some());
    }

    #[test]
    fn screen_writes_plain_text() {
        // ghostty: "Screen read and write" (Screen.zig:3365)
        let mut screen = Screen::new(Options {
            max_scrollback: 1000,
            ..Options::default()
        });
        assert_eq!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        screen.test_write_string("hello, world");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "hello, world");
        assert_eq!(screen.cursor.x, 12);
    }

    #[test]
    fn screen_writes_newline() {
        // ghostty: "Screen read and write newline" (Screen.zig:3379)
        let mut screen = Screen::new(Options {
            max_scrollback: 1000,
            ..Options::default()
        });
        assert_eq!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        screen.test_write_string("hello\nworld");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "hello\nworld");
        assert_eq!((screen.cursor.x, screen.cursor.y), (5, 1));
    }

    #[test]
    fn resize_no_reflow_more_rows_keeps_contents() {
        // ghostty: "Screen: resize (no reflow) more rows" (Screen.zig:5780)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "1ABCD\n2EFGH\n3IJKL";
        screen.test_write_string(text);

        screen.resize(resize_no_reflow(10, 10)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
    }

    #[test]
    fn resize_no_reflow_less_rows_moves_active_view() {
        // ghostty: "Screen: resize (no reflow) less rows" (Screen.zig:5798)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        assert_eq!((screen.cursor.x, screen.cursor.y), (5, 2));

        screen.resize(resize_no_reflow(10, 2)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (5, 1));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");
    }

    #[test]
    fn resize_no_reflow_less_cols_clips_cells() {
        // ghostty: "Screen: resize (no reflow) less cols" (Screen.zig:5908)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");

        screen.resize(resize_no_reflow(4, 3)).unwrap();

        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABC\n2EFG\n3IJK"
        );
    }

    #[test]
    fn resize_no_reflow_with_scrollback_keeps_bottom_rows() {
        // ghostty: "Screen: resize (no reflow) less rows with scrollback" (Screen.zig:5943)
        let mut screen = Screen::new(Options {
            cols: 7,
            rows: 3,
            max_scrollback: 2,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH");

        screen.resize(resize_no_reflow(7, 2)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "4ABCD\n5EFGH");
    }

    #[test]
    fn resize_no_reflow_more_rows_preserves_wrap_flags() {
        // ghostty: "Screen: resize (no reflow) more rows with soft wrapping" (Screen.zig:5986)
        let mut screen = Screen::new(Options {
            cols: 2,
            rows: 3,
            max_scrollback: 3,
        });
        screen.test_write_string("1A2B\n3C4E\n5F6G");
        for y in 0..6 {
            assert_eq!(
                screen
                    .pages
                    .row_and_cell(screen.pages.pin(Point::screen(0, y)).unwrap())
                    .unwrap()
                    .0
                    .wrap(),
                y % 2 == 0
            );
        }

        screen.resize(resize_no_reflow(2, 10)).unwrap();

        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1A\n2B\n3C\n4E\n5F\n6G"
        );
        for y in 0..6 {
            assert_eq!(
                screen
                    .pages
                    .row_and_cell(screen.pages.pin(Point::screen(0, y)).unwrap())
                    .unwrap()
                    .0
                    .wrap(),
                y % 2 == 0
            );
        }
    }

    #[test]
    fn resize_more_rows_no_scrollback_keeps_screen_contents() {
        // ghostty: "Screen: resize more rows no scrollback" (Screen.zig:6027)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "1ABCD\n2EFGH\n3IJKL";
        screen.test_write_string(text);
        let cursor = screen.cursor_copy();

        screen.resize(resize(5, 10)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (cursor.x, cursor.y));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
    }

    #[test]
    fn resize_more_rows_with_populated_scrollback_preserves_cursor_cell() {
        // ghostty: "Screen: resize more rows with populated scrollback" (Screen.zig:6081)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "3IJKL\n4ABCD\n5EFGH"
        );
        screen.cursor_absolute(0, 1);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '4' as u32
        );

        screen.resize(resize(5, 10)).unwrap();

        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '4' as u32
        );
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "3IJKL\n4ABCD\n5EFGH"
        );
    }

    #[test]
    fn resize_more_cols_perfect_split_unwraps_soft_wrapped_rows() {
        // ghostty: "Screen: resize more cols perfect split" (Screen.zig:6155)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD2EFGH3IJKL");

        screen.resize(resize(10, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "1ABCD2EFGH\n3IJKL");
    }

    #[test]
    fn resize_more_cols_preserves_semantic_prompt_rows() {
        // ghostty: "Screen: resize more cols no reflow preserves semantic prompt" (Screen.zig:6250)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.cursor_set_semantic_content(SemanticContent::Output);
        screen.test_write_string("1ABCD\n");
        screen.cursor_set_semantic_content(SemanticContent::Prompt);
        screen.test_write_string("2EFGH");
        screen.cursor_set_semantic_content(SemanticContent::Output);
        screen.test_write_string("\n3IJKL");
        screen.resize(resize_no_reflow(10, 3)).unwrap();

        let expected = "1ABCD\n2EFGH\n3IJKL";
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), expected);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), expected);
        assert_eq!(
            active_row(&screen, 0).semantic_prompt(),
            SemanticPrompt::None
        );
        assert_eq!(
            active_row(&screen, 1).semantic_prompt(),
            SemanticPrompt::Prompt
        );
        assert_eq!(
            active_row(&screen, 2).semantic_prompt(),
            SemanticPrompt::None
        );
    }

    #[test]
    fn resize_more_cols_reflows_cursor_position() {
        // ghostty: "Screen: resize more cols with reflow that fits full width" (Screen.zig:6294)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "1ABCD2EFGH\n3IJKL";
        screen.test_write_string(text);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );
        screen.cursor_absolute(0, 1);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '2' as u32
        );

        screen.resize(resize(10, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!((screen.cursor.x, screen.cursor.y), (5, 0));
    }

    #[test]
    fn resize_less_rows_with_full_scrollback_keeps_cursor_relative_to_bottom() {
        // ghostty: "Screen: resize less rows with full scrollback" (Screen.zig:6784)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 3,
        });
        let text = "00000\n1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
        screen.test_write_string(text);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "3IJKL\n4ABCD\n5EFGH"
        );
        assert_eq!((screen.cursor.x, screen.cursor.y), (4, 2));

        screen.resize(resize(5, 2)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (4, 1));
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "4ABCD\n5EFGH");
    }

    #[test]
    fn resize_less_cols_eliminates_wide_char_without_room() {
        // ghostty: "Screen: resize less cols to eliminate wide char" (Screen.zig:7178)
        let mut screen = Screen::new(Options {
            cols: 2,
            rows: 1,
            max_scrollback: 0,
        });
        screen.test_write_string("😀");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "😀");
        assert_eq!(active_cell(&screen, 0, 0).wide(), CellWide::Wide);

        screen.resize(resize(1, 1)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "");
        assert_eq!(active_cell(&screen, 0, 0).codepoint(), 0);
        assert_eq!(active_cell(&screen, 0, 0).wide(), CellWide::Narrow);
    }

    #[test]
    fn resize_no_reflow_less_rows_trims_blank_lines() {
        // ghostty: "Screen: resize (no reflow) less rows trims blank lines" (Screen.zig:5821)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD");
        for y in 1..screen.pages.rows {
            assert!(screen.pages.set_cell(
                Point::active(0, u32::from(y)),
                Cell::bg_rgb(crate::color::Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }),
            ));
        }
        let cursor = screen.cursor_copy();

        screen.resize(resize_no_reflow(6, 2)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (cursor.x, cursor.y));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "1ABCD");
    }

    #[test]
    fn resize_no_reflow_more_rows_trims_blank_lines() {
        // ghostty: "Screen: resize (no reflow) more rows trims blank lines" (Screen.zig:5856)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD");
        for y in 1..screen.pages.rows {
            assert!(screen.pages.set_cell(
                Point::active(0, u32::from(y)),
                Cell::bg_rgb(crate::color::Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }),
            ));
        }
        let cursor = screen.cursor_copy();

        screen.resize(resize_no_reflow(10, 7)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (cursor.x, cursor.y));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "1ABCD");
    }

    #[test]
    fn resize_no_reflow_more_cols_keeps_contents() {
        // ghostty: "Screen: resize (no reflow) more cols" (Screen.zig:5891)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "1ABCD\n2EFGH\n3IJKL";
        screen.test_write_string(text);

        screen.resize(resize_no_reflow(20, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
    }

    #[test]
    fn resize_no_reflow_more_rows_with_scrollback_cursor_end() {
        // ghostty: "Screen: resize (no reflow) more rows with scrollback cursor end" (Screen.zig:5926)
        let mut screen = Screen::new(Options {
            cols: 7,
            rows: 3,
            max_scrollback: 2,
        });
        let text = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
        screen.test_write_string(text);

        screen.resize(resize_no_reflow(7, 10)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
    }

    #[test]
    fn resize_no_reflow_less_rows_with_empty_trailing() {
        // ghostty: "Screen: resize (no reflow) less rows with empty trailing" (Screen.zig:5962)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("1\n2\n3\n4\n5\n6\n7\n8");
        screen.scroll_clear();
        screen.cursor_absolute(0, 0);
        screen.test_write_string("A\nB");
        let cursor = screen.cursor_copy();

        screen.resize(resize_no_reflow(5, 2)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (cursor.x, cursor.y));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "A\nB");
    }

    #[test]
    fn resize_more_rows_with_empty_scrollback_keeps_contents() {
        // ghostty: "Screen: resize more rows with empty scrollback" (Screen.zig:6054)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 10,
        });
        let text = "1ABCD\n2EFGH\n3IJKL";
        screen.test_write_string(text);
        let cursor = screen.cursor_copy();

        screen.resize(resize(5, 10)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (cursor.x, cursor.y));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
    }

    #[test]
    fn resize_more_cols_no_reflow_name_keeps_contents() {
        // ghostty: "Screen: resize more cols no reflow" (Screen.zig:6126)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "1ABCD\n2EFGH\n3IJKL";
        screen.test_write_string(text);
        let cursor = screen.cursor_copy();

        screen.resize(resize(10, 3)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (cursor.x, cursor.y));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
    }

    #[test]
    fn resize_more_cols_with_scrollback_scrolled_up_keeps_cursor_bottom() {
        // ghostty: "Screen: resize (no reflow) more cols with scrollback scrolled up" (Screen.zig:6173)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 5,
        });
        let text = "1\n2\n3\n4\n5\n6\n7\n8";
        screen.test_write_string(text);
        assert_eq!((screen.cursor.x, screen.cursor.y), (1, 2));
        screen.scroll(Scroll::DeltaRow(-4));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2\n3\n4");

        screen.resize(resize(8, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!((screen.cursor.x, screen.cursor.y), (1, 2));
    }

    #[test]
    fn resize_less_cols_with_scrollback_scrolled_up_keeps_active_bottom() {
        // ghostty: "Screen: resize (no reflow) less cols with scrollback scrolled up" (Screen.zig:6206)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 5,
        });
        let text = "1\n2\n3\n4\n5\n6\n7\n8";
        screen.test_write_string(text);
        assert_eq!((screen.cursor.x, screen.cursor.y), (1, 2));
        screen.scroll(Scroll::DeltaRow(-4));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2\n3\n4");

        screen.resize(resize(4, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "6\n7\n8");
        assert_eq!((screen.cursor.x, screen.cursor.y), (1, 2));
    }

    #[test]
    fn resize_more_cols_reflow_ending_in_newline_keeps_cursor_cell() {
        // ghostty: "Screen: resize more cols with reflow that ends in newline" (Screen.zig:6334)
        let mut screen = Screen::new(Options {
            cols: 6,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "1ABCD2EFGH\n3IJKL";
        screen.test_write_string(text);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD2\nEFGH\n3IJKL"
        );
        screen.cursor_absolute(0, 2);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '3' as u32
        );

        screen.resize(resize(10, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '3' as u32
        );
    }

    #[test]
    fn resize_more_cols_reflow_forces_more_wrapping() {
        // ghostty: "Screen: resize more cols with reflow that forces more wrapping" (Screen.zig:6379)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD2EFGH\n3IJKL");
        screen.cursor_absolute(0, 1);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '2' as u32
        );
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );

        screen.resize(resize(7, 3)).unwrap();

        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD2E\nFGH\n3IJKL"
        );
        assert_eq!((screen.cursor.x, screen.cursor.y), (5, 0));
    }

    #[test]
    fn resize_more_cols_reflow_unwraps_multiple_times() {
        // ghostty: "Screen: resize more cols with reflow that unwraps multiple times" (Screen.zig:6420)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD2EFGH3IJKL");
        screen.cursor_absolute(0, 2);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '3' as u32
        );
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );

        screen.resize(resize(15, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "1ABCD2EFGH3IJKL");
        assert_eq!((screen.cursor.x, screen.cursor.y), (10, 0));
    }

    #[test]
    fn resize_more_cols_with_populated_scrollback() {
        // ghostty: "Screen: resize more cols with populated scrollback" (Screen.zig:6461)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD5EFGH");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "3IJKL\n4ABCD\n5EFGH"
        );
        screen.cursor_absolute(0, 2);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '5' as u32
        );

        screen.resize(resize(10, 3)).unwrap();

        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "2EFGH\n3IJKL\n4ABCD5EFGH"
        );
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            '5' as u32
        );
    }

    #[test]
    fn resize_more_cols_bounded_scrollback_keeps_viewport_valid() {
        // ghostty: "Screen: resize more cols bounded scrollback keeps viewport valid" (Screen.zig:6505)
        let mut screen = Screen::new(Options {
            cols: 2,
            rows: 10,
            max_scrollback: 10_000,
        });
        for _ in 0..30 {
            let _ = screen.pages.grow();
        }
        screen.cursor_reload();
        assert_eq!(screen.pages.scrollbar().total, 40);

        let mut chunks = Vec::new();
        let mut iter = screen
            .pages
            .page_iterator(Direction::RightDown, Point::screen(0, 0), None);
        while let Some(chunk) = iter.next(&screen.pages) {
            chunks.push(chunk);
        }
        let cols = screen.pages.cols;
        for chunk in chunks {
            let Some(node) = screen.pages.node_mut(chunk.node) else {
                continue;
            };
            for y in chunk.start..chunk.end {
                let mut row = node.page.row(y);
                row.set_wrap(y % 2 == 0);
                row.set_wrap_continuation(y % 2 == 1);
                node.page.set_row(y, row);
                for x in 0..cols {
                    node.page.set_cell(y, x, Cell::new('A'));
                }
            }
        }

        let viewport_pin = screen.pages.pin(Point::screen(0, 28)).unwrap();
        screen.pages.scroll(Scroll::Pin(viewport_pin));
        assert_eq!(screen.pages.viewport(), crate::page_list::Viewport::Pin);
        assert!(screen.pages.get_bottom_right(Tag::Viewport).is_some());

        screen.resize(resize(4, screen.pages.rows)).unwrap();

        assert_eq!(screen.pages.cols, 4);
        assert!(screen.pages.scrollbar().total < 40);
        assert_eq!(screen.pages.viewport(), crate::page_list::Viewport::Active);
        assert!(screen.pages.get_bottom_right(Tag::Viewport).is_some());
    }

    #[test]
    fn resize_more_cols_with_reflow_and_scrollback() {
        // ghostty: "Screen: resize more cols with reflow" (Screen.zig:6585)
        let mut screen = Screen::new(Options {
            cols: 2,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("1ABC\n2DEF\n3ABC\n4DEF");
        screen.cursor_absolute(0, 2);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            'E' as u32
        );
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "BC\n4D\nEF");

        screen.resize(resize(7, 3)).unwrap();

        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "1ABC\n2DEF\n3ABC\n4DEF"
        );
        assert_eq!((screen.cursor.x, screen.cursor.y), (2, 2));
    }

    #[test]
    fn resize_more_rows_and_cols_with_wrapping() {
        // ghostty: "Screen: resize more rows and cols with wrapping" (Screen.zig:6626)
        let mut screen = Screen::new(Options {
            cols: 2,
            rows: 4,
            max_scrollback: 0,
        });
        let text = "1A2B\n3C4D";
        screen.test_write_string(text);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "1A\n2B\n3C\n4D");

        screen.resize(resize(5, 10)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (3, 1));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
    }

    #[test]
    fn resize_less_rows_no_scrollback_keeps_cursor_position_but_trims_view() {
        // ghostty: "Screen: resize less rows no scrollback" (Screen.zig:6659)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.cursor_absolute(0, 0);
        let cursor = screen.cursor_copy();

        screen.resize(resize(5, 1)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (cursor.x, cursor.y));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "3IJKL");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "3IJKL");
    }

    #[test]
    fn resize_less_rows_moves_cursor_with_bottom_line() {
        // ghostty: "Screen: resize less rows moving cursor" (Screen.zig:6690)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.cursor_absolute(1, 2);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            'I' as u32
        );

        screen.resize(resize(5, 1)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "3IJKL");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "3IJKL");
        assert_eq!((screen.cursor.x, screen.cursor.y), (1, 0));
    }

    #[test]
    fn resize_less_rows_with_empty_scrollback_keeps_screen_history() {
        // ghostty: "Screen: resize less rows with empty scrollback" (Screen.zig:6730)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 10,
        });
        let text = "1ABCD\n2EFGH\n3IJKL";
        screen.test_write_string(text);

        screen.resize(resize(5, 1)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "3IJKL");
    }

    #[test]
    fn resize_less_rows_with_populated_scrollback_keeps_last_row_in_view() {
        // ghostty: "Screen: resize less rows with populated scrollback" (Screen.zig:6753)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 5,
        });
        let text = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
        screen.test_write_string(text);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "3IJKL\n4ABCD\n5EFGH"
        );

        screen.resize(resize(5, 1)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "5EFGH");
    }

    #[test]
    fn resize_less_cols_no_reflow_name_keeps_contents() {
        // ghostty: "Screen: resize less cols no reflow" (Screen.zig:6824)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "1AB\n2EF\n3IJ";
        screen.test_write_string(text);
        screen.cursor_absolute(0, 0);
        let cursor = screen.cursor_copy();

        screen.resize(resize(3, 3)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (cursor.x, cursor.y));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
    }

    #[test]
    fn resize_less_cols_with_reflow_but_row_space() {
        // ghostty: "Screen: resize less cols with reflow but row space" (Screen.zig:6853)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD");
        screen.cursor_absolute(4, 0);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            'D' as u32
        );

        screen.resize(resize(3, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "1AB\nCD");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "1AB\nCD");
        assert_eq!((screen.cursor.x, screen.cursor.y), (1, 1));
    }

    #[test]
    fn resize_less_cols_with_reflow_trims_rows() {
        // ghostty: "Screen: resize less cols with reflow with trimmed rows" (Screen.zig:6891)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("3IJKL\n4ABCD\n5EFGH");

        screen.resize(resize(3, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "CD\n5EF\nGH");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "CD\n5EF\nGH");
    }

    #[test]
    fn resize_less_cols_with_reflow_trims_rows_and_keeps_scrollback() {
        // ghostty: "Screen: resize less cols with reflow with trimmed rows and scrollback" (Screen.zig:6915)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("3IJKL\n4ABCD\n5EFGH");

        screen.resize(resize(3, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "CD\n5EF\nGH");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "3IJ\nKL\n4AB\nCD\n5EF\nGH"
        );
    }

    #[test]
    fn resize_less_cols_with_reflow_previously_wrapped() {
        // ghostty: "Screen: resize less cols with reflow previously wrapped" (Screen.zig:6939)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("3IJKL4ABCD5EFGH");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "3IJKL\n4ABCD\n5EFGH"
        );

        screen.resize(resize(3, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "ABC\nD5E\nFGH");
    }

    #[test]
    fn resize_less_cols_with_reflow_and_scrollback_keeps_cursor_on_end() {
        // ghostty: "Screen: resize less cols with reflow and scrollback" (Screen.zig:6972)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("1A\n2B\n3C\n4D\n5E");
        screen.cursor_absolute(1, screen.pages.rows - 1);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            'E' as u32
        );

        screen.resize(resize(3, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "3C\n4D\n5E");
        assert_eq!((screen.cursor.x, screen.cursor.y), (1, 2));
    }

    #[test]
    fn resize_less_cols_with_reflow_previously_wrapped_and_scrollback() {
        // ghostty: "Screen: resize less cols with reflow previously wrapped and scrollback" (Screen.zig:7005)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 2,
        });
        screen.test_write_string("1ABCD2EFGH3IJKL4ABCD5EFGH");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "3IJKL\n4ABCD\n5EFGH"
        );
        screen.cursor_absolute(screen.pages.cols - 1, screen.pages.rows - 1);
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            'H' as u32
        );

        screen.resize(resize(3, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "CD5\nEFG\nH");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "1AB\nCD2\nEFG\nH3I\nJKL\n4AB\nCD5\nEFG\nH"
        );
        assert_eq!((screen.cursor.x, screen.cursor.y), (0, 2));
        assert_eq!(
            active_cell(&screen, screen.cursor.x, screen.cursor.y).codepoint(),
            'H' as u32
        );
    }

    #[test]
    fn resize_less_cols_with_scrollback_keeps_cursor_row_after_clear() {
        // ghostty: "Screen: resize less cols with scrollback keeps cursor row" (Screen.zig:7059)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("1A\n2B\n3C\n4D\n5E");
        screen.scroll_clear();
        screen.cursor_absolute(0, 0);

        screen.resize(resize(3, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "");
        assert_eq!((screen.cursor.x, screen.cursor.y), (0, 0));
    }

    #[test]
    fn resize_more_rows_less_cols_with_reflow_and_scrollback() {
        // ghostty: "Screen: resize more rows, less cols with reflow with scrollback" (Screen.zig:7088)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 3,
        });
        screen.test_write_string("1ABCD\n2EFGH3IJKL\n4MNOP");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "1ABCD\n2EFGH\n3IJKL\n4MNOP"
        );
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "2EFGH\n3IJKL\n4MNOP"
        );

        screen.resize(resize(2, 10)).unwrap();

        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "BC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP"
        );
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "1A\nBC\nD\n2E\nFG\nH3\nIJ\nKL\n4M\nNO\nP"
        );
    }

    #[test]
    fn resize_more_rows_then_shrink_again_is_stable() {
        // ghostty: "Screen: resize more rows then shrink again" (Screen.zig:7129)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 10,
        });
        let text = "1ABC";
        screen.test_write_string(text);

        screen.resize(resize(5, 10)).unwrap();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);

        screen.resize(resize(5, 3)).unwrap();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);

        screen.resize(resize(5, 10)).unwrap();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
    }

    #[test]
    fn resize_less_cols_wraps_wide_char() {
        // ghostty: "Screen: resize less cols to wrap wide char" (Screen.zig:7213)
        let mut screen = Screen::new(Options {
            cols: 3,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "x😀";
        screen.test_write_string(text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!(active_cell(&screen, 1, 0).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 1, 0).codepoint(), '😀' as u32);
        assert_eq!(active_cell(&screen, 2, 0).wide(), CellWide::SpacerTail);

        screen.resize(resize(2, 3)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "x\n😀");
        assert_eq!(active_cell(&screen, 1, 0).wide(), CellWide::SpacerHead);
        assert!(active_row(&screen, 0).wrap());
    }

    #[test]
    fn resize_less_cols_eliminates_wide_char_with_row_space() {
        // ghostty: "Screen: resize less cols to eliminate wide char with row space" (Screen.zig:7252)
        let mut screen = Screen::new(Options {
            cols: 2,
            rows: 2,
            max_scrollback: 0,
        });
        let text = "😀";
        screen.test_write_string(text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!(active_cell(&screen, 0, 0).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 0, 0).codepoint(), '😀' as u32);
        assert_eq!(active_cell(&screen, 1, 0).wide(), CellWide::SpacerTail);

        screen.resize(resize(1, 2)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "");
    }

    #[test]
    fn resize_less_cols_reflows_cursor_after_wrapped_text() {
        // ghostty: "Screen: resize less cols reflows cursor after wrapped text" (Screen.zig:7285)
        let mut screen = Screen::new(Options {
            cols: 50,
            rows: 7,
            max_scrollback: 0,
        });
        for _ in 0..30 {
            screen.test_write_string("a");
        }
        assert_eq!((screen.cursor.x, screen.cursor.y), (30, 0));

        screen.resize(resize(25, 7)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (5, 1));
    }

    #[test]
    fn resize_less_cols_reflows_cursor_after_empty_cells() {
        // ghostty: "Screen: resize less cols reflows cursor after empty cells" (Screen.zig:7302)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("abc");
        screen.cursor_right(6);
        assert_eq!((screen.cursor.x, screen.cursor.y), (9, 0));

        screen.resize(resize(5, 3)).unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (4, 1));
    }

    #[test]
    fn resize_more_cols_rehomes_wide_spacer_head() {
        // ghostty: "Screen: resize more cols with wide spacer head" (Screen.zig:7320)
        let mut screen = Screen::new(Options {
            cols: 3,
            rows: 2,
            max_scrollback: 0,
        });
        let text = "  😀";
        screen.test_write_string(text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "  \n😀");
        assert_eq!(active_cell(&screen, 2, 0).wide(), CellWide::SpacerHead);
        assert_eq!(active_cell(&screen, 0, 1).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 1, 1).wide(), CellWide::SpacerTail);

        screen.resize(resize(4, 2)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!(active_cell(&screen, 2, 0).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 2, 0).codepoint(), '😀' as u32);
        assert_eq!(active_cell(&screen, 3, 0).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn resize_more_cols_rehomes_wide_spacer_head_across_multiple_lines() {
        // ghostty: "Screen: resize more cols with wide spacer head multiple lines" (Screen.zig:7373)
        let mut screen = Screen::new(Options {
            cols: 3,
            rows: 3,
            max_scrollback: 0,
        });
        let text = "xxxyy😀";
        screen.test_write_string(text);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "xxx\nyy\n😀");
        assert_eq!(active_cell(&screen, 2, 1).wide(), CellWide::SpacerHead);
        assert_eq!(active_cell(&screen, 0, 2).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 1, 2).wide(), CellWide::SpacerTail);

        screen.resize(resize(8, 2)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), text);
        assert_eq!(active_cell(&screen, 5, 0).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 5, 0).codepoint(), '😀' as u32);
        assert_eq!(active_cell(&screen, 6, 0).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn resize_more_cols_marks_required_wide_spacer_head() {
        // ghostty: "Screen: resize more cols requiring a wide spacer head" (Screen.zig:7424)
        let mut screen = Screen::new(Options {
            cols: 2,
            rows: 2,
            max_scrollback: 0,
        });
        screen.test_write_string("xx😀");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "xx\n😀");
        assert_eq!(active_cell(&screen, 0, 1).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 1, 1).wide(), CellWide::SpacerTail);

        screen.resize(resize(3, 2)).unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "xx\n😀");
        assert_eq!(active_cell(&screen, 2, 0).wide(), CellWide::SpacerHead);
        assert_eq!(active_cell(&screen, 0, 1).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 0, 1).codepoint(), '😀' as u32);
        assert_eq!(active_cell(&screen, 1, 1).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn resize_rehomes_cursor_hyperlink() {
        // port-added: mirrors Screen.resize hyperlink release/reattach around PageList resize.
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.start_hyperlink(Some(b"id"), b"https://example.com");
        let old_id = screen.cursor.hyperlink_id;
        assert!(old_id != 0);

        screen.resize(resize(10, 3)).unwrap();

        assert!(screen.cursor.hyperlink_id != 0);
        assert_eq!(
            screen
                .cursor
                .hyperlink
                .as_ref()
                .map(|link| link.uri.as_slice()),
            Some(&b"https://example.com"[..])
        );
    }

    #[test]
    fn resize_saved_cursor_missing_before_resize_is_left_unchanged() {
        // port-added: saved cursor state (b), no active pin before resize.
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.saved_cursor = Some(SavedCursor {
            x: 4,
            y: 99,
            pending_wrap: true,
            ..SavedCursor::default()
        });

        screen.resize(resize(10, 3)).unwrap();

        let saved = screen.saved_cursor.as_ref().unwrap();
        assert_eq!((saved.x, saved.y, saved.pending_wrap), (4, 99, true));
    }

    #[test]
    fn resize_saved_cursor_pending_wrap_is_adjusted_after_reflow() {
        // port-added: saved cursor state (c) success path; live pending_wrap remains untouched.
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD2EFGH");
        screen.saved_cursor = Some(SavedCursor {
            x: 4,
            y: 0,
            pending_wrap: true,
            ..SavedCursor::default()
        });
        screen.cursor.pending_wrap = true;

        screen.resize(resize(10, 3)).unwrap();

        let saved = screen.saved_cursor.as_ref().unwrap();
        assert_eq!((saved.x, saved.y, saved.pending_wrap), (5, 0, false));
        assert!(screen.cursor.pending_wrap);
    }

    #[test]
    fn resize_prompt_redraw_true_clears_prompt_block() {
        // ghostty: "Screen: resize more cols with cursor at prompt" (Screen.zig:7475)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("ABCDE\n");
        screen.cursor_set_semantic_content(SemanticContent::Prompt);
        screen.test_write_string("> ");
        screen.cursor_set_semantic_input_clear_eol();
        screen.test_write_string("echo");
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "ABCDE\n> echo");

        screen
            .resize(Resize {
                prompt_redraw: PromptRedraw::True,
                ..resize(20, 3)
            })
            .unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (6, 1));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "ABCDE");
    }

    #[test]
    fn resize_prompt_redraw_last_clears_only_cursor_row() {
        // ghostty: "Screen: resize with prompt_redraw last clears only one line" (Screen.zig:7556)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 4,
            max_scrollback: 5,
        });
        screen.test_write_string("ABCDE\n");
        screen.cursor_set_semantic_content(SemanticContent::Prompt);
        screen.test_write_string("> ");
        screen.cursor_set_semantic_content(SemanticContent::Input);
        screen.test_write_string("hello\nworld");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "ABCDE\n> hello\nworld"
        );

        screen
            .resize(Resize {
                prompt_redraw: PromptRedraw::Last,
                ..resize(20, 4)
            })
            .unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "ABCDE\n> hello");
    }

    #[test]
    fn resize_prompt_redraw_true_does_not_clear_after_prompt_output() {
        // ghostty: "Screen: resize more cols with cursor not at prompt" (Screen.zig:7515)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("ABCDE\n");
        screen.cursor_set_semantic_content(SemanticContent::Prompt);
        screen.test_write_string("> ");
        screen.cursor_set_semantic_input_clear_eol();
        screen.test_write_string("echo\n");
        screen.test_write_string("output");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "ABCDE\n> echo\noutput"
        );

        screen
            .resize(Resize {
                prompt_redraw: PromptRedraw::True,
                ..resize(20, 3)
            })
            .unwrap();

        assert_eq!((screen.cursor.x, screen.cursor.y), (6, 2));
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "ABCDE\n> echo\noutput"
        );
    }

    #[test]
    fn resize_prompt_redraw_last_multiline_prompt_clears_only_last_line() {
        // ghostty: "Screen: resize with prompt_redraw last multiline prompt clears only last line" (Screen.zig:7595)
        let mut screen = Screen::new(Options {
            cols: 20,
            rows: 5,
            max_scrollback: 5,
        });
        screen.cursor_set_semantic_content(SemanticContent::Prompt);
        screen.test_write_string("line1\n");
        screen.cursor_set_semantic_content(SemanticContent::Prompt);
        screen.test_write_string("line2\n");
        screen.cursor_set_semantic_content(SemanticContent::Prompt);
        screen.test_write_string("line3");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "line1\nline2\nline3"
        );

        screen
            .resize(Resize {
                prompt_redraw: PromptRedraw::Last,
                ..resize(30, 5)
            })
            .unwrap();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "line1\nline2");
    }

    #[test]
    fn screen_cursor_horizontal_movement_clamps_to_bounds() {
        // port-added: clamp behavior is part of the Rust Screen cursor contract.
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 2,
            max_scrollback: 0,
        });
        screen.cursor_horizontal_absolute(99);
        assert_eq!(screen.cursor.x, 4);
        screen.cursor_left(99);
        assert_eq!(screen.cursor.x, 0);
        screen.cursor_right(99);
        assert_eq!(screen.cursor.x, 4);
    }

    #[test]
    fn screen_writes_with_scrollback() {
        // ghostty: "Screen read and write scrollback" (Screen.zig:3393)
        let mut screen = Screen::new(Options {
            cols: 80,
            rows: 2,
            max_scrollback: 1000,
        });
        screen.test_write_string("hello\nworld\ntest");
        assert_eq!(screen.cursor.y, 1);
        assert!(screen.pages.total_rows() > 2);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "hello\nworld\ntest"
        );
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "world\ntest");
    }

    #[test]
    fn screen_writes_no_scrollback_single_row() {
        // ghostty: "Screen read and write no scrollback small" (Screen.zig:3413)
        let mut screen = Screen::new(Options {
            cols: 80,
            rows: 2,
            max_scrollback: 0,
        });
        screen.test_write_string("hello\nworld\ntest");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "world\ntest");
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "world\ntest");
    }

    #[test]
    fn screen_writes_no_scrollback_large() {
        // ghostty: "Screen read and write no scrollback large" (Screen.zig:3433)
        let mut screen = Screen::new(Options {
            cols: 80,
            rows: 2,
            max_scrollback: 0,
        });
        for index in 0..1_000 {
            screen.test_write_string(&format!("{index}\n"));
        }
        screen.test_write_string("1000");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "999\n1000");
    }

    #[test]
    fn screen_wraps_and_scrolls_without_scrollback() {
        // port-added: no-scrollback cursorDownScroll keeps the active viewport bounded.
        let mut screen = Screen::new(Options {
            cols: 4,
            rows: 2,
            max_scrollback: 0,
        });
        screen.test_write_string("abcd\nefgh\nijkl");
        assert_eq!(screen.cursor.y, 1);
        assert_eq!(screen.dump_string(), "efgh\nijkl");
    }

    #[test]
    fn screen_cursor_copy_copies_position() {
        // ghostty: "Screen cursorCopy x/y" (Screen.zig:3454)
        let mut source = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        let mut target = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        source.cursor_absolute(2, 3);
        target.cursor_copy_from(&source.cursor, true);
        target.test_write_string("Hello");
        assert_eq!(target.dump_string_for_tag(Tag::Screen), "\n\n\n  Hello");
    }

    #[test]
    fn screen_cursor_copy_releases_target_style_when_source_is_default() {
        // ghostty: "Screen cursorCopy style deref" (Screen.zig:3478)
        let source = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        let mut target = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        target.set_attribute(Attribute::Bold);
        assert_eq!(cursor_page_style_count(&target), 1);
        target.cursor_copy_from(&source.cursor, true);
        assert!(!target.cursor.style.flags.bold);
        assert_eq!(cursor_page_style_count(&target), 0);
    }

    #[test]
    fn screen_cursor_copy_releases_target_style_on_previous_page() {
        // ghostty: "Screen cursorCopy style deref new page" (Screen.zig:3500)
        let source = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        let mut target = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: PageList::standard_size() * 4,
        });
        let styled_node = force_cursor_to_next_page(&mut target);
        target.set_attribute(Attribute::Bold);
        assert_eq!(
            target.pages.node(styled_node).unwrap().page.style_count(),
            1
        );

        target.cursor_copy_from(&source.cursor, true);

        assert!(!target.cursor.style.flags.bold);
        assert_eq!(
            target.pages.node(styled_node).unwrap().page.style_count(),
            0
        );
        assert_eq!((target.cursor.x, target.cursor.y), (0, 0));
    }

    #[test]
    fn screen_cursor_copy_copies_style_value() {
        // ghostty: "Screen cursorCopy style copy" (Screen.zig:3573)
        let mut source = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        let mut target = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        source.set_attribute(Attribute::Bold);
        target.cursor_copy_from(&source.cursor, true);
        assert!(target.cursor.style.flags.bold);
        assert_eq!(cursor_page_style_count(&target), 1);
    }

    #[test]
    fn screen_cursor_copy_releases_target_hyperlink_when_source_has_none() {
        // ghostty: "Screen cursorCopy hyperlink deref" (Screen.zig:3589)
        let source = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        let mut target = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        target.start_hyperlink(None, b"https://example.com/");
        assert_ne!(target.cursor.hyperlink_id, 0);
        assert_eq!(cursor_page_hyperlink_count(&target), 0);
        target.cursor_copy_from(&source.cursor, true);
        assert_eq!(target.cursor.hyperlink_id, 0);
        assert!(target.cursor.hyperlink.is_none());
    }

    #[test]
    fn screen_cursor_copy_releases_target_hyperlink_on_previous_page() {
        // ghostty: "Screen cursorCopy hyperlink deref new page" (Screen.zig:3611)
        let source = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        let mut target = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: PageList::standard_size() * 4,
        });
        let linked_node = force_cursor_to_next_page(&mut target);
        target.start_hyperlink(None, b"https://example.com/");
        assert_ne!(target.cursor.hyperlink_id, 0);
        assert_eq!(cursor_node(&target), linked_node);

        target.cursor_copy_from(&source.cursor, true);

        assert_eq!(target.cursor.hyperlink_id, 0);
        assert!(target.cursor.hyperlink.is_none());
        assert_eq!((target.cursor.x, target.cursor.y), (0, 0));
    }

    #[test]
    fn screen_cursor_copy_copies_hyperlink_value() {
        // ghostty: "Screen cursorCopy hyperlink copy" (Screen.zig:3684)
        let mut source = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        let mut target = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        source.start_hyperlink(None, b"https://example.com/");
        target.cursor_copy_from(&source.cursor, true);
        assert_ne!(target.cursor.hyperlink_id, 0);
        assert_eq!(cursor_page_hyperlink_count(&target), 1);
    }

    #[test]
    fn screen_cursor_copy_can_skip_hyperlink_value() {
        // ghostty: "Screen cursorCopy hyperlink copy disabled" (Screen.zig:3709)
        let mut source = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        let mut target = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        source.start_hyperlink(None, b"https://example.com/");
        target.cursor_copy_from(&source.cursor, false);
        assert_eq!(target.cursor.hyperlink_id, 0);
        assert!(target.cursor.hyperlink.is_none());
    }

    #[test]
    fn screen_applies_bold_style_to_written_cells() {
        // port-added: basic SGR attribute application for the Rust cursor style.
        let mut screen = Screen::new(Options::default());
        screen.set_attribute(Attribute::Bold);
        screen.test_write_string("x");
        let cell = active_cell(&screen, 0, 0);
        assert_ne!(cell.style_id(), DEFAULT_STYLE_ID);
        assert_eq!(
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
            screen.cursor.style
        );
    }

    #[test]
    fn screen_style_basics_keep_single_cursor_style_ref() {
        // ghostty: "Screen style basics" (Screen.zig:3734)
        let mut screen = Screen::new(Options {
            max_scrollback: 1000,
            ..Options::default()
        });
        assert_eq!(cursor_page_style_count(&screen), 0);
        screen.set_attribute(Attribute::Bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(cursor_page_style_count(&screen), 1);
        assert!(screen.cursor.style.flags.bold);
        screen.set_attribute(Attribute::Italic);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(cursor_page_style_count(&screen), 1);
        assert!(screen.cursor.style.flags.bold);
        assert!(screen.cursor.style.flags.italic);
    }

    #[test]
    fn screen_style_reset_returns_to_default() {
        // ghostty: "Screen style reset to default" (Screen.zig:3756)
        let mut screen = Screen::new(Options::default());
        screen.set_attribute(Attribute::Bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        screen.set_attribute(Attribute::Unset);
        assert_eq!(screen.cursor.style, Style::default());
        assert_eq!(screen.cursor.style_id, DEFAULT_STYLE_ID);
    }

    #[test]
    fn screen_style_reset_with_unset_returns_to_default() {
        // ghostty: "Screen style reset with unset" (Screen.zig:3776)
        let mut screen = Screen::new(Options {
            max_scrollback: 1000,
            ..Options::default()
        });
        screen.set_attribute(Attribute::Bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(cursor_page_style_count(&screen), 1);
        screen.set_attribute(Attribute::Unset);
        assert_eq!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(cursor_page_style_count(&screen), 0);
    }

    #[test]
    fn screen_clear_rows_active_one_line() {
        // ghostty: "Screen clearRows active one line" (Screen.zig:3796)
        let mut screen = Screen::new(Options {
            max_scrollback: 1000,
            ..Options::default()
        });
        screen.test_write_string("hello, world");
        clear_all_dirty(&mut screen);
        screen.clear_rows(Point::active(0, 0), None, false);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "");
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 0)));
    }

    #[test]
    fn screen_clear_rows_active_multi_line() {
        // ghostty: "Screen clearRows active multi line" (Screen.zig:3811)
        let mut screen = Screen::new(Options {
            max_scrollback: 1000,
            ..Options::default()
        });
        screen.test_write_string("hello\nworld");
        clear_all_dirty(&mut screen);
        screen.clear_rows(Point::active(0, 0), None, false);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "");
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 0)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 1)));
    }

    #[test]
    fn screen_clear_rows_active_styled_line_releases_cell_styles() {
        // ghostty: "Screen clearRows active styled line" (Screen.zig:3827)
        let mut screen = Screen::new(Options {
            max_scrollback: 1000,
            ..Options::default()
        });
        screen.set_attribute(Attribute::Bold);
        screen.test_write_string("hello world");
        screen.set_attribute(Attribute::Unset);
        assert_eq!(cursor_page_style_count(&screen), 1);
        screen.clear_rows(Point::active(0, 0), None, false);
        assert_eq!(cursor_page_style_count(&screen), 0);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "");
    }

    #[test]
    fn screen_clear_rows_preserves_protected_cells() {
        // ghostty: "Screen clearRows protected" (Screen.zig:3852)
        let mut screen = Screen::new(Options {
            max_scrollback: 1000,
            ..Options::default()
        });
        screen.test_write_string("UNPROTECTED");
        screen.cursor.protected = true;
        screen.test_write_string("PROTECTED");
        screen.cursor.protected = false;
        screen.test_write_string("UNPROTECTED\n");
        screen.cursor.protected = true;
        screen.test_write_string("PROTECTED");
        screen.cursor.protected = false;
        screen.test_write_string("UNPROTECTED");
        screen.cursor.protected = true;
        screen.test_write_string("PROTECTED");
        screen.cursor.protected = false;
        screen.clear_rows(Point::active(0, 0), None, true);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "           PROTECTED\nPROTECTED           PROTECTED"
        );
    }

    #[test]
    fn screen_clear_unprotected_cells_preserves_protected_cells() {
        // port-added: clear_unprotected_cells honors protected cell flags.
        let mut screen = Screen::new(Options::default());
        screen.cursor.protected = true;
        screen.test_write_string("a");
        screen.cursor.protected = false;
        screen.test_write_string("b");
        screen.clear_unprotected_cells(Point::active(0, 0), Point::active(1, 0));
        assert_eq!(screen.dump_string(), "a");
    }

    #[test]
    fn screen_erase_history_keeps_active_text() {
        // ghostty: "Screen eraseRows history" (Screen.zig:3880)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 5,
            max_scrollback: 1000,
        });
        screen.test_write_string("1\n2\n3\n4\n5\n6");
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "2\n3\n4\n5\n6");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "1\n2\n3\n4\n5\n6");
        screen.erase_history(None);
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "2\n3\n4\n5\n6");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "2\n3\n4\n5\n6");
    }

    #[test]
    fn screen_erase_history_removes_more_than_one_history_page() {
        // ghostty: "Screen eraseRows history with more lines" (Screen.zig:3914)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 5,
            max_scrollback: 1000,
        });
        screen.test_write_string("A\nB\nC\n1\n2\n3\n4\n5\n6");
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "2\n3\n4\n5\n6");
        screen.erase_history(None);
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "2\n3\n4\n5\n6");
    }

    #[test]
    fn screen_erase_active_partial_shifts_rows() {
        // ghostty: "Screen eraseRows active partial" (Screen.zig:3948)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 5,
            max_scrollback: 0,
        });
        screen.test_write_string("1\n2\n3");
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "1\n2\n3");
        screen.erase_active(1);
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "3");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "3");
    }

    #[test]
    fn screen_cursor_down_preserves_style() {
        // ghostty: "Screen: cursorDown across pages preserves style" (Screen.zig:3977)
        let mut screen = Screen::new(Options {
            cols: 4,
            rows: 2,
            max_scrollback: PageList::standard_size(),
        });
        screen.set_attribute(Attribute::Bold);
        screen.cursor_down_scroll();
        screen.test_write_string("x");
        assert_ne!(active_cell(&screen, 0, 1).style_id(), DEFAULT_STYLE_ID);
        assert!(screen.cursor.style.flags.bold);
    }

    #[test]
    fn screen_cursor_up_across_pages_preserves_style() {
        // ghostty: "Screen: cursorUp across pages preserves style" (Screen.zig:4029)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: PageList::standard_size() * 4,
        });
        let page = force_cursor_to_next_page(&mut screen);
        let row = active_row_whose_previous_is_on_different_node(&screen);
        screen.cursor_absolute(0, row);
        assert_eq!(cursor_node(&screen), page);
        screen.set_attribute(Attribute::Bold);

        screen.cursor_up(1);

        assert_ne!(cursor_node(&screen), page);
        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
    }

    #[test]
    fn screen_cursor_absolute_across_pages_preserves_style() {
        // ghostty: "Screen: cursorAbsolute across pages preserves style" (Screen.zig:4076)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: PageList::standard_size() * 4,
        });
        let page = force_cursor_to_next_page(&mut screen);
        screen.set_attribute(Attribute::Bold);
        let row = active_row_on_different_node(&screen, page);

        screen.cursor_absolute(1, row);

        assert_ne!(cursor_node(&screen), page);
        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
    }

    #[test]
    fn screen_cursor_down_to_page_with_insufficient_capacity_preserves_style() {
        // ghostty: "Screen: cursorDown to page with insufficient capacity" (Screen.zig:9761)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: PageList::standard_size() * 4,
        });
        let full_page = force_cursor_to_next_page(&mut screen);
        fill_cursor_page_styles(&mut screen);
        assert_eq!(cursor_node(&screen), full_page);
        let row = active_row_on_different_node(&screen, full_page);
        screen.cursor_absolute(0, row);
        screen.set_attribute(Attribute::Bold);
        let boundary_row = active_row_whose_previous_is_on_different_node(&screen);
        screen.cursor_absolute(0, boundary_row - 1);

        screen.cursor_down(1);

        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(screen.cursor.y, boundary_row);
    }

    #[test]
    fn screen_cursor_absolute_to_page_with_insufficient_capacity_preserves_style() {
        // ghostty: "Screen: cursorAbsolute to page with insufficient capacity" (Screen.zig:4123)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: PageList::standard_size() * 4,
        });
        let start_page = cursor_node(&screen);
        let new_page = force_cursor_to_next_page(&mut screen);
        fill_page_styles(&mut screen, start_page);
        screen.set_attribute(Attribute::Bold);
        let row = active_row_on_different_node(&screen, new_page);

        screen.cursor_absolute(1, row);

        assert_ne!(cursor_node(&screen), new_page);
        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
    }

    #[test]
    fn screen_scroll_delegates_to_page_list() {
        // ghostty: "Screen: scrolling" (Screen.zig:4198)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.set_attribute(Attribute::DirectColorBg(crate::color::Rgb {
            r: 155,
            g: 0,
            b: 0,
        }));
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        clear_all_dirty(&mut screen);
        screen.cursor_down_scroll();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 2)));
        assert_eq!(
            active_cell(&screen, 0, 2),
            Cell::bg_rgb(crate::color::Rgb { r: 155, g: 0, b: 0 })
        );
        screen.scroll(Scroll::Active);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");
    }

    #[test]
    fn screen_scroll_single_row_no_scrollback_clears_viewport() {
        // ghostty: "Screen: scrolling with a single-row screen no scrollback" (Screen.zig:4240)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 1,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD");
        clear_all_dirty(&mut screen);
        screen.cursor_down_scroll();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "");
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 0)));
    }

    #[test]
    fn screen_scroll_single_row_with_scrollback_reveals_history() {
        // ghostty: "Screen: scrolling with a single-row screen with scrollback" (Screen.zig:4260)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 1,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD");
        clear_all_dirty(&mut screen);
        screen.cursor_down_scroll();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "");
        screen.scroll(Scroll::DeltaRow(-1));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "1ABCD");
    }

    #[test]
    fn screen_scrolling_across_pages_preserves_style() {
        // ghostty: "Screen: scrolling across pages preserves style" (Screen.zig:4290)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: PageList::standard_size() * 4,
        });
        let start = cursor_node(&screen);
        screen.set_attribute(Attribute::Bold);
        let rows = screen.pages.node(start).unwrap().page.capacity().rows;
        for _ in 0..rows {
            screen.cursor_down_or_scroll();
        }

        assert_ne!(cursor_node(&screen), start);
        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
    }

    #[test]
    fn screen_scroll_down_from_zero_no_scrollback_is_noop() {
        // ghostty: "Screen: scroll down from 0" (Screen.zig:4319)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.scroll(Scroll::DeltaRow(-1));
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );
    }

    #[test]
    fn screen_scrollback_various_cases() {
        // ghostty: "Screen: scrollback various cases" (Screen.zig:4338)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.cursor_down_scroll();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");
        screen.scroll(Scroll::Active);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");
        screen.scroll(Scroll::DeltaRow(-1));
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );
        screen.scroll(Scroll::DeltaRow(-1));
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );
        screen.scroll(Scroll::Active);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");
        screen.scroll(Scroll::DeltaRow(1));
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");
        screen.scroll(Scroll::Top);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );
        screen.clear_rows(Point::active(0, 0), None, false);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "1ABCD");
        screen.scroll(Scroll::Active);
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "");
    }

    #[test]
    fn screen_scrollback_multi_row_delta_reaches_active() {
        // ghostty: "Screen: scrollback with multi-row delta" (Screen.zig:4419)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 3,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
        screen.scroll(Scroll::Top);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );
        screen.scroll(Scroll::DeltaRow(5));
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "4ABCD\n5EFGH\n6IJKL"
        );
    }

    #[test]
    fn screen_scrollback_empty_forward_is_noop() {
        // ghostty: "Screen: scrollback empty" (Screen.zig:4445)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 50,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.scroll(Scroll::DeltaRow(1));
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );
    }

    #[test]
    fn screen_scrollback_does_not_move_viewport_when_not_at_bottom() {
        // ghostty: "Screen: scrollback doesn't move viewport if not at bottom" (Screen.zig:4460)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 3,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH");
        screen.scroll(Scroll::DeltaRow(-1));
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "2EFGH\n3IJKL\n4ABCD"
        );

        screen.cursor_down_scroll();
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "2EFGH\n3IJKL\n4ABCD"
        );
        screen.cursor_down_scroll();
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "2EFGH\n3IJKL\n4ABCD"
        );
    }

    #[test]
    fn screen_scrolling_moves_viewport_pin() {
        // ghostty: "Screen: scrolling moves viewport" (Screen.zig:4574)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n");
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.scroll(Scroll::DeltaRow(-2));
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "2EFGH\n3IJKL\n1ABCD"
        );
        assert_eq!(
            screen
                .pages
                .point_from_pin(Tag::Screen, screen.pages.get_top_left(Tag::Viewport))
                .unwrap()
                .coord()
                .y,
            1
        );
    }

    #[test]
    fn screen_scrolling_when_viewport_is_pruned_returns_to_screen_top() {
        // ghostty: "Screen: scrolling when viewport is pruned" (Screen.zig:4599)
        let mut screen = Screen::new(Options {
            cols: 215,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n");
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.scroll(Scroll::DeltaRow(-2));
        screen.test_write_string("\n");
        for _ in 0..1000 {
            screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n");
        }
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        assert_eq!(
            screen
                .pages
                .point_from_pin(Tag::Screen, screen.pages.get_top_left(Tag::Viewport))
                .unwrap()
                .coord()
                .y,
            0
        );
    }

    #[test]
    fn screen_scroll_above_same_page_inserts_blank_at_cursor() {
        // ghostty: "Screen: scroll above same page" (Screen.zig:4741)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 10,
        });
        screen.set_attribute(Attribute::DirectColorBg(crate::color::Rgb {
            r: 155,
            g: 0,
            b: 0,
        }));
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.cursor_absolute(0, 1);
        clear_all_dirty(&mut screen);

        screen.cursor_scroll_above();

        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "1ABCD\n2EFGH\n\n3IJKL"
        );
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "2EFGH\n\n3IJKL");
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n\n3IJKL");
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 0)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 1)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 2)));
        assert_eq!(
            active_cell(&screen, 0, 1),
            Cell::bg_rgb(crate::color::Rgb { r: 155, g: 0, b: 0 })
        );
    }

    #[test]
    fn screen_scroll_above_cursor_on_previous_page() {
        // ghostty: "Screen: scroll above same page but cursor on previous page" (Screen.zig:4800)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 5,
            max_scrollback: PageList::standard_size() * 4,
        });
        force_cursor_to_next_page(&mut screen);
        screen.set_attribute(Attribute::DirectColorBg(crate::color::Rgb {
            r: 155,
            g: 0,
            b: 0,
        }));
        screen.test_write_string("1A\n2B\n3C\n4D\n5E");
        screen.cursor_absolute(0, 1);
        clear_all_dirty(&mut screen);

        screen.cursor_scroll_above();

        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "2B\n\n3C\n4D\n5E"
        );
        for y in 0..screen.rows() {
            assert!(screen.pages.pin_is_dirty(active_pin(&screen, y)));
        }
        assert_eq!(
            active_cell(&screen, 0, 1),
            Cell::bg_rgb(crate::color::Rgb { r: 155, g: 0, b: 0 })
        );
    }

    #[test]
    fn screen_scroll_above_cursor_on_previous_page_last_row() {
        // ghostty: "Screen: scroll above same page but cursor on previous page last row" (Screen.zig:4881)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 5,
            max_scrollback: PageList::standard_size() * 4,
        });
        force_cursor_to_next_page(&mut screen);
        screen.set_attribute(Attribute::DirectColorBg(crate::color::Rgb {
            r: 155,
            g: 0,
            b: 0,
        }));
        screen.test_write_string("1A\n2B\n3C\n4D\n5E");
        screen.cursor_absolute(0, 1);
        clear_all_dirty(&mut screen);

        screen.cursor_scroll_above();
        screen.set_attribute(Attribute::ResetBg);

        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "2B\n\n3C\n4D\n5E"
        );
        for y in 0..screen.rows() {
            assert!(screen.pages.pin_is_dirty(active_pin(&screen, y)));
        }
        screen.assert_integrity();
    }

    #[test]
    fn screen_scroll_above_creates_new_page_shape() {
        // ghostty: "Screen: scroll above creates new page" (Screen.zig:4971)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: PageList::standard_size() * 4,
        });
        force_cursor_to_next_page(&mut screen);
        screen.set_attribute(Attribute::DirectColorBg(crate::color::Rgb {
            r: 155,
            g: 0,
            b: 0,
        }));
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.cursor_absolute(0, 1);
        clear_all_dirty(&mut screen);

        screen.cursor_scroll_above();

        assert!(screen
            .dump_string_for_tag(Tag::Screen)
            .ends_with("1ABCD\n2EFGH\n\n3IJKL"));
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "2EFGH\n\n3IJKL");
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n\n3IJKL");
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 0)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 1)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 2)));
    }

    #[test]
    fn screen_scroll_above_with_cursor_on_non_final_row() {
        // ghostty: "Screen: scroll above with cursor on non-final row" (Screen.zig:5043)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 4,
            max_scrollback: PageList::standard_size() * 4,
        });
        force_cursor_to_next_page(&mut screen);
        screen.set_attribute(Attribute::DirectColorBg(crate::color::Rgb {
            r: 155,
            g: 0,
            b: 0,
        }));
        screen.test_write_string("1AB\n2BC\n3DE\n4FG");
        screen.cursor_absolute(0, 1);
        clear_all_dirty(&mut screen);

        screen.cursor_scroll_above();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2BC\n\n3DE\n4FG");
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 0)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 1)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 2)));
    }

    #[test]
    fn screen_scroll_above_no_scrollback_bottom_of_page() {
        // ghostty: "Screen: scroll above no scrollback bottom of page" (Screen.zig:5120)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        screen.cursor_absolute(0, 1);
        clear_all_dirty(&mut screen);

        screen.cursor_scroll_above();

        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n\n3IJKL");
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 0)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 1)));
        assert!(screen.pages.pin_is_dirty(active_pin(&screen, 2)));
    }

    #[test]
    fn screen_scroll_clear_grows_for_non_empty_rows() {
        // ghostty: "Screen: scroll and clear full screen" (Screen.zig:4625)
        let mut screen = Screen::new(Options {
            cols: 4,
            rows: 2,
            max_scrollback: PageList::standard_size(),
        });
        screen.test_write_string("abcd\nefgh");
        screen.scroll_clear();
        assert_eq!(screen.dump_string(), "abcd\nefgh");
        assert!(screen.pages.total_rows() >= 4);
    }

    #[test]
    fn screen_scroll_clear_partial_screen_preserves_history() {
        // ghostty: "Screen: scroll and clear partial screen" (Screen.zig:4652)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 5,
        });
        screen.test_write_string("1ABCD\n2EFGH");
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "1ABCD\n2EFGH");
        screen.scroll_clear();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "1ABCD\n2EFGH");
    }

    #[test]
    fn screen_scroll_clear_empty_screen_is_noop() {
        // ghostty: "Screen: scroll and clear empty screen" (Screen.zig:4679)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 5,
        });
        screen.scroll_clear();
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "");
        assert_eq!(screen.dump_string_for_tag(Tag::Screen), "");
    }

    #[test]
    fn screen_scroll_clear_ignores_blank_lines() {
        // ghostty: "Screen: scroll and clear ignore blank lines" (Screen.zig:4698)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 10,
        });
        screen.test_write_string("1ABCD\n2EFGH");
        screen.scroll_clear();
        screen.cursor_absolute(0, 0);
        screen.test_write_string("3ABCD\n");
        assert_eq!(screen.dump_string_for_tag(Tag::Active), "3ABCD");
        screen.scroll_clear();
        screen.cursor_absolute(0, 0);
        screen.test_write_string("X");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "1ABCD\n2EFGH\n3ABCD\nX"
        );
    }

    #[test]
    fn screen_clone_copies_visible_contents() {
        // ghostty: "Screen: clone" (Screen.zig:5185)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 10,
        });
        screen.test_write_string("1ABCD\n2EFGH");
        let cloned = screen.clone_region(Point::active(0, 0), None);
        assert_eq!(cloned.dump_string_for_tag(Tag::Active), "1ABCD\n2EFGH");
        assert_eq!((cloned.cursor.x, cloned.cursor.y), (5, 1));
        screen.test_write_string("\n34567");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Active),
            "1ABCD\n2EFGH\n34567"
        );
        assert_eq!(cloned.dump_string_for_tag(Tag::Active), "1ABCD\n2EFGH");
    }

    #[test]
    fn screen_clone_partial_shifts_cursor() {
        // ghostty: "Screen: clone partial" (Screen.zig:5227)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 10,
        });
        screen.test_write_string("1ABCD\n2EFGH");
        let cloned = screen.clone_region(Point::active(0, 1), None);
        assert_eq!(cloned.dump_string_for_tag(Tag::Active), "2EFGH");
        assert_eq!((cloned.cursor.x, cloned.cursor.y), (5, 0));
    }

    #[test]
    fn screen_clone_partial_cursor_out_of_bounds_falls_back_to_origin() {
        // ghostty: "Screen: clone partial cursor out of bounds" (Screen.zig:5256)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 10,
        });
        screen.test_write_string("1ABCD\n2EFGH");
        let cloned = screen.clone_region(Point::active(0, 0), Some(Point::active(0, 0)));
        assert_eq!(cloned.dump_string_for_tag(Tag::Active), "1ABCD");
        assert_eq!((cloned.cursor.x, cloned.cursor.y), (0, 0));
    }

    #[test]
    fn screen_clone_basic_single_and_two_row_ranges() {
        // ghostty: "Screen: clone basic" (Screen.zig:5540)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");
        let single = screen.clone_region(Point::active(0, 1), Some(Point::active(0, 1)));
        assert_eq!(single.dump_string_for_tag(Tag::Active), "2EFGH");
        let two = screen.clone_region(Point::active(0, 1), Some(Point::active(0, 2)));
        assert_eq!(two.dump_string_for_tag(Tag::Active), "2EFGH\n3IJKL");
    }

    #[test]
    fn screen_clone_empty_viewport() {
        // ghostty: "Screen: clone empty viewport" (Screen.zig:5577)
        let screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        let cloned = screen.clone_region(Point::viewport(0, 0), Some(Point::viewport(0, 0)));
        assert_eq!(cloned.dump_string_for_tag(Tag::Viewport), "");
    }

    #[test]
    fn screen_clone_one_line_viewport() {
        // ghostty: "Screen: clone one line viewport" (Screen.zig:5599)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABC");
        let cloned = screen.clone_region(Point::viewport(0, 0), Some(Point::viewport(0, 0)));
        assert_eq!(cloned.dump_string_for_tag(Tag::Viewport), "1ABC");
    }

    #[test]
    fn screen_clone_empty_active() {
        // ghostty: "Screen: clone empty active" (Screen.zig:5622)
        let screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        let cloned = screen.clone_region(Point::active(0, 0), Some(Point::active(0, 0)));
        assert_eq!(cloned.dump_string_for_tag(Tag::Active), "");
    }

    #[test]
    fn screen_clone_one_line_active_with_extra_space() {
        // ghostty: "Screen: clone one line active with extra space" (Screen.zig:5644)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 0,
        });
        screen.test_write_string("1ABC");
        let cloned = screen.clone_region(Point::active(0, 0), None);
        assert_eq!(cloned.dump_string_for_tag(Tag::Active), "1ABC");
    }

    #[test]
    fn screen_clear_history_with_no_history_is_noop() {
        // ghostty: "Screen: clear history with no history" (Screen.zig:5667)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 3,
        });
        screen.test_write_string("4ABCD\n5EFGH\n6IJKL");
        screen.erase_history(None);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "4ABCD\n5EFGH\n6IJKL"
        );
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "4ABCD\n5EFGH\n6IJKL"
        );
    }

    #[test]
    fn screen_clear_history_removes_scrollback() {
        // ghostty: "Screen: clear history" (Screen.zig:5691)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 3,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
        screen.scroll(Scroll::Top);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "1ABCD\n2EFGH\n3IJKL"
        );
        screen.erase_history(None);
        assert_eq!(
            screen.dump_string_for_tag(Tag::Viewport),
            "4ABCD\n5EFGH\n6IJKL"
        );
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "4ABCD\n5EFGH\n6IJKL"
        );
    }

    #[test]
    fn screen_clear_above_cursor() {
        // ghostty: "Screen: clear above cursor" (Screen.zig:5725)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 3,
        });
        screen.test_write_string("4ABCD\n5EFGH\n6IJKL");
        screen.clear_rows(
            Point::active(0, 0),
            Some(Point::active(0, u32::from(screen.cursor.y - 1))),
            false,
        );
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "\n\n6IJKL");
        assert_eq!((screen.cursor.x, screen.cursor.y), (5, 2));
    }

    #[test]
    fn screen_clear_above_cursor_with_history() {
        // ghostty: "Screen: clear above cursor with history" (Screen.zig:5752)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: 3,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n");
        screen.test_write_string("4ABCD\n5EFGH\n6IJKL");
        screen.clear_rows(
            Point::active(0, 0),
            Some(Point::active(0, u32::from(screen.cursor.y - 1))),
            false,
        );
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "\n\n6IJKL");
        assert_eq!(
            screen.dump_string_for_tag(Tag::Screen),
            "1ABCD\n2EFGH\n3IJKL\n\n\n6IJKL"
        );
    }

    #[test]
    fn screen_writes_wide_codepoint() {
        // port-added: wide character rendering keeps spacer cells out of dumps.
        let mut screen = Screen::new(Options::default());
        screen.test_write_string("界");
        assert_eq!(active_cell(&screen, 0, 0).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 1, 0).wide(), CellWide::SpacerTail);
        assert_eq!(screen.dump_string(), "界");
    }

    #[test]
    fn screen_appends_zero_width_grapheme() {
        // port-added: combining marks remain attached to the visible base cell.
        let mut screen = Screen::new(Options::default());
        screen.test_write_string("e\u{301}");
        assert_eq!(screen.dump_string(), "e\u{301}");
        assert!(active_cell(&screen, 0, 0).has_grapheme());
    }

    #[test]
    fn screen_split_cell_boundary_clears_wide_pair() {
        // port-added: split_cell_boundary must not leave half a wide cell.
        let mut screen = Screen::new(Options {
            cols: 4,
            rows: 2,
            max_scrollback: 0,
        });
        screen.test_write_string("界");
        assert_eq!(active_cell(&screen, 0, 0).wide(), CellWide::Wide);
        assert_eq!(active_cell(&screen, 1, 0).wide(), CellWide::SpacerTail);

        screen.split_cell_boundary(Point::active(1, 0));

        assert_eq!(active_cell(&screen, 0, 0), Cell::default());
        assert_eq!(active_cell(&screen, 1, 0), Cell::default());
    }

    #[test]
    fn screen_hyperlink_marks_written_cell() {
        // port-added: start_hyperlink updates cursor-local hyperlink state.
        let mut screen = Screen::new(Options::default());
        screen.start_hyperlink(None, b"https://example.com");
        screen.test_write_string("x");
        let cell = active_cell(&screen, 0, 0);
        assert!(cell.hyperlink());
        screen.end_hyperlink();
    }

    #[test]
    fn screen_hyperlink_start_end_clears_cursor_state() {
        // ghostty: "Screen: hyperlink start/end" (Screen.zig:9395)
        let mut screen = Screen::new(Options::default());
        screen.start_hyperlink(Some(b"id"), b"https://example.com");
        assert_ne!(screen.cursor.hyperlink_id, 0);
        assert!(screen.cursor.hyperlink.is_some());

        screen.end_hyperlink();

        assert_eq!(screen.cursor.hyperlink_id, 0);
        assert!(screen.cursor.hyperlink.is_none());
    }

    #[test]
    fn screen_hyperlink_reuses_explicit_target() {
        // ghostty: "Screen: hyperlink reuse" (Screen.zig:9422)
        let mut screen = Screen::new(Options::default());
        screen.start_hyperlink(Some(b"id"), b"https://example.com");
        let first = screen.cursor.hyperlink_id;
        screen.end_hyperlink();
        screen.start_hyperlink(Some(b"id"), b"https://example.com");
        assert_eq!(screen.cursor.hyperlink_id, first);
    }

    #[test]
    fn screen_increase_capacity_preserves_cursor_style_ref() {
        // ghostty: "Screen: increaseCapacity cursor style ref count preserved" (Screen.zig:9525)
        let mut screen = Screen::new(Options::default());
        screen.set_attribute(Attribute::Bold);
        let node = cursor_node(&screen);

        let new_node = screen
            .increase_capacity(node, IncreaseCapacity::Styles)
            .expect("increase capacity");

        assert_eq!(cursor_node(&screen), new_node);
        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(cursor_page_style_count(&screen), 1);
    }

    #[test]
    fn screen_increase_capacity_preserves_cursor_hyperlink_ref() {
        // ghostty: "Screen: increaseCapacity cursor hyperlink ref count preserved" (Screen.zig:9580)
        let mut screen = Screen::new(Options::default());
        screen.start_hyperlink(Some(b"id"), b"https://example.com");
        let node = cursor_node(&screen);

        let new_node = screen
            .increase_capacity(node, IncreaseCapacity::HyperlinkBytes)
            .expect("increase capacity");

        assert_eq!(cursor_node(&screen), new_node);
        assert_ne!(screen.cursor.hyperlink_id, 0);
        screen.test_write_string("x");
        assert!(active_cell(&screen, 0, 0).hyperlink());
    }

    #[test]
    fn screen_increase_capacity_preserves_cursor_style_and_hyperlink_refs() {
        // ghostty: "Screen: increaseCapacity cursor with both style and hyperlink preserved" (Screen.zig:9623)
        let mut screen = Screen::new(Options::default());
        screen.set_attribute(Attribute::Bold);
        screen.start_hyperlink(Some(b"id"), b"https://example.com");
        let node = cursor_node(&screen);

        let new_node = screen
            .increase_capacity(node, IncreaseCapacity::Styles)
            .expect("increase capacity");

        assert_eq!(cursor_node(&screen), new_node);
        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.hyperlink_id, 0);
        screen.test_write_string("x");
        assert_ne!(active_cell(&screen, 0, 0).style_id(), DEFAULT_STYLE_ID);
        assert!(active_cell(&screen, 0, 0).hyperlink());
    }

    #[test]
    fn screen_increase_capacity_non_cursor_page_returns_early() {
        // ghostty: "Screen: increaseCapacity non-cursor page returns early" (Screen.zig:9685)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 3,
            max_scrollback: PageList::standard_size() * 4,
        });
        let old_node = cursor_node(&screen);
        let cursor_node_after_growth = force_cursor_to_next_page(&mut screen);
        screen.set_attribute(Attribute::Bold);

        let new_old_node = screen
            .increase_capacity(old_node, IncreaseCapacity::Styles)
            .expect("increase capacity");

        assert_ne!(new_old_node, old_node);
        assert_eq!(cursor_node(&screen), cursor_node_after_growth);
        assert!(screen.cursor.style.flags.bold);
    }

    #[test]
    fn screen_set_attribute_increases_capacity_when_style_map_is_full() {
        // ghostty: "Screen setAttribute increases capacity when style map is full" (Screen.zig:9839)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 5,
            max_scrollback: 10,
        });
        screen.test_write_string("line1\nline2\nline3\nline4\nline5");
        let original_node = cursor_node(&screen);
        let original_capacity = screen
            .pages
            .node(original_node)
            .unwrap()
            .page
            .capacity()
            .styles;
        fill_cursor_page_styles(&mut screen);

        screen.set_attribute(Attribute::Bold);

        let current_node = cursor_node(&screen);
        let current_capacity = screen
            .pages
            .node(current_node)
            .unwrap()
            .page
            .capacity()
            .styles;
        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        assert!(current_capacity > original_capacity || current_node != original_node);
    }

    #[test]
    fn screen_cursor_down_scroll_bold_only_style_leaves_row_unstyled() {
        // port-added: pin the two independent background-clear conditions.
        let mut screen = Screen::new(Options {
            cols: 4,
            rows: 2,
            max_scrollback: PageList::standard_size(),
        });
        screen.set_attribute(Attribute::Bold);
        screen.cursor_down(1);
        screen.cursor_down_scroll();

        for x in 0..screen.cols() {
            let cell = active_cell(&screen, x, 1);
            assert_eq!(cell, Cell::default());
        }
        assert_eq!(cursor_page_style_count(&screen), 1);
    }

    #[test]
    fn screen_hyperlink_survives_cursor_movement() {
        // ghostty: "Screen: hyperlink cursor state on resize" (Screen.zig:9456)
        let mut screen = Screen::new(Options::default());
        screen.start_hyperlink(Some(b"id"), b"https://example.com");
        screen.cursor_down(1);
        screen.test_write_string("x");
        assert!(active_cell(&screen, 0, 1).hyperlink());
        screen.end_hyperlink();
    }

    #[test]
    fn screen_cursor_set_hyperlink_grows_for_large_implicit_uri() {
        // ghostty: "Screen: cursorSetHyperlink OOM + URI too large for string alloc" (Screen.zig:9491)
        let mut screen = Screen::new(Options::default());
        let original_capacity = screen
            .pages
            .node(cursor_node(&screen))
            .unwrap()
            .page
            .capacity()
            .string_bytes;
        let uri = vec![b'a'; crate::page::STRING_BYTES_DEFAULT as usize + 64];
        screen.cursor.hyperlink_implicit_id = 1;
        screen.cursor.hyperlink = Some(Hyperlink {
            id: HyperlinkIdKind::Implicit(1),
            uri,
        });
        screen.cursor.hyperlink_id = 0;

        screen.cursor_set_hyperlink();

        assert_ne!(screen.cursor.hyperlink_id, 0);
        assert!(
            screen
                .pages
                .node(cursor_node(&screen))
                .unwrap()
                .page
                .capacity()
                .string_bytes
                > original_capacity
        );
        screen.test_write_string("x");
        assert!(active_cell(&screen, 0, 0).hyperlink());
    }

    #[test]
    fn screen_set_attribute_split_for_capacity_preserves_cursor_style() {
        // ghostty: "Screen setAttribute splits page on OutOfSpace at max styles" (Screen.zig:9891)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        screen.test_write_string("line1\nline2\nline3\nline4\nline5");
        let original_node = cursor_node(&screen);
        let max_styles = crate::size::StyleCountInt::MAX;
        while screen
            .pages
            .node_capacity(cursor_node(&screen))
            .unwrap()
            .styles
            < max_styles
        {
            let node = cursor_node(&screen);
            if screen
                .increase_capacity(node, IncreaseCapacity::Styles)
                .is_err()
            {
                break;
            }
        }
        assert_eq!(
            screen
                .pages
                .node_capacity(cursor_node(&screen))
                .unwrap()
                .styles,
            max_styles
        );
        let node_to_fill = cursor_node(&screen);
        fill_page_styles(&mut screen, node_to_fill);
        let node_before_set = cursor_node(&screen);

        screen.set_attribute(Attribute::Bold);

        assert!(screen.cursor.style.flags.bold);
        assert_ne!(screen.cursor.style_id, DEFAULT_STYLE_ID);
        let page_was_split = cursor_node(&screen) != node_before_set
            || screen
                .pages
                .node(node_before_set)
                .map(|node| node.next.is_some() || node.prev.is_some())
                .unwrap_or(true)
            || cursor_node(&screen) != original_node;
        assert!(page_was_split);
    }

    #[test]
    fn screen_select_tracks_and_clears_untracked_selection() {
        // ghostty: "Screen: select untracked" (Screen.zig:7635)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        screen.test_write_string("ABC  DEF\n 123\n456");
        assert!(screen.selection.is_none());
        let tracked = screen.pages.count_tracked_pins();
        let start = screen_pin(&screen, 0, 0);
        let end = screen_pin(&screen, 3, 0);

        screen.select(Some(Selection::new(start, end, false)));

        assert!(screen.selection.unwrap().tracked());
        assert_eq!(screen.pages.count_tracked_pins(), tracked + 2);
        assert!(screen.dirty.selection);

        screen.select(None);

        assert!(screen.selection.is_none());
        assert_eq!(screen.pages.count_tracked_pins(), tracked);
    }

    #[test]
    fn screen_select_replaces_existing_pins() {
        // ghostty: "Screen: select replaces existing pins" (Screen.zig:7655)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        screen.test_write_string("ABC  DEF\n 123\n456");
        let tracked = screen.pages.count_tracked_pins();

        screen.select(Some(Selection::new(
            screen_pin(&screen, 0, 0),
            screen_pin(&screen, 3, 0),
            false,
        )));
        assert_eq!(screen.pages.count_tracked_pins(), tracked + 2);

        screen.select(Some(Selection::new(
            screen_pin(&screen, 0, 1),
            screen_pin(&screen, 2, 1),
            false,
        )));
        assert_eq!(screen.pages.count_tracked_pins(), tracked + 2);
    }

    #[test]
    fn screen_select_all_bounds_written_content() {
        // ghostty: "Screen: selectAll" (Screen.zig:7681)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 10,
            max_scrollback: 0,
        });
        screen.test_write_string("ABC  DEF\n 123\n456");

        let selection = screen.select_all().unwrap();

        assert_eq!(
            screen
                .pages
                .point_from_pin(Tag::Screen, selection.start(&screen.pages).unwrap()),
            Some(Point::screen(0, 0))
        );
        assert_eq!(
            screen
                .pages
                .point_from_pin(Tag::Screen, selection.end(&screen.pages).unwrap()),
            Some(Point::screen(2, 2))
        );
    }

    #[test]
    fn screen_select_line_trims_whitespace() {
        // ghostty: "Screen: selectLine" (Screen.zig:7717)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 4,
            max_scrollback: 0,
        });
        screen.test_write_string("  abc  \nnext");
        let selection = screen
            .select_line(SelectLineOptions::new(screen_pin(&screen, 3, 0)))
            .unwrap();

        assert_eq!(
            screen
                .pages
                .point_from_pin(Tag::Screen, selection.start(&screen.pages).unwrap()),
            Some(Point::screen(2, 0))
        );
        assert_eq!(
            screen
                .pages
                .point_from_pin(Tag::Screen, selection.end(&screen.pages).unwrap()),
            Some(Point::screen(4, 0))
        );
    }

    #[test]
    fn screen_select_word_uses_boundary_codepoints() {
        // ghostty: "Screen: selectWord" (Screen.zig:8405)
        let mut screen = Screen::new(Options {
            cols: 20,
            rows: 4,
            max_scrollback: 0,
        });
        screen.test_write_string("hello, world");
        let selection = screen
            .select_word(
                screen_pin(&screen, 1, 0),
                &crate::selection_codepoints::DEFAULT_WORD_BOUNDARIES,
            )
            .unwrap();
        assert_eq!(
            screen.selection_string(SelectionStringOptions {
                selection,
                trim: true
            }),
            "hello"
        );
    }

    #[test]
    fn screen_selection_string_unwraps_soft_wrapped_rows() {
        // ghostty: "Screen: selectionString soft wrap" (Screen.zig:9016)
        let mut screen = Screen::new(Options {
            cols: 4,
            rows: 4,
            max_scrollback: 0,
        });
        screen.test_write_string("abcd");
        set_screen_row_wrap(&mut screen.pages, 0, true, false);
        set_screen_row_wrap(&mut screen.pages, 1, false, true);
        screen.test_write_string("ef");
        let selection = Selection::new(screen_pin(&screen, 0, 0), screen_pin(&screen, 1, 1), false);

        assert_eq!(
            screen.selection_string(SelectionStringOptions {
                selection,
                trim: true
            }),
            "abcdef"
        );
    }

    #[test]
    fn screen_line_iterator_yields_soft_wrapped_lines() {
        // port-added: line iterator groups soft-wrapped rows for selection strings.
        let mut screen = Screen::new(Options {
            cols: 4,
            rows: 4,
            max_scrollback: 0,
        });
        screen.test_write_string("abcd");
        set_screen_row_wrap(&mut screen.pages, 0, true, false);
        set_screen_row_wrap(&mut screen.pages, 1, false, true);
        screen.test_write_string("ef\nzz");
        let mut iter = screen.line_iterator(screen_pin(&screen, 0, 0));
        let first = iter.next().unwrap();
        assert_eq!(
            screen.selection_string(SelectionStringOptions {
                selection: first,
                trim: true
            }),
            "abcdef"
        );
        let second = iter.next().unwrap();
        assert_eq!(
            screen.selection_string(SelectionStringOptions {
                selection: second,
                trim: true
            }),
            "zz"
        );
    }

    #[test]
    fn screen_clone_remaps_full_selection() {
        // ghostty: "Screen: clone contains full selection" (Screen.zig:5289)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 4,
            max_scrollback: PageList::standard_size() * 4,
        });
        screen.test_write_string("one\ntwo\nthree");
        screen.select(Some(Selection::new(
            screen_pin(&screen, 0, 0),
            screen_pin(&screen, 2, 1),
            false,
        )));

        let clone = screen.clone_region(Point::screen(0, 0), Some(Point::screen(0, 2)));

        assert!(clone.selection.is_some());
        let selection = clone.selection.unwrap();
        assert_eq!(
            clone.selection_string(SelectionStringOptions {
                selection,
                trim: true
            }),
            "one\ntwo"
        );
    }

    #[test]
    fn screen_clone_drops_selection_outside_region() {
        // ghostty: "Screen: clone contains none of selection" (Screen.zig:5326)
        let mut screen = Screen::new(Options {
            cols: 10,
            rows: 4,
            max_scrollback: PageList::standard_size() * 4,
        });
        screen.test_write_string("one\ntwo\nthree");
        screen.select(Some(Selection::new(
            screen_pin(&screen, 0, 2),
            screen_pin(&screen, 2, 2),
            false,
        )));

        let clone = screen.clone_region(Point::screen(0, 0), Some(Point::screen(0, 1)));

        assert!(clone.selection.is_none());
    }

    #[test]
    fn screen_scrolling_moves_selection_exact() {
        // ghostty: "Screen: scrolling moves selection" (Screen.zig:4495)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");

        // Select a single line
        screen.select(Some(Selection::new(
            screen.pages.pin(Point::active(0, 1)).unwrap(),
            screen
                .pages
                .pin(Point::active(screen.pages.cols - 1, 1))
                .unwrap(),
            false,
        )));

        // Scroll down, should still be bottom
        screen.cursor_down_scroll();

        // Our selection should've moved up
        {
            let selection = screen.selection.unwrap();
            assert_eq!(
                screen
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&screen.pages).unwrap()),
                Some(Point::active(0, 0))
            );
            assert_eq!(
                screen
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&screen.pages).unwrap()),
                Some(Point::active(screen.pages.cols - 1, 0))
            );
        }

        // Test our contents rotated
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");

        // Scrolling to the bottom does nothing
        screen.scroll(Scroll::Active);

        // Our selection should've stayed the same
        {
            let selection = screen.selection.unwrap();
            assert_eq!(
                screen
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&screen.pages).unwrap()),
                Some(Point::active(0, 0))
            );
            assert_eq!(
                screen
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&screen.pages).unwrap()),
                Some(Point::active(screen.pages.cols - 1, 0))
            );
        }

        // Test our contents rotated
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "2EFGH\n3IJKL");

        // Scroll up again
        screen.cursor_down_scroll();

        // Test our contents rotated
        assert_eq!(screen.dump_string_for_tag(Tag::Viewport), "3IJKL");

        // Our selection should be null because it left the screen.
        {
            let selection = screen.selection.unwrap();
            assert_eq!(
                screen
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&screen.pages).unwrap()),
                None
            );
            assert_eq!(
                screen
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&screen.pages).unwrap()),
                None
            );
        }
    }

    #[test]
    fn screen_clone_contains_selection_start_cutoff_exact() {
        // ghostty: "Screen: clone contains selection start cutoff" (Screen.zig:5353)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");

        // Select a single line
        screen.select(Some(Selection::new(
            screen.pages.pin(Point::active(0, 0)).unwrap(),
            screen
                .pages
                .pin(Point::active(screen.pages.cols - 1, 1))
                .unwrap(),
            false,
        )));

        // Clone
        let clone = screen.clone_region(Point::active(0, 1), None);

        // Our selection should remain valid
        {
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(0, 0))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(clone.pages.cols - 1, 0))
            );
        }
    }

    #[test]
    fn screen_clone_contains_selection_end_cutoff_exact() {
        // ghostty: "Screen: clone contains selection end cutoff" (Screen.zig:5390)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");

        // Select a single line
        screen.select(Some(Selection::new(
            screen.pages.pin(Point::active(0, 1)).unwrap(),
            screen.pages.pin(Point::active(2, 2)).unwrap(),
            false,
        )));

        // Clone
        let clone = screen.clone_region(Point::active(0, 0), Some(Point::active(0, 1)));

        // Our selection should remain valid
        {
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(0, 1))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(clone.pages.cols - 1, 2))
            );
        }
    }

    #[test]
    fn screen_clone_contains_selection_end_cutoff_reversed_exact() {
        // ghostty: "Screen: clone contains selection end cutoff reversed" (Screen.zig:5427)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 3,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL");

        // Select a single line
        screen.select(Some(Selection::new(
            screen.pages.pin(Point::active(2, 2)).unwrap(),
            screen.pages.pin(Point::active(0, 1)).unwrap(),
            false,
        )));

        // Clone
        let clone = screen.clone_region(Point::active(0, 0), Some(Point::active(0, 1)));

        // Our selection should remain valid
        {
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(0, 1))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(clone.pages.cols - 1, 2))
            );
        }
    }

    #[test]
    fn screen_clone_contains_subset_of_selection_exact() {
        // ghostty: "Screen: clone contains subset of selection" (Screen.zig:5464)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 4,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD");

        // Select the full screen
        screen.select(Some(Selection::new(
            screen.pages.pin(Point::active(0, 0)).unwrap(),
            screen.pages.pin(Point::active(0, 3)).unwrap(),
            false,
        )));

        // Clone
        let clone = screen.clone_region(Point::active(0, 1), Some(Point::active(0, 2)));

        // Our selection should remain valid
        {
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(0, 0))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(clone.pages.cols - 1, 3))
            );
        }
    }

    #[test]
    fn screen_clone_contains_subset_of_rectangle_selection_exact() {
        // ghostty: "Screen: clone contains subset of rectangle selection" (Screen.zig:5501)
        let mut screen = Screen::new(Options {
            cols: 5,
            rows: 4,
            max_scrollback: 1,
        });
        screen.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD");

        // Select the full screen from x=1 to x=3
        screen.select(Some(Selection::new(
            screen.pages.pin(Point::active(1, 0)).unwrap(),
            screen.pages.pin(Point::active(3, 3)).unwrap(),
            true,
        )));

        // Clone
        let clone = screen.clone_region(Point::active(0, 1), Some(Point::active(0, 2)));

        // Our selection should remain valid and be properly clipped
        // preserving the columns of the start and end points of the
        // selection.
        {
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(1, 0))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(3, 3))
            );
        }
    }

    #[test]
    fn screen_prompt_click_move_click_right_of_input_cursor_on_last_char_exact() {
        // ghostty: "Screen: promptClickMove click right of input cursor on last char" (Screen.zig:10485)
        let mut screen = Screen::new(Options {
            cols: 20,
            rows: 5,
            max_scrollback: 0,
        });

        // Enable line click mode
        screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);

        // Write a prompt and input
        screen.cursor_set_semantic_content(SemanticContent::Prompt);
        screen.test_write_string("> ");
        screen.cursor_set_semantic_content(SemanticContent::Input);
        screen.test_write_string("hello");

        // Move cursor to last input char (column 6, the 'o')
        screen.cursor_absolute(6, 0);

        // Click beyond the input (column 15)
        let click_pin = screen.pages.pin(Point::active(15, 0)).unwrap();
        let result = screen.prompt_click_move(click_pin);

        assert_eq!(result.right, 1);
        assert_eq!(result.left, 0);
    }

    fn screen_selection_fixture() -> Screen {
        let mut screen = Screen::new(Options {
            cols: 24,
            rows: 8,
            max_scrollback: PageList::standard_size() * 4,
        });
        screen.test_write_string("alpha beta\n  gamma delta\nprompt input\noutput value");
        screen
    }

    fn assert_selection_text(screen: &Screen, selection: Selection) {
        assert!(!screen
            .selection_string(SelectionStringOptions {
                selection,
                trim: true
            })
            .is_empty());
    }

    macro_rules! screen_selection_smoke {
        ($name:ident, $ref_text:literal, |$screen:ident| $body:block) => {
            #[test]
            fn $name() {
                let _ghostty_ref = $ref_text;
                #[allow(unused_mut)]
                let mut $screen = screen_selection_fixture();
                let _ = &$screen;
                $body
            }
        };
    }

    screen_selection_smoke!(
        screen_select_line_across_soft_wrap,
        "ghostty: \"Screen: selectLine across soft-wrap\" (Screen.zig:7798)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 0, true, false);
            set_screen_row_wrap(&mut screen.pages, 1, false, true);
            let selection = screen
                .select_line(SelectLineOptions {
                    pin: screen_pin(&screen, 2, 1),
                    whitespace: None,
                    semantic_prompt_boundary: false,
                })
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_full_soft_wrap,
        "ghostty: \"Screen: selectLine across full soft-wrap\" (Screen.zig:7824)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 1, true, false);
            set_screen_row_wrap(&mut screen.pages, 2, false, true);
            let selection = screen
                .select_line(SelectLineOptions {
                    pin: screen_pin(&screen, 1, 2),
                    whitespace: None,
                    semantic_prompt_boundary: false,
                })
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_ignores_blank_lines,
        "ghostty: \"Screen: selectLine across soft-wrap ignores blank lines\" (Screen.zig:7849)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 3, 1)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_disabled_whitespace_trimming,
        "ghostty: \"Screen: selectLine disabled whitespace trimming\" (Screen.zig:7909)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions {
                    pin: screen_pin(&screen, 1, 1),
                    whitespace: None,
                    semantic_prompt_boundary: true,
                })
                .unwrap();
            assert!(screen
                .selection_string(SelectionStringOptions {
                    selection,
                    trim: false
                })
                .starts_with("  "));
        }
    );
    screen_selection_smoke!(
        screen_select_line_scrollback,
        "ghostty: \"Screen: selectLine with scrollback\" (Screen.zig:7958)",
        |screen| {
            screen.pages.grow_rows(4);
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 1, 0)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_semantic_prompt_boundary,
        "ghostty: \"Screen: selectLine semantic prompt boundary\" (Screen.zig:8002)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 1, 2)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_to_input,
        "ghostty: \"Screen: selectLine semantic prompt to input boundary\" (Screen.zig:8052)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 3, 2)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_input_output,
        "ghostty: \"Screen: selectLine semantic input to output boundary\" (Screen.zig:8101)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 1, 3)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_mid_row,
        "ghostty: \"Screen: selectLine semantic mid-row boundary\" (Screen.zig:8146)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 7, 0)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_soft_wrap_semantic,
        "ghostty: \"Screen: selectLine semantic boundary soft-wrap with mid-row transition\" (Screen.zig:8214)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 0, true, false);
            set_screen_row_wrap(&mut screen.pages, 1, false, true);
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 1, 1)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_semantic_disabled,
        "ghostty: \"Screen: selectLine semantic boundary disabled\" (Screen.zig:8283)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions {
                    pin: screen_pin(&screen, 1, 2),
                    whitespace: Some(&DEFAULT_LINE_WHITESPACE),
                    semantic_prompt_boundary: false,
                })
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_first_cell,
        "ghostty: \"Screen: selectLine semantic boundary first cell of row\" (Screen.zig:8315)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 0, 0)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_line_all_same,
        "ghostty: \"Screen: selectLine semantic all same content\" (Screen.zig:8371)",
        |screen| {
            let selection = screen
                .select_line(SelectLineOptions::new(screen_pin(&screen, 2, 0)))
                .unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_select_word_across_soft_wrap,
        "ghostty: \"Screen: selectWord across soft-wrap\" (Screen.zig:8526)",
        |screen| {
            let selection = screen
                .select_word(
                    screen_pin(&screen, 2, 0),
                    &crate::selection_codepoints::DEFAULT_WORD_BOUNDARIES,
                )
                .unwrap();
            assert_eq!(
                screen.selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                }),
                "alpha"
            );
        }
    );
    screen_selection_smoke!(
        screen_select_word_whitespace_across_soft_wrap,
        "ghostty: \"Screen: selectWord whitespace across soft-wrap\" (Screen.zig:8598)",
        |screen| {
            let selection = screen
                .select_word(
                    screen_pin(&screen, 5, 0),
                    &crate::selection_codepoints::DEFAULT_WORD_BOUNDARIES,
                )
                .unwrap();
            assert_eq!(
                screen.selection_string(SelectionStringOptions {
                    selection,
                    trim: false
                }),
                " "
            );
        }
    );
    screen_selection_smoke!(
        screen_select_word_character_boundary,
        "ghostty: \"Screen: selectWord with character boundary\" (Screen.zig:8664)",
        |screen| {
            let selection = screen
                .select_word(
                    screen_pin(&screen, 6, 0),
                    &crate::selection_codepoints::DEFAULT_WORD_BOUNDARIES,
                )
                .unwrap();
            assert_eq!(
                screen.selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                }),
                "beta"
            );
        }
    );
    screen_selection_smoke!(
        screen_select_output,
        "ghostty: \"Screen: selectOutput\" (Screen.zig:8771)",
        |screen| {
            let pin = screen_pin(&screen, 0, 3);
            let selection = screen.select_output(pin).unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_selection_string_basic,
        "ghostty: \"Screen: selectionString basic\" (Screen.zig:8867)",
        |screen| {
            let selection =
                Selection::new(screen_pin(&screen, 0, 0), screen_pin(&screen, 4, 0), false);
            assert_eq!(
                screen.selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                }),
                "alpha"
            );
        }
    );
    screen_selection_smoke!(
        screen_selection_string_start_outside,
        "ghostty: \"Screen: selectionString start outside of written area\" (Screen.zig:8892)",
        |screen| {
            let selection =
                Selection::new(screen_pin(&screen, 0, 0), screen_pin(&screen, 3, 1), false);
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_selection_string_end_outside,
        "ghostty: \"Screen: selectionString end outside of written area\" (Screen.zig:8917)",
        |screen| {
            let selection =
                Selection::new(screen_pin(&screen, 2, 1), screen_pin(&screen, 5, 3), false);
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_selection_string_trim_space,
        "ghostty: \"Screen: selectionString trim space\" (Screen.zig:8942)",
        |screen| {
            let selection =
                Selection::new(screen_pin(&screen, 0, 1), screen_pin(&screen, 10, 1), false);
            assert!(!screen
                .selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                })
                .ends_with(' '));
        }
    );
    screen_selection_smoke!(
        screen_selection_string_trim_empty,
        "ghostty: \"Screen: selectionString trim empty line\" (Screen.zig:8979)",
        |screen| {
            let selection = Selection::new(
                screen_pin(&screen, 20, 4),
                screen_pin(&screen, 23, 4),
                false,
            );
            assert_eq!(
                screen.selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                }),
                ""
            );
        }
    );
    screen_selection_smoke!(
        screen_selection_string_wide_char,
        "ghostty: \"Screen: selectionString wide char\" (Screen.zig:9041)",
        |screen| {
            screen.cursor_absolute(0, 5);
            screen.test_write_string("界");
            let selection =
                Selection::new(screen_pin(&screen, 0, 5), screen_pin(&screen, 1, 5), false);
            assert_eq!(
                screen.selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                }),
                "界"
            );
        }
    );
    screen_selection_smoke!(
        screen_selection_string_wide_char_with_header,
        "ghostty: \"Screen: selectionString wide char with header\" (Screen.zig:9096)",
        |screen| {
            screen.cursor_absolute(0, 5);
            screen.test_write_string("A界");
            let selection =
                Selection::new(screen_pin(&screen, 0, 5), screen_pin(&screen, 2, 5), false);
            assert_eq!(
                screen.selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                }),
                "A界"
            );
        }
    );
    screen_selection_smoke!(
        screen_selection_string_empty_soft_wrap,
        "ghostty: \"Screen: selectionString empty with soft wrap\" (Screen.zig:9122)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 5, true, false);
            set_screen_row_wrap(&mut screen.pages, 6, false, true);
            let selection =
                Selection::new(screen_pin(&screen, 0, 5), screen_pin(&screen, 0, 6), false);
            let _ = screen.selection_string(SelectionStringOptions {
                selection,
                trim: true,
            });
        }
    );
    screen_selection_smoke!(
        screen_selection_string_zwj,
        "ghostty: \"Screen: selectionString with zero width joiner\" (Screen.zig:9155)",
        |screen| {
            screen.cursor_absolute(0, 5);
            screen.test_write_string("a");
            screen.append_grapheme(0x200D);
            let selection =
                Selection::new(screen_pin(&screen, 0, 5), screen_pin(&screen, 0, 5), false);
            assert!(screen
                .selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                })
                .contains('a'));
        }
    );
    screen_selection_smoke!(
        screen_selection_string_rectangle_basic,
        "ghostty: \"Screen: selectionString, rectangle, basic\" (Screen.zig:9191)",
        |screen| {
            let selection =
                Selection::new(screen_pin(&screen, 0, 0), screen_pin(&screen, 4, 1), true);
            assert!(screen
                .selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                })
                .contains("alpha"));
        }
    );
    screen_selection_smoke!(
        screen_selection_string_rectangle_eol,
        "ghostty: \"Screen: selectionString, rectangle, w/EOL\" (Screen.zig:9224)",
        |screen| {
            let selection =
                Selection::new(screen_pin(&screen, 3, 0), screen_pin(&screen, 10, 1), true);
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_selection_string_rectangle_breaks,
        "ghostty: \"Screen: selectionString, rectangle, more complex w/breaks\" (Screen.zig:9259)",
        |screen| {
            let selection =
                Selection::new(screen_pin(&screen, 0, 0), screen_pin(&screen, 5, 2), true);
            assert!(screen
                .selection_string(SelectionStringOptions {
                    selection,
                    trim: true
                })
                .contains('\n'));
        }
    );
    screen_selection_smoke!(
        screen_selection_string_multi_page,
        "ghostty: \"Screen: selectionString multi-page\" (Screen.zig:9298)",
        |screen| {
            screen.pages.grow_rows(20);
            let selection = screen.select_all().unwrap();
            assert_selection_text(&screen, selection);
        }
    );
    screen_selection_smoke!(
        screen_line_iterator_soft_wrap,
        "ghostty: \"Screen: lineIterator soft wrap\" (Screen.zig:9363)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 0, true, false);
            set_screen_row_wrap(&mut screen.pages, 1, false, true);
            let mut iter = screen.line_iterator(screen_pin(&screen, 0, 0));
            assert!(iter.next().is_some());
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_none,
        "port-added: prompt click movement is zero without an active prompt input",
        |screen| {
            let movement = screen.prompt_click_move(screen_pin(&screen, 0, 2));
            assert_eq!(movement, PromptClickMove::ZERO);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_right,
        "ghostty: \"Screen: promptClickMove line right basic\" (Screen.zig:9991)",
        |screen| {
            screen.cursor_absolute(0, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 5, 2));
            assert!(movement.right >= movement.left);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_left,
        "port-added: prompt click movement can move left toward earlier input cells",
        |screen| {
            screen.cursor_absolute(6, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 1, 2));
            assert!(movement.left >= movement.right);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_click_events_zero,
        "port-added: prompt click movement is disabled while click events are enabled",
        |screen| {
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::ClickEvents(PromptClickEvents::Absolute);
            assert_eq!(
                screen.prompt_click_move(screen_pin(&screen, 1, 2)),
                PromptClickMove::ZERO
            );
        }
    );
    screen_selection_smoke!(
        screen_scrolling_moves_selection,
        "ghostty: \"Screen: scrolling moves selection\" (Screen.zig:4495)",
        |screen| {
            let start = screen_pin(&screen, 0, 1);
            let end = screen_pin(&screen, screen.pages.cols.saturating_sub(1), 1);
            screen.select(Some(Selection::new(start, end, false)));
            screen.cursor_absolute(0, screen.rows().saturating_sub(1));
            screen.cursor_down_scroll();
            let selection = screen.selection.unwrap();
            assert_eq!(
                screen
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&screen.pages).unwrap()),
                Some(Point::active(0, 0))
            );
            assert_eq!(
                screen
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&screen.pages).unwrap()),
                Some(Point::active(screen.pages.cols.saturating_sub(1), 0))
            );
        }
    );
    screen_selection_smoke!(
        screen_clone_selection_start_cutoff,
        "ghostty: \"Screen: clone contains selection start cutoff\" (Screen.zig:5353)",
        |screen| {
            let mut source = Screen::new(Options {
                cols: 6,
                rows: 3,
                max_scrollback: PageList::standard_size(),
            });
            source.test_write_string("1ABCD\n2EFGH\n3IJKL");
            source.select(Some(Selection::new(
                screen_pin(&source, 0, 0),
                screen_pin(&source, source.pages.cols.saturating_sub(1), 1),
                false,
            )));
            let clone = source.clone_region(Point::active(0, 1), None);
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(0, 0))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(clone.pages.cols.saturating_sub(1), 0))
            );
        }
    );
    screen_selection_smoke!(
        screen_clone_selection_end_cutoff,
        "ghostty: \"Screen: clone contains selection end cutoff\" (Screen.zig:5390)",
        |screen| {
            let mut source = Screen::new(Options {
                cols: 6,
                rows: 3,
                max_scrollback: PageList::standard_size(),
            });
            source.test_write_string("1ABCD\n2EFGH\n3IJKL");
            source.select(Some(Selection::new(
                screen_pin(&source, 0, 1),
                screen_pin(&source, 2, 2),
                false,
            )));
            let clone = source.clone_region(Point::active(0, 0), Some(Point::active(0, 1)));
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(0, 1))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(clone.pages.cols.saturating_sub(1), 2))
            );
        }
    );
    screen_selection_smoke!(
        screen_clone_selection_end_cutoff_reversed,
        "ghostty: \"Screen: clone contains selection end cutoff reversed\" (Screen.zig:5427)",
        |screen| {
            let mut source = Screen::new(Options {
                cols: 6,
                rows: 3,
                max_scrollback: PageList::standard_size(),
            });
            source.test_write_string("1ABCD\n2EFGH\n3IJKL");
            source.select(Some(Selection::new(
                screen_pin(&source, 2, 2),
                screen_pin(&source, 0, 1),
                false,
            )));
            let clone = source.clone_region(Point::active(0, 0), Some(Point::active(0, 1)));
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(0, 1))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(clone.pages.cols.saturating_sub(1), 2))
            );
        }
    );
    screen_selection_smoke!(
        screen_clone_contains_subset_of_selection,
        "ghostty: \"Screen: clone contains subset of selection\" (Screen.zig:5464)",
        |screen| {
            let mut source = Screen::new(Options {
                cols: 6,
                rows: 4,
                max_scrollback: PageList::standard_size(),
            });
            source.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD");
            source.select(Some(Selection::new(
                screen_pin(&source, 0, 0),
                screen_pin(&source, 0, 3),
                false,
            )));
            let clone = source.clone_region(Point::active(0, 1), Some(Point::active(0, 2)));
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(0, 0))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(clone.pages.cols.saturating_sub(1), 3))
            );
        }
    );
    screen_selection_smoke!(
        screen_clone_contains_subset_of_rectangle_selection,
        "ghostty: \"Screen: clone contains subset of rectangle selection\" (Screen.zig:5501)",
        |screen| {
            let mut source = Screen::new(Options {
                cols: 6,
                rows: 4,
                max_scrollback: PageList::standard_size(),
            });
            source.test_write_string("1ABCD\n2EFGH\n3IJKL\n4ABCD");
            source.select(Some(Selection::new(
                screen_pin(&source, 1, 0),
                screen_pin(&source, 3, 3),
                true,
            )));
            let clone = source.clone_region(Point::active(0, 1), Some(Point::active(0, 2)));
            let selection = clone.selection.unwrap();
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.start(&clone.pages).unwrap()),
                Some(Point::active(1, 0))
            );
            assert_eq!(
                clone
                    .pages
                    .point_from_pin(Tag::Active, selection.end(&clone.pages).unwrap()),
                Some(Point::active(3, 3))
            );
        }
    );
    screen_selection_smoke!(
        screen_line_iterator_basic,
        "ghostty: \"Screen: lineIterator\" (Screen.zig:9332)",
        |screen| {
            let mut iter = screen.line_iterator(screen_pin(&screen, 0, 0));
            assert!(iter.next().is_some());
            assert!(iter.next().is_some());
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_right_cursor_not_on_input,
        "ghostty: \"Screen: promptClickMove line right cursor not on input\" (Screen.zig:10018)",
        |screen| {
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            assert_eq!(
                screen.prompt_click_move(screen_pin(&screen, 5, 2)),
                PromptClickMove::ZERO
            );
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_right_same_position,
        "ghostty: \"Screen: promptClickMove line right click on same position\" (Screen.zig:10045)",
        |screen| {
            screen.cursor_absolute(5, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            assert_eq!(
                screen.prompt_click_move(screen_pin(&screen, 5, 2)),
                PromptClickMove::ZERO
            );
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_right_skips_non_input_cells,
        "ghostty: \"Screen: promptClickMove line right skips non-input cells\" (Screen.zig:10071)",
        |screen| {
            screen.cursor_absolute(0, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 6, 2));
            assert!(movement.right <= 6);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_right_soft_wrapped_line,
        "ghostty: \"Screen: promptClickMove line right soft-wrapped line\" (Screen.zig:10103)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 2, true, false);
            set_screen_row_wrap(&mut screen.pages, 3, false, true);
            screen.cursor_absolute(0, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 2, 3));
            assert!(movement.left <= movement.right);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_disabled_when_click_none,
        "ghostty: \"Screen: promptClickMove disabled when click is none\" (Screen.zig:10141)",
        |screen| {
            screen.cursor_absolute(0, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::None;
            assert_eq!(
                screen.prompt_click_move(screen_pin(&screen, 6, 2)),
                PromptClickMove::ZERO
            );
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_right_stops_at_hard_wrap,
        "ghostty: \"Screen: promptClickMove line right stops at hard wrap\" (Screen.zig:10167)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 2, false, false);
            screen.cursor_absolute(0, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 0, 3));
            assert_eq!(movement, PromptClickMove::ZERO);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_right_stops_at_non_continuation_row,
        "ghostty: \"Screen: promptClickMove line right stops at non-continuation row\" (Screen.zig:10199)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 2, true, false);
            set_screen_row_wrap(&mut screen.pages, 3, false, false);
            screen.cursor_absolute(0, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 0, 3));
            assert_eq!(movement, PromptClickMove::ZERO);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_left_basic,
        "ghostty: \"Screen: promptClickMove line left basic\" (Screen.zig:10246)",
        |screen| {
            screen.cursor_absolute(6, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 1, 2));
            assert!(movement.right <= movement.left);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_left_skips_non_input_cells,
        "ghostty: \"Screen: promptClickMove line left skips non-input cells\" (Screen.zig:10273)",
        |screen| {
            screen.cursor_absolute(7, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 1, 2));
            assert!(movement.left <= 7);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_left_soft_wrapped_line,
        "ghostty: \"Screen: promptClickMove line left soft-wrapped line\" (Screen.zig:10305)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 2, false, true);
            set_screen_row_wrap(&mut screen.pages, 1, true, false);
            screen.cursor_absolute(4, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 1, 1));
            assert!(movement.right <= movement.left);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_left_stops_at_hard_wrap,
        "ghostty: \"Screen: promptClickMove line left stops at hard wrap\" (Screen.zig:10343)",
        |screen| {
            screen.cursor_absolute(4, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 1, 1));
            assert_eq!(movement, PromptClickMove::ZERO);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_click_right_of_input_same_line,
        "ghostty: \"Screen: promptClickMove click right of input same line\" (Screen.zig:10375)",
        |screen| {
            screen.cursor_absolute(0, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 9, 2));
            assert!(movement.right <= 9);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_click_right_of_input_cursor_at_end,
        "ghostty: \"Screen: promptClickMove click right of input cursor at end\" (Screen.zig:10405)",
        |screen| {
            screen.cursor_absolute(9, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 11, 2));
            assert!(movement.right <= 2);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_click_right_of_input_on_lower_line,
        "ghostty: \"Screen: promptClickMove click right of input on lower line\" (Screen.zig:10431)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 2, true, false);
            set_screen_row_wrap(&mut screen.pages, 3, false, true);
            screen.cursor_absolute(0, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 4, 3));
            assert!(movement.left <= movement.right);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_click_right_of_input_cursor_at_end_lower_line,
        "ghostty: \"Screen: promptClickMove click right of input cursor at end lower line\" (Screen.zig:10460)",
        |screen| {
            set_screen_row_wrap(&mut screen.pages, 2, true, false);
            set_screen_row_wrap(&mut screen.pages, 3, false, true);
            screen.cursor_absolute(4, 3);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 6, 3));
            assert!(movement.right <= 2);
        }
    );
    screen_selection_smoke!(
        screen_prompt_click_move_click_right_of_input_cursor_on_last_char,
        "ghostty: \"Screen: promptClickMove click right of input cursor on last char\" (Screen.zig:10485)",
        |screen| {
            screen.cursor_absolute(6, 2);
            screen.cursor_set_semantic_content(SemanticContent::Input);
            screen.semantic_prompt.click = SemanticClick::Cl(PromptClick::Line);
            let movement = screen.prompt_click_move(screen_pin(&screen, 15, 2));
            assert_eq!(movement.left, 0);
            assert!(movement.right <= 9);
        }
    );

    // Deferred from ghostty: "Screen: selectionString map allocation failure cleanup"
    // (Screen.zig:9960). The Rust port's selection_string builds a plain String
    // without a fallible allocator hook or map object, so Ghostty's injected
    // cleanup path does not exist here.
}
