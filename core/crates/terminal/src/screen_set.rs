//! Primary/alternate terminal screen container.
//!
//! Rust port of Ghostty's `terminal/ScreenSet.zig`.

use crate::screen::{Options, Screen};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenKey {
    Primary,
    Alternate,
}

#[derive(Debug, Clone)]
pub struct ScreenSet {
    primary: Screen,
    alternate: Option<Screen>,
    active_key: ScreenKey,
    primary_generation: usize,
    alternate_generation: usize,
    options: Options,
}

impl ScreenSet {
    pub fn new(options: Options) -> Self {
        Self {
            primary: Screen::new(options),
            alternate: None,
            active_key: ScreenKey::Primary,
            primary_generation: 0,
            alternate_generation: 0,
            options,
        }
    }

    pub const fn active_key(&self) -> ScreenKey {
        self.active_key
    }

    pub const fn generation(&self, key: ScreenKey) -> usize {
        match key {
            ScreenKey::Primary => self.primary_generation,
            ScreenKey::Alternate => self.alternate_generation,
        }
    }

    pub fn get(&self, key: ScreenKey) -> Option<&Screen> {
        match key {
            ScreenKey::Primary => Some(&self.primary),
            ScreenKey::Alternate => self.alternate.as_ref(),
        }
    }

    pub fn get_mut(&mut self, key: ScreenKey) -> Option<&mut Screen> {
        match key {
            ScreenKey::Primary => Some(&mut self.primary),
            ScreenKey::Alternate => self.alternate.as_mut(),
        }
    }

    pub fn get_init(&mut self, key: ScreenKey) -> &mut Screen {
        match key {
            ScreenKey::Primary => &mut self.primary,
            // The alternate screen never keeps scrollback, matching ghostty's
            // `switchScreen`, which hardcodes `max_scrollback = 0` for it.
            ScreenKey::Alternate => {
                let options = self.options;
                self.alternate.get_or_insert_with(|| {
                    Screen::new(Options {
                        max_scrollback: 0,
                        ..options
                    })
                })
            }
        }
    }

    pub fn active(&self) -> &Screen {
        match self.active_key {
            ScreenKey::Primary => &self.primary,
            ScreenKey::Alternate => self.alternate.as_ref().unwrap_or(&self.primary),
        }
    }

    pub fn active_mut(&mut self) -> &mut Screen {
        match self.active_key {
            ScreenKey::Primary => &mut self.primary,
            ScreenKey::Alternate => match self.alternate.as_mut() {
                Some(screen) => screen,
                None => &mut self.primary,
            },
        }
    }

    pub fn remove(&mut self, key: ScreenKey) {
        match key {
            ScreenKey::Primary => panic!("primary screen cannot be removed"),
            ScreenKey::Alternate => {
                if self.alternate.take().is_some() {
                    self.alternate_generation = self.alternate_generation.wrapping_add(1);
                    if self.active_key == ScreenKey::Alternate {
                        self.active_key = ScreenKey::Primary;
                    }
                }
            }
        }
    }

    pub fn switch_to(&mut self, key: ScreenKey) {
        match key {
            ScreenKey::Primary => self.active_key = ScreenKey::Primary,
            ScreenKey::Alternate => {
                assert!(self.alternate.is_some());
                self.active_key = ScreenKey::Alternate;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn screen_set_initializes_and_switches_to_alternate() {
        // ghostty: "ScreenSet" (ScreenSet.zig:109)
        let mut set = ScreenSet::new(Options::default());
        assert_eq!(set.active_key(), ScreenKey::Primary);
        assert_eq!(set.generation(ScreenKey::Primary), 0);
        assert_eq!(set.generation(ScreenKey::Alternate), 0);

        let _ = set.get_init(ScreenKey::Alternate);
        assert_eq!(set.generation(ScreenKey::Alternate), 0);
        set.switch_to(ScreenKey::Alternate);
        assert_eq!(set.active_key(), ScreenKey::Alternate);
    }

    #[test]
    fn screen_set_generations_only_bump_on_real_removal() {
        // ghostty: "ScreenSet generations" (ScreenSet.zig:125)
        let mut set = ScreenSet::new(Options::default());
        assert_eq!(set.generation(ScreenKey::Primary), 0);
        assert_eq!(set.generation(ScreenKey::Alternate), 0);

        set.remove(ScreenKey::Alternate);
        assert_eq!(set.generation(ScreenKey::Alternate), 0);

        let _ = set.get_init(ScreenKey::Alternate);
        assert_eq!(set.generation(ScreenKey::Alternate), 0);
        let generation = set.generation(ScreenKey::Alternate);

        set.remove(ScreenKey::Alternate);
        assert_eq!(
            set.generation(ScreenKey::Alternate),
            generation.wrapping_add(1)
        );
        let _ = set.get_init(ScreenKey::Alternate);
        assert_eq!(
            set.generation(ScreenKey::Alternate),
            generation.wrapping_add(1)
        );
        assert_eq!(set.generation(ScreenKey::Primary), 0);
    }
}
