//! Terminal text search foundations.
//! ghostty: terminal/search.zig:1
//!
//! This begins the Rust port of Ghostty's `terminal/search.zig`. Screen-level
//! search orchestration and native integration land in later rounds.

mod active;
mod pagelist;
mod sliding_window;
mod viewport;

pub use active::ActiveSearch;
pub use pagelist::PageListSearch;
pub use sliding_window::{AppendError, Direction, SlidingWindow};
pub use viewport::ViewportSearch;
