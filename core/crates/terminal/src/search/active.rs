//! Forward search over the mutable active terminal area.

use crate::highlight::Flattened;
use crate::page_list::{NodeId, PageList};

use super::{AppendError, Direction, SlidingWindow};

// ghostty: terminal/search/active.zig:11
/// Rebuildable search state for the mutable active area of a page list.
pub struct ActiveSearch {
    window: SlidingWindow,
}

impl ActiveSearch {
    // ghostty: terminal/search/active.zig:23
    pub fn new(needle: &[u8]) -> Self {
        Self {
            window: SlidingWindow::new(Direction::Forward, needle),
        }
    }

    // ghostty: terminal/search/active.zig:52
    /// Rebuilds the search window and returns the earliest active-area node.
    ///
    /// A history search can start at the returned node. It may duplicate
    /// active results, so the screen-level coordinator must prune overlap.
    pub fn update(&mut self, pages: &PageList) -> Result<Option<NodeId>, AppendError> {
        self.window.clear_and_retain_capacity();

        let mut remaining = usize::from(pages.rows);
        let mut node = pages.last_node();
        let mut earliest_active = None;
        while let Some(node_id) = node {
            self.window.append(pages, node_id)?;
            earliest_active = Some(node_id);
            let current = pages.node(node_id).ok_or(AppendError::InvalidNode)?;
            let rows = usize::from(current.page.size().rows);
            node = current.prev;
            if remaining <= rows {
                break;
            }
            remaining -= rows;
        }

        let overlap_target = self.window.needle_len().saturating_sub(1);
        while let Some(node_id) = node {
            let current = pages.node(node_id).ok_or(AppendError::InvalidNode)?;
            let rows = current.page.size().rows;
            if rows == 0 || !current.page.row(rows - 1).wrap() {
                break;
            }
            node = current.prev;
            let added = self.window.append(pages, node_id)?;
            if added >= overlap_target {
                break;
            }
        }

        Ok(earliest_active)
    }

    // ghostty: terminal/search/active.zig:99
    pub fn next(&mut self, pages: &PageList) -> Option<Flattened> {
        self.window.next(pages)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page_list::Pin;
    use crate::point::Point;
    use crate::stream::Stream;
    use crate::terminal::{Options as TerminalOptions, Terminal};

    #[test]
    // ghostty: "simple search" (active.zig:104)
    fn simple_search() {
        let mut stream = terminal_stream();
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");
        let pages = &stream.handler.active_screen().pages;
        let mut search = ActiveSearch::new(b"Fizz");
        assert!(search.update(pages).unwrap().is_some());
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
    // ghostty: "clear screen and search" (active.zig:144)
    fn clear_screen_and_search() {
        let mut stream = terminal_stream();
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");
        let mut search = ActiveSearch::new(b"Fizz");
        assert!(search
            .update(&stream.handler.active_screen().pages)
            .unwrap()
            .is_some());

        stream.next_slice(b"\x1b[2J\x1b[HBuzz\r\nFizz\r\nBuzz");
        let pages = &stream.handler.active_screen().pages;
        assert!(search.update(pages).unwrap().is_some());
        assert_match(
            search.next(pages).unwrap(),
            pages,
            Point::active(0, 1),
            Point::active(3, 1),
        );
        assert!(search.next(pages).is_none());
    }

    fn terminal_stream() -> Stream<Terminal> {
        Stream::new(Terminal::new(TerminalOptions {
            cols: 10,
            rows: 10,
            max_scrollback: usize::MAX,
            ..TerminalOptions::default()
        }))
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
