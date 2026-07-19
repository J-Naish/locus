//! Terminal text selection.
//!
//! Rust port of Ghostty's `terminal/Selection.zig`. The order helpers
//! deliberately recompute `point_from_pin` on each call, matching upstream's
//! observable semantics even though it is not the cheapest implementation.

use crate::page_list::{Direction, PageList, Pin, PinId};
use crate::point::{Coordinate, Point, Tag};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Bounds {
    Untracked { start: Pin, end: Pin },
    Tracked { start: PinId, end: PinId },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Order {
    Forward,
    Reverse,
    MirroredForward,
    MirroredReverse,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Adjustment {
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    BeginningOfLine,
    EndOfLine,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Selection {
    pub bounds: Bounds,
    pub rectangle: bool,
}

impl Selection {
    pub const fn new(start: Pin, end: Pin, rectangle: bool) -> Self {
        Self {
            bounds: Bounds::Untracked { start, end },
            rectangle,
        }
    }

    pub fn start(self, pages: &PageList) -> Option<Pin> {
        match self.bounds {
            Bounds::Untracked { start, .. } => Some(start),
            Bounds::Tracked { start, .. } => pages.tracked_pin(start),
        }
    }

    pub fn end(self, pages: &PageList) -> Option<Pin> {
        match self.bounds {
            Bounds::Untracked { end, .. } => Some(end),
            Bounds::Tracked { end, .. } => pages.tracked_pin(end),
        }
    }

    pub const fn tracked(self) -> bool {
        matches!(self.bounds, Bounds::Tracked { .. })
    }

    pub fn track(self, pages: &mut PageList) -> Self {
        if self.tracked() {
            return self;
        }
        let Some(start) = self.start(pages) else {
            return self;
        };
        let Some(end) = self.end(pages) else {
            return self;
        };
        // Ghostty rolls back the first tracked pin if the second allocation
        // fails. PageList::track_pin is infallible in this Rust slab, so the
        // rollback path collapses to straight-line code.
        let start = pages.track_pin(start);
        let end = pages.track_pin(end);
        Self {
            bounds: Bounds::Tracked { start, end },
            rectangle: self.rectangle,
        }
    }

    pub fn untrack(self, pages: &mut PageList) {
        if let Bounds::Tracked { start, end } = self.bounds {
            let _ = pages.untrack_pin(start);
            let _ = pages.untrack_pin(end);
        }
    }

    pub fn eql(self, pages: &PageList, other: Self) -> bool {
        let Some(start) = self.start(pages) else {
            return false;
        };
        let Some(end) = self.end(pages) else {
            return false;
        };
        let Some(other_start) = other.start(pages) else {
            return false;
        };
        let Some(other_end) = other.end(pages) else {
            return false;
        };
        start.eql(other_start) && end.eql(other_end) && self.rectangle == other.rectangle
    }

    pub fn order(self, pages: &PageList) -> Option<Order> {
        let start = self.start(pages)?;
        let end = self.end(pages)?;
        let start = pages.point_from_pin(Tag::Screen, start)?.coord();
        let end = pages.point_from_pin(Tag::Screen, end)?.coord();

        if self.rectangle {
            if start.y > end.y && start.x >= end.x {
                return Some(Order::Reverse);
            }
            if start.y >= end.y && start.x > end.x {
                return Some(Order::Reverse);
            }
            if start.y > end.y && start.x < end.x {
                return Some(Order::MirroredReverse);
            }
            if start.y < end.y && start.x > end.x {
                return Some(Order::MirroredForward);
            }
            return Some(Order::Forward);
        }

        if start.y < end.y {
            return Some(Order::Forward);
        }
        if start.y > end.y {
            return Some(Order::Reverse);
        }
        if start.x <= end.x {
            Some(Order::Forward)
        } else {
            Some(Order::Reverse)
        }
    }

    pub fn top_left(self, pages: &PageList) -> Option<Pin> {
        let start = self.start(pages)?;
        let end = self.end(pages)?;
        match self.order(pages)? {
            Order::Forward => Some(start),
            Order::Reverse => Some(end),
            Order::MirroredForward => compose_pin(pages, start, end),
            Order::MirroredReverse => compose_pin(pages, end, start),
        }
    }

    pub fn bottom_right(self, pages: &PageList) -> Option<Pin> {
        let start = self.start(pages)?;
        let end = self.end(pages)?;
        match self.order(pages)? {
            Order::Forward => Some(end),
            Order::Reverse => Some(start),
            Order::MirroredForward => compose_pin(pages, end, start),
            Order::MirroredReverse => compose_pin(pages, start, end),
        }
    }

    pub fn ordered(self, pages: &PageList, desired: Order) -> Option<Self> {
        if self.order(pages)? == desired {
            return Some(Self::new(
                self.start(pages)?,
                self.end(pages)?,
                self.rectangle,
            ));
        }
        let top_left = self.top_left(pages)?;
        let bottom_right = self.bottom_right(pages)?;
        Some(match desired {
            Order::Reverse => Self::new(bottom_right, top_left, self.rectangle),
            Order::Forward | Order::MirroredForward | Order::MirroredReverse => {
                Self::new(top_left, bottom_right, self.rectangle)
            }
        })
    }

    pub fn contains(self, pages: &PageList, pin: Pin) -> bool {
        let Some(top_left_pin) = self.top_left(pages) else {
            return false;
        };
        let Some(bottom_right_pin) = self.bottom_right(pages) else {
            return false;
        };
        let Some(top_left) = pages
            .point_from_pin(Tag::Screen, top_left_pin)
            .map(Point::coord)
        else {
            return false;
        };
        let Some(bottom_right) = pages
            .point_from_pin(Tag::Screen, bottom_right_pin)
            .map(Point::coord)
        else {
            return false;
        };
        let Some(point) = pages.point_from_pin(Tag::Screen, pin).map(Point::coord) else {
            return false;
        };

        if self.rectangle {
            return point.y >= top_left.y
                && point.y <= bottom_right.y
                && point.x >= top_left.x
                && point.x <= bottom_right.x;
        }

        if top_left.y == bottom_right.y {
            return point.y == top_left.y && point.x >= top_left.x && point.x <= bottom_right.x;
        }
        if point.y == top_left.y {
            return point.x >= top_left.x;
        }
        if point.y == bottom_right.y {
            return point.x <= bottom_right.x;
        }
        top_left.y < point.y && point.y < bottom_right.y
    }

    pub fn contained_row(self, pages: &PageList, pin: Pin) -> Option<Self> {
        let top_left_pin = self.top_left(pages)?;
        let bottom_right_pin = self.bottom_right(pages)?;
        let top_left = pages.point_from_pin(Tag::Screen, top_left_pin)?.coord();
        let bottom_right = pages.point_from_pin(Tag::Screen, bottom_right_pin)?.coord();
        let point = pages.point_from_pin(Tag::Screen, pin)?.coord();
        self.contained_row_cached(
            pages,
            top_left_pin,
            bottom_right_pin,
            pin,
            top_left,
            bottom_right,
            point,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn contained_row_cached(
        self,
        pages: &PageList,
        top_left_pin: Pin,
        bottom_right_pin: Pin,
        pin: Pin,
        top_left: Coordinate,
        bottom_right: Coordinate,
        point: Coordinate,
    ) -> Option<Self> {
        if point.y < top_left.y || point.y > bottom_right.y {
            return None;
        }

        if self.rectangle {
            let start = Pin {
                x: top_left.x,
                ..pin
            };
            let end = Pin {
                x: bottom_right.x,
                ..pin
            };
            return Some(Self::new(start, end, true));
        }

        if point.y == top_left.y {
            if point.y == bottom_right.y {
                return Some(Self::new(top_left_pin, bottom_right_pin, false));
            }
            let end = Pin {
                x: pages.cols.saturating_sub(1),
                ..pin
            };
            return Some(Self::new(top_left_pin, end, false));
        }

        if point.y == bottom_right.y {
            return Some(Self::new(Pin { x: 0, ..pin }, bottom_right_pin, false));
        }

        Some(Self::new(
            Pin { x: 0, ..pin },
            Pin {
                x: pages.cols.saturating_sub(1),
                ..pin
            },
            false,
        ))
    }

    pub fn adjust(&mut self, pages: &mut PageList, adjustment: Adjustment) {
        let Some(mut end) = self.end(pages) else {
            return;
        };
        let adjusted = adjusted_pin(pages, end, adjustment);
        end = adjusted.unwrap_or(end);
        match self.bounds {
            Bounds::Untracked { ref mut end, .. } => *end = adjusted.unwrap_or(*end),
            Bounds::Tracked { end: id, .. } => {
                let _ = pages.set_tracked_pin(id, end);
            }
        }
    }
}

fn compose_pin(pages: &PageList, row_pin: Pin, column_pin: Pin) -> Option<Pin> {
    let row = pages.point_from_pin(Tag::Screen, row_pin)?.coord();
    let col = pages.point_from_pin(Tag::Screen, column_pin)?.coord();
    pages.pin(Point::screen(col.x, row.y))
}

fn adjusted_pin(pages: &PageList, end: Pin, adjustment: Adjustment) -> Option<Pin> {
    match adjustment {
        Adjustment::Up => pages.pin_up(end, 1).or(Some(Pin { x: 0, ..end })),
        Adjustment::Down => adjust_down(pages, end).or_else(|| current_line_end(pages, end)),
        Adjustment::Left => text_cell_in_direction(pages, end, Direction::LeftUp),
        Adjustment::Right => text_cell_in_direction(pages, end, Direction::RightDown),
        Adjustment::PageUp => pages
            .pin_up(end, pages.rows as usize)
            .or_else(|| pages.pin(Point::screen(0, 0))),
        Adjustment::PageDown => pages
            .pin_down(end, pages.rows as usize)
            .or_else(|| last_text_row_end(pages, end)),
        Adjustment::Home => pages.pin(Point::screen(0, 0)),
        Adjustment::End => last_text_row_end(pages, end),
        Adjustment::BeginningOfLine => Some(Pin { x: 0, ..end }),
        Adjustment::EndOfLine => current_line_end(pages, end),
    }
}

fn adjust_down(pages: &PageList, end: Pin) -> Option<Pin> {
    let mut current = end;
    while let Some(next) = pages.pin_down(current, 1) {
        if pages
            .node(next.node)
            .map(|node| node.page.has_text_any(next.y))
            .unwrap_or(false)
        {
            return Some(next);
        }
        current = next;
    }
    None
}

fn text_cell_in_direction(pages: &PageList, end: Pin, direction: Direction) -> Option<Pin> {
    let mut current = end;
    loop {
        current = match direction {
            Direction::LeftUp => step_left(pages, current)?,
            Direction::RightDown => step_right(pages, current)?,
        };
        let Some((_, cell)) = pages.row_and_cell(current) else {
            continue;
        };
        if cell.has_text() {
            return Some(current);
        }
    }
}

fn step_left(pages: &PageList, pin: Pin) -> Option<Pin> {
    if pin.x > 0 {
        return Some(Pin {
            x: pin.x - 1,
            ..pin
        });
    }
    let mut prior = pages.pin_up(pin, 1)?;
    prior.x = pages
        .node(prior.node)
        .map(|node| node.page.size().cols.saturating_sub(1))
        .unwrap_or(0);
    Some(prior)
}

fn step_right(pages: &PageList, pin: Pin) -> Option<Pin> {
    let cols = pages.node(pin.node)?.page.size().cols;
    if pin.x + 1 < cols {
        return Some(Pin {
            x: pin.x + 1,
            ..pin
        });
    }
    pages.pin_down(Pin { x: 0, ..pin }, 1)
}

fn current_line_end(pages: &PageList, pin: Pin) -> Option<Pin> {
    let cols = pages.node(pin.node)?.page.size().cols;
    Some(Pin {
        x: cols.saturating_sub(1),
        ..pin
    })
}

fn last_text_row_end(pages: &PageList, fallback: Pin) -> Option<Pin> {
    let bottom = pages.get_bottom_right(Tag::Screen)?;
    let mut current = bottom.left(bottom.x as usize);
    loop {
        if pages
            .node(current.node)
            .map(|node| node.page.has_text_any(current.y))
            .unwrap_or(false)
        {
            return current_line_end(pages, current);
        }
        let Some(prior) = pages.pin_up(current, 1) else {
            break;
        };
        current = prior.left(prior.x as usize);
    }
    Some(fallback)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::size::CellCountInt;

    fn screen_pin(pages: &PageList, x: CellCountInt, y: u32) -> Pin {
        pages.pin(Point::screen(x, y)).unwrap()
    }

    fn set_text(pages: &mut PageList, text: &[&str]) {
        for (y, row) in text.iter().enumerate() {
            for (x, ch) in row.chars().enumerate() {
                assert!(pages.set_cell(Point::screen(x as CellCountInt, y as u32), Cell::new(ch)));
            }
        }
    }

    use crate::page::Cell;

    #[test]
    fn selection_order_standard_matches_ghostty() {
        // ghostty: "Selection: order, standard" (Selection.zig:993)
        let pages = PageList::new(100, 100, None);
        assert_eq!(
            Selection::new(screen_pin(&pages, 2, 1), screen_pin(&pages, 2, 2), false).order(&pages),
            Some(Order::Forward)
        );
        assert_eq!(
            Selection::new(screen_pin(&pages, 2, 2), screen_pin(&pages, 2, 1), false).order(&pages),
            Some(Order::Reverse)
        );
        assert_eq!(
            Selection::new(screen_pin(&pages, 2, 1), screen_pin(&pages, 1, 1), false).order(&pages),
            Some(Order::Reverse)
        );
    }

    #[test]
    fn selection_order_rectangle_mirrors_axes() {
        // ghostty: "Selection: order, rectangle" (Selection.zig:1057)
        let pages = PageList::new(100, 100, None);
        assert_eq!(
            Selection::new(screen_pin(&pages, 3, 1), screen_pin(&pages, 1, 3), true).order(&pages),
            Some(Order::MirroredForward)
        );
        assert_eq!(
            Selection::new(screen_pin(&pages, 1, 3), screen_pin(&pages, 3, 1), true).order(&pages),
            Some(Order::MirroredReverse)
        );
        let top_left = Selection::new(screen_pin(&pages, 3, 1), screen_pin(&pages, 1, 3), true)
            .top_left(&pages)
            .unwrap();
        assert_eq!(
            pages.point_from_pin(Tag::Screen, top_left).unwrap(),
            Point::screen(1, 1)
        );
    }

    #[test]
    fn selection_contains_standard_and_rectangle() {
        // ghostty: "Selection: contains" (Selection.zig:1377)
        // ghostty: "Selection: contains, rectangle" (Selection.zig:1423)
        let pages = PageList::new(15, 15, None);
        let standard = Selection::new(screen_pin(&pages, 5, 1), screen_pin(&pages, 3, 2), false);
        assert!(standard.contains(&pages, screen_pin(&pages, 6, 1)));
        assert!(standard.contains(&pages, screen_pin(&pages, 1, 2)));
        assert!(!standard.contains(&pages, screen_pin(&pages, 1, 1)));

        let rect = Selection::new(screen_pin(&pages, 3, 3), screen_pin(&pages, 7, 9), true);
        assert!(rect.contains(&pages, screen_pin(&pages, 5, 6)));
        assert!(rect.contains(&pages, screen_pin(&pages, 7, 6)));
        assert!(!rect.contains(&pages, screen_pin(&pages, 8, 6)));
    }

    #[test]
    fn selection_contained_row_slices_multiline_selection() {
        // ghostty: "Selection: containedRow" (Selection.zig:1486)
        let pages = PageList::new(10, 5, None);
        let selection = Selection::new(screen_pin(&pages, 5, 1), screen_pin(&pages, 3, 3), false);
        assert!(selection
            .contained_row(&pages, screen_pin(&pages, 1, 4))
            .is_none());
        let middle = selection
            .contained_row(&pages, screen_pin(&pages, 2, 2))
            .unwrap();
        assert_eq!(
            pages.point_from_pin(Tag::Screen, middle.start(&pages).unwrap()),
            Some(Point::screen(0, 2))
        );
        assert_eq!(
            pages.point_from_pin(Tag::Screen, middle.end(&pages).unwrap()),
            Some(Point::screen(9, 2))
        );
    }

    #[test]
    fn selection_adjust_skips_blank_cells() {
        // ghostty: "Selection: adjust left skips blanks" (Selection.zig:628)
        let mut pages = PageList::new(10, 10, None);
        set_text(&mut pages, &["A1234", "B5678", "C12", "D56"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 5, 1), screen_pin(&pages, 4, 3), false);
        selection.adjust(&mut pages, Adjustment::Left);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(2, 3))
        );
    }

    #[test]
    fn selection_adjust_right_crosses_to_next_written_line() {
        // ghostty: "Selection: adjust right" (Selection.zig:512)
        let mut pages = PageList::new(10, 10, None);
        set_text(&mut pages, &["A1234", "B5678", "C1234", "D5678"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 4, 1), screen_pin(&pages, 4, 2), false);
        selection.adjust(&mut pages, Adjustment::Right);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(0, 3))
        );
    }

    #[test]
    fn selection_adjust_left_crosses_to_prior_written_line() {
        // ghostty: "Selection: adjust left" (Selection.zig:579)
        let mut pages = PageList::new(10, 10, None);
        set_text(&mut pages, &["A1234", "B5678", "C1234", "D5678"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 5, 1), screen_pin(&pages, 0, 3), false);
        selection.adjust(&mut pages, Adjustment::Left);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(4, 2))
        );
    }

    #[test]
    fn selection_adjust_up_preserves_column() {
        // ghostty: "Selection: adjust up" (Selection.zig:677)
        let mut pages = PageList::new(10, 10, None);
        set_text(&mut pages, &["A", "B", "C", "D", "E"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 5, 1), screen_pin(&pages, 3, 3), false);
        selection.adjust(&mut pages, Adjustment::Up);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(3, 2))
        );
    }

    #[test]
    fn selection_adjust_down_skips_blank_rows() {
        // ghostty: "Selection: adjust down with not full screen" (Selection.zig:771)
        let mut pages = PageList::new(10, 10, None);
        set_text(&mut pages, &["A", "B", "C"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 4, 1), screen_pin(&pages, 3, 2), false);
        selection.adjust(&mut pages, Adjustment::Down);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(9, 2))
        );
    }

    #[test]
    fn selection_adjust_down_moves_to_next_written_row() {
        // ghostty: "Selection: adjust down" (Selection.zig:724)
        let mut pages = PageList::new(10, 10, None);
        set_text(&mut pages, &["A", "B", "C", "D", "E"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 5, 1), screen_pin(&pages, 3, 3), false);
        selection.adjust(&mut pages, Adjustment::Down);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(3, 4))
        );
    }

    #[test]
    fn selection_adjust_home_jumps_to_origin() {
        // ghostty: "Selection: adjust home" (Selection.zig:799)
        let mut pages = PageList::new(10, 10, None);
        set_text(&mut pages, &["A", "B", "C"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 4, 1), screen_pin(&pages, 1, 2), false);
        selection.adjust(&mut pages, Adjustment::Home);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(0, 0))
        );
    }

    #[test]
    fn selection_adjust_end_jumps_to_last_written_row_end() {
        // ghostty: "Selection: adjust end with not full screen" (Selection.zig:827)
        let mut pages = PageList::new(10, 10, None);
        set_text(&mut pages, &["A", "B", "C"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 4, 0), screen_pin(&pages, 1, 1), false);
        selection.adjust(&mut pages, Adjustment::End);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(9, 2))
        );
    }

    #[test]
    fn selection_adjust_beginning_of_line_sets_x_zero() {
        // ghostty: "Selection: adjust beginning of line" (Selection.zig:855)
        let mut pages = PageList::new(8, 10, None);
        set_text(&mut pages, &["A12 B34", "C12 D34"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 5, 1), screen_pin(&pages, 5, 1), false);
        selection.adjust(&mut pages, Adjustment::BeginningOfLine);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(0, 1))
        );
    }

    #[test]
    fn selection_adjust_end_of_line_sets_last_column() {
        // ghostty: "Selection: adjust end of line" (Selection.zig:925)
        let mut pages = PageList::new(8, 10, None);
        set_text(&mut pages, &["A12 B34", "C12 D34"]);
        let mut selection =
            Selection::new(screen_pin(&pages, 1, 0), screen_pin(&pages, 1, 0), false);
        selection.adjust(&mut pages, Adjustment::EndOfLine);
        assert_eq!(
            pages.point_from_pin(Tag::Screen, selection.end(&pages).unwrap()),
            Some(Point::screen(7, 0))
        );
    }

    #[test]
    fn selection_bottom_right_normalizes_reverse() {
        // ghostty: "bottomRight" (Selection.zig:1233)
        let pages = PageList::new(10, 10, None);
        let selection = Selection::new(screen_pin(&pages, 3, 1), screen_pin(&pages, 1, 1), false);
        let bottom_right = selection.bottom_right(&pages).unwrap();
        assert_eq!(
            pages.point_from_pin(Tag::Screen, bottom_right),
            Some(Point::screen(3, 1))
        );
    }

    #[test]
    fn selection_top_left_composes_rectangle_axes() {
        // ghostty: "topLeft" (Selection.zig:1170)
        let pages = PageList::new(10, 10, None);
        let selection = Selection::new(screen_pin(&pages, 3, 1), screen_pin(&pages, 1, 3), true);
        let top_left = selection.top_left(&pages).unwrap();
        assert_eq!(
            pages.point_from_pin(Tag::Screen, top_left),
            Some(Point::screen(1, 1))
        );
    }

    #[test]
    fn selection_ordered_can_reverse() {
        // ghostty: "ordered" (Selection.zig:1296)
        let pages = PageList::new(10, 10, None);
        let selection = Selection::new(screen_pin(&pages, 1, 1), screen_pin(&pages, 3, 1), false);
        let reversed = selection.ordered(&pages, Order::Reverse).unwrap();
        assert_eq!(
            pages.point_from_pin(Tag::Screen, reversed.start(&pages).unwrap()),
            Some(Point::screen(3, 1))
        );
        assert_eq!(
            pages.point_from_pin(Tag::Screen, reversed.end(&pages).unwrap()),
            Some(Point::screen(1, 1))
        );
    }

    #[test]
    fn selection_tracking_uses_page_list_slab() {
        // port-added: Selection::track uses the same tracked-pin slab as Screen::select.
        let mut pages = PageList::new(10, 10, None);
        let initial = pages.count_tracked_pins();
        let selection = Selection::new(screen_pin(&pages, 0, 0), screen_pin(&pages, 1, 0), false)
            .track(&mut pages);
        assert!(selection.tracked());
        assert_eq!(pages.count_tracked_pins(), initial + 2);
        selection.untrack(&mut pages);
        assert_eq!(pages.count_tracked_pins(), initial);
    }
}
