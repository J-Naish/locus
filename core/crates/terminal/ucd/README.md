# Unicode Character Database

This directory vendors the Unicode Character Database inputs used to generate
the terminal's runtime Unicode lookup table.

- Version: Unicode 16.0.0
- Source: `https://www.unicode.org/Public/16.0.0/ucd/`
- License: Unicode License v3; see `core/THIRD_PARTY_NOTICES.md`

Vendored files:

- `auxiliary/GraphemeBreakProperty.txt` as `GraphemeBreakProperty.txt`
- `auxiliary/GraphemeBreakTest.txt` as `GraphemeBreakTest.txt`
- `emoji/emoji-data.txt`
- `DerivedCoreProperties.txt`
- `EastAsianWidth.txt`

The files are unmodified. In particular, `DerivedCoreProperties.txt` is kept
whole even though the generator currently consumes only `InCB` and
`Default_Ignorable_Code_Point`; this keeps regeneration inspectable and avoids
maintaining a custom trimmed data format.

Regenerate the Rust lookup table from the repository root:

```sh
python3 scripts/generate-unicode-tables.py
```
