//! Terminal charset slots and translation tables.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slots {
    G0,
    G1,
    G2,
    G3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ActiveSlot {
    Gl,
    Gr,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Charset {
    Utf8,
    #[default]
    Ascii,
    British,
    DecSpecial,
}

/// Translation table for a charset. `None` for UTF-8 because UTF-8 has no table.
pub fn table(set: Charset) -> Option<&'static [u16; 256]> {
    match set {
        Charset::Utf8 => None,
        Charset::Ascii => Some(&ASCII),
        Charset::British => Some(&BRITISH),
        Charset::DecSpecial => Some(&DEC_SPECIAL),
    }
}

const fn identity_table() -> [u16; 256] {
    let mut table = [0u16; 256];
    let mut index = 0;
    while index < 256 {
        table[index] = index as u16;
        index += 1;
    }
    table
}

const ASCII: [u16; 256] = identity_table();

const BRITISH: [u16; 256] = {
    let mut table = identity_table();
    table[0x23] = 0x00A3;
    table
};

const DEC_SPECIAL: [u16; 256] = {
    let mut table = identity_table();
    table[0x60] = 0x25C6;
    table[0x61] = 0x2592;
    table[0x62] = 0x2409;
    table[0x63] = 0x240C;
    table[0x64] = 0x240D;
    table[0x65] = 0x240A;
    table[0x66] = 0x00B0;
    table[0x67] = 0x00B1;
    table[0x68] = 0x2424;
    table[0x69] = 0x240B;
    table[0x6A] = 0x2518;
    table[0x6B] = 0x2510;
    table[0x6C] = 0x250C;
    table[0x6D] = 0x2514;
    table[0x6E] = 0x253C;
    table[0x6F] = 0x23BA;
    table[0x70] = 0x23BB;
    table[0x71] = 0x2500;
    table[0x72] = 0x23BC;
    table[0x73] = 0x23BD;
    table[0x74] = 0x251C;
    table[0x75] = 0x2524;
    table[0x76] = 0x2534;
    table[0x77] = 0x252C;
    table[0x78] = 0x2502;
    table[0x79] = 0x2264;
    table[0x7A] = 0x2265;
    table[0x7B] = 0x03C0;
    table[0x7C] = 0x2260;
    table[0x7D] = 0x00A3;
    table[0x7E] = 0x00B7;
    table
};

#[cfg(test)]
mod tests {
    use super::{table, Charset};

    // ghostty: unnamed charset table length test (charsets.zig:101)
    #[test]
    fn non_utf8_charsets_have_256_entry_tables() {
        for charset in [Charset::Ascii, Charset::British, Charset::DecSpecial] {
            assert_eq!(table(charset).map(|table| table.len()), Some(256));
        }
        assert!(table(Charset::Utf8).is_none());
    }
}
