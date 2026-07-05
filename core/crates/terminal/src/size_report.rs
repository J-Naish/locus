//! Terminal size report encoders.

use crate::size::CellCountInt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Style {
    Mode2048,
    Csi14T,
    Csi16T,
    Csi18T,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Size {
    pub rows: CellCountInt,
    pub columns: CellCountInt,
    pub cell_width: u32,
    pub cell_height: u32,
}

pub fn encode<W: std::fmt::Write>(writer: &mut W, style: Style, size: Size) -> std::fmt::Result {
    let width_pixels = u64::from(size.columns) * u64::from(size.cell_width);
    let height_pixels = u64::from(size.rows) * u64::from(size.cell_height);
    match style {
        Style::Mode2048 => write!(
            writer,
            "\x1B[48;{};{};{};{}t",
            size.rows, size.columns, height_pixels, width_pixels
        ),
        Style::Csi14T => write!(writer, "\x1B[4;{};{}t", height_pixels, width_pixels),
        Style::Csi16T => write!(writer, "\x1B[6;{};{}t", size.cell_height, size.cell_width),
        Style::Csi18T => write!(writer, "\x1B[8;{};{}t", size.rows, size.columns),
    }
}

#[cfg(test)]
mod tests {
    use super::{encode, Size, Style};

    fn test_size() -> Size {
        Size {
            rows: 24,
            columns: 80,
            cell_width: 9,
            cell_height: 18,
        }
    }

    fn encoded(style: Style, size: Size) -> String {
        let mut output = String::new();
        encode(&mut output, style, size).unwrap();
        output
    }

    // ghostty: "encode mode 2048" (size_report.zig:92)
    #[test]
    fn encode_mode_2048() {
        assert_eq!(
            encoded(Style::Mode2048, test_size()),
            "\x1B[48;24;80;432;720t"
        );
    }

    // ghostty: "encode csi 14 t" (size_report.zig:100)
    #[test]
    fn encode_csi_14_t() {
        assert_eq!(encoded(Style::Csi14T, test_size()), "\x1B[4;432;720t");
    }

    // ghostty: "encode csi 16 t" (size_report.zig:108)
    #[test]
    fn encode_csi_16_t() {
        assert_eq!(encoded(Style::Csi16T, test_size()), "\x1B[6;18;9t");
    }

    // ghostty: "encode csi 18 t" (size_report.zig:116)
    #[test]
    fn encode_csi_18_t() {
        assert_eq!(encoded(Style::Csi18T, test_size()), "\x1B[8;24;80t");
    }

    // ghostty: "encode max values for all fields" (size_report.zig:124)
    #[test]
    fn encode_max_values_for_all_fields() {
        let size = Size {
            rows: u16::MAX,
            columns: u16::MAX,
            cell_width: u32::MAX,
            cell_height: u32::MAX,
        };

        assert_eq!(
            encoded(Style::Mode2048, size),
            "\x1B[48;65535;65535;281470681677825;281470681677825t"
        );
        assert_eq!(
            encoded(Style::Csi14T, size),
            "\x1B[4;281470681677825;281470681677825t"
        );
        assert_eq!(
            encoded(Style::Csi16T, size),
            "\x1B[6;4294967295;4294967295t"
        );
        assert_eq!(encoded(Style::Csi18T, size), "\x1B[8;65535;65535t");
    }
}
