//! Terminal text search foundations.
//! ghostty: terminal/search.zig:1
//!
//! This ports Ghostty's terminal search stack through screen-level search
//! orchestration. Native integration lands in P7 and the find UI in P8.

mod active;
mod pagelist;
mod screen;
mod sliding_window;
mod viewport;

pub use active::ActiveSearch;
pub use pagelist::PageListSearch;
pub use screen::{ScreenSearch, ScreenSearchState, ScreenSearchTickError, Select};
pub use sliding_window::{AppendError, Direction, SlidingWindow};
pub use viewport::ViewportSearch;
