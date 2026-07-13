//! Reverse search through immutable page-list history.

use crate::highlight::Flattened;
use crate::page_list::{NodeId, PageList, Pin, PinId};

use super::{Direction, SlidingWindow};

// ghostty: terminal/search/pagelist.zig:15
/// Searches backward through a page list starting at a specific node.
///
/// The search owns a tracked pin that survives page movement. Call
/// [`Self::deinit`] before discarding this value so the pin is untracked.
pub struct PageListSearch {
    window: SlidingWindow,
    pin: PinId,
}

impl PageListSearch {
    // ghostty: terminal/search/pagelist.zig:47
    /// Creates a reverse search and tracks its current page-list position.
    pub fn new(pages: &mut PageList, needle: &[u8], start: NodeId) -> Option<Self> {
        let size = pages.node_page_size(start)?;
        let pin = pages.track_pin(Pin {
            node: start,
            x: size.cols.checked_sub(1)?,
            y: size.rows.checked_sub(1)?,
            garbage: false,
        });
        let mut window = SlidingWindow::new(Direction::Reverse, needle);
        if window.append(pages, start).is_err() {
            let _ = pages.untrack_pin(pin);
            return None;
        }
        Some(Self { window, pin })
    }

    // ghostty: terminal/search/pagelist.zig:82
    /// Untracks the progress pin. This search must not be used afterwards.
    pub fn deinit(&mut self, pages: &mut PageList) {
        let _ = pages.untrack_pin(self.pin);
    }

    // ghostty: terminal/search/pagelist.zig:98
    /// Returns the next match from the pages already loaded into the window.
    pub fn next(&mut self, pages: &PageList) -> Option<Flattened> {
        self.window.next(pages)
    }

    // ghostty: terminal/search/pagelist.zig:111
    /// Loads older pages until at least one needle's worth of bytes was added.
    pub fn feed(&mut self, pages: &mut PageList) -> bool {
        let Some(mut pin) = pages.tracked_pin(self.pin) else {
            return false;
        };
        if pin.garbage {
            return false;
        }

        let needle_len = self.window.needle_len();
        let mut remaining = needle_len;
        let mut next = pages.node(pin.node).and_then(|node| node.prev);
        while let Some(node_id) = next {
            next = pages.node(node_id).and_then(|node| node.prev);
            let Ok(added) = self.window.append(pages, node_id) else {
                // Rust deviation: Ghostty propagates allocation failure. The
                // Rust window only fails for a stale node, which exhausts this
                // search rather than exposing an allocation-shaped error.
                return false;
            };
            remaining = remaining.saturating_sub(added);
            pin.node = node_id;
            if !pages.set_tracked_pin(self.pin, pin) {
                return false;
            }
            if remaining == 0 {
                break;
            }
        }

        remaining < needle_len
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page_list::PageList;
    use crate::point::Point;
    use crate::screen::SelectionStringOptions;
    use crate::selection::Selection;
    use crate::stream::Stream;
    use crate::terminal::{Options as TerminalOptions, Terminal};

    #[test]
    // ghostty: "simple search" (pagelist.zig:137)
    fn simple_search() {
        let mut stream = terminal_stream(10, 10);
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");
        let start = stream.handler.active_screen().pages.last_node().unwrap();
        let mut search = PageListSearch::new(
            &mut stream.handler.active_screen_mut().pages,
            b"Fizz",
            start,
        )
        .unwrap();

        assert_match(
            search.next(&stream.handler.active_screen().pages).unwrap(),
            &stream.handler.active_screen().pages,
            Point::active(0, 2),
            Point::active(3, 2),
        );
        assert_match(
            search.next(&stream.handler.active_screen().pages).unwrap(),
            &stream.handler.active_screen().pages,
            Point::active(0, 0),
            Point::active(3, 0),
        );
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(!search.feed(&mut stream.handler.active_screen_mut().pages));
        search.deinit(&mut stream.handler.active_screen_mut().pages);
    }

    #[test]
    // ghostty: "feed multiple pages with matches" (pagelist.zig:184)
    fn feed_multiple_pages_with_matches() {
        let mut stream = terminal_stream(10, 10);
        let rows = first_page_capacity_rows(&stream.handler);
        for _ in 0..rows - 1 {
            stream.next_slice(b"\r\n");
        }
        stream.next_slice(b"Fizz");
        assert_eq!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );
        stream.next_slice(b"\r\n");
        assert_ne!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );
        stream.next_slice(b"Buzz\r\nFizz");

        let mut search = page_list_search(&mut stream, b"Fizz");
        assert!(search.next(&stream.handler.active_screen().pages).is_some());
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(search.feed(&mut stream.handler.active_screen_mut().pages));
        assert!(search.next(&stream.handler.active_screen().pages).is_some());
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(!search.feed(&mut stream.handler.active_screen_mut().pages));
        search.deinit(&mut stream.handler.active_screen_mut().pages);
    }

    #[test]
    // ghostty: "feed multiple pages no matches" (pagelist.zig:228)
    fn feed_multiple_pages_without_matches() {
        let mut stream = terminal_stream(10, 10);
        let rows = first_page_capacity_rows(&stream.handler);
        for _ in 0..rows - 1 {
            stream.next_slice(b"\r\n");
        }
        stream.next_slice(b"Hello\r\nWorld");
        assert_ne!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );

        let mut search = page_list_search(&mut stream, b"Nope");
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(search.feed(&mut stream.handler.active_screen_mut().pages));
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(!search.feed(&mut stream.handler.active_screen_mut().pages));
        search.deinit(&mut stream.handler.active_screen_mut().pages);
    }

    #[test]
    // ghostty: "feed iteratively through multiple matches" (pagelist.zig:267)
    fn feed_iteratively_through_multiple_matches() {
        let mut stream = terminal_stream(80, 24);
        let rows = first_page_capacity_rows(&stream.handler);
        for _ in 0..rows - 1 {
            stream.next_slice(b"\r\n");
        }
        stream.next_slice(b"Page1Test\r\nPage2Test");
        assert_ne!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );

        let mut search = page_list_search(&mut stream, b"Test");
        assert!(search.next(&stream.handler.active_screen().pages).is_some());
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(search.feed(&mut stream.handler.active_screen_mut().pages));
        assert!(search.next(&stream.handler.active_screen().pages).is_some());
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(!search.feed(&mut stream.handler.active_screen_mut().pages));
        search.deinit(&mut stream.handler.active_screen_mut().pages);
    }

    #[test]
    // ghostty: "feed with match spanning page boundary" (pagelist.zig:308)
    fn feed_finds_match_spanning_page_boundary() {
        let mut stream = terminal_stream(80, 24);
        fill_first_page_to_last_two_columns(&mut stream);
        stream.next_slice(b"Te");
        assert_eq!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );
        stream.next_slice(b"st");
        assert_ne!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );

        let mut search = page_list_search(&mut stream, b"Test");
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(search.feed(&mut stream.handler.active_screen_mut().pages));
        let flattened = search.next(&stream.handler.active_screen().pages).unwrap();
        let (start, end) = flattened_pins(&flattened);
        assert_ne!(start.node, end.node);
        assert_eq!(
            stream
                .handler
                .active_screen()
                .selection_string(SelectionStringOptions {
                    selection: Selection::new(start, end, false),
                    trim: false,
                }),
            "Test"
        );
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(!search.feed(&mut stream.handler.active_screen_mut().pages));
        search.deinit(&mut stream.handler.active_screen_mut().pages);
    }

    #[test]
    // ghostty: "feed with match spanning page boundary with newline" (pagelist.zig:362)
    fn newline_prevents_match_spanning_page_boundary() {
        let mut stream = terminal_stream(80, 24);
        fill_first_page_to_last_two_columns(&mut stream);
        stream.next_slice(b"Te\r\nst");
        assert_ne!(
            stream.handler.active_screen().pages.first_node(),
            stream.handler.active_screen().pages.last_node()
        );

        let mut search = page_list_search(&mut stream, b"Test");
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(search.feed(&mut stream.handler.active_screen_mut().pages));
        assert!(search.next(&stream.handler.active_screen().pages).is_none());
        assert!(!search.feed(&mut stream.handler.active_screen_mut().pages));
        search.deinit(&mut stream.handler.active_screen_mut().pages);
    }

    #[test]
    // ghostty: "feed with pruned page" (pagelist.zig:398)
    fn feed_stops_after_progress_page_is_pruned() {
        let mut pages = PageList::new(80, 24, Some(0));
        let first = pages.last_node().unwrap();
        let first_capacity = pages.node_capacity(first).unwrap().rows;
        let first_size = pages.node_page_size(first).unwrap().rows;
        for _ in first_size..first_capacity {
            assert_eq!(pages.grow(), None);
        }

        let second = pages.grow().unwrap();
        let second_capacity = pages.node_capacity(second).unwrap().rows;
        let second_size = pages.node_page_size(second).unwrap().rows;
        for _ in second_size..second_capacity {
            assert_eq!(pages.grow(), None);
        }

        let start = pages.last_node().unwrap();
        let mut search = PageListSearch::new(&mut pages, b"Test", start).unwrap();
        assert!(search.feed(&mut pages));
        assert!(!search.feed(&mut pages));
        let new = pages.grow().unwrap();
        assert_eq!(pages.last_node(), Some(new));
        assert_eq!(pages.first_node(), Some(second));
        assert_eq!(pages.last_node(), Some(first));
        assert!(!search.feed(&mut pages));
        search.deinit(&mut pages);
    }

    fn terminal_stream(cols: u16, rows: u16) -> Stream<Terminal> {
        Stream::new(Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback: usize::MAX,
            ..TerminalOptions::default()
        }))
    }

    fn page_list_search(stream: &mut Stream<Terminal>, needle: &[u8]) -> PageListSearch {
        let start = stream.handler.active_screen().pages.last_node().unwrap();
        PageListSearch::new(&mut stream.handler.active_screen_mut().pages, needle, start).unwrap()
    }

    fn first_page_capacity_rows(terminal: &Terminal) -> usize {
        let pages = &terminal.active_screen().pages;
        let first = pages.first_node().unwrap();
        usize::from(pages.node_capacity(first).unwrap().rows)
    }

    fn fill_first_page_to_last_two_columns(stream: &mut Stream<Terminal>) {
        let rows = first_page_capacity_rows(&stream.handler);
        for _ in 0..rows - 1 {
            stream.next_slice(b"\r\n");
        }
        for _ in 0..usize::from(stream.handler.active_screen().cols()) - 2 {
            stream.next_slice(b"x");
        }
    }

    fn assert_match(flattened: Flattened, pages: &PageList, start: Point, end: Point) {
        let (actual_start, actual_end) = flattened_pins(&flattened);
        assert_eq!(pages.point_from_pin(start.tag(), actual_start), Some(start));
        assert_eq!(pages.point_from_pin(end.tag(), actual_end), Some(end));
    }

    fn flattened_pins(flattened: &Flattened) -> (Pin, Pin) {
        let first = flattened.chunks.first().unwrap();
        let last = flattened.chunks.last().unwrap();
        (
            Pin {
                node: first.node,
                x: flattened.top_x,
                y: first.start,
                garbage: false,
            },
            Pin {
                node: last.node,
                x: flattened.bot_x,
                y: last.end - 1,
                garbage: false,
            },
        )
    }
}
