//! Renderer-facing terminal snapshot state.
//!
//! This ports the first RenderState slice from Ghostty's `terminal/render.zig`.
//! It keeps rendering data outside the terminal mutation path and consumes
//! dirty bits after rebuilding a snapshot.

use crate::color::{Palette, Rgb, DEFAULT_PALETTE};
use crate::highlight::Flattened;
use crate::modes::Mode;
use crate::page::{Cell, CellWide, Row};
use crate::page_list::{Direction, Pin};
use crate::point::{Coordinate, Point, Tag};
use crate::screen::CursorStyle;
use crate::selection::Selection;
use crate::size::CellCountInt;
use crate::style::Style;
use crate::terminal::Terminal;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirtyState {
    False,
    Partial,
    Full,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderColors {
    pub background: Rgb,
    pub foreground: Rgb,
    pub cursor: Rgb,
    pub palette: Palette,
}

impl Default for RenderColors {
    fn default() -> Self {
        Self {
            background: DEFAULT_PALETTE[0],
            foreground: DEFAULT_PALETTE[7],
            cursor: DEFAULT_PALETTE[7],
            palette: DEFAULT_PALETTE,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorViewport {
    pub coord: Coordinate,
    pub wide_tail: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderCursor {
    pub active: Coordinate,
    pub viewport: Option<CursorViewport>,
    pub cell: Cell,
    pub style: Style,
    pub visual_style: CursorStyle,
    pub password_input: bool,
    pub visible: bool,
    pub blinking: bool,
}

impl Default for RenderCursor {
    fn default() -> Self {
        Self {
            active: Coordinate { x: 0, y: 0 },
            viewport: None,
            cell: Cell::default(),
            style: Style::default(),
            visual_style: CursorStyle::Block,
            password_input: false,
            visible: true,
            blinking: false,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RenderCell {
    pub raw: Cell,
    pub style: Style,
    pub grapheme: Vec<u32>,
    pub hyperlink: Option<CellCountInt>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderSelection {
    pub start: CellCountInt,
    pub end: CellCountInt,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RenderHighlight {
    pub tag: u16,
    pub start: CellCountInt,
    pub end: CellCountInt,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderRow {
    pub pin: Option<Pin>,
    pub raw: Row,
    pub cells: Vec<RenderCell>,
    pub dirty: bool,
    pub selection: Option<RenderSelection>,
    pub highlights: Vec<RenderHighlight>,
}

impl RenderRow {
    fn blank(cols: CellCountInt) -> Self {
        Self {
            pin: None,
            raw: Row::default(),
            cells: vec![RenderCell::default(); cols as usize],
            dirty: true,
            selection: None,
            highlights: Vec::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RenderState {
    pub rows: CellCountInt,
    pub cols: CellCountInt,
    pub colors: RenderColors,
    pub cursor: RenderCursor,
    pub row_data: Vec<RenderRow>,
    pub dirty: DirtyState,
    pub scroll_delta: i32,
    screen_key: crate::screen_set::ScreenKey,
    viewport_pin: Option<Pin>,
}

impl RenderState {
    pub fn new(rows: CellCountInt, cols: CellCountInt) -> Self {
        Self {
            rows,
            cols,
            colors: RenderColors::default(),
            cursor: RenderCursor::default(),
            row_data: (0..rows).map(|_| RenderRow::blank(cols)).collect(),
            dirty: DirtyState::Full,
            scroll_delta: 0,
            screen_key: crate::screen_set::ScreenKey::Primary,
            viewport_pin: None,
        }
    }

    pub fn update(&mut self, terminal: &mut Terminal) {
        self.scroll_delta = 0;
        let screen_key = terminal.screens.active_key();
        let screen = terminal.active_screen();
        let dims_changed = self.rows != screen.rows() || self.cols != screen.cols();
        let viewport_pin = Some(screen.pages.get_top_left(Tag::Viewport));
        let viewport_changed = self.viewport_pin != viewport_pin;
        let full_redraw = dims_changed
            || self.screen_key != screen_key
            || terminal.dirty.any()
            || screen.dirty.any();
        let scroll_delta = (!full_redraw && viewport_changed)
            .then(|| {
                viewport_row_delta(
                    &screen.pages,
                    self.viewport_pin?,
                    viewport_pin?,
                    screen.rows(),
                )
            })
            .flatten();
        let redraw = full_redraw || (viewport_changed && scroll_delta.is_none());

        self.rows = screen.rows();
        self.cols = screen.cols();
        self.screen_key = screen_key;
        self.viewport_pin = viewport_pin;
        self.scroll_delta = scroll_delta.unwrap_or(0);
        self.colors = snapshot_colors(terminal);
        self.cursor = snapshot_cursor(terminal);

        if dims_changed || self.row_data.len() != self.rows as usize {
            self.row_data = (0..self.rows)
                .map(|_| RenderRow::blank(self.cols))
                .collect();
        } else if let Some(delta) = scroll_delta {
            if delta > 0 {
                self.row_data.rotate_left(delta as usize);
            } else {
                self.row_data.rotate_right(delta.unsigned_abs() as usize);
            }
        }
        let row_count = self.row_data.len();
        for (index, row) in self.row_data.iter_mut().enumerate() {
            if row.cells.len() != self.cols as usize {
                row.cells = vec![RenderCell::default(); self.cols as usize];
            }
            row.selection = None;
            row.highlights.clear();
            row.dirty = redraw
                || scroll_delta.is_some_and(|delta| {
                    if delta > 0 {
                        index >= row_count.saturating_sub(delta as usize)
                    } else {
                        index < delta.unsigned_abs() as usize
                    }
                });
        }

        let screen = terminal.active_screen();
        let top_left = Point::viewport(0, 0);
        let bottom_left = Some(Point::viewport(0, self.rows.saturating_sub(1) as u32));
        let mut iterator = screen
            .pages
            .row_iterator(Direction::RightDown, top_left, bottom_left);
        let cursor_pin = screen.cursor_pin();
        let selection = screen.selection;
        let selection_cache = selection_cache(screen, selection);
        for y in 0..self.rows {
            let Some(pin) = iterator.next(&screen.pages) else {
                break;
            };
            let Some(node) = screen.pages.node(pin.node) else {
                continue;
            };
            let row = &mut self.row_data[y as usize];
            let pin_dirty = screen.pages.pin_is_dirty(pin);
            let reusable_survivor = scroll_delta.is_some()
                && !row.dirty
                && row.pin == Some(pin)
                && pin_dirty
                && render_row_matches(row, &node.page, pin.y, self.cols);
            let was_dirty = row.dirty || (pin_dirty && !reusable_survivor);
            row.pin = Some(pin);
            row.raw = node.page.row(pin.y);
            row.dirty = was_dirty;
            if was_dirty {
                if row.raw.managed_memory() {
                    for x in 0..self.cols {
                        row.cells[x as usize] = snapshot_cell(&node.page, pin.y, x);
                    }
                } else {
                    // ghostty: render.zig:494-506 -- plain rows avoid managed
                    // lookups, but every field must still replace prior-frame data.
                    debug_assert!((0..self.cols).all(|x| {
                        let cell = node.page.cell(pin.y, x);
                        !cell.has_styling() && !cell.has_grapheme() && !cell.hyperlink()
                    }));
                    for x in 0..self.cols {
                        row.cells[x as usize] = RenderCell {
                            raw: node.page.cell(pin.y, x),
                            ..RenderCell::default()
                        };
                    }
                }
            }
            if let Some(cursor_pin) = cursor_pin {
                if cursor_pin.node == pin.node && cursor_pin.y == pin.y {
                    self.cursor.viewport = Some(CursorViewport {
                        coord: Coordinate {
                            x: cursor_pin.x,
                            y: u32::from(y),
                        },
                        // ghostty: render.zig:415-419
                        wide_tail: if cursor_pin.x > 0 {
                            screen
                                .cursor_cell_left(1)
                                .map(|cell| cell.wide() == CellWide::Wide)
                                .unwrap_or(false)
                        } else {
                            false
                        },
                    });
                }
            }
            if let Some((selection, top, bottom, top_coord, bottom_coord)) = selection_cache {
                let Some(point) = screen.pages.point_from_pin(Tag::Screen, pin) else {
                    continue;
                };
                if let Some(row_selection) = selection.contained_row_cached(
                    &screen.pages,
                    top,
                    bottom,
                    pin,
                    top_coord,
                    bottom_coord,
                    point.coord(),
                ) {
                    if let (Some(start), Some(end)) = (
                        row_selection.start(&screen.pages),
                        row_selection.end(&screen.pages),
                    ) {
                        row.selection = Some(RenderSelection {
                            start: start.x.min(end.x),
                            end: start.x.max(end.x),
                        });
                    }
                }
            }
        }

        let any_dirty = self.row_data.iter().any(|row| row.dirty);
        self.dirty = if redraw {
            DirtyState::Full
        } else if any_dirty {
            DirtyState::Partial
        } else {
            DirtyState::False
        };

        terminal.dirty.clear();
        terminal.active_screen_mut().dirty.clear();
        terminal.active_screen_mut().pages.clear_dirty();
    }

    pub fn update_highlights_flattened(&mut self, tag: u16, highlights: &[Flattened]) {
        for row in &mut self.row_data {
            let Some(pin) = row.pin else {
                continue;
            };
            let mut updated = Vec::new();
            for highlight in highlights {
                if highlight.chunks.iter().any(|chunk| {
                    chunk.node == pin.node && pin.y >= chunk.start && pin.y < chunk.end
                }) {
                    // ghostty: render.zig:709-718 -- a node can contain many
                    // viewport rows, so clipping applies only on the actual
                    // first and last rows of the flattened highlight.
                    updated.push(RenderHighlight {
                        tag,
                        start: if highlight
                            .chunks
                            .first()
                            .is_some_and(|chunk| chunk.node == pin.node && chunk.start == pin.y)
                        {
                            highlight.top_x
                        } else {
                            0
                        },
                        end: if highlight.chunks.last().is_some_and(|chunk| {
                            chunk.node == pin.node && chunk.end.saturating_sub(1) == pin.y
                        }) {
                            highlight.bot_x
                        } else {
                            self.cols.saturating_sub(1)
                        },
                    });
                }
            }
            let highlights_changed = row.highlights != updated;
            let has_match = !updated.is_empty();
            if highlights_changed {
                row.highlights = updated;
            }
            if has_match || highlights_changed {
                row.dirty = true;
                if self.dirty == DirtyState::False {
                    self.dirty = DirtyState::Partial;
                }
            }
        }
    }

    pub fn string(&self, include_map: bool) -> (String, Option<Vec<Coordinate>>) {
        let mut out = String::new();
        let mut map = include_map.then(Vec::new);
        for (row_index, row) in self.row_data.iter().enumerate() {
            for x in 0..self.cols {
                let coordinate = Coordinate {
                    x,
                    y: row_index as u32,
                };
                let Some(cell) = row.cells.get(x as usize) else {
                    push_mapped_char(&mut out, map.as_mut(), '\0', coordinate);
                    continue;
                };
                let ch = if cell.raw.has_text() {
                    char::from_u32(cell.raw.codepoint()).unwrap_or('\0')
                } else {
                    '\0'
                };
                push_mapped_char(&mut out, map.as_mut(), ch, coordinate);
                for codepoint in &cell.grapheme {
                    if let Some(ch) = char::from_u32(*codepoint) {
                        push_mapped_char(&mut out, map.as_mut(), ch, coordinate);
                    }
                }
            }
            if !row.raw.wrap() {
                push_mapped_char(
                    &mut out,
                    map.as_mut(),
                    '\n',
                    Coordinate {
                        x: self.cols.saturating_sub(1),
                        y: row_index as u32,
                    },
                );
            }
        }
        (out, map)
    }

    pub fn link_cells(&self, point: Coordinate) -> Vec<Coordinate> {
        let Some(row) = self.row_data.get(point.y as usize) else {
            return Vec::new();
        };
        let Some(source) = row
            .cells
            .get(point.x as usize)
            .and_then(|cell| cell.hyperlink)
        else {
            return Vec::new();
        };
        let mut coords = Vec::new();
        for (y, row) in self.row_data.iter().enumerate() {
            for (x, cell) in row.cells.iter().enumerate() {
                if cell.hyperlink == Some(source) {
                    coords.push(Coordinate {
                        x: x as CellCountInt,
                        y: y as u32,
                    });
                }
            }
        }
        coords
    }
}

fn push_mapped_char(
    out: &mut String,
    map: Option<&mut Vec<Coordinate>>,
    ch: char,
    coordinate: Coordinate,
) {
    out.push(ch);
    if let Some(map) = map {
        map.extend(std::iter::repeat_n(coordinate, ch.len_utf8()));
    }
}

fn viewport_row_delta(
    pages: &crate::page_list::PageList,
    previous: Pin,
    current: Pin,
    rows: CellCountInt,
) -> Option<i32> {
    for distance in 1..usize::from(rows) {
        if pages
            .pin_down(previous, distance)
            .is_some_and(|pin| pin.eql(current))
        {
            return i32::try_from(distance).ok();
        }
        if pages
            .pin_up(previous, distance)
            .is_some_and(|pin| pin.eql(current))
        {
            return i32::try_from(distance).ok().map(i32::wrapping_neg);
        }
    }
    None
}

fn snapshot_cell(page: &crate::page::Page, y: CellCountInt, x: CellCountInt) -> RenderCell {
    let cell = page.cell(y, x);
    RenderCell {
        raw: cell,
        style: if cell.has_styling() {
            page.style_for_cell(y, x)
                .map(Style::from)
                .unwrap_or_default()
        } else {
            Style::default()
        },
        grapheme: if cell.has_grapheme() {
            page.grapheme(y, x).unwrap_or_default()
        } else {
            Vec::new()
        },
        hyperlink: if cell.hyperlink() {
            page.hyperlink_id(y, x)
        } else {
            None
        },
    }
}

fn render_row_matches(
    cached: &RenderRow,
    page: &crate::page::Page,
    y: CellCountInt,
    cols: CellCountInt,
) -> bool {
    let mut cached_raw = cached.raw;
    cached_raw.set_dirty(false);
    let mut current_raw = page.row(y);
    current_raw.set_dirty(false);
    if cached_raw != current_raw {
        return false;
    }

    (0..cols).all(|x| {
        cached
            .cells
            .get(x as usize)
            .is_some_and(|cell| *cell == snapshot_cell(page, y, x))
    })
}

type SelectionCache = (Selection, Pin, Pin, Coordinate, Coordinate);

fn selection_cache(
    screen: &crate::screen::Screen,
    selection: Option<Selection>,
) -> Option<SelectionCache> {
    let selection = selection?;
    let top = selection.top_left(&screen.pages)?;
    let bottom = selection.bottom_right(&screen.pages)?;
    // ghostty: render.zig:601-602 -- selection endpoints remain resolvable
    // after either endpoint leaves the viewport.
    let top_coord = screen.pages.point_from_pin(Tag::Screen, top)?.coord();
    let bottom_coord = screen.pages.point_from_pin(Tag::Screen, bottom)?.coord();
    Some((selection, top, bottom, top_coord, bottom_coord))
}

fn snapshot_colors(terminal: &Terminal) -> RenderColors {
    let palette = terminal.colors.palette.current;
    let mut background = terminal.colors.background.get().unwrap_or(palette[0]);
    let mut foreground = terminal.colors.foreground.get().unwrap_or(palette[7]);
    if terminal.modes.get(Mode::ReverseColors) {
        std::mem::swap(&mut background, &mut foreground);
    }
    RenderColors {
        background,
        foreground,
        cursor: terminal.colors.cursor.get().unwrap_or(foreground),
        palette,
    }
}

fn snapshot_cursor(terminal: &Terminal) -> RenderCursor {
    let screen = terminal.active_screen();
    let active = Coordinate {
        x: screen.cursor.x,
        y: u32::from(screen.cursor.y),
    };
    RenderCursor {
        active,
        viewport: None,
        cell: screen.cursor_cell().unwrap_or_default(),
        style: screen.cursor.style,
        visual_style: screen.cursor.cursor_style,
        password_input: terminal.flags.password_input,
        visible: terminal.modes.get(Mode::CursorVisible),
        blinking: terminal.modes.get(Mode::CursorBlinking),
    }
}

trait DirtyExt {
    fn any(self) -> bool;
    fn clear(&mut self);
}

impl DirtyExt for crate::terminal::Dirty {
    fn any(self) -> bool {
        self.screen || self.tabs || self.title || self.palette
    }

    fn clear(&mut self) {
        *self = Self::default();
    }
}

impl DirtyExt for crate::screen::Dirty {
    fn any(self) -> bool {
        self.selection || self.hyperlink_hover
    }

    fn clear(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::Rgb;
    use crate::highlight::Untracked;
    use crate::page::STD_CAPACITY;
    use crate::point::Point;
    use crate::selection::Selection;
    use crate::sgr::Underline;
    use crate::stream::EraseLine;
    use crate::terminal::{Options, Terminal};

    fn terminal(cols: CellCountInt, rows: CellCountInt) -> Terminal {
        Terminal::new(Options {
            cols,
            rows,
            max_scrollback: 1024,
            ..Options::default()
        })
    }

    fn terminal_with_text(cols: CellCountInt, rows: CellCountInt, text: &str) -> Terminal {
        let mut terminal = terminal(cols, rows);
        terminal.print_string(text);
        terminal
    }

    #[test]
    fn styled() {
        // ghostty: "styled" (render.zig:882)
        let mut terminal = terminal(80, 24);
        terminal.decaln();
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(render.dirty, DirtyState::Full);
        assert_eq!(render.rows, 24);
        assert_eq!(render.cols, 80);
        assert_eq!(render.row_data[0].cells[0].raw.codepoint(), 'E' as u32);
    }

    #[test]
    fn basic_text() {
        // ghostty: "basic text" (render.zig:900)
        let mut terminal = terminal_with_text(10, 3, "ABCD");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(render.rows, 3);
        assert_eq!(render.row_data.len(), 3);
        for row in &render.row_data {
            assert_eq!(row.cells.len(), 10);
        }
        assert_eq!(render.row_data[0].cells[0].raw.codepoint(), 'A' as u32);
        assert_eq!(render.row_data[0].cells[1].raw.codepoint(), 'B' as u32);
        assert_eq!(render.row_data[0].cells[2].raw.codepoint(), 'C' as u32);
        assert_eq!(render.row_data[0].cells[3].raw.codepoint(), 'D' as u32);
        assert_eq!(render.row_data[0].cells[4].raw.codepoint(), 0);
    }

    #[test]
    fn styled_text() {
        // ghostty: "styled text" (render.zig:936)
        let mut terminal = terminal(10, 3);
        terminal.active_screen_mut().cursor.style.flags.bold = true;
        terminal.active_screen_mut().manual_style_update();
        terminal.print_string("A");
        terminal.active_screen_mut().cursor.style.flags.bold = false;
        terminal.active_screen_mut().cursor.style.flags.italic = true;
        terminal.active_screen_mut().manual_style_update();
        terminal.print_string("B");
        terminal.active_screen_mut().cursor.style.flags.italic = false;
        terminal.active_screen_mut().cursor.style.flags.underline = Underline::Single;
        terminal.active_screen_mut().manual_style_update();
        terminal.print_string("C");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(render.row_data[0].cells[0].raw.codepoint(), 'A' as u32);
        assert!(render.row_data[0].cells[0].style.flags.bold);
        assert_eq!(render.row_data[0].cells[1].raw.codepoint(), 'B' as u32);
        assert!(!render.row_data[0].cells[1].style.flags.bold);
        assert!(render.row_data[0].cells[1].style.flags.italic);
        assert_eq!(render.row_data[0].cells[2].raw.codepoint(), 'C' as u32);
        assert_eq!(
            render.row_data[0].cells[2].style.flags.underline,
            Underline::Single
        );
    }

    #[test]
    fn plain_row_snapshot_resets_stale_managed_fields() {
        let mut terminal = terminal(12, 2);
        terminal.active_screen_mut().cursor.style.flags.bold = true;
        terminal.active_screen_mut().manual_style_update();
        terminal.print_string("S");
        terminal.active_screen_mut().cursor.style = Style::default();
        terminal.active_screen_mut().manual_style_update();
        terminal.print_string("👨\u{200D}");
        terminal
            .active_screen_mut()
            .start_hyperlink(Some(b"id"), b"https://example.test");
        terminal.print_string("H");
        terminal.active_screen_mut().end_hyperlink();

        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert!(render.row_data[0].cells[0].style.flags.bold);
        assert!(!render.row_data[0].cells[1].grapheme.is_empty());
        assert!(render.row_data[0].cells[3].hyperlink.is_some());

        terminal.set_cursor_pos(1, 1);
        terminal.erase_line(EraseLine::Complete, false);
        terminal.print_string("plain");
        render.update(&mut terminal);

        for cell in &render.row_data[0].cells {
            assert_eq!(cell.style, Style::default());
            assert!(cell.grapheme.is_empty());
            assert!(cell.hyperlink.is_none());
        }
        let codepoints: Vec<u32> = render.row_data[0]
            .cells
            .iter()
            .map(|cell| cell.raw.codepoint())
            .collect();
        assert_eq!(
            &codepoints[..5],
            &['p' as u32, 'l' as u32, 'a' as u32, 'i' as u32, 'n' as u32]
        );

        terminal.set_cursor_pos(1, 1);
        terminal.erase_line(EraseLine::Complete, false);
        terminal.print_string("a");
        terminal.active_screen_mut().cursor.style.flags.bold = true;
        terminal.active_screen_mut().manual_style_update();
        terminal.print_string("b");
        terminal.active_screen_mut().cursor.style = Style::default();
        terminal.active_screen_mut().manual_style_update();
        terminal.print_string("c");
        render.update(&mut terminal);

        assert_eq!(render.row_data[0].cells[0].style, Style::default());
        assert!(render.row_data[0].cells[1].style.flags.bold);
        assert_eq!(render.row_data[0].cells[2].style, Style::default());
    }

    #[test]
    fn grapheme() {
        // ghostty: "grapheme" (render.zig:982)
        let mut terminal = terminal_with_text(10, 3, "A👨\u{200d}");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(render.row_data[0].cells[0].raw.codepoint(), 'A' as u32);
        assert_eq!(render.row_data[0].cells[1].raw.codepoint(), 0x1F468);
        assert_eq!(render.row_data[0].cells[1].raw.wide(), CellWide::Wide);
        assert_eq!(render.row_data[0].cells[1].grapheme, vec![0x200D]);
        assert_eq!(render.row_data[0].cells[2].raw.codepoint(), 0);
        assert_eq!(render.row_data[0].cells[2].raw.wide(), CellWide::SpacerTail);
    }

    #[test]
    fn cursor_state_in_viewport() {
        // ghostty: "cursor state in viewport" (render.zig:1029)
        let mut terminal = terminal_with_text(10, 5, "A");
        terminal.set_cursor_pos(1, 1);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(render.cursor.active, Coordinate { x: 0, y: 0 });
        assert_eq!(
            render.cursor.viewport.unwrap().coord,
            Coordinate { x: 0, y: 0 }
        );
        assert_eq!(render.cursor.cell.codepoint(), 'A' as u32);
        assert_eq!(render.cursor.style, Style::default());

        terminal.active_screen_mut().cursor.style.flags.bold = true;
        terminal.active_screen_mut().manual_style_update();
        render.update(&mut terminal);
        assert!(render.cursor.style.flags.bold);

        terminal.active_screen_mut().cursor.style = Style::default();
        terminal.active_screen_mut().manual_style_update();
        terminal.set_cursor_pos(2, 3);
        render.update(&mut terminal);
        assert_eq!(render.cursor.active, Coordinate { x: 2, y: 1 });
        assert_eq!(
            render.cursor.viewport.unwrap().coord,
            Coordinate { x: 2, y: 1 }
        );
    }

    #[test]
    fn cursor_state_out_of_viewport() {
        // ghostty: "cursor state out of viewport" (render.zig:1071)
        let mut terminal = terminal_with_text(10, 2, "A\r\nB\r\nC\r\nD\r\n");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(render.cursor.active, Coordinate { x: 0, y: 1 });
        assert_eq!(
            render.cursor.viewport.unwrap().coord,
            Coordinate { x: 0, y: 1 }
        );
        terminal.scroll_viewport(crate::page_list::Scroll::Top);
        render.update(&mut terminal);
        assert_eq!(render.cursor.active, Coordinate { x: 0, y: 1 });
        assert!(render.cursor.viewport.is_none());
    }

    #[test]
    fn cursor_wide_tail_false_after_wide_char() {
        let mut terminal = terminal_with_text(10, 3, "\u{3042}");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);

        let viewport = render.cursor.viewport.expect("cursor must be visible");
        assert_eq!(viewport.coord.x, 2);
        assert!(!viewport.wide_tail);
    }

    #[test]
    fn cursor_wide_tail_true_on_spacer_tail() {
        let mut terminal = terminal_with_text(10, 3, "\u{3042}");
        terminal.set_cursor_pos(1, 2);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);

        let viewport = render.cursor.viewport.expect("cursor must be visible");
        assert_eq!(viewport.coord.x, 1);
        assert!(viewport.wide_tail);
    }

    #[test]
    fn cursor_wide_tail_false_at_column_zero() {
        let mut terminal = terminal_with_text(10, 3, "\u{3042}");
        terminal.set_cursor_pos(1, 1);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);

        let viewport = render.cursor.viewport.expect("cursor must be visible");
        assert_eq!(viewport.coord.x, 0);
        assert!(!viewport.wide_tail);
    }

    #[test]
    fn dirty_state() {
        // ghostty: "dirty state" (render.zig:1105)
        let mut terminal = terminal(10, 5);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(render.dirty, DirtyState::Full);

        for row in &mut render.row_data {
            row.dirty = false;
        }
        render.update(&mut terminal);
        assert_eq!(render.dirty, DirtyState::False);
        assert!(render.row_data.iter().all(|row| !row.dirty));

        terminal.print_string("A");
        render.update(&mut terminal);
        assert_eq!(render.dirty, DirtyState::Partial);
        assert!(render.row_data[0].dirty);
        assert!(!render.row_data[1].dirty);
    }

    #[test]
    fn row_edits_do_not_force_full_redraw() {
        let mut edited = terminal_with_text(10, 4, "abcdef");
        let mut render = RenderState::new(0, 0);
        render.update(&mut edited);

        edited.set_cursor_pos(1, 3);
        edited.delete_chars(1);
        render.update(&mut edited);

        assert_eq!(render.dirty, DirtyState::Partial);
        assert_eq!(
            render
                .row_data
                .iter()
                .enumerate()
                .filter_map(|(index, row)| row.dirty.then_some(index))
                .collect::<Vec<_>>(),
            vec![0]
        );
    }

    #[test]
    fn region_scroll_does_not_force_full_redraw() {
        let mut scrolled = terminal(10, 5);
        scrolled.set_top_and_bottom_margin(2, 4);
        scrolled.set_mode(Mode::EnableLeftAndRightMargin);
        scrolled.set_left_and_right_margin(2, 9);
        scrolled.set_cursor_pos(4, 2);
        let mut render = RenderState::new(0, 0);
        render.update(&mut scrolled);

        scrolled.linefeed();
        render.update(&mut scrolled);

        assert_eq!(render.dirty, DirtyState::Partial);
        assert_eq!(
            render
                .row_data
                .iter()
                .enumerate()
                .filter_map(|(index, row)| row.dirty.then_some(index))
                .collect::<Vec<_>>(),
            vec![1, 2, 3]
        );
    }

    #[test]
    fn viewport_scroll_reuses_rows() {
        let mut terminal = terminal_with_text(8, 3, "one\r\ntwo\r\nthree");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        let surviving_row = render.row_data[1].cells.clone();

        terminal.linefeed();
        render.update(&mut terminal);

        assert_eq!(render.scroll_delta, 1);
        assert_eq!(render.dirty, DirtyState::Partial);
        assert_eq!(render.row_data[0].cells, surviving_row);
        assert_eq!(
            render
                .row_data
                .iter()
                .enumerate()
                .filter_map(|(index, row)| row.dirty.then_some(index))
                .collect::<Vec<_>>(),
            vec![2]
        );
    }

    #[test]
    fn viewport_jump_falls_back_to_full_redraw() {
        let mut terminal = terminal_with_text(8, 3, "one\r\ntwo\r\nthree");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        terminal.print_string("\r\nfive\r\nsix\r\nseven");
        render.update(&mut terminal);
        terminal.scroll_viewport(crate::page_list::Scroll::DeltaRow(-3));
        render.update(&mut terminal);

        assert_eq!(render.scroll_delta, 0);
        assert_eq!(render.dirty, DirtyState::Full);
        assert!(render.row_data.iter().all(|row| row.dirty));
    }

    #[test]
    fn viewport_scroll_up_reuses_rows() {
        let mut terminal = terminal_with_text(8, 3, "one\r\ntwo\r\nthree\r\nfour\r\nfive");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        let surviving_row = render.row_data[0].cells.clone();

        terminal.scroll_viewport(crate::page_list::Scroll::DeltaRow(-1));
        render.update(&mut terminal);

        assert_eq!(render.scroll_delta, -1);
        assert_eq!(render.dirty, DirtyState::Partial);
        assert_eq!(render.row_data[1].cells, surviving_row);
        assert_eq!(
            render
                .row_data
                .iter()
                .enumerate()
                .filter_map(|(index, row)| row.dirty.then_some(index))
                .collect::<Vec<_>>(),
            vec![0]
        );
    }

    #[test]
    fn colors() {
        // ghostty: "colors" (render.zig:1154)
        let mut terminal = terminal(10, 5);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        let red = Rgb {
            r: 0xff,
            g: 0,
            b: 0,
        };
        let white = Rgb {
            r: 0xff,
            g: 0xff,
            b: 0xff,
        };
        terminal.colors.cursor.set(red);
        terminal.colors.palette.set(0, white);
        terminal.dirty.palette = true;
        render.update(&mut terminal);
        assert_eq!(render.colors.cursor, red);
        assert_eq!(render.colors.palette[0], white);
    }

    #[test]
    fn selection_single_line() {
        // ghostty: "selection single line" (render.zig:1191)
        let mut terminal = terminal_with_text(10, 3, "line0\nabcdef\nline2");
        let pages = &terminal.active_screen().pages;
        let selection = Selection::new(
            pages.pin(Point::active(0, 1)).unwrap(),
            pages.pin(Point::active(2, 1)).unwrap(),
            false,
        );
        terminal.active_screen_mut().select(Some(selection));
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(render.row_data[0].selection, None);
        assert_eq!(
            render.row_data[1].selection,
            Some(RenderSelection { start: 0, end: 2 })
        );
        assert_eq!(render.row_data[2].selection, None);
        terminal.active_screen_mut().select(None);
        render.update(&mut terminal);
        assert!(render.row_data.iter().all(|row| row.selection.is_none()));
    }

    #[test]
    fn selection_multiple_lines() {
        // ghostty: "selection multiple lines" (render.zig:1226)
        let mut terminal = terminal_with_text(10, 3, "first\nsecond\nthird");
        let pages = &terminal.active_screen().pages;
        let selection = Selection::new(
            pages.pin(Point::active(0, 1)).unwrap(),
            pages.pin(Point::active(2, 2)).unwrap(),
            false,
        );
        terminal.active_screen_mut().select(Some(selection));
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert_eq!(
            render.row_data[1].selection,
            Some(RenderSelection { start: 0, end: 9 })
        );
        assert_eq!(
            render.row_data[2].selection,
            Some(RenderSelection { start: 0, end: 2 })
        );
    }

    #[test]
    fn selection_highlight_survives_offscreen_endpoints() {
        let mut terminal = terminal_with_text(8, 3, "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive");
        terminal.scroll_viewport(crate::page_list::Scroll::Top);
        let pages = &terminal.active_screen().pages;
        let selection = Selection::new(
            pages.pin(Point::screen(1, 0)).unwrap(),
            pages.pin(Point::screen(3, 5)).unwrap(),
            false,
        );
        terminal.active_screen_mut().select(Some(selection));
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);

        terminal.scroll_viewport(crate::page_list::Scroll::DeltaRow(2));
        render.update(&mut terminal);

        assert_eq!(
            render.row_data[0].selection,
            Some(RenderSelection { start: 0, end: 7 })
        );
        assert_eq!(
            render.row_data[2].selection,
            Some(RenderSelection { start: 0, end: 7 })
        );
    }

    #[test]
    fn link_cells() {
        // ghostty: "linkCells" (render.zig:1262)
        let mut terminal = terminal(10, 5);
        terminal
            .active_screen_mut()
            .start_hyperlink(Some(b"id"), b"https://example.test");
        terminal.print_string("LINK");
        terminal.active_screen_mut().end_hyperlink();
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        let cells = render.link_cells(Coordinate { x: 0, y: 0 });
        assert_eq!(
            cells,
            vec![
                Coordinate { x: 0, y: 0 },
                Coordinate { x: 1, y: 0 },
                Coordinate { x: 2, y: 0 },
                Coordinate { x: 3, y: 0 },
            ]
        );
        assert!(render.link_cells(Coordinate { x: 4, y: 0 }).is_empty());
    }

    #[test]
    fn string() {
        // ghostty: "string" (render.zig:1298)
        let mut terminal = terminal_with_text(5, 2, "AB");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        let (string, _) = render.string(false);
        assert_eq!(string, "AB\0\0\0\n\0\0\0\0\0\n");
    }

    #[test]
    fn string_map_tracks_utf8_bytes_after_wide_graphemes() {
        // ghostty: render.zig:746-793 -- each emitted UTF-8 byte maps back to
        // the source cell, including grapheme continuations.
        let mut terminal = terminal_with_text(20, 1, "日本語👨\u{200d}💻ASCII");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);

        let (string, map) = render.string(true);
        let map = map.expect("requested byte map");
        let ascii = string.find("ASCII").expect("ASCII suffix");
        assert_eq!(map.len(), string.len());
        assert_eq!(map[ascii], Coordinate { x: 8, y: 0 });
        assert_eq!(map[ascii + 4], Coordinate { x: 12, y: 0 });

        let emoji = string.find('👨').expect("emoji base");
        let laptop = string.find('💻').expect("emoji continuation");
        assert_eq!(map[emoji], Coordinate { x: 6, y: 0 });
        assert_eq!(map[laptop], Coordinate { x: 6, y: 0 });
    }

    #[test]
    fn link_cells_with_scrollback_spanning_pages() {
        // ghostty: "linkCells with scrollback spanning pages" (render.zig:1328)
        let mut terminal = Terminal::new(Options {
            cols: STD_CAPACITY.cols,
            rows: 10,
            max_scrollback: 10_000,
            ..Options::default()
        });
        for _ in 0..STD_CAPACITY.rows {
            terminal.print_string("x\n");
        }
        terminal
            .active_screen_mut()
            .start_hyperlink(Some(b"id"), b"https://example.test");
        terminal.print_string("LINK");
        terminal.active_screen_mut().end_hyperlink();
        terminal.print_string("\n");
        for _ in 0..5 {
            terminal.print_string("tail\n");
        }
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        let linked_cells: Vec<_> = (0..render.rows)
            .flat_map(|y| render.link_cells(Coordinate { x: 0, y: y as u32 }))
            .collect();
        assert!(linked_cells.len() >= 4);
        assert!(linked_cells
            .iter()
            .any(|coord| coord.y < render.rows as u32));
    }

    #[test]
    fn link_cells_with_invalid_viewport_point() {
        // ghostty: "linkCells with invalid viewport point" (render.zig:1370)
        let mut terminal = terminal(10, 5);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        assert!(render.link_cells(Coordinate { x: 0, y: 15 }).is_empty());
        assert!(render.link_cells(Coordinate { x: 20, y: 0 }).is_empty());
    }

    #[test]
    fn dirty_row_resets_highlights() {
        // ghostty: "dirty row resets highlights" (render.zig:1408)
        let mut terminal = terminal_with_text(10, 3, "ABC");
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        render.dirty = DirtyState::False;
        for row in &mut render.row_data {
            row.dirty = false;
        }
        let pages = &terminal.active_screen().pages;
        let highlight = Flattened::new(
            pages,
            Untracked::new(
                pages.pin(Point::screen(0, 0)).unwrap(),
                pages.pin(Point::screen(2, 0)).unwrap(),
            ),
        )
        .unwrap();
        render.update_highlights_flattened(1, &[highlight]);
        assert_eq!(render.row_data[0].highlights.len(), 1);
        terminal.set_cursor_pos(1, 1);
        terminal.print_string("X");
        render.update(&mut terminal);
        assert!(render.row_data[0].highlights.is_empty());
    }

    #[test]
    fn multi_row_highlight_clips_only_boundary_rows() {
        let mut terminal = terminal(10, 3);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        let pages = &terminal.active_screen().pages;
        let highlight = Flattened::new(
            pages,
            Untracked::new(
                pages.pin(Point::screen(3, 0)).unwrap(),
                pages.pin(Point::screen(6, 2)).unwrap(),
            ),
        )
        .unwrap();

        render.update_highlights_flattened(7, &[highlight]);

        assert_eq!(
            render.row_data[0].highlights,
            vec![RenderHighlight {
                tag: 7,
                start: 3,
                end: 9,
            }]
        );
        assert_eq!(
            render.row_data[1].highlights,
            vec![RenderHighlight {
                tag: 7,
                start: 0,
                end: 9,
            }]
        );
        assert_eq!(
            render.row_data[2].highlights,
            vec![RenderHighlight {
                tag: 7,
                start: 0,
                end: 6,
            }]
        );
    }

    #[test]
    fn wrapped_multi_row_highlight_never_inverts_ranges() {
        let mut terminal = terminal(10, 3);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        render.dirty = DirtyState::False;
        for row in &mut render.row_data {
            row.dirty = false;
        }
        let pages = &terminal.active_screen().pages;
        let highlight = Flattened::new(
            pages,
            Untracked::new(
                pages.pin(Point::screen(8, 0)).unwrap(),
                pages.pin(Point::screen(2, 2)).unwrap(),
            ),
        )
        .unwrap();

        render.update_highlights_flattened(9, &[highlight]);

        assert_eq!(render.dirty, DirtyState::Partial);
        assert!(render.row_data.iter().all(|row| row.dirty));
        assert!(render
            .row_data
            .iter()
            .flat_map(|row| &row.highlights)
            .all(|highlight| highlight.start <= highlight.end));
    }

    #[test]
    fn multi_row_highlight_marks_changed_rows_dirty() {
        let mut terminal = terminal(10, 3);
        let mut render = RenderState::new(0, 0);
        render.update(&mut terminal);
        render.dirty = DirtyState::False;
        for row in &mut render.row_data {
            row.dirty = false;
        }
        let pages = &terminal.active_screen().pages;
        let highlight = Flattened::new(
            pages,
            Untracked::new(
                pages.pin(Point::screen(1, 0)).unwrap(),
                pages.pin(Point::screen(4, 2)).unwrap(),
            ),
        )
        .unwrap();

        render.update_highlights_flattened(10, &[highlight]);

        assert_eq!(render.dirty, DirtyState::Partial);
        assert!(render.row_data.iter().all(|row| row.dirty));
    }
}
