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
            screen_key: crate::screen_set::ScreenKey::Primary,
            viewport_pin: None,
        }
    }

    pub fn update(&mut self, terminal: &mut Terminal) {
        let screen_key = terminal.screens.active_key();
        let screen = terminal.active_screen();
        let dims_changed = self.rows != screen.rows() || self.cols != screen.cols();
        let viewport_pin = Some(screen.pages.get_top_left(Tag::Viewport));
        let redraw = dims_changed
            || self.screen_key != screen_key
            || self.viewport_pin != viewport_pin
            || terminal.dirty.any()
            || screen.dirty.any();

        self.rows = screen.rows();
        self.cols = screen.cols();
        self.screen_key = screen_key;
        self.viewport_pin = viewport_pin;
        self.colors = snapshot_colors(terminal);
        self.cursor = snapshot_cursor(terminal);

        if dims_changed || self.row_data.len() != self.rows as usize {
            self.row_data = (0..self.rows)
                .map(|_| RenderRow::blank(self.cols))
                .collect();
        }
        for row in &mut self.row_data {
            if row.cells.len() != self.cols as usize {
                row.cells = vec![RenderCell::default(); self.cols as usize];
            }
            row.selection = None;
            row.highlights.clear();
            row.dirty = redraw;
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
            let was_dirty = row.dirty || screen.pages.pin_is_dirty(pin);
            row.pin = Some(pin);
            row.raw = node.page.row(pin.y);
            row.dirty = was_dirty;
            if was_dirty {
                for x in 0..self.cols {
                    let cell = node.page.cell(pin.y, x);
                    row.cells[x as usize] = RenderCell {
                        raw: cell,
                        style: node
                            .page
                            .style_for_cell(pin.y, x)
                            .map(Style::from)
                            .unwrap_or_default(),
                        grapheme: node.page.grapheme(pin.y, x).unwrap_or_default(),
                        hyperlink: node.page.hyperlink_id(pin.y, x),
                    };
                }
            }
            if let Some(cursor_pin) = cursor_pin {
                if cursor_pin.node == pin.node && cursor_pin.y == pin.y {
                    self.cursor.viewport = Some(CursorViewport {
                        coord: Coordinate {
                            x: cursor_pin.x,
                            y: u32::from(y),
                        },
                        wide_tail: screen
                            .cursor_cell_left(1)
                            .map(|cell| cell.wide() == CellWide::SpacerTail)
                            .unwrap_or(false),
                    });
                }
            }
            if let Some((selection, top, bottom, top_coord, bottom_coord)) = selection_cache {
                let point = Coordinate {
                    x: pin.x,
                    y: u32::from(y),
                };
                if let Some(row_selection) = selection.contained_row_cached(
                    &screen.pages,
                    top,
                    bottom,
                    pin,
                    top_coord,
                    bottom_coord,
                    point,
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
            row.highlights.clear();
            let Some(pin) = row.pin else {
                continue;
            };
            for highlight in highlights {
                if highlight.chunks.iter().any(|chunk| {
                    chunk.node == pin.node && pin.y >= chunk.start && pin.y < chunk.end
                }) {
                    row.highlights.push(RenderHighlight {
                        tag,
                        start: if highlight.chunks.first().map(|chunk| chunk.node) == Some(pin.node)
                        {
                            highlight.top_x
                        } else {
                            0
                        },
                        end: if highlight.chunks.last().map(|chunk| chunk.node) == Some(pin.node) {
                            highlight.bot_x
                        } else {
                            self.cols.saturating_sub(1)
                        },
                    });
                }
            }
        }
    }

    pub fn string(&self, include_map: bool) -> (String, Option<Vec<Coordinate>>) {
        let mut out = String::new();
        let mut map = include_map.then(Vec::new);
        for (row_index, row) in self.row_data.iter().enumerate() {
            for x in 0..self.cols {
                let cell = row
                    .cells
                    .get(x as usize)
                    .map(|cell| cell.raw)
                    .unwrap_or_default();
                let ch = if cell.has_text() {
                    char::from_u32(cell.codepoint()).unwrap_or('\0')
                } else {
                    '\0'
                };
                out.push(ch);
                if let Some(map) = &mut map {
                    map.push(Coordinate {
                        x,
                        y: row_index as u32,
                    });
                }
            }
            if !row.raw.wrap() {
                out.push('\n');
                if let Some(map) = &mut map {
                    map.push(Coordinate {
                        x: self.cols.saturating_sub(1),
                        y: row_index as u32,
                    });
                }
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

type SelectionCache = (Selection, Pin, Pin, Coordinate, Coordinate);

fn selection_cache(
    screen: &crate::screen::Screen,
    selection: Option<Selection>,
) -> Option<SelectionCache> {
    let selection = selection?;
    let top = selection.top_left(&screen.pages)?;
    let bottom = selection.bottom_right(&screen.pages)?;
    let top_coord = screen.pages.point_from_pin(Tag::Viewport, top)?.coord();
    let bottom_coord = screen.pages.point_from_pin(Tag::Viewport, bottom)?.coord();
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
}
