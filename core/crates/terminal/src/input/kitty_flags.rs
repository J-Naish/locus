//! Kitty keyboard protocol flags.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Flags {
    pub disambiguate: bool,
    pub report_events: bool,
    pub report_alternates: bool,
    pub report_all: bool,
    pub report_associated: bool,
}

impl Flags {
    pub const DISABLED: Self = Self {
        disambiguate: false,
        report_events: false,
        report_alternates: false,
        report_all: false,
        report_associated: false,
    };

    pub const ALL: Self = Self {
        disambiguate: true,
        report_events: true,
        report_alternates: true,
        report_all: true,
        report_associated: true,
    };

    pub const fn int(self) -> u8 {
        (self.disambiguate as u8)
            | ((self.report_events as u8) << 1)
            | ((self.report_alternates as u8) << 2)
            | ((self.report_all as u8) << 3)
            | ((self.report_associated as u8) << 4)
    }

    const fn from_bits(bits: u8) -> Self {
        Self {
            disambiguate: bits & (1 << 0) != 0,
            report_events: bits & (1 << 1) != 0,
            report_alternates: bits & (1 << 2) != 0,
            report_all: bits & (1 << 3) != 0,
            report_associated: bits & (1 << 4) != 0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetMode {
    Set,
    Or,
    Not,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FlagStack {
    flags: [Flags; Self::LEN],
    idx: usize,
}

impl Default for FlagStack {
    fn default() -> Self {
        Self {
            flags: [Flags::DISABLED; Self::LEN],
            idx: 0,
        }
    }
}

impl FlagStack {
    const LEN: usize = 8;

    pub const fn current(self) -> Flags {
        self.flags[self.idx]
    }

    pub fn set(&mut self, mode: SetMode, flags: Flags) {
        self.flags[self.idx] = match mode {
            SetMode::Set => flags,
            SetMode::Or => Flags::from_bits(self.flags[self.idx].int() | flags.int()),
            SetMode::Not => Flags::from_bits(self.flags[self.idx].int() & !flags.int()),
        };
    }

    pub fn push(&mut self, flags: Flags) {
        self.idx = (self.idx + 1) % Self::LEN;
        self.flags[self.idx] = flags;
    }

    pub fn pop(&mut self, n: usize) {
        if n >= Self::LEN {
            *self = Self::default();
            return;
        }

        for _ in 0..n {
            self.flags[self.idx] = Flags::DISABLED;
            self.idx = if self.idx == 0 {
                Self::LEN - 1
            } else {
                self.idx - 1
            };
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flag_stack_wraps_index_in_both_directions() {
        // ghostty: test (key.zig:65)
        let mut stack = FlagStack::default();
        stack.idx = FlagStack::LEN - 1;
        stack.idx = (stack.idx + 1) % FlagStack::LEN;
        assert_eq!(stack.idx, 0);

        stack.idx = 0;
        stack.idx = if stack.idx == 0 {
            FlagStack::LEN - 1
        } else {
            stack.idx - 1
        };
        assert_eq!(stack.idx, FlagStack::LEN - 1);
    }

    #[test]
    fn flags_int_preserves_packed_bit_order() {
        // ghostty: test (key.zig:109)
        assert_eq!(
            Flags {
                disambiguate: true,
                ..Flags::DISABLED
            }
            .int(),
            0b1
        );
        assert_eq!(
            Flags {
                report_events: true,
                ..Flags::DISABLED
            }
            .int(),
            0b10
        );
    }

    #[test]
    fn flag_stack_push_pop() {
        // ghostty: "FlagStack: push pop" (key.zig:126)
        let mut stack = FlagStack::default();
        stack.push(Flags {
            disambiguate: true,
            ..Flags::DISABLED
        });
        assert_eq!(
            stack.current(),
            Flags {
                disambiguate: true,
                ..Flags::DISABLED
            }
        );

        stack.pop(1);
        assert_eq!(stack.current(), Flags::DISABLED);
    }

    #[test]
    fn flag_stack_pop_big_number_resets_stack() {
        // ghostty: "FlagStack: pop big number" (key.zig:139)
        let mut stack = FlagStack::default();
        stack.pop(100);
        assert_eq!(stack.current(), Flags::DISABLED);
    }

    #[test]
    fn flag_stack_set_modes_update_current_entry() {
        // ghostty: "FlagStack: set" (key.zig:146)
        let mut stack = FlagStack::default();
        stack.set(
            SetMode::Set,
            Flags {
                disambiguate: true,
                ..Flags::DISABLED
            },
        );
        assert_eq!(
            stack.current(),
            Flags {
                disambiguate: true,
                ..Flags::DISABLED
            }
        );

        stack.set(
            SetMode::Or,
            Flags {
                report_events: true,
                ..Flags::DISABLED
            },
        );
        assert_eq!(
            stack.current(),
            Flags {
                disambiguate: true,
                report_events: true,
                ..Flags::DISABLED
            }
        );

        stack.set(
            SetMode::Not,
            Flags {
                report_events: true,
                ..Flags::DISABLED
            },
        );
        assert_eq!(
            stack.current(),
            Flags {
                disambiguate: true,
                ..Flags::DISABLED
            }
        );
    }
}
