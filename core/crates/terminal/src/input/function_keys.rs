//! Legacy PC-style key modifier tables.

use super::key_mods::Mods;

pub const MODIFIERS: [Mods; 15] = [
    Mods {
        shift: true,
        ..Mods::none()
    },
    Mods {
        alt: true,
        ..Mods::none()
    },
    Mods {
        shift: true,
        alt: true,
        ..Mods::none()
    },
    Mods {
        ctrl: true,
        ..Mods::none()
    },
    Mods {
        shift: true,
        ctrl: true,
        ..Mods::none()
    },
    Mods {
        alt: true,
        ctrl: true,
        ..Mods::none()
    },
    Mods {
        shift: true,
        alt: true,
        ctrl: true,
        ..Mods::none()
    },
    Mods {
        super_key: true,
        ..Mods::none()
    },
    Mods {
        shift: true,
        super_key: true,
        ..Mods::none()
    },
    Mods {
        alt: true,
        super_key: true,
        ..Mods::none()
    },
    Mods {
        shift: true,
        alt: true,
        super_key: true,
        ..Mods::none()
    },
    Mods {
        ctrl: true,
        super_key: true,
        ..Mods::none()
    },
    Mods {
        shift: true,
        ctrl: true,
        super_key: true,
        ..Mods::none()
    },
    Mods {
        alt: true,
        ctrl: true,
        super_key: true,
        ..Mods::none()
    },
    Mods {
        shift: true,
        alt: true,
        ctrl: true,
        super_key: true,
        ..Mods::none()
    },
];

pub fn modifier_code(mods: Mods) -> Option<usize> {
    MODIFIERS
        .iter()
        .position(|candidate| candidate.equal(mods))
        .map(|index| index + 2)
}
