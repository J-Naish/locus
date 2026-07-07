//! Terminal screen formatters.
//!
//! This module ports the plaintext half of Ghostty's
//! `terminal/formatter.zig`. The existing `Screen::dump_string*` helpers stay
//! in place as compatibility surfaces; this formatter is the richer walk used
//! by later export/copy paths.

use crate::page::{Cell, CellContentTag, CellWide, Page};
use crate::page_list::{Direction, PageList, Pin};
use crate::point::{Coordinate, Point, Tag};
use crate::screen::Screen;
use crate::selection::Selection;
use crate::size::CellCountInt;
use crate::terminal::Terminal;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Format {
    Plain,
    Vt,
    Html,
}

impl Format {
    pub const fn format_styled(self) -> bool {
        matches!(self, Self::Vt | Self::Html)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodepointReplacement {
    Codepoint(char),
    String(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodepointMap {
    pub range: (u32, u32),
    pub replacement: CodepointReplacement,
}

impl CodepointMap {
    pub const fn codepoint(start: char, end: char, replacement: char) -> Self {
        Self {
            range: (start as u32, end as u32),
            replacement: CodepointReplacement::Codepoint(replacement),
        }
    }

    pub fn string(start: char, end: char, replacement: &str) -> Self {
        Self {
            range: (start as u32, end as u32),
            replacement: CodepointReplacement::String(replacement.to_owned()),
        }
    }

    const fn contains(&self, codepoint: u32) -> bool {
        codepoint >= self.range.0 && codepoint <= self.range.1
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Options {
    pub emit: Format,
    pub unwrap: bool,
    pub trim: bool,
    pub codepoint_map: Vec<CodepointMap>,
}

impl Options {
    pub fn plain() -> Self {
        Self {
            emit: Format::Plain,
            unwrap: false,
            trim: true,
            codepoint_map: Vec::new(),
        }
    }

    pub fn plain_unwrapped() -> Self {
        Self {
            unwrap: true,
            ..Self::plain()
        }
    }
}

impl Default for Options {
    fn default() -> Self {
        Self::plain()
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TrailingState {
    pub rows: usize,
    pub cells: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PageFormat {
    pub text: String,
    pub point_map: Vec<Coordinate>,
    pub trailing_state: TrailingState,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PinFormat {
    pub text: String,
    pub pin_map: Vec<Pin>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PendingNewline {
    coordinate: Coordinate,
}

pub struct PageFormatter<'a> {
    pub page: &'a Page,
    pub opts: Options,
    pub start_x: CellCountInt,
    pub end_x: Option<CellCountInt>,
    pub start_y: CellCountInt,
    pub end_y: Option<CellCountInt>,
    pub rectangle: bool,
}

impl<'a> PageFormatter<'a> {
    pub fn new(page: &'a Page) -> Self {
        Self {
            page,
            opts: Options::plain(),
            start_x: 0,
            end_x: None,
            start_y: 0,
            end_y: None,
            rectangle: false,
        }
    }

    pub fn format(&self) -> PageFormat {
        self.format_with_state(TrailingState::default())
    }

    pub fn format_with_state(&self, trailing_state: TrailingState) -> PageFormat {
        let mut out = PageFormat {
            text: String::new(),
            point_map: Vec::new(),
            trailing_state: TrailingState::default(),
        };
        let size = self.page.size();
        let cols = size.cols;
        let rows = size.rows;

        let mut blank_cells = 0usize;
        let mut pending_newlines = Vec::<PendingNewline>::new();
        if self.start_x == 0 && self.start_y == 0 {
            blank_cells = trailing_state.cells;
            for row in 0..trailing_state.rows {
                pending_newlines.push(PendingNewline {
                    coordinate: Coordinate {
                        x: 0,
                        y: row as u32,
                    },
                });
            }
        }

        if cols == 0 || rows == 0 || self.start_x >= cols || self.start_y >= rows {
            out.trailing_state = TrailingState {
                rows: pending_newlines.len(),
                cells: blank_cells,
            };
            return out;
        }

        let mut end_x = self.end_x.unwrap_or(cols.saturating_sub(1)).min(cols - 1);
        let mut end_y = self.end_y.unwrap_or(rows.saturating_sub(1)).min(rows - 1);
        if self.start_y > end_y {
            out.trailing_state = TrailingState {
                rows: pending_newlines.len(),
                cells: blank_cells,
            };
            return out;
        }

        if self.opts.unwrap && !self.rectangle {
            let cell = self.page.cell(end_y, end_x);
            if matches!(cell.wide(), CellWide::SpacerHead) && end_y + 1 < rows {
                end_y += 1;
                end_x = 0;
            }
        }

        if self.start_y == end_y && self.start_x > end_x {
            out.trailing_state = TrailingState {
                rows: pending_newlines.len(),
                cells: blank_cells,
            };
            return out;
        }

        for y in self.start_y..=end_y {
            let row_end_x = if self.rectangle || y == end_y {
                end_x.saturating_add(1).min(cols)
            } else {
                cols
            };
            let row_start_x = if y == self.start_y || self.rectangle {
                match self.page.cell(y, self.start_x).wide() {
                    CellWide::SpacerTail => self.start_x.saturating_sub(1),
                    CellWide::SpacerHead => continue,
                    CellWide::Narrow | CellWide::Wide => self.start_x,
                }
            } else {
                0
            };

            if row_start_x >= row_end_x {
                continue;
            }

            if !self.row_has_text(y, row_start_x, row_end_x) {
                pending_newlines.push(PendingNewline {
                    coordinate: Coordinate { x: 0, y: y.into() },
                });
                continue;
            }

            self.flush_newlines(&mut out, &mut pending_newlines);

            let row = self.page.row(y);
            if !row.wrap_continuation() || !self.opts.unwrap {
                blank_cells = 0;
            }

            let mut last_emitted = Coordinate { x: 0, y: y.into() };
            for x in row_start_x..row_end_x {
                let cell = self.page.cell(y, x);
                match cell.wide() {
                    CellWide::SpacerHead | CellWide::SpacerTail => continue,
                    CellWide::Narrow | CellWide::Wide => {}
                }

                if self.cell_is_blank_for_plain(cell) {
                    blank_cells = blank_cells.saturating_add(1);
                    continue;
                }

                self.flush_blank_cells(&mut out, blank_cells, y, x);
                blank_cells = 0;

                let coordinate = Coordinate { x, y: y.into() };
                self.write_cell(&mut out, y, x, cell, coordinate);
                last_emitted = coordinate;
            }

            if !row.wrap() || !self.opts.unwrap {
                pending_newlines.push(PendingNewline {
                    coordinate: last_emitted,
                });
            }
        }

        out.trailing_state = TrailingState {
            rows: pending_newlines.len(),
            cells: blank_cells,
        };
        out
    }

    fn row_has_text(&self, y: CellCountInt, start: CellCountInt, end: CellCountInt) -> bool {
        (start..end).any(|x| self.page.cell(y, x).has_text())
    }

    fn cell_is_blank_for_plain(&self, cell: Cell) -> bool {
        if !cell.has_text() {
            return true;
        }
        self.opts.trim && cell.codepoint() == u32::from(' ')
    }

    fn flush_newlines(&self, out: &mut PageFormat, pending: &mut Vec<PendingNewline>) {
        for newline in pending.drain(..) {
            out.text.push('\n');
            out.point_map.push(newline.coordinate);
        }
    }

    fn flush_blank_cells(
        &self,
        out: &mut PageFormat,
        count: usize,
        y: CellCountInt,
        current_x: CellCountInt,
    ) {
        if count == 0 {
            return;
        }
        let start = current_x.saturating_sub(count as CellCountInt);
        for offset in 0..count {
            out.text.push(' ');
            out.point_map.push(Coordinate {
                x: start.saturating_add(offset as CellCountInt),
                y: y.into(),
            });
        }
    }

    fn write_cell(
        &self,
        out: &mut PageFormat,
        y: CellCountInt,
        x: CellCountInt,
        cell: Cell,
        coordinate: Coordinate,
    ) {
        match cell.content_tag() {
            CellContentTag::BgColorPalette | CellContentTag::BgColorRgb => {
                self.write_codepoint(out, u32::from(' '), coordinate);
            }
            CellContentTag::Codepoint | CellContentTag::CodepointGrapheme => {
                if cell.codepoint() != 0 {
                    self.write_codepoint(out, cell.codepoint(), coordinate);
                }
                if cell.has_grapheme() {
                    if let Some(values) = self.page.grapheme(y, x) {
                        for value in values {
                            self.write_codepoint(out, value, coordinate);
                        }
                    }
                }
            }
        }
    }

    fn write_codepoint(&self, out: &mut PageFormat, codepoint: u32, coordinate: Coordinate) {
        for mapping in self.opts.codepoint_map.iter().rev() {
            if !mapping.contains(codepoint) {
                continue;
            }
            match &mapping.replacement {
                CodepointReplacement::Codepoint(ch) => {
                    push_mapped_char(&mut out.text, &mut out.point_map, *ch, coordinate);
                }
                CodepointReplacement::String(value) => {
                    out.text.push_str(value);
                    out.point_map
                        .extend(std::iter::repeat_n(coordinate, value.len()));
                }
            }
            return;
        }

        if let Some(ch) = char::from_u32(codepoint) {
            push_mapped_char(&mut out.text, &mut out.point_map, ch, coordinate);
        }
    }
}

pub struct PageListFormatter<'a> {
    pub list: &'a PageList,
    pub opts: Options,
    pub top_left: Option<Pin>,
    pub bottom_right: Option<Pin>,
    pub rectangle: bool,
}

impl<'a> PageListFormatter<'a> {
    pub fn new(list: &'a PageList) -> Self {
        Self {
            list,
            opts: Options::plain(),
            top_left: None,
            bottom_right: None,
            rectangle: false,
        }
    }

    pub fn format(&self) -> PinFormat {
        let top_left = self
            .top_left
            .unwrap_or_else(|| self.list.get_top_left(Tag::Screen));
        let Some(bottom_right) = self
            .bottom_right
            .or_else(|| self.list.get_bottom_right(Tag::Screen))
        else {
            return PinFormat {
                text: String::new(),
                pin_map: Vec::new(),
            };
        };

        let mut text = String::new();
        let mut pin_map = Vec::new();
        let mut trailing = TrailingState::default();
        let mut current = Some(top_left.node);

        while let Some(node_id) = current {
            let Some(node) = self.list.node(node_id) else {
                break;
            };
            let start_y = if node_id == top_left.node {
                top_left.y
            } else {
                0
            };
            let end_y = if node_id == bottom_right.node {
                bottom_right.y
            } else {
                node.page.size().rows.saturating_sub(1)
            };
            let start_x = if node_id == top_left.node || self.rectangle {
                top_left.x
            } else {
                0
            };
            let end_x = if node_id == bottom_right.node || self.rectangle {
                Some(bottom_right.x)
            } else {
                None
            };

            let page_format = PageFormatter {
                page: &node.page,
                opts: self.opts.clone(),
                start_x,
                end_x,
                start_y,
                end_y: Some(end_y),
                rectangle: self.rectangle,
            }
            .format_with_state(trailing);

            for point in page_format.point_map {
                pin_map.push(Pin {
                    node: node_id,
                    x: point.x,
                    y: point.y as CellCountInt,
                    garbage: false,
                });
            }
            text.push_str(&page_format.text);
            trailing = page_format.trailing_state;

            if node_id == bottom_right.node {
                break;
            }
            current = node.next;
        }

        PinFormat { text, pin_map }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenContent {
    None,
    Selection(Option<Selection>),
}

pub struct ScreenFormatter<'a> {
    pub screen: &'a Screen,
    pub opts: Options,
    pub content: ScreenContent,
}

impl<'a> ScreenFormatter<'a> {
    pub fn new(screen: &'a Screen) -> Self {
        Self {
            screen,
            opts: Options::plain(),
            content: ScreenContent::Selection(None),
        }
    }

    pub fn format(&self) -> PinFormat {
        match self.content {
            ScreenContent::None => PinFormat {
                text: String::new(),
                pin_map: Vec::new(),
            },
            ScreenContent::Selection(selection) => {
                let (top_left, bottom_right, rectangle) = match selection {
                    Some(selection) => {
                        let Some(top_left) = selection.top_left(&self.screen.pages) else {
                            return PinFormat {
                                text: String::new(),
                                pin_map: Vec::new(),
                            };
                        };
                        let Some(bottom_right) = selection.bottom_right(&self.screen.pages) else {
                            return PinFormat {
                                text: String::new(),
                                pin_map: Vec::new(),
                            };
                        };
                        (Some(top_left), Some(bottom_right), selection.rectangle)
                    }
                    None => (
                        Some(self.screen.pages.get_top_left(Tag::Screen)),
                        self.screen.pages.get_bottom_right(Tag::Screen),
                        false,
                    ),
                };
                PageListFormatter {
                    list: &self.screen.pages,
                    opts: self.opts.clone(),
                    top_left,
                    bottom_right,
                    rectangle,
                }
                .format()
            }
        }
    }
}

pub struct TerminalFormatter<'a> {
    pub terminal: &'a Terminal,
    pub opts: Options,
    pub content: ScreenContent,
}

impl<'a> TerminalFormatter<'a> {
    pub fn new(terminal: &'a Terminal) -> Self {
        Self {
            terminal,
            opts: Options::plain(),
            content: ScreenContent::Selection(None),
        }
    }

    pub fn format(&self) -> PinFormat {
        ScreenFormatter {
            screen: self.terminal.active_screen(),
            opts: self.opts.clone(),
            content: self.content,
        }
        .format()
    }
}

fn push_mapped_char(
    text: &mut String,
    map: &mut Vec<Coordinate>,
    ch: char,
    coordinate: Coordinate,
) {
    text.push(ch);
    map.extend(std::iter::repeat_n(coordinate, ch.len_utf8()));
}

#[allow(dead_code)]
fn _iterator_dependency_marker(_: Direction, _: Point) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page::{Capacity, PageSize};
    use crate::selection::Selection;
    use crate::terminal::{Options as TerminalOptions, Terminal};

    fn page(cols: CellCountInt, rows: CellCountInt) -> Page {
        let mut page = Page::init(Capacity::new(cols, rows));
        page.set_size(PageSize { cols, rows });
        page
    }

    fn write_row(page: &mut Page, y: CellCountInt, text: &str) {
        let mut x = 0;
        for ch in text.chars() {
            if x >= page.size().cols {
                break;
            }
            if ch == '⚡' && x + 1 < page.size().cols {
                let mut cell = Cell::new(ch);
                cell.set_wide(CellWide::Wide);
                page.set_cell(y, x, cell);
                let mut tail = Cell::default();
                tail.set_wide(CellWide::SpacerTail);
                page.set_cell(y, x + 1, tail);
                x += 2;
            } else {
                page.set_cell(y, x, Cell::new(ch));
                x += 1;
            }
        }
    }

    fn page_from_rows(cols: CellCountInt, rows: &[&str]) -> Page {
        let mut page = page(cols, rows.len() as CellCountInt);
        for (y, row) in rows.iter().enumerate() {
            write_row(&mut page, y as CellCountInt, row);
        }
        page
    }

    fn page_from_wrapped(cols: CellCountInt, text: &str) -> Page {
        let chars: Vec<char> = text.chars().collect();
        let row_count = chars.len().div_ceil(cols as usize).max(1);
        let mut page = page(cols, row_count as CellCountInt);
        for (index, ch) in chars.into_iter().enumerate() {
            let y = (index / cols as usize) as CellCountInt;
            let x = (index % cols as usize) as CellCountInt;
            page.set_cell(y, x, Cell::new(ch));
        }
        for y in 0..row_count as CellCountInt {
            let mut row = page.row(y);
            row.set_wrap((y as usize) + 1 < row_count);
            row.set_wrap_continuation(y > 0);
            page.set_row(y, row);
        }
        page
    }

    fn format_page(page: &Page) -> PageFormat {
        PageFormatter::new(page).format()
    }

    fn format_page_with(page: &Page, configure: impl FnOnce(&mut PageFormatter<'_>)) -> PageFormat {
        let mut formatter = PageFormatter::new(page);
        configure(&mut formatter);
        formatter.format()
    }

    fn terminal(cols: CellCountInt, rows: CellCountInt) -> Terminal {
        Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback: 4096,
            width_px: 0,
            height_px: 0,
        })
    }

    fn terminal_with_text(cols: CellCountInt, rows: CellCountInt, text: &str) -> Terminal {
        let mut terminal = terminal(cols, rows);
        terminal.print_string(text);
        terminal
    }

    // ghostty: "Page plain single line" (formatter.zig:1591)
    #[test]
    fn page_plain_single_line() {
        let page = page_from_rows(80, &["hello, world"]);
        let result = format_page(&page);
        assert_eq!(result.text, "hello, world");
        assert_eq!(result.trailing_state.rows, page.size().rows as usize);
        assert_eq!(result.trailing_state.cells, 68);
        assert_eq!(result.point_map[0], Coordinate { x: 0, y: 0 });
    }

    // ghostty: "Page plain single line soft-wrapped unwrapped" (formatter.zig:1638)
    #[test]
    fn page_plain_single_line_soft_wrapped_unwrapped() {
        let page = page_from_wrapped(3, "hello!");
        let result = format_page_with(&page, |formatter| formatter.opts.unwrap = true);
        assert_eq!(result.text, "hello!");
        assert_eq!(
            result.point_map,
            vec![
                Coordinate { x: 0, y: 0 },
                Coordinate { x: 1, y: 0 },
                Coordinate { x: 2, y: 0 },
                Coordinate { x: 0, y: 1 },
                Coordinate { x: 1, y: 1 },
                Coordinate { x: 2, y: 1 },
            ]
        );
    }

    // ghostty: "Page plain single wide char" (formatter.zig:1708)
    #[test]
    fn page_plain_single_wide_char() {
        let page = page_from_rows(80, &["1A⚡"]);
        assert_eq!(format_page(&page).text, "1A⚡");
        assert_eq!(
            format_page_with(&page, |formatter| formatter.start_x = 2).text,
            "⚡"
        );
        assert_eq!(
            format_page_with(&page, |formatter| formatter.start_x = 3).text,
            "⚡"
        );
    }

    // ghostty: "Page plain single wide char soft-wrapped unwrapped" (formatter.zig:1799)
    #[test]
    fn page_plain_single_wide_char_soft_wrapped_unwrapped() {
        let mut page = page(3, 2);
        write_row(&mut page, 0, "1A");
        let mut head = Cell::default();
        head.set_wide(CellWide::SpacerHead);
        page.set_cell(0, 2, head);
        let mut row0 = page.row(0);
        row0.set_wrap(true);
        page.set_row(0, row0);
        write_row(&mut page, 1, "⚡");
        let mut row1 = page.row(1);
        row1.set_wrap_continuation(true);
        page.set_row(1, row1);
        let result = format_page_with(&page, |formatter| formatter.opts.unwrap = true);
        assert_eq!(result.text, "1A⚡");
    }

    // ghostty: "Page plain multiline" (formatter.zig:1916)
    #[test]
    fn page_plain_multiline() {
        let page = page_from_rows(80, &["hello", "world"]);
        let result = format_page(&page);
        assert_eq!(result.text, "hello\nworld");
        assert_eq!(result.point_map[5], Coordinate { x: 4, y: 0 });
    }

    // ghostty: "Page plain multiline rectangle" (formatter.zig:1967)
    #[test]
    fn page_plain_multiline_rectangle() {
        let page = page_from_rows(80, &["hello", "world"]);
        let result = format_page_with(&page, |formatter| {
            formatter.start_x = 1;
            formatter.end_x = Some(3);
            formatter.rectangle = true;
        });
        assert_eq!(result.text, "ell\norl");
    }

    // ghostty: "Page plain multi blank lines" (formatter.zig:2021)
    #[test]
    fn page_plain_multi_blank_lines() {
        let page = page_from_rows(80, &["hello", "", "", "world"]);
        assert_eq!(format_page(&page).text, "hello\n\n\nworld");
    }

    // ghostty: "Page plain trailing blank lines" (formatter.zig:2074)
    #[test]
    fn page_plain_trailing_blank_lines() {
        let page = page_from_rows(80, &["hello", "world", "", ""]);
        assert_eq!(format_page(&page).text, "hello\nworld");
    }

    // ghostty: "Page plain trailing whitespace" (formatter.zig:2127)
    #[test]
    fn page_plain_trailing_whitespace() {
        let page = page_from_rows(80, &["hello   ", "world   "]);
        assert_eq!(format_page(&page).text, "hello\nworld");
    }

    // ghostty: "Page plain trailing whitespace no trim" (formatter.zig:2180)
    #[test]
    fn page_plain_trailing_whitespace_no_trim() {
        let page = page_from_rows(80, &["hello   ", "world  "]);
        let result = format_page_with(&page, |formatter| formatter.opts.trim = false);
        assert_eq!(result.text, "hello   \nworld  ");
    }

    // ghostty: "Page plain with prior trailing state rows" (formatter.zig:2236)
    #[test]
    fn page_plain_with_prior_trailing_state_rows() {
        let page = page_from_rows(80, &["hello"]);
        let result =
            PageFormatter::new(&page).format_with_state(TrailingState { rows: 2, cells: 0 });
        assert_eq!(result.text, "\n\nhello");
    }

    // ghostty: "Page plain with prior trailing state cells no wrapped line" (formatter.zig:2282)
    #[test]
    fn page_plain_with_prior_trailing_state_cells_no_wrapped_line() {
        let page = page_from_rows(80, &["hello"]);
        let result =
            PageFormatter::new(&page).format_with_state(TrailingState { rows: 0, cells: 3 });
        assert_eq!(result.text, "hello");
    }

    // ghostty: "Page plain with prior trailing state cells with wrap continuation" (formatter.zig:2327)
    #[test]
    fn page_plain_with_prior_trailing_state_cells_with_wrap_continuation() {
        let mut page = page_from_rows(80, &["world"]);
        let mut row = page.row(0);
        row.set_wrap_continuation(true);
        page.set_row(0, row);
        let formatter = PageFormatter {
            opts: Options::plain_unwrapped(),
            ..PageFormatter::new(&page)
        };
        let result = formatter.format_with_state(TrailingState { rows: 0, cells: 3 });
        assert_eq!(result.text, "   world");
    }

    // ghostty: "Page plain soft-wrapped without unwrap" (formatter.zig:2381)
    #[test]
    fn page_plain_soft_wrapped_without_unwrap() {
        let page = page_from_wrapped(10, "hello world test");
        assert_eq!(format_page(&page).text, "hello worl\nd test");
    }

    // ghostty: "Page plain soft-wrapped with unwrap" (formatter.zig:2430)
    #[test]
    fn page_plain_soft_wrapped_with_unwrap() {
        let page = page_from_wrapped(10, "hello world test");
        assert_eq!(
            format_page_with(&page, |formatter| formatter.opts.unwrap = true).text,
            "hello world test"
        );
    }

    // ghostty: "Page plain soft-wrapped 3 lines without unwrap" (formatter.zig:2478)
    #[test]
    fn page_plain_soft_wrapped_three_lines_without_unwrap() {
        let page = page_from_wrapped(10, "hello world this is a test");
        assert_eq!(format_page(&page).text, "hello worl\nd this is\na test");
    }

    // ghostty: "Page plain soft-wrapped 3 lines with unwrap" (formatter.zig:2532)
    #[test]
    fn page_plain_soft_wrapped_three_lines_with_unwrap() {
        let page = page_from_wrapped(10, "hello world this is a test");
        assert_eq!(
            format_page_with(&page, |formatter| formatter.opts.unwrap = true).text,
            "hello world this is a test"
        );
    }

    // ghostty: "Page plain start_y subset" (formatter.zig:2584)
    #[test]
    fn page_plain_start_y_subset() {
        let page = page_from_rows(80, &["hello", "world", "test"]);
        assert_eq!(
            format_page_with(&page, |f| f.start_y = 1).text,
            "world\ntest"
        );
    }

    // ghostty: "Page plain end_y subset" (formatter.zig:2631)
    #[test]
    fn page_plain_end_y_subset() {
        let page = page_from_rows(80, &["hello", "world", "test"]);
        assert_eq!(
            format_page_with(&page, |f| f.end_y = Some(1)).text,
            "hello\nworld"
        );
    }

    // ghostty: "Page plain start_y and end_y range" (formatter.zig:2678)
    #[test]
    fn page_plain_start_y_and_end_y_range() {
        let page = page_from_rows(80, &["first", "world", "test", "last"]);
        assert_eq!(
            format_page_with(&page, |f| {
                f.start_y = 1;
                f.end_y = Some(2);
            })
            .text,
            "world\ntest"
        );
    }

    // ghostty: "Page plain start_y out of bounds" (formatter.zig:2726)
    #[test]
    fn page_plain_start_y_out_of_bounds() {
        let page = page_from_rows(80, &["hello"]);
        assert_eq!(format_page_with(&page, |f| f.start_y = 30).text, "");
    }

    // ghostty: "Page plain end_y greater than rows" (formatter.zig:2764)
    #[test]
    fn page_plain_end_y_greater_than_rows() {
        let page = page_from_rows(80, &["hello"]);
        assert_eq!(
            format_page_with(&page, |f| f.end_y = Some(30)).text,
            "hello"
        );
    }

    // ghostty: "Page plain end_y less than start_y" (formatter.zig:2807)
    #[test]
    fn page_plain_end_y_less_than_start_y() {
        let page = page_from_rows(80, &["hello"]);
        assert_eq!(
            format_page_with(&page, |f| {
                f.start_y = 5;
                f.end_y = Some(2);
            })
            .text,
            ""
        );
    }

    // ghostty: "Page plain start_x on first row only" (formatter.zig:2846)
    #[test]
    fn page_plain_start_x_on_first_row_only() {
        let page = page_from_rows(80, &["hello world"]);
        assert_eq!(format_page_with(&page, |f| f.start_x = 6).text, "world");
    }

    // ghostty: "Page plain end_x on last row only" (formatter.zig:2888)
    #[test]
    fn page_plain_end_x_on_last_row_only() {
        let page = page_from_rows(80, &["first line", "second line", "third line"]);
        assert_eq!(
            format_page_with(&page, |f| {
                f.end_y = Some(2);
                f.end_x = Some(4);
            })
            .text,
            "first line\nsecond line\nthird"
        );
    }

    // ghostty: "Page plain start_x and end_x multiline" (formatter.zig:2941)
    #[test]
    fn page_plain_start_x_and_end_x_multiline() {
        let page = page_from_rows(80, &["hello world", "test case", "foobar"]);
        assert_eq!(
            format_page_with(&page, |f| {
                f.start_x = 6;
                f.end_y = Some(2);
                f.end_x = Some(2);
            })
            .text,
            "world\ntest case\nfoo"
        );
    }

    // ghostty: "Page plain start_x out of bounds" (formatter.zig:2998)
    #[test]
    fn page_plain_start_x_out_of_bounds() {
        let page = page_from_rows(80, &["hello"]);
        assert_eq!(format_page_with(&page, |f| f.start_x = 100).text, "");
    }

    // ghostty: "Page plain end_x greater than cols" (formatter.zig:3036)
    #[test]
    fn page_plain_end_x_greater_than_cols() {
        let page = page_from_rows(80, &["hello"]);
        assert_eq!(
            format_page_with(&page, |f| f.end_x = Some(100)).text,
            "hello"
        );
    }

    // ghostty: "Page plain end_x less than start_x single row" (formatter.zig:3078)
    #[test]
    fn page_plain_end_x_less_than_start_x_single_row() {
        let page = page_from_rows(80, &["hello"]);
        assert_eq!(
            format_page_with(&page, |f| {
                f.start_x = 10;
                f.end_y = Some(0);
                f.end_x = Some(5);
            })
            .text,
            ""
        );
    }

    // ghostty: "Page plain start_y non-zero ignores trailing state" (formatter.zig:3118)
    #[test]
    fn page_plain_start_y_non_zero_ignores_trailing_state() {
        let page = page_from_rows(80, &["hello", "world"]);
        let formatter = PageFormatter {
            start_y: 1,
            ..PageFormatter::new(&page)
        };
        assert_eq!(
            formatter
                .format_with_state(TrailingState { rows: 5, cells: 10 })
                .text,
            "world"
        );
    }

    // ghostty: "Page plain start_x non-zero ignores trailing state" (formatter.zig:3162)
    #[test]
    fn page_plain_start_x_non_zero_ignores_trailing_state() {
        let page = page_from_rows(80, &["hello world"]);
        let formatter = PageFormatter {
            start_x: 6,
            ..PageFormatter::new(&page)
        };
        assert_eq!(
            formatter
                .format_with_state(TrailingState { rows: 2, cells: 8 })
                .text,
            "world"
        );
    }

    // ghostty: "Page plain start_y and start_x zero uses trailing state" (formatter.zig:3206)
    #[test]
    fn page_plain_start_y_and_start_x_zero_uses_trailing_state() {
        let page = page_from_rows(80, &["hello"]);
        assert_eq!(
            PageFormatter::new(&page)
                .format_with_state(TrailingState { rows: 2, cells: 0 })
                .text,
            "\n\nhello"
        );
    }

    // ghostty: "Page plain single line with styling" (formatter.zig:3253)
    #[test]
    fn page_plain_single_line_with_styling() {
        let page = page_from_rows(80, &["hello, world"]);
        assert_eq!(format_page(&page).text, "hello, world");
    }

    // ghostty: "PageList plain single line" (formatter.zig:3574)
    #[test]
    fn page_list_plain_single_line() {
        let terminal = terminal_with_text(80, 24, "hello, world");
        let result = PageListFormatter::new(&terminal.active_screen().pages).format();
        assert_eq!(result.text, "hello, world");
        assert_eq!(result.pin_map[0].x, 0);
    }

    // ghostty: "PageList plain spanning two pages" (formatter.zig:3610)
    #[test]
    fn page_list_plain_spanning_two_pages() {
        let mut terminal = terminal(10, 3);
        for _ in 0..terminal.first_page_capacity_rows() {
            terminal.print_string("          \n");
        }
        terminal.print_string("page one\npage two");
        let result = PageListFormatter::new(&terminal.active_screen().pages).format();
        assert!(result.text.ends_with("page one\npage two"));
    }

    // ghostty: "PageList soft-wrapped line spanning two pages without unwrap" (formatter.zig:3683)
    #[test]
    fn page_list_soft_wrapped_line_spanning_two_pages_without_unwrap() {
        let terminal = terminal_with_text(10, 3, "hello world test");
        let result = PageListFormatter::new(&terminal.active_screen().pages).format();
        assert_eq!(result.text, "hello worl\nd test");
    }

    // ghostty: "PageList soft-wrapped line spanning two pages with unwrap" (formatter.zig:3747)
    #[test]
    fn page_list_soft_wrapped_line_spanning_two_pages_with_unwrap() {
        let terminal = terminal_with_text(10, 3, "hello world test");
        let mut formatter = PageListFormatter::new(&terminal.active_screen().pages);
        formatter.opts.unwrap = true;
        assert_eq!(formatter.format().text, "hello world test");
    }

    // ghostty: "PageList plain with x offset on single page" (formatter.zig:3868)
    #[test]
    fn page_list_plain_with_x_offset_on_single_page() {
        let terminal = terminal_with_text(80, 24, "hello world\ntest case\nfoobar");
        let pages = &terminal.active_screen().pages;
        let mut formatter = PageListFormatter::new(pages);
        formatter.top_left = pages.pin(Point::screen(6, 0));
        formatter.bottom_right = pages.pin(Point::screen(2, 2));
        assert_eq!(formatter.format().text, "world\ntest case\nfoo");
    }

    // ghostty: "PageList plain with x offset spanning two pages" (formatter.zig:3914)
    #[test]
    fn page_list_plain_with_x_offset_spanning_two_pages() {
        let terminal = terminal_with_text(80, 24, "hello world\nfoo");
        let pages = &terminal.active_screen().pages;
        let mut formatter = PageListFormatter::new(pages);
        formatter.top_left = pages.pin(Point::screen(6, 0));
        formatter.bottom_right = pages.pin(Point::screen(2, 1));
        assert_eq!(formatter.format().text, "world\nfoo");
    }

    // ghostty: "PageList plain with start_x only" (formatter.zig:3984)
    #[test]
    fn page_list_plain_with_start_x_only() {
        let terminal = terminal_with_text(80, 24, "hello world");
        let pages = &terminal.active_screen().pages;
        let mut formatter = PageListFormatter::new(pages);
        formatter.top_left = pages.pin(Point::screen(6, 0));
        assert_eq!(formatter.format().text, "world");
    }

    // ghostty: "PageList plain with end_x only" (formatter.zig:4025)
    #[test]
    fn page_list_plain_with_end_x_only() {
        let terminal = terminal_with_text(80, 24, "hello world\ntest");
        let pages = &terminal.active_screen().pages;
        let mut formatter = PageListFormatter::new(pages);
        formatter.bottom_right = pages.pin(Point::screen(2, 1));
        assert_eq!(formatter.format().text, "hello world\ntes");
    }

    // ghostty: "PageList plain rectangle basic" (formatter.zig:4078)
    #[test]
    fn page_list_plain_rectangle_basic() {
        let terminal = terminal_with_text(30, 5, "0123456789\nabcdefghij\nklmnopqrst");
        let pages = &terminal.active_screen().pages;
        let mut formatter = PageListFormatter::new(pages);
        formatter.rectangle = true;
        formatter.top_left = pages.pin(Point::screen(2, 0));
        formatter.bottom_right = pages.pin(Point::screen(6, 2));
        assert_eq!(formatter.format().text, "23456\ncdefg\nmnopq");
    }

    // ghostty: "PageList plain rectangle with EOL" (formatter.zig:4118)
    #[test]
    fn page_list_plain_rectangle_with_eol() {
        let terminal = terminal_with_text(30, 5, "hello world\nshort\nthird");
        let pages = &terminal.active_screen().pages;
        let mut formatter = PageListFormatter::new(pages);
        formatter.rectangle = true;
        formatter.top_left = pages.pin(Point::screen(2, 0));
        formatter.bottom_right = pages.pin(Point::screen(8, 2));
        assert_eq!(formatter.format().text, "llo wor\nort\nird");
    }

    // ghostty: "PageList plain rectangle more complex with breaks" (formatter.zig:4160)
    #[test]
    fn page_list_plain_rectangle_more_complex_with_breaks() {
        let terminal = terminal_with_text(30, 8, "aaaaaaaaaa\nbbbbbbbbbb\n\ncccccccccc");
        let pages = &terminal.active_screen().pages;
        let mut formatter = PageListFormatter::new(pages);
        formatter.rectangle = true;
        formatter.top_left = pages.pin(Point::screen(2, 1));
        formatter.bottom_right = pages.pin(Point::screen(5, 3));
        assert_eq!(formatter.format().text, "bbbb\n\ncccc");
    }

    // ghostty: "TerminalFormatter plain no selection" (formatter.zig:4206)
    #[test]
    fn terminal_formatter_plain_no_selection() {
        let terminal = terminal_with_text(80, 24, "hello\nworld");
        assert_eq!(
            TerminalFormatter::new(&terminal).format().text,
            "hello\nworld"
        );
    }

    // ghostty: "TerminalFormatter with selection" (formatter.zig:4275)
    #[test]
    fn terminal_formatter_with_selection() {
        let terminal = terminal_with_text(80, 24, "line1\nline2\nline3");
        let pages = &terminal.active_screen().pages;
        let selection = Selection::new(
            pages.pin(Point::screen(0, 1)).unwrap(),
            pages.pin(Point::screen(4, 1)).unwrap(),
            false,
        );
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.content = ScreenContent::Selection(Some(selection));
        assert_eq!(formatter.format().text, "line2");
    }

    // ghostty: "TerminalFormatter plain with pin_map" (formatter.zig:4304)
    #[test]
    fn terminal_formatter_plain_with_pin_map() {
        let terminal = terminal_with_text(80, 24, "hello, world");
        let result = TerminalFormatter::new(&terminal).format();
        assert_eq!(result.text, "hello, world");
        assert_eq!(result.pin_map.len(), result.text.len());
    }

    // ghostty: "TerminalFormatter plain multiline with pin_map" (formatter.zig:4341)
    #[test]
    fn terminal_formatter_plain_multiline_with_pin_map() {
        let terminal = terminal_with_text(80, 24, "hello\nworld");
        let result = TerminalFormatter::new(&terminal).format();
        assert_eq!(result.text, "hello\nworld");
        assert_eq!(result.pin_map[6].y, 1);
    }

    // ghostty: "TerminalFormatter with selection and pin_map" (formatter.zig:4426)
    #[test]
    fn terminal_formatter_with_selection_and_pin_map() {
        let terminal = terminal_with_text(80, 24, "line1\nline2");
        let pages = &terminal.active_screen().pages;
        let selection = Selection::new(
            pages.pin(Point::screen(0, 1)).unwrap(),
            pages.pin(Point::screen(4, 1)).unwrap(),
            false,
        );
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.content = ScreenContent::Selection(Some(selection));
        let result = formatter.format();
        assert_eq!(result.text, "line2");
        assert!(result.pin_map.iter().all(|pin| pin.y == 1));
    }

    // ghostty: "Screen plain single line" (formatter.zig:4470)
    #[test]
    fn screen_plain_single_line() {
        let terminal = terminal_with_text(80, 24, "hello, world");
        assert_eq!(
            ScreenFormatter::new(terminal.active_screen()).format().text,
            "hello, world"
        );
    }

    // ghostty: "Screen plain multiline" (formatter.zig:4507)
    #[test]
    fn screen_plain_multiline() {
        let terminal = terminal_with_text(80, 24, "hello\nworld");
        assert_eq!(
            ScreenFormatter::new(terminal.active_screen()).format().text,
            "hello\nworld"
        );
    }

    // ghostty: "Screen plain with selection" (formatter.zig:4555)
    #[test]
    fn screen_plain_with_selection() {
        let terminal = terminal_with_text(80, 24, "line1\nline2");
        let pages = &terminal.active_screen().pages;
        let selection = Selection::new(
            pages.pin(Point::screen(0, 1)).unwrap(),
            pages.pin(Point::screen(4, 1)).unwrap(),
            false,
        );
        let mut formatter = ScreenFormatter::new(terminal.active_screen());
        formatter.content = ScreenContent::Selection(Some(selection));
        assert_eq!(formatter.format().text, "line2");
    }

    // ghostty: "Page codepoint_map single replacement" (formatter.zig:5629)
    #[test]
    fn page_codepoint_map_single_replacement() {
        let page = page_from_rows(80, &["hello world"]);
        let result = format_page_with(&page, |f| {
            f.opts
                .codepoint_map
                .push(CodepointMap::codepoint('o', 'o', 'x'));
        });
        assert_eq!(result.text, "hellx wxrld");
    }

    // ghostty: "Page codepoint_map conflicting replacement prefers last" (formatter.zig:5688)
    #[test]
    fn page_codepoint_map_conflicting_replacement_prefers_last() {
        let page = page_from_rows(80, &["hello"]);
        let result = format_page_with(&page, |f| {
            f.opts
                .codepoint_map
                .push(CodepointMap::codepoint('o', 'o', 'x'));
            f.opts
                .codepoint_map
                .push(CodepointMap::codepoint('o', 'o', 'y'));
        });
        assert_eq!(result.text, "helly");
    }

    // ghostty: "Page codepoint_map replace with string" (formatter.zig:5730)
    #[test]
    fn page_codepoint_map_replace_with_string() {
        let page = page_from_rows(80, &["hello"]);
        let result = format_page_with(&page, |f| {
            f.opts
                .codepoint_map
                .push(CodepointMap::string('o', 'o', "XYZ"));
        });
        assert_eq!(result.text, "hellXYZ");
        assert_eq!(result.point_map[4], Coordinate { x: 4, y: 0 });
        assert_eq!(result.point_map[6], Coordinate { x: 4, y: 0 });
    }

    // ghostty: "Page codepoint_map range replacement" (formatter.zig:5786)
    #[test]
    fn page_codepoint_map_range_replacement() {
        let page = page_from_rows(80, &["abcdefg"]);
        let result = format_page_with(&page, |f| {
            f.opts
                .codepoint_map
                .push(CodepointMap::codepoint('b', 'e', 'X'));
        });
        assert_eq!(result.text, "aXXXXfg");
    }

    // ghostty: "Page codepoint_map multiple ranges" (formatter.zig:5824)
    #[test]
    fn page_codepoint_map_multiple_ranges() {
        let page = page_from_rows(80, &["abc n xyz"]);
        let result = format_page_with(&page, |f| {
            f.opts
                .codepoint_map
                .push(CodepointMap::codepoint('a', 'm', 'A'));
            f.opts
                .codepoint_map
                .push(CodepointMap::codepoint('n', 'z', 'Z'));
        });
        assert_eq!(result.text, "AAA Z ZZZ");
    }

    // ghostty: "Page codepoint_map unicode replacement" (formatter.zig:5868)
    #[test]
    fn page_codepoint_map_unicode_replacement() {
        let page = page_from_rows(80, &["hello ⚡ world"]);
        let result = format_page_with(&page, |f| {
            f.opts
                .codepoint_map
                .push(CodepointMap::string('⚡', '⚡', "🔥"));
        });
        assert_eq!(result.text, "hello 🔥 world");
    }

    // ghostty: "Page codepoint_map with styled formats" (formatter.zig:5933)
    #[test]
    fn page_codepoint_map_with_styled_formats_plain_half() {
        let page = page_from_rows(80, &["red text"]);
        let result = format_page_with(&page, |f| {
            f.opts.emit = Format::Vt;
            f.opts
                .codepoint_map
                .push(CodepointMap::codepoint('e', 'e', 'X'));
        });
        assert_eq!(result.text, "rXd tXxt");
    }

    // ghostty: "Page codepoint_map empty map" (formatter.zig:5974)
    #[test]
    fn page_codepoint_map_empty_map() {
        let page = page_from_rows(80, &["hello world"]);
        assert_eq!(format_page(&page).text, "hello world");
    }
}
