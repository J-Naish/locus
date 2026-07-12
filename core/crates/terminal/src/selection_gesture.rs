//! Mouse selection gesture state.
//!
//! Rust port of Ghostty's `terminal/SelectionGesture.zig` adapted to Rust's
//! tracked-pin slab instead of mutable `*Pin` pointers.

use crate::page_list::{Pin, PinId, Scroll};
use crate::point::{Coordinate, Point};
use crate::screen::SelectLineOptions;
use crate::screen_set::{ScreenKey, ScreenSet};
use crate::selection::Selection;
use crate::size::CellCountInt;
use crate::terminal::Terminal;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Autoscroll {
    #[default]
    None,
    Up,
    Down,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Behavior {
    #[default]
    Cell,
    Word,
    Line,
    Output,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Time(pub u64);

impl Time {
    fn elapsed_since(self, other: Self) -> u64 {
        self.0.saturating_sub(other.0)
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Geometry {
    pub columns: CellCountInt,
    pub cell_width: f64,
    pub padding_left: f64,
    pub screen_height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Press<'a> {
    pub time: Option<Time>,
    pub pin: Pin,
    pub xpos: f64,
    pub ypos: f64,
    pub max_distance: f64,
    pub repeat_interval: u64,
    pub word_boundary_codepoints: &'a [char],
    pub behaviors: &'a [Behavior],
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Drag<'a> {
    pub pin: Option<Pin>,
    pub xpos: f64,
    pub ypos: f64,
    pub rectangle: bool,
    pub word_boundary_codepoints: &'a [char],
    pub geometry: Geometry,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AutoscrollTick<'a> {
    pub viewport: Coordinate,
    pub xpos: f64,
    pub ypos: f64,
    pub rectangle: bool,
    pub word_boundary_codepoints: &'a [char],
    pub geometry: Geometry,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeepPress<'a> {
    pub pin: Pin,
    pub word_boundary_codepoints: &'a [char],
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Release {
    pub pin: Option<Pin>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SelectionGesture {
    left_click_pin: Option<PinId>,
    left_click_screen: Option<ScreenKey>,
    generation: usize,
    count: u8,
    time: Option<Time>,
    behavior: Behavior,
    xpos: f64,
    ypos: f64,
    dragged: bool,
    autoscroll: Autoscroll,
}

impl Default for SelectionGesture {
    fn default() -> Self {
        Self {
            left_click_pin: None,
            left_click_screen: None,
            generation: 0,
            count: 0,
            time: None,
            behavior: Behavior::Cell,
            xpos: 0.0,
            ypos: 0.0,
            dragged: false,
            autoscroll: Autoscroll::None,
        }
    }
}

impl SelectionGesture {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn press(&mut self, terminal: &mut Terminal, press: Press<'_>) -> Option<Selection> {
        if !self.press_repeat(terminal, &press) {
            self.press_initial(terminal, &press);
        }
        self.press_selection(terminal, press.pin, press.word_boundary_codepoints)
    }

    pub fn drag(&mut self, terminal: &mut Terminal, drag: Drag<'_>) -> Option<Selection> {
        let click = self.validated_left_click_pin(&terminal.screens)?;
        let pin = drag.pin?;
        self.autoscroll = autoscroll_from_y(drag.ypos, drag.geometry.screen_height);
        let screen = terminal.screens.get(self.left_click_screen?)?;
        let selection = match self.behavior {
            Behavior::Cell => drag_selection(
                &screen.pages,
                click,
                pin,
                self.xpos,
                drag.xpos,
                drag.rectangle,
                drag.geometry,
            ),
            Behavior::Word => {
                word_drag_selection(screen, click, pin, drag.word_boundary_codepoints)
            }
            Behavior::Line => line_drag_selection(screen, click, pin),
            Behavior::Output => output_drag_selection(screen, click, pin),
        };
        self.dragged = self.dragged
            || !click.eql(pin)
            || (self.behavior == Behavior::Cell && selection.is_some());
        terminal.active_screen_mut().select(selection);
        selection
    }

    pub fn autoscroll_tick(
        &mut self,
        terminal: &mut Terminal,
        tick: AutoscrollTick<'_>,
    ) -> Option<Selection> {
        if self.count == 0 {
            debug_assert_eq!(self.autoscroll, Autoscroll::None);
            return None;
        }
        let delta = match self.autoscroll {
            Autoscroll::None => return None,
            Autoscroll::Up => -1,
            Autoscroll::Down => 1,
        };
        // ghostty: SelectionGesture.zig:478-484. A stale anchor cancels the
        // timer-driven gesture instead of continuing to scroll forever.
        if self.validated_left_click_pin(&terminal.screens).is_none() {
            self.reset(terminal);
            return None;
        }
        terminal.scroll_viewport(Scroll::DeltaRow(delta));
        let pin = terminal
            .active_screen()
            .pages
            .pin(Point::viewport(tick.viewport.x, tick.viewport.y))?;
        self.drag(
            terminal,
            Drag {
                pin: Some(pin),
                xpos: tick.xpos,
                ypos: tick.ypos,
                rectangle: tick.rectangle,
                word_boundary_codepoints: tick.word_boundary_codepoints,
                geometry: tick.geometry,
            },
        )
    }

    pub fn deep_press(
        &mut self,
        terminal: &mut Terminal,
        press: DeepPress<'_>,
    ) -> Option<Selection> {
        let selection = terminal
            .active_screen()
            .select_word(press.pin, press.word_boundary_codepoints)?;
        self.reset(terminal);
        self.dragged = true;
        terminal.active_screen_mut().select(Some(selection));
        Some(selection)
    }

    pub fn release(&mut self, terminal: &mut Terminal, release: Release) {
        // ghostty: SelectionGesture.zig:564-572
        if self.count == 0 {
            debug_assert_eq!(self.autoscroll, Autoscroll::None);
            return;
        }
        self.autoscroll = Autoscroll::None;
        if let Some(click) = self.validated_left_click_pin(&terminal.screens) {
            if release.pin.map(|pin| !pin.eql(click)).unwrap_or(true) {
                self.dragged = true;
            }
        } else {
            self.dragged = true;
        }
    }

    pub fn dragged(&self) -> bool {
        self.dragged
    }

    pub fn count(&self) -> u8 {
        self.count
    }

    pub fn set_autoscroll(&mut self, autoscroll: Autoscroll) {
        self.autoscroll = autoscroll;
    }

    fn press_initial(&mut self, terminal: &mut Terminal, press: &Press<'_>) {
        self.reset(terminal);
        let key = terminal.screens.active_key();
        let generation = terminal.screens.generation(key);
        let screen = terminal.active_screen_mut();
        let id = screen.pages.track_pin(press.pin);
        self.left_click_pin = Some(id);
        self.left_click_screen = Some(key);
        self.generation = generation;
        self.count = 1;
        self.time = press.time;
        self.behavior = behavior_for_count(self.count, press.behaviors);
        self.xpos = press.xpos;
        self.ypos = press.ypos;
        self.dragged = false;
    }

    fn press_repeat(&mut self, terminal: &mut Terminal, press: &Press<'_>) -> bool {
        let Some(last) = self.time else {
            return false;
        };
        let Some(now) = press.time else {
            return false;
        };
        if now.elapsed_since(last) > press.repeat_interval {
            return false;
        }
        if distance(self.xpos, self.ypos, press.xpos, press.ypos) > press.max_distance {
            return false;
        }
        let Some(key) = self.left_click_screen else {
            return false;
        };
        if terminal.screens.active_key() != key
            || terminal.screens.generation(key) != self.generation
        {
            return false;
        }
        if self.left_click_pin.is_none() {
            return false;
        }
        // ghostty: SelectionGesture.zig:657-664. Repeated clicks update the
        // click sequence while preserving its original tracked anchor.
        self.count = self.count.saturating_add(1).min(3);
        self.time = press.time;
        self.behavior = behavior_for_count(self.count, press.behaviors);
        self.dragged = false;
        self.autoscroll = Autoscroll::None;
        true
    }

    fn press_selection(
        &mut self,
        terminal: &mut Terminal,
        pin: Pin,
        word_boundary_codepoints: &[char],
    ) -> Option<Selection> {
        let selection = match self.behavior {
            Behavior::Cell => None,
            Behavior::Word => terminal
                .active_screen()
                .select_word(pin, word_boundary_codepoints),
            Behavior::Line => terminal
                .active_screen()
                .select_line(SelectLineOptions::new(pin)),
            Behavior::Output => terminal.active_screen().select_output(pin),
        };
        self.apply_press_selection(terminal, selection)
    }

    fn apply_press_selection(
        &mut self,
        terminal: &mut Terminal,
        selection: Option<Selection>,
    ) -> Option<Selection> {
        if let Some(selection) = selection {
            terminal.active_screen_mut().select(Some(selection));
            return Some(selection);
        }
        // Ghostty returns the press selection for the surface to apply. This
        // Rust port applies it here; a plain single click clears an existing
        // selection, while double/triple-click misses leave the prior state.
        if self.count == 1 && terminal.active_screen().selection.is_some() {
            terminal.active_screen_mut().select(None);
        }
        None
    }

    fn validated_left_click_pin(&self, screens: &ScreenSet) -> Option<Pin> {
        let key = self.left_click_screen?;
        // ghostty: SelectionGesture.zig:219-227. A tracked pin is meaningful
        // only while its originating screen is the active screen instance.
        if screens.active_key() != key {
            return None;
        }
        if screens.generation(key) != self.generation {
            return None;
        }
        screens.get(key)?.pages.tracked_pin(self.left_click_pin?)
    }

    pub fn reset(&mut self, terminal: &mut Terminal) {
        if let (Some(key), Some(id)) = (self.left_click_screen, self.left_click_pin) {
            // ghostty: SelectionGesture.zig:179-185. Use the originating
            // screen, but never untrack through a recycled screen generation.
            if terminal.screens.generation(key) == self.generation {
                if let Some(screen) = terminal.screens.get_mut(key) {
                    let _ = screen.pages.untrack_pin(id);
                }
            }
        }
        *self = Self::default();
    }
}

fn behavior_for_count(count: u8, behaviors: &[Behavior]) -> Behavior {
    let index = count.saturating_sub(1) as usize;
    behaviors
        .get(index)
        .copied()
        .unwrap_or_else(|| behaviors.last().copied().unwrap_or(Behavior::Cell))
}

fn distance(x1: f64, y1: f64, x2: f64, y2: f64) -> f64 {
    let dx = x1 - x2;
    let dy = y1 - y2;
    (dx * dx + dy * dy).sqrt()
}

fn autoscroll_from_y(y: f64, height: f64) -> Autoscroll {
    // ghostty: SelectionGesture.zig:161-164,378-384. Keep a one-pixel
    // activation buffer so fullscreen-edge drags still autoscroll.
    const AUTOSCROLL_BUFFER: f64 = 1.0;
    if y <= AUTOSCROLL_BUFFER {
        Autoscroll::Up
    } else if y > height - AUTOSCROLL_BUFFER {
        Autoscroll::Down
    } else {
        Autoscroll::None
    }
}

fn drag_selection(
    pages: &crate::page_list::PageList,
    click: Pin,
    drag: Pin,
    click_xpos: f64,
    drag_xpos: f64,
    rectangle: bool,
    geometry: Geometry,
) -> Option<Selection> {
    let threshold = (geometry.cell_width * 0.6).round();
    let max_x = f64::from(geometry.columns) * geometry.cell_width - 1.0;
    let click_frac =
        ((click_xpos - geometry.padding_left).max(0.0).min(max_x)) % geometry.cell_width;
    let drag_frac = ((drag_xpos - geometry.padding_left).max(0.0).min(max_x)) % geometry.cell_width;
    let same_pin = drag.eql(click);
    let end_before_start = if same_pin {
        drag_frac < click_frac
    } else if rectangle {
        drag.x < click.x || (drag.x == click.x && drag_frac < click_frac)
    } else {
        pages.pin_before(drag, click)
    };
    let include_click = if end_before_start {
        click_frac >= threshold
    } else {
        click_frac < threshold
    };
    let include_drag = if end_before_start {
        drag_frac < threshold
    } else {
        drag_frac >= threshold
    };

    let mut start = click;
    let mut end = drag;
    if end_before_start {
        if !include_drag {
            end = if rectangle {
                end.right_clamp(pages, 1)
            } else {
                end.right_wrap(pages, 1).unwrap_or(drag)
            };
        }
        if !include_click {
            start = if rectangle {
                start.left_clamp(1)
            } else {
                start.left_wrap(pages, 1).unwrap_or(click)
            };
        }
    } else {
        if !include_click {
            start = if rectangle {
                start.right_clamp(pages, 1)
            } else {
                start.right_wrap(pages, 1).unwrap_or(click)
            };
        }
        if !include_drag {
            end = if rectangle {
                end.left_clamp(1)
            } else {
                end.left_wrap(pages, 1).unwrap_or(drag)
            };
        }
    }
    if (!include_click && same_pin)
        || (!include_click && rectangle && click.x == drag.x)
        || (!include_click && end.eql(click))
        || (!include_click && rectangle && end.x == click.x)
        || (!include_drag && start.eql(drag))
        || (!include_drag && rectangle && start.x == drag.x)
    {
        return None;
    }
    Some(Selection::new(start, end, rectangle))
}

fn word_drag_selection(
    screen: &crate::screen::Screen,
    click: Pin,
    pin: Pin,
    word_boundary_codepoints: &[char],
) -> Option<Selection> {
    let word_start = screen.select_word_between(click, pin, word_boundary_codepoints)?;
    let word_current = screen.select_word_between(pin, click, word_boundary_codepoints)?;
    if screen.pages.pin_before(pin, click) {
        Some(Selection::new(
            word_current.start(&screen.pages)?,
            word_start.end(&screen.pages)?,
            false,
        ))
    } else {
        Some(Selection::new(
            word_start.start(&screen.pages)?,
            word_current.end(&screen.pages)?,
            false,
        ))
    }
}

fn line_drag_selection(screen: &crate::screen::Screen, click: Pin, pin: Pin) -> Option<Selection> {
    let line = screen.select_line(SelectLineOptions::new(pin))?;
    let selection = screen
        .select_line(SelectLineOptions::new(click))
        .or_else(|| {
            screen.select_line(SelectLineOptions {
                whitespace: None,
                ..SelectLineOptions::new(click)
            })
        })?;
    if screen.pages.pin_before(pin, click) {
        Some(Selection::new(
            line.start(&screen.pages)?,
            selection.end(&screen.pages)?,
            false,
        ))
    } else {
        Some(Selection::new(
            selection.start(&screen.pages)?,
            line.end(&screen.pages)?,
            false,
        ))
    }
}

fn output_drag_selection(
    screen: &crate::screen::Screen,
    click: Pin,
    pin: Pin,
) -> Option<Selection> {
    let selection = screen.select_output(click)?;
    let Some(current) = screen.select_output(pin) else {
        return Some(selection);
    };
    if screen.pages.pin_before(pin, click) {
        Some(Selection::new(
            current.start(&screen.pages)?,
            selection.end(&screen.pages)?,
            false,
        ))
    } else {
        Some(Selection::new(
            selection.start(&screen.pages)?,
            current.end(&screen.pages)?,
            false,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page::Cell;
    use crate::page::SemanticContent;
    use crate::point::Point;
    use crate::point::Tag;
    use crate::selection_codepoints::DEFAULT_WORD_BOUNDARIES;
    use crate::terminal::{Options, Terminal};

    fn terminal_with_text(cols: CellCountInt, rows: CellCountInt, text: &str) -> Terminal {
        let mut terminal = Terminal::new(Options {
            cols,
            rows,
            max_scrollback: 1024,
            ..Options::default()
        });
        terminal.print_string(text);
        terminal
    }

    fn press_at(terminal: &Terminal, x: CellCountInt, y: u32, time: u64) -> Press<'static> {
        press_at_with_xpos(terminal, x, y, time, f64::from(x) * 10.0)
    }

    fn press_at_with_xpos(
        terminal: &Terminal,
        x: CellCountInt,
        y: u32,
        time: u64,
        xpos: f64,
    ) -> Press<'static> {
        Press {
            time: Some(Time(time)),
            pin: screen_pin(terminal, x, y),
            xpos,
            ypos: f64::from(y) * 20.0,
            max_distance: 4.0,
            repeat_interval: 500,
            word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
            behaviors: &[Behavior::Cell, Behavior::Word, Behavior::Line],
        }
    }

    fn press_gesture(
        gesture: &mut SelectionGesture,
        terminal: &mut Terminal,
        x: CellCountInt,
        y: u32,
        time: u64,
    ) -> Option<Selection> {
        let press = press_at(terminal, x, y, time);
        gesture.press(terminal, press)
    }

    fn screen_pin(terminal: &Terminal, x: CellCountInt, y: u32) -> Pin {
        terminal
            .active_screen()
            .pages
            .pin(Point::screen(x, y))
            .unwrap()
    }

    fn test_geometry() -> Geometry {
        Geometry {
            columns: 10,
            cell_width: 10.0,
            padding_left: 5.0,
            screen_height: 80.0,
        }
    }

    fn selection_points(
        terminal: &Terminal,
        selection: Selection,
    ) -> (CellCountInt, u32, CellCountInt, u32) {
        selection_points_from_pages(&terminal.active_screen().pages, selection)
    }

    fn selection_points_from_pages(
        pages: &crate::page_list::PageList,
        selection: Selection,
    ) -> (CellCountInt, u32, CellCountInt, u32) {
        let start = pages
            .point_from_pin(
                Tag::Screen,
                selection.start(pages).expect("selection start"),
            )
            .expect("start point")
            .coord();
        let end = pages
            .point_from_pin(Tag::Screen, selection.end(pages).expect("selection end"))
            .expect("end point")
            .coord();
        (start.x, start.y, end.x, end.y)
    }

    fn drag_selection_case(
        click_x: f64,
        click_y: u32,
        drag_x: f64,
        drag_y: u32,
        rectangle: bool,
    ) -> Option<(CellCountInt, u32, CellCountInt, u32)> {
        let terminal = terminal_with_text(10, 5, "");
        let pages = &terminal.active_screen().pages;
        let click = screen_pin(&terminal, click_x.floor() as CellCountInt, click_y);
        let drag = screen_pin(&terminal, drag_x.floor() as CellCountInt, drag_y);
        let click_xpos = (click_x * 10.0).floor() + 5.0;
        let drag_xpos = (drag_x * 10.0).floor() + 5.0;
        drag_selection(
            pages,
            click,
            drag,
            click_xpos,
            drag_xpos,
            rectangle,
            test_geometry(),
        )
        .map(|selection| selection_points_from_pages(pages, selection))
    }

    fn assert_press_result(
        result: Option<Selection>,
        terminal: &Terminal,
        expected: Option<(CellCountInt, u32, CellCountInt, u32)>,
    ) {
        assert_eq!(
            result.map(|selection| selection_points(terminal, selection)),
            expected
        );
    }

    fn assert_selection_result(
        result: Option<Selection>,
        terminal: &Terminal,
        expected: (CellCountInt, u32, CellCountInt, u32),
    ) {
        assert_eq!(
            result.map(|selection| selection_points(terminal, selection)),
            Some(expected)
        );
    }

    #[test]
    fn selection_gesture_drag_selection_logic() {
        // ghostty: "SelectionGesture drag selection logic" (SelectionGesture.zig:1107)
        let cases = [
            (3.0, 3, 3.9, 3, Some((3, 3, 3, 3))),
            (3.0, 3, 5.9, 3, Some((3, 3, 5, 3))),
            (3.0, 3, 5.0, 3, Some((3, 3, 4, 3))),
            (3.9, 3, 5.9, 3, Some((4, 3, 5, 3))),
            (3.9, 3, 5.0, 3, Some((4, 3, 4, 3))),
            (3.0, 3, 3.1, 3, None),
            (3.8, 3, 3.9, 3, None),
            (3.9, 3, 4.0, 3, None),
            (3.9, 3, 3.0, 3, Some((3, 3, 3, 3))),
            (5.9, 3, 3.0, 3, Some((5, 3, 3, 3))),
            (5.9, 3, 3.9, 3, Some((5, 3, 4, 3))),
            (5.0, 3, 3.0, 3, Some((4, 3, 3, 3))),
            (5.0, 3, 3.9, 3, Some((4, 3, 4, 3))),
            (3.1, 3, 3.0, 3, None),
            (3.9, 3, 3.8, 3, None),
            (4.0, 3, 3.9, 3, None),
            (9.9, 2, 0.0, 4, Some((0, 3, 9, 3))),
            (0.0, 4, 9.9, 2, Some((9, 3, 0, 3))),
        ];
        for (click_x, click_y, drag_x, drag_y, expected) in cases {
            assert_eq!(
                drag_selection_case(click_x, click_y, drag_x, drag_y, false),
                expected,
                "{click_x},{click_y} -> {drag_x},{drag_y}"
            );
        }
    }

    #[test]
    fn selection_gesture_rectangle_drag_selection_logic() {
        // ghostty: "SelectionGesture rectangle drag selection logic" (SelectionGesture.zig:1251)
        let cases = [
            (3.0, 2, 3.9, 4, Some((3, 2, 3, 4))),
            (3.0, 2, 5.9, 4, Some((3, 2, 5, 4))),
            (3.0, 2, 5.0, 4, Some((3, 2, 4, 4))),
            (3.9, 2, 5.9, 4, Some((4, 2, 5, 4))),
            (3.9, 2, 5.0, 4, Some((4, 2, 4, 4))),
            (3.0, 2, 3.1, 4, None),
            (3.8, 2, 3.9, 4, None),
            (3.9, 2, 4.0, 4, None),
            (3.9, 2, 3.0, 4, Some((3, 2, 3, 4))),
            (5.9, 2, 3.0, 4, Some((5, 2, 3, 4))),
            (5.9, 2, 3.9, 4, Some((5, 2, 4, 4))),
            (5.0, 2, 3.0, 4, Some((4, 2, 3, 4))),
            (5.0, 2, 3.9, 4, Some((4, 2, 4, 4))),
            (3.1, 2, 3.0, 4, None),
            (3.9, 2, 3.8, 4, None),
            (4.0, 2, 3.9, 4, None),
            (9.9, 2, 0.0, 4, Some((9, 2, 0, 4))),
            (0.0, 4, 9.9, 2, Some((0, 4, 9, 2))),
        ];
        for (click_x, click_y, drag_x, drag_y, expected) in cases {
            assert_eq!(
                drag_selection_case(click_x, click_y, drag_x, drag_y, true),
                expected,
                "{click_x},{click_y} -> {drag_x},{drag_y}"
            );
        }
    }

    #[test]
    fn selection_gesture_press_records_initial_click() {
        // ghostty: "SelectionGesture press records initial click" (SelectionGesture.zig:1395)
        let mut terminal = terminal_with_text(20, 5, "alpha beta");
        let mut gesture = SelectionGesture::new();
        let result = press_gesture(&mut gesture, &mut terminal, 1, 0, 1);
        assert_press_result(result, &terminal, None);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_press_returns_standard_click_selections() {
        // ghostty: "SelectionGesture press returns standard click selections" (SelectionGesture.zig:1412)
        let mut terminal = terminal_with_text(20, 5, "alpha beta\none two");
        let mut gesture = SelectionGesture::new();

        let first = press_gesture(&mut gesture, &mut terminal, 1, 0, 1);
        assert_press_result(first, &terminal, None);

        let second = press_gesture(&mut gesture, &mut terminal, 1, 0, 2);
        assert_press_result(second, &terminal, Some((0, 0, 4, 0)));

        let third = press_gesture(&mut gesture, &mut terminal, 1, 0, 3);
        assert_press_result(third, &terminal, Some((0, 0, 9, 0)));
    }

    #[test]
    fn selection_gesture_press_behaviors_choose_press_and_drag_behavior() {
        // ghostty: "SelectionGesture press behaviors choose press and drag behavior" (SelectionGesture.zig:1439)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut press = press_at(&terminal, 0, 0, 1);
        press.behaviors = &[Behavior::Word, Behavior::Line];
        let mut gesture = SelectionGesture::new();
        let selection = gesture.press(&mut terminal, press);
        assert_selection_result(selection, &terminal, (0, 0, 4, 0));
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_output_behavior_selects_and_drags_semantic_output() {
        // ghostty: "SelectionGesture output behavior selects and drags semantic output" (SelectionGesture.zig:1471)
        let mut terminal = Terminal::new(Options {
            cols: 10,
            rows: 6,
            max_scrollback: 1024,
            ..Options::default()
        });
        terminal
            .active_screen_mut()
            .cursor_set_semantic_content(SemanticContent::Output);
        terminal.print_string("out1\n");
        terminal
            .active_screen_mut()
            .cursor_set_semantic_content(SemanticContent::Prompt);
        terminal.print_string("$ ");
        terminal
            .active_screen_mut()
            .cursor_set_semantic_content(SemanticContent::Input);
        terminal.print_string("cmd\n");
        terminal
            .active_screen_mut()
            .cursor_set_semantic_content(SemanticContent::Output);
        terminal.print_string("out2");
        for (y, start_x) in [(0, 4), (2, 4)] {
            for x in start_x..10 {
                let mut cell = Cell::new('\0');
                cell.set_semantic_content(SemanticContent::Input);
                assert!(terminal
                    .active_screen_mut()
                    .pages
                    .set_cell(Point::screen(x, y), cell));
            }
        }

        let mut press = press_at(&terminal, 1, 0, 1);
        press.behaviors = &[Behavior::Output];
        let mut gesture = SelectionGesture::new();
        let first = gesture.press(&mut terminal, press);
        assert_press_result(first, &terminal, Some((0, 0, 3, 0)));

        let drag_pin = screen_pin(&terminal, 1, 2);
        let drag = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 10.0,
                ypos: 40.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: test_geometry(),
            },
        );
        assert_selection_result(drag, &terminal, (0, 0, 3, 2));
    }

    #[test]
    fn selection_gesture_drag_returns_selection_and_records_autoscroll() {
        // ghostty: "SelectionGesture drag returns selection and records autoscroll" (SelectionGesture.zig:1507)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();
        let press = press_at(&terminal, 0, 0, 1);
        let _ = gesture.press(&mut terminal, press);
        let drag_pin = screen_pin(&terminal, 2, 0);
        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 31.0,
                ypos: 100.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: test_geometry(),
            },
        );
        assert_selection_result(selection, &terminal, (0, 0, 2, 0));
        assert_eq!(gesture.autoscroll, Autoscroll::Down);
    }

    #[test]
    fn selection_gesture_release_clears_autoscroll_and_records_drag() {
        // ghostty: "SelectionGesture release clears autoscroll and records drag" (SelectionGesture.zig:1535)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 0, 0, 1);
        gesture.autoscroll = Autoscroll::Down;
        let release_pin = screen_pin(&terminal, 1, 0);
        gesture.release(
            &mut terminal,
            Release {
                pin: Some(release_pin),
            },
        );
        assert_eq!(gesture.autoscroll, Autoscroll::None);
        assert!(gesture.dragged());
    }

    #[test]
    fn selection_gesture_release_with_invalidated_click_records_drag() {
        // ghostty: "SelectionGesture release with invalidated click records drag" (SelectionGesture.zig:1556)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 0, 0, 1);
        gesture.release(&mut terminal, Release { pin: None });
        assert!(gesture.dragged());
    }

    #[test]
    fn selection_gesture_same_cell_threshold_selection_records_drag() {
        // ghostty: "SelectionGesture same-cell threshold selection records drag" (SelectionGesture.zig:1577)
        let mut terminal = terminal_with_text(5, 5, "");
        let mut gesture = SelectionGesture::new();
        let press = press_at_with_xpos(&terminal, 1, 1, 1, 10.0);
        let _ = gesture.press(&mut terminal, press);
        assert!(!gesture.dragged());
        let drag_pin = screen_pin(&terminal, 1, 1);
        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 19.0,
                ypos: 50.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: Geometry {
                    padding_left: 0.0,
                    ..test_geometry()
                },
            },
        );
        assert_selection_result(selection, &terminal, (1, 1, 1, 1));
        assert!(gesture.dragged());
    }

    #[test]
    fn selection_gesture_drag_without_press_returns_null() {
        // ghostty: "SelectionGesture drag without press returns null" (SelectionGesture.zig:1598)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();
        let drag_pin = screen_pin(&terminal, 0, 0);
        let result = gesture
            .drag(
                &mut terminal,
                Drag {
                    pin: Some(drag_pin),
                    xpos: 0.0,
                    ypos: 0.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .map(|selection| selection_points(&terminal, selection));
        assert_eq!(result, None);
        assert_eq!(terminal.active_screen().selection, None);
    }

    #[test]
    fn selection_gesture_cell_press_clears_existing_selection() {
        // port-added: Ghostty applies a null cell press by clearing an existing
        // single-click selection in the surface.
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let start = screen_pin(&terminal, 0, 0);
        let end = screen_pin(&terminal, 4, 0);
        terminal
            .active_screen_mut()
            .select(Some(Selection::new(start, end, false)));
        let mut gesture = SelectionGesture::new();
        let result = press_gesture(&mut gesture, &mut terminal, 1, 0, 1);
        assert_press_result(result, &terminal, None);
        assert_eq!(terminal.active_screen().selection, None);
    }

    #[test]
    fn selection_gesture_drag_collapse_clears_existing_selection() {
        // port-added: a drag that collapses to null still applies the null
        // selection to the active screen.
        let mut terminal = terminal_with_text(10, 5, "");
        let mut gesture = SelectionGesture::new();
        let press = press_at_with_xpos(&terminal, 3, 3, 1, 35.0);
        let _ = gesture.press(&mut terminal, press);
        let existing_start = screen_pin(&terminal, 0, 0);
        let existing_end = screen_pin(&terminal, 2, 0);
        terminal.active_screen_mut().select(Some(Selection::new(
            existing_start,
            existing_end,
            false,
        )));
        let drag_pin = screen_pin(&terminal, 3, 3);
        let result = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 36.0,
                ypos: 60.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: test_geometry(),
            },
        );
        assert_press_result(result, &terminal, None);
        assert_eq!(terminal.active_screen().selection, None);
    }

    #[test]
    fn selection_gesture_drag_autoscroll_edge_boundaries() {
        // ghostty: "SelectionGesture drag autoscroll edge boundaries" (SelectionGesture.zig:1609)
        assert_eq!(autoscroll_from_y(1.0, 80.0), Autoscroll::Up);
        assert_eq!(autoscroll_from_y(1.1, 80.0), Autoscroll::None);
        assert_eq!(autoscroll_from_y(79.0, 80.0), Autoscroll::None);
        assert_eq!(autoscroll_from_y(79.1, 80.0), Autoscroll::Down);
    }

    #[test]
    fn selection_gesture_autoscroll_tick_scrolls_and_continues_drag() {
        // ghostty: "SelectionGesture autoscroll tick scrolls and continues drag" (SelectionGesture.zig:1633)
        let mut terminal = terminal_with_text(5, 5, "");
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 1, 1, 1);
        gesture.autoscroll = Autoscroll::Down;
        let result = gesture
            .autoscroll_tick(
                &mut terminal,
                AutoscrollTick {
                    viewport: Coordinate { x: 3, y: 2 },
                    xpos: 39.0,
                    ypos: 100.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: Geometry {
                        columns: 5,
                        padding_left: 0.0,
                        screen_height: 100.0,
                        ..test_geometry()
                    },
                },
            )
            .map(|selection| selection_points(&terminal, selection));
        assert_eq!(result, Some((1, 1, 3, 2)));
    }

    #[test]
    fn selection_gesture_autoscroll_tick_resolves_drag_pin_after_scrolling() {
        // ghostty: "SelectionGesture autoscroll tick resolves drag pin after scrolling" (SelectionGesture.zig:1657)
        let mut terminal = terminal_with_text(5, 3, "1111\n2222\n3333\n4444\n5555");
        terminal.scroll_viewport(Scroll::DeltaRow(-2));
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 1, 1, 1);
        gesture.autoscroll = Autoscroll::Down;
        let viewport = Coordinate { x: 3, y: 2 };
        let pre_scroll_pin = terminal
            .active_screen()
            .pages
            .pin(Point::viewport(viewport.x, viewport.y))
            .expect("pre-scroll viewport pin");
        let selection = gesture
            .autoscroll_tick(
                &mut terminal,
                AutoscrollTick {
                    viewport,
                    xpos: 39.0,
                    ypos: 100.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: Geometry {
                        columns: 5,
                        padding_left: 0.0,
                        screen_height: 100.0,
                        ..test_geometry()
                    },
                },
            )
            .expect("autoscroll selection");
        let post_scroll_pin = terminal
            .active_screen()
            .pages
            .pin(Point::viewport(viewport.x, viewport.y))
            .expect("post-scroll viewport pin");
        assert!(!pre_scroll_pin.eql(post_scroll_pin));
        assert_eq!(
            selection.end(&terminal.active_screen().pages),
            Some(post_scroll_pin)
        );
    }

    #[test]
    fn selection_gesture_autoscroll_tick_stops_with_invalidated_click() {
        // ghostty: "SelectionGesture autoscroll tick stops with invalidated click" (SelectionGesture.zig:1686)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 1, 1, 1);
        gesture.autoscroll = Autoscroll::Down;
        let _ = terminal.screens.get_init(ScreenKey::Alternate);
        terminal.screens.switch_to(ScreenKey::Alternate);
        let result = gesture
            .autoscroll_tick(
                &mut terminal,
                AutoscrollTick {
                    viewport: Coordinate { x: 2, y: 1 },
                    xpos: 20.0,
                    ypos: 80.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .map(|selection| selection_points(&terminal, selection));
        assert_eq!(result, None);
        assert_eq!(gesture.count(), 0);
        assert_eq!(gesture.autoscroll, Autoscroll::None);
    }

    #[test]
    fn selection_gesture_autoscroll_tick_preserves_rectangle_mode() {
        // ghostty: SelectionGesture.zig:426-496
        let mut terminal = terminal_with_text(10, 4, "one\ntwo\nthree\nfour\nfive\nsix");
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 1, 2, 1);
        gesture.autoscroll = Autoscroll::Down;

        let selection = gesture
            .autoscroll_tick(
                &mut terminal,
                AutoscrollTick {
                    viewport: Coordinate { x: 3, y: 3 },
                    xpos: 39.0,
                    ypos: 100.0,
                    rectangle: true,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .expect("rectangle autoscroll selection");

        assert!(selection.rectangle);
    }

    #[test]
    fn selection_gesture_deep_press_selects_word_and_consumes_drag() {
        // ghostty: "SelectionGesture deep press selects word and consumes drag" (SelectionGesture.zig:1711)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let pin = screen_pin(&terminal, 1, 0);
        let mut gesture = SelectionGesture::new();
        let selection = gesture
            .deep_press(
                &mut terminal,
                DeepPress {
                    pin,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                },
            )
            .unwrap();
        assert_eq!(selection_points(&terminal, selection), (0, 0, 4, 0));
        assert!(gesture.dragged());
    }

    #[test]
    fn selection_gesture_drag_with_invalidated_click_returns_null() {
        // ghostty: "SelectionGesture drag with invalidated click returns null" (SelectionGesture.zig:1743)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();
        let drag_pin = screen_pin(&terminal, 0, 0);
        let result = gesture
            .drag(
                &mut terminal,
                Drag {
                    pin: Some(drag_pin),
                    xpos: 0.0,
                    ypos: 0.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .map(|selection| selection_points(&terminal, selection));
        assert_eq!(result, None);
    }

    #[test]
    fn selection_gesture_double_click_drag_selects_by_word() {
        // ghostty: "SelectionGesture double-click drag selects by word" (SelectionGesture.zig:1767)
        let mut terminal = terminal_with_text(20, 5, "alpha beta gamma");
        let mut press = press_at(&terminal, 1, 0, 1);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        let _ = gesture.press(&mut terminal, press);
        let drag_pin = screen_pin(&terminal, 7, 0);
        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 70.0,
                ypos: 0.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: test_geometry(),
            },
        );
        assert_selection_result(selection, &terminal, (0, 0, 9, 0));
        assert_eq!(gesture.count(), 2);
    }

    #[test]
    fn selection_gesture_double_click_drag_selects_by_word_backwards() {
        // ghostty: "SelectionGesture double-click drag selects by word backwards" (SelectionGesture.zig:1790)
        let mut terminal = terminal_with_text(20, 5, "alpha beta gamma");
        let mut press = press_at(&terminal, 7, 0, 1);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        let _ = gesture.press(&mut terminal, press);
        let drag_pin = screen_pin(&terminal, 1, 0);
        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 10.0,
                ypos: 0.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: test_geometry(),
            },
        );
        assert_selection_result(selection, &terminal, (0, 0, 9, 0));
        assert_eq!(gesture.count(), 2);
    }

    #[test]
    fn selection_gesture_double_click_drag_on_empty_cell_selects_nearest_word() {
        // ghostty: "SelectionGesture double-click drag on empty cell selects nearest word" (SelectionGesture.zig:1813)
        let mut terminal = terminal_with_text(20, 5, "alpha beta");
        let mut press = press_at(&terminal, 1, 0, 1);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        let _ = gesture.press(&mut terminal, press);
        let drag_pin = screen_pin(&terminal, 15, 0);
        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 150.0,
                ypos: 0.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: Geometry {
                    columns: 20,
                    ..test_geometry()
                },
            },
        );
        assert_selection_result(selection, &terminal, (0, 0, 9, 0));
    }

    #[test]
    fn selection_gesture_triple_click_drag_selects_by_line() {
        // ghostty: "SelectionGesture triple-click drag selects by line" (SelectionGesture.zig:1836)
        let mut terminal = terminal_with_text(20, 5, "alpha beta\none two\nthree four");
        let mut press = press_at(&terminal, 1, 0, 1);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(3));
        let _ = gesture.press(&mut terminal, press);
        let drag_pin = screen_pin(&terminal, 2, 2);
        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 20.0,
                ypos: 40.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: Geometry {
                    columns: 20,
                    ..test_geometry()
                },
            },
        );
        assert_eq!(gesture.count(), 3);
        assert_selection_result(selection, &terminal, (0, 0, 9, 2));
    }

    #[test]
    fn selection_gesture_triple_click_drag_selects_by_line_backwards() {
        // ghostty: "SelectionGesture triple-click drag selects by line backwards" (SelectionGesture.zig:1858)
        let mut terminal = terminal_with_text(20, 5, "alpha beta\none two\nthree four");
        let mut press = press_at(&terminal, 2, 2, 1);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(3));
        let _ = gesture.press(&mut terminal, press);
        let drag_pin = screen_pin(&terminal, 1, 0);
        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(drag_pin),
                xpos: 10.0,
                ypos: 0.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: Geometry {
                    columns: 20,
                    ..test_geometry()
                },
            },
        );
        assert_eq!(gesture.count(), 3);
        assert_selection_result(selection, &terminal, (0, 0, 9, 2));
    }

    #[test]
    fn selection_gesture_repeat_increments_click_count() {
        // ghostty: "SelectionGesture repeat increments click count" (SelectionGesture.zig:1880)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut press = press_at(&terminal, 0, 0, 10);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(20));
        let _ = gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 2);
    }

    #[test]
    fn selection_gesture_repeat_keeps_original_anchor_and_stops_autoscroll() {
        // ghostty: "SelectionGesture repeat increments click count" (SelectionGesture.zig:1880)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();
        let mut first = press_at(&terminal, 0, 0, 10);
        first.max_distance = 100.0;
        let _ = gesture.press(&mut terminal, first);
        gesture.autoscroll = Autoscroll::Down;

        let mut repeated = press_at(&terminal, 5, 0, 20);
        repeated.max_distance = 100.0;
        let _ = gesture.press(&mut terminal, repeated);

        assert_eq!(gesture.count(), 2);
        assert_eq!(gesture.autoscroll, Autoscroll::None);
        assert_eq!(
            gesture
                .validated_left_click_pin(&terminal.screens)
                .map(|pin| pin.x),
            Some(0)
        );
    }

    #[test]
    fn selection_gesture_release_without_press_is_noop() {
        // ghostty: SelectionGesture.zig:564-572
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();

        gesture.release(&mut terminal, Release { pin: None });

        assert!(!gesture.dragged());
        assert_eq!(gesture.autoscroll, Autoscroll::None);
    }

    #[test]
    fn selection_gesture_repeat_clamps_at_triple_click() {
        // ghostty: "SelectionGesture repeat clamps at triple click" (SelectionGesture.zig:1894)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut press = press_at(&terminal, 0, 0, 10);
        let mut gesture = SelectionGesture::new();
        for time in [10, 20, 30, 40] {
            press.time = Some(Time(time));
            let _ = gesture.press(&mut terminal, press);
        }
        assert_eq!(gesture.count(), 3);
    }

    #[test]
    fn selection_gesture_null_initial_time_stays_single_click() {
        // ghostty: "SelectionGesture null initial time stays single click" (SelectionGesture.zig:1907)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut press = press_at(&terminal, 0, 0, 10);
        press.time = None;
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(20));
        let _ = gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_null_repeat_time_stays_single_click() {
        // ghostty: "SelectionGesture null repeat time stays single click" (SelectionGesture.zig:1921)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut press = press_at(&terminal, 0, 0, 10);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = None;
        let _ = gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_distant_press_resets_click_count() {
        // ghostty: "SelectionGesture distant press resets click count" (SelectionGesture.zig:1935)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut press = press_at(&terminal, 0, 0, 10);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.pin = screen_pin(&terminal, 5, 0);
        press.xpos = 50.0;
        press.time = Some(Time(20));
        let _ = gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_expired_repeat_resets_click_count() {
        // ghostty: "SelectionGesture expired repeat resets click count" (SelectionGesture.zig:1950)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut press = press_at(&terminal, 0, 0, 10);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        press.time = Some(Time(600));
        let _ = gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_screen_switch_resets_click_count() {
        // ghostty: "SelectionGesture screen switch resets click count" (SelectionGesture.zig:1968)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut press = press_at(&terminal, 0, 0, 10);
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        let _ = terminal.screens.get_init(ScreenKey::Alternate);
        terminal.screens.switch_to(ScreenKey::Alternate);
        press.pin = terminal
            .active_screen()
            .pages
            .pin(Point::screen(0, 0))
            .unwrap();
        press.time = Some(Time(20));
        let _ = gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_drag_rejects_anchor_from_inactive_screen() {
        // ghostty: "SelectionGesture screen switch resets click count" (SelectionGesture.zig:1968)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 0, 0, 10);

        let _ = terminal.screens.get_init(ScreenKey::Alternate);
        terminal.screens.switch_to(ScreenKey::Alternate);
        let alternate_pin = screen_pin(&terminal, 3, 0);
        let tracked_before = terminal.active_screen().pages.count_tracked_pins();

        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(alternate_pin),
                xpos: 30.0,
                ypos: 10.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: test_geometry(),
            },
        );

        assert_eq!(selection, None);
        assert_eq!(
            terminal.active_screen().pages.count_tracked_pins(),
            tracked_before
        );
    }

    #[test]
    fn selection_gesture_removed_screen_resets_without_untracking_stale_pin() {
        // ghostty: "SelectionGesture removed screen resets without untracking stale pin" (SelectionGesture.zig:1991)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let _ = terminal.screens.get_init(ScreenKey::Alternate);
        terminal.screens.switch_to(ScreenKey::Alternate);
        let pin = terminal
            .active_screen()
            .pages
            .pin(Point::screen(0, 0))
            .unwrap();
        let mut press = press_at(&terminal, 0, 0, 10);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        let _ = gesture.press(&mut terminal, press);
        terminal.screens.remove(ScreenKey::Alternate);
        press.pin = screen_pin(&terminal, 0, 0);
        press.time = Some(Time(20));
        let _ = gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_reset_does_not_untrack_recycled_screen_pin() {
        // ghostty: "SelectionGesture removed screen resets without untracking stale pin" (SelectionGesture.zig:1991)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let _ = terminal.screens.get_init(ScreenKey::Alternate);
        terminal.screens.switch_to(ScreenKey::Alternate);
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 0, 0, 10);

        terminal.screens.remove(ScreenKey::Alternate);
        let _ = terminal.screens.get_init(ScreenKey::Alternate);
        terminal.screens.switch_to(ScreenKey::Alternate);
        let pin = screen_pin(&terminal, 1, 0);
        let id = terminal.active_screen_mut().pages.track_pin(pin);

        gesture.reset(&mut terminal);

        assert_eq!(terminal.active_screen().pages.tracked_pin(id), Some(pin));
    }

    #[test]
    fn selection_gesture_deinit_untracks_pin() {
        // ghostty: "SelectionGesture deinit untracks pin" (SelectionGesture.zig:2013)
        let mut terminal = terminal_with_text(20, 5, "hello world");
        let before = terminal.active_screen().pages.count_tracked_pins();
        let mut gesture = SelectionGesture::new();
        let _ = press_gesture(&mut gesture, &mut terminal, 0, 0, 1);
        assert_eq!(
            terminal.active_screen().pages.count_tracked_pins(),
            before + 1
        );
        gesture.reset(&mut terminal);
        assert_eq!(terminal.active_screen().pages.count_tracked_pins(), before);
    }
}
