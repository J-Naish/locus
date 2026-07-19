//! Terminal screen formatters.
//!
//! This module ports the plaintext half of Ghostty's
//! `terminal/formatter.zig`. The existing `Screen::dump_string*` helpers stay
//! in place as compatibility surfaces; this formatter is the richer walk used
//! by later export/copy paths.

use crate::color::{Palette, Rgb};
use crate::modes::Mode;
use crate::page::{Cell, CellContentTag, CellWide, Page};
use crate::page_list::{Direction, PageList, Pin};
use crate::point::{Coordinate, Point, Tag};
use crate::screen::{Charset, CharsetSlot, CharsetState, Screen};
use crate::selection::Selection;
use crate::size::CellCountInt;
use crate::style::{Style, StyleColor};
use crate::terminal::Terminal;
use std::fmt::Write as _;

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

    const fn is_vt(self) -> bool {
        matches!(self, Self::Vt)
    }

    const fn is_html(self) -> bool {
        matches!(self, Self::Html)
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
    pub foreground: Option<Rgb>,
    pub background: Option<Rgb>,
    pub palette: Option<Palette>,
}

impl Options {
    pub fn plain() -> Self {
        Self {
            emit: Format::Plain,
            unwrap: false,
            trim: true,
            codepoint_map: Vec::new(),
            foreground: None,
            background: None,
            palette: None,
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

#[derive(Debug, Default)]
struct PageFormatState {
    current_style: Style,
    current_hyperlink: Option<Vec<u8>>,
    last_coordinate: Option<Coordinate>,
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
        let mut state = PageFormatState::default();
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

        self.write_header(&mut out);

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

            self.flush_newlines(&mut out, &mut pending_newlines, &mut state);

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

                if self.cell_is_blank(cell) {
                    blank_cells = blank_cells.saturating_add(1);
                    continue;
                }

                self.flush_blank_cells(&mut out, &mut state, blank_cells, y, x);
                blank_cells = 0;

                let coordinate = Coordinate { x, y: y.into() };
                self.write_cell(&mut out, &mut state, y, x, cell, coordinate);
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
        self.close_style(&mut out, &mut state, Coordinate { x: 0, y: 0 });
        self.close_hyperlink(&mut out, &mut state, Coordinate { x: 0, y: 0 });
        self.write_footer(&mut out);
        out
    }

    fn row_has_text(&self, y: CellCountInt, start: CellCountInt, end: CellCountInt) -> bool {
        (start..end).any(|x| !self.cell_is_blank(self.page.cell(y, x)))
    }

    fn cell_is_blank(&self, cell: Cell) -> bool {
        if self.opts.emit.format_styled() {
            match cell.content_tag() {
                CellContentTag::BgColorPalette | CellContentTag::BgColorRgb => return false,
                CellContentTag::Codepoint | CellContentTag::CodepointGrapheme => {
                    if cell.has_styling() || cell.hyperlink() {
                        return false;
                    }
                }
            }
        }
        if !cell.has_text() {
            return true;
        }
        self.opts.trim && cell.codepoint() == u32::from(' ')
    }

    fn flush_newlines(
        &self,
        out: &mut PageFormat,
        pending: &mut Vec<PendingNewline>,
        state: &mut PageFormatState,
    ) {
        for newline in pending.drain(..) {
            self.close_style(out, state, newline.coordinate);
            if self.opts.emit.is_vt() {
                push_mapped_str(out, "\r\n", newline.coordinate);
            } else {
                push_mapped_char(&mut out.text, &mut out.point_map, '\n', newline.coordinate);
            }
        }
    }

    fn flush_blank_cells(
        &self,
        out: &mut PageFormat,
        state: &mut PageFormatState,
        count: usize,
        y: CellCountInt,
        current_x: CellCountInt,
    ) {
        if count == 0 {
            return;
        }
        let start = current_x.saturating_sub(count as CellCountInt);
        for offset in 0..count {
            let coordinate = Coordinate {
                x: start.saturating_add(offset as CellCountInt),
                y: y.into(),
            };
            self.update_cell_markup(
                out,
                state,
                y,
                coordinate.x,
                self.page.cell(y, coordinate.x),
                coordinate,
            );
            push_mapped_char(&mut out.text, &mut out.point_map, ' ', coordinate);
            state.last_coordinate = Some(coordinate);
        }
    }

    fn write_cell(
        &self,
        out: &mut PageFormat,
        state: &mut PageFormatState,
        y: CellCountInt,
        x: CellCountInt,
        cell: Cell,
        coordinate: Coordinate,
    ) {
        self.update_cell_markup(out, state, y, x, cell, coordinate);
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
        state.last_coordinate = Some(coordinate);
    }

    fn write_codepoint(&self, out: &mut PageFormat, codepoint: u32, coordinate: Coordinate) {
        for mapping in self.opts.codepoint_map.iter().rev() {
            if !mapping.contains(codepoint) {
                continue;
            }
            match &mapping.replacement {
                CodepointReplacement::Codepoint(ch) => {
                    self.write_char(out, *ch, coordinate);
                }
                CodepointReplacement::String(value) => {
                    self.write_str_content(out, value, coordinate);
                }
            }
            return;
        }

        if let Some(ch) = char::from_u32(codepoint) {
            self.write_char(out, ch, coordinate);
        }
    }

    fn write_header(&self, out: &mut PageFormat) {
        let coordinate = Coordinate { x: 0, y: 0 };
        if self.opts.emit.is_vt() {
            if let Some(foreground) = self.opts.foreground {
                push_mapped_str(out, &osc_color(10, foreground), coordinate);
            }
            if let Some(background) = self.opts.background {
                push_mapped_str(out, &osc_color(11, background), coordinate);
            }
        } else if self.opts.emit.is_html() {
            let mut header = String::from("<div style=\"font-family: monospace; white-space: pre;");
            if let Some(background) = self.opts.background {
                header.push_str("background-color: ");
                push_css_hex_color(&mut header, background);
                header.push(';');
            }
            if let Some(foreground) = self.opts.foreground {
                header.push_str("color: ");
                push_css_hex_color(&mut header, foreground);
                header.push(';');
            }
            header.push_str("\">");
            push_mapped_str(out, &header, coordinate);
        }
    }

    fn write_footer(&self, out: &mut PageFormat) {
        if self.opts.emit.is_html() {
            push_mapped_str(out, "</div>", Coordinate { x: 0, y: 0 });
        }
    }

    fn update_cell_markup(
        &self,
        out: &mut PageFormat,
        state: &mut PageFormatState,
        y: CellCountInt,
        x: CellCountInt,
        cell: Cell,
        coordinate: Coordinate,
    ) {
        if !self.opts.emit.format_styled() {
            return;
        }

        let style = self.cell_style(y, x, cell);
        if style != state.current_style {
            if self.opts.emit.is_vt() && !style.is_default() {
                self.open_style(out, state, style, coordinate);
            } else {
                self.close_style(out, state, coordinate);
                self.open_style(out, state, style, coordinate);
            }
        }

        if self.opts.emit.is_html() {
            let next_hyperlink = self.page.hyperlink_uri(y, x).map(<[u8]>::to_vec);
            if next_hyperlink != state.current_hyperlink {
                // Ghostty's HTML formatter intentionally closes the style div
                // before the anchor, producing mis-nested markup in styled
                // hyperlinks (formatter.zig:7105-7225). Keep this ordering for
                // byte-for-byte compatibility with the source tests.
                self.close_hyperlink(out, state, coordinate);
                if let Some(uri) = next_hyperlink {
                    self.open_hyperlink(out, state, uri, coordinate);
                }
            }
        }
    }

    fn cell_style(&self, y: CellCountInt, x: CellCountInt, cell: Cell) -> Style {
        let mut style = self
            .page
            .style_for_cell(y, x)
            .map(Style::from)
            .unwrap_or_default();
        match cell.content_tag() {
            CellContentTag::BgColorPalette => {
                style.bg_color = StyleColor::Palette(cell.palette_index());
            }
            CellContentTag::BgColorRgb => {
                style.bg_color = StyleColor::Rgb(cell.rgb());
            }
            CellContentTag::Codepoint | CellContentTag::CodepointGrapheme => {}
        }
        style
    }

    fn open_style(
        &self,
        out: &mut PageFormat,
        state: &mut PageFormatState,
        style: Style,
        coordinate: Coordinate,
    ) {
        if style.is_default() {
            state.current_style = Style::default();
            return;
        }

        if self.opts.emit.is_vt() {
            let mut formatted = style.formatter_vt();
            formatted.palette = self.opts.palette.as_ref();
            push_mapped_str(out, &formatted.to_string(), coordinate);
        } else if self.opts.emit.is_html() {
            let mut formatted = style.formatter_html();
            formatted.palette = self.opts.palette.as_ref();
            let mut tag = String::from("<div style=\"display: inline;");
            tag.push_str(&formatted.to_string());
            tag.push_str("\">");
            push_mapped_str(out, &tag, coordinate);
        }
        state.current_style = style;
    }

    fn close_style(
        &self,
        out: &mut PageFormat,
        state: &mut PageFormatState,
        coordinate: Coordinate,
    ) {
        if state.current_style.is_default() {
            return;
        }
        if self.opts.emit.is_vt() {
            push_mapped_str(out, "\x1b[0m", coordinate);
        } else if self.opts.emit.is_html() {
            push_mapped_str(out, "</div>", coordinate);
        }
        state.current_style = Style::default();
    }

    fn open_hyperlink(
        &self,
        out: &mut PageFormat,
        state: &mut PageFormatState,
        uri: Vec<u8>,
        coordinate: Coordinate,
    ) {
        let mut tag = String::from("<a href=\"");
        push_html_escaped_bytes(&mut tag, &uri, true);
        tag.push_str("\">");
        push_mapped_str(out, &tag, coordinate);
        state.current_hyperlink = Some(uri);
    }

    fn close_hyperlink(
        &self,
        out: &mut PageFormat,
        state: &mut PageFormatState,
        coordinate: Coordinate,
    ) {
        if state.current_hyperlink.is_some() {
            let close_coordinate = state.last_coordinate.unwrap_or(coordinate);
            push_mapped_str(out, "</a>", close_coordinate);
            state.current_hyperlink = None;
        }
    }

    fn write_char(&self, out: &mut PageFormat, ch: char, coordinate: Coordinate) {
        if self.opts.emit.is_html() {
            write_html_char(out, ch, coordinate);
        } else {
            push_mapped_char(&mut out.text, &mut out.point_map, ch, coordinate);
        }
    }

    fn write_str_content(&self, out: &mut PageFormat, value: &str, coordinate: Coordinate) {
        if self.opts.emit.is_html() {
            for ch in value.chars() {
                write_html_char(out, ch, coordinate);
            }
        } else {
            push_mapped_str(out, value, coordinate);
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

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ScreenExtra {
    pub cursor: bool,
    pub style: bool,
    pub hyperlink: bool,
    pub protection: bool,
    pub charsets: bool,
}

impl ScreenExtra {
    pub const NONE: Self = Self {
        cursor: false,
        style: false,
        hyperlink: false,
        protection: false,
        charsets: false,
    };

    pub const STYLES: Self = Self {
        cursor: false,
        style: true,
        hyperlink: true,
        protection: false,
        charsets: false,
    };

    pub const ALL: Self = Self {
        cursor: true,
        style: true,
        hyperlink: true,
        protection: true,
        charsets: true,
    };

    const fn is_set(self) -> bool {
        self.cursor || self.style || self.hyperlink || self.protection || self.charsets
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TerminalExtra {
    pub palette: bool,
    pub modes: bool,
    pub scrolling_region: bool,
    pub tabstops: bool,
    pub pwd: bool,
    pub keyboard: bool,
    pub screen: ScreenExtra,
}

impl TerminalExtra {
    pub const NONE: Self = Self {
        palette: false,
        modes: false,
        scrolling_region: false,
        tabstops: false,
        pwd: false,
        keyboard: false,
        screen: ScreenExtra::NONE,
    };

    pub const STYLES: Self = Self {
        palette: true,
        modes: false,
        scrolling_region: false,
        tabstops: false,
        pwd: false,
        keyboard: false,
        screen: ScreenExtra::STYLES,
    };

    pub const ALL: Self = Self {
        palette: true,
        modes: true,
        scrolling_region: true,
        tabstops: true,
        pwd: true,
        keyboard: true,
        screen: ScreenExtra::ALL,
    };
}

pub struct ScreenFormatter<'a> {
    pub screen: &'a Screen,
    pub opts: Options,
    pub content: ScreenContent,
    pub extra: ScreenExtra,
}

impl<'a> ScreenFormatter<'a> {
    pub fn new(screen: &'a Screen) -> Self {
        Self {
            screen,
            opts: Options::plain(),
            content: ScreenContent::Selection(None),
            extra: ScreenExtra::STYLES,
        }
    }

    pub fn format(&self) -> PinFormat {
        let mut output = match self.content {
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
        };
        self.append_extras(&mut output);
        output
    }

    fn append_extras(&self, out: &mut PinFormat) {
        if !self.opts.emit.is_vt() || !self.extra.is_set() {
            return;
        }

        let pin = format_anchor_pin(out, self.screen.pages.get_top_left(Tag::Screen));
        let cursor = &self.screen.cursor;

        if self.extra.style {
            let mut formatted = cursor.style.formatter_vt();
            formatted.palette = self.opts.palette.as_ref();
            push_pin_mapped_str(out, &formatted.to_string(), pin);
        }

        if self.extra.hyperlink {
            if let Some(link) = cursor.hyperlink.as_ref() {
                push_pin_mapped_str(out, "\x1b]8;;", pin);
                push_pin_mapped_str(out, &String::from_utf8_lossy(&link.uri), pin);
                push_pin_mapped_str(out, "\x1b\\", pin);
            }
        }

        if self.extra.protection && cursor.protected {
            push_pin_mapped_str(out, "\x1b[1\"q", pin);
        }

        if self.extra.charsets {
            append_charset_extras(out, self.screen.charset, pin);
        }

        if self.extra.cursor {
            let sequence = format!("\x1b[{};{}H", cursor.y + 1, cursor.x + 1);
            push_pin_mapped_str(out, &sequence, pin);
        }
    }
}

pub struct TerminalFormatter<'a> {
    pub terminal: &'a Terminal,
    pub opts: Options,
    pub content: ScreenContent,
    pub extra: TerminalExtra,
}

impl<'a> TerminalFormatter<'a> {
    pub fn new(terminal: &'a Terminal) -> Self {
        Self {
            terminal,
            opts: Options::plain(),
            content: ScreenContent::Selection(None),
            extra: TerminalExtra::STYLES,
        }
    }

    pub fn format(&self) -> PinFormat {
        let mut opts = self.opts.clone();
        opts.palette = Some(self.terminal.colors.palette.current);
        opts.foreground = self.terminal.colors.foreground.get();
        opts.background = self.terminal.colors.background.get();
        let mut output = PinFormat {
            text: String::new(),
            pin_map: Vec::new(),
        };
        let anchor = self
            .terminal
            .active_screen()
            .pages
            .get_top_left(Tag::Screen);

        if opts.emit.is_html() && self.extra.palette {
            push_pin_mapped_str(
                &mut output,
                &html_palette_stylesheet(&self.terminal.colors.palette.current),
                anchor,
            );
        } else if opts.emit.is_vt() && self.extra.palette {
            push_pin_mapped_str(
                &mut output,
                &vt_palette_sequences(&self.terminal.colors.palette.current),
                anchor,
            );
        }

        let screen_output = ScreenFormatter {
            screen: self.terminal.active_screen(),
            opts,
            content: self.content,
            extra: self.extra.screen,
        }
        .format();
        append_pin_format(&mut output, screen_output);

        self.append_extras(&mut output);
        output
    }

    fn append_extras(&self, out: &mut PinFormat) {
        if !self.opts.emit.is_vt() {
            return;
        }

        let pin = format_anchor_pin(
            out,
            self.terminal
                .active_screen()
                .pages
                .get_top_left(Tag::Screen),
        );

        if self.extra.scrolling_region {
            let region = &self.terminal.scrolling_region;
            if region.top != 0 || region.bottom != self.terminal.rows - 1 {
                let sequence = format!("\x1b[{};{}r", region.top + 1, region.bottom + 1);
                push_pin_mapped_str(out, &sequence, pin);
            }
            if region.left != 0 || region.right != self.terminal.cols - 1 {
                let sequence = format!("\x1b[{};{}s", region.left + 1, region.right + 1);
                push_pin_mapped_str(out, &sequence, pin);
            }
        }

        if self.extra.modes {
            append_mode_escape(
                out,
                pin,
                self.terminal.modes.get(Mode::BracketedPaste),
                false,
                2004,
            );
            append_mode_escape(
                out,
                pin,
                self.terminal.modes.get(Mode::MouseEventNormal),
                false,
                1000,
            );
            append_mode_escape(out, pin, self.terminal.modes.get(Mode::Wraparound), true, 7);
        }

        if self.extra.tabstops {
            push_pin_mapped_str(out, "\x1b[3g", pin);
            for column in 0..usize::from(self.terminal.cols) {
                if self.terminal.tabstops.get(column) {
                    let sequence = format!("\x1b[{}G\x1bH", column + 1);
                    push_pin_mapped_str(out, &sequence, pin);
                }
            }
        }

        if self.extra.keyboard && self.terminal.flags.modify_other_keys_2 {
            push_pin_mapped_str(out, "\x1b[>4;2m", pin);
        }

        if self.extra.pwd {
            if let Some(pwd) = self.terminal.pwd() {
                push_pin_mapped_str(out, "\x1b]7;", pin);
                push_pin_mapped_str(out, pwd, pin);
                push_pin_mapped_str(out, "\x1b\\", pin);
            }
        }
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

fn push_mapped_str(out: &mut PageFormat, value: &str, coordinate: Coordinate) {
    out.text.push_str(value);
    out.point_map
        .extend(std::iter::repeat_n(coordinate, value.len()));
}

fn append_pin_format(out: &mut PinFormat, value: PinFormat) {
    out.text.push_str(&value.text);
    out.pin_map.extend(value.pin_map);
}

fn push_pin_mapped_str(out: &mut PinFormat, value: &str, pin: Pin) {
    out.text.push_str(value);
    out.pin_map.extend(std::iter::repeat_n(pin, value.len()));
}

fn format_anchor_pin(out: &PinFormat, fallback: Pin) -> Pin {
    out.pin_map.last().copied().unwrap_or(fallback)
}

fn vt_palette_sequences(palette: &Palette) -> String {
    let mut output = String::new();
    for (index, color) in palette.iter().enumerate() {
        let _ = write!(
            output,
            "\x1b]4;{index};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
            color.r, color.g, color.b
        );
    }
    output
}

fn html_palette_stylesheet(palette: &Palette) -> String {
    let mut output = String::from("<style>:root{");
    for (index, color) in palette.iter().enumerate() {
        let _ = write!(output, "--vt-palette-{index}: ");
        push_css_hex_color(&mut output, *color);
        output.push(';');
    }
    output.push_str("}</style>");
    output
}

fn append_mode_escape(out: &mut PinFormat, pin: Pin, enabled: bool, default: bool, value: u16) {
    if enabled == default {
        return;
    }
    let final_byte = if enabled { 'h' } else { 'l' };
    let sequence = format!("\x1b[?{value}{final_byte}");
    push_pin_mapped_str(out, &sequence, pin);
}

fn append_charset_extras(out: &mut PinFormat, charset: CharsetState, pin: Pin) {
    for (slot, value) in [
        (CharsetSlot::G0, charset.g0),
        (CharsetSlot::G1, charset.g1),
        (CharsetSlot::G2, charset.g2),
        (CharsetSlot::G3, charset.g3),
    ] {
        if let Some(sequence) = charset_designation_sequence(slot, value) {
            push_pin_mapped_str(out, sequence, pin);
        }
    }

    match charset.gl {
        CharsetSlot::G0 => push_pin_mapped_str(out, "\x0f", pin),
        CharsetSlot::G1 => push_pin_mapped_str(out, "\x0e", pin),
        // The stream port currently treats ESC n/o as single shifts, so do
        // not serialize persistent G2/G3 GL invocation until that state is
        // modeled symmetrically.
        CharsetSlot::G2 | CharsetSlot::G3 => {}
    }
}

fn charset_designation_sequence(slot: CharsetSlot, charset: Charset) -> Option<&'static str> {
    match (slot, charset) {
        (CharsetSlot::G0, Charset::Ascii) => None,
        (CharsetSlot::G1, Charset::Ascii) => None,
        (CharsetSlot::G2, Charset::Ascii) => None,
        (CharsetSlot::G3, Charset::Ascii) => None,
        (CharsetSlot::G0, Charset::Utf8) => Some("\x1b%G"),
        (CharsetSlot::G0, Charset::British) => Some("\x1b(A"),
        (CharsetSlot::G1, Charset::British) => Some("\x1b)A"),
        (CharsetSlot::G2, Charset::British) => Some("\x1b*A"),
        (CharsetSlot::G3, Charset::British) => Some("\x1b+A"),
        (CharsetSlot::G0, Charset::DecSpecial) => Some("\x1b(0"),
        (CharsetSlot::G1, Charset::DecSpecial) => Some("\x1b)0"),
        (CharsetSlot::G2, Charset::DecSpecial) => Some("\x1b*0"),
        (CharsetSlot::G3, Charset::DecSpecial) => Some("\x1b+0"),
        (CharsetSlot::G1 | CharsetSlot::G2 | CharsetSlot::G3, Charset::Utf8) => None,
    }
}

fn write_html_char(out: &mut PageFormat, ch: char, coordinate: Coordinate) {
    match ch {
        '<' => push_mapped_str(out, "&lt;", coordinate),
        '>' => push_mapped_str(out, "&gt;", coordinate),
        '&' => push_mapped_str(out, "&amp;", coordinate),
        '"' => push_mapped_str(out, "&quot;", coordinate),
        '\'' => push_mapped_str(out, "&#39;", coordinate),
        ch if ch.is_ascii() => push_mapped_char(&mut out.text, &mut out.point_map, ch, coordinate),
        ch => push_mapped_str(out, &format!("&#{};", ch as u32), coordinate),
    }
}

fn push_html_escaped_bytes(out: &mut String, bytes: &[u8], attribute: bool) {
    for byte in bytes {
        match *byte {
            b'<' => out.push_str("&lt;"),
            b'>' => out.push_str("&gt;"),
            b'&' => out.push_str("&amp;"),
            b'"' if attribute => out.push_str("&quot;"),
            b'\'' if attribute => out.push_str("&#39;"),
            byte if byte.is_ascii() => out.push(byte as char),
            byte => {
                let _ = write!(out, "&#{};", byte);
            }
        }
    }
}

fn push_css_hex_color(out: &mut String, color: Rgb) {
    let _ = write!(out, "#{:02x}{:02x}{:02x}", color.r, color.g, color.b);
}

fn osc_color(index: u8, color: Rgb) -> String {
    format!(
        "\x1b]{index};rgb:{:02x}/{:02x}/{:02x}\x1b\\",
        color.r, color.g, color.b
    )
}

#[allow(dead_code)]
fn _iterator_dependency_marker(_: Direction, _: Point) {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::DEFAULT_PALETTE;
    use crate::modes::Mode;
    use crate::page::{Capacity, PageSize};
    use crate::selection::Selection;
    use crate::stream::Stream;
    use crate::stream_terminal::{NoopEffects, TerminalHandler};
    use crate::style::{PackedStyle, StyleFlags};
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

    fn format_page_vt(page: &Page) -> String {
        format_page_with(page, |formatter| formatter.opts.emit = Format::Vt).text
    }

    fn format_page_html(page: &Page) -> String {
        format_page_with(page, |formatter| formatter.opts.emit = Format::Html).text
    }

    fn set_style_range(
        page: &mut Page,
        y: CellCountInt,
        start: CellCountInt,
        end: CellCountInt,
        style: Style,
    ) {
        let packed = PackedStyle::from(style);
        for x in start..end {
            page.set_style(y, x, packed).unwrap();
        }
    }

    fn set_hyperlink_range(
        page: &mut Page,
        y: CellCountInt,
        start: CellCountInt,
        end: CellCountInt,
        uri: &[u8],
    ) {
        let link = page.insert_hyperlink_implicit(1, uri).unwrap();
        for x in start..end {
            page.set_hyperlink_id(y, x, link).unwrap();
        }
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

    fn terminal_from_vt(cols: CellCountInt, rows: CellCountInt, bytes: &[u8]) -> Terminal {
        let handler = TerminalHandler::new(terminal(cols, rows), NoopEffects);
        let mut stream = Stream::new(handler);
        stream.next_slice(bytes);
        stream.handler.into_parts().0
    }

    fn roundtrip_terminal(cols: CellCountInt, rows: CellCountInt, output: &str) -> Terminal {
        terminal_from_vt(cols, rows, output.as_bytes())
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

    // ghostty: "Page VT single line with bold" (formatter.zig:3338)
    #[test]
    fn page_vt_single_line_with_bold_styling() {
        let mut page = page_from_rows(80, &["hello"]);
        set_style_range(
            &mut page,
            0,
            0,
            5,
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        assert_eq!(format_page_vt(&page), "\x1b[0m\x1b[1mhello\x1b[0m");
    }

    // ghostty: "Page VT multiple styles" (formatter.zig:3384)
    #[test]
    fn page_vt_single_line_with_multiple_styles() {
        let mut page = page_from_rows(80, &["hello world"]);
        set_style_range(
            &mut page,
            0,
            0,
            6,
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        set_style_range(
            &mut page,
            0,
            6,
            11,
            Style {
                flags: StyleFlags {
                    bold: true,
                    italic: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        assert_eq!(
            format_page_vt(&page),
            "\x1b[0m\x1b[1mhello \x1b[0m\x1b[1m\x1b[3mworld\x1b[0m"
        );
    }

    // ghostty: "Page VT with foreground color" (formatter.zig:3419)
    #[test]
    fn page_vt_single_line_with_palette_foreground() {
        let mut page = page_from_rows(80, &["red"]);
        set_style_range(
            &mut page,
            0,
            0,
            3,
            Style {
                fg_color: StyleColor::Palette(1),
                ..Style::default()
            },
        );
        assert_eq!(format_page_vt(&page), "\x1b[0m\x1b[38;5;1mred\x1b[0m");
    }

    // ghostty: "Page VT single line plain text" (formatter.zig:3299)
    #[test]
    fn page_vt_single_line_plain_text() {
        let page = page_from_rows(80, &["hello"]);
        assert_eq!(format_page_vt(&page), "hello");
    }

    // ghostty: "Page VT with background and foreground colors" (formatter.zig:3465)
    #[test]
    fn page_vt_includes_foreground_and_background_header() {
        let page = page_from_rows(80, &["hello"]);
        let result = format_page_with(&page, |formatter| {
            formatter.opts.emit = Format::Vt;
            formatter.opts.foreground = Some(Rgb {
                r: 0xab,
                g: 0xcd,
                b: 0xef,
            });
            formatter.opts.background = Some(Rgb {
                r: 0x12,
                g: 0x34,
                b: 0x56,
            });
        });
        assert_eq!(
            result.text,
            "\x1b]10;rgb:ab/cd/ef\x1b\\\x1b]11;rgb:12/34/56\x1b\\hello"
        );
    }

    // ghostty: "Page VT multi-line with styles" (formatter.zig:3502)
    #[test]
    fn page_vt_multiline_closes_style_before_newline() {
        let mut page = page_from_rows(80, &["first", "second"]);
        set_style_range(
            &mut page,
            0,
            0,
            5,
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        set_style_range(
            &mut page,
            1,
            0,
            6,
            Style {
                flags: StyleFlags {
                    italic: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        assert_eq!(
            format_page_vt(&page),
            "\x1b[0m\x1b[1mfirst\x1b[0m\r\n\x1b[0m\x1b[3msecond\x1b[0m"
        );
    }

    // ghostty: "Page VT duplicate style not emitted twice" (formatter.zig:3539)
    #[test]
    fn page_vt_duplicate_style_not_emitted_twice() {
        let mut page = page_from_rows(80, &["hello"]);
        set_style_range(
            &mut page,
            0,
            0,
            5,
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        assert_eq!(format_page_vt(&page), "\x1b[0m\x1b[1mhello\x1b[0m");
    }

    // ghostty: "Page VT with palette option emits RGB" (formatter.zig:5500)
    #[test]
    fn page_vt_with_palette_option_emits_rgb() {
        let mut page = page_from_rows(80, &["red"]);
        set_style_range(
            &mut page,
            0,
            0,
            3,
            Style {
                fg_color: StyleColor::Palette(1),
                ..Style::default()
            },
        );
        let mut palette = DEFAULT_PALETTE;
        palette[1] = Rgb {
            r: 0xab,
            g: 0xcd,
            b: 0xef,
        };
        let result = format_page_with(&page, |formatter| {
            formatter.opts.emit = Format::Vt;
            formatter.opts.palette = Some(palette);
        });
        assert_eq!(result.text, "\x1b[0m\x1b[38;2;171;205;239mred\x1b[0m");
    }

    // ghostty: "Page VT style reset properly closes styles" (formatter.zig:5598)
    #[test]
    fn page_vt_style_reset_properly_closes_styles() {
        let mut page = page_from_rows(80, &["boldnormal"]);
        set_style_range(
            &mut page,
            0,
            0,
            4,
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        assert_eq!(format_page_vt(&page), "\x1b[0m\x1b[1mbold\x1b[0mnormal");
    }

    // ghostty: "Page codepoint_map with styled formats" (formatter.zig:5933)
    #[test]
    fn page_codepoint_map_with_styled_formats_vt() {
        let mut page = page_from_rows(80, &["red text"]);
        set_style_range(
            &mut page,
            0,
            0,
            8,
            Style {
                fg_color: StyleColor::Palette(1),
                ..Style::default()
            },
        );
        let result = format_page_with(&page, |formatter| {
            formatter.opts.emit = Format::Vt;
            formatter
                .opts
                .codepoint_map
                .push(CodepointMap::codepoint('e', 'e', 'X'));
        });
        assert_eq!(result.text, "\x1b[0m\x1b[38;5;1mrXd tXxt\x1b[0m");
    }

    // ghostty: "Page VT background color on trailing blank cells" (formatter.zig:6008)
    #[test]
    fn page_vt_background_color_on_trailing_blank_cells() {
        let mut page = page(12, 2);
        write_row(&mut page, 0, "CPU:");
        for x in 4..10 {
            page.set_cell(0, x, Cell::bg_palette(1));
        }
        write_row(&mut page, 1, "line2");
        let result = format_page_with(&page, |formatter| {
            formatter.opts.emit = Format::Vt;
            formatter.opts.trim = false;
        });
        let first_line = result.text.split("\r\n").next().unwrap();
        assert!(first_line.contains("\x1b[48;5;1m"));
    }

    // ghostty: "Page html plain text" (formatter.zig:5194)
    #[test]
    fn page_html_single_line() {
        let page = page_from_rows(80, &["hello, world"]);
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\">hello, world</div>"
        );
    }

    // ghostty: "Page html ascii characters unchanged" (formatter.zig:5436)
    #[test]
    fn page_html_ascii_characters_unchanged() {
        let page = page_from_rows(80, &["hello world"]);
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\">hello world</div>"
        );
    }

    // ghostty: "Page html with escaping" (formatter.zig:5332)
    #[test]
    fn page_html_escapes_special_characters_and_unicode() {
        let page = page_from_rows(80, &["<tag>&\"'╰─ ❯"]);
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\">&lt;tag&gt;&amp;&quot;&#39;&#9584;&#9472; &#10095;</div>"
        );
    }

    // ghostty: "Page html with unicode as numeric entities" (formatter.zig:5402)
    #[test]
    fn page_html_with_unicode_as_numeric_entities() {
        let page = page_from_rows(80, &["╰─ ❯"]);
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\">&#9584;&#9472; &#10095;</div>"
        );
    }

    // ghostty: "Page html mixed ascii and unicode" (formatter.zig:5468)
    #[test]
    fn page_html_mixed_ascii_and_unicode() {
        let page = page_from_rows(80, &["test ╰─❯ ok"]);
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\">test &#9584;&#9472;&#10095; ok</div>"
        );
    }

    // ghostty: "Page html with multiple styles" (formatter.zig:5158)
    #[test]
    fn page_html_multiple_styles() {
        let mut page = page_from_rows(80, &["bolditalicnormal"]);
        set_style_range(
            &mut page,
            0,
            0,
            4,
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        set_style_range(
            &mut page,
            0,
            4,
            10,
            Style {
                flags: StyleFlags {
                    bold: true,
                    italic: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\"><div style=\"display: inline;font-weight: bold;\">bold</div><div style=\"display: inline;font-weight: bold;font-style: italic;\">italic</div>normal</div>"
        );
    }

    // ghostty: "Page html with colors" (formatter.zig:5226)
    #[test]
    fn page_html_single_line_with_colors() {
        let mut page = page_from_rows(80, &["colored"]);
        set_style_range(
            &mut page,
            0,
            0,
            7,
            Style {
                fg_color: StyleColor::Palette(1),
                bg_color: StyleColor::Palette(4),
                ..Style::default()
            },
        );
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\"><div style=\"display: inline;color: var(--vt-palette-1);background-color: var(--vt-palette-4);\">colored</div></div>"
        );
    }

    // ghostty: "Page html with background and foreground colors" (formatter.zig:5297)
    #[test]
    fn page_html_with_background_and_foreground_colors() {
        let page = page_from_rows(80, &["hello"]);
        let result = format_page_with(&page, |formatter| {
            formatter.opts.emit = Format::Html;
            formatter.opts.background = Some(Rgb {
                r: 0x12,
                g: 0x34,
                b: 0x56,
            });
            formatter.opts.foreground = Some(Rgb {
                r: 0xab,
                g: 0xcd,
                b: 0xef,
            });
        });
        assert_eq!(
            result.text,
            "<div style=\"font-family: monospace; white-space: pre;background-color: #123456;color: #abcdef;\">hello</div>"
        );
    }

    // ghostty: "Page html with palette option emits RGB" (formatter.zig:5544)
    #[test]
    fn page_html_with_palette_option_emits_rgb() {
        let mut page = page_from_rows(80, &["red"]);
        set_style_range(
            &mut page,
            0,
            0,
            3,
            Style {
                fg_color: StyleColor::Palette(1),
                ..Style::default()
            },
        );
        let mut palette = DEFAULT_PALETTE;
        palette[1] = Rgb {
            r: 0xab,
            g: 0xcd,
            b: 0xef,
        };
        let result = format_page_with(&page, |formatter| {
            formatter.opts.emit = Format::Html;
            formatter.opts.palette = Some(palette);
        });
        assert_eq!(
            result.text,
            "<div style=\"font-family: monospace; white-space: pre;\"><div style=\"display: inline;color: rgb(171, 205, 239);\">red</div></div>"
        );
    }

    // ghostty: "Page HTML with hyperlinks" (formatter.zig:6062)
    #[test]
    fn page_html_with_hyperlinks() {
        let mut page = page_from_rows(80, &["link text normal"]);
        set_hyperlink_range(&mut page, 0, 0, 9, b"https://example.com");
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\"><a href=\"https://example.com\">link text</a> normal</div>"
        );
    }

    // ghostty: "Page HTML with multiple hyperlinks" (formatter.zig:6096)
    #[test]
    fn page_html_with_multiple_hyperlinks() {
        let mut page = page_from_rows(80, &["first second"]);
        set_hyperlink_range(&mut page, 0, 0, 5, b"https://first.com");
        set_hyperlink_range(&mut page, 0, 6, 12, b"https://second.com");
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\"><a href=\"https://first.com\">first</a> <a href=\"https://second.com\">second</a></div>"
        );
    }

    // ghostty: "Page HTML with hyperlink escaping" (formatter.zig:6133)
    #[test]
    fn page_html_with_hyperlink_escaping() {
        let mut page = page_from_rows(80, &["link"]);
        set_hyperlink_range(&mut page, 0, 0, 4, b"https://example.com?a=1&b=2");
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\"><a href=\"https://example.com?a=1&amp;b=2\">link</a></div>"
        );
    }

    // ghostty: "Page HTML with styled hyperlink" (formatter.zig:6167)
    #[test]
    fn page_html_hyperlink_with_style_keeps_ghostty_misnesting() {
        let mut page = page_from_rows(80, &["bold link"]);
        set_style_range(
            &mut page,
            0,
            0,
            9,
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        let link = page
            .insert_hyperlink_implicit(1, b"https://example.com")
            .unwrap();
        for x in 0..9 {
            page.set_hyperlink_id(0, x, link).unwrap();
        }
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\"><div style=\"display: inline;font-weight: bold;\"><a href=\"https://example.com\">bold link</div></a></div>"
        );
    }

    // ghostty: "Page HTML hyperlink closes style before anchor" (formatter.zig:6202)
    #[test]
    fn page_html_hyperlink_closes_style_before_anchor() {
        let mut page = page_from_rows(80, &["bold plain"]);
        set_style_range(
            &mut page,
            0,
            0,
            4,
            Style {
                flags: StyleFlags {
                    bold: true,
                    ..StyleFlags::default()
                },
                ..Style::default()
            },
        );
        set_hyperlink_range(&mut page, 0, 0, 10, b"https://example.com");
        assert_eq!(
            format_page_html(&page),
            "<div style=\"font-family: monospace; white-space: pre;\"><div style=\"display: inline;font-weight: bold;\"><a href=\"https://example.com\">bold</div> plain</a></div>"
        );
    }

    // ghostty: "Page HTML hyperlink point map maps closing to previous cell" (formatter.zig:6237)
    #[test]
    fn page_html_hyperlink_point_map_maps_closing_to_previous_cell() {
        let mut page = page_from_rows(80, &["link text"]);
        set_hyperlink_range(&mut page, 0, 0, 9, b"https://example.com");
        let result = format_page_with(&page, |formatter| formatter.opts.emit = Format::Html);
        let closing = result.text.find("</a>").unwrap();
        for coordinate in &result.point_map[closing..closing + 4] {
            assert_eq!(*coordinate, Coordinate { x: 8, y: 0 });
        }
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

    // ghostty: "PageList VT spanning two pages" (formatter.zig:3808)
    #[test]
    fn page_list_vt_spanning_two_pages() {
        let mut terminal = terminal(10, 3);
        for _ in 0..terminal.first_page_capacity_rows() {
            terminal.print_string("          \n");
        }
        terminal.print_string("page one\npage two");
        let mut formatter = PageListFormatter::new(&terminal.active_screen().pages);
        formatter.opts.emit = Format::Vt;
        let result = formatter.format();

        assert!(result.text.ends_with("page one\r\npage two"));
        assert_eq!(result.pin_map.len(), result.text.len());
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

    // ghostty: "TerminalFormatter vt with palette" (formatter.zig:4230)
    #[test]
    fn terminal_formatter_vt_with_palette() {
        let terminal = terminal_from_vt(80, 24, b"\x1b]4;0;rgb:12/34/56\x1b\\test");
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.opts.emit = Format::Vt;
        formatter.extra.palette = true;

        let output = formatter.format();
        assert!(output.text.starts_with("\x1b]4;0;rgb:12/34/56\x1b\\"));

        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert_eq!(
            roundtripped.colors.palette.current[0],
            Rgb {
                r: 0x12,
                g: 0x34,
                b: 0x56
            }
        );
        assert_eq!(roundtripped.plain_string(), "test");
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

    // ghostty: "TerminalFormatter vt with palette and pin_map" (formatter.zig:4389)
    #[test]
    fn terminal_formatter_vt_with_palette_and_pin_map() {
        let terminal = terminal_from_vt(80, 24, b"\x1b]4;1;rgb:aa/bb/cc\x1b\\test");
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.opts.emit = Format::Vt;
        formatter.extra.palette = true;

        let output = formatter.format();
        assert_eq!(output.text.len(), output.pin_map.len());
        let top_left = terminal.active_screen().pages.get_top_left(Tag::Screen);
        assert_eq!(output.pin_map[0].node, top_left.node);
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

    // ghostty: "Screen vt with cursor position" (formatter.zig:4599)
    #[test]
    fn screen_vt_with_cursor_position() {
        let terminal = terminal_from_vt(80, 24, b"hello\r\nworld");
        let mut formatter = ScreenFormatter::new(terminal.active_screen());
        formatter.opts.emit = Format::Vt;
        formatter.extra.cursor = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert_eq!(
            terminal.active_screen().cursor.x,
            roundtripped.active_screen().cursor.x
        );
        assert_eq!(
            terminal.active_screen().cursor.y,
            roundtripped.active_screen().cursor.y
        );
        assert_eq!(output.text.len(), output.pin_map.len());
    }

    // ghostty: "Screen vt with style" (formatter.zig:4658)
    #[test]
    fn screen_vt_with_style() {
        let terminal = terminal_from_vt(80, 24, b"\x1b[1;31mhello");
        let mut formatter = ScreenFormatter::new(terminal.active_screen());
        formatter.opts.emit = Format::Vt;
        formatter.extra.style = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert_eq!(
            terminal.active_screen().cursor.style,
            roundtripped.active_screen().cursor.style
        );
    }

    // ghostty: "Screen vt with hyperlink" (formatter.zig:4710)
    #[test]
    fn screen_vt_with_hyperlink() {
        let terminal = terminal_from_vt(80, 24, b"\x1b]8;;http://example.com\x1b\\hello");
        let mut formatter = ScreenFormatter::new(terminal.active_screen());
        formatter.opts.emit = Format::Vt;
        formatter.extra.hyperlink = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        let expected = terminal.active_screen().cursor.hyperlink.as_ref();
        let actual = roundtripped.active_screen().cursor.hyperlink.as_ref();
        assert_eq!(
            expected.map(|link| link.uri.as_slice()),
            actual.map(|link| link.uri.as_slice())
        );
    }

    // ghostty: "Screen vt with protection" (formatter.zig:4770)
    #[test]
    fn screen_vt_with_protection() {
        let terminal = terminal_from_vt(80, 24, b"\x1b[1\"qhello");
        let mut formatter = ScreenFormatter::new(terminal.active_screen());
        formatter.opts.emit = Format::Vt;
        formatter.extra.protection = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert_eq!(
            terminal.active_screen().cursor.protected,
            roundtripped.active_screen().cursor.protected
        );
    }

    // ghostty: "Screen vt with charsets" (formatter.zig:4876)
    #[test]
    fn screen_vt_with_charsets() {
        let terminal = terminal_from_vt(80, 24, b"\x1b(0\x0ehello");
        let mut formatter = ScreenFormatter::new(terminal.active_screen());
        formatter.opts.emit = Format::Vt;
        formatter.extra.charsets = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert_eq!(
            terminal.active_screen().charset.gl,
            roundtripped.active_screen().charset.gl
        );
        assert_eq!(
            terminal.active_screen().charset.g0,
            roundtripped.active_screen().charset.g0
        );
    }

    // ghostty: "Terminal vt with scrolling region" (formatter.zig:4933)
    #[test]
    fn terminal_vt_with_scrolling_region() {
        let terminal = terminal_from_vt(80, 24, b"\x1b[6;21rhello");
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.opts.emit = Format::Vt;
        formatter.extra.scrolling_region = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert_eq!(
            terminal.scrolling_region.top,
            roundtripped.scrolling_region.top
        );
        assert_eq!(
            terminal.scrolling_region.bottom,
            roundtripped.scrolling_region.bottom
        );
    }

    // ghostty: "Terminal vt with modes" (formatter.zig:4977)
    #[test]
    fn terminal_vt_with_modes() {
        let terminal = terminal_from_vt(80, 24, b"\x1b[?2004h\x1b[?1000h\x1b[?7lhello");
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.opts.emit = Format::Vt;
        formatter.extra.modes = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert_eq!(
            terminal.modes.get(Mode::BracketedPaste),
            roundtripped.modes.get(Mode::BracketedPaste)
        );
        assert_eq!(
            terminal.modes.get(Mode::MouseEventNormal),
            roundtripped.modes.get(Mode::MouseEventNormal)
        );
        assert_eq!(
            terminal.modes.get(Mode::Wraparound),
            roundtripped.modes.get(Mode::Wraparound)
        );
    }

    // ghostty: "Terminal vt with tabstops" (formatter.zig:5023)
    #[test]
    fn terminal_vt_with_tabstops() {
        let terminal = terminal_from_vt(
            80,
            24,
            b"\x1b[3g\x1b[5G\x1bH\x1b[15G\x1bH\x1b[30G\x1bHhello",
        );
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.opts.emit = Format::Vt;
        formatter.extra.tabstops = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert!(roundtripped.tabstops.get(4));
        assert!(roundtripped.tabstops.get(14));
        assert!(roundtripped.tabstops.get(29));
        assert_eq!(terminal.tabstops.get(8), roundtripped.tabstops.get(8));
    }

    // ghostty: "Terminal vt with keyboard modes" (formatter.zig:5074)
    #[test]
    fn terminal_vt_with_keyboard_modes() {
        let mut terminal = terminal_with_text(80, 24, "hello");
        terminal.flags.modify_other_keys_2 = true;
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.opts.emit = Format::Vt;
        formatter.extra.keyboard = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert!(roundtripped.flags.modify_other_keys_2);
    }

    // port-added: formatter emits CSI > 4;0 m through the same keyboard path.
    #[test]
    fn terminal_vt_with_keyboard_modes_can_disable_modify_other_keys() {
        let roundtripped = roundtrip_terminal(80, 24, "\x1b[>4;2m\x1b[>4;0mhello");
        assert!(!roundtripped.flags.modify_other_keys_2);
    }

    // ghostty: "Terminal vt with pwd" (formatter.zig:5117)
    #[test]
    fn terminal_vt_with_pwd() {
        let terminal = terminal_from_vt(80, 24, b"\x1b]7;file://host/home/user\x1b\\hello");
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.opts.emit = Format::Vt;
        formatter.extra.pwd = true;

        let output = formatter.format();
        let roundtripped = roundtrip_terminal(80, 24, &output.text);
        assert_eq!(terminal.pwd(), roundtripped.pwd());
    }

    // ghostty: "TerminalFormatter html with palette" (formatter.zig:5260)
    #[test]
    fn terminal_formatter_html_with_palette() {
        let terminal = terminal_with_text(80, 24, "hello");
        let mut formatter = TerminalFormatter::new(&terminal);
        formatter.opts.emit = Format::Html;
        formatter.extra.palette = true;

        let output = formatter.format();
        assert!(output.text.starts_with("<style>:root{"));
        assert!(output.text.contains("--vt-palette-0: "));
        assert!(output
            .text
            .contains("}</style><div style=\"font-family: monospace; white-space: pre;"));
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

    // port-added: the styled codepoint-map contract also covers this short input.
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

    // T-omitted (kitty unsupported): "Screen vt with kitty keyboard" (formatter.zig:4822)
}
