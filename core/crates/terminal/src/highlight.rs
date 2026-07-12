//! Terminal highlight tracking.
//!
//! Rust port of Ghostty's `terminal/highlight.zig` for the subset needed by
//! render snapshots. Highlights are stored either as untracked pins supplied by
//! callers or as tracked pins owned by a `PageList`.

use crate::page_list::{Direction, PageList, Pin, PinId};
use crate::point::Tag;
use crate::selection::Selection;
use crate::size::CellCountInt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Untracked {
    pub start: Pin,
    pub end: Pin,
}

impl Untracked {
    pub const fn new(start: Pin, end: Pin) -> Self {
        Self { start, end }
    }

    pub fn track(self, pages: &mut PageList) -> Tracked {
        Tracked {
            start: pages.track_pin(self.start),
            end: pages.track_pin(self.end),
        }
    }

    pub fn eql(self, other: Self) -> bool {
        self.start.eql(other.start) && self.end.eql(other.end)
    }

    pub fn selection(self) -> Selection {
        Selection::new(self.start, self.end, false)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tracked {
    pub start: PinId,
    pub end: PinId,
}

impl Tracked {
    pub fn untrack(self, pages: &mut PageList) {
        let _ = pages.untrack_pin(self.start);
        let _ = pages.untrack_pin(self.end);
    }

    pub fn untracked(self, pages: &PageList) -> Option<Untracked> {
        Some(Untracked {
            start: pages.tracked_pin(self.start)?,
            end: pages.tracked_pin(self.end)?,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlattenedChunk {
    pub node: crate::page_list::NodeId,
    pub start: CellCountInt,
    pub end: CellCountInt,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Flattened {
    pub chunks: Vec<FlattenedChunk>,
    pub top_x: CellCountInt,
    pub bot_x: CellCountInt,
}

impl Flattened {
    pub fn new(pages: &PageList, highlight: Untracked) -> Option<Self> {
        let top_left = Selection::new(highlight.start, highlight.end, false).top_left(pages)?;
        let bottom_right =
            Selection::new(highlight.start, highlight.end, false).bottom_right(pages)?;
        let top_point = pages.point_from_pin(Tag::Screen, top_left)?;
        let bottom_point = pages.point_from_pin(Tag::Screen, bottom_right)?;
        let mut iterator = pages.page_iterator(Direction::RightDown, top_point, Some(bottom_point));
        let mut chunks = Vec::new();
        while let Some(chunk) = iterator.next(pages) {
            chunks.push(FlattenedChunk {
                node: chunk.node,
                start: chunk.start,
                end: chunk.end,
            });
        }
        Some(Self {
            chunks,
            top_x: top_left.x,
            // Upstream highlight.zig historically called this `end_x`; T8b
            // ports the corrected behavior by carrying the bottom pin's x.
            bot_x: bottom_right.x,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page_list::PageList;
    use crate::point::Point;

    #[test]
    fn flattened_highlight_records_bottom_x() {
        // port-added: highlight.zig has no upstream tests; this pins the
        // corrected bottom-x behavior noted in the T8b task.
        let pages = PageList::new(10, 3, Some(0));
        let start = pages.pin(Point::screen(2, 0)).unwrap();
        let end = pages.pin(Point::screen(7, 1)).unwrap();
        let flattened = Flattened::new(&pages, Untracked::new(start, end)).unwrap();
        assert_eq!(flattened.top_x, 2);
        assert_eq!(flattened.bot_x, 7);
        assert_eq!(flattened.chunks.len(), 1);
    }

    #[test]
    fn tracked_highlight_round_trips_to_untracked() {
        // port-added: highlight.zig has no upstream tests.
        let mut pages = PageList::new(8, 2, Some(0));
        let start = pages.pin(Point::screen(1, 0)).unwrap();
        let end = pages.pin(Point::screen(3, 0)).unwrap();
        let tracked = Untracked::new(start, end).track(&mut pages);
        assert_eq!(tracked.untracked(&pages), Some(Untracked::new(start, end)));
        tracked.untrack(&mut pages);
        assert_eq!(tracked.untracked(&pages), None);
    }
}
