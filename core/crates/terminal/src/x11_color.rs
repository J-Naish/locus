//! X11 named-color lookup (rgb.txt), case-insensitive, exact-length match.

use std::collections::HashMap;
use std::sync::OnceLock;

use crate::color::Rgb;

static COLORS: OnceLock<HashMap<String, Rgb>> = OnceLock::new();

pub fn get(name: &str) -> Option<Rgb> {
    let key = name.to_ascii_lowercase();
    color_map().get(&key).copied()
}

fn color_map() -> &'static HashMap<String, Rgb> {
    COLORS.get_or_init(|| {
        let mut map = HashMap::new();
        for raw_line in include_str!("x11_color/rgb.txt").lines() {
            let line = raw_line.strip_suffix('\r').unwrap_or(raw_line);
            if line.is_empty() || line.len() < 12 {
                continue;
            }

            let Some(red) = parse_u8_field(&line[0..3]) else {
                continue;
            };
            let Some(green) = parse_u8_field(&line[4..7]) else {
                continue;
            };
            let Some(blue) = parse_u8_field(&line[8..11]) else {
                continue;
            };
            let name = line[12..].trim_matches([' ', '\t']).to_ascii_lowercase();
            map.insert(
                name,
                Rgb {
                    r: red,
                    g: green,
                    b: blue,
                },
            );
        }
        map
    })
}

fn parse_u8_field(field: &str) -> Option<u8> {
    field.trim_matches(' ').parse().ok()
}

#[cfg(test)]
mod tests {
    use super::get;
    use crate::color::Rgb;

    // ghostty: unnamed X11 lookup test (x11_color.zig:54)
    #[test]
    fn x11_lookup_is_case_insensitive_with_exact_names() {
        assert_eq!(get("nosuchcolor"), None);
        assert_eq!(
            get("white"),
            Some(Rgb {
                r: 255,
                g: 255,
                b: 255
            })
        );
        assert_eq!(get("black"), Some(Rgb { r: 0, g: 0, b: 0 }));
        assert_eq!(get("red"), Some(Rgb { r: 255, g: 0, b: 0 }));
        assert_eq!(get("green"), Some(Rgb { r: 0, g: 255, b: 0 }));
        assert_eq!(get("blue"), Some(Rgb { r: 0, g: 0, b: 255 }));
        assert_eq!(
            get("medium spring green"),
            Some(Rgb {
                r: 0,
                g: 250,
                b: 154
            })
        );
        assert_eq!(
            get("ForestGreen"),
            Some(Rgb {
                r: 34,
                g: 139,
                b: 34
            })
        );
        assert_eq!(
            get("FoReStGReen"),
            Some(Rgb {
                r: 34,
                g: 139,
                b: 34
            })
        );
        assert_eq!(
            get("forestgreen"),
            Some(Rgb {
                r: 34,
                g: 139,
                b: 34
            })
        );
        assert_eq!(
            get("lawngreen"),
            Some(Rgb {
                r: 124,
                g: 252,
                b: 0
            })
        );
        assert_eq!(
            get("mediumspringgreen"),
            Some(Rgb {
                r: 0,
                g: 250,
                b: 154
            })
        );
    }
}
