//! Grid size primitives.
//!
//! Phase T4 ports the rest of Ghostty's size.zig (offsets, layout math). This
//! phase only needs the cell-count type.

/// Integer type for row/column counts (ghostty: size.zig `CellCountInt = u16`).
pub type CellCountInt = u16;
