//! Search coordination across a mutable terminal screen and its scrollback.

use std::fmt;

use crate::highlight::{Flattened, Tracked, Untracked};
use crate::page_list::{NodeId, PageList, Pin, PinId};
use crate::screen::Screen;
use crate::size::CellCountInt;

use super::{ActiveSearch, AppendError, Direction, PageListSearch, SlidingWindow};

/// Incremental progress state for a screen-wide search.
// ghostty: terminal/search/screen.zig:100
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenSearchState {
    Active,
    History,
    HistoryFeed,
    Complete,
}

impl ScreenSearchState {
    // ghostty: terminal/search/screen.zig:115
    pub const fn is_complete(self) -> bool {
        matches!(self, Self::Complete)
    }

    // ghostty: terminal/search/screen.zig:122
    pub const fn needs_feed(self) -> bool {
        matches!(self, Self::HistoryFeed | Self::Complete)
    }
}

/// Direction in which the selected search match advances.
// ghostty: terminal/search/screen.zig:685
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Select {
    /// Newest to oldest.
    Next,
    /// Oldest to newest.
    Prev,
}

/// Non-fatal stop conditions from one incremental search tick.
// ghostty: terminal/search/screen.zig:233
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenSearchTickError {
    FeedRequired,
    SearchComplete,
}

impl fmt::Display for ScreenSearchTickError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::FeedRequired => "screen search requires more history",
            Self::SearchComplete => "screen search is complete",
        })
    }
}

struct HistorySearch {
    searcher: PageListSearch,
    start_pin: PinId,
}

impl HistorySearch {
    // ghostty: terminal/search/screen.zig:94
    fn deinit(&mut self, pages: &mut PageList) {
        self.searcher.deinit(pages);
        let _ = pages.untrack_pin(self.start_pin);
    }
}

struct SelectedMatch {
    /// Index from the end of the match list, where zero is newest.
    idx: usize,
    highlight: Tracked,
}

impl SelectedMatch {
    // ghostty: terminal/search/screen.zig:78
    fn deinit(self, pages: &mut PageList) {
        self.highlight.untrack(pages);
    }
}

/// Cached search results spanning a screen's active area and scrollback.
// ghostty: terminal/search/screen.zig:26-40
pub struct ScreenSearch {
    active: ActiveSearch,
    history: Option<HistorySearch>,
    state: ScreenSearchState,
    selected: Option<SelectedMatch>,
    history_results: Vec<Flattened>,
    active_results: Vec<Flattened>,
    rows: CellCountInt,
    cols: CellCountInt,
}

impl ScreenSearch {
    // ghostty: terminal/search/screen.zig:135
    pub fn new(screen: &mut Screen, needle: &[u8]) -> Result<Self, AppendError> {
        let mut result = Self {
            active: ActiveSearch::new(needle),
            history: None,
            state: ScreenSearchState::Active,
            selected: None,
            history_results: Vec::new(),
            active_results: Vec::new(),
            rows: screen.pages.rows,
            cols: screen.pages.cols,
        };
        result.reload_active(screen)?;
        Ok(result)
    }

    // ghostty: terminal/search/screen.zig:159
    pub fn deinit(&mut self, screen: &mut Screen) {
        if let Some(mut history) = self.history.take() {
            history.deinit(&mut screen.pages);
        }
        if let Some(selected) = self.selected.take() {
            selected.deinit(&mut screen.pages);
        }
        self.active_results.clear();
        self.history_results.clear();
    }

    // ghostty: terminal/search/screen.zig:175
    pub fn needle(&self) -> &[u8] {
        self.active.needle()
    }

    // ghostty: terminal/search/screen.zig:181
    pub fn matches_len(&self) -> usize {
        self.active_results.len() + self.history_results.len()
    }

    // ghostty: terminal/search/screen.zig:188
    pub fn matches(&self) -> Vec<Flattened> {
        let mut results = Vec::with_capacity(self.matches_len());
        results.extend(self.active_results.iter().rev().cloned());
        results.extend(self.history_results.iter().cloned());
        results
    }

    // ghostty: terminal/search/screen.zig:223
    pub fn search_all(&mut self, screen: &mut Screen) -> Result<(), AppendError> {
        loop {
            match self.tick(screen) {
                Ok(()) => {}
                Err(ScreenSearchTickError::FeedRequired) => self.feed(screen)?,
                Err(ScreenSearchTickError::SearchComplete) => return Ok(()),
            }
        }
    }

    // ghostty: terminal/search/screen.zig:248
    pub fn tick(&mut self, screen: &Screen) -> Result<(), ScreenSearchTickError> {
        match self.state {
            ScreenSearchState::Active => self.tick_active(screen),
            ScreenSearchState::History => self.tick_history(screen),
            ScreenSearchState::HistoryFeed => Err(ScreenSearchTickError::FeedRequired),
            ScreenSearchState::Complete => Err(ScreenSearchTickError::SearchComplete),
        }
    }

    // ghostty: terminal/search/screen.zig:262
    pub fn feed(&mut self, screen: &mut Screen) -> Result<(), AppendError> {
        if screen.pages.rows != self.rows || screen.pages.cols != self.cols {
            let needle = self.needle().to_vec();
            let replacement = Self::new(screen, &needle)?;
            self.deinit(screen);
            *self = replacement;
        }

        let Some(history) = self.history.as_mut() else {
            self.state = ScreenSearchState::Complete;
            return Ok(());
        };
        if !history.searcher.feed(&mut screen.pages) {
            self.state = ScreenSearchState::Complete;
            self.prune_history(&screen.pages);
            return Ok(());
        }

        match self.state {
            ScreenSearchState::Active | ScreenSearchState::History => {}
            ScreenSearchState::HistoryFeed => self.state = ScreenSearchState::History,
            ScreenSearchState::Complete => {
                // Ghostty marks this unreachable. A stale page search can be
                // exhausted in Rust instead, so retain the complete state.
            }
        }
        Ok(())
    }

    fn prune_history(&mut self, pages: &PageList) {
        // ghostty: terminal/search/screen.zig:320
        // Rust deviation: generational NodeIds make stale/recycled nodes
        // directly detectable, so no copied serial is needed on each chunk.
        if let Some(index) = self.history_results.iter().position(|highlight| {
            highlight
                .chunks
                .iter()
                .any(|chunk| pages.node(chunk.node).is_none())
        }) {
            self.history_results.truncate(index);
        }
    }

    // ghostty: terminal/search/screen.zig:339
    fn tick_active(&mut self, screen: &Screen) -> Result<(), ScreenSearchTickError> {
        while let Some(highlight) = self.active.next(&screen.pages) {
            self.active_results.push(highlight);
        }
        self.state = ScreenSearchState::History;
        Ok(())
    }

    // ghostty: terminal/search/screen.zig:358
    fn tick_history(&mut self, screen: &Screen) -> Result<(), ScreenSearchTickError> {
        let Some(history) = self.history.as_mut() else {
            self.state = ScreenSearchState::Complete;
            return Ok(());
        };
        let Some(start_pin) = screen.pages.tracked_pin(history.start_pin) else {
            self.state = ScreenSearchState::Complete;
            return Ok(());
        };
        while let Some(highlight) = history.searcher.next(&screen.pages) {
            if highlight.chunks.first().map(|chunk| chunk.node) == Some(start_pin.node) {
                continue;
            }
            self.history_results.push(highlight);
        }
        self.state = ScreenSearchState::HistoryFeed;
        Ok(())
    }

    // ghostty: terminal/search/screen.zig:394
    pub fn reload_active(&mut self, screen: &mut Screen) -> Result<(), AppendError> {
        // Ghostty's allocation-failure tripwire has no Rust equivalent: Vec
        // allocation is infallible at this layer.
        let should_select_prev = self
            .selected
            .as_ref()
            .and_then(|selected| selected.highlight.untracked(&screen.pages))
            .is_some_and(|highlight| highlight.start.garbage || highlight.end.garbage)
            || self
                .selected
                .as_ref()
                .is_some_and(|selected| selected.highlight.untracked(&screen.pages).is_none());
        if should_select_prev {
            if let Some(selected) = self.selected.take() {
                selected.deinit(&mut screen.pages);
            }
        }

        let history_node = self.active.update(&screen.pages)?;
        self.reload_history(screen, history_node)?;

        let old_active_len = self.active_results.len();
        let old_selection_idx = self.selected.as_ref().map(|selected| selected.idx);
        self.active_results.clear();
        let old_state = self.state;
        self.tick_active(screen)
            .map_err(|_| AppendError::InvalidNode)?;
        if old_state != ScreenSearchState::Active {
            self.state = old_state;
        }

        if screen.no_scrollback {
            self.prune_inactive_results(&screen.pages);
        }
        self.fixup_selection_after_active_reload(screen, old_active_len, old_selection_idx);

        if should_select_prev {
            let _ = self.select_prev(screen);
        }
        Ok(())
    }

    fn reload_history(
        &mut self,
        screen: &mut Screen,
        history_node: Option<NodeId>,
    ) -> Result<(), AppendError> {
        let Some(history_node) = history_node else {
            if let Some(mut history) = self.history.take() {
                history.deinit(&mut screen.pages);
                self.history_results.clear();
            }
            let active_len = self.active_results.len();
            if self
                .selected
                .as_ref()
                .is_some_and(|selected| selected.idx >= active_len)
            {
                if let Some(selected) = self.selected.take() {
                    selected.deinit(&mut screen.pages);
                }
            }
            return Ok(());
        };

        if screen.no_scrollback {
            debug_assert!(self.history.is_none());
            return Ok(());
        }

        let history_is_garbage = self.history.as_ref().is_some_and(|history| {
            screen
                .pages
                .tracked_pin(history.start_pin)
                .is_none_or(|pin| pin.garbage)
        });
        if history_is_garbage {
            if let Some(mut history) = self.history.take() {
                history.deinit(&mut screen.pages);
            }
            self.history_results.clear();
        }

        if self.history.is_none() {
            let searcher = PageListSearch::new(&mut screen.pages, self.needle(), history_node)
                .ok_or(AppendError::InvalidNode)?;
            let start_pin = screen.pages.track_pin(Pin::new(history_node));
            self.history = Some(HistorySearch {
                searcher,
                start_pin,
            });
            return Ok(());
        }

        let Some(start_pin_id) = self.history.as_ref().map(|history| history.start_pin) else {
            return Ok(());
        };
        let Some(mut start_pin) = screen.pages.tracked_pin(start_pin_id) else {
            return Err(AppendError::InvalidNode);
        };
        if start_pin.node == history_node {
            return Ok(());
        }

        let mut window = SlidingWindow::new(Direction::Forward, self.needle());
        loop {
            window.append(&screen.pages, start_pin.node)?;
            if start_pin.node == history_node {
                break;
            }
            start_pin.node = screen
                .pages
                .node(start_pin.node)
                .and_then(|node| node.next)
                .ok_or(AppendError::InvalidNode)?;
        }
        if !screen.pages.set_tracked_pin(start_pin_id, start_pin) {
            return Err(AppendError::InvalidNode);
        }

        let mut results = Vec::with_capacity(self.history_results.len());
        while let Some(highlight) = window.next(&screen.pages) {
            if highlight.chunks.first().map(|chunk| chunk.node) != Some(history_node) {
                results.push(highlight);
            }
        }
        if results.is_empty() {
            return Ok(());
        }

        let added_len = results.len();
        results.reverse();
        results.append(&mut self.history_results);
        self.history_results = results;
        if let Some(selected) = self.selected.as_mut() {
            if selected.idx >= self.active_results.len() {
                selected.idx += added_len;
            }
        }
        Ok(())
    }

    fn prune_inactive_results(&mut self, pages: &PageList) {
        let top_left = pages.get_top_left(crate::point::Tag::Active);
        let first_active = self.active_results.iter().position(|highlight| {
            flattened_untracked(highlight)
                .is_some_and(|untracked| top_left.before(pages, untracked.end))
        });
        match first_active {
            Some(0) => {}
            Some(index) => {
                self.active_results.drain(0..index);
            }
            None => self.active_results.clear(),
        }
    }

    fn fixup_selection_after_active_reload(
        &mut self,
        screen: &mut Screen,
        old_active_len: usize,
        old_selection_idx: Option<usize>,
    ) {
        let Some(old_idx) = old_selection_idx else {
            return;
        };
        let Some(current) = self.selected.as_mut() else {
            return;
        };
        if old_idx >= old_active_len {
            current.idx = old_idx - old_active_len + self.active_results.len();
            return;
        }

        let tracked = current.highlight.untracked(&screen.pages);
        if let Some((index, _)) = self
            .active_results
            .iter()
            .enumerate()
            .find(|(_, highlight)| flattened_untracked(highlight) == tracked)
        {
            current.idx = self.active_results.len() - 1 - index;
            return;
        }

        if let Some(selected) = self.selected.take() {
            selected.deinit(&mut screen.pages);
        }
        let _ = self.select_next(screen);
    }

    // ghostty: terminal/search/screen.zig:670
    pub fn selected_match(&self) -> Option<&Flattened> {
        let idx = self.selected.as_ref()?.idx;
        self.match_by_selection_index(idx)
    }

    // ghostty: terminal/search/screen.zig:698
    pub fn select(&mut self, screen: &mut Screen, to: Select) -> Result<bool, AppendError> {
        self.reload_active(screen)?;
        self.prune_history(&screen.pages);
        Ok(match to {
            Select::Next => self.select_next(screen),
            Select::Prev => self.select_prev(screen),
        })
    }

    // ghostty: terminal/search/screen.zig:711
    fn select_next(&mut self, screen: &mut Screen) -> bool {
        self.move_selection(screen, true)
    }

    // ghostty: terminal/search/screen.zig:765
    fn select_prev(&mut self, screen: &mut Screen) -> bool {
        self.move_selection(screen, false)
    }

    fn move_selection(&mut self, screen: &mut Screen, toward_older: bool) -> bool {
        let total = self.matches_len();
        if total == 0 {
            if let Some(selected) = self.selected.take() {
                selected.deinit(&mut screen.pages);
            }
            return false;
        }

        let next_idx = match self.selected.as_ref().map(|selected| selected.idx) {
            None if toward_older => 0,
            None => total - 1,
            Some(idx) if toward_older => (idx + 1) % total,
            Some(0) => total - 1,
            Some(idx) => idx - 1,
        };
        let Some(untracked) = self
            .match_by_selection_index(next_idx)
            .and_then(flattened_untracked)
        else {
            return false;
        };
        let tracked = untracked.track(&mut screen.pages);
        if let Some(previous) = self.selected.take() {
            previous.deinit(&mut screen.pages);
        }
        self.selected = Some(SelectedMatch {
            idx: next_idx,
            highlight: tracked,
        });
        true
    }

    fn match_by_selection_index(&self, idx: usize) -> Option<&Flattened> {
        let active_len = self.active_results.len();
        if idx < active_len {
            return self.active_results.get(active_len - 1 - idx);
        }
        self.history_results.get(idx - active_len)
    }
}

fn flattened_untracked(flattened: &Flattened) -> Option<Untracked> {
    let first = flattened.chunks.first()?;
    let last = flattened.chunks.last()?;
    Some(Untracked::new(
        Pin {
            node: first.node,
            x: flattened.top_x,
            y: first.start,
            garbage: false,
        },
        Pin {
            node: last.node,
            x: flattened.bot_x,
            y: last.end.checked_sub(1)?,
            garbage: false,
        },
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::point::Point;
    use crate::stream::{EraseDisplay, Stream};
    use crate::terminal::{Options as TerminalOptions, Terminal};

    #[test]
    // ghostty: "simple search" (screen.zig:823)
    fn simple_search() {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");

        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        let matches = search.matches();
        assert_eq!(matches.len(), 2);
        assert_match(
            &matches[0],
            stream.handler.active_screen(),
            Point::screen(0, 2),
            Point::screen(3, 2),
        );
        assert_match(
            &matches[1],
            stream.handler.active_screen(),
            Point::screen(0, 0),
            Point::screen(3, 0),
        );
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "simple search with history" (screen.zig:867)
    fn simple_search_with_history() {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"Fizz\r\n");
        grow_to_pages(&mut stream, 3, b"\r\n");
        append_blank_rows(&mut stream, 2);
        stream.next_slice(b"hello.");

        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        assert!(search.active_results.is_empty());
        let matches = search.matches();
        assert_eq!(matches.len(), 1);
        assert_match(
            &matches[0],
            stream.handler.active_screen(),
            Point::screen(0, 0),
            Point::screen(3, 0),
        );
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "reload active with history change" (screen.zig:908)
    fn reload_active_with_history_change() {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"Fizz\r\n");
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        assert_eq!(search.matches_len(), 1);

        grow_to_pages(&mut stream, 2, b"\r\n");
        append_blank_rows(&mut stream, 2);
        stream.next_slice(b"2Fizz");
        search
            .reload_active(stream.handler.active_screen_mut())
            .unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        let matches = search.matches();
        assert_eq!(matches.len(), 2);
        assert_match(
            &matches[1],
            stream.handler.active_screen(),
            Point::screen(0, 0),
            Point::screen(3, 0),
        );
        assert_match(
            &matches[0],
            stream.handler.active_screen(),
            Point::active(1, 1),
            Point::active(4, 1),
        );

        stream.handler.full_reset();
        stream.next_slice(b"WeFizzing");
        search
            .reload_active(stream.handler.active_screen_mut())
            .unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        let matches = search.matches();
        assert_eq!(matches.len(), 1);
        assert_match(
            &matches[0],
            stream.handler.active_screen(),
            Point::active(2, 0),
            Point::active(5, 0),
        );
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "active change contents" (screen.zig:994)
    fn active_change_contents() {
        let mut stream = terminal_stream(10, 5, usize::MAX);
        stream.next_slice(b"Fuzz\r\nBuzz\r\nFizz\r\nBang");
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        assert_eq!(search.active_results.len(), 1);

        stream.next_slice(b"\x1b[2J\x1b[HBang\r\nFizz\r\nHello!");
        search
            .reload_active(stream.handler.active_screen_mut())
            .unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        let matches = search.matches();
        assert_eq!(matches.len(), 1);
        assert_match(
            &matches[0],
            stream.handler.active_screen(),
            Point::screen(0, 1),
            Point::screen(3, 1),
        );
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "select next" (screen.zig:1034)
    fn select_next() {
        let mut stream = two_match_stream();
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        assert!(search.selected_match().is_none());
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();

        assert!(search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap());
        assert_match(
            search.selected_match().unwrap(),
            stream.handler.active_screen(),
            Point::screen(0, 2),
            Point::screen(3, 2),
        );
        assert!(search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap());
        assert_match(
            search.selected_match().unwrap(),
            stream.handler.active_screen(),
            Point::screen(0, 0),
            Point::screen(3, 0),
        );
        assert!(search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap());
        assert_match(
            search.selected_match().unwrap(),
            stream.handler.active_screen(),
            Point::screen(0, 2),
            Point::screen(3, 2),
        );
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "select in active changes contents completely" (screen.zig:1093)
    fn selected_active_match_tracks_changed_contents() {
        let mut stream = terminal_stream(10, 5, usize::MAX);
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap();
        search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap();
        assert_match(
            search.selected_match().unwrap(),
            stream.handler.active_screen(),
            Point::screen(0, 0),
            Point::screen(3, 0),
        );

        stream.next_slice(b"\x1b[2J\x1b[HFuzz\r\nFizz\r\nHello!");
        search
            .reload_active(stream.handler.active_screen_mut())
            .unwrap();
        assert_match(
            search.selected_match().unwrap(),
            stream.handler.active_screen(),
            Point::screen(0, 1),
            Point::screen(3, 1),
        );

        stream.next_slice(b"\x1b[2J\x1b[HFuzz\r\nFizz\r\nFizz");
        search
            .reload_active(stream.handler.active_screen_mut())
            .unwrap();
        assert_match(
            search.selected_match().unwrap(),
            stream.handler.active_screen(),
            Point::screen(0, 1),
            Point::screen(3, 1),
        );
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "select into history" (screen.zig:1157)
    fn selection_in_history_survives_active_changes() {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"Fizz\r\n");
        grow_to_pages(&mut stream, 3, b"\r\n");
        append_blank_rows(&mut stream, 2);
        stream.next_slice(b"hello.");
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap();

        let assert_history_selection = |search: &ScreenSearch, stream: &Stream<Terminal>| {
            assert_match(
                search.selected_match().unwrap(),
                stream.handler.active_screen(),
                Point::screen(0, 0),
                Point::screen(3, 0),
            );
        };
        assert_history_selection(&search, &stream);
        stream.next_slice(b"\x1b[2J\x1b[Hyo yo");
        search
            .reload_active(stream.handler.active_screen_mut())
            .unwrap();
        assert_history_selection(&search, &stream);
        stream.next_slice(b"\r\nfizz\r\nfizz\r\nfizz");
        search
            .reload_active(stream.handler.active_screen_mut())
            .unwrap();
        assert_history_selection(&search, &stream);
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "select prev" (screen.zig:1229)
    fn select_prev() {
        let mut stream = two_match_stream();
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        for expected_y in [0, 2, 0] {
            assert!(search
                .select(stream.handler.active_screen_mut(), Select::Prev)
                .unwrap());
            assert_match(
                search.selected_match().unwrap(),
                stream.handler.active_screen(),
                Point::screen(0, expected_y),
                Point::screen(3, expected_y),
            );
        }
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "select prev then next" (screen.zig:1288)
    fn select_prev_then_next() {
        let mut stream = two_match_stream();
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        for (direction, expected_y) in [(Select::Next, 2), (Select::Next, 0), (Select::Prev, 2)] {
            search
                .select(stream.handler.active_screen_mut(), direction)
                .unwrap();
            assert_match(
                search.selected_match().unwrap(),
                stream.handler.active_screen(),
                Point::screen(0, expected_y),
                Point::screen(3, expected_y),
            );
        }
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "select prev with history" (screen.zig:1332)
    fn select_prev_with_history() {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"Fizz\r\n");
        grow_to_pages(&mut stream, 3, b"\r\n");
        append_blank_rows(&mut stream, 2);
        stream.next_slice(b"Fizz.");
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        search
            .select(stream.handler.active_screen_mut(), Select::Prev)
            .unwrap();
        assert_match(
            search.selected_match().unwrap(),
            stream.handler.active_screen(),
            Point::screen(0, 0),
            Point::screen(3, 0),
        );
        search
            .select(stream.handler.active_screen_mut(), Select::Prev)
            .unwrap();
        assert_match(
            search.selected_match().unwrap(),
            stream.handler.active_screen(),
            Point::active(0, 1),
            Point::active(3, 1),
        );
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "select prev wraps when all matches are in history" (screen.zig:1383)
    fn select_prev_wraps_when_all_matches_are_in_history() {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"Fizz\r\n");
        grow_to_pages(&mut stream, 3, b"\r\n");
        append_blank_rows(&mut stream, 2);
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        assert!(search.active_results.is_empty());
        search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap();
        search
            .select(stream.handler.active_screen_mut(), Select::Prev)
            .unwrap();
        assert!(search.selected_match().is_some());
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "select after all matches disappear drops the selection" (screen.zig:1417)
    fn select_after_all_matches_disappear_drops_the_selection() {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"Fizz");
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap();
        stream.next_slice(b"\x1b[1;1H    ");
        assert!(!search
            .select(stream.handler.active_screen_mut(), Select::Prev)
            .unwrap());
        assert!(search.selected_match().is_none());
        assert_eq!(search.matches_len(), 0);
        search.deinit(stream.handler.active_screen_mut());
    }

    #[test]
    // ghostty: "screen search no scrollback has no history" (screen.zig:1449)
    fn no_scrollback_screen_has_no_history_matches() {
        let mut stream = terminal_stream(10, 2, 0);
        // Rust's lower terminal layer does not yet implement Ghostty's
        // alternate-screen CSI 22 J scroll-complete behavior. Scrolling the
        // match out with max_scrollback=0 establishes the same search state.
        stream.next_slice(b"Fizz\r\nhello\r\nworld");
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"Fizz").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        assert!(search.active_results.is_empty());
        assert!(search.matches().is_empty());
        search.deinit(stream.handler.active_screen_mut());
    }

    // The allocation-failure-only tests at screen.zig:1483 and screen.zig:1529
    // are intentionally not ported. Rust's Vec allocation is infallible at this
    // layer, so neither injected cleanup path exists to exercise.

    #[test]
    // ghostty: "select after clearing scrollback" (screen.zig:1576)
    fn select_after_clearing_scrollback() {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"error\r\n");
        grow_to_pages(&mut stream, 3, b"error\r\n");
        append_blank_rows(&mut stream, 2);
        stream.next_slice(b"error.");
        let mut search = ScreenSearch::new(stream.handler.active_screen_mut(), b"error").unwrap();
        search
            .search_all(stream.handler.active_screen_mut())
            .unwrap();
        assert!(!search.history_results.is_empty());
        assert!(!search.active_results.is_empty());
        search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap();
        stream
            .handler
            .erase_display(EraseDisplay::Scrollback, false);
        let _ = search
            .select(stream.handler.active_screen_mut(), Select::Next)
            .unwrap();
        let _ = search
            .select(stream.handler.active_screen_mut(), Select::Prev)
            .unwrap();
        search.deinit(stream.handler.active_screen_mut());
    }

    fn terminal_stream(cols: u16, rows: u16, max_scrollback: usize) -> Stream<Terminal> {
        Stream::new(Terminal::new(TerminalOptions {
            cols,
            rows,
            max_scrollback,
            ..TerminalOptions::default()
        }))
    }

    fn two_match_stream() -> Stream<Terminal> {
        let mut stream = terminal_stream(10, 2, usize::MAX);
        stream.next_slice(b"Fizz\r\nBuzz\r\nFizz\r\nBang");
        stream
    }

    fn grow_to_pages(stream: &mut Stream<Terminal>, target: usize, input: &[u8]) {
        while stream.handler.active_screen().pages.total_pages() < target {
            stream.next_slice(input);
        }
    }

    fn append_blank_rows(stream: &mut Stream<Terminal>, count: usize) {
        for _ in 0..count {
            stream.next_slice(b"\r\n");
        }
    }

    fn assert_match(
        flattened: &crate::highlight::Flattened,
        screen: &crate::screen::Screen,
        start: Point,
        end: Point,
    ) {
        let untracked = flattened_untracked(flattened).unwrap();
        assert_eq!(
            screen.pages.point_from_pin(start.tag(), untracked.start),
            Some(start)
        );
        assert_eq!(
            screen.pages.point_from_pin(end.tag(), untracked.end),
            Some(end)
        );
    }
}
