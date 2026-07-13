//! Forward search limited to the visible terminal viewport.

use crate::highlight::Flattened;
use crate::page_list::{Direction as PageDirection, NodeId, PageList};
use crate::point::{Point, Tag};

use super::{AppendError, Direction, SlidingWindow};

// ghostty: terminal/search/viewport.zig:12
/// Searches the pages covered by the viewport and skips unchanged searches.
///
/// Whole pages are searched, so matches outside the viewport may be returned
/// when they share a page with visible rows.
pub struct ViewportSearch {
    window: SlidingWindow,
    fingerprint: Option<Fingerprint>,
    // Rust deviation: SlidingWindow intentionally exposes only needle length
    // to sibling layers, so this forward-only search retains the original
    // bytes for its public needle accessor.
    needle: Vec<u8>,
    /// `None` disables dirty tracking. `Some` is caller-maintained state.
    pub active_dirty: Option<bool>,
}

impl ViewportSearch {
    // ghostty: terminal/search/viewport.zig:35
    pub fn new(needle: &[u8]) -> Self {
        Self {
            window: SlidingWindow::new(Direction::Forward, needle),
            fingerprint: None,
            needle: needle.to_vec(),
            active_dirty: None,
        }
    }

    // ghostty: terminal/search/viewport.zig:58
    pub fn reset(&mut self) {
        self.fingerprint = None;
        self.window.clear_and_retain_capacity();
    }

    // ghostty: terminal/search/viewport.zig:65
    pub fn needle(&self) -> &[u8] {
        &self.needle
    }

    // ghostty: terminal/search/viewport.zig:79
    /// Rebuilds the window when the viewport or mutable active overlap changed.
    pub fn update(&mut self, pages: &PageList) -> Result<bool, AppendError> {
        let fingerprint = Fingerprint::new(pages).ok_or(AppendError::InvalidNode)?;
        if self.fingerprint.as_ref() == Some(&fingerprint) {
            let check_active = match self.active_dirty {
                None => true,
                Some(false) => false,
                Some(true) => {
                    self.active_dirty = Some(false);
                    true
                }
            };

            let overlaps_active = if check_active {
                let active_top = pages.get_top_left(Tag::Active).node;
                let active_bottom = pages
                    .get_bottom_right(Tag::Active)
                    .ok_or(AppendError::InvalidNode)?
                    .node;
                fingerprint
                    .nodes
                    .iter()
                    .any(|node| *node == active_top || *node == active_bottom)
            } else {
                false
            };
            if !overlaps_active {
                return Ok(false);
            }
        }

        self.fingerprint = Some(fingerprint);
        if self.active_dirty.is_some() {
            self.active_dirty = Some(false);
        }
        self.window.clear_and_retain_capacity();

        let nodes = self
            .fingerprint
            .as_ref()
            .map(|fingerprint| fingerprint.nodes.as_slice())
            .ok_or(AppendError::InvalidNode)?;
        let first = *nodes.first().ok_or(AppendError::InvalidNode)?;
        let overlap_target = self.window.needle_len().saturating_sub(1);

        let mut node = pages.node(first).and_then(|page| page.prev);
        let mut added = 0usize;
        while let Some(node_id) = node {
            let current = pages.node(node_id).ok_or(AppendError::InvalidNode)?;
            let rows = current.page.size().rows;
            if rows == 0 || !current.page.row(rows - 1).wrap() {
                break;
            }
            node = current.prev;
            added = added.saturating_add(self.window.append(pages, node_id)?);
            if added >= overlap_target {
                break;
            }
        }

        for node_id in nodes {
            self.window.append(pages, *node_id)?;
        }

        let end = *nodes.last().ok_or(AppendError::InvalidNode)?;
        let end_page = pages.node(end).ok_or(AppendError::InvalidNode)?;
        let end_rows = end_page.page.size().rows;
        if end_rows > 0 && end_page.page.row(end_rows - 1).wrap() {
            node = end_page.next;
            added = 0;
            while let Some(node_id) = node {
                let current = pages.node(node_id).ok_or(AppendError::InvalidNode)?;
                node = current.next;
                added = added.saturating_add(self.window.append(pages, node_id)?);
                if added >= overlap_target {
                    break;
                }
                let rows = current.page.size().rows;
                if rows == 0 || !current.page.row(rows - 1).wrap() {
                    break;
                }
            }
        }

        Ok(true)
    }

    // ghostty: terminal/search/viewport.zig:179
    pub fn next(&mut self, pages: &PageList) -> Option<Flattened> {
        self.window.next(pages)
    }
}

// ghostty: terminal/search/viewport.zig:183
#[derive(Debug, Clone, PartialEq, Eq)]
struct Fingerprint {
    // Rust deviation: full generational NodeIds replace pointer identities,
    // so an arena slot reused after pruning cannot compare equal by accident.
    nodes: Vec<NodeId>,
}

impl Fingerprint {
    // ghostty: terminal/search/viewport.zig:191
    fn new(pages: &PageList) -> Option<Self> {
        let bottom = u32::from(pages.rows.checked_sub(1)?);
        let mut iterator = pages.page_iterator(
            PageDirection::RightDown,
            Point::viewport(0, 0),
            Some(Point::viewport(0, bottom)),
        );
        let mut nodes = Vec::new();
        while let Some(chunk) = iterator.next(pages) {
            nodes.push(chunk.node);
        }
        if nodes.is_empty() {
            return None;
        }
        Some(Self { nodes })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page_list::{Pin, Scroll};
    use crate::stream::Stream;
    use crate::terminal::{Options as TerminalOptions, Terminal};

    #[test]
    // ghostty: "simple search" (viewport.zig:219)
    fn simple_search() {
        let mut stream = terminal_stream(10, 10);
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");
        let pages = &stream.handler.active_screen().pages;
        let mut search = ViewportSearch::new(b"Fizz");
        assert!(search.update(pages).unwrap());
        assert!(search.update(pages).unwrap());
        assert_match(
            search.next(pages).unwrap(),
            pages,
            Point::active(0, 0),
            Point::active(3, 0),
        );
        assert_match(
            search.next(pages).unwrap(),
            pages,
            Point::active(0, 2),
            Point::active(3, 2),
        );
        assert!(search.next(pages).is_none());
    }

    #[test]
    // ghostty: "clear screen and search" (viewport.zig:262)
    fn clear_screen_and_search() {
        let mut stream = terminal_stream(10, 10);
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");
        let mut search = ViewportSearch::new(b"Fizz");
        assert!(search
            .update(&stream.handler.active_screen().pages)
            .unwrap());
        stream.next_slice(b"\x1b[2J\x1b[HBuzz\r\nFizz\r\nBuzz");
        let pages = &stream.handler.active_screen().pages;
        assert!(search.update(pages).unwrap());
        assert_match(
            search.next(pages).unwrap(),
            pages,
            Point::active(0, 1),
            Point::active(3, 1),
        );
        assert!(search.next(pages).is_none());
    }

    #[test]
    // ghostty: "clear screen and search dirty tracking" (viewport.zig:295)
    fn dirty_tracking_controls_active_area_research() {
        let mut stream = terminal_stream(10, 10);
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");
        let mut search = ViewportSearch::new(b"Fizz");
        search.active_dirty = Some(false);
        assert!(search
            .update(&stream.handler.active_screen().pages)
            .unwrap());
        assert!(!search
            .update(&stream.handler.active_screen().pages)
            .unwrap());

        stream.next_slice(b"\x1b[2J\x1b[HBuzz\r\nFizz\r\nBuzz");
        assert!(!search
            .update(&stream.handler.active_screen().pages)
            .unwrap());
        search.active_dirty = Some(true);
        let pages = &stream.handler.active_screen().pages;
        assert!(search.update(pages).unwrap());
        assert_eq!(search.active_dirty, Some(false));
        assert_match(
            search.next(pages).unwrap(),
            pages,
            Point::active(0, 1),
            Point::active(3, 1),
        );
        assert!(search.next(pages).is_none());
    }

    #[test]
    // ghostty: "history search, no active area" (viewport.zig:342)
    fn history_viewport_without_active_area_skips_redundant_search() {
        let mut stream = terminal_stream(10, 2);
        let first_rows = first_page_capacity_rows(&stream.handler);
        stream.next_slice(b"Fizz\r\n");
        for _ in 1..first_rows - 1 {
            stream.next_slice(b"\r\n");
        }
        assert_eq!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );
        stream.next_slice(b"\r\nBuzz\r\nFizz");
        assert_ne!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );
        stream.handler.scroll_viewport(Scroll::Top);

        let pages = &stream.handler.active_screen().pages;
        let mut search = ViewportSearch::new(b"Fizz");
        assert!(search.update(pages).unwrap());
        assert_match(
            search.next(pages).unwrap(),
            pages,
            Point::screen(0, 0),
            Point::screen(3, 0),
        );
        assert!(search.next(pages).is_none());
        assert!(!search.update(pages).unwrap());
        assert!(search.next(pages).is_none());
    }

    fn terminal_stream(cols: u16, rows: u16) -> Stream<Terminal> {
        Stream::new(Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback: usize::MAX,
            ..TerminalOptions::default()
        }))
    }

    fn first_page_capacity_rows(terminal: &Terminal) -> usize {
        let pages = &terminal.active_screen().pages;
        let first = pages.first_node().unwrap();
        usize::from(pages.node_capacity(first).unwrap().rows)
    }

    fn assert_match(flattened: Flattened, pages: &PageList, start: Point, end: Point) {
        let first = flattened.chunks.first().unwrap();
        let last = flattened.chunks.last().unwrap();
        let actual_start = Pin {
            node: first.node,
            x: flattened.top_x,
            y: first.start,
            garbage: false,
        };
        let actual_end = Pin {
            node: last.node,
            x: flattened.bot_x,
            y: last.end - 1,
            garbage: false,
        };
        assert_eq!(pages.point_from_pin(start.tag(), actual_start), Some(start));
        assert_eq!(pages.point_from_pin(end.tag(), actual_end), Some(end));
    }
}
