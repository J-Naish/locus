//! Terminal screen state.
//!
//! This ports the first structural slice of Ghostty's `terminal/Screen.zig`.
//! Resize, selection, and kitty-specific behavior are intentionally deferred
//! to later terminal phases.

use unicode_width::UnicodeWidthChar;

use crate::color::Name;
use crate::hyperlink::{Hyperlink, HyperlinkId, HyperlinkIdKind};
use crate::page::{Cell, CellWide, Page, SemanticContent};
use crate::page_list::{
    CloneOptions, IncreaseCapacity, IncreaseCapacityError, PageList, Pin, PinId, Scroll,
};
use crate::point::{Coordinate, Point, Tag};
use crate::sgr::Attribute;
use crate::size::CellCountInt;
use crate::style::{PackedStyle, Style, StyleColor, StyleId, DEFAULT_STYLE_ID};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Dirty {
    pub selection: bool,
    pub hyperlink_hover: bool,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum SemanticClick {
    #[default]
    None,
    ClickEvents,
    Cl,
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

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Charset {
    #[default]
    Ascii,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CharsetSlot {
    G0,
    G1,
    G2,
    G3,
}

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
    pub saved_cursor: SavedCursor,
    pub charset: CharsetState,
    pub semantic_prompt: ScreenSemanticPrompt,
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
            saved_cursor: SavedCursor::default(),
            charset: CharsetState::default(),
            semantic_prompt: ScreenSemanticPrompt::default(),
            dirty: Dirty::default(),
        };
        screen.assert_integrity();
        screen
    }

    pub fn reset(&mut self) {
        let options = Options {
            cols: self.pages.cols,
            rows: self.pages.rows,
            max_scrollback: if self.no_scrollback {
                0
            } else {
                self.pages.max_size()
            },
        };
        *self = Self::new(options);
    }

    pub fn cols(&self) -> CellCountInt {
        self.pages.cols
    }

    pub fn rows(&self) -> CellCountInt {
        self.pages.rows
    }

    pub fn assert_integrity(&self) {
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

    pub fn cursor_pin(&self) -> Option<Pin> {
        self.pages.tracked_pin(self.cursor.pin)
    }

    pub fn cursor_cell(&self) -> Option<Cell> {
        let pin = self.cursor_pin()?;
        self.pages
            .node(pin.node)
            .map(|node| node.page.cell(pin.y, pin.x))
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
        self.cursor.pending_wrap = false;
    }

    pub fn cursor_horizontal_absolute(&mut self, x: CellCountInt) {
        let target_x = x.min(self.cols().saturating_sub(1));
        self.cursor.pending_wrap = false;
        self.cursor_change_active_point(target_x, self.cursor.y);
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
        let x = self.cursor.x.saturating_sub(cols as CellCountInt);
        self.cursor_change_active_point(x, self.cursor.y);
    }

    pub fn cursor_right(&mut self, cols: usize) {
        let x = self
            .cursor
            .x
            .saturating_add(cols as CellCountInt)
            .min(self.cols().saturating_sub(1));
        self.cursor_change_active_point(x, self.cursor.y);
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
        if let Some(node) = self.pages.node_mut(start_pin.node) {
            if protected {
                for x in start_x..end_x {
                    if !node.page.cell(start_pin.y, x).protected() {
                        node.page.clear_cells(start_pin.y, x, x.saturating_add(1));
                    }
                }
            } else {
                node.page.clear_cells(start_pin.y, start_x, end_x);
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
        let Some(pin) = self.pages.pin(point) else {
            return;
        };
        let left = pin.x.saturating_sub(1);
        if let Some(node) = self.pages.node_mut(pin.node) {
            let cell = node.page.cell(pin.y, pin.x);
            if matches!(cell.wide(), CellWide::SpacerTail) {
                node.page.clear_cells(pin.y, left, pin.x.saturating_add(1));
            } else if matches!(cell.wide(), CellWide::SpacerHead) {
                node.page.clear_cells(pin.y, pin.x, pin.x.saturating_add(2));
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
            return;
        }

        let style = PackedStyle::from(self.cursor.style);
        loop {
            let Some(pin) = self.cursor_pin() else {
                self.cursor.style_id = DEFAULT_STYLE_ID;
                return;
            };
            let Some(node) = self.pages.node_mut(pin.node) else {
                self.cursor.style_id = DEFAULT_STYLE_ID;
                return;
            };
            match node.page.add_style(style) {
                Ok(id) => {
                    self.cursor.style_id = id;
                    return;
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
                        return;
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

    fn append_grapheme_to_previous_cell(&mut self, codepoint: u32) {
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

    pub fn cursor_set_semantic_content(&mut self, content: SemanticContent) {
        self.cursor.semantic_content = content;
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
        self.dump_string_for_tag(Tag::Screen)
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
        clone.manual_style_update();
        clone
    }

    fn write_char(&mut self, ch: char) {
        match ch {
            '\n' => {
                self.cursor_down_or_scroll();
                self.cursor_horizontal_absolute(0);
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
                node.page.set_row(pin.y, row);
            }
        }
        self.cursor.pending_wrap = false;
    }

    fn write_cell(&mut self, ch: char, width: usize) {
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

    fn write_spacer_tail(&mut self) {
        let mut cell = Cell::default();
        cell.set_wide(CellWide::SpacerTail);
        self.put_cell_at_cursor(cell);
        self.cursor_set_hyperlink();
    }

    fn write_spacer_head(&mut self) {
        let mut cell = Cell::default();
        cell.set_wide(CellWide::SpacerHead);
        self.put_cell_at_cursor(cell);
        self.cursor_set_hyperlink();
    }

    fn put_cell_at_cursor(&mut self, cell: Cell) {
        let Some(pin) = self.cursor_pin() else {
            return;
        };
        if let Some(node) = self.pages.node_mut(pin.node) {
            node.page.clear_cells(pin.y, pin.x, pin.x.saturating_add(1));
            node.page.set_cell(pin.y, pin.x, cell);
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

    fn cursor_change_active_point(&mut self, x: CellCountInt, y: CellCountInt) {
        if let Some(pin) = self.pages.pin(Point::active(x, u32::from(y))) {
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

    fn clear_row_at_cursor(&mut self) {
        if let Some(pin) = self.cursor_pin() {
            self.clear_row(pin, false);
        }
    }

    fn clear_row(&mut self, pin: Pin, protected: bool) {
        if let Some(node) = self.pages.node_mut(pin.node) {
            if protected {
                for x in 0..node.page.size().cols {
                    if !node.page.cell(pin.y, x).protected() {
                        node.page.clear_cells(pin.y, x, x.saturating_add(1));
                    }
                }
            } else {
                node.page.clear_cells(pin.y, 0, node.page.size().cols);
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
        let mut out = String::new();
        for x in 0..page.size().cols {
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
        out.trim_end_matches(' ').to_string()
    }
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

    // T6c deferred: selection-specific Screen tests in Screen.zig are omitted
    // until the selection data model is ported:
    // - "Screen: scrolling moves selection" (Screen.zig:4495)
    // - "Screen: clone contains full selection" (Screen.zig:5289)
    // - "Screen: clone contains none of selection" (Screen.zig:5326)
    // - "Screen: clone selection start cutoff" (Screen.zig:5353)
    // - "Screen: clone selection end cutoff" (Screen.zig:5390)
    // - "Screen: clone selection end cutoff reversed" (Screen.zig:5427)
    // - "Screen: clone contains subset of selection" (Screen.zig:5464)
    // - "Screen: clone contains subset of rectangle selection" (Screen.zig:5501)
}
