//! Page-oriented sliding search window.

use std::fmt;

use crate::circ_buf::{CircBuf, Direction as BufferDirection};
use crate::formatter::{Options as FormatterOptions, PageFormatter};
use crate::highlight::{Flattened, FlattenedChunk};
use crate::page_list::{NodeId, PageList};
use crate::point::Coordinate;
use crate::size::CellCountInt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Forward,
    Reverse,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppendError {
    InvalidNode,
}

impl fmt::Display for AppendError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidNode => formatter.write_str("page node is stale or missing"),
        }
    }
}

#[derive(Debug, Clone)]
struct Meta {
    // ghostty: terminal/search/sliding_window.zig:88
    // Rust deviation: a generational NodeId plus serial replaces Ghostty's
    // stable node pointer. Every dereference validates both values.
    node: NodeId,
    serial: u64,
    cell_map: Vec<Coordinate>,
}

impl Default for Meta {
    fn default() -> Self {
        Self {
            node: NodeId {
                index: 0,
                generation: 0,
            },
            serial: 0,
            cell_map: Vec::new(),
        }
    }
}

// ghostty: terminal/search/sliding_window.zig:17
pub struct SlidingWindow {
    data: CircBuf<u8>,
    meta: CircBuf<Meta>,
    // Rust deviation: Ghostty's MultiArrayList is an SoA scratch buffer. The
    // ported highlight ABI is AoS, so this is a Vec<FlattenedChunk>.
    chunk_buffer: Vec<FlattenedChunk>,
    data_offset: usize,
    needle: Vec<u8>,
    direction: Direction,
    overlap_buffer: Vec<u8>,
}

impl SlidingWindow {
    // ghostty: terminal/search/sliding_window.zig:99
    pub fn new(direction: Direction, needle: &[u8]) -> Self {
        let mut needle = needle.to_vec();
        if direction == Direction::Reverse {
            needle.reverse();
        }
        let overlap_buffer = vec![0; needle.len().saturating_mul(2)];
        Self {
            data: CircBuf::new(0),
            meta: CircBuf::new(0),
            chunk_buffer: Vec::new(),
            data_offset: 0,
            needle,
            direction,
            overlap_buffer,
        }
    }

    // ghostty: terminal/search/sliding_window.zig:142
    pub fn clear_and_retain_capacity(&mut self) {
        let meta_len = self.meta.len();
        if meta_len > 0 {
            self.meta.delete_oldest(meta_len);
        }
        self.meta.clear();
        self.data.clear();
        self.data_offset = 0;
    }

    // ghostty: terminal/search/sliding_window.zig:159
    pub fn next(&mut self, pages: &PageList) -> Option<Flattened> {
        if self.needle.is_empty() || self.data.len() < self.needle.len() {
            return None;
        }

        let found = {
            let data_len = self.data.len();
            let (first, second) = self
                .data
                .get_mut_slices(self.data_offset, data_len - self.data_offset);

            if let Some(index) = index_of_ascii_case_insensitive(first, &self.needle) {
                Some(index)
            } else if !first.is_empty() && !second.is_empty() {
                let prefix_len = first.len().min(self.needle.len().saturating_sub(1));
                let suffix_len = second.len().min(self.needle.len().saturating_sub(1));
                let overlap_len = prefix_len + suffix_len;
                self.overlap_buffer[..prefix_len]
                    .copy_from_slice(&first[first.len() - prefix_len..]);
                self.overlap_buffer[prefix_len..overlap_len].copy_from_slice(&second[..suffix_len]);
                index_of_ascii_case_insensitive(&self.overlap_buffer[..overlap_len], &self.needle)
                    .map(|index| first.len() - prefix_len + index)
                    .or_else(|| {
                        index_of_ascii_case_insensitive(second, &self.needle)
                            .map(|index| first.len() + index)
                    })
            } else {
                index_of_ascii_case_insensitive(second, &self.needle)
                    .map(|index| first.len() + index)
            }
        };

        if let Some(start) = found {
            return self.highlight(pages, start, self.needle.len());
        }

        if self.needle.len() == 1 {
            self.clear_and_retain_capacity();
            self.assert_integrity();
            return None;
        }

        let keep = self.needle.len() - 1;
        let mut reverse = self.meta.iterator(BufferDirection::Reverse);
        let mut saved = 0usize;
        let mut retained_meta_index = None;
        while let Some(meta) = reverse.next() {
            let needed = keep - saved;
            if meta.cell_map.len() >= needed {
                self.data_offset = meta.cell_map.len() - needed;
                retained_meta_index = Some(reverse.index);
                break;
            }
            saved += meta.cell_map.len();
        }

        if let Some(reverse_index) = retained_meta_index {
            let prune_count = self.meta.len() - reverse_index;
            if prune_count > 0 {
                let mut forward = self.meta.iterator(BufferDirection::Forward);
                let mut prune_data_len = 0usize;
                for _ in 0..prune_count {
                    let Some(meta) = forward.next() else {
                        break;
                    };
                    prune_data_len += meta.cell_map.len();
                }
                self.meta.delete_oldest(prune_count);
                self.data.delete_oldest(prune_data_len);
            }
        }

        self.data_offset = self.data.len() - self.needle.len() + 1;
        self.assert_integrity();
        None
    }

    // ghostty: terminal/search/sliding_window.zig:280
    fn highlight(
        &mut self,
        pages: &PageList,
        start_offset: usize,
        len: usize,
    ) -> Option<Flattened> {
        let start = start_offset + self.data_offset;
        let end = start + len - 1;
        debug_assert!(start < self.data.len());
        debug_assert!(start + len <= self.data.len());

        self.chunk_buffer.clear();
        let mut top_x = 0;
        let mut bottom_x = 0;
        let mut start_meta_index = None;
        let mut start_meta_consumed = 0usize;
        let mut end_in_start_meta = false;

        let mut iterator = self.meta.iterator(BufferDirection::Forward);
        let mut consumed = 0usize;
        while let Some(meta) = iterator.next() {
            let prior_consumed = consumed;
            consumed += meta.cell_map.len();
            let meta_index = start.saturating_sub(prior_consumed);
            if start < prior_consumed || meta_index >= meta.cell_map.len() {
                continue;
            }

            let rows = valid_node_rows(pages, meta)?;
            let end_index = end.saturating_sub(prior_consumed);
            let start_map = meta.cell_map[meta_index];
            top_x = start_map.x;
            if end < prior_consumed + meta.cell_map.len() {
                let end_map = meta.cell_map[end_index];
                bottom_x = end_map.x;
                self.chunk_buffer.push(FlattenedChunk {
                    node: meta.node,
                    start: coordinate_y(start_map)?,
                    end: coordinate_y(end_map)?.saturating_add(1),
                });
                end_in_start_meta = true;
            } else {
                self.chunk_buffer.push(FlattenedChunk {
                    node: meta.node,
                    start: coordinate_y(start_map)?,
                    end: rows,
                });
            }
            start_meta_index = Some(iterator.index - 1);
            start_meta_consumed = prior_consumed;
            break;
        }

        let start_meta_index = start_meta_index?;
        if !end_in_start_meta {
            let mut end_iterator = self.meta.iterator(BufferDirection::Forward);
            end_iterator.seek_by((start_meta_index + 1) as isize);
            let mut end_consumed = start_meta_consumed
                + self
                    .meta_at(start_meta_index)
                    .map(|meta| meta.cell_map.len())?;
            while let Some(meta) = end_iterator.next() {
                let rows = valid_node_rows(pages, meta)?;
                let meta_index = end.saturating_sub(end_consumed);
                if end >= end_consumed + meta.cell_map.len() {
                    self.chunk_buffer.push(FlattenedChunk {
                        node: meta.node,
                        start: 0,
                        end: rows,
                    });
                    end_consumed += meta.cell_map.len();
                    continue;
                }

                let map = meta.cell_map[meta_index];
                bottom_x = map.x;
                self.chunk_buffer.push(FlattenedChunk {
                    node: meta.node,
                    start: 0,
                    end: coordinate_y(map)?.saturating_add(1),
                });
                break;
            }
        }

        let prune_meta = start_meta_index;
        self.data_offset = start - start_meta_consumed + 1;
        if prune_meta > 0 {
            self.meta.delete_oldest(prune_meta);
            self.data.delete_oldest(start_meta_consumed);
        }

        if self.direction == Direction::Reverse {
            self.chunk_buffer.reverse();
            if self.chunk_buffer.len() > 1 {
                let first = self.chunk_buffer[0];
                let last_index = self.chunk_buffer.len() - 1;
                let last = self.chunk_buffer[last_index];
                let first_rows = valid_chunk_rows(pages, first.node)?;
                self.chunk_buffer[0].start = first.end.saturating_sub(1);
                self.chunk_buffer[0].end = first_rows;
                self.chunk_buffer[last_index].end = last.start.saturating_add(1);
                self.chunk_buffer[last_index].start = 0;
            } else if let Some(chunk) = self.chunk_buffer.first_mut() {
                let start_y = chunk.start;
                chunk.start = chunk.end.saturating_sub(1);
                chunk.end = start_y.saturating_add(1);
            }
            std::mem::swap(&mut top_x, &mut bottom_x);
        }

        // Rust deviation: `Flattened` owns its AoS chunk Vec while Ghostty's
        // result borrows MultiArrayList scratch storage, so returning a match
        // clones only the small chunk list and retains scratch capacity.
        Some(Flattened {
            chunks: self.chunk_buffer.clone(),
            top_x,
            bot_x: bottom_x,
        })
    }

    // ghostty: terminal/search/sliding_window.zig:510
    pub fn append(&mut self, pages: &PageList, node_id: NodeId) -> Result<usize, AppendError> {
        let node = pages.node(node_id).ok_or(AppendError::InvalidNode)?;
        let serial = pages.node_serial(node_id).ok_or(AppendError::InvalidNode)?;
        let mut formatter = PageFormatter::new(&node.page);
        formatter.opts = FormatterOptions::plain_unwrapped();
        let mut formatted = formatter.format();
        debug_assert_eq!(formatted.point_map.len(), formatted.text.len());

        let page_size = node.page.size();
        if page_size.rows > 0 && !node.page.row(page_size.rows - 1).wrap() {
            formatted.text.push('\n');
            formatted
                .point_map
                .push(formatted.point_map.last().copied().unwrap_or_default());
        }

        if formatted.text.is_empty() {
            self.assert_integrity();
            return Ok(0);
        }

        let mut written = formatted.text.into_bytes();
        if self.direction == Direction::Reverse {
            written.reverse();
            formatted.point_map.reverse();
        }

        self.data.ensure_unused_capacity(written.len());
        self.meta.ensure_unused_capacity(1);
        self.chunk_buffer.reserve(self.meta.capacity());
        self.data.append_slice_assume_capacity(&written);
        // ghostty uses appendAssumeCapacity after reserving above. Keeping that
        // contract avoids disguising an impossible capacity error as a stale node.
        self.meta.append_assume_capacity(Meta {
            node: node_id,
            serial,
            cell_map: formatted.point_map,
        });
        self.assert_integrity();
        Ok(written.len())
    }

    #[cfg(test)]
    fn change_needle_for_test(&mut self, needle: &[u8]) {
        debug_assert_eq!(needle.len(), self.needle.len());
        self.needle.clear();
        self.needle.extend_from_slice(needle);
    }

    fn meta_at(&self, index: usize) -> Option<&Meta> {
        let mut iterator = self.meta.iterator(BufferDirection::Forward);
        iterator.seek_by(index as isize);
        iterator.next()
    }

    // ghostty: terminal/search/sliding_window.zig:603
    fn assert_integrity(&self) {
        #[cfg(debug_assertions)]
        {
            let mut iterator = self.meta.iterator(BufferDirection::Forward);
            let mut mapped = 0usize;
            while let Some(meta) = iterator.next() {
                mapped += meta.cell_map.len();
            }
            debug_assert_eq!(mapped, self.data.len());
            debug_assert!(matches!(self.data.len(), 0) || self.data_offset < self.data.len());
        }
    }
}

fn valid_node_rows(pages: &PageList, meta: &Meta) -> Option<CellCountInt> {
    // Rust safety deviation from sliding_window.zig:302-371: Ghostty owns
    // stable node pointers; the arena port validates both generation and
    // serial before resolving page data.
    if pages.node_serial(meta.node) != Some(meta.serial) {
        return None;
    }
    pages.node_page_size(meta.node).map(|size| size.rows)
}

fn valid_chunk_rows(pages: &PageList, node: NodeId) -> Option<CellCountInt> {
    // sliding_window.zig:420-459 reads nodes retained by the metadata
    // iterator. The immutable PageList borrow prevents reuse during this
    // operation; NodeId generation validation is supplied by the arena API.
    pages.node_page_size(node).map(|size| size.rows)
}

fn coordinate_y(coordinate: Coordinate) -> Option<CellCountInt> {
    // Rust safety deviation: Zig uses @intCast at sliding_window.zig:330-371;
    // malformed coordinates fail the match instead of trapping.
    CellCountInt::try_from(coordinate.y).ok()
}

fn index_of_ascii_case_insensitive(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    // ghostty: terminal/search/sliding_window.zig:177-232
    if needle.is_empty() {
        return Some(0);
    }
    haystack.windows(needle.len()).position(|candidate| {
        candidate
            .iter()
            .zip(needle)
            .all(|(left, right)| left.eq_ignore_ascii_case(right))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page_list::Pin;
    use crate::point::{Point, Tag};
    use crate::screen::{Options as ScreenOptions, Screen};
    use crate::stream::Stream;
    use crate::stream_terminal::{NoopEffects, TerminalHandler};
    use crate::terminal::{Options as TerminalOptions, Terminal};

    #[test]
    // ghostty: "SlidingWindow empty on init" (sliding_window.zig:635)
    fn empty_on_init() {
        let window = SlidingWindow::new(Direction::Forward, b"boo!");
        assert_eq!((window.data.len(), window.meta.len()), (0, 0));
    }

    #[test]
    // ghostty: "SlidingWindow single append" (sliding_window.zig:645)
    fn single_append_finds_two_matches() {
        let screen = single_page_screen("hello. boo! hello. boo!");
        let mut window = SlidingWindow::new(Direction::Forward, b"boo!");
        append_first(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (7, 0), (10, 0));
        assert_match(&mut window, &screen.pages, (19, 0), (22, 0));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
    }

    #[test]
    // ghostty: "SlidingWindow single append case insensitive ASCII" (sliding_window.zig:690)
    fn single_append_matches_ascii_case_insensitively() {
        let screen = single_page_screen("hello. boo! hello. boo!");
        let mut window = SlidingWindow::new(Direction::Forward, b"Boo!");
        append_first(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (7, 0), (10, 0));
        assert_match(&mut window, &screen.pages, (19, 0), (22, 0));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
    }

    #[test]
    // ghostty: "SlidingWindow single append single char" (sliding_window.zig:735)
    fn single_append_finds_single_character_matches() {
        let screen = single_page_screen("hello. boo! hello. boo!");
        let mut window = SlidingWindow::new(Direction::Forward, b"b");
        append_first(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (7, 0), (7, 0));
        assert_match(&mut window, &screen.pages, (19, 0), (19, 0));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
    }

    #[test]
    // ghostty: "SlidingWindow single append no match" (sliding_window.zig:780)
    fn single_append_keeps_page_when_no_match_needs_overlap() {
        let screen = single_page_screen("hello. boo! hello. boo!");
        let mut window = SlidingWindow::new(Direction::Forward, b"nope!");
        append_first(&mut window, &screen);
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 1);
    }

    #[test]
    // ghostty: "SlidingWindow two pages" (sliding_window.zig:804)
    fn two_pages_find_matches_in_page_order() {
        let screen = two_page_boo_screen();
        let mut window = SlidingWindow::new(Direction::Forward, b"boo!");
        append_two_forward(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (76, 22), (79, 22));
        assert_match(&mut window, &screen.pages, (7, 23), (10, 23));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
    }

    #[test]
    // ghostty: "SlidingWindow two pages single char" (sliding_window.zig:859)
    fn two_pages_find_single_character_matches() {
        let screen = two_page_boo_screen();
        let mut window = SlidingWindow::new(Direction::Forward, b"b");
        append_two_forward(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (76, 22), (76, 22));
        assert_match(&mut window, &screen.pages, (7, 23), (7, 23));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
    }

    #[test]
    // ghostty: "SlidingWindow two pages match across boundary" (sliding_window.zig:914)
    fn two_pages_match_across_boundary() {
        let screen = two_page_boundary_screen(false);
        let mut window = SlidingWindow::new(Direction::Forward, b"hello, world");
        append_two_forward(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (76, 22), (7, 23));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 2);
    }

    #[test]
    // ghostty: "SlidingWindow two pages no match across boundary with newline" (sliding_window.zig:959)
    fn two_pages_newline_prevents_boundary_match() {
        let screen = two_page_boundary_screen(true);
        let mut window = SlidingWindow::new(Direction::Forward, b"hello, world");
        append_two_forward(&mut window, &screen);
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 2);
    }

    #[test]
    // ghostty: "SlidingWindow two pages no match across boundary with newline reverse" (sliding_window.zig:992)
    fn two_pages_newline_prevents_boundary_match_in_reverse() {
        let screen = two_page_boundary_screen(true);
        let mut window = SlidingWindow::new(Direction::Reverse, b"hello, world");
        append_two_reverse(&mut window, &screen);
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
    }

    #[test]
    // ghostty: "SlidingWindow two pages no match prunes first page" (sliding_window.zig:1022)
    fn two_pages_no_match_prunes_first_page() {
        let screen = two_page_boo_screen();
        let mut window = SlidingWindow::new(Direction::Forward, b"nope!");
        append_two_forward(&mut window, &screen);
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 1);
    }

    #[test]
    // ghostty: "SlidingWindow two pages no match keeps both pages" (sliding_window.zig:1057)
    fn two_pages_no_match_keeps_pages_needed_for_needle() {
        let screen = two_page_boo_screen();
        let first_rows = first_page_rows(&screen.pages);
        let needle = vec![b'x'; first_rows * 80];
        let mut window = SlidingWindow::new(Direction::Forward, &needle);
        append_two_forward(&mut window, &screen);
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 2);
    }

    #[test]
    // ghostty: "SlidingWindow single append across circular buffer boundary" (sliding_window.zig:1097)
    fn single_append_finds_match_after_circular_buffer_wrap() {
        circular_boundary_case(Direction::Forward, b"boo", (19, 0), (21, 0));
    }

    #[test]
    // ghostty: "SlidingWindow single append match on boundary" (sliding_window.zig:1153)
    fn single_append_finds_match_spanning_circular_buffer_boundary() {
        circular_match_boundary_case(Direction::Forward, b"boo!");
    }

    #[test]
    // ghostty: "SlidingWindow single append reversed" (sliding_window.zig:1212)
    fn single_append_reversed_finds_matches_newest_first() {
        let screen = single_page_screen("hello. boo! hello. boo!");
        let mut window = SlidingWindow::new(Direction::Reverse, b"boo!");
        append_first(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (19, 0), (22, 0));
        assert_match(&mut window, &screen.pages, (7, 0), (10, 0));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
    }

    #[test]
    // ghostty: "SlidingWindow single append no match reversed" (sliding_window.zig:1257)
    fn single_append_reversed_keeps_page_when_no_match() {
        let screen = single_page_screen("hello. boo! hello. boo!");
        let mut window = SlidingWindow::new(Direction::Reverse, b"nope!");
        append_first(&mut window, &screen);
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 1);
    }

    #[test]
    // ghostty: "SlidingWindow two pages reversed" (sliding_window.zig:1281)
    fn two_pages_reversed_find_matches_in_reverse_order() {
        let screen = two_page_boo_screen();
        let mut window = SlidingWindow::new(Direction::Reverse, b"boo!");
        append_two_reverse(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (7, 23), (10, 23));
        assert_match(&mut window, &screen.pages, (76, 22), (79, 22));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
    }

    #[test]
    // ghostty: "SlidingWindow two pages match across boundary reversed" (sliding_window.zig:1336)
    fn two_pages_reversed_match_across_boundary() {
        let screen = two_page_boundary_screen(false);
        let mut window = SlidingWindow::new(Direction::Reverse, b"hello, world");
        append_two_reverse(&mut window, &screen);
        assert_match(&mut window, &screen.pages, (76, 22), (7, 23));
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 1);
    }

    #[test]
    // ghostty: "SlidingWindow two pages no match prunes first page reversed" (sliding_window.zig:1382)
    fn two_pages_reversed_no_match_prunes_first_appended_page() {
        let screen = two_page_boo_screen();
        let mut window = SlidingWindow::new(Direction::Reverse, b"nope!");
        append_two_reverse(&mut window, &screen);
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 1);
    }

    #[test]
    // ghostty: "SlidingWindow two pages no match keeps both pages reversed" (sliding_window.zig:1417)
    fn two_pages_reversed_no_match_keeps_pages_needed_for_needle() {
        let screen = two_page_boo_screen();
        let first_rows = first_page_rows(&screen.pages);
        let needle = vec![b'x'; first_rows * 80];
        let mut window = SlidingWindow::new(Direction::Reverse, &needle);
        append_two_reverse(&mut window, &screen);
        assert!(window.next(&screen.pages).is_none());
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 2);
    }

    #[test]
    // ghostty: "SlidingWindow single append across circular buffer boundary reversed" (sliding_window.zig:1457)
    fn single_append_reversed_finds_match_after_circular_buffer_wrap() {
        circular_boundary_case(Direction::Reverse, b"oob", (19, 0), (21, 0));
    }

    #[test]
    // ghostty: "SlidingWindow single append match on boundary reversed" (sliding_window.zig:1514)
    fn single_append_reversed_finds_match_spanning_circular_buffer_boundary() {
        circular_match_boundary_case(Direction::Reverse, b"!oob");
    }

    #[test]
    // ghostty: "SlidingWindow single append soft wrapped" (sliding_window.zig:1574)
    fn single_append_matches_across_soft_wrap() {
        soft_wrap_case(Direction::Forward);
    }

    #[test]
    // ghostty: "SlidingWindow single append reversed soft wrapped" (sliding_window.zig:1611)
    fn single_append_reversed_matches_across_soft_wrap() {
        soft_wrap_case(Direction::Reverse);
    }

    #[test]
    // ghostty: "SlidingWindow append whitespace only node" (sliding_window.zig:1650)
    fn append_whitespace_only_node_is_empty_and_safe() {
        let mut screen = Screen::new(ScreenOptions::default());
        let first = screen.pages.first_node().unwrap();
        set_last_row_wrap(&mut screen.pages, first, true);
        let mut window = SlidingWindow::new(Direction::Forward, b"x");
        assert_eq!(window.append(&screen.pages, first), Ok(0));
        assert!(window.next(&screen.pages).is_none());
    }

    fn single_page_screen(text: &str) -> Screen {
        let mut screen = Screen::new(ScreenOptions::default());
        screen.test_write_string(text);
        assert_eq!(screen.pages.first_node(), screen.pages.last_node());
        screen
    }

    fn two_page_boo_screen() -> Screen {
        let mut screen = Screen::new(ScreenOptions {
            cols: 80,
            rows: 24,
            max_scrollback: 1000,
        });
        fill_first_page_prefix(&mut screen, "boo!");
        screen.test_write_string("\n");
        assert_ne!(screen.pages.first_node(), screen.pages.last_node());
        screen.test_write_string("hello. boo!");
        screen
    }

    fn two_page_boundary_screen(with_newline: bool) -> Screen {
        let mut screen = Screen::new(ScreenOptions {
            cols: 80,
            rows: 24,
            max_scrollback: 1000,
        });
        fill_first_page_prefix(&mut screen, "hell");
        if with_newline {
            screen.test_write_string("\n");
        }
        screen.test_write_string("o, world!");
        assert_ne!(screen.pages.first_node(), screen.pages.last_node());
        screen
    }

    fn fill_first_page_prefix(screen: &mut Screen, suffix: &str) {
        let rows = first_page_rows(&screen.pages);
        for _ in 0..rows - 1 {
            screen.test_write_string("\n");
        }
        for _ in 0..80 - suffix.len() {
            screen.test_write_string("x");
        }
        screen.test_write_string(suffix);
        assert_eq!(screen.pages.first_node(), screen.pages.last_node());
    }

    fn first_page_rows(pages: &PageList) -> usize {
        let first = pages.first_node().unwrap();
        usize::from(pages.node(first).unwrap().page.capacity().rows)
    }

    fn append_first(window: &mut SlidingWindow, screen: &Screen) {
        let first = screen.pages.first_node().unwrap();
        window.append(&screen.pages, first).unwrap();
    }

    fn append_two_forward(window: &mut SlidingWindow, screen: &Screen) {
        let (first, second) = first_two_nodes(&screen.pages);
        window.append(&screen.pages, first).unwrap();
        window.append(&screen.pages, second).unwrap();
    }

    fn append_two_reverse(window: &mut SlidingWindow, screen: &Screen) {
        let (first, second) = first_two_nodes(&screen.pages);
        window.append(&screen.pages, second).unwrap();
        window.append(&screen.pages, first).unwrap();
    }

    fn first_two_nodes(pages: &PageList) -> (NodeId, NodeId) {
        let first = pages.first_node().unwrap();
        let second = pages.node(first).unwrap().next.unwrap();
        (first, second)
    }

    fn assert_match(
        window: &mut SlidingWindow,
        pages: &PageList,
        expected_start: (CellCountInt, u32),
        expected_end: (CellCountInt, u32),
    ) {
        let flattened = window.next(pages).unwrap();
        let (start, end) = flattened_pins(&flattened);
        assert_eq!(
            pages.point_from_pin(Tag::Active, start),
            Some(Point::active(expected_start.0, expected_start.1))
        );
        assert_eq!(
            pages.point_from_pin(Tag::Active, end),
            Some(Point::active(expected_end.0, expected_end.1))
        );
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

    fn circular_boundary_case(
        direction: Direction,
        replacement_needle: &[u8],
        expected_start: (CellCountInt, u32),
        expected_end: (CellCountInt, u32),
    ) {
        let screen = single_page_screen("XXXXXXXXXXXXXXXXXXXboo!XXXXX");
        let first = screen.pages.first_node().unwrap();
        let mut window = SlidingWindow::new(direction, b"abc");
        window.append(&screen.pages, first).unwrap();
        window.append(&screen.pages, first).unwrap();
        assert_data_slice_shape(&mut window, false);
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 1);
        window.change_needle_for_test(replacement_needle);
        window.append(&screen.pages, first).unwrap();
        assert_data_slice_shape(&mut window, true);
        assert_match(&mut window, &screen.pages, expected_start, expected_end);
        assert!(window.next(&screen.pages).is_none());
    }

    fn circular_match_boundary_case(direction: Direction, replacement_needle: &[u8]) {
        let mut screen = single_page_screen("o!XXXXXXXXXXXXXXXXXXXbo");
        let first = screen.pages.first_node().unwrap();
        set_last_row_wrap(&mut screen.pages, first, true);
        let mut window = SlidingWindow::new(direction, b"abcd");
        window.append(&screen.pages, first).unwrap();
        window.append(&screen.pages, first).unwrap();
        assert_data_slice_shape(&mut window, false);
        assert!(window.next(&screen.pages).is_none());
        assert_eq!(window.meta.len(), 1);
        window.change_needle_for_test(replacement_needle);
        window.append(&screen.pages, first).unwrap();
        assert_data_slice_shape(&mut window, true);
        assert_match(&mut window, &screen.pages, (21, 0), (1, 0));
        assert!(window.next(&screen.pages).is_none());
    }

    fn assert_data_slice_shape(window: &mut SlidingWindow, wrapped: bool) {
        let len = window.data.len();
        let (first, second) = window.data.get_mut_slices(0, len);
        assert!(!first.is_empty());
        assert_eq!(!second.is_empty(), wrapped);
    }

    fn set_last_row_wrap(pages: &mut PageList, node_id: NodeId, wrap: bool) {
        let rows = pages.node_page_size(node_id).unwrap().rows;
        let node = pages.node_mut(node_id).unwrap();
        let mut row = node.page.row(rows - 1);
        row.set_wrap(wrap);
        node.page.set_row(rows - 1, row);
    }

    fn soft_wrap_case(direction: Direction) {
        let terminal = Terminal::new(TerminalOptions {
            cols: 4,
            rows: 5,
            ..TerminalOptions::default()
        });
        let handler = TerminalHandler::new(terminal, NoopEffects);
        let mut stream = Stream::new(handler);
        stream.next_slice(b"A\r\nxxboo!\r\nC");
        let terminal = &stream.handler.terminal;
        let pages = &terminal.active_screen().pages;
        let first = pages.first_node().unwrap();
        assert_eq!(Some(first), pages.last_node());
        let mut window = SlidingWindow::new(direction, b"boo!");
        window.append(pages, first).unwrap();
        assert_match(&mut window, pages, (2, 1), (1, 2));
        assert!(window.next(pages).is_none());
        assert!(window.next(pages).is_none());
    }
}
