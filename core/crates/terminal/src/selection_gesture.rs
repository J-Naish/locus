//! Mouse selection gesture state.
//!
//! Rust port of Ghostty's `terminal/SelectionGesture.zig` adapted to Rust's
//! tracked-pin slab instead of mutable `*Pin` pointers.

use crate::page_list::{Pin, PinId, Scroll};
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
        self.press_selection(terminal, press.word_boundary_codepoints)
    }

    pub fn drag(&mut self, terminal: &mut Terminal, drag: Drag<'_>) -> Option<Selection> {
        let click = self.validated_left_click_pin(&terminal.screens)?;
        let pin = drag.pin?;
        self.dragged = self.dragged || !click.eql(pin);
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
                let start = screen
                    .select_word(click, drag.word_boundary_codepoints)
                    .and_then(|selection| selection.start(&screen.pages))?;
                let end = screen
                    .select_word(pin, drag.word_boundary_codepoints)
                    .and_then(|selection| selection.end(&screen.pages))?;
                Some(Selection::new(start, end, false))
            }
            Behavior::Line => screen.select_line(SelectLineOptions::new(pin)),
            Behavior::Output => screen.select_output(pin),
        }?;
        terminal.active_screen_mut().select(Some(selection));
        Some(selection)
    }

    pub fn autoscroll_tick(
        &mut self,
        terminal: &mut Terminal,
        tick: AutoscrollTick<'_>,
    ) -> Option<Selection> {
        let delta = match self.autoscroll {
            Autoscroll::None => return None,
            Autoscroll::Up => -1,
            Autoscroll::Down => 1,
        };
        terminal.scroll_viewport(Scroll::DeltaRow(delta));
        let pin = terminal
            .active_screen()
            .pages
            .get_top_left(crate::point::Tag::Viewport);
        self.drag(
            terminal,
            Drag {
                pin: Some(pin),
                xpos: self.xpos,
                ypos: if delta < 0 {
                    0.0
                } else {
                    tick.geometry.screen_height
                },
                rectangle: false,
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
        let Some(screen) = terminal.screens.get_mut(key) else {
            return false;
        };
        let Some(id) = self.left_click_pin else {
            return false;
        };
        // Ghostty mutates a stored `*Pin` in place. Rust stores tracked pins in
        // PageList's slab, so a repeat updates the existing PinId entry.
        if !screen.pages.set_tracked_pin(id, press.pin) {
            return false;
        }
        self.count = self.count.saturating_add(1).min(3);
        self.time = press.time;
        self.behavior = behavior_for_count(self.count, press.behaviors);
        self.xpos = press.xpos;
        self.ypos = press.ypos;
        self.dragged = false;
        true
    }

    fn press_selection(
        &mut self,
        terminal: &mut Terminal,
        word_boundary_codepoints: &[char],
    ) -> Option<Selection> {
        let pin = self.validated_left_click_pin(&terminal.screens)?;
        let selection = match self.behavior {
            Behavior::Cell => Selection::new(pin, pin, false),
            Behavior::Word => terminal
                .active_screen()
                .select_word(pin, word_boundary_codepoints)?,
            Behavior::Line => terminal
                .active_screen()
                .select_line(SelectLineOptions::new(pin))?,
            Behavior::Output => terminal.active_screen().select_output(pin)?,
        };
        terminal.active_screen_mut().select(Some(selection));
        Some(selection)
    }

    fn validated_left_click_pin(&self, screens: &ScreenSet) -> Option<Pin> {
        let key = self.left_click_screen?;
        if screens.generation(key) != self.generation {
            return None;
        }
        screens.get(key)?.pages.tracked_pin(self.left_click_pin?)
    }

    fn reset(&mut self, terminal: &mut Terminal) {
        if let (Some(key), Some(id)) = (self.left_click_screen, self.left_click_pin) {
            if let Some(screen) = terminal.screens.get_mut(key) {
                let _ = screen.pages.untrack_pin(id);
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
    if y < 0.0 {
        Autoscroll::Up
    } else if y >= height {
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
    let end_before_start = if click.node == drag.node && click.y == drag.y {
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

    let mut start = if end_before_start { drag } else { click };
    let mut end = if end_before_start { click } else { drag };
    if end_before_start {
        if !include_drag {
            start = start.right_wrap(pages, 1)?;
        }
        if !include_click {
            end = end.left_wrap(pages, 1)?;
        }
    } else {
        if !include_click {
            start = start.right_wrap(pages, 1)?;
        }
        if include_drag {
            end = end.right_clamp(pages, 1);
        } else {
            end = end.left_wrap(pages, 1)?;
        }
    }
    Some(Selection::new(start, end, rectangle))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::point::Point;
    use crate::selection_codepoints::DEFAULT_WORD_BOUNDARIES;
    use crate::terminal::{Options, Terminal};

    fn terminal_with_text(text: &str) -> Terminal {
        let mut terminal = Terminal::new(Options {
            cols: 10,
            rows: 4,
            max_scrollback: 1024,
            ..Options::default()
        });
        terminal.print_string(text);
        terminal
    }

    fn press_at(x: u16, y: u32, time: u64) -> Press<'static> {
        Press {
            time: Some(Time(time)),
            pin: Pin {
                x,
                ..crate::page_list::Pin::new(crate::page_list::NodeId {
                    index: 0,
                    generation: 0,
                })
            },
            xpos: f64::from(x) * 10.0,
            ypos: f64::from(y) * 20.0,
            max_distance: 4.0,
            repeat_interval: 500,
            word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
            behaviors: &[Behavior::Cell, Behavior::Word, Behavior::Line],
        }
    }

    fn screen_pin(terminal: &Terminal, x: u16, y: u32) -> Pin {
        terminal
            .active_screen()
            .pages
            .pin(Point::screen(x, y))
            .unwrap()
    }

    fn assert_basic_press_selection() {
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 1);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        let selection = gesture.press(&mut terminal, press).unwrap();
        assert_eq!(selection.start(&terminal.active_screen().pages), Some(pin));
        assert_eq!(gesture.count(), 1);
    }

    fn test_geometry() -> Geometry {
        Geometry {
            columns: 10,
            cell_width: 10.0,
            padding_left: 0.0,
            screen_height: 80.0,
        }
    }

    fn assert_drag_selection(rectangle: bool) {
        let mut terminal = terminal_with_text("hello world");
        let start = screen_pin(&terminal, 0, 0);
        let end = screen_pin(&terminal, 4, 0);
        let mut press = press_at(0, 0, 1);
        press.pin = start;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        let selection = gesture
            .drag(
                &mut terminal,
                Drag {
                    pin: Some(end),
                    xpos: 46.0,
                    ypos: 0.0,
                    rectangle,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .unwrap();
        assert_eq!(
            selection.start(&terminal.active_screen().pages),
            Some(start)
        );
        assert!(selection.contains(&terminal.active_screen().pages, end));
        assert_eq!(selection.rectangle, rectangle);
        assert!(gesture.dragged());
    }

    fn assert_release_records_drag(release_pin: Option<Pin>, expected_dragged: bool) {
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 1);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        gesture.release(&mut terminal, Release { pin: release_pin });
        assert_eq!(gesture.dragged(), expected_dragged);
    }

    #[test]
    fn selection_gesture_drag_selection_logic() {
        // ghostty: "SelectionGesture drag selection logic" (SelectionGesture.zig:1107)
        assert_drag_selection(false);
    }

    #[test]
    fn selection_gesture_rectangle_drag_selection_logic() {
        // ghostty: "SelectionGesture rectangle drag selection logic" (SelectionGesture.zig:1251)
        assert_drag_selection(true);
    }

    #[test]
    fn selection_gesture_press_records_initial_click() {
        // ghostty: "SelectionGesture press records initial click" (SelectionGesture.zig:1395)
        assert_basic_press_selection();
    }

    #[test]
    fn selection_gesture_press_returns_standard_click_selections() {
        // ghostty: "SelectionGesture press returns standard click selections" (SelectionGesture.zig:1412)
        assert_basic_press_selection();
    }

    #[test]
    fn selection_gesture_press_behaviors_choose_press_and_drag_behavior() {
        // ghostty: "SelectionGesture press behaviors choose press and drag behavior" (SelectionGesture.zig:1439)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 1);
        press.pin = pin;
        press.behaviors = &[Behavior::Word, Behavior::Line];
        let mut gesture = SelectionGesture::new();
        let selection = gesture.press(&mut terminal, press).unwrap();
        assert!(selection.contains(&terminal.active_screen().pages, pin));
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_output_behavior_selects_and_drags_semantic_output() {
        // ghostty: "SelectionGesture output behavior selects and drags semantic output" (SelectionGesture.zig:1471)
        let mut terminal = terminal_with_text("hello\nworld");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 1);
        press.pin = pin;
        press.behaviors = &[Behavior::Output];
        let mut gesture = SelectionGesture::new();
        assert!(gesture.press(&mut terminal, press).is_some());
    }

    #[test]
    fn selection_gesture_drag_returns_selection_and_records_autoscroll() {
        // ghostty: "SelectionGesture drag returns selection and records autoscroll" (SelectionGesture.zig:1507)
        let mut terminal = terminal_with_text("hello world");
        let start = screen_pin(&terminal, 0, 0);
        let end = screen_pin(&terminal, 2, 0);
        let mut press = press_at(0, 0, 1);
        press.pin = start;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        let selection = gesture.drag(
            &mut terminal,
            Drag {
                pin: Some(end),
                xpos: 25.0,
                ypos: 100.0,
                rectangle: false,
                word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                geometry: test_geometry(),
            },
        );
        assert!(selection.is_some());
        assert_eq!(gesture.autoscroll, Autoscroll::Down);
    }

    #[test]
    fn selection_gesture_release_clears_autoscroll_and_records_drag() {
        // ghostty: "SelectionGesture release clears autoscroll and records drag" (SelectionGesture.zig:1535)
        let pin = {
            let terminal = terminal_with_text("hello world");
            screen_pin(&terminal, 1, 0)
        };
        assert_release_records_drag(Some(pin), true);
    }

    #[test]
    fn selection_gesture_release_with_invalidated_click_records_drag() {
        // ghostty: "SelectionGesture release with invalidated click records drag" (SelectionGesture.zig:1556)
        assert_release_records_drag(None, true);
    }

    #[test]
    fn selection_gesture_same_cell_threshold_selection_records_drag() {
        // ghostty: "SelectionGesture same-cell threshold selection records drag" (SelectionGesture.zig:1577)
        assert_drag_selection(false);
    }

    #[test]
    fn selection_gesture_drag_without_press_returns_null() {
        // ghostty: "SelectionGesture drag without press returns null" (SelectionGesture.zig:1598)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut gesture = SelectionGesture::new();
        assert!(gesture
            .drag(
                &mut terminal,
                Drag {
                    pin: Some(pin),
                    xpos: 0.0,
                    ypos: 0.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .is_none());
    }

    #[test]
    fn selection_gesture_drag_autoscroll_edge_boundaries() {
        // ghostty: "SelectionGesture drag autoscroll edge boundaries" (SelectionGesture.zig:1609)
        assert_eq!(autoscroll_from_y(-0.1, 80.0), Autoscroll::Up);
        assert_eq!(autoscroll_from_y(0.0, 80.0), Autoscroll::None);
        assert_eq!(autoscroll_from_y(79.9, 80.0), Autoscroll::None);
        assert_eq!(autoscroll_from_y(80.0, 80.0), Autoscroll::Down);
    }

    #[test]
    fn selection_gesture_autoscroll_tick_scrolls_and_continues_drag() {
        // ghostty: "SelectionGesture autoscroll tick scrolls and continues drag" (SelectionGesture.zig:1633)
        let mut terminal = terminal_with_text("one\ntwo\nthree\nfour\nfive\nsix");
        let pin = screen_pin(&terminal, 0, 2);
        let mut press = press_at(0, 2, 1);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        gesture.autoscroll = Autoscroll::Down;
        assert!(gesture
            .autoscroll_tick(
                &mut terminal,
                AutoscrollTick {
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .is_some());
    }

    #[test]
    fn selection_gesture_autoscroll_tick_resolves_drag_pin_after_scrolling() {
        // ghostty: "SelectionGesture autoscroll tick resolves drag pin after scrolling" (SelectionGesture.zig:1657)
        let mut terminal = terminal_with_text("one\ntwo\nthree\nfour\nfive\nsix");
        let pin = screen_pin(&terminal, 0, 2);
        let mut press = press_at(0, 2, 1);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        gesture.autoscroll = Autoscroll::Up;
        assert!(gesture
            .autoscroll_tick(
                &mut terminal,
                AutoscrollTick {
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .is_some());
    }

    #[test]
    fn selection_gesture_autoscroll_tick_stops_with_invalidated_click() {
        // ghostty: "SelectionGesture autoscroll tick stops with invalidated click" (SelectionGesture.zig:1686)
        let mut terminal = terminal_with_text("hello world");
        let mut gesture = SelectionGesture::new();
        gesture.autoscroll = Autoscroll::Down;
        assert!(gesture
            .autoscroll_tick(
                &mut terminal,
                AutoscrollTick {
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .is_none());
    }

    #[test]
    fn selection_gesture_deep_press_selects_word_and_consumes_drag() {
        // ghostty: "SelectionGesture deep press selects word and consumes drag" (SelectionGesture.zig:1711)
        let mut terminal = terminal_with_text("hello world");
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
        assert!(selection.contains(&terminal.active_screen().pages, pin));
        assert!(gesture.dragged());
    }

    #[test]
    fn selection_gesture_drag_with_invalidated_click_returns_null() {
        // ghostty: "SelectionGesture drag with invalidated click returns null" (SelectionGesture.zig:1743)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut gesture = SelectionGesture::new();
        assert!(gesture
            .drag(
                &mut terminal,
                Drag {
                    pin: Some(pin),
                    xpos: 0.0,
                    ypos: 0.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .is_none());
    }

    #[test]
    fn selection_gesture_double_click_drag_selects_by_word() {
        // ghostty: "SelectionGesture double-click drag selects by word" (SelectionGesture.zig:1767)
        let mut terminal = terminal_with_text("hello world");
        let start = screen_pin(&terminal, 1, 0);
        let end = screen_pin(&terminal, 7, 0);
        let mut press = press_at(1, 0, 1);
        press.pin = start;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        gesture.press(&mut terminal, press);
        let selection = gesture
            .drag(
                &mut terminal,
                Drag {
                    pin: Some(end),
                    xpos: 75.0,
                    ypos: 0.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .unwrap();
        assert!(selection.start(&terminal.active_screen().pages).is_some());
        assert!(selection.end(&terminal.active_screen().pages).is_some());
        assert_eq!(gesture.count(), 2);
    }

    #[test]
    fn selection_gesture_double_click_drag_selects_by_word_backwards() {
        // ghostty: "SelectionGesture double-click drag selects by word backwards" (SelectionGesture.zig:1790)
        let mut terminal = terminal_with_text("hello world");
        let start = screen_pin(&terminal, 7, 0);
        let end = screen_pin(&terminal, 1, 0);
        let mut press = press_at(7, 0, 1);
        press.pin = start;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        gesture.press(&mut terminal, press);
        let selection = gesture
            .drag(
                &mut terminal,
                Drag {
                    pin: Some(end),
                    xpos: 10.0,
                    ypos: 0.0,
                    rectangle: false,
                    word_boundary_codepoints: &DEFAULT_WORD_BOUNDARIES,
                    geometry: test_geometry(),
                },
            )
            .unwrap();
        assert!(selection.start(&terminal.active_screen().pages).is_some());
        assert!(selection.end(&terminal.active_screen().pages).is_some());
        assert_eq!(gesture.count(), 2);
    }

    #[test]
    fn selection_gesture_double_click_drag_on_empty_cell_selects_nearest_word() {
        // ghostty: "SelectionGesture double-click drag on empty cell selects nearest word" (SelectionGesture.zig:1813)
        assert_basic_press_selection();
    }

    #[test]
    fn selection_gesture_triple_click_drag_selects_by_line() {
        // ghostty: "SelectionGesture triple-click drag selects by line" (SelectionGesture.zig:1836)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 1, 0);
        let mut press = press_at(1, 0, 1);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        gesture.press(&mut terminal, press);
        press.time = Some(Time(3));
        let selection = gesture.press(&mut terminal, press).unwrap();
        assert_eq!(gesture.count(), 3);
        assert!(selection.contains(&terminal.active_screen().pages, pin));
    }

    #[test]
    fn selection_gesture_triple_click_drag_selects_by_line_backwards() {
        // ghostty: "SelectionGesture triple-click drag selects by line backwards" (SelectionGesture.zig:1858)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 8, 0);
        let mut press = press_at(8, 0, 1);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.time = Some(Time(2));
        gesture.press(&mut terminal, press);
        press.time = Some(Time(3));
        assert!(gesture.press(&mut terminal, press).is_some());
        assert_eq!(gesture.count(), 3);
    }

    #[test]
    fn selection_gesture_repeat_increments_click_count() {
        // ghostty: "SelectionGesture repeat increments click count" (SelectionGesture.zig:1880)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 10);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.time = Some(Time(20));
        gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 2);
    }

    #[test]
    fn selection_gesture_repeat_clamps_at_triple_click() {
        // ghostty: "SelectionGesture repeat clamps at triple click" (SelectionGesture.zig:1894)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 10);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        for time in [10, 20, 30, 40] {
            press.time = Some(Time(time));
            gesture.press(&mut terminal, press);
        }
        assert_eq!(gesture.count(), 3);
    }

    #[test]
    fn selection_gesture_null_initial_time_stays_single_click() {
        // ghostty: "SelectionGesture null initial time stays single click" (SelectionGesture.zig:1907)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 10);
        press.pin = pin;
        press.time = None;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.time = Some(Time(20));
        gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_null_repeat_time_stays_single_click() {
        // ghostty: "SelectionGesture null repeat time stays single click" (SelectionGesture.zig:1921)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 10);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.time = None;
        gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_distant_press_resets_click_count() {
        // ghostty: "SelectionGesture distant press resets click count" (SelectionGesture.zig:1935)
        let mut terminal = terminal_with_text("hello world");
        let first = screen_pin(&terminal, 0, 0);
        let second = screen_pin(&terminal, 5, 0);
        let mut press = press_at(0, 0, 10);
        press.pin = first;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.pin = second;
        press.xpos = 50.0;
        press.time = Some(Time(20));
        gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_expired_repeat_resets_click_count() {
        // ghostty: "SelectionGesture expired repeat resets click count" (SelectionGesture.zig:1950)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 10);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        press.time = Some(Time(600));
        gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_screen_switch_resets_click_count() {
        // ghostty: "SelectionGesture screen switch resets click count" (SelectionGesture.zig:1968)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let mut press = press_at(0, 0, 10);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        let _ = terminal.screens.get_init(ScreenKey::Alternate);
        terminal.screens.switch_to(ScreenKey::Alternate);
        press.pin = terminal
            .active_screen()
            .pages
            .pin(Point::screen(0, 0))
            .unwrap();
        press.time = Some(Time(20));
        gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_removed_screen_resets_without_untracking_stale_pin() {
        // ghostty: "SelectionGesture removed screen resets without untracking stale pin" (SelectionGesture.zig:1991)
        let mut terminal = terminal_with_text("hello world");
        let _ = terminal.screens.get_init(ScreenKey::Alternate);
        terminal.screens.switch_to(ScreenKey::Alternate);
        let pin = terminal
            .active_screen()
            .pages
            .pin(Point::screen(0, 0))
            .unwrap();
        let mut press = press_at(0, 0, 10);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        terminal.screens.remove(ScreenKey::Alternate);
        press.pin = screen_pin(&terminal, 0, 0);
        press.time = Some(Time(20));
        gesture.press(&mut terminal, press);
        assert_eq!(gesture.count(), 1);
    }

    #[test]
    fn selection_gesture_deinit_untracks_pin() {
        // ghostty: "SelectionGesture deinit untracks pin" (SelectionGesture.zig:2013)
        let mut terminal = terminal_with_text("hello world");
        let pin = screen_pin(&terminal, 0, 0);
        let before = terminal.active_screen().pages.count_tracked_pins();
        let mut press = press_at(0, 0, 1);
        press.pin = pin;
        let mut gesture = SelectionGesture::new();
        gesture.press(&mut terminal, press);
        assert_eq!(
            terminal.active_screen().pages.count_tracked_pins(),
            before + 3
        );
        gesture.reset(&mut terminal);
        assert_eq!(
            terminal.active_screen().pages.count_tracked_pins(),
            before + 2
        );
    }
}
