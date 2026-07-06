//! Terminal coordinate spaces.
//!
//! Rust port of Ghostty's `terminal/point.zig`.

use crate::size::CellCountInt;

/// The possible reference locations for a point.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tag {
    /// The editable active area at the bottom of the screen.
    Active,
    /// The currently visible viewport.
    Viewport,
    /// The whole written screen, including scrollback and active rows.
    Screen,
    /// The scrollback region before the active area.
    History,
}

/// An x/y coordinate inside a tagged terminal region.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Coordinate {
    pub x: CellCountInt,
    pub y: u32,
}

/// A point tagged with its coordinate space.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Point {
    Active(Coordinate),
    Viewport(Coordinate),
    Screen(Coordinate),
    History(Coordinate),
}

impl Point {
    pub const fn active(x: CellCountInt, y: u32) -> Self {
        Self::Active(Coordinate { x, y })
    }

    pub const fn viewport(x: CellCountInt, y: u32) -> Self {
        Self::Viewport(Coordinate { x, y })
    }

    pub const fn screen(x: CellCountInt, y: u32) -> Self {
        Self::Screen(Coordinate { x, y })
    }

    pub const fn history(x: CellCountInt, y: u32) -> Self {
        Self::History(Coordinate { x, y })
    }

    pub const fn tag(self) -> Tag {
        match self {
            Self::Active(_) => Tag::Active,
            Self::Viewport(_) => Tag::Viewport,
            Self::Screen(_) => Tag::Screen,
            Self::History(_) => Tag::History,
        }
    }

    pub const fn coord(self) -> Coordinate {
        match self {
            Self::Active(coordinate)
            | Self::Viewport(coordinate)
            | Self::Screen(coordinate)
            | Self::History(coordinate) => coordinate,
        }
    }

    pub const fn with_tag(tag: Tag, coordinate: Coordinate) -> Self {
        match tag {
            Tag::Active => Self::Active(coordinate),
            Tag::Viewport => Self::Viewport(coordinate),
            Tag::Screen => Self::Screen(coordinate),
            Tag::History => Self::History(coordinate),
        }
    }
}
