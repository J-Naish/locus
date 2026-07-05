//! Terminal emulation core.
//!
//! A Rust port of Ghostty's terminal core (see core/THIRD_PARTY_NOTICES.md).
//! This crate holds the platform-independent VT state machine and (in later
//! phases) terminal state, screen storage, and render snapshots. It is pure
//! logic: no I/O, no PTY, no FFI — those live in other crates.

pub mod osc;
pub mod parser;
pub mod utf8;
