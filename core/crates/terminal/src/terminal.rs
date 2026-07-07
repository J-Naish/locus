//! Terminal state and high-level control operations.
//!
//! This is the first Rust slice of Ghostty's `terminal/Terminal.zig`: it wires
//! the parser stream to the screen/page substrate and ports the core print,
//! cursor, margin, tab, scroll, resize, and row-editing operations. Alternate
//! screen, DECCOLM, full erase display/line, reset, and richer OSC state are
//! intentionally left for later terminal phases.

use crate::charsets::{ActiveSlot, Charset, Slots as CharsetSlots};
use crate::color::{DynamicPalette, DynamicRgb, DEFAULT_PALETTE};
use crate::modes::{Mode, ModeState};
use crate::osc::parsers::semantic_prompt::{
    PromptKind, SemanticPrompt as SemanticPromptCommand, SemanticPromptAction,
};
use crate::page::{Cell, CellWide, CloneSource, SemanticContent, SemanticPrompt};
use crate::page_list::Pin;
use crate::point::{Point, Tag};
use crate::screen::{CharsetState, CursorStyle as ScreenCursorStyle, Options as ScreenOptions};
use crate::screen::{PromptRedraw, Resize, SavedCursor, Screen, SemanticClick};
use crate::screen_set::{ScreenKey, ScreenSet};
use crate::size::CellCountInt;
use crate::stream::{CursorStyle, EraseDisplay, EraseLine, Handler, ProtectedMode};
use crate::style::{Style, StyleColor, DEFAULT_STYLE_ID};
use crate::tabstops::{Tabstops, TABSTOP_INTERVAL};
use crate::unicode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Options {
    pub cols: CellCountInt,
    pub rows: CellCountInt,
    pub max_scrollback: usize,
    pub width_px: u32,
    pub height_px: u32,
}

impl Default for Options {
    fn default() -> Self {
        Self {
            cols: 80,
            rows: 24,
            max_scrollback: 0,
            width_px: 0,
            height_px: 0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScrollingRegion {
    pub top: CellCountInt,
    pub bottom: CellCountInt,
    pub left: CellCountInt,
    pub right: CellCountInt,
}

impl ScrollingRegion {
    fn full(cols: CellCountInt, rows: CellCountInt) -> Self {
        Self {
            top: 0,
            bottom: rows.saturating_sub(1),
            left: 0,
            right: cols.saturating_sub(1),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StatusDisplay {
    Main,
    Status,
}

/// DECCOLM target width. Faithful port of ghostty's `DeccolmMode`
/// (Terminal.zig:2875).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeccolmMode {
    Cols80,
    Cols132,
}

/// The xterm alternate-screen mode numbers. Faithful port of ghostty's
/// `SwitchScreenMode` (Terminal.zig:3153).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SwitchScreenMode {
    /// Mode 47: switch screens, copy only the cursor, never erase.
    M47,
    /// Mode 1047: like 47, but clear the alternate screen on exit.
    M1047,
    /// Mode 1049: save the cursor, switch to a cleared alternate screen on
    /// entry, restore the cursor on the primary screen on exit.
    M1049,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Dirty {
    pub screen: bool,
    pub tabs: bool,
    pub title: bool,
    pub palette: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalColors {
    pub palette: DynamicPalette,
    pub foreground: DynamicRgb,
    pub background: DynamicRgb,
    pub cursor: DynamicRgb,
}

impl Default for TerminalColors {
    fn default() -> Self {
        Self {
            palette: DynamicPalette::new(DEFAULT_PALETTE),
            foreground: DynamicRgb::UNSET,
            background: DynamicRgb::UNSET,
            cursor: DynamicRgb::UNSET,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MouseEvent {
    #[default]
    None,
    X10,
    Normal,
    Button,
    Any,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MouseFormat {
    #[default]
    X10,
    Utf8,
    Sgr,
    Urxvt,
    SgrPixels,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TerminalFlags {
    pub mouse_shift_capture: bool,
    pub mouse_event: MouseEvent,
    pub mouse_format: MouseFormat,
    pub modify_other_keys_2: bool,
    pub shell_redraws_prompt: bool,
    pub password_input: bool,
}

#[derive(Debug, Clone)]
pub struct Terminal {
    pub screens: ScreenSet,
    pub status_display: StatusDisplay,
    pub tabstops: Tabstops,
    pub rows: CellCountInt,
    pub cols: CellCountInt,
    pub width_px: u32,
    pub height_px: u32,
    pub scrolling_region: ScrollingRegion,
    pub previous_char: Option<char>,
    pub modes: ModeState,
    pub protected_mode: ProtectedMode,
    pub dirty: Dirty,
    pub colors: TerminalColors,
    pub flags: TerminalFlags,
    pub title: Option<String>,
    pub pwd: Option<String>,
    pub mouse_shape: Option<String>,
}

impl Terminal {
    pub fn new(options: Options) -> Self {
        let screen_options = ScreenOptions {
            cols: options.cols,
            rows: options.rows,
            max_scrollback: options.max_scrollback,
        };
        Self {
            screens: ScreenSet::new(screen_options),
            status_display: StatusDisplay::Main,
            tabstops: Tabstops::new(usize::from(options.cols), TABSTOP_INTERVAL),
            rows: options.rows,
            cols: options.cols,
            width_px: options.width_px,
            height_px: options.height_px,
            scrolling_region: ScrollingRegion::full(options.cols, options.rows),
            previous_char: None,
            modes: ModeState::default(),
            protected_mode: ProtectedMode::Off,
            dirty: Dirty::default(),
            colors: TerminalColors::default(),
            flags: TerminalFlags::default(),
            title: None,
            pwd: None,
            mouse_shape: None,
        }
    }

    pub fn active_screen(&self) -> &Screen {
        self.screens.active()
    }

    pub fn active_screen_mut(&mut self) -> &mut Screen {
        self.screens.active_mut()
    }

    pub fn dump_string(&self) -> String {
        self.active_screen().dump_string_for_tag(Tag::Active)
    }

    /// The plain text of the viewport, joining wrapped lines with newlines.
    /// Mirrors Ghostty's `Terminal.plainString`, which dumps the `.viewport`
    /// region (this differs from the active area only when scrolled back).
    pub fn plain_string(&self) -> String {
        self.active_screen().dump_string_for_tag(Tag::Viewport)
    }

    /// The plain text of the viewport, unwrapping soft-wrapped lines (each
    /// logical line stays on one output line). Mirrors Ghostty's
    /// `Terminal.plainStringUnwrapped`.
    pub fn plain_string_unwrapped(&self) -> String {
        self.active_screen()
            .dump_string_for_tag_unwrapped(Tag::Viewport)
    }

    pub fn set_title(&mut self, title: &str) {
        self.title = if title.is_empty() {
            None
        } else {
            Some(title.to_owned())
        };
        self.dirty.title = true;
    }

    pub fn title(&self) -> Option<&str> {
        self.title.as_deref()
    }

    pub fn set_pwd(&mut self, pwd: &str) {
        self.pwd = if pwd.is_empty() {
            None
        } else {
            Some(pwd.to_owned())
        };
    }

    pub fn pwd(&self) -> Option<&str> {
        self.pwd.as_deref()
    }

    /// Whether the cell at `point` is marked dirty. Testing scaffolding
    /// mirroring Ghostty's `Terminal.isDirty`.
    pub fn is_dirty(&self, point: Point) -> bool {
        self.active_screen()
            .pages
            .pin(point)
            .map(|pin| self.active_screen().pages.pin_is_dirty(pin))
            .unwrap_or(false)
    }

    /// Clear all dirty bits. Testing scaffolding mirroring Ghostty's
    /// `Terminal.clearDirty`.
    pub fn clear_dirty(&mut self) {
        self.active_screen_mut().pages.clear_dirty();
    }

    pub fn scroll_viewport(&mut self, scroll: crate::page_list::Scroll) {
        self.active_screen_mut().scroll(scroll);
    }

    /// The cell at `point`, if any. Mirrors `screens.active.pages.getCell`.
    pub fn get_cell(&self, point: Point) -> Option<Cell> {
        self.active_screen().pages.get_cell(point)
    }

    /// The grapheme code points attached to the cell at `point`, if any.
    /// Mirrors looking up a cell's `lookupGrapheme`.
    pub fn grapheme_at(&self, point: Point) -> Option<Vec<u32>> {
        let pin = self.active_screen().pages.pin(point)?;
        self.active_screen()
            .pages
            .node(pin.node)
            .and_then(|node| node.page.grapheme(pin.y, pin.x))
    }

    /// The number of distinct styles stored in the page holding the cursor.
    /// Mirrors reading `cursor.page_pin.node.data.styles.count()`.
    pub fn cursor_page_style_count(&self) -> usize {
        self.active_screen()
            .cursor_pin()
            .and_then(|pin| self.active_screen().pages.node(pin.node))
            .map(|node| node.page.style_count())
            .unwrap_or(0)
    }

    /// The ref count of the cursor's current style in the page holding the
    /// cursor. Mirrors reading
    /// `cursor.page_pin.node.data.styles.refCount(memory, cursor.style_id)`.
    pub fn cursor_page_style_ref_count(&self) -> u16 {
        let screen = self.active_screen();
        let style_id = screen.cursor.style_id;
        screen
            .cursor_pin()
            .and_then(|pin| screen.pages.node(pin.node))
            .map(|node| node.page.style_ref_count(style_id))
            .unwrap_or(0)
    }

    /// The number of grapheme cells stored in the page holding the cursor.
    /// Mirrors reading `cursor.page_pin.node.data.graphemeCount()`.
    pub fn cursor_page_grapheme_count(&self) -> usize {
        self.active_screen()
            .cursor_pin()
            .and_then(|pin| self.active_screen().pages.node(pin.node))
            .map(|node| node.page.grapheme_count())
            .unwrap_or(0)
    }

    /// The hyperlink id attached to the cell at `point`, if any. Mirrors
    /// looking up a cell's `lookupHyperlink`.
    pub fn hyperlink_id_at(&self, point: Point) -> Option<crate::hyperlink::HyperlinkId> {
        let pin = self.active_screen().pages.pin(point)?;
        self.active_screen()
            .pages
            .node(pin.node)
            .and_then(|node| node.page.hyperlink_id(pin.y, pin.x))
    }

    /// The number of hyperlinked cells stored in the page holding the cell at
    /// `point`. Mirrors reading `list_cell.node.data.hyperlink_map.count()`.
    pub fn hyperlink_count_at(&self, point: Point) -> usize {
        self.active_screen()
            .pages
            .pin(point)
            .and_then(|pin| self.active_screen().pages.node(pin.node))
            .map(|node| node.page.hyperlink_count())
            .unwrap_or(0)
    }

    /// The number of distinct hyperlinks (URIs) stored in the page holding the
    /// cell at `point`. Mirrors reading `list_cell.node.data.hyperlink_set.count()`.
    pub fn hyperlink_set_count_at(&self, point: Point) -> usize {
        self.active_screen()
            .pages
            .pin(point)
            .and_then(|pin| self.active_screen().pages.node(pin.node))
            .map(|node| node.page.hyperlink_set_count())
            .unwrap_or(0)
    }

    /// The row containing the cell at `point`, if any.
    pub fn get_row(&self, point: Point) -> Option<crate::page::Row> {
        let pin = self.active_screen().pages.pin(point)?;
        self.active_screen()
            .pages
            .node(pin.node)
            .map(|node| node.page.row(pin.y))
    }

    /// The physical row capacity of the first page. Mirrors reading
    /// `screens.active.pages.pages.first.?.data.capacity.rows`.
    pub fn first_page_capacity_rows(&self) -> CellCountInt {
        self.active_screen()
            .pages
            .first_node()
            .and_then(|id| self.active_screen().pages.node(id))
            .map(|node| node.page.capacity().rows)
            .unwrap_or(0)
    }

    /// The grapheme byte capacity of the first page. Mirrors reading
    /// `screens.active.pages.pages.first.?.data.capacity.grapheme_bytes`.
    pub fn first_page_capacity_grapheme_bytes(&self) -> crate::size::GraphemeBytesInt {
        self.active_screen()
            .pages
            .first_node()
            .and_then(|id| self.active_screen().pages.node(id))
            .map(|node| node.page.capacity().grapheme_bytes)
            .unwrap_or(0)
    }

    pub fn print_string(&mut self, value: &str) {
        // ghostty: `Terminal.printString` (Terminal.zig:301) maps `\n` to a
        // carriage return followed by a line feed.
        for ch in value.chars() {
            match ch {
                '\n' => {
                    self.carriage_return();
                    self.linefeed();
                }
                '\r' => self.carriage_return(),
                '\t' => self.horizontal_tab(),
                '\u{8}' => self.backspace(),
                _ => self.print(ch),
            }
        }
    }

    pub fn print_repeat(&mut self, count_req: usize) {
        if let Some(c) = self.previous_char {
            let count = count_req.max(1);
            for _ in 0..count {
                self.print(c);
            }
        }
    }

    pub fn print(&mut self, cp: char) {
        // If we're not on the main display, do nothing for now.
        if self.status_display != StatusDisplay::Main {
            return;
        }

        let c = u32::from(cp);

        // Our right margin depends on where our cursor is now.
        let right_limit = self.print_right_limit_exclusive();

        // Perform grapheme clustering if grapheme support is enabled (mode
        // 2027). This is much slower than the normal path so the conditional is
        // ordered least-likely to most-likely to drop out quickly.
        if c > 255
            && self.modes.get(Mode::GraphemeCluster)
            && self.active_screen().cursor.x > 0
            && self.print_grapheme(c, right_limit)
        {
            return;
        }

        // Determine the width of this character. Fast-path byte-sized code
        // points since they're so common. Control characters are filtered
        // before print.
        let width = if c <= 0xFF {
            1usize
        } else {
            usize::from(unicode::props(c).width)
        };

        // Attach zero-width characters to our cell as grapheme data.
        if width == 0 {
            self.print_zero_width(c);
            return;
        }

        // We have a printable character, save it for REP.
        self.previous_char = Some(cp);

        // If we're soft-wrapping, then handle that first.
        if self.active_screen().cursor.pending_wrap && self.modes.get(Mode::Wraparound) {
            self.print_wrap();
        }

        // If we have insert mode enabled then we need to handle that. We only
        // do insert mode if we're not at the end of the line.
        if self.modes.get(Mode::Insert)
            && self.active_screen().cursor.x + (width as CellCountInt) < self.cols
        {
            self.insert_blanks(width);
        }

        match width {
            1 => {
                self.active_screen_mut().cursor_mark_dirty();
                self.active_screen_mut().print_cell(c, CellWide::Narrow);
            }
            2 => {
                if right_limit - self.scrolling_region.left > 1 {
                    // If we don't have space for the wide char, insert spacers
                    // and wrap, then print the wide char as normal.
                    if self.active_screen().cursor.x == right_limit - 1 {
                        // Without wraparound we don't print at all and don't
                        // move the cursor. This is how xterm behaves.
                        if !self.modes.get(Mode::Wraparound) {
                            return;
                        }

                        // We only create a spacer head at the real edge of the
                        // screen. Otherwise clear the space with a narrow to
                        // allow soft wrapping to work correctly.
                        if right_limit == self.cols {
                            // Set wrap to true even though printWrap is called
                            // below: a page resize during printCell would fail
                            // integrity checks otherwise.
                            self.set_cursor_row_wrap(true);
                            self.active_screen_mut().print_cell(0, CellWide::SpacerHead);
                        } else {
                            self.active_screen_mut().print_cell(0, CellWide::Narrow);
                        }
                        self.print_wrap();
                    }

                    self.active_screen_mut().cursor_mark_dirty();
                    self.active_screen_mut().print_cell(c, CellWide::Wide);
                    self.active_screen_mut().cursor_right(1);
                    self.active_screen_mut().print_cell(0, CellWide::SpacerTail);
                } else {
                    // Terminals should never be only 1-wide; guard anyway.
                    self.active_screen_mut().cursor_mark_dirty();
                    self.active_screen_mut().print_cell(0, CellWide::Narrow);
                }
            }
            _ => unreachable!("width must be <= 2"),
        }

        // If we're at the column limit, wrap the next time. Don't move now.
        if self.active_screen().cursor.x == right_limit - 1 {
            self.active_screen_mut().cursor.pending_wrap = true;
            return;
        }

        self.active_screen_mut().cursor_right(1);
    }

    /// Grapheme-clustering branch of [`print`]. Returns `true` if the code point
    /// was consumed as part of a grapheme (the caller should return), `false`
    /// if it turned out to be a grapheme break and normal printing should
    /// proceed. Mirrors the `grapheme:` block of Ghostty's `Terminal.print`.
    fn print_grapheme(&mut self, c: u32, right_limit: CellCountInt) -> bool {
        // Determine the previous cell we're attaching to and the left offset.
        let left = self.grapheme_prev_left(right_limit);
        let Some(cursor_pin) = self.active_screen().cursor_pin() else {
            return false;
        };
        // Resolve the previous cell as an absolute pin (a spacer tail redirects
        // one cell further left to the real content cell). Ghostty holds a raw
        // pointer here; we hold a pin so it stays valid as the cursor moves.
        let mut prev_pin = cursor_pin;
        prev_pin.x = cursor_pin.x.saturating_sub(left);
        let mut prev_cell = self.cell_at_pin(prev_pin);
        if matches!(prev_cell.wide(), CellWide::SpacerTail) {
            prev_pin.x = cursor_pin.x.saturating_sub(left + 1);
            prev_cell = self.cell_at_pin(prev_pin);
        }

        // If the previous cell has no content, this is a new cell and a
        // grapheme break.
        if prev_cell.codepoint() == 0 {
            return false;
        }

        // Replay any existing grapheme code points through the break state,
        // then test the break between the last code point and `c`.
        let mut previous_codepoint = prev_cell.codepoint();
        let mut state = unicode::BreakState::default();
        if prev_cell.has_grapheme() {
            if let Some(cps) = self.grapheme_at_pin(prev_pin) {
                for cp2 in cps {
                    let _ = unicode::grapheme_break(previous_codepoint, cp2, &mut state);
                    previous_codepoint = cp2;
                }
            }
        }
        let grapheme_break = unicode::grapheme_break(previous_codepoint, c, &mut state);

        // If we CAN break, `c` starts a new cell: fall back to normal printing.
        if grapheme_break {
            return false;
        }

        // `c` is part of the grapheme with the previous char.
        let mut desired_wide = DesiredWide::NoChange;
        if c == 0xFE0F || c == 0xFE0E {
            // Emoji variation selectors: VS16 makes wide, VS15 makes narrow. If
            // this is not a valid variation sequence, ignore the char.
            if !unicode::props(previous_codepoint).emoji_vs_base {
                return true;
            }
            desired_wide = if c == 0xFE0F {
                DesiredWide::Wide
            } else {
                DesiredWide::Narrow
            };
        } else if !unicode::props(c).width_zero_in_grapheme {
            // A code point that contributes width means we're at least width 2,
            // since the first code point must be at least width 1.
            desired_wide = DesiredWide::Wide;
        }

        match desired_wide {
            DesiredWide::Wide => {
                if !self.grapheme_transition_wide(&mut prev_pin, left, right_limit) {
                    return true;
                }
            }
            DesiredWide::Narrow => {
                self.grapheme_transition_narrow(prev_pin, left, right_limit);
            }
            DesiredWide::NoChange => {}
        }

        self.active_screen_mut().cursor_mark_dirty();
        self.active_screen_mut().append_grapheme_pin(prev_pin, c);
        true
    }

    /// Read the cell at an absolute pin.
    fn cell_at_pin(&self, pin: Pin) -> Cell {
        self.active_screen()
            .pages
            .node(pin.node)
            .map(|node| node.page.cell(pin.y, pin.x))
            .unwrap_or_default()
    }

    /// Grapheme code points attached to the cell at an absolute pin.
    fn grapheme_at_pin(&self, pin: Pin) -> Option<Vec<u32>> {
        self.active_screen()
            .pages
            .node(pin.node)
            .and_then(|node| node.page.grapheme(pin.y, pin.x))
    }

    /// Set the `wide` class of the cell at an absolute pin.
    fn set_pin_wide(&mut self, pin: Pin, wide: CellWide) {
        if let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) {
            let mut cell = node.page.cell(pin.y, pin.x);
            cell.set_wide(wide);
            node.page.set_cell(pin.y, pin.x, cell);
        }
    }

    /// The `.wide` transition inside [`print_grapheme`]. Repositions onto the
    /// previous cell and makes it wide, handling the wrap-across-boundary case
    /// (including transferring existing grapheme data). Returns `false` if the
    /// character had to be dropped (no wraparound at the edge), `true`
    /// otherwise. On a successful wrap transfer, `prev_left` is reset to `1`
    /// since the previous cell is now directly left of the cursor.
    fn grapheme_transition_wide(
        &mut self,
        prev_pin: &mut Pin,
        left: CellCountInt,
        right_limit: CellCountInt,
    ) -> bool {
        // If prev cell is already wide, nothing to do.
        if matches!(self.cell_at_pin(*prev_pin).wide(), CellWide::Wide) {
            return true;
        }

        // Move the cursor back to the previous cell. After this the cursor is
        // positioned on `prev_pin`.
        self.active_screen_mut().cursor_left(usize::from(left));

        if self.active_screen().cursor.x == right_limit - 1 {
            if !self.modes.get(Mode::Wraparound) {
                return false;
            }

            // Writing a spacer_head before printWrap can trigger integrity
            // violations, so mark the wrap first if we're wrapping the row.
            let row_wrap = right_limit == self.cols;
            if row_wrap {
                self.set_cursor_row_wrap(true);
            }

            let prev_cell = self.cell_at_pin(*prev_pin);
            let prev_cp = prev_cell.codepoint();

            if prev_cell.has_grapheme() {
                // Like printCell but without clearing the grapheme data so we
                // can move it. Convert the old cell to spacer_head/narrow.
                self.set_cursor_cell_wide_and_clear_codepoint(if row_wrap {
                    CellWide::SpacerHead
                } else {
                    CellWide::Narrow
                });

                self.print_wrap();
                self.active_screen_mut().print_cell(prev_cp, CellWide::Wide);

                self.transfer_grapheme_across_wrap(right_limit);
            } else {
                self.active_screen_mut().print_cell(
                    0,
                    if row_wrap {
                        CellWide::SpacerHead
                    } else {
                        CellWide::Narrow
                    },
                );
                self.print_wrap();
                self.active_screen_mut().print_cell(prev_cp, CellWide::Wide);
            }

            // The previous cell is now the (new) cell under the cursor.
            if let Some(pin) = self.active_screen().cursor_pin() {
                *prev_pin = pin;
            }
        } else {
            // Cursor is now on the previous cell; make it wide in place.
            self.set_pin_wide(*prev_pin, CellWide::Wide);
        }

        // Write our spacer, since the previous cell is now wide.
        self.active_screen_mut().cursor_right(1);
        self.active_screen_mut().print_cell(0, CellWide::SpacerTail);

        // Move the cursor again so we're beyond our spacer.
        if self.active_screen().cursor.x == right_limit - 1 {
            self.active_screen_mut().cursor.pending_wrap = true;
        } else {
            self.active_screen_mut().cursor_right(1);
        }
        true
    }

    /// The `.narrow` transition inside [`print_grapheme`]. Makes the previous
    /// cell narrow, removes its spacer tail, and back-tracks the cursor so we
    /// don't leave a trailing space.
    fn grapheme_transition_narrow(
        &mut self,
        prev_pin: Pin,
        left: CellCountInt,
        right_limit: CellCountInt,
    ) {
        // Only fires if the previous cell is currently wide.
        if !matches!(self.cell_at_pin(prev_pin).wide(), CellWide::Wide) {
            return;
        }
        self.set_pin_wide(prev_pin, CellWide::Narrow);

        // Remove the wide spacer tail (one cell right of the wide char). This is
        // `cursorCellLeft(prev.left - 1)` in Ghostty; the cursor has not moved.
        if let Some(cursor_pin) = self.active_screen().cursor_pin() {
            let mut tail = cursor_pin;
            tail.x = cursor_pin.x.saturating_sub(left.saturating_sub(1));
            self.set_pin_wide(tail, CellWide::Narrow);
        }

        // Back-track the cursor so we don't leave an extra space.
        if self.active_screen().cursor.x == right_limit - 1 {
            self.active_screen_mut().cursor.pending_wrap = false;
        } else {
            self.active_screen_mut().cursor_left(1);
        }
    }

    /// Transfer grapheme code points from the old (pre-wrap) previous cell to
    /// the new wide cell after a wrap, matching the `transfer_graphemes` block
    /// in Ghostty's `print`.
    fn transfer_grapheme_across_wrap(&mut self, right_limit: CellCountInt) {
        let Some(new_pin) = self.active_screen().cursor_pin() else {
            return;
        };
        let Some(mut old_pin) = self.active_screen().pages.pin_up(new_pin, 1) else {
            return;
        };
        old_pin.x = right_limit - 1;

        let screen = self.active_screen_mut();
        if new_pin.node == old_pin.node {
            if let Some(node) = screen.pages.node_mut(new_pin.node) {
                node.page
                    .move_grapheme(old_pin.y, old_pin.x, new_pin.y, new_pin.x);
                node.page.update_row_grapheme_flag(old_pin.y);
            }
        } else {
            let cps = screen
                .pages
                .node(old_pin.node)
                .map(|node| node.page.grapheme(old_pin.y, old_pin.x))
                .unwrap_or(None);
            if let Some(cps) = cps {
                for cp in cps {
                    screen.append_grapheme_pin(new_pin, cp);
                }
            }
            if let Some(node) = screen.pages.node_mut(old_pin.node) {
                node.page.clear_grapheme(old_pin.y, old_pin.x);
                node.page.update_row_grapheme_flag(old_pin.y);
            }
        }
    }

    /// Zero-width branch of [`print`]. Attaches the code point to the previous
    /// cell as grapheme data, matching the `width == 0` block of Ghostty's
    /// `Terminal.print`.
    fn print_zero_width(&mut self, c: u32) {
        // With grapheme clustering enabled we don't blindly attach zero-width
        // characters; ignore instead.
        if self.modes.get(Mode::GraphemeCluster) {
            return;
        }

        // With wraparound and a pending wrap, the char we're attaching to is
        // still under the cursor. Otherwise it's the cell to the left.
        let left: CellCountInt =
            if self.modes.get(Mode::Wraparound) && self.active_screen().cursor.pending_wrap {
                0
            } else {
                1
            };

        // At cell zero with no pending wrap this is malformed input; ignore.
        if self.active_screen().cursor.x == 0 && left == 1 {
            return;
        }

        // Find our previous cell, skipping over a spacer tail.
        let (prev_left, prev_cell) = {
            let screen = self.active_screen();
            let immediate = screen.cursor_cell_left(left).unwrap_or_default();
            if matches!(immediate.wide(), CellWide::SpacerTail) {
                (
                    left + 1,
                    screen.cursor_cell_left(left + 1).unwrap_or_default(),
                )
            } else {
                (left, immediate)
            }
        };

        // If the previous cell has no text, ignore the zero-width character.
        if !prev_cell.has_text() {
            return;
        }

        // If this is an emoji variation selector, prev must be an emoji.
        if (c == 0xFE0F || c == 0xFE0E)
            && !matches!(
                unicode::props(prev_cell.codepoint()).grapheme_break,
                unicode::GraphemeBreak::ExtendedPictographic
            )
        {
            return;
        }

        self.append_grapheme_left_of_cursor(prev_left, c);
    }

    /// Compute the `left` offset used to find the previous cell in the grapheme
    /// path, matching the `left:` block in Ghostty's `print`.
    fn grapheme_prev_left(&self, right_limit: CellCountInt) -> CellCountInt {
        if self.modes.get(Mode::Wraparound) {
            return CellCountInt::from(!self.active_screen().cursor.pending_wrap);
        }
        if self.active_screen().cursor.x != right_limit - 1 {
            return 1;
        }
        let cp = self
            .active_screen()
            .cursor_cell()
            .map(|c| c.codepoint())
            .unwrap_or(0);
        CellCountInt::from(cp == 0)
    }

    pub fn linefeed(&mut self) {
        self.index();
        if self.modes.get(Mode::Linefeed) {
            self.carriage_return();
        }
    }

    pub fn index(&mut self) {
        // Unset pending wrap state.
        self.active_screen_mut().cursor.pending_wrap = false;

        // Perform the actual line movement (scroll or cursor down).
        let y = self.active_screen().cursor.y;
        if y == self.scrolling_region.bottom && self.cursor_inside_horizontal_region() {
            self.scroll_up(1);
        } else {
            self.cursor_down(1);
        }

        // We handle our cursor semantic prompt state AFTER doing the scrolling,
        // because we may need to apply it to the new row. Mirrors Ghostty's
        // `index` deferred block.
        if self.active_screen().cursor.semantic_content != SemanticContent::Output {
            // Always reset any semantic content clear-eol state.
            if self.active_screen().cursor.semantic_content_clear_eol {
                self.active_screen_mut().cursor.semantic_content = SemanticContent::Output;
                self.active_screen_mut().cursor.semantic_content_clear_eol = false;
            } else {
                // If we aren't clearing our state at EOL and we're not output,
                // mark the new row as a prompt continuation. This works around
                // shells that don't send OSC 133 k=s sequences for
                // continuations. A later `semanticPrompt` may correct a false
                // positive if the shell then outputs command content.
                self.set_cursor_row_semantic_prompt(SemanticPrompt::PromptContinuation);
            }
        }
    }

    pub fn reverse_index(&mut self) {
        let y = self.active_screen().cursor.y;
        if y == self.scrolling_region.top && self.cursor_inside_horizontal_region() {
            self.scroll_down(1);
        } else {
            self.cursor_up(1);
        }
    }

    pub fn next_line(&mut self) {
        self.index();
        self.carriage_return();
    }

    pub fn carriage_return(&mut self) {
        let target = self.carriage_return_column();
        self.active_screen_mut().cursor_horizontal_absolute(target);
    }

    pub fn backspace(&mut self) {
        self.cursor_left(1);
    }

    pub fn set_cursor_pos(&mut self, row: u16, col: u16) {
        let row = row.saturating_sub(1);
        let col = col.saturating_sub(1);
        let (top, bottom, left, right) = if self.modes.get(Mode::Origin) {
            (
                self.scrolling_region.top,
                self.scrolling_region.bottom,
                self.scrolling_region.left,
                self.scrolling_region.right,
            )
        } else {
            (
                0,
                self.rows.saturating_sub(1),
                0,
                self.cols.saturating_sub(1),
            )
        };
        let y = top.saturating_add(row as CellCountInt).min(bottom);
        let x = left.saturating_add(col as CellCountInt).min(right);
        self.active_screen_mut().cursor_absolute(x, y);
    }

    pub fn cursor_up(&mut self, count: usize) {
        let y = self.active_screen().cursor.y;
        let top = if self.cursor_inside_vertical_region() {
            self.scrolling_region.top
        } else {
            0
        };
        let target = y.saturating_sub(count as CellCountInt).max(top);
        let x = self.active_screen().cursor.x;
        self.active_screen_mut().cursor_absolute(x, target);
    }

    pub fn cursor_down(&mut self, count: usize) {
        let y = self.active_screen().cursor.y;
        let bottom = if self.cursor_inside_vertical_region() {
            self.scrolling_region.bottom
        } else {
            self.rows.saturating_sub(1)
        };
        let target = y.saturating_add(count as CellCountInt).min(bottom);
        let x = self.active_screen().cursor.x;
        self.active_screen_mut().cursor_absolute(x, target);
    }

    pub fn cursor_right(&mut self, count: usize) {
        let x = self.active_screen().cursor.x;
        let right = if self.cursor_inside_horizontal_region() {
            self.scrolling_region.right
        } else {
            self.cols.saturating_sub(1)
        };
        let target = x.saturating_add(count as CellCountInt).min(right);
        let y = self.active_screen().cursor.y;
        self.active_screen_mut().cursor_absolute(target, y);
    }

    pub fn cursor_left(&mut self, count_req: usize) {
        // ghostty: `Terminal.cursorLeft` (Terminal.zig:1012)
        // Wrapping behavior depends on various terminal modes.
        let wrap_mode = if !self.modes.get(Mode::Wraparound) {
            CursorLeftWrap::None
        } else if self.modes.get(Mode::ReverseWrapExtended) {
            CursorLeftWrap::ReverseExtended
        } else if self.modes.get(Mode::ReverseWrap) {
            CursorLeftWrap::Reverse
        } else {
            CursorLeftWrap::None
        };

        let mut count = count_req.max(1) as CellCountInt;

        // No-wrap mode: the fast, typical path. Move left and clear wrap.
        if wrap_mode == CursorLeftWrap::None {
            let x = self.active_screen().cursor.x;
            self.active_screen_mut()
                .cursor_left(usize::from(count.min(x)));
            self.active_screen_mut().cursor.pending_wrap = false;
            return;
        }

        // A pending wrap in either reverse mode consumes one step (xterm).
        if self.active_screen().cursor.pending_wrap {
            count = count.saturating_sub(1);
            self.active_screen_mut().cursor.pending_wrap = false;
        }

        let top = self.scrolling_region.top;
        let bottom = self.scrolling_region.bottom;
        let right_margin = self.scrolling_region.right;
        let left_margin = if self.active_screen().cursor.x < self.scrolling_region.left {
            0
        } else {
            self.scrolling_region.left
        };

        // Edge cases when the cursor is already on the left margin.
        if self.active_screen().cursor.x == left_margin && wrap_mode == CursorLeftWrap::Reverse {
            // In reverse mode, if we're already before the top margin then we
            // set the cursor to the top-left and we're done.
            if self.active_screen().cursor.y <= top {
                self.active_screen_mut().cursor_absolute(left_margin, top);
                return;
            }
        }

        loop {
            // We can move at most to the left margin.
            let max = self.active_screen().cursor.x - left_margin;
            let amount = max.min(count);
            count -= amount;
            self.active_screen_mut().cursor_left(usize::from(amount));

            // If we have no more to move, we're done.
            if count == 0 {
                break;
            }

            // If we are at the top, then we are done (unless extended).
            if self.active_screen().cursor.y == top {
                if wrap_mode != CursorLeftWrap::ReverseExtended {
                    break;
                }
                self.active_screen_mut()
                    .cursor_absolute(right_margin, bottom);
                count -= 1;
                continue;
            }

            // UNDEFINED TERMINAL BEHAVIOR: xterm crashes here. We instead wrap
            // up to (0, 0) and stop.
            if self.active_screen().cursor.y == 0 {
                debug_assert_eq!(self.active_screen().cursor.x, left_margin);
                break;
            }

            // In non-extended reverse mode, only continue onto a previous line
            // if that line was itself soft-wrapped.
            if wrap_mode != CursorLeftWrap::ReverseExtended {
                let cx = self.active_screen().cursor.x;
                let cy = self.active_screen().cursor.y;
                let prev_wrap = self
                    .get_row(Point::active(cx, u32::from(cy - 1)))
                    .map(|row| row.wrap())
                    .unwrap_or(false);
                if !prev_wrap {
                    break;
                }
            }

            let y = self.active_screen().cursor.y - 1;
            self.active_screen_mut().cursor_absolute(right_margin, y);
            count -= 1;
        }
    }

    pub fn set_top_and_bottom_margin(&mut self, top: u16, bottom: u16) {
        let top = top.max(1);
        let bottom = if bottom == 0 { self.rows } else { bottom };
        if top >= bottom || bottom > self.rows {
            return;
        }
        self.scrolling_region.top = top - 1;
        self.scrolling_region.bottom = bottom - 1;
        self.set_cursor_pos(1, 1);
    }

    pub fn set_left_and_right_margin(&mut self, left: u16, right: u16) {
        if !self.modes.get(Mode::EnableLeftAndRightMargin) {
            return;
        }
        let left = left.max(1);
        let right = if right == 0 { self.cols } else { right };
        if left >= right || right > self.cols {
            return;
        }
        self.scrolling_region.left = left - 1;
        self.scrolling_region.right = right - 1;
        self.set_cursor_pos(1, 1);
    }

    pub fn scroll_up(&mut self, count: usize) {
        // Preserve our x/y/pending_wrap to restore (Ghostty uses a `defer`).
        let old_x = self.active_screen().cursor.x;
        let old_y = self.active_screen().cursor.y;
        let old_wrap = self.active_screen().cursor.pending_wrap;

        // If our scroll region is at the top and we have no left/right margins
        // then we move the scrolled out text into the scrollback.
        if self.scrolling_region.top == 0
            && self.scrolling_region.left == 0
            && self.scrolling_region.right == self.cols.saturating_sub(1)
        {
            // Clamp count to the scroll region height.
            let region_height = usize::from(self.scrolling_region.bottom) + 1;
            let adjusted_count = count.min(region_height);
            // Move our cursor to the bottom of the scroll region so we can use
            // cursorScrollAbove to create scrollback.
            let bottom = self.scrolling_region.bottom;
            self.active_screen_mut().cursor_absolute(0, bottom);
            for _ in 0..adjusted_count {
                self.active_screen_mut().cursor_scroll_above();
            }
        } else {
            // Move to the top of the scroll region and delete lines.
            let left = self.scrolling_region.left;
            let top = self.scrolling_region.top;
            self.active_screen_mut().cursor_absolute(left, top);
            self.delete_lines(count);
        }

        // Restore the cursor position and pending wrap.
        self.active_screen_mut().cursor_absolute(old_x, old_y);
        self.active_screen_mut().cursor.pending_wrap = old_wrap;
        self.dirty.screen = true;
    }

    pub fn scroll_down(&mut self, count: usize) {
        // Preserve our x/y/pending_wrap to restore (Ghostty uses a `defer`).
        let old_x = self.active_screen().cursor.x;
        let old_y = self.active_screen().cursor.y;
        let old_wrap = self.active_screen().cursor.pending_wrap;

        // Move to the top of the scroll region and insert lines.
        let left = self.scrolling_region.left;
        let top = self.scrolling_region.top;
        self.active_screen_mut().cursor_absolute(left, top);
        self.insert_lines(count);

        // Restore the cursor position and pending wrap.
        self.active_screen_mut().cursor_absolute(old_x, old_y);
        self.active_screen_mut().cursor.pending_wrap = old_wrap;
        self.dirty.screen = true;
    }

    pub fn insert_lines(&mut self, count: usize) {
        // Rare, but happens.
        if count == 0 {
            return;
        }
        // If the cursor is outside the scroll region we do nothing.
        if !self.cursor_inside_region() {
            return;
        }

        // At the end we need to return the cursor to the row it started on and
        // always unset pending wrap (Ghostty uses a `defer`).
        let start_y = self.active_screen().cursor.y;

        let left_right = self.scrolling_region.left > 0
            || self.scrolling_region.right < self.cols.saturating_sub(1);

        // Remaining rows from our cursor to the bottom of the scroll region.
        let rem = self.scrolling_region.bottom - start_y + 1;
        let adjusted_count = (count.min(usize::from(rem))) as CellCountInt;

        // Start at the bottom row of the affected range and walk up.
        let start_pin = self
            .active_screen()
            .pages
            .pin(Point::active(0, u32::from(start_y + rem - 1)));
        let mut cur_pin = start_pin;
        let mut y = rem;
        while y > 0 {
            let Some(pin) = cur_pin else { break };
            if y > adjusted_count {
                // This row receives shifted content from `adjusted_count`
                // rows above it.
                let off_pin = self
                    .active_screen()
                    .pages
                    .pin_up(pin, usize::from(adjusted_count));
                if let Some(off_pin) = off_pin {
                    self.shift_row(off_pin, pin, left_right);
                }
            } else {
                // This row is past the shifted range, so clear it.
                self.clear_shifted_row(pin);
            }
            self.mark_pin_dirty(pin);
            y -= 1;
            cur_pin = self.active_screen().pages.pin_up(pin, 1);
        }

        let left = self.scrolling_region.left;
        self.active_screen_mut().cursor_absolute(left, start_y);
        self.active_screen_mut().cursor.pending_wrap = false;
        self.dirty.screen = true;
    }

    pub fn delete_lines(&mut self, count: usize) {
        // Rare, but happens.
        if count == 0 {
            return;
        }
        // If the cursor is outside the scroll region we do nothing.
        if !self.cursor_inside_region() {
            return;
        }

        // At the end we need to return the cursor to the row it started on and
        // always unset pending wrap (Ghostty uses a `defer`).
        let start_y = self.active_screen().cursor.y;

        let left_right = self.scrolling_region.left > 0
            || self.scrolling_region.right < self.cols.saturating_sub(1);

        // Remaining rows from our cursor to the bottom of the scroll region.
        let rem = self.scrolling_region.bottom - start_y + 1;
        let adjusted_count = (count.min(usize::from(rem))) as CellCountInt;

        // Start at the cursor row and walk down.
        let start_pin = self
            .active_screen()
            .pages
            .pin(Point::active(0, u32::from(start_y)));
        let mut cur_pin = start_pin;
        let mut y = 0;
        while y < rem {
            let Some(pin) = cur_pin else { break };
            if y < rem - adjusted_count {
                // This row receives shifted content from `adjusted_count`
                // rows below it.
                let off_pin = self
                    .active_screen()
                    .pages
                    .pin_down(pin, usize::from(adjusted_count));
                if let Some(off_pin) = off_pin {
                    self.shift_row(off_pin, pin, left_right);
                }
            } else {
                // This row is out of bounds after the shift, so clear it.
                self.clear_shifted_row(pin);
            }
            self.mark_pin_dirty(pin);
            y += 1;
            cur_pin = self.active_screen().pages.pin_down(pin, 1);
        }

        let left = self.scrolling_region.left;
        self.active_screen_mut().cursor_absolute(left, start_y);
        self.active_screen_mut().cursor.pending_wrap = false;
        self.dirty.screen = true;
    }

    /// ICH: insert `count` blank cells at the cursor, shifting existing content
    /// right within the current row (bounded by the scroll region's right
    /// margin). ghostty: `Terminal.insertBlanks` (Terminal.zig:2240).
    pub fn insert_blanks(&mut self, count: usize) {
        // Unset pending wrap state without wrapping. Note: this purposely
        // happens BEFORE the scroll region check below, because that's what
        // xterm does.
        self.active_screen_mut().cursor.pending_wrap = false;

        // A zero count does nothing. The rest of this function assumes count > 0.
        if count == 0 {
            return;
        }

        // If our cursor is outside the margins then do nothing. We DO reset
        // wrap state still so this must remain below the above logic.
        let x = self.active_screen().cursor.x;
        if x < self.scrolling_region.left || x > self.scrolling_region.right {
            return;
        }

        let y = u32::from(self.active_screen().cursor.y);

        // If our X is a wide spacer tail then we need to erase the previous
        // cell too so we don't split a multi-cell character.
        if self.cell_wide_at(y, x) == CellWide::SpacerTail {
            debug_assert!(x > 0);
            self.active_screen_mut().clear_cells(
                Point::active(x - 1, y),
                Point::active(x, y),
                false,
            );
        }

        // Remaining cols from our cursor to the right margin.
        let rem = self.scrolling_region.right - x + 1;

        // If the cell at the right margin is wide, its spacer tail is outside
        // the scroll region and would be orphaned by either the shift or the
        // clear. Clean up both halves up front.
        let right_x = x + (rem - 1);
        if self.cell_wide_at(y, right_x) == CellWide::Wide {
            self.active_screen_mut().clear_cells(
                Point::active(right_x, y),
                Point::active(right_x + 1, y),
                false,
            );
        }

        // We can only insert blanks up to our remaining cols.
        let adjusted_count = (count as CellCountInt).min(rem);

        // The number of cols at the right of the scroll region that will NOT be
        // blank, so we need to shift them right.
        let scroll_amount = rem - adjusted_count;
        if scroll_amount > 0 {
            // If our last cell we're shifting is wide, clear it to be empty so
            // we don't split the multi-cell char.
            let end_x = x + (scroll_amount - 1);
            if self.cell_wide_at(y, end_x) == CellWide::Wide {
                self.active_screen_mut().clear_cells(
                    Point::active(end_x, y),
                    Point::active(end_x + 1, y),
                    false,
                );
            }

            // We work backwards so we don't overwrite data.
            let mut sx = x + (scroll_amount - 1);
            loop {
                self.swap_row_cells(y, sx, sx + adjusted_count);
                if sx == x {
                    break;
                }
                sx -= 1;
            }
        }

        // Insert blanks. The blanks preserve the background color.
        self.active_screen_mut().clear_cells(
            Point::active(x, y),
            Point::active(x + adjusted_count - 1, y),
            false,
        );

        // Our row is always dirty.
        self.active_screen_mut().cursor_mark_dirty();
        self.dirty.screen = true;
    }

    /// DCH: remove `count` characters at the cursor, shifting the remaining
    /// characters left and filling the right margin with blanks. Does not move
    /// the cursor. ghostty: `Terminal.deleteChars` (Terminal.zig:2341).
    pub fn delete_chars(&mut self, count_req: usize) {
        if count_req == 0 {
            return;
        }

        // If our cursor is outside the margins then do nothing.
        let x = self.active_screen().cursor.x;
        if x < self.scrolling_region.left || x > self.scrolling_region.right {
            return;
        }

        let y = u32::from(self.active_screen().cursor.y);

        // Remaining cols from our cursor to the right margin.
        let rem = self.scrolling_region.right - x + 1;

        // We can only delete up to our remaining cols.
        let count = (count_req as CellCountInt).min(rem);

        let right_boundary = self.scrolling_region.right + 1;
        self.active_screen_mut()
            .split_cell_boundary(Point::active(x, y));
        self.active_screen_mut()
            .split_cell_boundary(Point::active(x + count, y));
        self.active_screen_mut()
            .split_cell_boundary(Point::active(right_boundary, y));

        // The number of cols at the right of the scroll region that will NOT be
        // blank, so we need to shift them left.
        let scroll_amount = rem - count;
        let mut sx = x;
        if scroll_amount > 0 {
            let right_x = x + (scroll_amount - 1);
            while sx <= right_x {
                self.swap_row_cells(y, sx + count, sx);
                sx += 1;
            }
        }

        // Insert blanks. The blanks preserve the background color.
        let clear_end = sx + (rem - scroll_amount);
        self.active_screen_mut().clear_cells(
            Point::active(sx, y),
            Point::active(clear_end - 1, y),
            false,
        );

        // Our row's soft-wrap is always reset.
        self.active_screen_mut().cursor_reset_wrap();

        // Our row is always dirty.
        self.active_screen_mut().cursor_mark_dirty();
        self.dirty.screen = true;
    }

    /// The wide-flag of the cell at active `(x, y)`, or `Narrow` if out of range.
    fn cell_wide_at(&self, y: u32, x: CellCountInt) -> CellWide {
        self.get_cell(Point::active(x, y))
            .map(|c| c.wide())
            .unwrap_or(CellWide::Narrow)
    }

    /// Swap two cells in the cursor's active row, preserving graphemes and
    /// hyperlinks. Mirrors Ghostty's `page.swapCells`.
    fn swap_row_cells(&mut self, y: u32, a: CellCountInt, b: CellCountInt) {
        let Some(pin) = self.active_screen().pages.pin(Point::active(a, y)) else {
            return;
        };
        if let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) {
            let _ = node.page.swap_cells(pin.y, a, b);
        }
    }

    pub fn erase_chars(&mut self, count_req: usize) {
        let y = self.active_screen().cursor.y;
        let x = self.active_screen().cursor.x;

        // ECH ignores the scroll-region right margin and operates over the full
        // screen width.
        let remaining = self.cols - x;
        let mut end = remaining.min(count_req.max(1) as CellCountInt);

        // If our last cell is a wide char then we need to also clear the cell
        // beyond it since we can't just split a wide char.
        if end != remaining {
            let last_x = x + end - 1;
            if self
                .get_cell(Point::active(last_x, u32::from(y)))
                .map(|c| c.wide() == CellWide::Wide)
                .unwrap_or(false)
            {
                end += 1;
            }
        }

        // Handle any boundary conditions on the edges of the erased area.
        self.active_screen_mut()
            .split_cell_boundary(Point::active(x, u32::from(y)));
        self.active_screen_mut()
            .split_cell_boundary(Point::active(x + end, u32::from(y)));

        // Reset our row's soft-wrap and mark the cursor row dirty.
        self.active_screen_mut().cursor_reset_wrap();
        self.active_screen_mut().cursor_mark_dirty();

        // Clear the cells [x, x + end). If we never had a protection mode, or
        // the last protection mode was not ISO, use the fast path.
        let protected = self.protected_mode == ProtectedMode::Iso;
        self.active_screen_mut().clear_cells(
            Point::active(x, u32::from(y)),
            Point::active(x + end - 1, u32::from(y)),
            protected,
        );
        self.dirty.screen = true;
    }

    /// Erase the line.
    pub fn erase_line(&mut self, mode: EraseLine, protected_req: bool) {
        let y = u32::from(self.active_screen().cursor.y);

        // Get our start/end columns depending on the mode. `end` here is the
        // exclusive right bound, matching Ghostty's `cells[start..end]` slice.
        let (start, end) = match mode {
            EraseLine::Right => {
                let mut x = self.active_screen().cursor.x;
                // If our X is a wide spacer tail then we need to erase the
                // previous cell too so we don't split a multi-cell character.
                let is_spacer_tail = self
                    .active_screen()
                    .cursor_cell()
                    .map(|c| c.wide() == CellWide::SpacerTail)
                    .unwrap_or(false);
                if x > 0 && is_spacer_tail {
                    x -= 1;
                }
                // Reset our row's soft-wrap.
                self.active_screen_mut().cursor_reset_wrap();
                (x, self.cols)
            }
            EraseLine::Left => {
                let mut x = self.active_screen().cursor.x;
                // If our x is a wide char we need to delete the tail too.
                let is_wide = self
                    .active_screen()
                    .cursor_cell()
                    .map(|c| c.wide() == CellWide::Wide)
                    .unwrap_or(false);
                if is_wide {
                    x += 1;
                }
                (0, x + 1)
            }
            // Note that it seems like complete should reset the soft-wrap
            // state of the line but in xterm it does not.
            EraseLine::Complete => (0, self.cols),
            // Unimplemented modes: log-and-return in Ghostty; we return.
            EraseLine::RightUnlessPendingWrap => return,
        };

        // All modes will clear the pending wrap state and we know we have
        // a valid mode at this point.
        self.active_screen_mut().cursor.pending_wrap = false;

        // We always mark our row as dirty.
        self.active_screen_mut().cursor_mark_dirty();

        // Nothing to clear if the range is empty.
        if end <= start {
            return;
        }

        // We respect protected attributes if explicitly requested (probably
        // a DECSEL sequence) or if our last protected mode was ISO even if it's
        // not currently set.
        let protected = self.protected_mode == ProtectedMode::Iso || protected_req;

        self.active_screen_mut().clear_cells(
            Point::active(start, y),
            Point::active(end - 1, y),
            protected,
        );
    }

    /// Erase the display.
    pub fn erase_display(&mut self, mode: EraseDisplay, protected_req: bool) {
        // We respect protected attributes if explicitly requested (probably
        // a DECSEL sequence) or if our last protected mode was ISO even if it's
        // not currently set.
        let protected = self.protected_mode == ProtectedMode::Iso || protected_req;

        match mode {
            EraseDisplay::ScrollComplete => {
                self.active_screen_mut().scroll_clear();
                // Unsets pending wrap state.
                self.active_screen_mut().cursor.pending_wrap = false;
            }

            EraseDisplay::Complete => {
                // If we're on the primary screen and our last non-empty row is
                // a prompt, then we do a scroll_complete instead. This is a
                // heuristic to get the generally desirable behavior that ^L
                // at a prompt scrolls the screen contents prior to clearing.
                // Most shells send `ESC [ H ESC [ 2 J` so we can't just check
                // our current cursor position. See #905
                if self.screens.active_key() == ScreenKey::Primary && self.active_at_prompt() {
                    self.active_screen_mut().scroll_clear();
                }

                // All active area.
                self.active_screen_mut()
                    .clear_rows(Point::active(0, 0), None, protected);

                // Unsets pending wrap state.
                self.active_screen_mut().cursor.pending_wrap = false;

                // Cleared screen dirty bit.
                self.dirty.screen = true;
            }

            EraseDisplay::Below => {
                // All lines to the right (including the cursor).
                self.erase_line(EraseLine::Right, protected_req);

                // All lines below.
                let cursor_y = u32::from(self.active_screen().cursor.y);
                if cursor_y + 1 < u32::from(self.rows) {
                    self.active_screen_mut().clear_rows(
                        Point::active(0, cursor_y + 1),
                        None,
                        protected,
                    );
                }

                // Unsets pending wrap state. Should be done by erase_line.
                debug_assert!(!self.active_screen().cursor.pending_wrap);
            }

            EraseDisplay::Above => {
                // Erase to the left (including the cursor).
                self.erase_line(EraseLine::Left, protected_req);

                // All lines above.
                let cursor_y = u32::from(self.active_screen().cursor.y);
                if cursor_y > 0 {
                    self.active_screen_mut().clear_rows(
                        Point::active(0, 0),
                        Some(Point::active(0, cursor_y - 1)),
                        protected,
                    );
                }

                // Unsets pending wrap state.
                debug_assert!(!self.active_screen().cursor.pending_wrap);
            }

            EraseDisplay::Scrollback => self.active_screen_mut().erase_history(None),
        }
    }

    /// Returns whether the last non-empty row of the active area is a prompt
    /// or prompt continuation. Used by the `erase_display(.complete)` `^L`
    /// scroll heuristic (Ghostty's inline `at_prompt` block).
    fn active_at_prompt(&self) -> bool {
        let screen = self.active_screen();
        // Ghostty walks the active area bottom-to-top and breaks on the first
        // row it reaches: a prompt/continuation means we're at a prompt, a
        // `.none` (command output) means we're not. Because every row carries
        // one of these three semantic values, the bottom-most active row always
        // decides the outcome, so we only need to inspect it.
        let Some(bottom_right) = screen.pages.get_bottom_right(Tag::Active) else {
            return false;
        };
        let semantic = screen
            .pages
            .node(bottom_right.node)
            .map(|node| node.page.row(bottom_right.y).semantic_prompt())
            .unwrap_or(SemanticPrompt::None);
        match semantic {
            // At a prompt or input area, so we are at a prompt.
            SemanticPrompt::Prompt | SemanticPrompt::PromptContinuation => true,
            // Command output, so we are most certainly not at a prompt.
            SemanticPrompt::None => false,
        }
    }

    /// Writes the SGR representation of the current cursor style into `buf`,
    /// used for DECRPSS responses. The response always starts with `0`.
    /// See <https://vt100.net/docs/vt510-rm/DECRPSS>.
    pub fn print_attributes(&self) -> String {
        let mut out = String::new();
        // The SGR response always starts with a 0.
        out.push('0');

        let pen = &self.active_screen().cursor.style;

        if pen.flags.bold {
            out.push_str(";1");
        }
        if pen.flags.faint {
            out.push_str(";2");
        }
        if pen.flags.italic {
            out.push_str(";3");
        }
        if pen.flags.underline != crate::sgr::Underline::None {
            out.push_str(";4");
        }
        if pen.flags.blink {
            out.push_str(";5");
        }
        if pen.flags.inverse {
            out.push_str(";7");
        }
        if pen.flags.invisible {
            out.push_str(";8");
        }
        if pen.flags.strikethrough {
            out.push_str(";9");
        }

        Self::write_sgr_color(&mut out, pen.fg_color, 3, 9, 38);
        Self::write_sgr_color(&mut out, pen.bg_color, 4, 10, 48);

        out
    }

    /// Appends the SGR encoding of a single foreground/background color to
    /// `out`. `low` is the base for palette indices < 8 (3 for fg, 4 for bg),
    /// `high` is the base for palette indices in 8..16 (9 for fg, 10 for bg),
    /// and `ext` is the extended-color introducer (38 for fg, 48 for bg).
    fn write_sgr_color(out: &mut String, color: StyleColor, low: u8, high: u8, ext: u8) {
        use std::fmt::Write;
        match color {
            StyleColor::None => {}
            StyleColor::Palette(idx) => {
                if idx >= 16 {
                    let _ = write!(out, ";{ext}:5:{idx}");
                } else if idx >= 8 {
                    let _ = write!(out, ";{high}{}", idx - 8);
                } else {
                    let _ = write!(out, ";{low}{idx}");
                }
            }
            StyleColor::Rgb(rgb) => {
                let _ = write!(out, ";{ext}:2::{}:{}:{}", rgb.r, rgb.g, rgb.b);
            }
        }
    }

    pub fn horizontal_tab(&mut self) {
        // Mirrors Ghostty's `horizontalTab`: repeatedly move the cursor right
        // (an in-row move that does not dirty the row) until we land on a
        // tabstop or reach the right margin. We check the tabstop at the
        // *new* cursor position so a space is written at the tabstop unless
        // we're at the end (the loop condition).
        while self.active_screen().cursor.x < self.scrolling_region.right {
            self.active_screen_mut().cursor_right(1);
            if self
                .tabstops
                .get(usize::from(self.active_screen().cursor.x))
            {
                return;
            }
        }
    }

    pub fn horizontal_tab_back(&mut self, count: usize) {
        // With origin mode enabled, our leftmost limit is the left margin.
        let left_limit = if self.modes.get(Mode::Origin) {
            self.scrolling_region.left
        } else {
            0
        };
        for _ in 0..count {
            loop {
                // If we're already at the edge of the screen, we're done.
                if self.active_screen().cursor.x <= left_limit {
                    return;
                }
                // Move the cursor left, stopping on the first tabstop.
                self.active_screen_mut().cursor_left(1);
                if self
                    .tabstops
                    .get(usize::from(self.active_screen().cursor.x))
                {
                    break;
                }
            }
        }
    }

    pub fn tab_set(&mut self) {
        self.tabstops
            .set(usize::from(self.active_screen().cursor.x));
        self.dirty.tabs = true;
    }

    pub fn tab_clear_current(&mut self) {
        self.tabstops
            .unset(usize::from(self.active_screen().cursor.x));
        self.dirty.tabs = true;
    }

    pub fn tab_clear_all(&mut self) {
        self.tabstops = Tabstops::new(usize::from(self.cols), 0);
        self.dirty.tabs = true;
    }

    pub fn tab_reset(&mut self) {
        self.tabstops.reset(TABSTOP_INTERVAL);
        self.dirty.tabs = true;
    }

    pub fn set_protected_mode(&mut self, mode: ProtectedMode) {
        // ghostty: `Terminal.setProtectedMode` (Terminal.zig:1170)
        match mode {
            ProtectedMode::Off => {
                // screen.protected_mode is NEVER reset to `.off` because logic
                // such as eraseChars depends on knowing the _most recent_ mode.
                self.active_screen_mut().cursor.protected = false;
            }
            ProtectedMode::Iso | ProtectedMode::Dec => {
                self.active_screen_mut().cursor.protected = true;
                self.protected_mode = mode;
            }
        }
    }

    /// DECALN: fill the entire screen with `E` for alignment testing.
    /// ghostty: `Terminal.decaln` (Terminal.zig:2655).
    pub fn decaln(&mut self) {
        // Clear our stylistic attributes, preserving only the fg/bg colors.
        // This is the only thing that can fail so Ghostty does it first so it
        // can be undone; our `manual_style_update` is infallible.
        {
            let cursor = &mut self.active_screen_mut().cursor;
            cursor.style = Style {
                fg_color: cursor.style.fg_color,
                bg_color: cursor.style.bg_color,
                ..Style::default()
            };
        }
        self.active_screen_mut().manual_style_update();

        // Reset margins, also sets cursor to top-left.
        self.scrolling_region = ScrollingRegion::full(self.cols, self.rows);

        // Origin mode is disabled.
        self.modes.set(Mode::Origin, false);

        // Move our cursor to the top-left.
        self.set_cursor_pos(1, 1);

        // Use clearRows instead of eraseDisplay because we must NOT respect
        // protected attributes here.
        self.active_screen_mut()
            .clear_rows(Point::active(0, 0), None, false);

        // Fill with Es by moving the cursor down row by row.
        let last_row = self.rows.saturating_sub(1);
        loop {
            let style_id = self.active_screen().cursor.style_id;
            if let Some(pin) = self.active_screen().cursor_pin() {
                if let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) {
                    let cols = node.page.size().cols;
                    let mut e_cell = Cell::new('E');
                    e_cell.set_style_id(style_id);
                    // DECALN does not respect protected state (verified w/ xterm).
                    e_cell.set_protected(false);
                    for x in 0..cols {
                        node.page.set_cell(pin.y, x, e_cell);
                    }
                    // If we have a ref-counted style, increase its count.
                    if style_id != DEFAULT_STYLE_ID {
                        node.page.use_style_multiple(style_id, cols);
                        let mut row = node.page.row(pin.y);
                        row.set_styled(true);
                        node.page.set_row(pin.y, row);
                    }
                }
            }
            self.active_screen_mut().cursor_mark_dirty();
            if self.active_screen().cursor.y == last_row {
                break;
            }
            self.active_screen_mut().cursor_down(1);
        }

        // Reset the cursor to the top-left.
        self.set_cursor_pos(1, 1);
        self.dirty.screen = true;
    }

    /// DECSC: save cursor position and further state. Save state is per-screen;
    /// re-saving overwrites the prior save for the active screen.
    /// ghostty: `Terminal.saveCursor` (Terminal.zig:1116).
    pub fn save_cursor(&mut self) {
        let origin = self.modes.get(Mode::Origin);
        let screen = self.active_screen_mut();
        screen.saved_cursor = Some(SavedCursor {
            x: screen.cursor.x,
            y: screen.cursor.y,
            style: screen.cursor.style,
            protected: screen.cursor.protected,
            pending_wrap: screen.cursor.pending_wrap,
            origin,
            charset: screen.charset,
        });
    }

    /// DECRC: restore cursor position and other state. If no save was done
    /// before, values reset to their initial defaults.
    /// ghostty: `Terminal.restoreCursor` (Terminal.zig:1132).
    pub fn restore_cursor(&mut self) {
        let saved = self
            .active_screen()
            .saved_cursor
            .clone()
            .unwrap_or_else(|| SavedCursor {
                x: 0,
                y: 0,
                style: Style::default(),
                protected: false,
                pending_wrap: false,
                origin: false,
                charset: CharsetState::default(),
            });

        // Set the style first because it can fail. Regardless of the error, we
        // revert to an unstyled cursor: it is more important that the restore
        // succeeds in other attributes because terminals have no way to
        // communicate failure back.
        {
            let screen = self.active_screen_mut();
            screen.cursor.style = saved.style;
            if !screen.try_manual_style_update() {
                screen.cursor.style = Style::default();
                screen.manual_style_update();
            }
        }

        self.modes.set(Mode::Origin, saved.origin);

        let cols = self.cols;
        let rows = self.rows;
        let screen = self.active_screen_mut();
        screen.charset = saved.charset;
        screen.cursor.protected = saved.protected;
        // `cursor_absolute` clears `pending_wrap`, so restore it afterward to
        // preserve the saved wrap-pending state (matches Ghostty, whose
        // `cursorAbsolute` does not touch pending_wrap).
        screen.cursor_absolute(
            saved.x.min(cols.saturating_sub(1)),
            saved.y.min(rows.saturating_sub(1)),
        );
        screen.cursor.pending_wrap = saved.pending_wrap;
    }

    /// Resize the terminal to the given dimensions. The primary screen reflows
    /// when wraparound mode is enabled; the alternate screen never reflows. Any
    /// custom scroll margins are lost. ghostty: `Terminal.resize`
    /// (Terminal.zig:2915).
    pub fn resize(&mut self, cols: CellCountInt, rows: CellCountInt) {
        // If our cols/rows didn't change then we're done.
        if self.cols == cols && self.rows == rows {
            return;
        }

        // Resize our tabstops. Tab stops do not preserve custom stops across a
        // column change; they reset to the default every-8 pattern.
        if self.cols != cols {
            self.tabstops = Tabstops::new(usize::from(cols), TABSTOP_INTERVAL);
        }

        // Resize primary screen, which supports reflow.
        let reflow = self.modes.get(Mode::Wraparound);
        if let Some(primary) = self.screens.get_mut(ScreenKey::Primary) {
            let _ = primary.resize(Resize {
                cols,
                rows,
                reflow,
                prompt_redraw: PromptRedraw::True,
            });
        }

        // Alternate screen, if it exists, doesn't reflow.
        if let Some(alt) = self.screens.get_mut(ScreenKey::Alternate) {
            let _ = alt.resize(Resize {
                cols,
                rows,
                reflow: false,
                prompt_redraw: PromptRedraw::False,
            });
        }

        // Whenever we resize we just mark it as a screen clear.
        self.dirty.screen = true;

        // Set our size.
        self.cols = cols;
        self.rows = rows;

        // Reset the scrolling region.
        self.scrolling_region = ScrollingRegion::full(cols, rows);
    }

    /// DECCOLM: fix the terminal width at 80 or 132 columns. Does nothing
    /// unless DEC mode 40 (`enable_mode_3`) is set. Faithful port of ghostty's
    /// `deccolm` (Terminal.zig:2887).
    pub fn deccolm(&mut self, mode: DeccolmMode) {
        // If DEC mode 40 isn't enabled this is ignored, and we clear the
        // 132-column mode flag so a bare set-mode can't stick.
        if !self.modes.get(Mode::EnableMode3) {
            self.modes.set(Mode::Column132, false);
            return;
        }

        // Enable it.
        self.modes
            .set(Mode::Column132, mode == DeccolmMode::Cols132);

        // Resize to the requested width, keeping the current row count.
        let cols = match mode {
            DeccolmMode::Cols132 => 132,
            DeccolmMode::Cols80 => 80,
        };
        self.resize(cols, self.rows);

        // Erase the display and home the cursor.
        self.erase_display(EraseDisplay::Complete, false);
        self.set_cursor_pos(1, 1);
    }

    /// Full reset (RIS). Faithful port of ghostty's `fullReset`
    /// (Terminal.zig:3184).
    pub fn full_reset(&mut self) {
        // Ensure we're back on the primary screen and drop the alternate.
        self.screens.switch_to(ScreenKey::Primary);
        self.screens.remove(ScreenKey::Alternate);

        // Reset the active (primary) screen.
        self.active_screen_mut().reset();

        // Reset our basic state.
        self.modes.reset();
        self.previous_char = None;
        self.pwd = None;
        self.title = None;
        self.status_display = StatusDisplay::Main;
        self.protected_mode = ProtectedMode::Off;
        self.flags = TerminalFlags::default();
        self.mouse_shape = None;
        self.tabstops = Tabstops::new(usize::from(self.cols), TABSTOP_INTERVAL);
        self.scrolling_region = ScrollingRegion::full(self.cols, self.rows);

        // Always mark dirty so we redraw everything.
        self.dirty = Dirty::default();
        self.dirty.screen = true;
    }

    /// Switch to the given screen type. This does NOT clear the screen or copy
    /// the cursor; callers handle those. Returns whether the screen actually
    /// changed. Faithful port of ghostty's `switchScreen` (Terminal.zig:3009).
    pub fn switch_screen(&mut self, key: ScreenKey) -> bool {
        // Already on the requested screen: nothing to do.
        if self.screens.active_key() == key {
            return false;
        }

        // We always end hyperlink state on the OLD screen before switching.
        self.active_screen_mut().end_hyperlink();

        // Carry the charset state across (it follows the terminal, not the
        // screen), and ensure the target screen exists.
        let charset = self.active_screen().charset;
        {
            let new = self.screens.get_init(key);
            debug_assert_eq!(new.cursor.hyperlink_id, 0);
            new.charset = charset;
            new.clear_selection();
        }

        // A screen switch always forces a full redraw.
        self.dirty.screen = true;

        // Finalize the switch.
        self.screens.switch_to(key);
        true
    }

    /// Switch screens via a mode number (47/1047/1049), handling the
    /// mode-specific clear/save/restore behavior. Faithful port of ghostty's
    /// `switchScreenMode` (Terminal.zig:3088).
    pub fn switch_screen_mode(&mut self, mode: SwitchScreenMode, enabled: bool) {
        match mode {
            SwitchScreenMode::M47 => {}
            // Disabling 1047 while on the alternate screen clears it.
            SwitchScreenMode::M1047 => {
                if !enabled && self.screens.active_key() == ScreenKey::Alternate {
                    self.erase_display(EraseDisplay::Complete, false);
                }
            }
            // 1049 unconditionally saves the cursor when enabling.
            SwitchScreenMode::M1049 => {
                if enabled {
                    self.save_cursor();
                }
            }
        }

        // Switch to the destination screen first.
        let to = if enabled {
            ScreenKey::Alternate
        } else {
            ScreenKey::Primary
        };
        let changed = self.switch_screen(to);

        match mode {
            // 47/1047 copy the cursor (without hyperlink) when the screen
            // actually changed.
            SwitchScreenMode::M47 | SwitchScreenMode::M1047 => {
                if changed {
                    self.copy_cursor_from_other_screen(to);
                }
            }
            SwitchScreenMode::M1049 => {
                if enabled {
                    debug_assert_eq!(self.screens.active_key(), ScreenKey::Alternate);
                    self.erase_display(EraseDisplay::Complete, false);
                    // Entering the alt screen copies the primary cursor.
                    if changed {
                        self.copy_cursor_from_other_screen(to);
                    }
                } else {
                    debug_assert_eq!(self.screens.active_key(), ScreenKey::Primary);
                    self.restore_cursor();
                }
            }
        }
    }

    /// Copy the cursor from the non-active screen onto the now-active `to`
    /// screen (without the hyperlink). Mirrors ghostty's `cursorCopy` call in
    /// `switchScreenMode`; the source is always the screen we just left.
    fn copy_cursor_from_other_screen(&mut self, to: ScreenKey) {
        let from = match to {
            ScreenKey::Primary => ScreenKey::Alternate,
            ScreenKey::Alternate => ScreenKey::Primary,
        };
        let Some(source) = self.screens.get(from).map(|screen| screen.cursor_copy()) else {
            return;
        };
        self.active_screen_mut().cursor_copy_from(&source, false);
    }

    /// Returns true if the cursor is currently at a shell prompt. Faithful port
    /// of ghostty's `cursorIsAtPrompt` (Terminal.zig).
    pub fn cursor_is_at_prompt(&self) -> bool {
        // The secondary screen is never a prompt.
        if self.screens.active_key() == ScreenKey::Alternate {
            return false;
        }

        // If our page row is a prompt then we're always at a prompt.
        if self
            .active_screen()
            .cursor_row_semantic_prompt()
            .map(|prompt| prompt != SemanticPrompt::None)
            .unwrap_or(false)
        {
            return true;
        }

        // Otherwise defer to the cursor's own semantic content.
        match self.active_screen().cursor.semantic_content {
            SemanticContent::Input | SemanticContent::Prompt => true,
            SemanticContent::Output => false,
        }
    }

    /// Set the charset into the given slot.
    pub fn configure_charset(&mut self, slot: CharsetSlots, set: Charset) {
        self.active_screen_mut().charset.set(slot, set);
    }

    /// Invoke the charset in `slot` into the active slot. If `single` is true,
    /// then this will only be invoked for a single character.
    pub fn invoke_charset(&mut self, active: ActiveSlot, slot: CharsetSlots, single: bool) {
        if single {
            debug_assert_eq!(active, ActiveSlot::Gl);
            self.active_screen_mut().charset.single_shift = Some(slot);
            return;
        }
        match active {
            ActiveSlot::Gl => self.active_screen_mut().charset.gl = slot,
            ActiveSlot::Gr => self.active_screen_mut().charset.gr = slot,
        }
    }

    /// Perform a semantic prompt command (OSC 133). Faithful port of
    /// ghostty's `semanticPrompt` (Terminal.zig:1181).
    pub fn semantic_prompt(&mut self, cmd: SemanticPromptCommand<'_>) {
        match cmd.action {
            SemanticPromptAction::FreshLine => self.semantic_prompt_fresh_line(),
            SemanticPromptAction::FreshLineNewPrompt | SemanticPromptAction::NewCommand => {
                // "First do a fresh-line." `NewCommand` degrades to the `A`
                // action because we don't track explicit command IDs.
                self.semantic_prompt_fresh_line();

                // "Subsequent text is a prompt string (as if followed by
                // OSC 133;P;k=i)."
                let kind = cmd.read_prompt_kind().unwrap_or(PromptKind::Initial);
                self.active_screen_mut().cursor_set_semantic_prompt(kind);

                if let Some(redraw) = cmd.read_redraw() {
                    self.flags.shell_redraws_prompt = matches!(
                        redraw,
                        crate::osc::parsers::semantic_prompt::PromptRedraw::True
                            | crate::osc::parsers::semantic_prompt::PromptRedraw::Last
                    );
                }

                // click_events takes priority over cl.
                if let Some(events) = cmd.read_click_events() {
                    self.active_screen_mut().semantic_prompt.click =
                        SemanticClick::ClickEvents(events);
                } else if let Some(cl) = cmd.read_cl() {
                    self.active_screen_mut().semantic_prompt.click = SemanticClick::Cl(cl);
                }
            }
            SemanticPromptAction::PromptStart => {
                let kind = cmd.read_prompt_kind().unwrap_or(PromptKind::Initial);
                self.active_screen_mut().cursor_set_semantic_prompt(kind);
            }
            SemanticPromptAction::EndPromptStartInput => {
                self.active_screen_mut()
                    .cursor_set_semantic_content(SemanticContent::Input);
            }
            SemanticPromptAction::EndPromptStartInputTerminateEol => {
                self.active_screen_mut()
                    .cursor_set_semantic_input_clear_eol();
            }
            SemanticPromptAction::EndInputStartOutput => {
                self.active_screen_mut()
                    .cursor_set_semantic_content(SemanticContent::Output);
                // Fish heuristic: a prompt row with the cursor at column zero is
                // assumed to be overwriting the prompt, so un-mark it.
                let at_col_zero = self.active_screen().cursor.x == 0;
                let row_is_prompt = self
                    .active_screen()
                    .cursor_row_semantic_prompt()
                    .map(|prompt| prompt != SemanticPrompt::None)
                    .unwrap_or(false);
                if row_is_prompt && at_col_zero {
                    self.active_screen_mut()
                        .set_cursor_row_semantic_prompt(SemanticPrompt::None);
                }
            }
            SemanticPromptAction::EndCommand => {
                self.active_screen_mut()
                    .cursor_set_semantic_content(SemanticContent::Output);
            }
        }
    }

    /// OSC 133;L — move to a fresh line if not already at the left margin.
    fn semantic_prompt_fresh_line(&mut self) {
        let cursor_x = self.active_screen().cursor.x;
        let left_margin = if cursor_x < self.scrolling_region.left {
            0
        } else {
            self.scrolling_region.left
        };
        if cursor_x == left_margin {
            return;
        }
        self.carriage_return();
        self.index();
    }

    pub fn set_mode(&mut self, mode: Mode) {
        self.modes.set(mode, true);
    }

    pub fn reset_mode(&mut self, mode: Mode) {
        self.modes.set(mode, false);
    }

    fn print_wrap(&mut self) {
        // We only mark that we soft-wrapped if we're at the edge of our full
        // screen. We don't mark the row as wrapped if we're in the middle due
        // to a right margin.
        let mark_wrap = self.active_screen().cursor.x == self.cols.saturating_sub(1);
        if mark_wrap {
            self.set_cursor_row_wrap(true);
        }

        // Capture the semantic prompt state so we can extend it to the next
        // line. We do this before index() because it may modify memory.
        let old_semantic = self.active_screen().cursor.semantic_content;

        // Move to the next line.
        self.index();
        let left = self.scrolling_region.left;
        self.active_screen_mut().cursor_horizontal_absolute(left);

        // Extend a prompt onto the continuation row.
        if matches!(old_semantic, SemanticContent::Prompt) {
            self.set_cursor_row_semantic_prompt(SemanticPrompt::PromptContinuation);
        }

        if mark_wrap {
            self.set_cursor_row_wrap_continuation(true);
        }
    }

    /// Set `row.wrap` on the cursor's row.
    fn set_cursor_row_wrap(&mut self, value: bool) {
        if let Some(pin) = self.active_screen().cursor_pin() {
            if let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) {
                let mut row = node.page.row(pin.y);
                row.set_wrap(value);
                node.page.set_row(pin.y, row);
            }
        }
    }

    /// Set `row.wrap_continuation` on the cursor's row.
    fn set_cursor_row_wrap_continuation(&mut self, value: bool) {
        if let Some(pin) = self.active_screen().cursor_pin() {
            if let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) {
                let mut row = node.page.row(pin.y);
                row.set_wrap_continuation(value);
                node.page.set_row(pin.y, row);
            }
        }
    }

    /// Set `row.semantic_prompt` on the cursor's row.
    fn set_cursor_row_semantic_prompt(&mut self, prompt: SemanticPrompt) {
        if let Some(pin) = self.active_screen().cursor_pin() {
            if let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) {
                let mut row = node.page.row(pin.y);
                row.set_semantic_prompt(prompt);
                node.page.set_row(pin.y, row);
            }
        }
    }

    /// Delegate to the active screen's `set_cursor_cell_wide_and_clear_codepoint`.
    fn set_cursor_cell_wide_and_clear_codepoint(&mut self, wide: CellWide) {
        self.active_screen_mut()
            .set_cursor_cell_wide_and_clear_codepoint(wide);
    }

    /// Append a grapheme code point to the cell `n` columns left of the cursor.
    fn append_grapheme_left_of_cursor(&mut self, n: CellCountInt, codepoint: u32) {
        self.active_screen_mut()
            .append_grapheme_cursor_left(n, codepoint);
    }

    fn print_right_limit_exclusive(&self) -> CellCountInt {
        let cursor_x = self.active_screen().cursor.x;
        if cursor_x > self.scrolling_region.right {
            self.cols
        } else {
            self.scrolling_region.right.saturating_add(1)
        }
    }

    fn carriage_return_column(&self) -> CellCountInt {
        let cursor_x = self.active_screen().cursor.x;
        if self.modes.get(Mode::Origin) || cursor_x >= self.scrolling_region.left {
            self.scrolling_region.left
        } else {
            0
        }
    }

    fn cursor_inside_vertical_region(&self) -> bool {
        let y = self.active_screen().cursor.y;
        y >= self.scrolling_region.top && y <= self.scrolling_region.bottom
    }

    fn cursor_inside_horizontal_region(&self) -> bool {
        let x = self.active_screen().cursor.x;
        x >= self.scrolling_region.left && x <= self.scrolling_region.right
    }

    fn cursor_inside_region(&self) -> bool {
        self.cursor_inside_vertical_region() && self.cursor_inside_horizontal_region()
    }

    /// Prepare a row for being shifted by an insert/delete lines operation.
    /// Mirrors Ghostty's `rowWillBeShifted`: clears stale spacer heads and any
    /// wide chars straddling the scroll region's left/right boundaries.
    fn row_will_be_shifted(&mut self, pin: Pin) {
        let left = self.scrolling_region.left;
        let right = self.scrolling_region.right;
        let touches_edge = right == self.cols.saturating_sub(1) || left < 2;
        let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) else {
            return;
        };
        let page = &mut node.page;
        let cols = page.capacity().cols;

        // If our scrolling region includes the rightmost column, or the left
        // margin is within the two leftmost columns, turn any spacer head on
        // the last physical cell into a normal empty cell.
        if touches_edge {
            let end = cols.saturating_sub(1);
            if page.cell(pin.y, end).wide() == CellWide::SpacerHead {
                let mut cell = page.cell(pin.y, end);
                cell.set_wide(CellWide::Narrow);
                page.set_cell(pin.y, end, cell);
            }
        }

        // If the leftmost cell of the region is a spacer tail, clear the wide
        // char to its left that would be split by the move.
        if left < cols && page.cell(pin.y, left).wide() == CellWide::SpacerTail && left > 0 {
            let wide_x = left - 1;
            if page.cell(pin.y, wide_x).has_grapheme() {
                // clear_grapheme updates the row grapheme flag internally.
                page.clear_grapheme(pin.y, wide_x);
            }
            let mut wide_cell = page.cell(pin.y, wide_x);
            wide_cell.set_codepoint(0);
            wide_cell.set_wide(CellWide::Narrow);
            page.set_cell(pin.y, wide_x, wide_cell);
            let mut left_cell = page.cell(pin.y, left);
            left_cell.set_wide(CellWide::Narrow);
            page.set_cell(pin.y, left, left_cell);
        }

        // If the rightmost cell of the region is a wide char, clear it and its
        // spacer tail (which sits just outside the region).
        if right < cols && page.cell(pin.y, right).wide() == CellWide::Wide {
            let tail_x = right + 1;
            if page.cell(pin.y, right).has_grapheme() {
                // clear_grapheme updates the row grapheme flag internally.
                page.clear_grapheme(pin.y, right);
            }
            let mut right_cell = page.cell(pin.y, right);
            right_cell.set_codepoint(0);
            right_cell.set_wide(CellWide::Narrow);
            page.set_cell(pin.y, right, right_cell);
            if tail_x < cols {
                let mut tail_cell = page.cell(pin.y, tail_x);
                tail_cell.set_wide(CellWide::Narrow);
                page.set_cell(pin.y, tail_x, tail_cell);
            }
        }
    }

    /// Shift the row at `src_pin` into `dst_pin`, bounded to the scroll region's
    /// columns. Mirrors the shifted-row branch of Ghostty's insert/deleteLines.
    fn shift_row(&mut self, src_pin: Pin, dst_pin: Pin, left_right: bool) {
        self.row_will_be_shifted(dst_pin);
        self.row_will_be_shifted(src_pin);

        // A full-width shift never preserves wrap state.
        if !left_right {
            self.clear_row_wrap_flags(src_pin);
            self.clear_row_wrap_flags(dst_pin);
        }

        let left = self.scrolling_region.left;
        let right = self.scrolling_region.right;
        let right_exclusive = right.saturating_add(1);
        let len = right - left + 1;

        if src_pin.node == dst_pin.node {
            // Same page: move the cells in place, carrying grapheme and
            // hyperlink data without duplicating set entries.
            if let Some(node) = self.active_screen_mut().pages.node_mut(dst_pin.node) {
                node.page.move_cells(src_pin.y, left, dst_pin.y, left, len);
            }
            return;
        }

        // Different pages: clone the bounded column range across.
        let source_page = self
            .active_screen()
            .pages
            .node(src_pin.node)
            .map(|node| node.page.clone());
        let Some(source_page) = source_page else {
            return;
        };
        if let Some(node) = self.active_screen_mut().pages.node_mut(dst_pin.node) {
            node.page.clone_partial_row_from(
                CloneSource::Other(&source_page),
                dst_pin.y,
                src_pin.y,
                left,
                right_exclusive,
            );
        }
    }

    /// Clear the scroll-region columns of the row at `pin`, filling with the
    /// current blank cell. Mirrors the cleared-row branch of insert/deleteLines
    /// (which calls `clearCells`).
    fn clear_shifted_row(&mut self, pin: Pin) {
        self.row_will_be_shifted(pin);
        let left = self.scrolling_region.left;
        let right = self.scrolling_region.right;
        let fill = self.active_screen().blank_cell();
        if let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) {
            node.page.fill_cells(pin.y, left, right + 1, fill);
        }
    }

    /// Clear `wrap` and `wrap_continuation` on the row at `pin`.
    fn clear_row_wrap_flags(&mut self, pin: Pin) {
        if let Some(node) = self.active_screen_mut().pages.node_mut(pin.node) {
            let mut row = node.page.row(pin.y);
            row.set_wrap(false);
            row.set_wrap_continuation(false);
            node.page.set_row(pin.y, row);
        }
    }

    /// Mark the row at `pin` dirty.
    fn mark_pin_dirty(&mut self, pin: Pin) {
        self.active_screen_mut().pages.mark_dirty(pin);
    }
}

/// Width transition requested while extending a grapheme cluster in
/// [`Terminal::print_grapheme`]. Mirrors the anonymous enum in Ghostty's print.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum DesiredWide {
    NoChange,
    Wide,
    Narrow,
}

/// Wrapping behavior for [`Terminal::cursor_left`]. Mirrors the anonymous
/// `WrapMode` enum in Ghostty's `cursorLeft`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CursorLeftWrap {
    None,
    Reverse,
    ReverseExtended,
}

impl Default for Terminal {
    fn default() -> Self {
        Self::new(Options::default())
    }
}

impl Handler for Terminal {
    fn print(&mut self, cp: char) {
        Terminal::print(self, cp);
    }

    fn print_repeat(&mut self, count: usize) {
        self.print_repeat(count);
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            b'\n' | 0x0B | 0x0C => self.linefeed(),
            b'\r' => self.carriage_return(),
            0x08 => self.backspace(),
            b'\t' => self.horizontal_tab(),
            _ => {}
        }
    }

    fn index(&mut self) {
        self.index();
    }

    fn reverse_index(&mut self) {
        self.reverse_index();
    }

    fn next_line(&mut self) {
        self.next_line();
    }

    fn cursor_up(&mut self, value: u16) {
        self.cursor_up(usize::from(value));
    }

    fn cursor_down(&mut self, value: u16) {
        self.cursor_down(usize::from(value));
    }

    fn cursor_right(&mut self, value: u16) {
        self.cursor_right(usize::from(value));
    }

    fn cursor_left(&mut self, value: u16) {
        self.cursor_left(usize::from(value));
    }

    fn cursor_col(&mut self, col: u16) {
        let row = self.active_screen().cursor.y.saturating_add(1);
        self.set_cursor_pos(row, col);
    }

    fn cursor_row(&mut self, row: u16) {
        let col = self.active_screen().cursor.x.saturating_add(1);
        self.set_cursor_pos(row, col);
    }

    fn cursor_col_relative(&mut self, value: u16) {
        self.cursor_right(usize::from(value));
    }

    fn cursor_row_relative(&mut self, value: u16) {
        self.cursor_down(usize::from(value));
    }

    fn cursor_position(&mut self, row: u16, col: u16) {
        self.set_cursor_pos(row, col);
    }

    fn insert_blanks(&mut self, value: usize) {
        self.insert_blanks(value);
    }

    fn delete_chars(&mut self, value: usize) {
        self.delete_chars(value);
    }

    fn erase_chars(&mut self, value: usize) {
        self.erase_chars(value);
    }

    fn insert_lines(&mut self, value: usize) {
        self.insert_lines(value);
    }

    fn delete_lines(&mut self, value: usize) {
        self.delete_lines(value);
    }

    fn scroll_up(&mut self, value: usize) {
        self.scroll_up(value);
    }

    fn scroll_down(&mut self, value: usize) {
        self.scroll_down(value);
    }

    fn erase_display(&mut self, mode: EraseDisplay, protected: bool) {
        self.erase_display(mode, protected);
    }

    fn erase_line(&mut self, mode: EraseLine, protected: bool) {
        self.erase_line(mode, protected);
    }

    fn set_attribute(&mut self, attribute: crate::sgr::Attribute<'_>) {
        self.active_screen_mut().set_attribute(attribute);
    }

    fn set_mode(&mut self, mode: Mode) {
        self.set_mode(mode);
    }

    fn reset_mode(&mut self, mode: Mode) {
        self.reset_mode(mode);
    }

    fn save_mode(&mut self, mode: Mode) {
        self.modes.save(mode);
    }

    fn restore_mode(&mut self, mode: Mode) {
        let _ = self.modes.restore(mode);
    }

    fn protected_mode(&mut self, mode: ProtectedMode) {
        self.set_protected_mode(mode);
    }

    fn cursor_style(&mut self, style: CursorStyle) {
        self.active_screen_mut().cursor.cursor_style = match style {
            CursorStyle::Default | CursorStyle::BlinkingBlock | CursorStyle::SteadyBlock => {
                ScreenCursorStyle::Block
            }
            CursorStyle::BlinkingUnderline | CursorStyle::SteadyUnderline => {
                ScreenCursorStyle::Underline
            }
            CursorStyle::BlinkingBar | CursorStyle::SteadyBar => ScreenCursorStyle::Bar,
        };
    }

    fn mouse_shift_capture(&mut self, enabled: bool) {
        self.flags.mouse_shift_capture = enabled;
    }

    fn left_and_right_margin(&mut self, left: u16, right: u16) {
        self.set_left_and_right_margin(left, right);
    }

    fn top_and_bottom_margin(&mut self, top: u16, bottom: u16) {
        self.set_top_and_bottom_margin(top, bottom);
    }

    fn restore_cursor(&mut self) {
        self.restore_cursor();
    }

    fn save_cursor(&mut self) {
        self.save_cursor();
    }

    fn tab_set(&mut self) {
        self.tab_set();
    }

    fn horizontal_tab(&mut self, count: usize) {
        for _ in 0..count {
            self.horizontal_tab();
        }
    }

    fn horizontal_tab_back(&mut self, count: usize) {
        self.horizontal_tab_back(count);
    }

    fn tab_clear_current(&mut self) {
        self.tab_clear_current();
    }

    fn tab_clear_all(&mut self) {
        self.tab_clear_all();
    }

    fn tab_reset(&mut self) {
        self.tab_reset();
    }

    fn configure_charset(&mut self, slot: CharsetSlots, charset: Charset) {
        self.configure_charset(slot, charset);
    }

    fn invoke_charset(&mut self, active: ActiveSlot, slot: CharsetSlots, single: bool) {
        self.invoke_charset(active, slot, single);
    }

    fn decaln(&mut self) {
        self.decaln();
    }

    fn full_reset(&mut self) {
        self.full_reset();
    }

    fn start_hyperlink(&mut self, id: Option<&[u8]>, uri: &[u8]) {
        self.active_screen_mut().start_hyperlink(id, uri);
    }

    fn end_hyperlink(&mut self) {
        self.active_screen_mut().end_hyperlink();
    }

    fn semantic_prompt(&mut self, cmd: crate::osc::SemanticPrompt<'_>) {
        self.semantic_prompt(cmd);
    }

    fn mouse_shape(&mut self, shape: &[u8]) {
        self.mouse_shape = std::str::from_utf8(shape).ok().map(ToOwned::to_owned);
    }

    fn window_title(&mut self, title: &str) {
        self.set_title(title);
    }

    fn window_icon(&mut self, title: &str) {
        self.window_title(title);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::Rgb;
    use crate::osc::parsers::semantic_prompt::{PromptClick, PromptClickEvents};
    use crate::page::{CellContentTag, CellWide};
    use crate::page_list::Scroll;
    use crate::sgr::Attribute;
    use crate::stream::Stream;

    fn terminal(cols: CellCountInt, rows: CellCountInt) -> Terminal {
        Terminal::new(Options {
            cols,
            rows,
            max_scrollback: 1024 * 1024,
            width_px: 0,
            height_px: 0,
        })
    }

    fn terminal_opts(cols: CellCountInt, rows: CellCountInt, max_scrollback: usize) -> Terminal {
        Terminal::new(Options {
            cols,
            rows,
            max_scrollback,
            width_px: 0,
            height_px: 0,
        })
    }

    /// Print a raw code point (Ghostty's `print` takes a `u21`).
    fn print_cp(t: &mut Terminal, cp: u32) {
        t.print(char::from_u32(cp).expect("valid code point"));
    }

    fn screen_point(x: CellCountInt, y: u32) -> Point {
        Point::screen(x, y)
    }

    fn cell(t: &Terminal, x: CellCountInt, y: u32) -> Cell {
        t.get_cell(screen_point(x, y)).expect("cell exists")
    }

    fn active_cell(t: &Terminal, x: CellCountInt, y: u32) -> Cell {
        t.get_cell(Point::active(x, y)).expect("active cell exists")
    }

    fn viewport_cell(t: &Terminal, x: CellCountInt, y: u32) -> Cell {
        t.get_cell(Point::viewport(x, y))
            .expect("viewport cell exists")
    }

    #[test]
    fn input_with_no_control_characters() {
        // ghostty: "Terminal: input with no control characters" (Terminal.zig:3230)
        let mut t = terminal(40, 40);
        for c in "hello".chars() {
            t.print(c);
        }
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 5);
        assert_eq!(t.plain_string(), "hello");
        assert!(t.is_dirty(screen_point(5, 0)));
        assert!(!t.is_dirty(screen_point(5, 1)));
    }

    #[test]
    fn input_with_basic_wraparound() {
        // ghostty: "Terminal: input with basic wraparound" (Terminal.zig:3250)
        let mut t = terminal(5, 40);
        for c in "helloworldabc12".chars() {
            t.print(c);
        }
        assert_eq!(t.active_screen().cursor.y, 2);
        assert_eq!(t.active_screen().cursor.x, 4);
        assert!(t.active_screen().cursor.pending_wrap);
        assert_eq!(t.plain_string(), "hello\nworld\nabc12");
    }

    #[test]
    fn input_with_basic_wraparound_dirty() {
        // ghostty: "Terminal: input with basic wraparound dirty" (Terminal.zig:3267)
        let mut t = terminal(5, 40);
        for c in "hello".chars() {
            t.print(c);
        }
        assert!(t.is_dirty(screen_point(4, 0)));
        t.clear_dirty();
        t.print('w');
        // Old row is dirty because cursor moved from there.
        assert!(t.is_dirty(screen_point(4, 0)));
        assert!(t.is_dirty(screen_point(0, 1)));
    }

    #[test]
    fn input_that_forces_scroll() {
        // ghostty: "Terminal: input that forces scroll" (Terminal.zig:3282)
        let mut t = terminal(1, 5);
        for c in "abcdef".chars() {
            t.print(c);
        }
        assert_eq!(t.active_screen().cursor.y, 4);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.plain_string(), "b\nc\nd\ne\nf");
    }

    #[test]
    fn input_unique_style_per_cell() {
        // ghostty: "Terminal: input unique style per cell" (Terminal.zig:3298)
        let mut t = terminal(30, 30);
        for y in 0..t.rows {
            for x in 0..t.cols {
                t.set_cursor_pos(y + 1, x + 1);
                t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
                    r: x as u8,
                    g: y as u8,
                    b: 0,
                }));
                t.print('x');
            }
        }
        // No explicit assertions: this is a stress/no-crash test.
    }

    #[test]
    fn input_glitch_text() {
        // ghostty: "Terminal: input glitch text" (Terminal.zig:3316)
        // glitch.txt is byte-identical to ghostty's res/glitch.txt. It only
        // contains a single `\n`, so print_string maps it exactly as ghostty's
        // printString does (CR + LF); no other control bytes are present.
        let glitch = include_str!("res/glitch.txt");
        let mut t = terminal(30, 30);

        // Get our initial grapheme capacity.
        let grapheme_cap = t.first_page_capacity_grapheme_bytes();

        // Print glitch text until our capacity changes.
        while t.first_page_capacity_grapheme_bytes() == grapheme_cap {
            t.print_string(glitch);
        }

        // We're testing to make sure that grapheme capacity gets increased.
        assert!(t.first_page_capacity_grapheme_bytes() > grapheme_cap);
    }

    #[test]
    fn zero_width_character_at_start() {
        // ghostty: "Terminal: zero-width character at start" (Terminal.zig:3340)
        let mut t = terminal(80, 80);
        print_cp(&mut t, 0x200D);
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        // Should not be dirty since we changed nothing.
        assert!(!t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn zero_width_character_attaches_to_pending_wrap_cell() {
        // ghostty: "Terminal: zero-width character attaches to pending wrap cell" (Terminal.zig:3356)
        let mut t = terminal(2, 2);
        // Disable grapheme clustering to exercise the fallback path.
        t.modes.set(Mode::GraphemeCluster, false);
        t.print('x');
        t.print('å');
        print_cp(&mut t, 0x0332);
        assert_eq!(t.plain_string(), "xå\u{0332}");
    }

    #[test]
    fn print_single_very_long_line() {
        // ghostty: "Terminal: print single very long line" (Terminal.zig:3373)
        let mut t = terminal(5, 5);
        for _ in 0..1000 {
            t.print('x');
        }
        // No-crash-only test.
    }

    #[test]
    fn print_wide_char() {
        // ghostty: "Terminal: print wide char" (Terminal.zig:3382)
        let mut t = terminal(80, 80);
        print_cp(&mut t, 0x1F600);
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x1F600);
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(cell(&t, 1, 0).wide(), CellWide::SpacerTail);
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_wide_char_at_edge_creates_spacer_head() {
        // ghostty: "Terminal: print wide char at edge creates spacer head" (Terminal.zig:3405)
        let mut t = terminal(10, 10);
        t.set_cursor_pos(1, 10);
        print_cp(&mut t, 0x1F600);
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert_eq!(cell(&t, 9, 0).wide(), CellWide::SpacerHead);
        assert_eq!(cell(&t, 0, 1).codepoint(), 0x1F600);
        assert_eq!(cell(&t, 0, 1).wide(), CellWide::Wide);
        assert_eq!(cell(&t, 1, 1).wide(), CellWide::SpacerTail);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert!(t.is_dirty(screen_point(0, 1)));
    }

    #[test]
    fn print_wide_char_with_1_column_width() {
        // ghostty: "Terminal: print wide char with 1-column width" (Terminal.zig:3439)
        let mut t = terminal(1, 2);
        t.print('😀');
        // This prints a space so we should be dirty.
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_wide_char_in_single_width_terminal() {
        // ghostty: "Terminal: print wide char in single-width terminal" (Terminal.zig:3450)
        let mut t = terminal(1, 80);
        print_cp(&mut t, 0x1F600);
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert!(t.active_screen().cursor.pending_wrap);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_over_wide_char_at_0_0() {
        // ghostty: "Terminal: print over wide char at 0,0" (Terminal.zig:3469)
        let mut t = terminal(80, 80);
        print_cp(&mut t, 0x1F600);
        t.set_cursor_pos(0, 0);
        t.print('A');
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 1);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('A'));
        assert_eq!(c.wide(), CellWide::Narrow);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert!(!t.is_dirty(screen_point(0, 1)));
    }

    #[test]
    fn print_over_wide_char_at_col_0_corrupts_previous_row() {
        // ghostty: "Terminal: print over wide char at col 0 corrupts previous row" (Terminal.zig:3497)
        let mut t = terminal(10, 3);
        for _ in 0..10 {
            print_cp(&mut t, 0x4E2D);
        }
        t.set_cursor_pos(2, 1);
        t.print('A');
        // Row 1, col 0 should be narrow (we just overwrote the wide char).
        assert_eq!(cell(&t, 0, 1).wide(), CellWide::Narrow);
        // Row 0, col 8 should still be wide (the last wide char on the row).
        assert_eq!(cell(&t, 8, 0).wide(), CellWide::Wide);
        // Row 0, col 9 must remain spacer_tail to pair with the wide at col 8.
        assert_eq!(cell(&t, 9, 0).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn print_over_wide_spacer_tail() {
        // ghostty: "Terminal: print over wide spacer tail" (Terminal.zig:3535)
        let mut t = terminal(5, 5);
        t.print('橋');
        t.set_cursor_pos(1, 2);
        t.print('X');
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), u32::from('X'));
        assert_eq!(c.wide(), CellWide::Narrow);
        assert_eq!(t.plain_string(), " X");
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_over_wide_char_with_bold() {
        // ghostty: "Terminal: print over wide char with bold" (Terminal.zig:3565)
        let mut t = terminal(80, 80);
        t.set_attribute(crate::sgr::Attribute::Bold);
        print_cp(&mut t, 0x1F600);
        // Verify we have styles in our style map.
        assert_eq!(t.cursor_page_style_count(), 1);
        t.set_cursor_pos(0, 0);
        t.set_attribute(crate::sgr::Attribute::Unset);
        t.print('A');
        // Verify our style is gone.
        assert_eq!(t.cursor_page_style_count(), 0);
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_over_wide_char_with_bg_color() {
        // ghostty: "Terminal: print over wide char with bg color" (Terminal.zig:3591)
        let mut t = terminal(80, 80);
        t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        print_cp(&mut t, 0x1F600);
        assert_eq!(t.cursor_page_style_count(), 1);
        t.set_cursor_pos(0, 0);
        t.set_attribute(crate::sgr::Attribute::Unset);
        t.print('A');
        assert_eq!(t.cursor_page_style_count(), 0);
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_multicodepoint_grapheme_disabled_mode_2027() {
        // ghostty: "Terminal: print multicodepoint grapheme, disabled mode 2027" (Terminal.zig:3621)
        // This is: 👨‍👩‍👧
        let mut t = terminal(80, 80);
        print_cp(&mut t, 0x1F468);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F469);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F467);
        assert_eq!(t.active_screen().cursor.y, 0);
        // We should have 6 cells taken up.
        assert_eq!(t.active_screen().cursor.x, 6);

        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x1F468);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap().len(), 1);

        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerTail);
        assert!(t.grapheme_at(screen_point(1, 0)).is_none());

        let c = cell(&t, 2, 0);
        assert_eq!(c.codepoint(), 0x1F469);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(t.grapheme_at(screen_point(2, 0)).unwrap().len(), 1);

        let c = cell(&t, 3, 0);
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerTail);
        assert!(t.grapheme_at(screen_point(3, 0)).is_none());

        let c = cell(&t, 4, 0);
        assert_eq!(c.codepoint(), 0x1F467);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
        assert!(t.grapheme_at(screen_point(4, 0)).is_none());

        let c = cell(&t, 5, 0);
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerTail);
        assert!(t.grapheme_at(screen_point(5, 0)).is_none());

        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn vs16_doesnt_make_character_with_2027_disabled() {
        // ghostty: "Terminal: VS16 doesn't make character with 2027 disabled" (Terminal.zig:3693)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, false);
        print_cp(&mut t, 0x2764); // Heart
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert_eq!(t.plain_string(), "❤️");
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x2764);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap().len(), 1);
    }

    #[test]
    fn ignored_vs16_doesnt_mark_dirty() {
        // ghostty: "Terminal: ignored VS16 doesn't mark dirty" (Terminal.zig:3720)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, false);
        print_cp(&mut t, 0x2764); // Heart
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert!(!t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_invalid_vs16_non_grapheme() {
        // ghostty: "Terminal: print invalid VS16 non-grapheme" (Terminal.zig:3735)
        let mut t = terminal(80, 80);
        t.print('x');
        print_cp(&mut t, 0xFE0F);
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 1);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('x'));
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
        assert_eq!(cell(&t, 1, 0).codepoint(), 0);
    }

    #[test]
    fn invalid_vs16_doesnt_mark_dirty() {
        // ghostty: "Terminal: invalid VS16 doesn't mark dirty" (Terminal.zig:3763)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, false);
        t.print('x');
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert!(!t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn variation_selectors_apply_to_preceding_codepoint() {
        // ghostty: "Terminal: variation selectors apply to preceding codepoint" (Terminal.zig:3779)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        // Pirate flag: black flag + ZWJ + skull and crossbones + VS16.
        print_cp(&mut t, 0x1F3F4);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x2620);
        print_cp(&mut t, 0xFE0F);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x1F3F4);
        assert!(c.has_grapheme());
        assert_eq!(
            t.grapheme_at(screen_point(0, 0)).unwrap(),
            vec![0x200D, 0x2620, 0xFE0F]
        );
    }

    #[test]
    fn print_multicodepoint_grapheme_mode_2027() {
        // ghostty: "Terminal: print multicodepoint grapheme, mode 2027" (Terminal.zig:3799)
        // This is: 👨‍👩‍👧
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x1F468);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F469);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F467);
        assert_eq!(t.active_screen().cursor.y, 0);
        // We should have 2 cells taken up. It is one character but "wide".
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(t.is_dirty(screen_point(0, 0)));

        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x1F468);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap().len(), 4);

        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn keypad_sequence_vs15() {
        // ghostty: "Terminal: keypad sequence VS15" (Terminal.zig:3841)
        // This is: "#︎" (number sign with text presentation selector)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x23); // # Number sign (valid base)
        print_cp(&mut t, 0xFE0E); // VS15 (text presentation selector)
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 1);
        assert!(t.is_dirty(screen_point(0, 0)));
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x23);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn keypad_sequence_vs16() {
        // ghostty: "Terminal: keypad sequence VS16" (Terminal.zig:3870)
        // This is: "#️" (number sign with emoji presentation selector)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x23); // # Number sign (valid base)
        print_cp(&mut t, 0xFE0F); // VS16 (emoji presentation selector)
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(t.is_dirty(screen_point(0, 0)));
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x23);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
    }

    #[test]
    fn fitzpatrick_skin_tone_next_valid_base() {
        // ghostty: "Terminal: Fitzpatrick skin tone next valid base" (Terminal.zig:3899)
        // This is: "👋🏿" (waving hand with dark skin tone)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x1F44B); // 👋 Waving hand (valid base)
        print_cp(&mut t, 0x1F3FF); // 🏿 Dark skin tone modifier
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(t.is_dirty(screen_point(0, 0)));
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x1F44B);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
    }

    #[test]
    fn fitzpatrick_skin_tone_next_to_non_base() {
        // ghostty: "Terminal: Fitzpatrick skin tone next to non-base" (Terminal.zig:3928)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x22); // "
        print_cp(&mut t, 0x1F3FF); // Dark skin tone
        print_cp(&mut t, 0x22); // "
        assert_eq!(t.active_screen().cursor.y, 0);
        // The skin tone should not join with the quotes.
        assert_eq!(t.active_screen().cursor.x, 4);
        assert!(t.is_dirty(screen_point(0, 0)));

        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x22);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);

        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0x1F3FF);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);

        let c = cell(&t, 3, 0);
        assert_eq!(c.codepoint(), 0x22);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn multicodepoint_grapheme_marks_dirty_on_every_codepoint() {
        // ghostty: "Terminal: multicodepoint grapheme marks dirty on every codepoint" (Terminal.zig:3973)
        // This is: 👨‍👩‍👧
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x1F468);
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0x200D);
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0x1F469);
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0x200D);
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0x1F467);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.active_screen().cursor.y, 0);
        // We should have 2 cells taken up. It is one character but "wide".
        assert_eq!(t.active_screen().cursor.x, 2);
    }

    #[test]
    fn vs15_to_make_narrow_character() {
        // ghostty: "Terminal: VS15 to make narrow character" (Terminal.zig:4002)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x2614); // Umbrella with rain drops, width=2
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        assert_eq!(t.active_screen().cursor.y, 0);
        // We should have 2 cells taken up. It is one character but "wide".
        assert_eq!(t.active_screen().cursor.x, 2);
        print_cp(&mut t, 0xFE0E); // VS15 to make narrow
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        assert_eq!(t.active_screen().cursor.y, 0);
        // VS15 should send us back a cell since our char is no longer wide.
        assert_eq!(t.active_screen().cursor.x, 1);
        assert_eq!(t.plain_string(), "☔︎");
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x2614);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap().len(), 1);
    }

    #[test]
    fn vs15_on_already_narrow_emoji() {
        // ghostty: "Terminal: VS15 on already narrow emoji" (Terminal.zig:4042)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x26C8); // Thunder cloud and rain, width=1
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0xFE0E); // VS15 to make narrow
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        assert_eq!(t.active_screen().cursor.y, 0);
        // Character takes up one cell.
        assert_eq!(t.active_screen().cursor.x, 1);
        assert_eq!(t.plain_string(), "⛈︎");
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x26C8);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap().len(), 1);
    }

    #[test]
    fn print_invalid_vs15_following_emoji_is_wide() {
        // ghostty: "Terminal: print invalid VS15 following emoji is wide" (Terminal.zig:4077)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x1F9E0); // 🧠
        print_cp(&mut t, 0xFE0E); // not valid with U+1F9E0 as base
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x1F9E0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn print_invalid_vs15_in_emoji_zwj_sequence() {
        // ghostty: "Terminal: print invalid VS15 in emoji ZWJ sequence" (Terminal.zig:4108)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x1F469); // 👩
        print_cp(&mut t, 0xFE0E); // not valid with U+1F469 as base
        print_cp(&mut t, 0x200D); // ZWJ
        print_cp(&mut t, 0x1F466); // 👦
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x1F469);
        assert!(c.has_grapheme());
        assert_eq!(
            t.grapheme_at(screen_point(0, 0)).unwrap(),
            vec![0x200D, 0x1F466]
        );
        assert_eq!(c.wide(), CellWide::Wide);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn vs15_to_make_narrow_character_with_pending_wrap() {
        // ghostty: "Terminal: VS15 to make narrow character with pending wrap" (Terminal.zig:4142)
        let mut t = terminal(4, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        assert!(t.modes.get(Mode::Wraparound));
        print_cp(&mut t, 0x1F34B); // Lemon, width=2
        print_cp(&mut t, 0x2614); // Umbrella with rain drops, width=2
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 3);
        assert!(t.active_screen().cursor.pending_wrap);
        print_cp(&mut t, 0xFE0E); // VS15 to make narrow
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 3);
        assert!(!t.active_screen().cursor.pending_wrap);
        assert_eq!(t.plain_string(), "🍋☔︎");
        let c = cell(&t, 2, 0);
        assert_eq!(c.codepoint(), 0x2614);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
        assert_eq!(t.grapheme_at(screen_point(2, 0)).unwrap().len(), 1);
        // VS15 should not affect the previous grapheme.
        let lemon = cell(&t, 0, 0);
        assert_eq!(lemon.codepoint(), 0x1F34B);
        assert_eq!(lemon.wide(), CellWide::Wide);
        let spacer = cell(&t, 1, 0);
        assert_eq!(spacer.codepoint(), 0);
        assert_eq!(spacer.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn vs16_to_make_wide_character_on_next_line() {
        // ghostty: "Terminal: VS16 to make wide character on next line" (Terminal.zig:4198)
        let mut t = terminal(3, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        t.cursor_right(2);
        t.print('#');
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(t.active_screen().cursor.pending_wrap);
        assert!(t.is_dirty(screen_point(2, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert!(t.is_dirty(screen_point(2, 0)));
        t.clear_dirty();
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(!t.active_screen().cursor.pending_wrap);

        // Previous cell turns into spacer_head.
        let c = cell(&t, 2, 0);
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerHead);
        // '#' cell is wide.
        let c = cell(&t, 0, 1);
        assert_eq!(c.codepoint(), u32::from('#'));
        assert!(c.has_grapheme());
        assert_eq!(t.grapheme_at(screen_point(0, 1)).unwrap(), vec![0xFE0F]);
        assert_eq!(c.wide(), CellWide::Wide);
        // spacer_tail.
        let c = cell(&t, 1, 1);
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn vs16_to_make_wide_character_on_next_line_with_hyperlink() {
        // ghostty: "Terminal: VS16 to make wide character on next line with hyperlink" (Terminal.zig:4247)
        let mut t = terminal(3, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.cursor_right(2);
        t.print('#');
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(t.active_screen().cursor.pending_wrap);
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(!t.active_screen().cursor.pending_wrap);

        // Previous cell turns into spacer_head and remains hyperlinked.
        let c = cell(&t, 2, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::SpacerHead);
        assert!(c.hyperlink());
        assert!(t.get_row(screen_point(2, 0)).unwrap().wrap());
        // '#' cell is now wide and still hyperlinked.
        let c = cell(&t, 0, 1);
        assert_eq!(c.codepoint(), u32::from('#'));
        assert!(c.has_grapheme());
        assert_eq!(t.grapheme_at(screen_point(0, 1)).unwrap(), vec![0xFE0F]);
        assert_eq!(c.wide(), CellWide::Wide);
        assert!(c.hyperlink());
        // spacer_tail inherits hyperlink as part of the same grapheme cell.
        let c = cell(&t, 1, 1);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::SpacerTail);
        assert!(c.hyperlink());
    }

    #[test]
    fn vs16_to_make_wide_character_with_pending_wrap() {
        // ghostty: "Terminal: VS16 to make wide character with pending wrap" (Terminal.zig:4299)
        let mut t = terminal(3, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        t.cursor_right(1);
        t.print('#');
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(!t.active_screen().cursor.pending_wrap);
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert_eq!(t.active_screen().cursor.x, 2);
        assert_eq!(t.active_screen().cursor.y, 0);
        assert!(t.active_screen().cursor.pending_wrap);

        // '#' cell is wide.
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), u32::from('#'));
        assert!(c.has_grapheme());
        assert_eq!(t.grapheme_at(screen_point(1, 0)).unwrap(), vec![0xFE0F]);
        assert_eq!(c.wide(), CellWide::Wide);
        // spacer_tail.
        let c = cell(&t, 2, 0);
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn vs16_to_make_wide_character_with_mode_2027() {
        // ghostty: "Terminal: VS16 to make wide character with mode 2027" (Terminal.zig:4336)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x2764); // Heart
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        assert_eq!(t.plain_string(), "❤️");
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x2764);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap().len(), 1);
    }

    #[test]
    fn vs16_repeated_with_mode_2027() {
        // ghostty: "Terminal: VS16 repeated with mode 2027" (Terminal.zig:4367)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x2764); // Heart
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        print_cp(&mut t, 0x2764); // Heart
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "❤️❤️");

        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x2764);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap().len(), 1);

        let c = cell(&t, 2, 0);
        assert_eq!(c.codepoint(), 0x2764);
        assert!(c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(t.grapheme_at(screen_point(2, 0)).unwrap().len(), 1);
    }

    #[test]
    fn print_invalid_vs16_grapheme() {
        // ghostty: "Terminal: print invalid VS16 grapheme" (Terminal.zig:4407)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        t.print('x');
        print_cp(&mut t, 0xFE0F); // invalid VS16
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 1);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('x'));
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn print_invalid_vs16_with_second_char() {
        // ghostty: "Terminal: print invalid VS16 with second char" (Terminal.zig:4439)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        t.print('x');
        print_cp(&mut t, 0xFE0F);
        t.print('y');
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('x'));
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), u32::from('y'));
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn print_grapheme_o_with_nonspacing_mark_should_be_narrow() {
        // ghostty: "Terminal: print grapheme ò (o with nonspacing mark) should be narrow" (Terminal.zig:4474)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        t.print('o');
        print_cp(&mut t, 0x0300); // combining grave accent
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 1);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('o'));
        assert!(c.has_grapheme());
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap(), vec![0x0300]);
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn print_devanagari_grapheme_should_be_wide() {
        // ghostty: "Terminal: print Devanagari grapheme should be wide" (Terminal.zig:4500)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        // क्‍ष
        print_cp(&mut t, 0x0915);
        print_cp(&mut t, 0x094D);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x0937);
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x0915);
        assert!(c.has_grapheme());
        assert_eq!(
            t.grapheme_at(screen_point(0, 0)).unwrap(),
            vec![0x094D, 0x200D, 0x0937]
        );
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(cell(&t, 1, 0).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn print_devanagari_grapheme_should_be_wide_on_next_line() {
        // ghostty: "Terminal: print Devanagari grapheme should be wide on next line" (Terminal.zig:4534)
        let mut t = terminal(3, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        t.cursor_right(2);
        // क्‍ष
        print_cp(&mut t, 0x0915);
        print_cp(&mut t, 0x094D);
        print_cp(&mut t, 0x200D);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(t.active_screen().cursor.pending_wrap);
        // This one increases the width to wide.
        print_cp(&mut t, 0x0937);
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(!t.active_screen().cursor.pending_wrap);

        // Previous cell turns into spacer_head.
        let c = cell(&t, 2, 0);
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerHead);
        // Devanagari grapheme is wide.
        let c = cell(&t, 0, 1);
        assert_eq!(c.codepoint(), 0x0915);
        assert!(c.has_grapheme());
        assert_eq!(
            t.grapheme_at(screen_point(0, 1)).unwrap(),
            vec![0x094D, 0x200D, 0x0937]
        );
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(cell(&t, 1, 1).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn print_devanagari_grapheme_should_be_wide_on_next_page() {
        // ghostty: "Terminal: print Devanagari grapheme should be wide on next page" (Terminal.zig:4582)
        let rows = crate::page::STD_CAPACITY.rows;
        let cols = crate::page::STD_CAPACITY.cols;
        let mut t = terminal(cols, rows);
        t.modes.set(Mode::GraphemeCluster, true);
        t.cursor_down(usize::from(rows - 1));
        let first_page_rows = t.first_page_capacity_rows();
        for _ in rows..first_page_rows {
            t.index();
        }
        t.cursor_right(usize::from(cols - 1));
        assert_eq!(t.active_screen().cursor.x, cols - 1);
        assert_eq!(t.active_screen().cursor.y, rows - 1);
        // क्‍ष
        print_cp(&mut t, 0x0915);
        print_cp(&mut t, 0x094D);
        print_cp(&mut t, 0x200D);
        assert_eq!(t.active_screen().cursor.x, cols - 1);
        assert!(t.active_screen().cursor.pending_wrap);
        // This one increases the width to wide.
        print_cp(&mut t, 0x0937);
        assert_eq!(t.active_screen().cursor.y, rows - 1);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert!(!t.active_screen().cursor.pending_wrap);

        // Previous cell turns into spacer_head. (Uses active addressing.)
        let c = t
            .get_cell(Point::active(cols - 1, u32::from(rows - 2)))
            .unwrap();
        assert_eq!(c.codepoint(), 0);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::SpacerHead);
        // Devanagari grapheme is wide.
        let c = t.get_cell(Point::active(0, u32::from(rows - 1))).unwrap();
        assert_eq!(c.codepoint(), 0x0915);
        assert!(c.has_grapheme());
        assert_eq!(
            t.grapheme_at(Point::active(0, u32::from(rows - 1)))
                .unwrap(),
            vec![0x094D, 0x200D, 0x0937]
        );
        assert_eq!(c.wide(), CellWide::Wide);
        let c = t.get_cell(Point::active(1, u32::from(rows - 1))).unwrap();
        assert_eq!(c.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn print_invalid_vs16_with_second_char_combining() {
        // ghostty: "Terminal: print invalid VS16 with second char (combining)" (Terminal.zig:4641)
        let mut t = terminal(80, 80);
        t.modes.set(Mode::GraphemeCluster, true);
        t.print('n');
        print_cp(&mut t, 0xFE0F); // invalid VS16
        print_cp(&mut t, 0x0303); // combining tilde
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 1);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('n'));
        assert!(c.has_grapheme());
        assert_eq!(t.grapheme_at(screen_point(0, 0)).unwrap(), vec![0x0303]);
        assert_eq!(c.wide(), CellWide::Narrow);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn overwrite_grapheme_should_clear_grapheme_data() {
        // ghostty: "Terminal: overwrite grapheme should clear grapheme data" (Terminal.zig:4675)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x26C8); // Thunder cloud and rain
        print_cp(&mut t, 0xFE0E); // VS15 to make narrow
        assert!(t.is_dirty(screen_point(0, 0)));
        t.clear_dirty();
        t.set_cursor_pos(1, 1);
        t.print('A');
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "A");
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('A'));
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn overwrite_multicodepoint_grapheme_clears_grapheme_data() {
        // ghostty: "Terminal: overwrite multicodepoint grapheme clears grapheme data" (Terminal.zig:4706)
        // https://github.com/mitchellh/ghostty/issues/289
        let mut t = terminal(10, 10);
        t.modes.set(Mode::GraphemeCluster, true);
        // This is: 👨‍👩‍👧 (which may or may not render correctly)
        print_cp(&mut t, 0x1F468);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F469);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F467);
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert_eq!(t.cursor_page_grapheme_count(), 1);
        // Move back and overwrite wide.
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.print('X');
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 1);
        assert_eq!(t.cursor_page_grapheme_count(), 0);
        assert_eq!(t.plain_string(), "X");
    }

    #[test]
    fn overwrite_multicodepoint_grapheme_tail_clears_grapheme_data() {
        // ghostty: "Terminal: overwrite multicodepoint grapheme tail clears grapheme data" (Terminal.zig:4746)
        // https://github.com/mitchellh/ghostty/issues/289
        let mut t = terminal(10, 10);
        t.modes.set(Mode::GraphemeCluster, true);
        // This is: 👨‍👩‍👧 (which may or may not render correctly)
        print_cp(&mut t, 0x1F468);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F469);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F467);
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert_eq!(t.cursor_page_grapheme_count(), 1);
        // Move back and overwrite wide.
        t.set_cursor_pos(1, 2);
        t.print('X');
        assert_eq!(t.plain_string(), " X");
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert_eq!(t.cursor_page_grapheme_count(), 0);
    }

    #[test]
    fn print_breaks_valid_grapheme_cluster_with_prepend_and_ascii_for_speed() {
        // ghostty: "Terminal: print breaks valid grapheme cluster with Prepend + ASCII for speed" (Terminal.zig:4784)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        // Make sure we're not at cursor.x == 0 for the next char.
        t.print('_');
        // U+0600 ARABIC NUMBER SIGN (Prepend)
        print_cp(&mut t, 0x0600);
        t.print('1');
        // We assume a grapheme break when c <= 255, so we end up with 3 narrow
        // cells (incorrect per UAX #29 GB9b, but an intentional optimization).
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 3);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0x0600);
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
        let c = cell(&t, 2, 0);
        assert_eq!(c.codepoint(), u32::from('1'));
        assert!(!c.has_grapheme());
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn print_writes_to_bottom_if_scrolled() {
        // ghostty: "Terminal: print writes to bottom if scrolled" (Terminal.zig:4831)
        let mut t = terminal(5, 2);
        for c in "hello".chars() {
            t.print(c);
        }
        t.set_cursor_pos(0, 0);
        // Make newlines so we create scrollback. 3 pushes hello off the screen.
        t.index();
        t.index();
        t.index();
        assert_eq!(t.plain_string(), "");
        // Scroll to the top.
        t.active_screen_mut().scroll(Scroll::Top);
        assert_eq!(t.plain_string(), "hello");
        // Type.
        t.print('A');
        t.active_screen_mut().scroll(Scroll::Active);
        assert_eq!(t.plain_string(), "\nA");
        let x = t.active_screen().cursor.x;
        let y = u32::from(t.active_screen().cursor.y);
        assert!(t.is_dirty(Point::active(x, y)));
    }

    #[test]
    fn print_charset() {
        // ghostty: "Terminal: print charset" (Terminal.zig:4873)
        let mut t = terminal(80, 80);
        // G1 should have no effect.
        t.configure_charset(CharsetSlots::G1, Charset::DecSpecial);
        t.configure_charset(CharsetSlots::G2, Charset::DecSpecial);
        t.configure_charset(CharsetSlots::G3, Charset::DecSpecial);
        // No dirty to configure charset.
        assert!(!t.is_dirty(screen_point(0, 0)));
        // Basic grid writing.
        t.print('`');
        t.configure_charset(CharsetSlots::G0, Charset::Utf8);
        t.print('`');
        t.configure_charset(CharsetSlots::G0, Charset::Ascii);
        t.print('`');
        t.configure_charset(CharsetSlots::G0, Charset::DecSpecial);
        t.print('`');
        assert_eq!(t.plain_string(), "```◆");
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_charset_outside_of_ascii() {
        // ghostty: "Terminal: print charset outside of ASCII" (Terminal.zig:4902)
        let mut t = terminal(80, 80);
        // G1 should have no effect.
        t.configure_charset(CharsetSlots::G1, Charset::DecSpecial);
        t.configure_charset(CharsetSlots::G2, Charset::DecSpecial);
        t.configure_charset(CharsetSlots::G3, Charset::DecSpecial);
        assert!(!t.is_dirty(screen_point(0, 0)));
        // Basic grid writing.
        t.configure_charset(CharsetSlots::G0, Charset::DecSpecial);
        t.print('`');
        print_cp(&mut t, 0x1F600);
        // Should have translated the ` but not the emoji (out of ASCII range
        // maps to a space).
        assert_eq!(t.plain_string(), "◆ ");
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_invoke_charset() {
        // ghostty: "Terminal: print invoke charset" (Terminal.zig:4927)
        let mut t = terminal(80, 80);
        t.configure_charset(CharsetSlots::G1, Charset::DecSpecial);
        t.print('`');
        // Invoke charset but should not mark dirty on its own.
        t.clear_dirty();
        t.invoke_charset(ActiveSlot::Gl, CharsetSlots::G1, false);
        assert!(!t.is_dirty(screen_point(0, 0)));
        t.print('`');
        assert!(t.is_dirty(screen_point(0, 0)));
        t.print('`');
        t.invoke_charset(ActiveSlot::Gl, CharsetSlots::G0, false);
        t.print('`');
        assert_eq!(t.plain_string(), "`◆◆`");
    }

    #[test]
    fn print_invoke_charset_single() {
        // ghostty: "Terminal: print invoke charset single" (Terminal.zig:4951)
        let mut t = terminal(80, 80);
        t.configure_charset(CharsetSlots::G1, Charset::DecSpecial);
        // Basic grid writing.
        t.print('`');
        t.invoke_charset(ActiveSlot::Gl, CharsetSlots::G1, true);
        t.print('`');
        t.print('`');
        assert_eq!(t.plain_string(), "`◆`");
    }

    // T-omitted (kitty unsupported): "Terminal: print kitty unicode placeholder" (Terminal.zig:4969)
    // T-omitted (glyph APC / kitty unsupported): "Terminal: glyph APC stores session glossary entries" (Terminal.zig:13238)

    #[test]
    fn soft_wrap() {
        // ghostty: "Terminal: soft wrap" (Terminal.zig:4989)
        let mut t = terminal(3, 80);
        // Basic grid writing.
        for c in "hello".chars() {
            t.print(c);
        }
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 2);
        assert_eq!(t.plain_string(), "hel\nlo");
    }

    #[test]
    fn soft_wrap_with_semantic_prompt() {
        // ghostty: "Terminal: soft wrap with semantic prompt" (Terminal.zig:5004)
        let mut t = terminal(3, 80);
        // Mark our prompt. Should not make anything dirty on its own.
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        assert!(!t.is_dirty(screen_point(0, 0)));
        // Write and wrap.
        for c in "hello".chars() {
            t.print(c);
        }
        assert_eq!(
            t.get_row(screen_point(0, 0)).unwrap().semantic_prompt(),
            SemanticPrompt::Prompt
        );
        assert_eq!(
            t.get_row(screen_point(0, 1)).unwrap().semantic_prompt(),
            SemanticPrompt::PromptContinuation
        );
    }

    #[test]
    fn disabled_wraparound_with_wide_char_and_one_space() {
        // ghostty: "Terminal: disabled wraparound with wide char and one space" (Terminal.zig:5025)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, false);
        // This puts our cursor at the end and there is NO SPACE for a wide char.
        t.print_string("AAAA");
        t.clear_dirty();
        print_cp(&mut t, 0x1F6A8); // Police car light
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 4);
        assert_eq!(t.plain_string(), "AAAA");
        // Make sure we printed nothing.
        let c = cell(&t, 4, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
        // Should not be dirty since we didn't modify anything.
        assert!(!t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn disabled_wraparound_with_wide_char_and_no_space() {
        // ghostty: "Terminal: disabled wraparound with wide char and no space" (Terminal.zig:5057)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, false);
        // This puts our cursor at the end and there is NO SPACE for a wide char.
        t.print_string("AAAAA");
        t.clear_dirty();
        print_cp(&mut t, 0x1F6A8); // Police car light
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 4);
        assert_eq!(t.plain_string(), "AAAAA");
        let c = cell(&t, 4, 0);
        assert_eq!(c.codepoint(), u32::from('A'));
        assert_eq!(c.wide(), CellWide::Narrow);
        // Should not be dirty since we didn't modify anything.
        assert!(!t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn disabled_wraparound_with_wide_grapheme_and_half_space() {
        // ghostty: "Terminal: disabled wraparound with wide grapheme and half space" (Terminal.zig:5088)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::GraphemeCluster, true);
        t.modes.set(Mode::Wraparound, false);
        // This puts our cursor at the end and there is NO SPACE for a wide char.
        t.print_string("AAAA");
        print_cp(&mut t, 0x2764); // Heart
        t.clear_dirty();
        print_cp(&mut t, 0xFE0F); // VS16 to make wide
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 4);
        assert_eq!(t.plain_string(), "AAAA❤");
        let c = cell(&t, 4, 0);
        assert_eq!(c.codepoint(), u32::from('❤'));
        assert_eq!(c.wide(), CellWide::Narrow);
        // Should not be dirty since we didn't modify anything.
        assert!(!t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_right_margin_wrap() {
        // ghostty: "Terminal: print right margin wrap" (Terminal.zig:5121)
        let mut t = terminal(10, 5);
        t.print_string("123456789");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(3, 5);
        t.set_cursor_pos(1, 5);
        t.print_string("XY");
        assert_eq!(t.plain_string(), "1234X6789\n  Y");
        let row = t.get_row(Point::active(0, 0)).unwrap();
        assert!(!row.wrap());
    }

    #[test]
    fn print_right_margin_wrap_dirty_tracking() {
        // ghostty: "Terminal: print right margin wrap dirty tracking" (Terminal.zig:5144)
        let mut t = terminal(10, 5);
        t.print_string("123456789");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(3, 5);
        t.set_cursor_pos(1, 5);
        t.clear_dirty();
        t.print('X');
        assert!(t.is_dirty(screen_point(4, 0)));
        assert!(!t.is_dirty(screen_point(2, 1)));
        t.clear_dirty();
        t.print('Y');
        assert!(t.is_dirty(screen_point(4, 0)));
        assert!(t.is_dirty(screen_point(2, 1)));
        assert_eq!(t.plain_string(), "1234X6789\n  Y");
    }

    #[test]
    fn print_right_margin_outside() {
        // ghostty: "Terminal: print right margin outside" (Terminal.zig:5173)
        let mut t = terminal(10, 5);
        t.print_string("123456789");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(3, 5);
        t.set_cursor_pos(1, 6);
        t.clear_dirty();
        t.print_string("XY");
        assert_eq!(t.plain_string(), "12345XY89");
        assert!(t.is_dirty(screen_point(5, 0)));
    }

    #[test]
    fn print_right_margin_outside_wrap() {
        // ghostty: "Terminal: print right margin outside wrap" (Terminal.zig:5193)
        let mut t = terminal(10, 5);
        t.print_string("123456789");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(3, 5);
        t.set_cursor_pos(1, 10);
        t.print_string("XY");
        assert_eq!(t.plain_string(), "123456789X\n  Y");
    }

    #[test]
    fn print_wide_char_at_right_margin_does_not_create_spacer_head() {
        // ghostty: "Terminal: print wide char at right margin does not create spacer head" (Terminal.zig:5210)
        let mut t = terminal(10, 10);
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(3, 5);
        t.set_cursor_pos(1, 5);
        print_cp(&mut t, 0x1F600); // Smiley face (wide)
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 4);
        // Both rows dirty due to cursor move.
        assert!(t.is_dirty(screen_point(4, 0)));
        assert!(t.is_dirty(screen_point(4, 1)));
        let c = cell(&t, 4, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
        assert!(!t.get_row(screen_point(4, 0)).unwrap().wrap());
        let c = cell(&t, 2, 1);
        assert_eq!(c.codepoint(), 0x1F600);
        assert_eq!(c.wide(), CellWide::Wide);
        assert_eq!(cell(&t, 3, 1).wide(), CellWide::SpacerTail);
    }

    #[test]
    fn print_with_hyperlink() {
        // ghostty: "Terminal: print with hyperlink" (Terminal.zig:5247)
        let mut t = terminal(80, 80);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("123456");
        for x in 0..6 {
            assert!(t.get_row(screen_point(x, 0)).unwrap().hyperlink());
            assert!(cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), Some(1));
        }
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_over_cell_with_same_hyperlink() {
        // ghostty: "Terminal: print over cell with same hyperlink" (Terminal.zig:5272)
        let mut t = terminal(80, 80);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("123456");
        t.set_cursor_pos(1, 1);
        t.print_string("123456");
        for x in 0..6 {
            assert!(t.get_row(screen_point(x, 0)).unwrap().hyperlink());
            assert!(cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), Some(1));
        }
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_and_end_hyperlink() {
        // ghostty: "Terminal: print and end hyperlink" (Terminal.zig:5299)
        let mut t = terminal(80, 80);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("123");
        t.active_screen_mut().end_hyperlink();
        t.print_string("456");
        for x in 0..3 {
            assert!(t.get_row(screen_point(x, 0)).unwrap().hyperlink());
            assert!(cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), Some(1));
        }
        for x in 3..6 {
            // Row still flagged hyperlink because row 0 contains a hyperlinked
            // cell elsewhere.
            assert!(t.get_row(screen_point(x, 0)).unwrap().hyperlink());
            assert!(!cell(&t, x, 0).hyperlink());
        }
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_and_change_hyperlink() {
        // ghostty: "Terminal: print and change hyperlink" (Terminal.zig:5336)
        let mut t = terminal(80, 80);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://one.example.com");
        t.print_string("123");
        t.active_screen_mut()
            .start_hyperlink(None, b"http://two.example.com");
        t.print_string("456");
        for x in 0..3 {
            assert!(cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), Some(1));
        }
        for x in 3..6 {
            assert!(cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), Some(2));
        }
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn overwrite_hyperlink() {
        // ghostty: "Terminal: overwrite hyperlink" (Terminal.zig:5371)
        let mut t = terminal(80, 80);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://one.example.com");
        t.print_string("123");
        t.set_cursor_pos(1, 1);
        t.active_screen_mut().end_hyperlink();
        t.print_string("456");
        for x in 0..3 {
            assert!(!t.get_row(screen_point(x, 0)).unwrap().hyperlink());
            assert!(!cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), None);
            assert_eq!(t.hyperlink_count_at(screen_point(x, 0)), 0);
        }
        assert!(t.is_dirty(screen_point(0, 0)));
    }

    #[test]
    fn print_wide_char_at_right_edge_with_hyperlink() {
        // ghostty: "Terminal: print wide char at right edge with hyperlink" (Terminal.zig:5404)
        // Printing a wide char at the right edge with an active hyperlink causes
        // printCell to write a spacer_head before printWrap sets the row wrap
        // flag; the integrity check inside setHyperlink must not panic.
        let mut t = terminal(10, 5);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.set_cursor_pos(1, 10);
        print_cp(&mut t, 0x4E2D); // '中' (wide char)
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 2);
        // Row 0, col 9: spacer head with hyperlink.
        let c = cell(&t, 9, 0);
        assert_eq!(c.wide(), CellWide::SpacerHead);
        assert!(c.hyperlink());
        assert!(t.get_row(screen_point(9, 0)).unwrap().wrap());
        // Row 1, col 0: the wide char with hyperlink.
        let c = cell(&t, 0, 1);
        assert_eq!(c.codepoint(), 0x4E2D);
        assert_eq!(c.wide(), CellWide::Wide);
        assert!(c.hyperlink());
        // Row 1, col 1: spacer tail with hyperlink.
        let c = cell(&t, 1, 1);
        assert_eq!(c.wide(), CellWide::SpacerTail);
        assert!(c.hyperlink());
    }

    #[test]
    fn linefeed_and_carriage_return() {
        // ghostty: "Terminal: linefeed and carriage return" (Terminal.zig:5444)
        let mut t = terminal(80, 80);
        for c in "hello".chars() {
            t.print(c);
        }
        t.clear_dirty();
        t.carriage_return();
        // CR should not mark row dirty because it doesn't change rendering.
        assert!(!t.is_dirty(screen_point(0, 0)));
        t.linefeed();
        // LF marks row dirty due to cursor movement.
        assert!(t.is_dirty(screen_point(0, 0)));
        assert!(t.is_dirty(screen_point(0, 1)));
        for c in "world".chars() {
            t.print(c);
        }
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 5);
        assert_eq!(t.plain_string(), "hello\nworld");
    }

    #[test]
    fn linefeed_unsets_pending_wrap() {
        // ghostty: "Terminal: linefeed unsets pending wrap" (Terminal.zig:5472)
        let mut t = terminal(5, 80);
        for c in "hello".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.clear_dirty();
        t.linefeed();
        assert!(t.is_dirty(screen_point(0, 0)));
        assert!(t.is_dirty(screen_point(0, 1)));
        assert!(!t.active_screen().cursor.pending_wrap);
    }

    #[test]
    fn linefeed_mode_automatic_carriage_return() {
        // ghostty: "Terminal: linefeed mode automatic carriage return" (Terminal.zig:5486)
        let mut t = terminal(10, 10);
        t.modes.set(Mode::Linefeed, true);
        t.print_string("123456");
        t.linefeed();
        t.print('X');
        assert_eq!(t.plain_string(), "123456\nX");
    }

    #[test]
    fn carriage_return_unsets_pending_wrap() {
        // ghostty: "Terminal: carriage return unsets pending wrap" (Terminal.zig:5502)
        let mut t = terminal(5, 80);
        for c in "hello".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.carriage_return();
        assert!(!t.active_screen().cursor.pending_wrap);
    }

    #[test]
    fn carriage_return_origin_mode_moves_to_left_margin() {
        // ghostty: "Terminal: carriage return origin mode moves to left margin" (Terminal.zig:5513)
        let mut t = terminal(5, 80);
        t.modes.set(Mode::Origin, true);
        t.active_screen_mut().cursor.x = 0;
        t.scrolling_region.left = 2;
        t.carriage_return();
        assert_eq!(t.active_screen().cursor.x, 2);
    }

    #[test]
    fn carriage_return_left_of_left_margin_moves_to_zero() {
        // ghostty: "Terminal: carriage return left of left margin moves to zero" (Terminal.zig:5524)
        let mut t = terminal(5, 80);
        t.active_screen_mut().cursor.x = 1;
        t.scrolling_region.left = 2;
        t.carriage_return();
        assert_eq!(t.active_screen().cursor.x, 0);
    }

    #[test]
    fn carriage_return_right_of_left_margin_moves_to_left_margin() {
        // ghostty: "Terminal: carriage return right of left margin moves to left margin" (Terminal.zig:5534)
        let mut t = terminal(5, 80);
        t.active_screen_mut().cursor.x = 3;
        t.scrolling_region.left = 2;
        t.carriage_return();
        assert_eq!(t.active_screen().cursor.x, 2);
    }

    #[test]
    fn backspace() {
        // ghostty: "Terminal: backspace" (Terminal.zig:5544)
        let mut t = terminal(80, 80);
        for c in "hello".chars() {
            t.print(c);
        }
        t.backspace();
        t.print('y');
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 5);
        assert_eq!(t.plain_string(), "helly");
    }

    #[test]
    fn horizontal_tabs() {
        // ghostty: "Terminal: horizontal tabs" (Terminal.zig:5561)
        let mut t = terminal(20, 5);
        t.print('1');
        t.horizontal_tab();
        assert_eq!(t.active_screen().cursor.x, 8);
        t.horizontal_tab();
        assert_eq!(t.active_screen().cursor.x, 16);
        // HT at the end.
        t.horizontal_tab();
        assert_eq!(t.active_screen().cursor.x, 19);
        t.horizontal_tab();
        assert_eq!(t.active_screen().cursor.x, 19);
    }

    #[test]
    fn horizontal_tabs_starting_on_tabstop() {
        // ghostty: "Terminal: horizontal tabs starting on tabstop" (Terminal.zig:5582)
        let mut t = terminal(20, 5);
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y, 9);
        t.print('X');
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y, 9);
        t.horizontal_tab();
        t.print('A');
        assert_eq!(t.plain_string(), "        X       A");
    }

    #[test]
    fn horizontal_tabs_with_right_margin() {
        // ghostty: "Terminal: horizontal tabs with right margin" (Terminal.zig:5600)
        let mut t = terminal(20, 5);
        t.scrolling_region.left = 2;
        t.scrolling_region.right = 5;
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y, 1);
        t.print('X');
        t.horizontal_tab();
        t.print('A');
        assert_eq!(t.plain_string(), "X    A");
    }

    #[test]
    fn horizontal_tabs_back() {
        // ghostty: "Terminal: horizontal tabs back" (Terminal.zig:5619)
        let mut t = terminal(20, 5);
        // Edge of screen.
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y, 20);
        t.horizontal_tab_back(1);
        assert_eq!(t.active_screen().cursor.x, 16);
        t.horizontal_tab_back(1);
        assert_eq!(t.active_screen().cursor.x, 8);
        t.horizontal_tab_back(1);
        assert_eq!(t.active_screen().cursor.x, 0);
        t.horizontal_tab_back(1);
        assert_eq!(t.active_screen().cursor.x, 0);
    }

    #[test]
    fn horizontal_tabs_back_starting_on_tabstop() {
        // ghostty: "Terminal: horizontal tabs back starting on tabstop" (Terminal.zig:5642)
        let mut t = terminal(20, 5);
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y, 9);
        t.print('X');
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y, 9);
        t.horizontal_tab_back(1);
        t.print('A');
        assert_eq!(t.plain_string(), "A       X");
    }

    #[test]
    fn horizontal_tabs_with_left_margin_in_origin_mode() {
        // ghostty: "Terminal: horizontal tabs with left margin in origin mode" (Terminal.zig:5660)
        let mut t = terminal(20, 5);
        t.modes.set(Mode::Origin, true);
        t.scrolling_region.left = 2;
        t.scrolling_region.right = 5;
        t.set_cursor_pos(1, 2);
        t.print('X');
        t.horizontal_tab_back(1);
        t.print('A');
        assert_eq!(t.plain_string(), "  AX");
    }

    #[test]
    fn horizontal_tab_back_with_cursor_before_left_margin() {
        // ghostty: "Terminal: horizontal tab back with cursor before left margin" (Terminal.zig:5680)
        let mut t = terminal(20, 5);
        t.modes.set(Mode::Origin, true);
        t.save_cursor();
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(5, 0);
        t.restore_cursor();
        t.horizontal_tab_back(1);
        t.print('X');
        assert_eq!(t.plain_string(), "X");
    }

    #[test]
    fn cursor_pos_resets_wrap() {
        // ghostty: "Terminal: cursorPos resets wrap" (Terminal.zig:5700)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.set_cursor_pos(1, 1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "XBCDE");
    }

    #[test]
    fn cursor_pos_off_the_screen() {
        // ghostty: "Terminal: cursorPos off the screen" (Terminal.zig:5718)
        let mut t = terminal(5, 5);
        t.set_cursor_pos(500, 500);
        t.print('X');
        assert_eq!(t.plain_string(), "\n\n\n\n    X");
    }

    #[test]
    fn cursor_pos_relative_to_origin() {
        // ghostty: "Terminal: cursorPos relative to origin" (Terminal.zig:5733)
        let mut t = terminal(5, 5);
        t.scrolling_region.top = 2;
        t.scrolling_region.bottom = 3;
        t.modes.set(Mode::Origin, true);
        t.set_cursor_pos(1, 1);
        t.print('X');
        assert_eq!(t.plain_string(), "\n\nX");
    }

    #[test]
    fn cursor_pos_relative_to_origin_with_left_right() {
        // ghostty: "Terminal: cursorPos relative to origin with left/right" (Terminal.zig:5751)
        let mut t = terminal(5, 5);
        t.scrolling_region.top = 2;
        t.scrolling_region.bottom = 3;
        t.scrolling_region.left = 2;
        t.scrolling_region.right = 4;
        t.modes.set(Mode::Origin, true);
        t.set_cursor_pos(1, 1);
        t.print('X');
        assert_eq!(t.plain_string(), "\n\n  X");
    }

    #[test]
    fn cursor_pos_limits_with_full_scroll_region() {
        // ghostty: "Terminal: cursorPos limits with full scroll region" (Terminal.zig:5771)
        let mut t = terminal(5, 5);
        t.scrolling_region.top = 2;
        t.scrolling_region.bottom = 3;
        t.scrolling_region.left = 2;
        t.scrolling_region.right = 4;
        t.modes.set(Mode::Origin, true);
        t.set_cursor_pos(500, 500);
        t.print('X');
        assert_eq!(t.plain_string(), "\n\n\n    X");
    }

    #[test]
    fn set_cursor_pos_original_test() {
        // ghostty: "Terminal: setCursorPos (original test)" (Terminal.zig:5792)
        let mut t = terminal(80, 80);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 0);
        // Setting it to 0 should keep it zero (1 based).
        t.set_cursor_pos(0, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 0);
        // Should clamp to size.
        t.set_cursor_pos(81, 81);
        assert_eq!(t.active_screen().cursor.x, 79);
        assert_eq!(t.active_screen().cursor.y, 79);
        // Should reset pending wrap.
        t.set_cursor_pos(0, 80);
        t.print('c');
        assert!(t.active_screen().cursor.pending_wrap);
        t.set_cursor_pos(0, 80);
        assert!(!t.active_screen().cursor.pending_wrap);
        // Origin mode.
        t.modes.set(Mode::Origin, true);
        // No change without a scroll region.
        t.set_cursor_pos(81, 81);
        assert_eq!(t.active_screen().cursor.x, 79);
        assert_eq!(t.active_screen().cursor.y, 79);
        // Set the scroll region.
        t.set_top_and_bottom_margin(10, t.rows);
        t.set_cursor_pos(0, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 9);
        t.set_cursor_pos(1, 1);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 9);
        t.set_cursor_pos(100, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 79);
        t.set_top_and_bottom_margin(10, 11);
        t.set_cursor_pos(2, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 10);
    }

    #[test]
    fn set_top_and_bottom_margin_simple() {
        // ghostty: "Terminal: setTopAndBottomMargin simple" (Terminal.zig:5844)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_top_and_bottom_margin(0, 0);
        t.clear_dirty();
        t.scroll_down(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "\nABC\nDEF\nGHI");
    }

    #[test]
    fn set_top_and_bottom_margin_top_only() {
        // ghostty: "Terminal: setTopAndBottomMargin top only" (Terminal.zig:5874)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_top_and_bottom_margin(2, 0);
        t.clear_dirty();
        t.scroll_down(1);
        // This is dirty because the cursor moves from this row.
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "ABC\n\nDEF\nGHI");
    }

    #[test]
    fn set_top_and_bottom_margin_top_and_bottom() {
        // ghostty: "Terminal: setTopAndBottomMargin top and bottom" (Terminal.zig:5904)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_top_and_bottom_margin(1, 2);
        t.clear_dirty();
        t.scroll_down(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(!t.is_dirty(Point::active(0, 2)));
        assert_eq!(t.plain_string(), "\nABC\nGHI");
    }

    #[test]
    fn set_top_and_bottom_margin_top_equal_to_bottom() {
        // ghostty: "Terminal: setTopAndBottomMargin top equal to bottom" (Terminal.zig:5932)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_top_and_bottom_margin(2, 2);
        t.clear_dirty();
        t.scroll_down(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "\nABC\nDEF\nGHI");
    }

    #[test]
    fn set_left_and_right_margin_simple() {
        // ghostty: "Terminal: setLeftAndRightMargin simple" (Terminal.zig:5961)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(0, 0);
        t.clear_dirty();
        t.erase_chars(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(!t.is_dirty(Point::active(0, 1)));
        assert_eq!(t.plain_string(), " BC\nDEF\nGHI");
    }

    #[test]
    fn set_left_and_right_margin_left_only() {
        // ghostty: "Terminal: setLeftAndRightMargin left only" (Terminal.zig:5989)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(2, 0);
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.insert_lines(1);
        assert_eq!(t.scrolling_region.left, 1);
        assert_eq!(t.scrolling_region.right, t.cols - 1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "A\nDBC\nGEF\n HI");
    }

    #[test]
    fn set_left_and_right_margin_left_and_right() {
        // ghostty: "Terminal: setLeftAndRightMargin left and right" (Terminal.zig:6022)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(1, 2);
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.insert_lines(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "  C\nABF\nDEI\nGH");
    }

    #[test]
    fn set_left_and_right_margin_left_equal_right() {
        // ghostty: "Terminal: setLeftAndRightMargin left equal right" (Terminal.zig:6053)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(2, 2);
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.insert_lines(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "\nABC\nDEF\nGHI");
    }

    #[test]
    fn set_left_and_right_margin_mode_69_unset() {
        // ghostty: "Terminal: setLeftAndRightMargin mode 69 unset" (Terminal.zig:6084)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.modes.set(Mode::EnableLeftAndRightMargin, false);
        t.set_left_and_right_margin(1, 2);
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.insert_lines(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "\nABC\nDEF\nGHI");
    }

    #[test]
    fn insert_lines_simple() {
        // ghostty: "Terminal: insertLines simple" (Terminal.zig:6115)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.insert_lines(1);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "ABC\n\nDEF\nGHI");
    }

    #[test]
    fn insert_lines_colors_with_bg_color() {
        // ghostty: "Terminal: insertLines colors with bg color" (Terminal.zig:6144)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.insert_lines(1);
        assert_eq!(t.plain_string(), "ABC\n\nDEF\nGHI");
        for x in 0..t.cols {
            let c = active_cell(&t, x, 1);
            assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
            assert_eq!(
                c.rgb(),
                crate::color::Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }
            );
        }
    }

    #[test]
    fn insert_lines_handles_style_refs() {
        // ghostty: "Terminal: insertLines handles style refs" (Terminal.zig:6185)
        let mut t = terminal(5, 3);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        // For the line being deleted, create a refcounted style.
        t.set_attribute(crate::sgr::Attribute::Bold);
        t.print_string("GHI");
        t.set_attribute(crate::sgr::Attribute::Unset);
        t.set_cursor_pos(2, 2);
        // verify we have styles in our style map
        assert_eq!(t.cursor_page_style_count(), 1);
        t.insert_lines(1);
        assert_eq!(t.plain_string(), "ABC\n\nDEF");
        // verify we have no styles in our style map
        assert_eq!(t.cursor_page_style_count(), 0);
    }

    #[test]
    fn insert_lines_outside_of_scroll_region() {
        // ghostty: "Terminal: insertLines outside of scroll region" (Terminal.zig:6219)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_top_and_bottom_margin(3, 4);
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.insert_lines(1);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert!(!t.is_dirty(Point::active(0, 1)));
        assert!(!t.is_dirty(Point::active(0, 2)));
        assert_eq!(t.plain_string(), "ABC\nDEF\nGHI");
    }

    #[test]
    fn insert_lines_top_bottom_scroll_region() {
        // ghostty: "Terminal: insertLines top/bottom scroll region" (Terminal.zig:6248)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.carriage_return();
        t.linefeed();
        t.print_string("123");
        t.set_top_and_bottom_margin(1, 3);
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.insert_lines(1);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(!t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "ABC\n\nDEF\n123");
    }

    #[test]
    fn insert_lines_across_page_boundary_marks_all_shifted_rows_dirty() {
        // ghostty: "Terminal: insertLines across page boundary marks all shifted rows dirty" (Terminal.zig:6281)
        let mut t = Terminal::new(Options {
            cols: 10,
            rows: 5,
            max_scrollback: 1024,
            width_px: 0,
            height_px: 0,
        });
        let first_page_nrows = t.first_page_capacity_rows();
        // Fill up the first page minus 3 rows.
        for _ in 0..first_page_nrows - 3 {
            t.linefeed();
        }
        t.print_string("1AAAA");
        t.carriage_return();
        t.linefeed();
        t.print_string("2BBBB");
        t.carriage_return();
        t.linefeed();
        t.print_string("3CCCC");
        t.carriage_return();
        t.linefeed();
        t.print_string("4DDDD");
        t.carriage_return();
        t.linefeed();
        t.print_string("5EEEE");
        // Verify we now have a second page.
        assert!(t.active_screen().pages.total_pages() > 1);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_lines(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert!(t.is_dirty(Point::active(0, 4)));
        assert_eq!(t.plain_string(), "\n1AAAA\n2BBBB\n3CCCC\n4DDDD");
    }

    #[test]
    fn insert_lines_legacy_test() {
        // ghostty: "Terminal: insertLines (legacy test)" (Terminal.zig:6327)
        let mut t = terminal(2, 5);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.carriage_return();
        t.linefeed();
        t.print('D');
        t.carriage_return();
        t.linefeed();
        t.print('E');
        t.set_cursor_pos(2, 1);
        t.insert_lines(2);
        assert_eq!(t.plain_string(), "A\n\n\nB\nC");
    }

    #[test]
    fn insert_lines_zero() {
        // ghostty: "Terminal: insertLines zero" (Terminal.zig:6360)
        let mut t = terminal(2, 5);
        // This should do nothing.
        t.set_cursor_pos(1, 1);
        t.insert_lines(0);
    }

    #[test]
    fn insert_lines_with_scroll_region() {
        // ghostty: "Terminal: insertLines with scroll region" (Terminal.zig:6370)
        let mut t = terminal(2, 6);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.carriage_return();
        t.linefeed();
        t.print('D');
        t.carriage_return();
        t.linefeed();
        t.print('E');
        t.set_top_and_bottom_margin(1, 2);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_lines(1);
        t.print('X');
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(!t.is_dirty(Point::active(0, 2)));
        assert_eq!(t.plain_string(), "X\nA\nC\nD\nE");
    }

    #[test]
    fn insert_lines_more_than_remaining() {
        // ghostty: "Terminal: insertLines more than remaining" (Terminal.zig:6409)
        let mut t = terminal(2, 5);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.carriage_return();
        t.linefeed();
        t.print('D');
        t.carriage_return();
        t.linefeed();
        t.print('E');
        t.set_cursor_pos(2, 1);
        t.clear_dirty();
        t.insert_lines(20);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert_eq!(t.plain_string(), "A");
    }

    #[test]
    fn insert_lines_resets_pending_wrap() {
        // ghostty: "Terminal: insertLines resets pending wrap" (Terminal.zig:6447)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.insert_lines(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('B');
        assert_eq!(t.plain_string(), "B\nABCDE");
    }

    #[test]
    fn insert_lines_resets_wrap() {
        // ghostty: "Terminal: insertLines resets wrap" (Terminal.zig:6465)
        let mut t = terminal(3, 3);
        t.print('1');
        t.carriage_return();
        t.linefeed();
        for c in "ABCDEF".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.insert_lines(1);
        t.print('X');
        assert_eq!(t.plain_string(), "X\n1\nABC");
        let row = t.get_row(Point::active(0, 2)).expect("row exists");
        assert!(!row.wrap());
    }

    #[test]
    fn insert_lines_multi_codepoint_graphemes() {
        // ghostty: "Terminal: insertLines multi-codepoint graphemes" (Terminal.zig:6491)
        let mut t = terminal(5, 5);
        // Disable grapheme clustering (source comment; code sets mode true).
        t.modes.set(Mode::GraphemeCluster, true);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        // This is: 👨‍👩‍👧 (which may or may not render correctly)
        print_cp(&mut t, 0x1F468);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F469);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F467);
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        t.insert_lines(1);
        assert_eq!(t.plain_string(), "ABC\n\n👨‍👩‍👧\nGHI");
    }

    #[test]
    fn insert_lines_left_right_scroll_region() {
        // ghostty: "Terminal: insertLines left/right scroll region" (Terminal.zig:6523)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF456");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.insert_lines(1);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "ABC123\nD   56\nGEF489\n HI7");
    }

    #[test]
    fn scroll_up_simple() {
        // ghostty: "Terminal: scrollUp simple" (Terminal.zig:6554)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        let cursor_x = t.active_screen().cursor.x;
        let cursor_y = t.active_screen().cursor.y;
        let viewport_before = t.active_screen().pages.get_top_left(Tag::Viewport);
        t.scroll_up(1);
        let viewport_after = t.active_screen().pages.get_top_left(Tag::Viewport);
        assert_eq!(t.active_screen().cursor.x, cursor_x);
        assert_eq!(t.active_screen().cursor.y, cursor_y);
        // Viewport should have moved.
        assert!(!viewport_before.eql(viewport_after));
        assert_eq!(t.plain_string(), "DEF\nGHI");
    }

    #[test]
    fn scroll_up_moves_hyperlink() {
        // ghostty: "Terminal: scrollUp moves hyperlink" (Terminal.zig:6587)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("DEF");
        t.active_screen_mut().end_hyperlink();
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        t.scroll_up(1);
        assert_eq!(t.plain_string(), "DEF\nGHI");
        for x in 0..3 {
            let p = Point::viewport(x, 0);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
            assert_eq!(t.hyperlink_set_count_at(p), 1);
        }
        for x in 0..3 {
            let p = Point::viewport(x, 1);
            assert!(!t.get_row(p).expect("row").hyperlink());
            assert!(!viewport_cell(&t, x, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
    }

    #[test]
    fn scroll_up_clears_hyperlink() {
        // ghostty: "Terminal: scrollUp clears hyperlink" (Terminal.zig:6638)
        let mut t = terminal(5, 5);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("ABC");
        t.active_screen_mut().end_hyperlink();
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        t.scroll_up(1);
        assert_eq!(t.plain_string(), "DEF\nGHI");
        for x in 0..3 {
            let p = Point::viewport(x, 0);
            assert!(!t.get_row(p).expect("row").hyperlink());
            assert!(!viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
    }

    #[test]
    fn scroll_up_top_bottom_scroll_region() {
        // ghostty: "Terminal: scrollUp top/bottom scroll region" (Terminal.zig:6675)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_top_and_bottom_margin(2, 3);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.scroll_up(1);
        // This is dirty because the cursor moves from this row.
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert_eq!(t.plain_string(), "ABC\nGHI");
    }

    #[test]
    fn scroll_up_left_right_scroll_region() {
        // ghostty: "Terminal: scrollUp left/right scroll region" (Terminal.zig:6705)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF456");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(2, 2);
        let cursor_x = t.active_screen().cursor.x;
        let cursor_y = t.active_screen().cursor.y;
        t.clear_dirty();
        t.scroll_up(1);
        assert_eq!(t.active_screen().cursor.x, cursor_x);
        assert_eq!(t.active_screen().cursor.y, cursor_y);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert_eq!(t.plain_string(), "AEF423\nDHI756\nG   89");
    }

    #[test]
    fn scroll_up_left_right_scroll_region_hyperlink() {
        // ghostty: "Terminal: scrollUp left/right scroll region hyperlink" (Terminal.zig:6738)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.carriage_return();
        t.linefeed();
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("DEF456");
        t.active_screen_mut().end_hyperlink();
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(2, 2);
        t.scroll_up(1);
        assert_eq!(t.plain_string(), "AEF423\nDHI756\nG   89");
        // First row gets some hyperlinks.
        for x in 0..1 {
            let p = Point::viewport(x, 0);
            assert!(!viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
        for x in 1..4 {
            let p = Point::viewport(x, 0);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
            assert_eq!(t.hyperlink_set_count_at(p), 1);
        }
        for x in 4..6 {
            let p = Point::viewport(x, 0);
            assert!(!viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
        // Second row preserves hyperlink where we didn't scroll.
        for x in 0..1 {
            let p = Point::viewport(x, 1);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, x, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
            assert_eq!(t.hyperlink_set_count_at(p), 1);
        }
        for x in 1..4 {
            let p = Point::viewport(x, 1);
            assert!(!viewport_cell(&t, x, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
        for x in 4..6 {
            let p = Point::viewport(x, 1);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, x, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
            assert_eq!(t.hyperlink_set_count_at(p), 1);
        }
    }

    #[test]
    fn scroll_up_preserves_pending_wrap() {
        // ghostty: "Terminal: scrollUp preserves pending wrap" (Terminal.zig:6844)
        let mut t = terminal(5, 5);
        t.set_cursor_pos(1, 5);
        t.print('A');
        t.set_cursor_pos(2, 5);
        t.print('B');
        t.set_cursor_pos(3, 5);
        t.print('C');
        t.scroll_up(1);
        t.print('X');
        assert_eq!(t.plain_string(), "    B\n    C\n\nX");
    }

    #[test]
    fn scroll_up_full_top_bottom_region() {
        // ghostty: "Terminal: scrollUp full top/bottom region" (Terminal.zig:6865)
        let mut t = terminal(5, 5);
        t.print_string("top");
        t.set_cursor_pos(5, 1);
        t.print_string("ABCDE");
        t.set_top_and_bottom_margin(2, 5);
        t.clear_dirty();
        t.scroll_up(4);
        // This is dirty because the cursor moves from this row.
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert_eq!(t.plain_string(), "top");
    }

    #[test]
    fn scroll_up_full_top_bottom_left_right_scroll_region() {
        // ghostty: "Terminal: scrollUp full top/bottomleft/right scroll region" (Terminal.zig:6889)
        let mut t = terminal(5, 5);
        t.print_string("top");
        t.set_cursor_pos(5, 1);
        t.print_string("ABCDE");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_top_and_bottom_margin(2, 5);
        t.set_left_and_right_margin(2, 4);
        t.clear_dirty();
        t.scroll_up(4);
        assert!(t.is_dirty(Point::active(0, 0)));
        for y in 1..5 {
            assert!(t.is_dirty(Point::active(0, y)));
        }
        assert_eq!(t.plain_string(), "top\n\n\n\nA   E");
    }

    #[test]
    fn scroll_up_creates_scrollback_in_primary_screen() {
        // ghostty: "Terminal: scrollUp creates scrollback in primary screen" (Terminal.zig:6918)
        let mut t = Terminal::new(Options {
            cols: 5,
            rows: 5,
            max_scrollback: 10,
            width_px: 0,
            height_px: 0,
        });
        t.print_string("AAAAA");
        t.carriage_return();
        t.linefeed();
        t.print_string("BBBBB");
        t.carriage_return();
        t.linefeed();
        t.print_string("CCCCC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DDDDD");
        t.carriage_return();
        t.linefeed();
        t.print_string("EEEEE");
        t.clear_dirty();
        // Scroll up by 1, which should push 'AAAAA' into scrollback.
        t.scroll_up(1);
        // The cursor row (new empty row) should be dirty.
        let cx = t.active_screen().cursor.x;
        let cy = t.active_screen().cursor.y;
        assert!(t.is_dirty(Point::active(cx, u32::from(cy))));
        assert_eq!(t.plain_string(), "BBBBB\nCCCCC\nDDDDD\nEEEEE");
        t.active_screen_mut().scroll(Scroll::Top);
        assert_eq!(t.plain_string(), "AAAAA\nBBBBB\nCCCCC\nDDDDD\nEEEEE");
    }

    #[test]
    fn scroll_up_with_max_scrollback_zero() {
        // ghostty: "Terminal: scrollUp with max_scrollback zero" (Terminal.zig:6965)
        let mut t = Terminal::new(Options {
            cols: 5,
            rows: 5,
            max_scrollback: 0,
            width_px: 0,
            height_px: 0,
        });
        t.print_string("AAAAA");
        t.carriage_return();
        t.linefeed();
        t.print_string("BBBBB");
        t.carriage_return();
        t.linefeed();
        t.print_string("CCCCC");
        t.scroll_up(1);
        assert_eq!(t.plain_string(), "BBBBB\nCCCCC");
        t.active_screen_mut().scroll(Scroll::Top);
        assert_eq!(t.plain_string(), "BBBBB\nCCCCC");
    }

    #[test]
    fn scroll_up_with_max_scrollback_zero_and_top_margin() {
        // ghostty: "Terminal: scrollUp with max_scrollback zero and top margin" (Terminal.zig:6997)
        let mut t = Terminal::new(Options {
            cols: 5,
            rows: 5,
            max_scrollback: 0,
            width_px: 0,
            height_px: 0,
        });
        t.print_string("AAAAA");
        t.carriage_return();
        t.linefeed();
        t.print_string("BBBBB");
        t.carriage_return();
        t.linefeed();
        t.print_string("CCCCC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DDDDD");
        // Set top margin (not at row 0).
        t.set_top_and_bottom_margin(2, 5);
        t.scroll_up(1);
        assert_eq!(t.plain_string(), "AAAAA\nCCCCC\nDDDDD");
    }

    #[test]
    fn scroll_up_with_max_scrollback_zero_and_left_right_margin() {
        // ghostty: "Terminal: scrollUp with max_scrollback zero and left/right margin" (Terminal.zig:7027)
        let mut t = Terminal::new(Options {
            cols: 10,
            rows: 5,
            max_scrollback: 0,
            width_px: 0,
            height_px: 0,
        });
        t.print_string("AAAAABBBBB");
        t.carriage_return();
        t.linefeed();
        t.print_string("CCCCCDDDDD");
        t.carriage_return();
        t.linefeed();
        t.print_string("EEEEEFFFFF");
        // Set left/right margins (columns 2-6, 1-indexed = indices 1-5).
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(2, 6);
        t.scroll_up(1);
        assert_eq!(t.plain_string(), "ACCCCDBBBB\nCEEEEFDDDD\nE     FFFF");
    }

    #[test]
    fn scroll_down_simple() {
        // ghostty: "Terminal: scrollDown simple" (Terminal.zig:7055)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        let cursor_x = t.active_screen().cursor.x;
        let cursor_y = t.active_screen().cursor.y;
        t.clear_dirty();
        t.scroll_down(1);
        assert_eq!(t.active_screen().cursor.x, cursor_x);
        assert_eq!(t.active_screen().cursor.y, cursor_y);
        for y in 0..5 {
            assert!(t.is_dirty(Point::active(0, y)));
        }
        assert_eq!(t.plain_string(), "\nABC\nDEF\nGHI");
    }

    #[test]
    fn scroll_down_hyperlink_moves() {
        // ghostty: "Terminal: scrollDown hyperlink moves" (Terminal.zig:7087)
        let mut t = terminal(5, 5);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("ABC");
        t.active_screen_mut().end_hyperlink();
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        t.scroll_down(1);
        assert_eq!(t.plain_string(), "\nABC\nDEF\nGHI");
        for x in 0..3 {
            let p = Point::viewport(x, 1);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, x, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
            assert_eq!(t.hyperlink_set_count_at(p), 1);
        }
        for x in 0..3 {
            let p = Point::viewport(x, 0);
            assert!(!t.get_row(p).expect("row").hyperlink());
            assert!(!viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
    }

    #[test]
    fn scroll_down_outside_of_scroll_region() {
        // ghostty: "Terminal: scrollDown outside of scroll region" (Terminal.zig:7138)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_top_and_bottom_margin(3, 4);
        t.set_cursor_pos(2, 2);
        let cursor_x = t.active_screen().cursor.x;
        let cursor_y = t.active_screen().cursor.y;
        t.clear_dirty();
        t.scroll_down(1);
        assert_eq!(t.active_screen().cursor.x, cursor_x);
        assert_eq!(t.active_screen().cursor.y, cursor_y);
        assert!(!t.is_dirty(Point::active(0, 0)));
        // Dirty because the cursor moves from this row.
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "ABC\nDEF\n\nGHI");
    }

    #[test]
    fn scroll_down_left_right_scroll_region() {
        // ghostty: "Terminal: scrollDown left/right scroll region" (Terminal.zig:7173)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF456");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(2, 2);
        let cursor_x = t.active_screen().cursor.x;
        let cursor_y = t.active_screen().cursor.y;
        t.clear_dirty();
        t.scroll_down(1);
        assert_eq!(t.active_screen().cursor.x, cursor_x);
        assert_eq!(t.active_screen().cursor.y, cursor_y);
        for y in 0..4 {
            assert!(t.is_dirty(Point::active(0, y)));
        }
        assert_eq!(t.plain_string(), "A   23\nDBC156\nGEF489\n HI7");
    }

    #[test]
    fn scroll_down_left_right_scroll_region_hyperlink() {
        // ghostty: "Terminal: scrollDown left/right scroll region hyperlink" (Terminal.zig:7207)
        let mut t = terminal(10, 10);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("ABC123");
        t.active_screen_mut().end_hyperlink();
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF456");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(2, 2);
        t.scroll_down(1);
        assert_eq!(t.plain_string(), "A   23\nDBC156\nGEF489\n HI7");
        // First row preserves hyperlink where we didn't scroll.
        for x in 0..1 {
            let p = Point::viewport(x, 0);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
            assert_eq!(t.hyperlink_set_count_at(p), 1);
        }
        for x in 1..4 {
            let p = Point::viewport(x, 0);
            assert!(!viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
        for x in 4..6 {
            let p = Point::viewport(x, 0);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
            assert_eq!(t.hyperlink_set_count_at(p), 1);
        }
        // Second row gets some hyperlinks.
        for x in 0..1 {
            let p = Point::viewport(x, 1);
            assert!(!viewport_cell(&t, x, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
        for x in 1..4 {
            let p = Point::viewport(x, 1);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, x, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
            assert_eq!(t.hyperlink_set_count_at(p), 1);
        }
        for x in 4..6 {
            let p = Point::viewport(x, 1);
            assert!(!viewport_cell(&t, x, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
    }

    #[test]
    fn scroll_down_outside_of_left_right_scroll_region() {
        // ghostty: "Terminal: scrollDown outside of left/right scroll region" (Terminal.zig:7313)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF456");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(1, 1);
        let cursor_x = t.active_screen().cursor.x;
        let cursor_y = t.active_screen().cursor.y;
        t.clear_dirty();
        t.scroll_down(1);
        assert_eq!(t.active_screen().cursor.x, cursor_x);
        assert_eq!(t.active_screen().cursor.y, cursor_y);
        for y in 0..4 {
            assert!(t.is_dirty(Point::active(0, y)));
        }
        assert_eq!(t.plain_string(), "A   23\nDBC156\nGEF489\n HI7");
    }

    #[test]
    fn scroll_down_preserves_pending_wrap() {
        // ghostty: "Terminal: scrollDown preserves pending wrap" (Terminal.zig:7347)
        let mut t = terminal(5, 10);
        t.set_cursor_pos(1, 5);
        t.print('A');
        t.set_cursor_pos(2, 5);
        t.print('B');
        t.set_cursor_pos(3, 5);
        t.print('C');
        t.scroll_down(1);
        t.print('X');
        assert_eq!(t.plain_string(), "\n    A\n    B\nX   C");
    }

    #[test]
    fn erase_chars_simple_operation() {
        // ghostty: "Terminal: eraseChars simple operation" (Terminal.zig:7368)
        let mut t = terminal(5, 5);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.erase_chars(2);
        t.print('X');
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(!t.is_dirty(Point::active(0, 1)));
        assert_eq!(t.plain_string(), "X C");
    }

    #[test]
    fn erase_chars_minimum_one() {
        // ghostty: "Terminal: eraseChars minimum one" (Terminal.zig:7389)
        let mut t = terminal(5, 5);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.erase_chars(0);
        t.print('X');
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "XBC");
    }

    #[test]
    fn erase_chars_beyond_screen_edge() {
        // ghostty: "Terminal: eraseChars beyond screen edge" (Terminal.zig:7408)
        let mut t = terminal(5, 5);
        for c in "  ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 4);
        t.erase_chars(10);
        assert_eq!(t.plain_string(), "  A");
    }

    #[test]
    fn erase_chars_wide_character() {
        // ghostty: "Terminal: eraseChars wide character" (Terminal.zig:7424)
        let mut t = terminal(5, 5);
        t.print('橋');
        for c in "BC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.erase_chars(1);
        t.print('X');
        assert_eq!(t.plain_string(), "X BC");
    }

    #[test]
    fn erase_chars_resets_pending_wrap() {
        // ghostty: "Terminal: eraseChars resets pending wrap" (Terminal.zig:7442)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.erase_chars(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDX");
    }

    #[test]
    fn erase_chars_resets_wrap() {
        // ghostty: "Terminal: eraseChars resets wrap" (Terminal.zig:7460)
        let mut t = terminal(5, 5);
        for c in "ABCDE123".chars() {
            t.print(c);
        }
        assert!(t.get_row(Point::active(0, 0)).expect("row").wrap());
        t.set_cursor_pos(1, 1);
        t.erase_chars(1);
        assert!(!t.get_row(Point::active(0, 0)).expect("row").wrap());
        t.print('X');
        assert_eq!(t.plain_string(), "XBCDE\n123");
    }

    #[test]
    fn erase_chars_preserves_background_sgr() {
        // ghostty: "Terminal: eraseChars preserves background sgr" (Terminal.zig:7490)
        let mut t = terminal(10, 10);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.erase_chars(2);
        assert_eq!(t.plain_string(), "  C");
        for x in 0..2 {
            let c = active_cell(&t, x, 0);
            assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
            assert_eq!(
                c.rgb(),
                crate::color::Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }
            );
        }
    }

    #[test]
    fn erase_chars_handles_refcounted_styles() {
        // ghostty: "Terminal: eraseChars handles refcounted styles" (Terminal.zig:7529)
        let mut t = terminal(10, 10);
        t.set_attribute(crate::sgr::Attribute::Bold);
        t.print('A');
        t.print('B');
        t.set_attribute(crate::sgr::Attribute::Unset);
        t.print('C');
        // Verify we have styles in our style map.
        assert_eq!(t.cursor_page_style_count(), 1);
        t.set_cursor_pos(1, 1);
        t.erase_chars(2);
        // Verify we have no styles in our style map.
        assert_eq!(t.cursor_page_style_count(), 0);
    }

    #[test]
    fn erase_chars_protected_attributes_respected_with_iso() {
        // ghostty: "Terminal: eraseChars protected attributes respected with iso" (Terminal.zig:7551)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.erase_chars(2);
        assert_eq!(t.plain_string(), "ABC");
    }

    #[test]
    fn erase_chars_protected_attributes_ignored_with_dec_most_recent() {
        // ghostty: "Terminal: eraseChars protected attributes ignored with dec most recent" (Terminal.zig:7568)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_protected_mode(ProtectedMode::Dec);
        t.set_protected_mode(ProtectedMode::Off);
        t.set_cursor_pos(1, 1);
        t.erase_chars(2);
        assert_eq!(t.plain_string(), "  C");
    }

    #[test]
    fn erase_chars_protected_attributes_ignored_with_dec_set() {
        // ghostty: "Terminal: eraseChars protected attributes ignored with dec set" (Terminal.zig:7587)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Dec);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.erase_chars(2);
        assert_eq!(t.plain_string(), "  C");
    }

    #[test]
    fn erase_chars_wide_char_boundary_conditions() {
        // ghostty: "Terminal: eraseChars wide char boundary conditions" (Terminal.zig:7604)
        let mut t = terminal(8, 1);
        t.print_string("😀a😀b😀");
        assert_eq!(t.plain_string(), "😀a😀b😀");
        t.set_cursor_pos(1, 2);
        t.erase_chars(3);
        t.active_screen().assert_integrity();
        assert_eq!(t.plain_string(), "     b😀");
    }

    #[test]
    fn erase_chars_wide_char_splits_proper_cell_boundaries() {
        // ghostty: "Terminal: eraseChars wide char splits proper cell boundaries" (Terminal.zig:7627)
        // Regression: https://github.com/ghostty-org/ghostty/issues/2817
        let mut t = terminal(30, 1);
        t.print_string("x食べて下さい");
        assert_eq!(t.plain_string(), "x食べて下さい");
        t.set_cursor_pos(1, 6); // At: て
        t.erase_chars(4); // Delete: て下
        t.active_screen().assert_integrity();
        assert_eq!(t.plain_string(), "x食べ    さい");
    }

    #[test]
    fn erase_chars_wide_char_wrap_boundary_conditions() {
        // ghostty: "Terminal: eraseChars wide char wrap boundary conditions" (Terminal.zig:7657)
        let mut t = terminal(8, 3);
        t.print_string(".......😀abcde😀......");
        assert_eq!(t.plain_string(), ".......\n😀abcde\n😀......");
        assert_eq!(t.plain_string_unwrapped(), ".......😀abcde😀......");
        t.set_cursor_pos(2, 2);
        t.erase_chars(3);
        t.active_screen().assert_integrity();
        assert_eq!(t.plain_string(), ".......\n    cde\n😀......");
        assert_eq!(t.plain_string_unwrapped(), ".......     cde\n😀......");
    }

    #[test]
    fn reverse_index_basic() {
        // ghostty: "Terminal: reverseIndex" (Terminal.zig:7688)
        let mut t = terminal(2, 5);
        t.print('A'); // Initial value
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.reverse_index();
        t.print('D');
        t.carriage_return();
        t.linefeed();
        t.carriage_return();
        t.linefeed();
        assert_eq!(t.plain_string(), "A\nBD\nC");
    }

    #[test]
    fn reverse_index_from_the_top() {
        // ghostty: "Terminal: reverseIndex from the top" (Terminal.zig:7715)
        let mut t = terminal(2, 5);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.carriage_return();
        t.linefeed();
        t.set_cursor_pos(1, 1);
        t.reverse_index();
        t.print('D');
        t.carriage_return();
        t.linefeed();
        t.set_cursor_pos(1, 1);
        t.reverse_index();
        t.print('E');
        t.carriage_return();
        t.linefeed();
        assert_eq!(t.plain_string(), "E\nD\nA\nB");
    }

    #[test]
    fn reverse_index_top_of_scrolling_region() {
        // ghostty: "Terminal: reverseIndex top of scrolling region" (Terminal.zig:7748)
        let mut t = terminal(2, 10);
        t.set_cursor_pos(2, 1); // Initial value
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.carriage_return();
        t.linefeed();
        t.print('D');
        t.carriage_return();
        t.linefeed();
        // Set our scroll region.
        t.set_top_and_bottom_margin(2, 5);
        t.set_cursor_pos(2, 1);
        t.reverse_index();
        t.print('X');
        assert_eq!(t.plain_string(), "\nX\nA\nB\nC");
    }

    #[test]
    fn reverse_index_top_of_screen() {
        // ghostty: "Terminal: reverseIndex top of screen" (Terminal.zig:7781)
        let mut t = terminal(5, 5);
        t.print('A');
        t.set_cursor_pos(2, 1);
        t.print('B');
        t.set_cursor_pos(3, 1);
        t.print('C');
        t.set_cursor_pos(1, 1);
        t.reverse_index();
        t.print('X');
        assert_eq!(t.plain_string(), "X\nA\nB\nC");
    }

    #[test]
    fn reverse_index_not_top_of_screen() {
        // ghostty: "Terminal: reverseIndex not top of screen" (Terminal.zig:7802)
        let mut t = terminal(5, 5);
        t.print('A');
        t.set_cursor_pos(2, 1);
        t.print('B');
        t.set_cursor_pos(3, 1);
        t.print('C');
        t.set_cursor_pos(2, 1);
        t.reverse_index();
        t.print('X');
        assert_eq!(t.plain_string(), "X\nB\nC");
    }

    #[test]
    fn reverse_index_top_bottom_margins() {
        // ghostty: "Terminal: reverseIndex top/bottom margins" (Terminal.zig:7823)
        let mut t = terminal(5, 5);
        t.print('A');
        t.set_cursor_pos(2, 1);
        t.print('B');
        t.set_cursor_pos(3, 1);
        t.print('C');
        t.set_top_and_bottom_margin(2, 3);
        t.set_cursor_pos(2, 1);
        t.reverse_index();
        assert_eq!(t.plain_string(), "A\n\nB");
    }

    #[test]
    fn reverse_index_outside_top_bottom_margins() {
        // ghostty: "Terminal: reverseIndex outside top/bottom margins" (Terminal.zig:7844)
        let mut t = terminal(5, 5);
        t.print('A');
        t.set_cursor_pos(2, 1);
        t.print('B');
        t.set_cursor_pos(3, 1);
        t.print('C');
        t.set_top_and_bottom_margin(2, 3);
        t.set_cursor_pos(1, 1);
        t.reverse_index();
        assert_eq!(t.plain_string(), "A\nB\nC");
    }

    #[test]
    fn reverse_index_left_right_margins() {
        // ghostty: "Terminal: reverseIndex left/right margins" (Terminal.zig:7865)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.set_cursor_pos(2, 1);
        t.print_string("DEF");
        t.set_cursor_pos(3, 1);
        t.print_string("GHI");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(2, 3);
        t.set_cursor_pos(1, 2);
        t.reverse_index();
        assert_eq!(t.plain_string(), "A\nDBC\nGEF\n HI");
    }

    #[test]
    fn reverse_index_outside_left_right_margins() {
        // ghostty: "Terminal: reverseIndex outside left/right margins" (Terminal.zig:7887)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.set_cursor_pos(2, 1);
        t.print_string("DEF");
        t.set_cursor_pos(3, 1);
        t.print_string("GHI");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(2, 3);
        t.set_cursor_pos(1, 1);
        t.reverse_index();
        assert_eq!(t.plain_string(), "ABC\nDEF\nGHI");
    }

    #[test]
    fn index_basic() {
        // ghostty: "Terminal: index" (Terminal.zig:7909)
        let mut t = terminal(2, 5);
        t.index();
        t.print('A');
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert_eq!(t.plain_string(), "\nA");
    }

    #[test]
    fn index_from_the_bottom() {
        // ghostty: "Terminal: index from the bottom" (Terminal.zig:7927)
        let mut t = terminal(2, 5);
        t.set_cursor_pos(5, 1);
        t.print('A');
        t.cursor_left(1); // undo moving right from 'A'
        t.clear_dirty();
        t.index();
        t.print('B');
        assert!(t.is_dirty(Point::active(0, 3)));
        assert!(t.is_dirty(Point::active(0, 4)));
        assert_eq!(t.plain_string(), "\n\n\nA\nB");
    }

    #[test]
    fn index_scrolling_with_hyperlink() {
        // ghostty: "Terminal: index scrolling with hyperlink" (Terminal.zig:7950)
        let mut t = terminal(2, 5);
        t.set_cursor_pos(5, 1);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print('A');
        t.active_screen_mut().end_hyperlink();
        t.cursor_left(1); // undo moving right from 'A'
        t.index();
        t.print('B');
        assert_eq!(t.plain_string(), "\n\n\nA\nB");
        {
            let p = Point::viewport(0, 3);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, 0, 3).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
        }
        {
            let p = Point::viewport(0, 4);
            assert!(!t.get_row(p).expect("row").hyperlink());
            assert!(!viewport_cell(&t, 0, 4).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
    }

    #[test]
    fn index_outside_of_scrolling_region() {
        // ghostty: "Terminal: index outside of scrolling region" (Terminal.zig:7995)
        let mut t = terminal(2, 5);
        assert_eq!(t.active_screen().cursor.y, 0);
        t.set_top_and_bottom_margin(2, 5);
        t.index();
        assert_eq!(t.active_screen().cursor.y, 1);
    }

    #[test]
    fn index_from_the_bottom_outside_of_scroll_region() {
        // ghostty: "Terminal: index from the bottom outside of scroll region" (Terminal.zig:8006)
        let mut t = terminal(2, 5);
        t.set_top_and_bottom_margin(1, 2);
        t.set_cursor_pos(5, 1);
        t.print('A');
        t.clear_dirty();
        t.index();
        t.print('B');
        assert!(t.is_dirty(Point::active(0, 4)));
        assert_eq!(t.plain_string(), "\n\n\n\nAB");
    }

    #[test]
    fn index_no_scroll_region_top_of_screen() {
        // ghostty: "Terminal: index no scroll region, top of screen" (Terminal.zig:8026)
        let mut t = terminal(5, 5);
        t.print('A');
        t.clear_dirty();
        t.index();
        t.print('X');
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert_eq!(t.plain_string(), "A\n X");
    }

    #[test]
    fn index_bottom_of_primary_screen() {
        // ghostty: "Terminal: index bottom of primary screen" (Terminal.zig:8046)
        let mut t = terminal(5, 5);
        t.set_cursor_pos(5, 1);
        t.print('A');
        t.clear_dirty();
        t.index();
        t.print('X');
        assert!(t.is_dirty(Point::active(0, 3)));
        assert!(t.is_dirty(Point::active(0, 4)));
        assert_eq!(t.plain_string(), "\n\n\nA\n X");
    }

    #[test]
    fn index_bottom_of_primary_screen_background_sgr() {
        // ghostty: "Terminal: index bottom of primary screen background sgr" (Terminal.zig:8067)
        let mut t = terminal(5, 5);
        t.set_cursor_pos(5, 1);
        t.print('A');
        t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.index();
        assert_eq!(t.plain_string(), "\n\n\nA");
        for x in 0..5 {
            let c = active_cell(&t, x, 4);
            assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
            assert_eq!(
                c.rgb(),
                crate::color::Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }
            );
        }
    }

    #[test]
    fn index_inside_scroll_region() {
        // ghostty: "Terminal: index inside scroll region" (Terminal.zig:8100)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(1, 3);
        t.print('A');
        t.clear_dirty();
        t.index();
        t.print('X');
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert_eq!(t.plain_string(), "A\n X");
    }

    #[test]
    fn index_bottom_of_scroll_region_with_hyperlinks() {
        // ghostty: "Terminal: index bottom of scroll region with hyperlinks" (Terminal.zig:8121)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(1, 2);
        t.print('A');
        t.index();
        t.carriage_return();
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print('B');
        t.active_screen_mut().end_hyperlink();
        t.index();
        t.carriage_return();
        t.print('C');
        assert_eq!(t.plain_string(), "B\nC");
        {
            let p = Point::viewport(0, 0);
            assert!(t.get_row(p).expect("row").hyperlink());
            assert!(viewport_cell(&t, 0, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), Some(1));
        }
        {
            let p = Point::viewport(0, 1);
            assert!(!t.get_row(p).expect("row").hyperlink());
            assert!(!viewport_cell(&t, 0, 1).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
        }
    }

    #[test]
    fn index_bottom_of_scroll_region_clear_hyperlinks() {
        // ghostty: "Terminal: index bottom of scroll region clear hyperlinks" (Terminal.zig:8169)
        let mut t = terminal_opts(5, 5, 0);
        t.set_top_and_bottom_margin(2, 3);
        t.set_cursor_pos(2, 1);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print('A');
        t.active_screen_mut().end_hyperlink();
        t.index();
        t.carriage_return();
        t.print('B');
        t.index();
        t.carriage_return();
        t.print('C');
        assert_eq!(t.plain_string(), "\nB\nC");
        for y in 1..3 {
            let p = Point::viewport(0, y);
            assert!(!t.get_row(p).expect("row").hyperlink());
            assert!(!viewport_cell(&t, 0, y).hyperlink());
            assert_eq!(t.hyperlink_id_at(p), None);
            assert_eq!(t.hyperlink_set_count_at(p), 0);
        }
    }

    #[test]
    fn index_bottom_of_scroll_region_with_background_sgr() {
        // ghostty: "Terminal: index bottom of scroll region with background SGR" (Terminal.zig:8208)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(1, 3);
        t.set_cursor_pos(4, 1);
        t.print('B');
        t.set_cursor_pos(3, 1);
        t.print('A');
        t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.index();
        assert_eq!(t.plain_string(), "\nA\n\nB");
        for x in 0..t.cols {
            let c = active_cell(&t, x, 2);
            assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
            assert_eq!(
                c.rgb(),
                crate::color::Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }
            );
        }
    }

    #[test]
    fn index_bottom_of_primary_screen_with_scroll_region() {
        // ghostty: "Terminal: index bottom of primary screen with scroll region" (Terminal.zig:8245)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(1, 3);
        t.set_cursor_pos(3, 1);
        t.print('A');
        t.set_cursor_pos(5, 1);
        t.clear_dirty();
        t.index();
        t.index();
        t.index();
        t.print('X');
        for y in 0..4 {
            assert!(!t.is_dirty(Point::active(0, y)));
        }
        assert!(t.is_dirty(Point::active(0, 4)));
        assert_eq!(t.plain_string(), "\n\nA\n\nX");
    }

    #[test]
    fn index_outside_left_right_margin() {
        // ghostty: "Terminal: index outside left/right margin" (Terminal.zig:8273)
        let mut t = terminal(10, 5);
        t.set_top_and_bottom_margin(1, 3);
        t.scrolling_region.left = 3;
        t.scrolling_region.right = 5;
        t.set_cursor_pos(3, 3);
        t.print('A');
        t.set_cursor_pos(3, 1);
        t.clear_dirty();
        t.index();
        t.print('X');
        assert!(t.is_dirty(Point::active(0, 2)));
        assert_eq!(t.plain_string(), "\n\nX A");
    }

    #[test]
    fn index_inside_left_right_margin() {
        // ghostty: "Terminal: index inside left/right margin" (Terminal.zig:8297)
        let mut t = terminal(10, 5);
        t.print_string("AAAAAA");
        t.carriage_return();
        t.linefeed();
        t.print_string("AAAAAA");
        t.carriage_return();
        t.linefeed();
        t.print_string("AAAAAA");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_top_and_bottom_margin(1, 3);
        t.set_left_and_right_margin(1, 3);
        t.set_cursor_pos(3, 1);
        t.clear_dirty();
        t.index();
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert_eq!(t.active_screen().cursor.y, 2);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.plain_string(), "AAAAAA\nAAAAAA\n   AAA");
    }

    #[test]
    fn index_bottom_of_scroll_region_creates_scrollback() {
        // ghostty: "Terminal: index bottom of scroll region creates scrollback" (Terminal.zig:8331)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(1, 3);
        t.print_string("1\n2\n3");
        t.set_cursor_pos(4, 1);
        t.print('X');
        t.set_cursor_pos(3, 1);
        t.index();
        t.print('Y');
        assert_eq!(
            t.active_screen().dump_string_for_tag(Tag::Viewport),
            "2\n3\nY\nX"
        );
        assert_eq!(
            t.active_screen().dump_string_for_tag(Tag::Screen),
            "1\n2\n3\nY\nX"
        );
    }

    #[test]
    fn index_bottom_of_scroll_region_no_scrollback() {
        // ghostty: "Terminal: index bottom of scroll region no scrollback" (Terminal.zig:8356)
        let mut t = terminal_opts(5, 5, 0);
        t.set_top_and_bottom_margin(1, 3);
        t.set_cursor_pos(4, 1);
        t.print('B');
        t.set_cursor_pos(3, 1);
        t.print('A');
        t.clear_dirty();
        t.index();
        t.print('X');
        assert_eq!(t.plain_string(), "\nA\n X\nB");
    }

    #[test]
    fn index_bottom_of_scroll_region_blank_line_preserves_sgr() {
        // ghostty: "Terminal: index bottom of scroll region blank line preserves SGR" (Terminal.zig:8377)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(1, 3);
        t.print_string("1\n2\n3");
        t.set_cursor_pos(4, 1);
        t.print('X');
        t.set_cursor_pos(3, 1);
        t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.index();
        assert_eq!(
            t.active_screen().dump_string_for_tag(Tag::Viewport),
            "2\n3\n\nX"
        );
        assert_eq!(
            t.active_screen().dump_string_for_tag(Tag::Screen),
            "1\n2\n3\n\nX"
        );
        for x in 0..t.cols {
            let c = active_cell(&t, x, 2);
            assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
            assert_eq!(
                c.rgb(),
                crate::color::Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }
            );
        }
    }

    #[test]
    fn cursor_up_basic() {
        // ghostty: "Terminal: cursorUp basic" (Terminal.zig:8418)
        let mut t = terminal(5, 5);
        t.set_cursor_pos(3, 1);
        t.print('A');
        t.cursor_up(10);
        t.print('X');
        assert_eq!(t.plain_string(), " X\n\nA");
    }

    #[test]
    fn cursor_up_below_top_scroll_margin() {
        // ghostty: "Terminal: cursorUp below top scroll margin" (Terminal.zig:8435)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(2, 4);
        t.set_cursor_pos(3, 1);
        t.print('A');
        t.cursor_up(5);
        t.print('X');
        assert_eq!(t.plain_string(), "\n X\nA");
    }

    #[test]
    fn cursor_up_above_top_scroll_margin() {
        // ghostty: "Terminal: cursorUp above top scroll margin" (Terminal.zig:8453)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(3, 5);
        t.set_cursor_pos(3, 1);
        t.print('A');
        t.set_cursor_pos(2, 1);
        t.cursor_up(10);
        t.print('X');
        assert_eq!(t.plain_string(), "X\n\nA");
    }

    #[test]
    fn cursor_up_resets_wrap() {
        // ghostty: "Terminal: cursorUp resets wrap" (Terminal.zig:8472)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.cursor_up(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDX");
    }

    #[test]
    fn cursor_left_no_wrap() {
        // ghostty: "Terminal: cursorLeft no wrap" (Terminal.zig:8490)
        let mut t = terminal(10, 5);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.cursor_left(10);
        assert_eq!(t.plain_string(), "A\nB");
    }

    #[test]
    fn cursor_left_unsets_pending_wrap_state() {
        // ghostty: "Terminal: cursorLeft unsets pending wrap state" (Terminal.zig:8508)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.cursor_left(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCXE");
    }

    #[test]
    fn cursor_left_unsets_pending_wrap_state_with_longer_jump() {
        // ghostty: "Terminal: cursorLeft unsets pending wrap state with longer jump" (Terminal.zig:8526)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.cursor_left(3);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "AXCDE");
    }

    #[test]
    fn cursor_left_reverse_wrap_with_pending_wrap_state() {
        // ghostty: "Terminal: cursorLeft reverse wrap with pending wrap state" (Terminal.zig:8544)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrap, true);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.cursor_left(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDX");
    }

    #[test]
    fn cursor_left_reverse_wrap_extended_with_pending_wrap_state() {
        // ghostty: "Terminal: cursorLeft reverse wrap extended with pending wrap state" (Terminal.zig:8565)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrapExtended, true);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.cursor_left(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDX");
    }

    #[test]
    fn cursor_left_reverse_wrap() {
        // ghostty: "Terminal: cursorLeft reverse wrap" (Terminal.zig:8586)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrap, true);
        for c in "ABCDE1".chars() {
            t.print(c);
        }
        t.cursor_left(2);
        t.print('X');
        assert!(t.active_screen().cursor.pending_wrap);
        assert_eq!(t.plain_string(), "ABCDX\n1");
    }

    #[test]
    fn cursor_left_reverse_wrap_with_no_soft_wrap() {
        // ghostty: "Terminal: cursorLeft reverse wrap with no soft wrap" (Terminal.zig:8606)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrap, true);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        t.print('1');
        t.cursor_left(2);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDE\nX");
    }

    #[test]
    fn cursor_left_reverse_wrap_before_left_margin() {
        // ghostty: "Terminal: cursorLeft reverse wrap before left margin" (Terminal.zig:8628)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrap, true);
        t.set_top_and_bottom_margin(3, 0);
        t.cursor_left(1);
        t.print('X');
        assert_eq!(t.plain_string(), "\n\nX");
    }

    #[test]
    fn cursor_left_extended_reverse_wrap() {
        // ghostty: "Terminal: cursorLeft extended reverse wrap" (Terminal.zig:8646)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrapExtended, true);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        t.print('1');
        t.cursor_left(2);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDX\n1");
    }

    #[test]
    fn cursor_left_extended_reverse_wrap_bottom_wraparound() {
        // ghostty: "Terminal: cursorLeft extended reverse wrap bottom wraparound" (Terminal.zig:8668)
        let mut t = terminal(5, 3);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrapExtended, true);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        t.print('1');
        t.cursor_left(1 + usize::from(t.cols) + 1);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDE\n1\n    X");
    }

    #[test]
    fn cursor_left_extended_reverse_wrap_is_priority_if_both_set() {
        // ghostty: "Terminal: cursorLeft extended reverse wrap is priority if both set" (Terminal.zig:8690)
        let mut t = terminal(5, 3);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrap, true);
        t.modes.set(Mode::ReverseWrapExtended, true);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        t.print('1');
        t.cursor_left(1 + usize::from(t.cols) + 1);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDE\n1\n    X");
    }

    #[test]
    fn cursor_left_extended_reverse_wrap_above_top_scroll_region() {
        // ghostty: "Terminal: cursorLeft extended reverse wrap above top scroll region" (Terminal.zig:8713)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrapExtended, true);
        t.set_top_and_bottom_margin(3, 0);
        t.set_cursor_pos(2, 1);
        t.cursor_left(1000);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 0);
    }

    #[test]
    fn cursor_left_reverse_wrap_on_first_row() {
        // ghostty: "Terminal: cursorLeft reverse wrap on first row" (Terminal.zig:8729)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Wraparound, true);
        t.modes.set(Mode::ReverseWrap, true);
        t.set_top_and_bottom_margin(3, 0);
        t.set_cursor_pos(1, 2);
        t.cursor_left(1000);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 0);
    }

    #[test]
    fn cursor_down_basic() {
        // ghostty: "Terminal: cursorDown basic" (Terminal.zig:8745)
        let mut t = terminal(5, 5);
        t.print('A');
        t.cursor_down(10);
        t.print('X');
        assert_eq!(t.plain_string(), "A\n\n\n\n X");
    }

    #[test]
    fn cursor_down_above_bottom_scroll_margin() {
        // ghostty: "Terminal: cursorDown above bottom scroll margin" (Terminal.zig:8761)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(1, 3);
        t.print('A');
        t.cursor_down(10);
        t.print('X');
        assert_eq!(t.plain_string(), "A\n\n X");
    }

    #[test]
    fn cursor_down_below_bottom_scroll_margin() {
        // ghostty: "Terminal: cursorDown below bottom scroll margin" (Terminal.zig:8778)
        let mut t = terminal(5, 5);
        t.set_top_and_bottom_margin(1, 3);
        t.print('A');
        t.set_cursor_pos(4, 1);
        t.cursor_down(10);
        t.print('X');
        assert_eq!(t.plain_string(), "A\n\n\n\nX");
    }

    #[test]
    fn cursor_down_resets_wrap() {
        // ghostty: "Terminal: cursorDown resets wrap" (Terminal.zig:8796)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.cursor_down(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDE\n    X");
    }

    #[test]
    fn cursor_right_resets_wrap() {
        // ghostty: "Terminal: cursorRight resets wrap" (Terminal.zig:8814)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.cursor_right(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDX");
    }

    #[test]
    fn cursor_right_to_the_edge_of_screen() {
        // ghostty: "Terminal: cursorRight to the edge of screen" (Terminal.zig:8832)
        let mut t = terminal(5, 5);
        t.cursor_right(100);
        t.print('X');
        assert_eq!(t.plain_string(), "    X");
    }

    #[test]
    fn cursor_right_left_of_right_margin() {
        // ghostty: "Terminal: cursorRight left of right margin" (Terminal.zig:8847)
        let mut t = terminal(5, 5);
        t.scrolling_region.right = 2;
        t.cursor_right(100);
        t.print('X');
        assert_eq!(t.plain_string(), "  X");
    }

    #[test]
    fn cursor_right_right_of_right_margin() {
        // ghostty: "Terminal: cursorRight right of right margin" (Terminal.zig:8863)
        let mut t = terminal(5, 5);
        t.scrolling_region.right = 2;
        t.set_cursor_pos(1, 4);
        t.cursor_right(100);
        t.print('X');
        assert_eq!(t.plain_string(), "    X");
    }

    #[test]
    fn delete_lines_simple() {
        // ghostty: "Terminal: deleteLines simple" (Terminal.zig:8880)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.delete_lines(1);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert_eq!(t.plain_string(), "ABC\nGHI");
    }

    #[test]
    fn delete_lines_colors_with_bg_color() {
        // ghostty: "Terminal: deleteLines colors with bg color" (Terminal.zig:8909)
        let mut t = terminal(5, 5);
        t.print_string("ABC");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI");
        t.set_cursor_pos(2, 2);
        t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.delete_lines(1);
        assert_eq!(t.plain_string(), "ABC\nGHI");
        for x in 0..t.cols {
            let c = active_cell(&t, x, 4);
            assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
            assert_eq!(
                c.rgb(),
                crate::color::Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }
            );
        }
    }

    #[test]
    fn delete_lines_across_page_boundary_marks_all_shifted_rows_dirty() {
        // ghostty: "Terminal: deleteLines across page boundary marks all shifted rows dirty" (Terminal.zig:8950)
        let mut t = terminal_opts(10, 5, 1024);
        let first_page_nrows = t.first_page_capacity_rows();
        // Fill up the first page minus 3 rows.
        for _ in 0..first_page_nrows - 3 {
            t.linefeed();
        }
        // Add content that will cross a page boundary.
        t.print_string("1AAAA");
        t.carriage_return();
        t.linefeed();
        t.print_string("2BBBB");
        t.carriage_return();
        t.linefeed();
        t.print_string("3CCCC");
        t.carriage_return();
        t.linefeed();
        t.print_string("4DDDD");
        t.carriage_return();
        t.linefeed();
        t.print_string("5EEEE");
        // Verify we now have a second page.
        assert!(t.active_screen().pages.total_pages() > 1);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.delete_lines(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(t.is_dirty(Point::active(0, 3)));
        assert!(t.is_dirty(Point::active(0, 4)));
        assert_eq!(t.plain_string(), "2BBBB\n3CCCC\n4DDDD\n5EEEE");
    }

    #[test]
    fn delete_lines_legacy() {
        // ghostty: "Terminal: deleteLines (legacy)" (Terminal.zig:8996)
        let mut t = terminal(80, 80);
        // Initial value
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.carriage_return();
        t.linefeed();
        t.print('D');
        t.cursor_up(2);
        t.delete_lines(1);
        t.print('E');
        t.carriage_return();
        t.linefeed();
        // We should be
        assert_eq!(t.active_screen().cursor.x, 0);
        assert_eq!(t.active_screen().cursor.y, 2);
        assert_eq!(t.plain_string(), "A\nE\nD");
    }

    #[test]
    fn delete_lines_with_scroll_region() {
        // ghostty: "Terminal: deleteLines with scroll region" (Terminal.zig:9031)
        let mut t = terminal(80, 80);
        // Initial value
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.carriage_return();
        t.linefeed();
        t.print('D');
        t.set_top_and_bottom_margin(1, 3);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.delete_lines(1);
        t.print('E');
        t.carriage_return();
        t.linefeed();
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(!t.is_dirty(Point::active(0, 3)));
        // We should be
        // assert_eq!(t.active_screen().cursor.x, 0);
        // assert_eq!(t.active_screen().cursor.y, 2);
        assert_eq!(t.plain_string(), "E\nC\n\nD");
    }

    #[test]
    fn delete_lines_with_scroll_region_large_count() {
        // ghostty: "Terminal: deleteLines with scroll region, large count" (Terminal.zig:9074)
        let mut t = terminal(80, 80);
        // Initial value
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.carriage_return();
        t.linefeed();
        t.print('D');
        t.set_top_and_bottom_margin(1, 3);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.delete_lines(5);
        t.print('E');
        t.carriage_return();
        t.linefeed();
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(t.is_dirty(Point::active(0, 1)));
        assert!(t.is_dirty(Point::active(0, 2)));
        assert!(!t.is_dirty(Point::active(0, 3)));
        // We should be
        // assert_eq!(t.active_screen().cursor.x, 0);
        // assert_eq!(t.active_screen().cursor.y, 2);
        assert_eq!(t.plain_string(), "E\n\n\nD");
    }

    #[test]
    fn delete_lines_with_scroll_region_cursor_outside_of_region() {
        // ghostty: "Terminal: deleteLines with scroll region, cursor outside of region" (Terminal.zig:9117)
        let mut t = terminal(80, 80);
        // Initial value
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.carriage_return();
        t.linefeed();
        t.print('C');
        t.carriage_return();
        t.linefeed();
        t.print('D');
        t.set_top_and_bottom_margin(1, 3);
        t.set_cursor_pos(4, 1);
        t.clear_dirty();
        t.delete_lines(1);
        for y in 0..4 {
            assert!(!t.is_dirty(Point::active(0, y)));
        }
        assert_eq!(t.plain_string(), "A\nB\nC\nD");
    }

    #[test]
    fn delete_lines_resets_pending_wrap() {
        // ghostty: "Terminal: deleteLines resets pending wrap" (Terminal.zig:9152)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.delete_lines(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('B');
        assert_eq!(t.plain_string(), "B");
    }

    #[test]
    fn delete_lines_resets_wrap() {
        // ghostty: "Terminal: deleteLines resets wrap" (Terminal.zig:9170)
        let mut t = terminal(3, 3);
        t.print('1');
        t.carriage_return();
        t.linefeed();
        for c in "ABCDEF".chars() {
            t.print(c);
        }
        t.set_top_and_bottom_margin(1, 2);
        t.set_cursor_pos(1, 1);
        t.delete_lines(1);
        t.print('X');
        assert_eq!(t.plain_string(), "XBC\n\nDEF");
        for y in 0..t.rows {
            let row = t.get_row(Point::active(0, u32::from(y))).expect("row");
            assert!(!row.wrap());
        }
    }

    #[test]
    fn delete_lines_left_right_scroll_region() {
        // ghostty: "Terminal: deleteLines left/right scroll region" (Terminal.zig:9201)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF456");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.delete_lines(1);
        assert!(!t.is_dirty(Point::active(0, 0)));
        for y in 1..3 {
            assert!(t.is_dirty(Point::active(0, y)));
        }
        assert_eq!(t.plain_string(), "ABC123\nDHI756\nG   89");
    }

    #[test]
    fn delete_lines_left_right_scroll_region_from_top() {
        // ghostty: "Terminal: deleteLines left/right scroll region from top" (Terminal.zig:9233)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF456");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.delete_lines(1);
        for y in 0..3 {
            assert!(t.is_dirty(Point::active(0, y)));
        }
        assert_eq!(t.plain_string(), "AEF423\nDHI756\nG   89");
    }

    #[test]
    fn delete_lines_left_right_scroll_region_high_count() {
        // ghostty: "Terminal: deleteLines left/right scroll region high count" (Terminal.zig:9264)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.carriage_return();
        t.linefeed();
        t.print_string("DEF456");
        t.carriage_return();
        t.linefeed();
        t.print_string("GHI789");
        t.scrolling_region.left = 1;
        t.scrolling_region.right = 3;
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.delete_lines(100);
        assert!(!t.is_dirty(Point::active(0, 0)));
        for y in 1..3 {
            assert!(t.is_dirty(Point::active(0, y)));
        }
        assert_eq!(t.plain_string(), "ABC123\nD   56\nG   89");
    }

    #[test]
    fn delete_lines_wide_character_spacer_head() {
        // ghostty: "Terminal: deleteLines wide character spacer head" (Terminal.zig:9296)
        let mut t = terminal(5, 3);
        // Initial value
        // +-----+
        // |AAAAA| < Wrapped
        // |BBBB*| < Wrapped     (continued)
        // |WWCCC| < Non-wrapped (continued)
        // +-----+
        // where * represents a spacer head cell
        // and WW is the wide character.
        t.print_string("AAAAABBBB\u{1F600}CCC");
        // Delete the top line
        // +-----+
        // |BBBB | < Non-wrapped
        // |WWCCC| < Non-wrapped
        // |     | < Non-wrapped
        // +-----+
        // This should convert the spacer head to
        // a regular empty cell, and un-set wrap.
        t.set_cursor_pos(1, 1);
        t.delete_lines(1);
        let str = t.plain_string();
        let unwrapped_str = t.plain_string_unwrapped();
        assert_eq!(str, "BBBB\n\u{1F600}CCC");
        assert_eq!(unwrapped_str, "BBBB\n\u{1F600}CCC");
    }

    #[test]
    fn delete_lines_wide_character_spacer_head_left_scroll_margin() {
        // ghostty: "Terminal: deleteLines wide character spacer head left scroll margin" (Terminal.zig:9332)
        let mut t = terminal(5, 3);
        // Initial value
        // +-----+
        // |AAAAA| < Wrapped
        // |BBBB*| < Wrapped     (continued)
        // |WWCCC| < Non-wrapped (continued)
        // +-----+
        // where * represents a spacer head cell
        // and WW is the wide character.
        t.print_string("AAAAABBBB\u{1F600}CCC");
        t.scrolling_region.left = 2;
        // Delete the top line
        //    ###  <- scrolling region
        // +-----+
        // |AABB | < Wrapped
        // |BBCCC| < Wrapped     (continued)
        // |WW   | < Non-wrapped (continued)
        // +-----+
        // This should convert the spacer head to
        // a regular empty cell, but due to the
        // left scrolling margin, wrap state should
        // remain.
        t.set_cursor_pos(1, 3);
        t.delete_lines(1);
        let str = t.plain_string();
        let unwrapped_str = t.plain_string_unwrapped();
        assert_eq!(str, "AABB\nBBCCC\n\u{1F600}");
        assert_eq!(unwrapped_str, "AABB BBCCC\u{1F600}");
    }

    #[test]
    fn delete_lines_wide_character_spacer_head_right_scroll_margin() {
        // ghostty: "Terminal: deleteLines wide character spacer head right scroll margin" (Terminal.zig:9373)
        let mut t = terminal(5, 3);
        // Initial value
        // +-----+
        // |AAAAA| < Wrapped
        // |BBBB*| < Wrapped     (continued)
        // |WWCCC| < Non-wrapped (continued)
        // +-----+
        // where * represents a spacer head cell
        // and WW is the wide character.
        t.print_string("AAAAABBBB\u{1F600}CCC");
        t.scrolling_region.right = 3;
        // Delete the top line
        //  ####   <- scrolling region
        // +-----+
        // |BBBBA| < Wrapped
        // |WWCC | < Wrapped     (continued)
        // |    C| < Non-wrapped (continued)
        // +-----+
        // This should convert the spacer head to
        // a regular empty cell, but due to the
        // right scrolling margin, wrap state should
        // remain.
        t.set_cursor_pos(1, 1);
        t.delete_lines(1);
        let str = t.plain_string();
        let unwrapped_str = t.plain_string_unwrapped();
        assert_eq!(str, "BBBBA\n\u{1F600}CC\n    C");
        assert_eq!(unwrapped_str, "BBBBA\u{1F600}CC     C");
    }

    #[test]
    fn delete_lines_wide_character_spacer_head_left_and_right_scroll_margin() {
        // ghostty: "Terminal: deleteLines wide character spacer head left and right scroll margin" (Terminal.zig:9414)
        let mut t = terminal(5, 3);
        // Initial value
        // +-----+
        // |AAAAA| < Wrapped
        // |BBBB*| < Wrapped     (continued)
        // |WWCCC| < Non-wrapped (continued)
        // +-----+
        // where * represents a spacer head cell
        // and WW is the wide character.
        t.print_string("AAAAABBBB\u{1F600}CCC");
        t.scrolling_region.right = 3;
        t.scrolling_region.left = 2;
        // Delete the top line
        //    ##   <- scrolling region
        // +-----+
        // |AABBA| < Wrapped
        // |BBCC*| < Wrapped     (continued)
        // |WW  C| < Non-wrapped (continued)
        // +-----+
        // Because there is both a left scrolling
        // margin > 1 and a right scrolling margin
        // the spacer head should remain, and the
        // wrap state should be untouched.
        t.set_cursor_pos(1, 3);
        t.delete_lines(1);
        let str = t.plain_string();
        let unwrapped_str = t.plain_string_unwrapped();
        assert_eq!(str, "AABBA\nBBCC\n\u{1F600}  C");
        assert_eq!(unwrapped_str, "AABBABBCC\u{1F600}  C");
    }

    #[test]
    fn delete_lines_wide_character_spacer_head_left_lt_2_and_right_scroll_margin() {
        // ghostty: "Terminal: deleteLines wide character spacer head left (< 2) and right scroll margin" (Terminal.zig:9456)
        let mut t = terminal(5, 3);
        // Initial value
        // +-----+
        // |AAAAA| < Wrapped
        // |BBBB*| < Wrapped     (continued)
        // |WWCCC| < Non-wrapped (continued)
        // +-----+
        // where * represents a spacer head cell
        // and WW is the wide character.
        t.print_string("AAAAABBBB\u{1F600}CCC");
        t.scrolling_region.right = 3;
        t.scrolling_region.left = 1;
        // Delete the top line
        //   ###   <- scrolling region
        // +-----+
        // |ABBBA| < Wrapped
        // |B CC | < Wrapped     (continued)
        // |    C| < Non-wrapped (continued)
        // +-----+
        // Because the left margin is 1, the wide
        // char is split, and therefore removed,
        // along with the spacer head - however,
        // wrap state should be untouched.
        t.set_cursor_pos(1, 2);
        t.delete_lines(1);
        let str = t.plain_string();
        let unwrapped_str = t.plain_string_unwrapped();
        assert_eq!(str, "ABBBA\nB CC\n    C");
        assert_eq!(unwrapped_str, "ABBBAB CC     C");
    }

    #[test]
    fn delete_lines_wide_characters_split_by_left_right_scroll_region_boundaries() {
        // ghostty: "Terminal: deleteLines wide characters split by left/right scroll region boundaries" (Terminal.zig:9498)
        let mut t = terminal(5, 2);
        // Initial value
        // +-----+
        // |AAAAA|
        // |WWBWW|
        // +-----+
        // where WW represents a wide character
        t.print_string("AAAAA\n\u{1F600}B\u{1F600}");
        t.scrolling_region.right = 3;
        t.scrolling_region.left = 1;
        // Delete the top line
        //   ###   <- scrolling region
        // +-----+
        // |A B A|
        // |     |
        // +-----+
        // The two wide chars, because they're
        // split by the edge of the scrolling
        // region, get removed.
        t.set_cursor_pos(1, 2);
        t.delete_lines(1);
        assert_eq!(t.plain_string(), "A B A");
    }

    #[test]
    fn delete_lines_zero() {
        // ghostty: "Terminal: deleteLines zero" (Terminal.zig:9533)
        let mut t = terminal(2, 5);
        // This should do nothing
        t.set_cursor_pos(1, 1);
        t.delete_lines(0);
    }

    #[test]
    fn default_style_is_empty() {
        // ghostty: "Terminal: default style is empty" (Terminal.zig:9543)
        let mut t = terminal(5, 5);
        t.print('A');
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('A'));
        assert_eq!(c.style_id(), 0);
    }

    #[test]
    fn bold_style() {
        // ghostty: "Terminal: bold style" (Terminal.zig:9558)
        let mut t = terminal(5, 5);
        t.set_attribute(crate::sgr::Attribute::Bold);
        t.print('A');
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('A'));
        assert!(c.style_id() != 0);
        assert!(t.cursor_page_style_ref_count() > 1);
    }

    #[test]
    fn garbage_collect_overwritten() {
        // ghostty: "Terminal: garbage collect overwritten" (Terminal.zig:9576)
        let mut t = terminal(5, 5);
        t.set_attribute(crate::sgr::Attribute::Bold);
        t.print('A');
        t.set_cursor_pos(1, 1);
        t.set_attribute(crate::sgr::Attribute::Unset);
        t.print('B');
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), u32::from('B'));
        assert_eq!(c.style_id(), 0);
        // verify we have no styles in our style map
        assert_eq!(t.cursor_page_style_count(), 0);
    }

    #[test]
    fn do_not_garbage_collect_old_styles_in_use() {
        // ghostty: "Terminal: do not garbage collect old styles in use" (Terminal.zig:9599)
        let mut t = terminal(5, 5);
        t.set_attribute(crate::sgr::Attribute::Bold);
        t.print('A');
        t.set_attribute(crate::sgr::Attribute::Unset);
        t.print('B');
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), u32::from('B'));
        assert_eq!(c.style_id(), 0);
        // verify we have no styles in our style map
        assert_eq!(t.cursor_page_style_count(), 1);
    }

    #[test]
    fn print_with_style_marks_the_row_as_styled() {
        // ghostty: "Terminal: print with style marks the row as styled" (Terminal.zig:9621)
        let mut t = terminal(5, 5);
        t.set_attribute(crate::sgr::Attribute::Bold);
        t.print('A');
        t.set_attribute(crate::sgr::Attribute::Unset);
        t.print('B');
        let row = t.get_row(screen_point(0, 0)).expect("row");
        assert!(row.styled());
    }

    #[test]
    fn decaln() {
        // ghostty: "Terminal: DECALN" (Terminal.zig:9637)
        let mut t = terminal(2, 2);
        // Initial value
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.print('B');
        t.decaln();
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        for y in 0..t.rows {
            assert!(t.is_dirty(Point::active(0, u32::from(y))));
        }
        assert_eq!(t.plain_string(), "EE\nEE");
    }

    #[test]
    fn decaln_reset_margins() {
        // ghostty: "Terminal: decaln reset margins" (Terminal.zig:9664)
        let mut t = terminal(3, 3);
        // Initial value
        t.modes.set(Mode::Origin, true);
        t.set_top_and_bottom_margin(2, 3);
        t.decaln();
        t.scroll_down(1);
        assert_eq!(t.plain_string(), "\nEEE\nEEE");
    }

    #[test]
    fn decaln_preserves_color() {
        // ghostty: "Terminal: decaln preserves color" (Terminal.zig:9682)
        let mut t = terminal(3, 3);
        // Initial value
        t.set_attribute(crate::sgr::Attribute::DirectColorBg(crate::color::Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.modes.set(Mode::Origin, true);
        t.set_top_and_bottom_margin(2, 3);
        t.decaln();
        t.scroll_down(1);
        assert_eq!(t.plain_string(), "\nEEE\nEEE");
        let c = active_cell(&t, 0, 0);
        assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
        assert_eq!(
            c.rgb(),
            crate::color::Rgb {
                r: 0xFF,
                g: 0,
                b: 0
            }
        );
    }

    #[test]
    fn decaln_resets_graphemes_with_protected_mode() {
        // ghostty: "Terminal: DECALN resets graphemes with protected mode" (Terminal.zig:9711)
        let mut t = terminal(3, 3);
        // Add protected mode. A previous version of DECALN accidentally preserved
        // protected mode which left dangling managed memory.
        t.set_protected_mode(ProtectedMode::Iso);
        // This is: 👨‍👩‍👧 (which may or may not render correctly)
        t.modes.set(Mode::GraphemeCluster, true);
        print_cp(&mut t, 0x1F468);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F469);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F467);
        t.decaln();
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert!(t.active_screen().cursor.protected);
        assert!(t.protected_mode == ProtectedMode::Iso);
        for y in 0..t.rows {
            assert!(t.is_dirty(Point::active(0, u32::from(y))));
        }
        assert_eq!(t.plain_string(), "EEE\nEEE\nEEE");
    }

    #[test]
    fn insert_blanks_zero() {
        // ghostty: "Terminal: insertBlanks zero" (Terminal.zig:9747)
        let mut t = terminal(5, 2);
        t.print('A');
        t.print('B');
        t.print('C');
        t.set_cursor_pos(1, 1);
        t.insert_blanks(0);
        assert_eq!(t.plain_string(), "ABC");
    }

    #[test]
    fn insert_blanks() {
        // ghostty: "Terminal: insertBlanks" (Terminal.zig:9766)
        let mut t = terminal(5, 2);
        t.print('A');
        t.print('B');
        t.print('C');
        // NOTE: this is not verified with conformance tests, so these
        // tests might actually be verifying wrong behavior.
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_blanks(2);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert!(!t.is_dirty(Point::active(0, 1)));
        assert_eq!(t.plain_string(), "  ABC");
    }

    #[test]
    fn insert_blanks_pushes_off_end() {
        // ghostty: "Terminal: insertBlanks pushes off end" (Terminal.zig:9790)
        let mut t = terminal(3, 2);
        t.print('A');
        t.print('B');
        t.print('C');
        // NOTE: this is not verified with conformance tests, so these
        // tests might actually be verifying wrong behavior.
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_blanks(2);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "  A");
    }

    #[test]
    fn insert_blanks_more_than_size() {
        // ghostty: "Terminal: insertBlanks more than size" (Terminal.zig:9813)
        let mut t = terminal(3, 2);
        t.print('A');
        t.print('B');
        t.print('C');
        // NOTE: this is not verified with conformance tests, so these
        // tests might actually be verifying wrong behavior.
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_blanks(5);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "");
    }

    #[test]
    fn insert_blanks_no_scroll_region_fits() {
        // ghostty: "Terminal: insertBlanks no scroll region, fits" (Terminal.zig:9836)
        let mut t = terminal(10, 10);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_blanks(2);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "  ABC");
    }

    #[test]
    fn insert_blanks_preserves_background_sgr() {
        // ghostty: "Terminal: insertBlanks preserves background sgr" (Terminal.zig:9855)
        let mut t = terminal(10, 10);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.insert_blanks(2);
        assert_eq!(t.plain_string(), "  ABC");
        let c = active_cell(&t, 0, 0);
        assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
        assert_eq!(
            c.rgb(),
            Rgb {
                r: 0xFF,
                g: 0,
                b: 0
            }
        );
    }

    #[test]
    fn insert_blanks_shift_off_screen() {
        // ghostty: "Terminal: insertBlanks shift off screen" (Terminal.zig:9885)
        let mut t = terminal(5, 10);
        for c in "  ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 3);
        t.clear_dirty();
        t.insert_blanks(2);
        assert!(t.is_dirty(Point::active(0, 0)));
        t.print('X');
        assert_eq!(t.plain_string(), "  X A");
    }

    #[test]
    fn insert_blanks_split_multi_cell_character() {
        // ghostty: "Terminal: insertBlanks split multi-cell character" (Terminal.zig:9904)
        let mut t = terminal(5, 10);
        for c in "123".chars() {
            t.print(c);
        }
        t.print('橋');
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_blanks(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), " 123");
    }

    #[test]
    fn insert_blanks_inside_left_right_scroll_region() {
        // ghostty: "Terminal: insertBlanks inside left/right scroll region" (Terminal.zig:9923)
        let mut t = terminal(10, 10);
        t.scrolling_region.left = 2;
        t.scrolling_region.right = 4;
        t.set_cursor_pos(1, 3);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 3);
        t.clear_dirty();
        t.insert_blanks(2);
        assert!(t.is_dirty(Point::active(0, 0)));
        t.print('X');
        assert_eq!(t.plain_string(), "  X A");
    }

    #[test]
    fn insert_blanks_outside_left_right_scroll_region() {
        // ghostty: "Terminal: insertBlanks outside left/right scroll region" (Terminal.zig:9946)
        let mut t = terminal(6, 10);
        t.set_cursor_pos(1, 4);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.scrolling_region.left = 2;
        t.scrolling_region.right = 4;
        assert!(t.active_screen().cursor.pending_wrap);
        t.clear_dirty();
        t.insert_blanks(2);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "   ABX");
    }

    #[test]
    fn insert_blanks_left_right_scroll_region_large_count() {
        // ghostty: "Terminal: insertBlanks left/right scroll region large count" (Terminal.zig:9969)
        let mut t = terminal(10, 10);
        t.modes.set(Mode::Origin, true);
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(3, 5);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_blanks(140);
        assert!(t.is_dirty(Point::active(0, 0)));
        t.print('X');
        assert_eq!(t.plain_string(), "  X");
    }

    #[test]
    fn insert_blanks_deleting_graphemes() {
        // ghostty: "Terminal: insertBlanks deleting graphemes" (Terminal.zig:9990)
        let mut t = terminal(5, 5);
        // Disable grapheme clustering
        t.modes.set(Mode::GraphemeCluster, true);
        t.print_string("ABC");
        // This is: 👨‍👩‍👧 (which may or may not render correctly)
        print_cp(&mut t, 0x1F468);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F469);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F467);
        // We should have one cell with graphemes
        assert_eq!(t.cursor_page_grapheme_count(), 1);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_blanks(4);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "    A");
        // We should have no graphemes
        assert_eq!(t.cursor_page_grapheme_count(), 0);
    }

    #[test]
    fn insert_blanks_shift_graphemes() {
        // ghostty: "Terminal: insertBlanks shift graphemes" (Terminal.zig:10026)
        let mut t = terminal(5, 5);
        // Enable grapheme clustering
        t.modes.set(Mode::GraphemeCluster, true);
        t.print_string("A");
        // This is: 👨‍👩‍👧 (which may or may not render correctly)
        print_cp(&mut t, 0x1F468);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F469);
        print_cp(&mut t, 0x200D);
        print_cp(&mut t, 0x1F467);
        // We should have one cell with graphemes
        assert_eq!(t.cursor_page_grapheme_count(), 1);
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.insert_blanks(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), " A👨‍👩‍👧");
        // We should have no graphemes
        assert_eq!(t.cursor_page_grapheme_count(), 1);
    }

    #[test]
    fn insert_blanks_split_multi_cell_character_from_tail() {
        // ghostty: "Terminal: insertBlanks split multi-cell character from tail" (Terminal.zig:10062)
        let mut t = terminal(5, 10);
        t.print_string("橋123");
        t.set_cursor_pos(1, 2);
        t.insert_blanks(1);
        assert_eq!(t.plain_string(), "   12");
    }

    #[test]
    fn insert_blanks_shifts_hyperlinks() {
        // ghostty: "Terminal: insertBlanks shifts hyperlinks" (Terminal.zig:10078)
        // osc "8;;http://example.com"
        // printf "link"
        // printf "\r"
        // csi "3@"
        // echo
        //
        // link should be preserved, blanks should not be linked
        let mut t = terminal(10, 2);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("ABC");
        t.set_cursor_pos(1, 1);
        t.insert_blanks(2);
        assert_eq!(t.plain_string(), "  ABC");
        // Verify all our cells have a hyperlink
        for x in 2..5 {
            assert!(t.get_row(screen_point(x, 0)).unwrap().hyperlink());
            assert!(cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), Some(1));
        }
        for x in 0..2 {
            assert!(!cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), None);
        }
    }

    #[test]
    fn insert_blanks_pushes_hyperlink_off_end_completely() {
        // ghostty: "Terminal: insertBlanks pushes hyperlink off end completely" (Terminal.zig:10127)
        let mut t = terminal(3, 2);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.print_string("ABC");
        t.set_cursor_pos(1, 1);
        t.insert_blanks(3);
        assert_eq!(t.plain_string(), "");
        for x in 0..3 {
            assert!(!t.get_row(screen_point(x, 0)).unwrap().hyperlink());
            assert!(!cell(&t, x, 0).hyperlink());
            assert_eq!(t.hyperlink_id_at(screen_point(x, 0)), None);
        }
    }

    #[test]
    fn insert_blanks_wide_char_straddling_right_margin() {
        // ghostty: "Terminal: insertBlanks wide char straddling right margin" (Terminal.zig:10157)
        // Crash found by AFL++ fuzzer.
        //
        // When a wide character straddles the right scroll margin (head at the
        // margin, spacer_tail just beyond it), insertBlanks shifts the wide head
        // away via swapCells but leaves the orphaned spacer_tail in place,
        // causing a page integrity violation.
        let mut t = terminal(10, 5);
        // Fill row: A B C D 橋 _ _ _ _ _
        // Positions: 0 1 2 3 4W 5T 6 7 8 9
        t.set_cursor_pos(1, 1);
        for c in "ABCD".chars() {
            t.print(c);
        }
        t.print('橋'); // wide char: head at 4, spacer_tail at 5
                       // Set right margin so the wide head is AT the boundary and the
                       // spacer_tail is just outside it.
        t.scrolling_region.right = 4;
        // Position cursor at x=2 (1-indexed col 3) and insert one blank. This
        // triggers the swap loop which displaces the wide head at position 4
        // without clearing the spacer_tail at position 5.
        t.set_cursor_pos(1, 3);
        t.insert_blanks(1);
        assert_eq!(t.plain_string(), "AB CD");
    }

    #[test]
    fn insert_blanks_wide_char_spacer_tail_orphaned_beyond_right_margin() {
        // ghostty: "Terminal: insertBlanks wide char spacer_tail orphaned beyond right margin" (Terminal.zig:10191)
        // Regression test for AFL++ crash.
        //
        // When insertBlanks clears the entire region from cursor to the right
        // margin (scroll_amount == 0), a wide character whose head is AT the
        // right margin gets cleared but its spacer_tail just beyond the margin
        // is left behind, causing a page integrity violation:
        //   "spacer tail not following wide"
        let mut t = terminal(10, 5);
        // Fill cols 0–9 with wide chars: 中中中中中
        // Positions: 0W 1T 2W 3T 4W 5T 6W 7T 8W 9T
        for _ in 0..5 {
            print_cp(&mut t, 0x4E2D);
        }
        // Set left/right margins so that the last wide char (cols 8–9)
        // straddles the boundary: head at col 8 (inside), tail at col 9 (outside).
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(1, 9); // 1-indexed: left=0, right=8
                                           // Cursor is now at (0, 0) after DECSLRM. Print a narrow char to advance
                                           // cursor to col 1.
        t.print('a');
        // ICH 8: insert 8 blanks at cursor x=1.
        // rem = right(8) - x(1) + 1 = 8, adjusted_count = 8, scroll_amount = 0.
        // The code clears cols 1–8 without noticing the spacer_tail at col 9.
        t.insert_blanks(8);
        assert_eq!(t.plain_string(), "a");
    }

    #[test]
    fn insert_mode_with_space() {
        // ghostty: "Terminal: insert mode with space" (Terminal.zig:10228)
        let mut t = terminal(10, 2);
        for c in "hello".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.modes.set(Mode::Insert, true);
        t.print('X');
        assert_eq!(t.plain_string(), "hXello");
    }

    #[test]
    fn insert_mode_doesnt_wrap_pushed_characters() {
        // ghostty: "Terminal: insert mode doesn't wrap pushed characters" (Terminal.zig:10245)
        let mut t = terminal(5, 2);
        for c in "hello".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.modes.set(Mode::Insert, true);
        t.print('X');
        assert_eq!(t.plain_string(), "hXell");
    }

    #[test]
    fn insert_mode_does_nothing_at_the_end_of_the_line() {
        // ghostty: "Terminal: insert mode does nothing at the end of the line" (Terminal.zig:10262)
        let mut t = terminal(5, 2);
        for c in "hello".chars() {
            t.print(c);
        }
        t.modes.set(Mode::Insert, true);
        t.print('X');
        assert_eq!(t.plain_string(), "hello\nX");
    }

    #[test]
    fn insert_mode_with_wide_characters() {
        // ghostty: "Terminal: insert mode with wide characters" (Terminal.zig:10278)
        let mut t = terminal(5, 2);
        for c in "hello".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.modes.set(Mode::Insert, true);
        t.print('😀'); // 0x1F600
        assert_eq!(t.plain_string(), "h😀el");
    }

    #[test]
    fn insert_mode_with_wide_characters_at_end() {
        // ghostty: "Terminal: insert mode with wide characters at end" (Terminal.zig:10295)
        let mut t = terminal(5, 2);
        for c in "well".chars() {
            t.print(c);
        }
        t.modes.set(Mode::Insert, true);
        t.print('😀'); // 0x1F600
        assert_eq!(t.plain_string(), "well\n😀");
    }

    #[test]
    fn insert_mode_pushing_off_wide_character() {
        // ghostty: "Terminal: insert mode pushing off wide character" (Terminal.zig:10311)
        let mut t = terminal(5, 2);
        for c in "123".chars() {
            t.print(c);
        }
        t.print('😀'); // 0x1F600
        t.modes.set(Mode::Insert, true);
        t.set_cursor_pos(1, 1);
        t.print('X');
        assert_eq!(t.plain_string(), "X123");
    }

    #[test]
    fn delete_chars() {
        // ghostty: "Terminal: deleteChars" (Terminal.zig:10329)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.delete_chars(2);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "ADE");
    }

    #[test]
    fn delete_chars_zero_count() {
        // ghostty: "Terminal: deleteChars zero count" (Terminal.zig:10348)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.delete_chars(0);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "ABCDE");
    }

    #[test]
    fn delete_chars_more_than_half() {
        // ghostty: "Terminal: deleteChars more than half" (Terminal.zig:10367)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.delete_chars(3);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "AE");
    }

    #[test]
    fn delete_chars_more_than_line_width() {
        // ghostty: "Terminal: deleteChars more than line width" (Terminal.zig:10386)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.delete_chars(10);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "A");
    }

    #[test]
    fn delete_chars_should_shift_left() {
        // ghostty: "Terminal: deleteChars should shift left" (Terminal.zig:10405)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.delete_chars(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "ACDE");
    }

    #[test]
    fn delete_chars_resets_pending_wrap() {
        // ghostty: "Terminal: deleteChars resets pending wrap" (Terminal.zig:10424)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.delete_chars(1);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('X');
        assert_eq!(t.plain_string(), "ABCDX");
    }

    #[test]
    fn delete_chars_resets_wrap() {
        // ghostty: "Terminal: deleteChars resets wrap" (Terminal.zig:10442)
        let mut t = terminal(5, 5);
        for c in "ABCDE123".chars() {
            t.print(c);
        }
        assert!(t.get_row(Point::active(0, 0)).unwrap().wrap());
        t.set_cursor_pos(1, 1);
        t.delete_chars(1);
        assert!(!t.get_row(Point::active(0, 0)).unwrap().wrap());
        t.print('X');
        assert_eq!(t.plain_string(), "XCDE\n123");
    }

    #[test]
    fn delete_chars_simple_operation() {
        // ghostty: "Terminal: deleteChars simple operation" (Terminal.zig:10471)
        let mut t = terminal(10, 10);
        t.print_string("ABC123");
        t.set_cursor_pos(1, 3);
        t.clear_dirty();
        t.delete_chars(2);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "AB23");
    }

    #[test]
    fn delete_chars_preserves_background_sgr() {
        // ghostty: "Terminal: deleteChars preserves background sgr" (Terminal.zig:10490)
        let mut t = terminal(10, 10);
        for c in "ABC123".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 3);
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.delete_chars(2);
        assert_eq!(t.plain_string(), "AB23");
        for x in (t.cols - 2)..t.cols {
            let c = active_cell(&t, x, 0);
            assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
            assert_eq!(
                c.rgb(),
                Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }
            );
        }
    }

    #[test]
    fn delete_chars_outside_scroll_region() {
        // ghostty: "Terminal: deleteChars outside scroll region" (Terminal.zig:10523)
        let mut t = terminal(6, 10);
        t.print_string("ABC123");
        t.scrolling_region.left = 2;
        t.scrolling_region.right = 4;
        assert!(t.active_screen().cursor.pending_wrap);
        t.clear_dirty();
        t.delete_chars(2);
        assert!(!t.is_dirty(Point::active(0, 0)));
        assert!(t.active_screen().cursor.pending_wrap);
        assert_eq!(t.plain_string(), "ABC123");
    }

    #[test]
    fn delete_chars_inside_scroll_region() {
        // ghostty: "Terminal: deleteChars inside scroll region" (Terminal.zig:10544)
        let mut t = terminal(6, 10);
        t.print_string("ABC123");
        t.scrolling_region.left = 2;
        t.scrolling_region.right = 4;
        t.set_cursor_pos(1, 4);
        t.clear_dirty();
        t.delete_chars(1);
        assert!(t.is_dirty(Point::active(0, 0)));
        assert_eq!(t.plain_string(), "ABC2 3");
    }

    #[test]
    fn delete_chars_split_wide_character_from_spacer_tail() {
        // ghostty: "Terminal: deleteChars split wide character from spacer tail" (Terminal.zig:10565)
        let mut t = terminal(6, 10);
        t.print_string("A橋123");
        t.set_cursor_pos(1, 3);
        t.delete_chars(1);
        assert_eq!(t.plain_string(), "A 123");
    }

    #[test]
    fn delete_chars_split_wide_character_from_wide() {
        // ghostty: "Terminal: deleteChars split wide character from wide" (Terminal.zig:10581)
        let mut t = terminal(6, 10);
        t.print_string("橋123");
        t.set_cursor_pos(1, 1);
        t.delete_chars(1);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), u32::from('1'));
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn delete_chars_split_wide_character_from_end() {
        // ghostty: "Terminal: deleteChars split wide character from end" (Terminal.zig:10604)
        let mut t = terminal(6, 10);
        t.print_string("A橋123");
        t.set_cursor_pos(1, 1);
        t.delete_chars(1);
        let c = cell(&t, 0, 0);
        assert_eq!(c.codepoint(), 0x6A4B);
        assert_eq!(c.wide(), CellWide::Wide);
        let c = cell(&t, 1, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn delete_chars_with_a_spacer_head_at_the_end() {
        // ghostty: "Terminal: deleteChars with a spacer head at the end" (Terminal.zig:10627)
        let mut t = terminal(5, 10);
        t.print_string("0123橋123");
        {
            let c = cell(&t, 4, 0);
            assert_eq!(c.wide(), CellWide::SpacerHead);
            assert!(t.get_row(screen_point(4, 0)).unwrap().wrap());
        }
        t.set_cursor_pos(1, 1);
        t.delete_chars(1);
        let c = cell(&t, 3, 0);
        assert_eq!(c.codepoint(), 0);
        assert_eq!(c.wide(), CellWide::Narrow);
    }

    #[test]
    fn delete_chars_split_wide_character_tail() {
        // ghostty: "Terminal: deleteChars split wide character tail" (Terminal.zig:10652)
        let mut t = terminal(5, 5);
        t.set_cursor_pos(1, t.cols - 1);
        print_cp(&mut t, 0x6A4B); // 橋
        t.carriage_return();
        t.delete_chars(usize::from(t.cols - 1));
        t.print('0');
        assert_eq!(t.plain_string(), "0");
    }

    #[test]
    fn delete_chars_wide_char_boundary_conditions() {
        // ghostty: "Terminal: deleteChars wide char boundary conditions" (Terminal.zig:10670)
        let mut t = terminal(8, 1);

        // EXPLANATION(qwerasd):
        //
        // There are 3 or 4 boundaries to be concerned with in deleteChars,
        // depending on how you count them. Consider the following terminal:
        //
        //   +--------+
        // 0 |.ABCDEF.|
        //   : ^      : (^ = cursor)
        //   +--------+
        //
        // if we DCH 3 we get
        //
        //   +--------+
        // 0 |.DEF....|
        //   +--------+
        //
        // The boundaries exist at the following points then:
        //
        //   +--------+
        // 0 |.ABCDEF.|
        //   :11 22 33:
        //   +--------+
        //
        // I'm counting 2 for double since it's both the end of the deleted
        // content and the start of the content that is shifted in to place.
        //
        // Now consider wide characters (represented as `WW`) at these boundaries:
        //
        //   +--------+
        // 0 |WWaWWbWW|
        //   : ^      : (^ = cursor)
        //   : ^^^    : (^ = deleted by DCH 3)
        //   +--------+
        //
        // -> DCH 3
        // -> The first 2 wide characters are split & destroyed (verified in xterm)
        //
        //   +--------+
        // 0 |..bWW...|
        //   +--------+
        t.print_string("😀a😀b😀");
        assert_eq!(t.plain_string(), "😀a😀b😀");
        t.set_cursor_pos(1, 2);
        t.delete_chars(3);
        t.active_screen().assert_integrity();
        assert_eq!(t.plain_string(), "  b😀");
    }

    #[test]
    fn delete_chars_wide_char_wrap_boundary_conditions() {
        // ghostty: "Terminal: deleteChars wide char wrap boundary conditions" (Terminal.zig:10734)
        let mut t = terminal(8, 3);

        // EXPLANATION(qwerasd):
        // (cont. from "Terminal: deleteChars wide char boundary conditions")
        //
        // Additionally consider soft-wrapped wide chars (`H` = spacer head):
        //
        //   +--------+
        // 0 |.......H…
        // 1 …WWabcdeH…
        //   : ^      : (^ = cursor)
        //   : ^^^    : (^ = deleted by DCH 3)
        // 2 …WW......|
        //   +--------+
        //
        // -> DCH 3
        // -> First wide character split and destroyed, including spacer head,
        //    second spacer head removed (verified in xterm).
        // -> Wrap state of row reset
        //
        //   +--------+
        // 0 |........|
        // 1 |.cde....|
        // 2 |WW......|
        //   +--------+
        t.print_string(".......😀abcde😀......");
        assert_eq!(t.plain_string(), ".......\n😀abcde\n😀......");
        assert_eq!(t.plain_string_unwrapped(), ".......😀abcde😀......");
        t.set_cursor_pos(2, 2);
        t.delete_chars(3);
        t.active_screen().assert_integrity();
        assert_eq!(t.plain_string(), ".......\n cde\n😀......");
        assert_eq!(t.plain_string_unwrapped(), ".......  cde\n😀......");
    }

    #[test]
    fn delete_chars_wide_char_across_right_margin() {
        // ghostty: "Terminal: deleteChars wide char across right margin" (Terminal.zig:10790)
        let mut t = terminal(8, 3);

        // scroll region
        //    VVVVVV
        //  +-######-+
        //  |.abcdeWW|
        //  : ^      : (^ = cursor)
        //  +--------+
        //
        // DCH 1
        t.print_string("123456橋");
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(2, 7);
        assert_eq!(t.plain_string(), "123456橋");
        t.set_cursor_pos(1, 2);
        t.delete_chars(1);
        t.active_screen().assert_integrity();
        // NOTE: This behavior is slightly inconsistent with xterm. xterm
        // _visually_ splits the wide character (half the wide character shows
        // up in col 6 and half in col 8). In all other wide char split scenarios,
        // xterm clears the cell. Therefore, we've chosen to clear the cell here.
        // Given we have space, we also could actually preserve it, but I haven't
        // yet found a terminal that behaves that way. We should be open to
        // revisiting this behavior but for now we're going with the simpler
        // impl.
        assert_eq!(t.plain_string(), "13456");
    }

    #[test]
    fn save_cursor() {
        // ghostty: "Terminal: saveCursor" (Terminal.zig:10833)
        let mut t = terminal(3, 3);
        t.set_attribute(Attribute::Bold);
        t.active_screen_mut().charset.gr = CharsetSlots::G3;
        t.modes.set(Mode::Origin, true);
        t.save_cursor();
        t.active_screen_mut().charset.gr = CharsetSlots::G0;
        t.set_attribute(Attribute::Unset);
        t.modes.set(Mode::Origin, false);
        t.restore_cursor();
        assert!(t.active_screen().cursor.style.flags.bold);
        assert!(t.active_screen().charset.gr == CharsetSlots::G3);
        assert!(t.modes.get(Mode::Origin));
    }

    #[test]
    fn save_cursor_position() {
        // ghostty: "Terminal: saveCursor position" (Terminal.zig:10851)
        let mut t = terminal(10, 5);
        t.set_cursor_pos(1, 5);
        t.print('A');
        t.save_cursor();
        t.set_cursor_pos(1, 1);
        t.print('B');
        t.restore_cursor();
        t.print('X');
        assert_eq!(t.plain_string(), "B   AX");
    }

    #[test]
    fn save_cursor_pending_wrap_state() {
        // ghostty: "Terminal: saveCursor pending wrap state" (Terminal.zig:10871)
        let mut t = terminal(5, 5);
        t.set_cursor_pos(1, 5);
        t.print('A');
        t.save_cursor();
        t.set_cursor_pos(1, 1);
        t.print('B');
        t.restore_cursor();
        t.print('X');
        assert_eq!(t.plain_string(), "B   A\nX");
    }

    #[test]
    fn save_cursor_origin_mode() {
        // ghostty: "Terminal: saveCursor origin mode" (Terminal.zig:10891)
        let mut t = terminal(10, 5);
        t.modes.set(Mode::Origin, true);
        t.save_cursor();
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(3, 5);
        t.set_top_and_bottom_margin(2, 4);
        t.restore_cursor();
        t.print('X');
        assert_eq!(t.plain_string(), "X");
    }

    #[test]
    fn save_cursor_resize() {
        // ghostty: "Terminal: saveCursor resize" (Terminal.zig:10911)
        let mut t = terminal(10, 5);
        t.set_cursor_pos(1, 10);
        t.save_cursor();
        t.resize(5, 5);
        t.restore_cursor();
        t.print('X');
        assert_eq!(t.plain_string(), "    X");
    }

    #[test]
    fn save_cursor_protected_pen() {
        // ghostty: "Terminal: saveCursor protected pen" (Terminal.zig:10929)
        let mut t = terminal(10, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        assert!(t.active_screen().cursor.protected);
        t.set_cursor_pos(1, 10);
        t.save_cursor();
        t.set_protected_mode(ProtectedMode::Off);
        assert!(!t.active_screen().cursor.protected);
        t.restore_cursor();
        assert!(t.active_screen().cursor.protected);
    }

    #[test]
    fn save_cursor_doesnt_modify_hyperlink_state() {
        // ghostty: "Terminal: saveCursor doesn't modify hyperlink state" (Terminal.zig:10944)
        let mut t = terminal(3, 3);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        let id = t.active_screen().cursor.hyperlink_id;
        t.save_cursor();
        assert_eq!(id, t.active_screen().cursor.hyperlink_id);
        t.restore_cursor();
        assert_eq!(id, t.active_screen().cursor.hyperlink_id);
    }

    #[test]
    fn restore_cursor_uses_default_style_on_out_of_space() {
        // ghostty: "Terminal: restoreCursor uses default style on OutOfSpace" (Terminal.zig:10957)
        // Tests that restoreCursor falls back to default style when
        // manualStyleUpdate fails with OutOfSpace (can't split a 1-row page
        // and styles are at max capacity).
        // Use a single row so the page can't be split
        let mut t = terminal(10, 1);

        // Set a style and save the cursor
        t.set_attribute(Attribute::Bold);
        t.save_cursor();

        // Clear the style
        t.set_attribute(Attribute::Unset);
        assert!(!t.active_screen().cursor.style.flags.bold);

        // Fill the style map to max capacity
        let max_styles = crate::size::CellCountInt::MAX;
        loop {
            let node = t.active_screen().cursor_pin().unwrap().node;
            if t.active_screen().pages.node_capacity(node).unwrap().styles >= max_styles {
                break;
            }
            if t.active_screen_mut()
                .increase_capacity(node, crate::page_list::IncreaseCapacity::Styles)
                .is_err()
            {
                break;
            }
        }

        let node = t.active_screen().cursor_pin().unwrap().node;
        assert_eq!(
            t.active_screen().pages.node_capacity(node).unwrap().styles,
            max_styles
        );

        // Fill all style slots using the StyleSet's layout capacity, which
        // accounts for the load factor. The capacity in the layout is the
        // actual max number of items that can be stored.
        {
            let max_items = t
                .active_screen()
                .pages
                .node(node)
                .map(|node| node.page.style_layout_cap())
                .unwrap_or(0);
            let mut n = 1usize;
            while n < max_items {
                let style = crate::style::PackedStyle::from(Style {
                    bg_color: crate::style::StyleColor::Rgb(Rgb {
                        r: ((n >> 16) & 0xFF) as u8,
                        g: ((n >> 8) & 0xFF) as u8,
                        b: (n & 0xFF) as u8,
                    }),
                    ..Style::default()
                });
                let Some(node) = t.active_screen_mut().pages.node_mut(node) else {
                    break;
                };
                if node.page.add_style(style).is_err() {
                    break;
                }
                n += 1;
            }
        }

        // Restore cursor - should fall back to default style since page
        // can't be split (1 row) and styles are at max capacity
        t.restore_cursor();

        // The style should be reset to default because OutOfSpace occurred
        assert!(!t.active_screen().cursor.style.flags.bold);
        assert_eq!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
    }

    #[test]
    fn stream_dispatches_to_terminal() {
        // port-added: Stream<Terminal> integration for T7b handler wiring.
        let mut stream = Stream::new(terminal(8, 3));
        stream.next_slice(b"ab\x1B[2;3Hcd");
        assert_eq!(stream.handler.dump_string(), "ab\n  cd");
    }

    // Helper: assert every cell in [x_range] on active row `y` is a red RGB bg.
    fn assert_red_bg_row(t: &Terminal, xs: std::ops::Range<CellCountInt>, y: u32) {
        for x in xs {
            let c = active_cell(t, x, y);
            assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
            assert_eq!(
                c.rgb(),
                Rgb {
                    r: 0xFF,
                    g: 0,
                    b: 0
                }
            );
        }
    }

    #[test]
    fn set_protected_mode() {
        // ghostty: "Terminal: setProtectedMode" (Terminal.zig:11014)
        let mut t = terminal(3, 3);
        assert!(!t.active_screen().cursor.protected);
        t.set_protected_mode(ProtectedMode::Off);
        assert!(!t.active_screen().cursor.protected);
        t.set_protected_mode(ProtectedMode::Iso);
        assert!(t.active_screen().cursor.protected);
        t.set_protected_mode(ProtectedMode::Dec);
        assert!(t.active_screen().cursor.protected);
        t.set_protected_mode(ProtectedMode::Off);
        assert!(!t.active_screen().cursor.protected);
    }

    #[test]
    fn erase_line_simple_erase_right() {
        // ghostty: "Terminal: eraseLine simple erase right" (Terminal.zig:11030)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 3);
        t.clear_dirty();
        t.erase_line(EraseLine::Right, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "AB");
    }

    #[test]
    fn erase_line_resets_pending_wrap() {
        // ghostty: "Terminal: eraseLine resets pending wrap" (Terminal.zig:11048)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.erase_line(EraseLine::Right, false);
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('B');
        assert_eq!(t.plain_string(), "ABCDB");
    }

    #[test]
    fn erase_line_resets_wrap() {
        // ghostty: "Terminal: eraseLine resets wrap" (Terminal.zig:11066)
        let mut t = terminal(5, 5);
        for c in "ABCDE123".chars() {
            t.print(c);
        }
        assert!(t.get_row(screen_point(0, 0)).unwrap().wrap());
        t.set_cursor_pos(1, 1);
        t.erase_line(EraseLine::Right, false);
        assert!(!t.get_row(screen_point(0, 0)).unwrap().wrap());
        t.print('X');
        assert_eq!(t.plain_string(), "X\n123");
    }

    #[test]
    fn erase_line_right_preserves_background_sgr() {
        // ghostty: "Terminal: eraseLine right preserves background sgr" (Terminal.zig:11093)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.erase_line(EraseLine::Right, false);
        assert_eq!(t.plain_string(), "A");
        assert_red_bg_row(&t, 1..5, 0);
    }

    #[test]
    fn erase_line_right_wide_character() {
        // ghostty: "Terminal: eraseLine right wide character" (Terminal.zig:11126)
        let mut t = terminal(10, 5);
        for c in "AB".chars() {
            t.print(c);
        }
        t.print('橋');
        for c in "DE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 4);
        t.clear_dirty();
        t.erase_line(EraseLine::Right, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "AB");
    }

    #[test]
    fn erase_line_right_protected_attributes_respected_with_iso() {
        // ghostty: "Terminal: eraseLine right protected attributes respected with iso" (Terminal.zig:11146)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.erase_line(EraseLine::Right, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "ABC");
    }

    #[test]
    fn erase_line_right_protected_attributes_ignored_with_dec_most_recent() {
        // ghostty: "Terminal: eraseLine right protected attributes ignored with dec most recent" (Terminal.zig:11165)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_protected_mode(ProtectedMode::Dec);
        t.set_protected_mode(ProtectedMode::Off);
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.erase_line(EraseLine::Right, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "A");
    }

    #[test]
    fn erase_line_right_protected_attributes_ignored_with_dec_set() {
        // ghostty: "Terminal: eraseLine right protected attributes ignored with dec set" (Terminal.zig:11186)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Dec);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.erase_line(EraseLine::Right, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "A");
    }

    #[test]
    fn erase_line_right_protected_requested() {
        // ghostty: "Terminal: eraseLine right protected requested" (Terminal.zig:11205)
        let mut t = terminal(10, 5);
        for c in "12345678".chars() {
            t.print(c);
        }
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 6);
        t.set_protected_mode(ProtectedMode::Dec);
        t.print('X');
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 4);
        t.clear_dirty();
        t.erase_line(EraseLine::Right, true);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "123  X");
    }

    #[test]
    fn erase_line_simple_erase_left() {
        // ghostty: "Terminal: eraseLine simple erase left" (Terminal.zig:11226)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 3);
        t.clear_dirty();
        t.erase_line(EraseLine::Left, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "   DE");
    }

    #[test]
    fn erase_line_left_resets_wrap() {
        // ghostty: "Terminal: eraseLine left resets wrap" (Terminal.zig:11244)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);
        t.clear_dirty();
        t.erase_line(EraseLine::Left, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert!(!t.active_screen().cursor.pending_wrap);
        t.print('B');
        assert_eq!(t.plain_string(), "    B");
    }

    #[test]
    fn erase_line_left_preserves_background_sgr() {
        // ghostty: "Terminal: eraseLine left preserves background sgr" (Terminal.zig:11264)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.erase_line(EraseLine::Left, false);
        assert_eq!(t.plain_string(), "  CDE");
        assert_red_bg_row(&t, 0..2, 0);
    }

    #[test]
    fn erase_line_left_wide_character() {
        // ghostty: "Terminal: eraseLine left wide character" (Terminal.zig:11297)
        let mut t = terminal(10, 5);
        for c in "AB".chars() {
            t.print(c);
        }
        t.print('橋');
        for c in "DE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 3);
        t.clear_dirty();
        t.erase_line(EraseLine::Left, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "    DE");
    }

    #[test]
    fn erase_line_left_protected_attributes_respected_with_iso() {
        // ghostty: "Terminal: eraseLine left protected attributes respected with iso" (Terminal.zig:11317)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.erase_line(EraseLine::Left, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "ABC");
    }

    #[test]
    fn erase_line_left_protected_attributes_ignored_with_dec_most_recent() {
        // ghostty: "Terminal: eraseLine left protected attributes ignored with dec most recent" (Terminal.zig:11336)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_protected_mode(ProtectedMode::Dec);
        t.set_protected_mode(ProtectedMode::Off);
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.erase_line(EraseLine::Left, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "  C");
    }

    #[test]
    fn erase_line_left_protected_attributes_ignored_with_dec_set() {
        // ghostty: "Terminal: eraseLine left protected attributes ignored with dec set" (Terminal.zig:11357)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Dec);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.erase_line(EraseLine::Left, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "  C");
    }

    #[test]
    fn erase_line_left_protected_requested() {
        // ghostty: "Terminal: eraseLine left protected requested" (Terminal.zig:11376)
        let mut t = terminal(10, 5);
        for c in "123456789".chars() {
            t.print(c);
        }
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 6);
        t.set_protected_mode(ProtectedMode::Dec);
        t.print('X');
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 8);
        t.clear_dirty();
        t.erase_line(EraseLine::Left, true);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "     X  9");
    }

    #[test]
    fn erase_line_complete_preserves_background_sgr() {
        // ghostty: "Terminal: eraseLine complete preserves background sgr" (Terminal.zig:11397)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.erase_line(EraseLine::Complete, false);
        assert_eq!(t.plain_string(), "");
        assert_red_bg_row(&t, 0..5, 0);
    }

    #[test]
    fn erase_line_complete_protected_attributes_respected_with_iso() {
        // ghostty: "Terminal: eraseLine complete protected attributes respected with iso" (Terminal.zig:11430)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 1);
        t.clear_dirty();
        t.erase_line(EraseLine::Complete, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "ABC");
    }

    #[test]
    fn erase_line_complete_protected_attributes_ignored_with_dec_most_recent() {
        // ghostty: "Terminal: eraseLine complete protected attributes ignored with dec most recent" (Terminal.zig:11449)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_protected_mode(ProtectedMode::Dec);
        t.set_protected_mode(ProtectedMode::Off);
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.erase_line(EraseLine::Complete, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "");
    }

    #[test]
    fn erase_line_complete_protected_attributes_ignored_with_dec_set() {
        // ghostty: "Terminal: eraseLine complete protected attributes ignored with dec set" (Terminal.zig:11470)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Dec);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.set_cursor_pos(1, 2);
        t.clear_dirty();
        t.erase_line(EraseLine::Complete, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "");
    }

    #[test]
    fn erase_line_complete_protected_requested() {
        // ghostty: "Terminal: eraseLine complete protected requested" (Terminal.zig:11489)
        let mut t = terminal(10, 5);
        for c in "123456789".chars() {
            t.print(c);
        }
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 6);
        t.set_protected_mode(ProtectedMode::Dec);
        t.print('X');
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 8);
        t.clear_dirty();
        t.erase_line(EraseLine::Complete, true);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "     X");
    }

    #[test]
    fn tab_clear_single() {
        // ghostty: "Terminal: tabClear single" (Terminal.zig:11510)
        let mut t = terminal(30, 5);
        t.horizontal_tab();
        t.tab_clear_current();
        assert!(!t.is_dirty(screen_point(0, 0)));
        t.set_cursor_pos(1, 1);
        t.horizontal_tab();
        assert_eq!(t.active_screen().cursor.x, 16);
    }

    #[test]
    fn tab_clear_all() {
        // ghostty: "Terminal: tabClear all" (Terminal.zig:11523)
        let mut t = terminal(30, 5);
        t.tab_clear_all();
        assert!(!t.is_dirty(screen_point(0, 0)));
        t.set_cursor_pos(1, 1);
        t.horizontal_tab();
        assert_eq!(t.active_screen().cursor.x, 29);
    }

    #[test]
    fn print_repeat_simple() {
        // ghostty: "Terminal: printRepeat simple" (Terminal.zig:11535)
        let mut t = terminal(5, 5);
        t.print_string("A");
        t.print_repeat(1);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "AA");
    }

    #[test]
    fn print_repeat_wrap() {
        // ghostty: "Terminal: printRepeat wrap" (Terminal.zig:11551)
        let mut t = terminal(5, 5);
        t.print_string("    A");
        t.print_repeat(1);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "    A\nA");
    }

    #[test]
    fn print_repeat_no_previous_character() {
        // ghostty: "Terminal: printRepeat no previous character" (Terminal.zig:11567)
        let mut t = terminal(5, 5);
        t.print_repeat(1);
        assert!(!t.is_dirty(screen_point(0, 0)));
        assert_eq!(t.plain_string(), "");
    }

    #[test]
    fn print_attributes() {
        // ghostty: "Terminal: printAttributes" (Terminal.zig:11582)
        let mut t = terminal(5, 5);

        {
            t.set_attribute(Attribute::DirectColorFg(Rgb { r: 1, g: 2, b: 3 }));
            assert_eq!(t.print_attributes(), "0;38:2::1:2:3");
            t.set_attribute(Attribute::Unset);
        }

        {
            t.set_attribute(Attribute::Bold);
            t.set_attribute(Attribute::DirectColorBg(Rgb { r: 1, g: 2, b: 3 }));
            assert_eq!(t.print_attributes(), "0;1;48:2::1:2:3");
            t.set_attribute(Attribute::Unset);
        }

        {
            t.set_attribute(Attribute::Bold);
            t.set_attribute(Attribute::Faint);
            t.set_attribute(Attribute::Italic);
            t.set_attribute(Attribute::Underline(crate::sgr::Underline::Single));
            t.set_attribute(Attribute::Blink);
            t.set_attribute(Attribute::Inverse);
            t.set_attribute(Attribute::Invisible);
            t.set_attribute(Attribute::Strikethrough);
            t.set_attribute(Attribute::DirectColorFg(Rgb {
                r: 100,
                g: 200,
                b: 255,
            }));
            t.set_attribute(Attribute::DirectColorBg(Rgb {
                r: 101,
                g: 102,
                b: 103,
            }));
            assert_eq!(
                t.print_attributes(),
                "0;1;2;3;4;5;7;8;9;38:2::100:200:255;48:2::101:102:103"
            );
            t.set_attribute(Attribute::Unset);
        }

        {
            t.set_attribute(Attribute::Underline(crate::sgr::Underline::Single));
            assert_eq!(t.print_attributes(), "0;4");
            t.set_attribute(Attribute::Unset);
        }

        {
            assert_eq!(t.print_attributes(), "0");
        }
    }

    #[test]
    fn erase_display_simple_erase_below() {
        // ghostty: "Terminal: eraseDisplay simple erase below" (Terminal.zig:11633)
        let mut t = terminal(5, 5);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.erase_display(EraseDisplay::Below, false);
        assert!(!t.is_dirty(screen_point(0, 0)));
        assert!(t.is_dirty(screen_point(0, 1)));
        assert!(t.is_dirty(screen_point(0, 2)));
        assert_eq!(t.plain_string(), "ABC\nD");
    }

    #[test]
    fn erase_display_erase_below_preserves_sgr_bg() {
        // ghostty: "Terminal: eraseDisplay erase below preserves SGR bg" (Terminal.zig:11661)
        let mut t = terminal(5, 5);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.erase_display(EraseDisplay::Below, false);
        assert_eq!(t.plain_string(), "ABC\nD");
        assert_red_bg_row(&t, 1..5, 1);
    }

    #[test]
    fn erase_display_below_split_multi_cell() {
        // ghostty: "Terminal: eraseDisplay below split multi-cell" (Terminal.zig:11701)
        let mut t = terminal(5, 5);
        t.print_string("AB橋C");
        t.carriage_return();
        t.linefeed();
        t.print_string("DE橋F");
        t.carriage_return();
        t.linefeed();
        t.print_string("GH橋I");
        t.set_cursor_pos(2, 4);
        t.erase_display(EraseDisplay::Below, false);
        assert_eq!(t.plain_string(), "AB橋C\nDE");
    }

    #[test]
    fn erase_display_below_protected_attributes_respected_with_iso() {
        // ghostty: "Terminal: eraseDisplay below protected attributes respected with iso" (Terminal.zig:11723)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.erase_display(EraseDisplay::Below, false);
        assert_eq!(t.plain_string(), "ABC\nDEF\nGHI");
    }

    #[test]
    fn erase_display_below_protected_attributes_ignored_with_dec_most_recent() {
        // ghostty: "Terminal: eraseDisplay below protected attributes ignored with dec most recent" (Terminal.zig:11746)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_protected_mode(ProtectedMode::Dec);
        t.set_protected_mode(ProtectedMode::Off);
        t.set_cursor_pos(2, 2);
        t.erase_display(EraseDisplay::Below, false);
        assert_eq!(t.plain_string(), "ABC\nD");
    }

    #[test]
    fn erase_display_below_protected_attributes_ignored_with_dec_set() {
        // ghostty: "Terminal: eraseDisplay below protected attributes ignored with dec set" (Terminal.zig:11771)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Dec);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.erase_display(EraseDisplay::Below, false);
        assert_eq!(t.plain_string(), "ABC\nD");
    }

    #[test]
    fn erase_display_below_protected_attributes_respected_with_force() {
        // ghostty: "Terminal: eraseDisplay below protected attributes respected with force" (Terminal.zig:11794)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Dec);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.erase_display(EraseDisplay::Below, true);
        assert_eq!(t.plain_string(), "ABC\nDEF\nGHI");
    }

    #[test]
    fn erase_display_simple_erase_above() {
        // ghostty: "Terminal: eraseDisplay simple erase above" (Terminal.zig:11817)
        let mut t = terminal(5, 5);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.clear_dirty();
        t.erase_display(EraseDisplay::Above, false);
        assert!(t.is_dirty(screen_point(0, 0)));
        assert!(t.is_dirty(screen_point(0, 1)));
        assert!(!t.is_dirty(screen_point(0, 2)));
        assert_eq!(t.plain_string(), "\n  F\nGHI");
    }

    #[test]
    fn erase_display_erase_above_preserves_sgr_bg() {
        // ghostty: "Terminal: eraseDisplay erase above preserves SGR bg" (Terminal.zig:11844)
        let mut t = terminal(5, 5);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.erase_display(EraseDisplay::Above, false);
        assert_eq!(t.plain_string(), "\n  F\nGHI");
        assert_red_bg_row(&t, 0..2, 1);
    }

    #[test]
    fn erase_display_above_split_multi_cell() {
        // ghostty: "Terminal: eraseDisplay above split multi-cell" (Terminal.zig:11884)
        let mut t = terminal(5, 5);
        t.print_string("AB橋C");
        t.carriage_return();
        t.linefeed();
        t.print_string("DE橋F");
        t.carriage_return();
        t.linefeed();
        t.print_string("GH橋I");
        t.set_cursor_pos(2, 3);
        t.erase_display(EraseDisplay::Above, false);
        assert_eq!(t.plain_string(), "\n    F\nGH橋I");
    }

    #[test]
    fn erase_display_above_protected_attributes_respected_with_iso() {
        // ghostty: "Terminal: eraseDisplay above protected attributes respected with iso" (Terminal.zig:11906)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.erase_display(EraseDisplay::Above, false);
        assert_eq!(t.plain_string(), "ABC\nDEF\nGHI");
    }

    #[test]
    fn erase_display_above_protected_attributes_ignored_with_dec_most_recent() {
        // ghostty: "Terminal: eraseDisplay above protected attributes ignored with dec most recent" (Terminal.zig:11929)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Iso);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_protected_mode(ProtectedMode::Dec);
        t.set_protected_mode(ProtectedMode::Off);
        t.set_cursor_pos(2, 2);
        t.erase_display(EraseDisplay::Above, false);
        assert_eq!(t.plain_string(), "\n  F\nGHI");
    }

    #[test]
    fn erase_display_above_protected_attributes_ignored_with_dec_set() {
        // ghostty: "Terminal: eraseDisplay above protected attributes ignored with dec set" (Terminal.zig:11954)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Dec);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.erase_display(EraseDisplay::Above, false);
        assert_eq!(t.plain_string(), "\n  F\nGHI");
    }

    #[test]
    fn erase_display_above_protected_attributes_respected_with_force() {
        // ghostty: "Terminal: eraseDisplay above protected attributes respected with force" (Terminal.zig:11977)
        let mut t = terminal(5, 5);
        t.set_protected_mode(ProtectedMode::Dec);
        for c in "ABC".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "DEF".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "GHI".chars() {
            t.print(c);
        }
        t.set_cursor_pos(2, 2);
        t.erase_display(EraseDisplay::Above, true);
        assert_eq!(t.plain_string(), "ABC\nDEF\nGHI");
    }

    #[test]
    fn erase_display_protected_complete() {
        // ghostty: "Terminal: eraseDisplay protected complete" (Terminal.zig:12000)
        let mut t = terminal(10, 5);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        for c in "123456789".chars() {
            t.print(c);
        }
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 6);
        t.set_protected_mode(ProtectedMode::Dec);
        t.print('X');
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 4);
        t.clear_dirty();
        t.erase_display(EraseDisplay::Complete, true);
        for y in 0..u32::from(t.rows) {
            assert!(t.is_dirty(screen_point(0, y)));
        }
        assert_eq!(t.plain_string(), "\n     X");
    }

    #[test]
    fn erase_display_protected_below() {
        // ghostty: "Terminal: eraseDisplay protected below" (Terminal.zig:12028)
        let mut t = terminal(10, 5);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        for c in "123456789".chars() {
            t.print(c);
        }
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 6);
        t.set_protected_mode(ProtectedMode::Dec);
        t.print('X');
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 4);
        t.erase_display(EraseDisplay::Below, true);
        assert_eq!(t.plain_string(), "A\n123  X");
    }

    #[test]
    fn erase_display_scroll_complete() {
        // ghostty: "Terminal: eraseDisplay scroll complete" (Terminal.zig:12050)
        let mut t = terminal(10, 5);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        t.erase_display(EraseDisplay::ScrollComplete, false);
        assert_eq!(t.plain_string(), "");
    }

    #[test]
    fn erase_display_protected_above() {
        // ghostty: "Terminal: eraseDisplay protected above" (Terminal.zig:12067)
        let mut t = terminal(10, 3);
        t.print('A');
        t.carriage_return();
        t.linefeed();
        for c in "123456789".chars() {
            t.print(c);
        }
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 6);
        t.set_protected_mode(ProtectedMode::Dec);
        t.print('X');
        let y = t.active_screen().cursor.y;
        t.set_cursor_pos(y + 1, 8);
        t.erase_display(EraseDisplay::Above, true);
        assert_eq!(t.plain_string(), "\n     X  9");
    }

    #[test]
    fn erase_display_complete_preserves_cursor() {
        // ghostty: "Terminal: eraseDisplay complete preserves cursor" (Terminal.zig:12089)
        let mut t = terminal(5, 5);
        t.print_string("AAAA");
        t.set_attribute(Attribute::Bold);
        assert_ne!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
        t.erase_display(EraseDisplay::Complete, false);
        assert_ne!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
    }

    #[test]
    fn semantic_prompt_marks_prompt_and_output() {
        // ghostty: "Terminal: semantic prompt" (Terminal.zig:12106)
        let mut t = terminal(10, 5);

        // Prompt
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::FreshLineNewPrompt,
        ));
        for c in "hello".chars() {
            t.print(c);
        }
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 5);
        {
            let x = t.active_screen().cursor.x - 1;
            let y = u32::from(t.active_screen().cursor.y);
            let c = active_cell(&t, x, y);
            assert_eq!(c.semantic_content(), SemanticContent::Prompt);
            let row = t.get_row(Point::active(x, y)).unwrap();
            assert_eq!(row.semantic_prompt(), SemanticPrompt::Prompt);
        }

        // Start input but end it on EOL
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::EndPromptStartInputTerminateEol,
        ));
        t.carriage_return();
        t.linefeed();

        // Write some output
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 0);
        for c in "world".chars() {
            t.print(c);
        }
        {
            let x = t.active_screen().cursor.x - 1;
            let y = u32::from(t.active_screen().cursor.y);
            let c = active_cell(&t, x, y);
            assert_eq!(c.semantic_content(), SemanticContent::Output);
            let row = t.get_row(Point::active(x, y)).unwrap();
            assert_eq!(row.semantic_prompt(), SemanticPrompt::None);
        }
    }

    /// The semantic-prompt classification of the active row at `y`.
    fn active_row_prompt(t: &Terminal, y: u32) -> SemanticPrompt {
        t.get_row(Point::active(0, y)).unwrap().semantic_prompt()
    }

    #[test]
    fn semantic_prompt_continuations() {
        // ghostty: "Terminal: semantic prompt continuations" (Terminal.zig:12150)
        let mut t = terminal(10, 5);

        // Prompt
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::FreshLineNewPrompt,
        ));
        for c in "hello".chars() {
            t.print(c);
        }
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 5);
        {
            let x = t.active_screen().cursor.x - 1;
            let y = u32::from(t.active_screen().cursor.y);
            let c = active_cell(&t, x, y);
            assert_eq!(c.semantic_content(), SemanticContent::Prompt);
            let row = t.get_row(Point::active(x, y)).unwrap();
            assert_eq!(row.semantic_prompt(), SemanticPrompt::Prompt);
        }

        // Continuation
        t.carriage_return();
        t.linefeed();
        t.semantic_prompt(SemanticPromptCommand {
            action: SemanticPromptAction::PromptStart,
            options_unvalidated: b"k=c",
        });
        assert_eq!(t.active_screen().cursor.y, 1);
        assert_eq!(t.active_screen().cursor.x, 0);
        for c in "world".chars() {
            t.print(c);
        }
        {
            let x = t.active_screen().cursor.x - 1;
            let y = u32::from(t.active_screen().cursor.y);
            let c = active_cell(&t, x, y);
            assert_eq!(c.semantic_content(), SemanticContent::Prompt);
            let row = t.get_row(Point::active(x, y)).unwrap();
            assert_eq!(row.semantic_prompt(), SemanticPrompt::PromptContinuation);
        }
    }

    #[test]
    fn index_in_prompt_mode_marks_new_row_as_prompt_continuation() {
        // ghostty: "Terminal: index in prompt mode marks new row as prompt continuation" (Terminal.zig:12197)
        let mut t = terminal(10, 5);

        // Start a prompt
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        for c in "hello".chars() {
            t.print(c);
        }

        // CRLF to a new line
        t.carriage_return();
        t.linefeed();

        assert_eq!(active_row_prompt(&t, 0), SemanticPrompt::Prompt);
        assert_eq!(active_row_prompt(&t, 1), SemanticPrompt::PromptContinuation);
        assert_eq!(
            t.active_screen().cursor.semantic_content,
            SemanticContent::Prompt
        );
    }

    #[test]
    fn index_in_input_mode_does_not_mark_new_row_as_prompt() {
        // ghostty: "Terminal: index in input mode does not mark new row as prompt" (Terminal.zig:12235)
        let mut t = terminal(10, 5);

        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        for c in "$ ".chars() {
            t.print(c);
        }
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::EndPromptStartInput,
        ));
        for c in "echo \\".chars() {
            t.print(c);
        }

        // CRLF to a new line
        t.carriage_return();
        t.linefeed();

        assert_eq!(active_row_prompt(&t, 1), SemanticPrompt::PromptContinuation);
        assert_eq!(
            t.active_screen().cursor.semantic_content,
            SemanticContent::Input
        );
    }

    #[test]
    fn index_in_output_mode_does_not_mark_new_row_as_prompt() {
        // ghostty: "Terminal: index in output mode does not mark new row as prompt" (Terminal.zig:12265)
        let mut t = terminal(10, 5);

        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        for c in "$ ".chars() {
            t.print(c);
        }
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::EndPromptStartInput,
        ));
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::EndInputStartOutput,
        ));
        for c in "ls".chars() {
            t.print(c);
        }

        // CRLF to a new line
        t.carriage_return();
        t.linefeed();

        assert_eq!(active_row_prompt(&t, 1), SemanticPrompt::None);
    }

    #[test]
    fn multiple_newlines_in_prompt_mode_marks_all_rows() {
        // ghostty: "Terminal: multiple newlines in prompt mode marks all rows" (Terminal.zig:12373)
        let mut t = terminal(10, 5);

        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        for c in "line1".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "line2".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        for c in "line3".chars() {
            t.print(c);
        }

        assert_eq!(active_row_prompt(&t, 0), SemanticPrompt::Prompt);
        assert_eq!(active_row_prompt(&t, 1), SemanticPrompt::PromptContinuation);
        assert_eq!(active_row_prompt(&t, 2), SemanticPrompt::PromptContinuation);
    }

    #[test]
    fn osc133c_at_x0_on_prompt_row_clears_prompt_mark() {
        // ghostty: "Terminal: OSC133C at x=0 on prompt row clears prompt mark" (Terminal.zig:12292)
        let mut t = terminal(10, 5);

        // Set up a prompt with input that wraps to a continuation line
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        for c in "$ echo \\".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();

        // Before OSC133C, the row is marked as a prompt continuation
        assert_eq!(active_row_prompt(&t, 1), SemanticPrompt::PromptContinuation);

        // OSC133C at x=0 should clear the prompt mark
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::EndInputStartOutput,
        ));
        assert_eq!(t.active_screen().cursor.x, 0);

        // After OSC133C, the prompt mark is cleared
        assert_eq!(active_row_prompt(&t, 1), SemanticPrompt::None);
    }

    #[test]
    fn osc133c_at_x_gt_0_on_prompt_row_does_not_clear_prompt_mark() {
        // ghostty: "Terminal: OSC133C at x>0 on prompt row does not clear prompt mark" (Terminal.zig:12331)
        let mut t = terminal(10, 5);

        // Set up a prompt with a continuation prompt string on the next line
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        for c in "$ ".chars() {
            t.print(c);
        }
        t.carriage_return();
        t.linefeed();
        t.semantic_prompt(SemanticPromptCommand {
            action: SemanticPromptAction::PromptStart,
            options_unvalidated: b"k=c",
        });
        for c in "> ".chars() {
            t.print(c);
        }

        // Before OSC133C, the row is marked as a prompt continuation
        assert_eq!(active_row_prompt(&t, 1), SemanticPrompt::PromptContinuation);

        // OSC133C at x>0 should NOT clear the prompt mark
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::EndInputStartOutput,
        ));
        assert!(t.active_screen().cursor.x > 0);

        // After OSC133C, the prompt mark remains
        assert_eq!(active_row_prompt(&t, 1), SemanticPrompt::PromptContinuation);
    }

    /// Drive a `fresh_line_new_prompt` (OSC 133;A) with the given raw option
    /// bytes and return the resulting screen click state.
    fn click_after_osc133a(options: &[u8]) -> SemanticClick {
        let mut t = terminal(10, 5);
        assert_eq!(t.active_screen().semantic_prompt.click, SemanticClick::None);
        t.semantic_prompt(SemanticPromptCommand {
            action: SemanticPromptAction::FreshLineNewPrompt,
            options_unvalidated: options,
        });
        t.active_screen().semantic_prompt.click
    }

    #[test]
    fn osc133a_click_events_1_sets_click_to_click_events() {
        // ghostty: "Terminal: OSC133A click_events=1 sets click to click_events" (Terminal.zig:12417)
        assert_eq!(
            click_after_osc133a(b"click_events=1"),
            SemanticClick::ClickEvents(PromptClickEvents::Absolute)
        );
    }

    #[test]
    fn osc133a_click_events_2_sets_click_to_click_events_relative() {
        // ghostty: "Terminal: OSC133A click_events=2 sets click to click_events (relative)" (Terminal.zig:12434)
        assert_eq!(
            click_after_osc133a(b"click_events=2"),
            SemanticClick::ClickEvents(PromptClickEvents::Relative)
        );
    }

    #[test]
    fn osc133a_click_events_0_does_not_set_click_events() {
        // ghostty: "Terminal: OSC133A click_events=0 does not set click_events" (Terminal.zig:12451)
        assert_eq!(click_after_osc133a(b"click_events=0"), SemanticClick::None);
    }

    #[test]
    fn osc133a_cl_option_sets_click_to_cl_value() {
        // ghostty: "Terminal: OSC133A cl option sets click to cl value" (Terminal.zig:12466)
        assert_eq!(
            click_after_osc133a(b"cl=m"),
            SemanticClick::Cl(PromptClick::Multiple)
        );
    }

    #[test]
    fn osc133a_cl_line_sets_click_to_line() {
        // ghostty: "Terminal: OSC133A cl=line sets click to line" (Terminal.zig:12480)
        assert_eq!(
            click_after_osc133a(b"cl=line"),
            SemanticClick::Cl(PromptClick::Line)
        );
    }

    #[test]
    fn osc133a_click_events_1_takes_priority_over_cl() {
        // ghostty: "Terminal: OSC133A click_events=1 takes priority over cl" (Terminal.zig:12493)
        assert_eq!(
            click_after_osc133a(b"click_events=1;cl=m"),
            SemanticClick::ClickEvents(PromptClickEvents::Absolute)
        );
    }

    #[test]
    fn osc133a_click_events_0_falls_back_to_cl() {
        // ghostty: "Terminal: OSC133A click_events=0 falls back to cl" (Terminal.zig:12508)
        assert_eq!(
            click_after_osc133a(b"click_events=0;cl=v"),
            SemanticClick::Cl(PromptClick::ConservativeVertical)
        );
    }

    #[test]
    fn osc133a_no_click_options_leaves_click_as_none() {
        // ghostty: "Terminal: OSC133A no click options leaves click as none" (Terminal.zig:12523)
        assert_eq!(click_after_osc133a(b"aid=123"), SemanticClick::None);
    }

    #[test]
    fn cursor_is_at_prompt() {
        // ghostty: "Terminal: cursorIsAtPrompt" (Terminal.zig:12537)
        let mut t = terminal(10, 3);
        assert!(!t.cursor_is_at_prompt());

        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        for c in "$ ".chars() {
            t.print(c);
        }
        assert!(t.cursor_is_at_prompt());

        // Input is also a prompt.
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::EndPromptStartInput,
        ));
        for c in "ls".chars() {
            t.print(c);
        }
        assert!(t.cursor_is_at_prompt());

        // Still a prompt because this line has a prompt.
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::EndInputStartOutput,
        ));
        assert!(t.cursor_is_at_prompt());

        // Newline to move to the next line (still in this prompt).
        t.linefeed();
        assert!(!t.cursor_is_at_prompt());

        // Now go to another prompt.
        t.linefeed();
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        assert!(t.cursor_is_at_prompt());
    }

    #[test]
    fn cursor_is_at_prompt_alternate_screen() {
        // ghostty: "Terminal: cursorIsAtPrompt alternate screen" (Terminal.zig:12566)
        let mut t = terminal(3, 2);
        assert!(!t.cursor_is_at_prompt());

        // Add a prompt on the primary screen.
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        assert!(t.cursor_is_at_prompt());

        // Switch to the alternate screen (never a prompt).
        t.switch_screen_mode(SwitchScreenMode::M1049, true);
        assert!(!t.cursor_is_at_prompt());

        // Even setting a prompt while on the alt screen keeps it not-a-prompt.
        t.semantic_prompt(SemanticPromptCommand::init(
            SemanticPromptAction::PromptStart,
        ));
        assert!(!t.cursor_is_at_prompt());
    }

    #[test]
    fn full_reset_with_a_non_empty_pen() {
        // ghostty: "Terminal: fullReset with a non-empty pen" (Terminal.zig:12582)
        let mut t = terminal(80, 80);
        t.set_attribute(Attribute::DirectColorFg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0x7F,
        }));
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0x7F,
        }));
        t.active_screen_mut().cursor.semantic_content = SemanticContent::Input;
        t.full_reset();

        let cell = active_cell(&t, 0, 0);
        assert_eq!(cell.style_id(), DEFAULT_STYLE_ID);
        assert_eq!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(
            t.active_screen().cursor.semantic_content,
            SemanticContent::Output
        );
    }

    #[test]
    fn full_reset_hyperlink() {
        // ghostty: "Terminal: fullReset hyperlink" (Terminal.zig:12604)
        let mut t = terminal(80, 80);
        t.active_screen_mut()
            .start_hyperlink(None, b"http://example.com");
        t.full_reset();
        assert_eq!(t.active_screen().cursor.hyperlink_id, 0);
    }

    #[test]
    fn full_reset_with_a_non_empty_saved_cursor() {
        // ghostty: "Terminal: fullReset with a non-empty saved cursor" (Terminal.zig:12613)
        let mut t = terminal(80, 80);
        t.set_attribute(Attribute::DirectColorFg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0x7F,
        }));
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0x7F,
        }));
        t.save_cursor();
        t.full_reset();

        let cell = active_cell(&t, 0, 0);
        assert_eq!(cell.style_id(), DEFAULT_STYLE_ID);
        assert_eq!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
    }

    #[test]
    fn full_reset_origin_mode() {
        // ghostty: "Terminal: fullReset origin mode" (Terminal.zig:12634)
        let mut t = terminal(10, 10);
        t.set_cursor_pos(3, 5);
        t.modes.set(Mode::Origin, true);
        t.full_reset();
        assert_eq!(t.active_screen().cursor.y, 0);
        assert_eq!(t.active_screen().cursor.x, 0);
        assert!(!t.modes.get(Mode::Origin));
    }

    #[test]
    fn full_reset_status_display() {
        // ghostty: "Terminal: fullReset status display" (Terminal.zig:12648)
        let mut t = terminal(10, 10);
        t.status_display = StatusDisplay::Status;
        t.full_reset();
        assert_eq!(t.status_display, StatusDisplay::Main);
    }

    #[test]
    fn full_reset_clears_alt_screen() {
        // ghostty: "Terminal: fullReset clears alt screen kitty keyboard state" (Terminal.zig:12658)
        // https://github.com/mitchellh/ghostty/issues/1607
        // The kitty-keyboard push from the Zig test is omitted (kitty
        // unsupported); the portable assertion is that fullReset removes the
        // alternate screen.
        let mut t = terminal(10, 10);
        t.switch_screen_mode(SwitchScreenMode::M1049, true);
        t.switch_screen_mode(SwitchScreenMode::M1049, false);
        t.full_reset();
        assert!(t.screens.get(ScreenKey::Alternate).is_none());
    }

    #[test]
    fn full_reset_default_modes() {
        // ghostty: "Terminal: fullReset default modes" (Terminal.zig:12676)
        // init(alloc, .{ .default_modes = .{ .grapheme_cluster = true } })
        let mut t = terminal(10, 10);
        t.modes = ModeState::with_default(
            crate::modes::ModeBits::default_values().with_mode(Mode::GraphemeCluster, true),
        );
        assert!(t.modes.get(Mode::GraphemeCluster));
        t.full_reset();
        assert!(t.modes.get(Mode::GraphemeCluster));
    }

    #[test]
    fn full_reset_tracked_pins() {
        // ghostty: "Terminal: fullReset tracked pins" (Terminal.zig:12688)
        let mut t = terminal(80, 80);
        let cursor_pin = t.active_screen().cursor_pin().unwrap();
        let p = t.active_screen_mut().pages.track_pin(cursor_pin);
        t.full_reset();
        let pin = t.active_screen().pages.tracked_pin(p).unwrap();
        assert!(t.active_screen().pages.pin_is_valid(pin));
    }

    #[test]
    fn resize_less_cols_with_wide_char_then_print() {
        // ghostty: "Terminal: resize less cols with wide char then print" (Terminal.zig:12701)
        // https://github.com/mitchellh/ghostty/issues/272
        // This is also tested in depth in screen resize tests but I want to keep
        // this test around to ensure we don't regress at multiple layers.
        let mut t = terminal(3, 3);
        t.print('x');
        print_cp(&mut t, 0x1F600); // 😀
        t.resize(2, 3);
        t.set_cursor_pos(1, 2);
        print_cp(&mut t, 0x1F600); // 😀
    }

    #[test]
    fn resize_with_left_and_right_margin_set() {
        // ghostty: "Terminal: resize with left and right margin set" (Terminal.zig:12715)
        // https://github.com/mitchellh/ghostty/issues/723
        // This was found via fuzzing so its highly specific.
        let cols = 70;
        let rows = 23;
        let mut t = terminal(cols, rows);
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.modes.set(Mode::EnableMode3, true);
        t.resize(cols, rows);
        t.set_left_and_right_margin(2, 0);
        t.print('0');
        t.print_repeat(1850);
        let _ = t.modes.restore(Mode::EnableMode3);
        t.resize(cols, rows);
    }

    #[test]
    fn resize_with_wraparound_off() {
        // ghostty: "Terminal: resize with wraparound off" (Terminal.zig:12733)
        // https://github.com/mitchellh/ghostty/issues/1343
        let cols = 4;
        let rows = 2;
        let mut t = terminal(cols, rows);
        t.modes.set(Mode::Wraparound, false);
        t.print('0');
        t.print('1');
        t.print('2');
        t.print('3');
        let new_cols = 2;
        t.resize(new_cols, rows);
        assert_eq!(t.plain_string(), "01");
    }

    #[test]
    fn resize_with_wraparound_on() {
        // ghostty: "Terminal: resize with wraparound on" (Terminal.zig:12753)
        let cols = 4;
        let rows = 2;
        let mut t = terminal(cols, rows);
        t.modes.set(Mode::Wraparound, true);
        t.print('0');
        t.print('1');
        t.print('2');
        t.print('3');
        let new_cols = 2;
        t.resize(new_cols, rows);
        assert_eq!(t.plain_string(), "01\n23");
    }

    #[test]
    fn resize_with_high_unique_style_per_cell() {
        // ghostty: "Terminal: resize with high unique style per cell" (Terminal.zig:12773)
        let mut t = terminal(30, 30);
        for y in 0..t.rows {
            for x in 0..t.cols {
                t.set_cursor_pos(y, x);
                t.set_attribute(Attribute::DirectColorBg(Rgb {
                    r: x as u8,
                    g: y as u8,
                    b: 0,
                }));
                t.print('x');
            }
        }
        t.resize(60, 30);
    }

    #[test]
    fn resize_with_high_unique_style_per_cell_with_wrapping() {
        // ghostty: "Terminal: resize with high unique style per cell with wrapping" (Terminal.zig:12793)
        let mut t = terminal(30, 30);
        let cell_count: u16 = t.rows * t.cols;
        for i in 0..cell_count {
            let r: u8 = (i >> 8) as u8;
            let g: u8 = (i & 0xFF) as u8;
            t.set_attribute(Attribute::DirectColorBg(Rgb { r, g, b: 0 }));
            t.print('x');
        }
        t.resize(60, 30);
    }

    #[test]
    fn resize_with_reflow_and_saved_cursor() {
        // ghostty: "Terminal: resize with reflow and saved cursor" (Terminal.zig:12814)
        let mut t = terminal(2, 3);
        t.print_string("1A2B");
        t.set_cursor_pos(2, 2);
        {
            let cell = t.active_screen().cursor_cell().expect("cursor cell exists");
            assert_eq!(cell.codepoint(), 'B' as u32);
        }
        assert_eq!(t.plain_string(), "1A\n2B");

        // Save the cursor, resize (reflow), and restore.
        t.save_cursor();
        t.resize(5, 3);
        t.restore_cursor();

        assert_eq!(t.plain_string(), "1A2B");
        let cell = t.active_screen().cursor_cell().expect("cursor cell exists");
        assert_eq!(cell.codepoint(), 'B' as u32);
    }

    #[test]
    fn resize_with_reflow_and_saved_cursor_pending_wrap() {
        // ghostty: "Terminal: resize with reflow and saved cursor pending wrap" (Terminal.zig:12856)
        let mut t = terminal(2, 3);
        t.print_string("1A2B");
        {
            let cell = t.active_screen().cursor_cell().expect("cursor cell exists");
            assert_eq!(cell.codepoint(), 'B' as u32);
        }
        assert_eq!(t.plain_string(), "1A\n2B");

        // Save the cursor, resize (reflow), and restore.
        t.save_cursor();
        t.resize(5, 3);
        t.restore_cursor();

        assert_eq!(t.plain_string(), "1A2B");

        // Pending wrap should be reset.
        t.print('X');
        assert_eq!(t.plain_string(), "1A2BX");
    }

    #[test]
    fn deccolm_without_dec_mode_40() {
        // ghostty: "Terminal: DECCOLM without DEC mode 40" (Terminal.zig:12895)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::Column132, true);
        t.deccolm(DeccolmMode::Cols132);
        assert_eq!(t.cols, 5);
        assert_eq!(t.rows, 5);
        assert!(!t.modes.get(Mode::Column132));
    }

    #[test]
    fn deccolm_unset() {
        // ghostty: "Terminal: DECCOLM unset" (Terminal.zig:12907)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::EnableMode3, true);
        t.deccolm(DeccolmMode::Cols80);
        assert_eq!(t.cols, 80);
        assert_eq!(t.rows, 5);
    }

    #[test]
    fn deccolm_resets_pending_wrap() {
        // ghostty: "Terminal: DECCOLM resets pending wrap" (Terminal.zig:12918)
        let mut t = terminal(5, 5);
        for c in "ABCDE".chars() {
            t.print(c);
        }
        assert!(t.active_screen().cursor.pending_wrap);

        t.modes.set(Mode::EnableMode3, true);
        t.deccolm(DeccolmMode::Cols80);
        assert_eq!(t.cols, 80);
        assert_eq!(t.rows, 5);
        assert!(!t.active_screen().cursor.pending_wrap);
    }

    #[test]
    fn deccolm_preserves_sgr_bg() {
        // ghostty: "Terminal: DECCOLM preserves SGR bg" (Terminal.zig:12933)
        let mut t = terminal(5, 5);
        t.set_attribute(Attribute::DirectColorBg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0,
        }));
        t.modes.set(Mode::EnableMode3, true);
        t.deccolm(DeccolmMode::Cols80);

        let c = active_cell(&t, 0, 0);
        assert_eq!(c.content_tag(), CellContentTag::BgColorRgb);
        assert_eq!(
            c.rgb(),
            Rgb {
                r: 0xFF,
                g: 0,
                b: 0
            }
        );
    }

    #[test]
    fn deccolm_resets_scroll_region() {
        // ghostty: "Terminal: DECCOLM resets scroll region" (Terminal.zig:12957)
        let mut t = terminal(5, 5);
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_top_and_bottom_margin(2, 3);
        t.set_left_and_right_margin(3, 5);
        t.modes.set(Mode::EnableMode3, true);
        t.deccolm(DeccolmMode::Cols80);

        assert!(t.modes.get(Mode::EnableLeftAndRightMargin));
        assert_eq!(t.scrolling_region.top, 0);
        assert_eq!(t.scrolling_region.bottom, 4);
        assert_eq!(t.scrolling_region.left, 0);
        assert_eq!(t.scrolling_region.right, 79);
    }

    #[test]
    fn mode_47_alt_screen_plain() {
        // ghostty: "Terminal: mode 47 alt screen plain" (Terminal.zig:12976)
        let mut t = terminal(5, 5);
        t.print_string("1A");

        // Switch to the alternate screen; it should be empty.
        t.switch_screen_mode(SwitchScreenMode::M47, true);
        assert_eq!(t.screens.active_key(), ScreenKey::Alternate);
        assert_eq!(t.plain_string(), "");

        // Write to the alt screen.
        t.print_string("2B");
        assert_eq!(t.plain_string(), "  2B");

        // Switch back to primary; it retains its content.
        t.switch_screen_mode(SwitchScreenMode::M47, false);
        assert_eq!(t.screens.active_key(), ScreenKey::Primary);
        assert_eq!(t.plain_string(), "1A");

        // Switch to alt again; mode 47 does NOT clear it.
        t.switch_screen_mode(SwitchScreenMode::M47, true);
        assert_eq!(t.screens.active_key(), ScreenKey::Alternate);
        assert_eq!(t.plain_string(), "  2B");
    }

    #[test]
    fn mode_47_copies_cursor_both_directions() {
        // ghostty: "Terminal: mode 47 copies cursor both directions" (Terminal.zig:13027)
        let mut t = terminal(5, 5);
        t.set_attribute(Attribute::DirectColorFg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0x7F,
        }));

        // Enter the alt screen: the cursor (and its style) is copied.
        t.switch_screen_mode(SwitchScreenMode::M47, true);
        assert_eq!(t.screens.active_key(), ScreenKey::Alternate);
        assert_ne!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(t.cursor_page_style_count(), 1);
        assert!(t.cursor_page_style_ref_count() > 0);

        // Change the style on the alt screen.
        t.set_attribute(Attribute::DirectColorFg(Rgb {
            r: 0,
            g: 0xFF,
            b: 0,
        }));

        // Return to primary: the cursor is copied back.
        t.switch_screen_mode(SwitchScreenMode::M47, false);
        assert_eq!(t.screens.active_key(), ScreenKey::Primary);
        assert_ne!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(t.cursor_page_style_count(), 1);
        assert!(t.cursor_page_style_ref_count() > 0);
    }

    #[test]
    fn mode_1047_alt_screen_plain() {
        // ghostty: "Terminal: mode 1047 alt screen plain" (Terminal.zig:13063)
        let mut t = terminal(5, 5);
        t.print_string("1A");

        // Switch to the alternate screen; it should be empty.
        t.switch_screen_mode(SwitchScreenMode::M1047, true);
        assert_eq!(t.screens.active_key(), ScreenKey::Alternate);
        assert_eq!(t.plain_string(), "");

        // Write to the alt screen.
        t.print_string("2B");
        assert_eq!(t.plain_string(), "  2B");

        // Switch back to primary; it retains its content.
        t.switch_screen_mode(SwitchScreenMode::M1047, false);
        assert_eq!(t.screens.active_key(), ScreenKey::Primary);
        assert_eq!(t.plain_string(), "1A");

        // Switch to alt again; mode 1047 clears the alt screen on re-entry.
        t.switch_screen_mode(SwitchScreenMode::M1047, true);
        assert_eq!(t.screens.active_key(), ScreenKey::Alternate);
        assert_eq!(t.plain_string(), "");
    }

    #[test]
    fn mode_1047_copies_cursor_both_directions() {
        // ghostty: "Terminal: mode 1047 copies cursor both directions" (Terminal.zig:13114)
        let mut t = terminal(5, 5);
        t.set_attribute(Attribute::DirectColorFg(Rgb {
            r: 0xFF,
            g: 0,
            b: 0x7F,
        }));

        // Enter the alt screen: the cursor (and its style) is copied.
        t.switch_screen_mode(SwitchScreenMode::M1047, true);
        assert_eq!(t.screens.active_key(), ScreenKey::Alternate);
        assert_ne!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(t.cursor_page_style_count(), 1);
        assert!(t.cursor_page_style_ref_count() > 0);

        // Change the style on the alt screen.
        t.set_attribute(Attribute::DirectColorFg(Rgb {
            r: 0,
            g: 0xFF,
            b: 0,
        }));

        // Return to primary: the cursor is copied back.
        t.switch_screen_mode(SwitchScreenMode::M1047, false);
        assert_eq!(t.screens.active_key(), ScreenKey::Primary);
        assert_ne!(t.active_screen().cursor.style_id, DEFAULT_STYLE_ID);
        assert_eq!(t.cursor_page_style_count(), 1);
        assert!(t.cursor_page_style_ref_count() > 0);
    }

    #[test]
    fn mode_1049_alt_screen_plain() {
        // ghostty: "Terminal: mode 1049 alt screen plain" (Terminal.zig:13150)
        let mut t = terminal(5, 5);
        t.print_string("1A");

        // Switch to the alternate screen; it should be empty.
        t.switch_screen_mode(SwitchScreenMode::M1049, true);
        assert_eq!(t.screens.active_key(), ScreenKey::Alternate);
        assert_eq!(t.plain_string(), "");

        // Write to the alt screen.
        t.print_string("2B");
        assert_eq!(t.plain_string(), "  2B");

        // Switch back to primary; it retains its content.
        t.switch_screen_mode(SwitchScreenMode::M1049, false);
        assert_eq!(t.screens.active_key(), ScreenKey::Primary);
        assert_eq!(t.plain_string(), "1A");

        // Our cursor should be restored, so printing continues from it.
        t.print_string("C");
        assert_eq!(t.plain_string(), "1AC");

        // Switch to alt again; it is cleared on entry.
        t.switch_screen_mode(SwitchScreenMode::M1049, true);
        assert_eq!(t.screens.active_key(), ScreenKey::Alternate);
        assert_eq!(t.plain_string(), "");
    }

    #[test]
    fn delete_lines_wide_char_at_right_margin_with_full_clear() {
        // ghostty: "Terminal: deleteLines wide char at right margin with full clear" (Terminal.zig:13215)
        // Reproduces a crash found by AFL++ fuzzer (afl-out/stream/default/crashes/
        // id:000007,sig:06,src:004522). The crash is a page integrity violation
        // "spacer tail not following wide" triggered during scrollUp -> deleteLines
        // -> clearCells. When deleteLines count >= scroll region height, all rows
        // are cleared (no shifting), so rowWillBeShifted is never called and wide
        // characters straddling the right margin boundary leave orphaned spacer_tails.
        let mut t = terminal(80, 24);

        // Place a wide character at col 39 (1-indexed) on several rows.
        // The wide cell lands at col 38 (0-indexed) with spacer_tail at col 39.
        t.set_cursor_pos(10, 39);
        print_cp(&mut t, 0x4E2D); // '中'

        // Set left/right scroll margins so scrolling_region.right = 38.
        t.modes.set(Mode::EnableLeftAndRightMargin, true);
        t.set_left_and_right_margin(5, 39);

        // clearCells will clear cells[4..39], which includes the wide cell
        // at col 38 but NOT the spacer_tail at col 39.
        // scrollUp with count >= region height causes deleteLines to clear
        // ALL rows without any shifting, so rowWillBeShifted is never called
        // and the orphaned spacer_tail at col 39 triggers a page integrity
        // violation in clearCells.
        t.scroll_up(usize::from(t.rows));
    }
}
