//! Terminal emulation core.
//!
//! A Rust port of Ghostty's terminal core (see core/THIRD_PARTY_NOTICES.md).
//! This crate holds the platform-independent VT state machine and (in later
//! phases) terminal state, screen storage, and render snapshots. It is pure
//! logic: no I/O, no PTY, no FFI — those live in other crates.

pub mod apc;
pub(crate) mod bitmap_allocator;
pub mod charsets;
pub mod color;
pub mod dcs;
pub mod device_attributes;
pub mod device_status;
pub mod focus;
pub(crate) mod hash_map;
pub(crate) mod hyperlink;
pub mod modes;
pub mod osc;
pub mod page;
pub mod page_list;
pub mod parser;
pub mod point;
pub(crate) mod ref_counted_set;
pub mod screen;
pub mod screen_set;
pub mod selection;
pub mod selection_codepoints;
pub mod sgr;
pub mod size;
pub mod size_report;
pub mod stream;
pub mod style;
pub mod tabstops;
pub mod utf8;
pub mod x11_color;
