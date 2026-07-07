//! Flattened terminal strings with byte-to-pin maps.
//!
//! This ports the flattened storage part of Ghostty's `terminal/StringMap.zig`.
//! Regex search itself remains outside this crate; the ported search tests
//! below replace only the regex step with direct spans over the same flattened
//! string.

use crate::page_list::Pin;
use crate::selection::Selection;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StringMap {
    pub string: String,
    pub map: Vec<Pin>,
}

impl StringMap {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn push_char(&mut self, ch: char, pin: Pin) {
        self.string.push(ch);
        let bytes = ch.len_utf8();
        self.map.extend(std::iter::repeat_n(pin, bytes));
    }

    pub fn push_str_with_pin(&mut self, value: &str, pin: Pin) {
        for ch in value.chars() {
            self.push_char(ch, pin);
        }
    }

    pub fn pin_at_byte(&self, index: usize) -> Option<Pin> {
        self.map.get(index).copied()
    }

    pub fn selection_for_byte_range(&self, start: usize, end: usize) -> Option<Selection> {
        if start >= end || end > self.map.len() {
            return None;
        }
        Some(Selection::new(self.map[start], self.map[end - 1], false))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::page_list::{NodeId, Pin};
    use crate::point::Coordinate;

    fn pin(x: u16) -> Pin {
        pin_at(x, 0)
    }

    fn pin_at(x: u16, y: u16) -> Pin {
        Pin {
            node: NodeId {
                index: 0,
                generation: 0,
            },
            x,
            y,
            garbage: false,
        }
    }

    #[test]
    fn string_map_maps_every_utf8_byte_to_the_source_pin() {
        // port-added: T8b replaces StringMap.zig regex tests with direct
        // flattened-string/map assertions because this crate has no regex dep.
        let mut map = StringMap::new();
        map.push_char('é', pin(1));
        assert_eq!(map.string, "é");
        assert_eq!(map.map, vec![pin(1), pin(1)]);
    }

    #[test]
    fn string_map_selection_uses_inclusive_end_byte_pin() {
        // port-added: direct map assertion replacing regex match mapping.
        let mut map = StringMap::new();
        map.push_char('a', pin(1));
        map.push_char('b', pin(2));
        map.push_char('c', pin(3));
        let selection = map.selection_for_byte_range(0, 3).unwrap();
        assert_eq!(
            selection.start(&crate::page_list::PageList::new(4, 1, Some(0))),
            Some(pin(1))
        );
        assert_eq!(
            selection.end(&crate::page_list::PageList::new(4, 1, Some(0))),
            Some(pin(3))
        );
    }

    #[test]
    fn string_map_rejects_empty_or_out_of_range_matches() {
        // port-added: direct map assertion replacing regex match mapping.
        let mut map = StringMap::new();
        map.push_str_with_pin("ab", pin(0));
        assert!(map.selection_for_byte_range(1, 1).is_none());
        assert!(map.selection_for_byte_range(0, 3).is_none());
    }

    #[test]
    fn search_iterator() {
        // ghostty: "StringMap searchIterator" (StringMap.zig:115)
        // port-added adaptation: the regex engine is omitted; this asserts the
        // same flattened match span and byte-to-pin round trip directly.
        let mut map = StringMap::new();
        for (offset, ch) in "1ABCD2EFGH\n3IJKL".chars().enumerate() {
            let pin = match ch {
                '\n' => pin_at(10, 0),
                _ if offset <= 10 => pin_at(offset as u16, 0),
                _ => pin_at((offset - 11) as u16, 1),
            };
            map.push_char(ch, pin);
        }
        assert_eq!(&map.string[1..3], "AB");
        let selection = map.selection_for_byte_range(1, 3).unwrap();
        assert_eq!(
            selection.start(&crate::page_list::PageList::new(12, 2, Some(0))),
            Some(pin_at(1, 0))
        );
        assert_eq!(
            selection.end(&crate::page_list::PageList::new(12, 2, Some(0))),
            Some(pin_at(2, 0))
        );
    }

    #[test]
    fn search_iterator_url_detection() {
        // ghostty: "StringMap searchIterator URL detection" (StringMap.zig:172)
        // port-added adaptation: URL detection is represented by the known
        // match byte range; the map assertions remain the behavior under test.
        let mut map = StringMap::new();
        let text = "hello https://example.com/path world";
        for (x, ch) in text.chars().enumerate() {
            map.push_char(ch, pin(x as u16));
        }
        let start = 6;
        let end = 30;
        assert_eq!(&map.string[start..end], "https://example.com/path");
        let selection = map.selection_for_byte_range(start, end).unwrap();
        assert_eq!(
            selection.start(&crate::page_list::PageList::new(40, 1, Some(0))),
            Some(pin(6))
        );
        assert_eq!(
            selection.end(&crate::page_list::PageList::new(40, 1, Some(0))),
            Some(pin(29))
        );
    }

    #[test]
    fn search_iterator_url_with_click_position() {
        // ghostty: "StringMap searchIterator URL with click position" (StringMap.zig:233)
        // port-added adaptation: the URL match span is selected directly, then
        // the clicked pin is checked against the same selection range.
        let mut map = StringMap::new();
        let text = "hello https://example.com world";
        for (x, ch) in text.chars().enumerate() {
            map.push_char(ch, pin(x as u16));
        }
        let selection = map.selection_for_byte_range(6, 25).unwrap();
        let pages = crate::page_list::PageList::new(40, 1, Some(0));
        let click = pin(14);
        assert_eq!(map.pin_at_byte(14), Some(click));
        assert!(selection.contains(&pages, click));
        assert_eq!(
            pages
                .point_from_pin(crate::point::Tag::Screen, click)
                .map(|p| p.coord()),
            Some(Coordinate { x: 14, y: 0 })
        );
    }
}
