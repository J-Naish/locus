//! URL discovery for the visible terminal viewport.
//!
//! This is a dependency-free subset of Ghostty's default URL matcher. Version
//! one recognizes only `http://` and `https://`; schemes such as mailto and
//! ftp can be added later. Bracketed IPv6 hosts are deliberately skipped.

use std::cmp::Ordering;
use std::ops::Range;

use crate::formatter::{Options as FormatterOptions, PageFormatter};
use crate::page_list::{Direction, PageList, Pin};
use crate::point::{Point, Tag};
use crate::screen::Screen;
use crate::selection::Selection;
use crate::string_map::StringMap;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ViewportLink {
    pub selection: Selection,
    pub uri: String,
}

/// Detected plain-text URLs plus OSC 8 hyperlink runs in the viewport.
pub fn viewport_links(screen: &Screen) -> Vec<ViewportLink> {
    let pages = &screen.pages;
    let mut links = osc8_links(pages);
    let text = viewport_string_map(pages);

    for range in find_urls(&text.string) {
        let Some(selection) = text.selection_for_byte_range(range.start, range.end) else {
            continue;
        };
        if links
            .iter()
            .any(|link| selections_equal(pages, link.selection, selection))
        {
            continue;
        }
        links.push(ViewportLink {
            uri: text.string[range].to_owned(),
            selection,
        });
    }

    links.sort_by(|left, right| compare_links(pages, left, right));
    links
}

/// Finds the byte ranges of v1's dependency-free HTTP(S) URL subset.
pub fn find_urls(text: &str) -> Vec<Range<usize>> {
    let mut result = Vec::new();
    let mut offset = 0usize;

    while offset < text.len() {
        let Some(relative) = text[offset..]
            .find("https://")
            .into_iter()
            .chain(text[offset..].find("http://"))
            .min()
        else {
            break;
        };
        let start = offset + relative;
        let scheme_len = if text[start..].starts_with("https://") {
            "https://".len()
        } else {
            "http://".len()
        };
        let body_start = start + scheme_len;

        // Ghostty has a separate bracketed IPv6 branch. V1 deliberately does
        // not implement it rather than returning a misleading partial URL.
        if text[body_start..].starts_with('[') {
            offset = body_start.saturating_add(1);
            continue;
        }

        let mut end = body_start;
        for (relative, ch) in text[body_start..].char_indices() {
            if !is_scheme_url_char(ch) {
                break;
            }
            end = body_start + relative + ch.len_utf8();
        }
        end = trim_url_end(text, body_start, end);
        if end > body_start {
            result.push(start..end);
            offset = end;
        } else {
            offset = body_start;
        }
    }

    result
}

fn is_scheme_url_char(ch: char) -> bool {
    ch.is_alphanumeric()
        || matches!(
            ch,
            '_' | '-'
                | '.'
                | '~'
                | ':'
                | '/'
                | '?'
                | '#'
                | '@'
                | '!'
                | '$'
                | '&'
                | '*'
                | '+'
                | ','
                | ';'
                | '='
                | '%'
                // ghostty: config/url.zig:19-23. Parentheses are the one
                // documented suffix outside scheme_url_chars.
                | '('
                | ')'
        )
}

fn trim_url_end(text: &str, body_start: usize, mut end: usize) -> usize {
    // ghostty: config/url.zig:14-23.
    while end > body_start && matches!(text.as_bytes()[end - 1], b'.' | b',') {
        end -= 1;
    }

    let body = &text[body_start..end];
    let opens = body.bytes().filter(|byte| *byte == b'(').count();
    let mut closes = body.bytes().filter(|byte| *byte == b')').count();
    while closes > opens && end > body_start && text.as_bytes()[end - 1] == b')' {
        end -= 1;
        closes -= 1;
    }
    end
}

fn viewport_string_map(pages: &PageList) -> StringMap {
    let bottom = u32::from(pages.rows.saturating_sub(1));
    let mut iterator = pages.page_iterator(
        Direction::RightDown,
        Point::viewport(0, 0),
        Some(Point::viewport(0, bottom)),
    );
    let mut result = StringMap::new();

    while let Some(chunk) = iterator.next(pages) {
        let Some(node) = pages.node(chunk.node) else {
            continue;
        };
        if chunk.start >= chunk.end {
            continue;
        }
        let mut formatter = PageFormatter::new(&node.page);
        formatter.opts = FormatterOptions::plain_unwrapped();
        formatter.start_y = chunk.start;
        formatter.end_y = Some(chunk.end - 1);
        let formatted = formatter.format();
        debug_assert_eq!(formatted.text.len(), formatted.point_map.len());
        result.string.push_str(&formatted.text);
        result
            .map
            .extend(formatted.point_map.into_iter().map(|point| Pin {
                node: chunk.node,
                x: point.x,
                y: point.y as u16,
                garbage: false,
            }));

        let last_y = chunk.end - 1;
        if !node.page.row(last_y).wrap() {
            result.string.push('\n');
            result.map.push(Pin {
                node: chunk.node,
                x: 0,
                y: last_y,
                garbage: false,
            });
        }
    }
    result
}

#[derive(Debug)]
struct OscRun {
    page_id: u16,
    uri: String,
    start: Pin,
    end: Pin,
}

fn osc8_links(pages: &PageList) -> Vec<ViewportLink> {
    let bottom = u32::from(pages.rows.saturating_sub(1));
    let mut cells = pages.cell_iterator(
        Direction::RightDown,
        Point::viewport(0, 0),
        Some(Point::viewport(pages.cols.saturating_sub(1), bottom)),
    );
    let mut result = Vec::new();
    let mut current: Option<OscRun> = None;

    while let Some(pin) = cells.next(pages) {
        let candidate = pages.node(pin.node).and_then(|node| {
            let page_id = node.page.hyperlink_id(pin.y, pin.x)?;
            let uri = std::str::from_utf8(node.page.hyperlink_uri(pin.y, pin.x)?).ok()?;
            Some((page_id, uri.to_owned()))
        });

        let Some((page_id, uri)) = candidate else {
            finish_osc_run(&mut current, &mut result);
            continue;
        };
        let extends = current.as_ref().is_some_and(|run| {
            run.uri == uri
                && (run.page_id == page_id || run.end.node != pin.node)
                && pins_are_soft_adjacent(pages, run.end, pin)
        });
        if extends {
            if let Some(run) = &mut current {
                run.end = pin;
            }
            continue;
        }

        finish_osc_run(&mut current, &mut result);
        current = Some(OscRun {
            page_id,
            uri,
            start: pin,
            end: pin,
        });
    }
    finish_osc_run(&mut current, &mut result);
    result
}

fn pins_are_soft_adjacent(pages: &PageList, left: Pin, right: Pin) -> bool {
    if left.node == right.node && left.y == right.y {
        return left.x.checked_add(1) == Some(right.x);
    }
    let Some(node) = pages.node(left.node) else {
        return false;
    };
    if left.x.checked_add(1) != Some(node.page.size().cols) || !node.page.row(left.y).wrap() {
        return false;
    }
    left.right_wrap(pages, 1)
        .is_some_and(|next| next.eql(right))
}

fn finish_osc_run(current: &mut Option<OscRun>, result: &mut Vec<ViewportLink>) {
    let Some(run) = current.take() else {
        return;
    };
    result.push(ViewportLink {
        selection: Selection::new(run.start, run.end, false),
        uri: run.uri,
    });
}

fn selections_equal(pages: &PageList, left: Selection, right: Selection) -> bool {
    match (
        left.start(pages),
        left.end(pages),
        right.start(pages),
        right.end(pages),
    ) {
        (Some(left_start), Some(left_end), Some(right_start), Some(right_end)) => {
            left_start.eql(right_start) && left_end.eql(right_end)
        }
        _ => false,
    }
}

fn compare_links(pages: &PageList, left: &ViewportLink, right: &ViewportLink) -> Ordering {
    let left = left
        .selection
        .start(pages)
        .and_then(|pin| pages.point_from_pin(Tag::Screen, pin))
        .map(|point| point.coord());
    let right = right
        .selection
        .start(pages)
        .and_then(|pin| pages.point_from_pin(Tag::Screen, pin))
        .map(|point| point.coord());
    match (left, right) {
        (Some(left), Some(right)) => (left.y, left.x).cmp(&(right.y, right.x)),
        (Some(_), None) => Ordering::Less,
        (None, Some(_)) => Ordering::Greater,
        (None, None) => Ordering::Equal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::point::Tag;
    use crate::stream::Stream;
    use crate::terminal::{Options, Terminal};

    #[test]
    fn keeps_balanced_parentheses_from_documented_ghostty_example() {
        // ghostty: config/url.zig:14-23
        let text = "https://en.wikipedia.org/wiki/Rust_(video_game)";
        assert_eq!(find_urls(text), vec![0..text.len()]);
    }

    #[test]
    fn trims_surrounding_parenthesis_from_documented_ghostty_example() {
        // ghostty: config/url.zig:14-23
        let text = "(https://example.com)";
        assert_eq!(find_urls(text), vec![1..text.len() - 1]);
    }

    #[test]
    fn trims_trailing_period_and_comma() {
        // ghostty: config/url.zig:14-16
        let text = "https://one.test., http://two.test,";
        assert_eq!(find_urls(text), vec![0.."https://one.test".len(), 19..34]);
    }

    #[test]
    fn finds_http_and_https_at_end_of_line() {
        // ghostty: config/url.zig:25-26
        let text = "http://one.test https://two.test";
        assert_eq!(find_urls(text), vec![0..15, 16..32]);
    }

    #[test]
    fn ignores_non_urls_and_schemes_without_a_body() {
        // port-added: v1's intentionally narrowed scheme contract.
        assert!(find_urls("plain text ftp://example.test https://").is_empty());
    }

    #[test]
    fn viewport_url_crosses_a_soft_wrapped_row() {
        // ghostty: terminal/search/sliding_window.zig:298-338
        let mut stream = terminal_stream(12, 2);
        stream.next_slice(b"https://exam.test/x");
        let links = viewport_links(stream.handler.active_screen());
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].uri, "https://exam.test/x");
        let pages = &stream.handler.active_screen().pages;
        let start = links[0].selection.start(pages).and_then(|pin| {
            pages
                .point_from_pin(Tag::Viewport, pin)
                .map(|point| point.coord())
        });
        let end = links[0].selection.end(pages).and_then(|pin| {
            pages
                .point_from_pin(Tag::Viewport, pin)
                .map(|point| point.coord())
        });
        assert_eq!(start.map(|point| (point.x, point.y)), Some((0, 0)));
        assert_eq!(end.map(|point| (point.x, point.y)), Some((6, 1)));
    }

    #[test]
    fn hard_newline_breaks_a_url() {
        // ghostty: terminal/search/sliding_window.zig:298-338
        let mut stream = terminal_stream(20, 3);
        stream.next_slice(b"https://\r\nexample.test");
        assert!(viewport_links(stream.handler.active_screen()).is_empty());
    }

    #[test]
    fn osc8_run_yields_its_uri() {
        // ghostty: terminal/hyperlink.zig:29-45
        let mut stream = terminal_stream(20, 2);
        stream.next_slice(b"\x1b]8;;https://example.com\x1b\\text\x1b]8;;\x1b\\");
        let links = viewport_links(stream.handler.active_screen());
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].uri, "https://example.com");
    }

    #[test]
    fn osc8_wins_an_exact_plain_url_overlap() {
        // ghostty: terminal/hyperlink.zig:29-45
        let mut stream = terminal_stream(30, 2);
        stream.next_slice(b"\x1b]8;;https://target.test\x1b\\https://shown.test\x1b]8;;\x1b\\");
        let links = viewport_links(stream.handler.active_screen());
        assert_eq!(links.len(), 1);
        assert_eq!(links[0].uri, "https://target.test");
    }

    #[test]
    fn osc8_run_merges_across_a_soft_wrap() {
        // ghostty: terminal/hyperlink.zig:29-45
        let mut stream = terminal_stream(5, 3);
        stream.next_slice(b"\x1b]8;;https://target.test\x1b\\abcdefgh\x1b]8;;\x1b\\");
        let links = viewport_links(stream.handler.active_screen());
        assert_eq!(links.len(), 1);
        let pages = &stream.handler.active_screen().pages;
        let end = links[0].selection.end(pages).and_then(|pin| {
            pages
                .point_from_pin(Tag::Viewport, pin)
                .map(|point| point.coord())
        });
        assert_eq!(end.map(|point| (point.x, point.y)), Some((2, 1)));
    }

    fn terminal_stream(cols: u16, rows: u16) -> Stream<Terminal> {
        Stream::new(Terminal::new(Options {
            cols,
            rows,
            max_scrollback: usize::MAX,
            ..Options::default()
        }))
    }
}
