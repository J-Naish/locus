//! Terminal tab-stop bitset.

pub const TABSTOP_INTERVAL: usize = 8;
pub const PREALLOC_COLUMNS: usize = 512;
pub const PREALLOC_COUNT: usize = 64;
pub const UNIT_BITS: usize = 8;
pub const MASKS: [u8; UNIT_BITS] = [1, 2, 4, 8, 16, 32, 64, 128];

#[derive(Debug, Clone)]
pub struct Tabstops {
    cols: usize,
    prealloc_stops: [u8; PREALLOC_COUNT],
    dynamic_stops: Vec<u8>,
}

fn entry(col: usize) -> usize {
    col / UNIT_BITS
}

fn index(col: usize) -> usize {
    col % UNIT_BITS
}

impl Tabstops {
    pub fn new(cols: usize, interval: usize) -> Self {
        let mut tabstops = Self {
            cols: 0,
            prealloc_stops: [0; PREALLOC_COUNT],
            dynamic_stops: Vec::new(),
        };
        tabstops.resize(cols);
        tabstops.reset(interval);
        tabstops
    }

    pub fn set(&mut self, col: usize) {
        let unit = entry(col);
        let mask = MASKS[index(col)];
        if unit < PREALLOC_COUNT {
            self.prealloc_stops[unit] |= mask;
        } else {
            self.dynamic_stops[unit - PREALLOC_COUNT] |= mask;
        }
    }

    pub fn unset(&mut self, col: usize) {
        let unit = entry(col);
        let mask = MASKS[index(col)];
        // Ghostty currently toggles with XOR here; AND-NOT keeps TBC from
        // creating a stop when clearing an already-empty column.
        if unit < PREALLOC_COUNT {
            self.prealloc_stops[unit] &= !mask;
        } else {
            self.dynamic_stops[unit - PREALLOC_COUNT] &= !mask;
        }
    }

    pub fn get(&self, col: usize) -> bool {
        let unit = entry(col);
        let mask = MASKS[index(col)];
        let value = if unit < PREALLOC_COUNT {
            self.prealloc_stops[unit]
        } else {
            self.dynamic_stops[unit - PREALLOC_COUNT]
        };
        value & mask != 0
    }

    pub fn resize(&mut self, cols: usize) {
        self.cols = cols;
        if cols > PREALLOC_COLUMNS {
            let needed = cols - PREALLOC_COLUMNS;
            if needed > self.dynamic_stops.len() {
                self.dynamic_stops.resize(needed, 0);
            }
        }
    }

    pub fn capacity(&self) -> usize {
        (PREALLOC_COUNT + self.dynamic_stops.len()) * UNIT_BITS
    }

    pub fn reset(&mut self, interval: usize) {
        self.prealloc_stops.fill(0);
        self.dynamic_stops.fill(0);
        if interval == 0 {
            return;
        }

        // Ghostty computes `cols - 1`; saturating avoids an underflow for an
        // empty tabstop set while preserving all non-empty behavior.
        let end = self.cols.saturating_sub(1);
        let mut col = interval;
        while col < end {
            self.set(col);
            col += interval;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{entry, index, Tabstops, MASKS, PREALLOC_COLUMNS};

    // ghostty: "Tabstops: basic" (Tabstops.zig:181)
    #[test]
    fn basic_set_unset_get() {
        assert_eq!(entry(0), 0);
        assert_eq!(entry(7), 0);
        assert_eq!(entry(8), 1);
        assert_eq!(index(0), 0);
        assert_eq!(index(3), 3);
        assert_eq!(MASKS[3], 0b1000);

        let mut tabstops = Tabstops::new(0, 0);
        assert!(!tabstops.get(3));
        tabstops.set(3);
        assert!(tabstops.get(3));
        tabstops.unset(3);
        assert!(!tabstops.get(3));
    }

    // ghostty: "Tabstops: dynamic allocations" (Tabstops.zig:207)
    #[test]
    fn dynamic_growth_keeps_capacity_contract() {
        let mut tabstops = Tabstops::new(0, 0);
        let cap = tabstops.capacity();
        assert_eq!(cap, PREALLOC_COLUMNS);
        tabstops.resize(cap * 2);
        assert!(tabstops.capacity() > cap);
        tabstops.set(cap + 5);
        assert!(tabstops.get(cap + 5));
    }

    // ghostty: "Tabstops: interval" (Tabstops.zig:224)
    #[test]
    fn interval_initialization() {
        let tabstops = Tabstops::new(80, 4);
        assert!(!tabstops.get(0));
        assert!(tabstops.get(4));
        assert!(!tabstops.get(5));
        assert!(tabstops.get(8));
    }

    // ghostty: "Tabstops: count on 80" (Tabstops.zig:233)
    #[test]
    fn count_on_80() {
        let tabstops = Tabstops::new(80, 8);
        let count = (0..80).filter(|col| tabstops.get(*col)).count();
        assert_eq!(count, 9);
    }

    #[test]
    fn unset_on_unset_column_is_a_no_op() {
        let mut tabstops = Tabstops::new(80, 0);
        tabstops.unset(8);
        assert!(!tabstops.get(8));
    }

    // Ghostty's resize allocation-failure preservation test is Zig-specific
    // fault injection; Rust's Vec allocation path is intentionally infallible
    // here and aborts on OOM.
}
