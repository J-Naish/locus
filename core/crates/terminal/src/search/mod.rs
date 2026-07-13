//! Terminal text search foundations.
//! ghostty: terminal/search.zig:1
//!
//! This begins the Rust port of Ghostty's `terminal/search.zig`. Page-list,
//! screen, viewport, and active-area search layers land in later rounds.

mod sliding_window;

pub use sliding_window::{AppendError, Direction, SlidingWindow};
