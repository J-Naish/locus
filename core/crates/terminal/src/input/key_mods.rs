//! Keyboard modifier state.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mod {
    Shift,
    Ctrl,
    Alt,
    Super,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Side {
    Left,
    Right,
}

impl Side {
    const fn bit(self) -> u16 {
        match self {
            Side::Left => 0,
            Side::Right => 1,
        }
    }

    const fn from_bit(bit: bool) -> Self {
        if bit {
            Side::Right
        } else {
            Side::Left
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModifierSides {
    pub shift: Side,
    pub ctrl: Side,
    pub alt: Side,
    pub super_key: Side,
}

impl Default for ModifierSides {
    fn default() -> Self {
        Self {
            shift: Side::Left,
            ctrl: Side::Left,
            alt: Side::Left,
            super_key: Side::Left,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mods {
    pub shift: bool,
    pub ctrl: bool,
    pub alt: bool,
    pub super_key: bool,
    pub caps_lock: bool,
    pub num_lock: bool,
    pub sides: ModifierSides,
}

impl Mods {
    pub const fn none() -> Self {
        Self {
            shift: false,
            ctrl: false,
            alt: false,
            super_key: false,
            caps_lock: false,
            num_lock: false,
            sides: ModifierSides {
                shift: Side::Left,
                ctrl: Side::Left,
                alt: Side::Left,
                super_key: Side::Left,
            },
        }
    }

    pub const fn int(self) -> u16 {
        let mut value = 0;
        if self.shift {
            value |= 1 << 0;
        }
        if self.ctrl {
            value |= 1 << 1;
        }
        if self.alt {
            value |= 1 << 2;
        }
        if self.super_key {
            value |= 1 << 3;
        }
        if self.caps_lock {
            value |= 1 << 4;
        }
        if self.num_lock {
            value |= 1 << 5;
        }
        value |= self.sides.shift.bit() << 6;
        value |= self.sides.ctrl.bit() << 7;
        value |= self.sides.alt.bit() << 8;
        value |= self.sides.super_key.bit() << 9;
        value
    }

    pub const fn empty(self) -> bool {
        self.int() == 0
    }

    pub const fn equal(self, other: Self) -> bool {
        self.int() == other.int()
    }

    pub const fn binding(self) -> Self {
        Self {
            shift: self.shift,
            ctrl: self.ctrl,
            alt: self.alt,
            super_key: self.super_key,
            caps_lock: false,
            num_lock: false,
            sides: ModifierSides {
                shift: Side::Left,
                ctrl: Side::Left,
                alt: Side::Left,
                super_key: Side::Left,
            },
        }
    }

    pub fn unset(self, other: Self) -> Self {
        Self::from_bits(self.int() & !other.int())
    }

    pub const fn from_bits(bits: u16) -> Self {
        Self {
            shift: bits & (1 << 0) != 0,
            ctrl: bits & (1 << 1) != 0,
            alt: bits & (1 << 2) != 0,
            super_key: bits & (1 << 3) != 0,
            caps_lock: bits & (1 << 4) != 0,
            num_lock: bits & (1 << 5) != 0,
            sides: ModifierSides {
                shift: Side::from_bit(bits & (1 << 6) != 0),
                ctrl: Side::from_bit(bits & (1 << 7) != 0),
                alt: Side::from_bit(bits & (1 << 8) != 0),
                super_key: Side::from_bit(bits & (1 << 9) != 0),
            },
        }
    }
}
