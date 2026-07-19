#!/usr/bin/env python3
"""Generate the terminal's packed Unicode 16.0.0 lookup tables."""

from __future__ import annotations

import subprocess
from pathlib import Path


UNICODE_VERSION = "16.0.0"
MAX_CODE_POINT = 0x10FFFF
BLOCK_SHIFT = 8
BLOCK_SIZE = 1 << BLOCK_SHIFT
ROOT = Path(__file__).resolve().parents[1]
UCD = ROOT / "core/crates/terminal/ucd"
OUTPUT = ROOT / "core/crates/terminal/src/unicode/tables.rs"

GCB_VALUES = {
    "Other": 0,
    "CR": 1,
    "LF": 2,
    "Control": 3,
    "Extend": 4,
    "ZWJ": 5,
    "Regional_Indicator": 6,
    "Prepend": 7,
    "SpacingMark": 8,
    "L": 9,
    "V": 10,
    "T": 11,
    "LV": 12,
    "LVT": 13,
}


def code_point_range(text: str) -> range:
    bounds = text.strip().split("..")
    start = int(bounds[0], 16)
    end = int(bounds[-1], 16)
    return range(start, end + 1)


def data_lines(path: Path):
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        body, _, comment = raw_line.partition("#")
        body = body.strip()
        if not body or body.startswith("@missing"):
            continue
        yield [part.strip() for part in body.split(";")], comment.strip()


def require_version(path: Path) -> None:
    header = "\n".join(path.read_text(encoding="utf-8").splitlines()[:10])
    expected = "Emoji Version 16.0" if path.name == "emoji-data.txt" else UNICODE_VERSION
    if expected not in header:
        raise ValueError(f"{path} is not Unicode {UNICODE_VERSION}")


def load_properties() -> list[int]:
    count = MAX_CODE_POINT + 1
    grapheme = [GCB_VALUES["Other"]] * count
    east_asian_width = ["N"] * count
    general_category = ["Cn"] * count
    incb = [0] * count
    extended_pictographic = bytearray(count)
    emoji_modifier = bytearray(count)
    emoji_modifier_base = bytearray(count)
    default_ignorable = bytearray(count)

    required = [
        UCD / "GraphemeBreakProperty.txt",
        UCD / "GraphemeBreakTest.txt",
        UCD / "emoji-data.txt",
        UCD / "DerivedCoreProperties.txt",
        UCD / "EastAsianWidth.txt",
    ]
    for path in required:
        require_version(path)

    for fields, _ in data_lines(UCD / "GraphemeBreakProperty.txt"):
        value = GCB_VALUES[fields[1]]
        for cp in code_point_range(fields[0]):
            grapheme[cp] = value

    for fields, comment in data_lines(UCD / "EastAsianWidth.txt"):
        category = comment.split()[0]
        for cp in code_point_range(fields[0]):
            east_asian_width[cp] = fields[1]
            general_category[cp] = category

    for fields, _ in data_lines(UCD / "DerivedCoreProperties.txt"):
        if fields[1] == "Default_Ignorable_Code_Point":
            for cp in code_point_range(fields[0]):
                default_ignorable[cp] = 1
        elif fields[1] == "InCB" and len(fields) >= 3:
            value = {"Consonant": 1, "Linker": 2, "Extend": 3}.get(fields[2], 0)
            if value:
                for cp in code_point_range(fields[0]):
                    incb[cp] = value

    for fields, _ in data_lines(UCD / "emoji-data.txt"):
        target = None
        if fields[1] == "Extended_Pictographic":
            target = extended_pictographic
        elif fields[1] == "Emoji_Modifier":
            target = emoji_modifier
        elif fields[1] == "Emoji_Modifier_Base":
            target = emoji_modifier_base
        if target is not None:
            for cp in code_point_range(fields[0]):
                target[cp] = 1

    packed = [0] * count
    for cp in range(count):
        gcb = grapheme[cp]
        category = general_category[cp]
        standalone_width = 1
        if category in {"Cc", "Cs", "Zl", "Zp"}:
            standalone_width = 0
        elif cp == 0x00AD:
            standalone_width = 1
        elif default_ignorable[cp]:
            standalone_width = 0
        elif cp in {0x2E3A, 0x2E3B}:
            standalone_width = 2
        elif east_asian_width[cp] in {"W", "F"} or gcb == GCB_VALUES["Regional_Indicator"]:
            standalone_width = 2
        if cp == 0x20E3:
            standalone_width = 2

        zero_in_grapheme = (
            standalone_width == 0
            or category in {"Mn", "Mc", "Me", "Cf"}
            or gcb in {GCB_VALUES["V"], GCB_VALUES["T"], GCB_VALUES["Prepend"]}
            or bool(emoji_modifier[cp])
        )
        if cp == 0x00AD:
            zero_in_grapheme = False

        width = standalone_width
        if zero_in_grapheme and not emoji_modifier[cp] and gcb != GCB_VALUES["Prepend"]:
            width = 0

        packed[cp] = (
            gcb
            | (min(width, 2) << 4)
            | (int(zero_in_grapheme) << 6)
            | (int(bool(extended_pictographic[cp])) << 7)
            | (int(bool(emoji_modifier[cp])) << 8)
            | (incb[cp] << 9)
            | (int(bool(emoji_modifier_base[cp])) << 11)
            | (int(category != "Cn") << 12)
        )
    return packed


def format_array(name: str, rust_type: str, values: list[int], columns: int) -> str:
    lines = [f"pub(super) static {name}: &[{rust_type}] = &["]
    for offset in range(0, len(values), columns):
        chunk = values[offset : offset + columns]
        lines.append("    " + ", ".join(str(value) for value in chunk) + ",")
    lines.append("];")
    return "\n".join(lines)


def generate() -> str:
    packed = load_properties()
    stage1: list[int] = []
    leaves: list[tuple[int, ...]] = []
    leaf_indexes: dict[tuple[int, ...], int] = {}
    for offset in range(0, len(packed), BLOCK_SIZE):
        leaf = tuple(packed[offset : offset + BLOCK_SIZE])
        index = leaf_indexes.get(leaf)
        if index is None:
            index = len(leaves)
            leaf_indexes[leaf] = index
            leaves.append(leaf)
        stage1.append(index)

    flat_leaves = [value for leaf in leaves for value in leaf]
    default_packed = packed[0x0378]
    return "\n\n".join(
        [
            "// DO NOT EDIT — regenerate with `python3 scripts/generate-unicode-tables.py`.\n"
            "// Generated from the vendored Unicode Character Database inputs.",
            f'#[cfg(test)]\npub(super) const UCD_VERSION: &str = "{UNICODE_VERSION}";',
            f"pub(super) const BLOCK_SHIFT: u32 = {BLOCK_SHIFT};\n"
            f"pub(super) const BLOCK_SIZE: usize = {BLOCK_SIZE};\n"
            f"#[cfg(test)]\npub(super) const LEAF_COUNT: usize = {len(leaves)};\n"
            f"const DEFAULT_PACKED: u16 = {default_packed};",
            "#[inline]\n"
            "pub(super) fn packed(codepoint: u32) -> u16 {\n"
            "    if codepoint > 0x10FFFF {\n"
            "        return DEFAULT_PACKED;\n"
            "    }\n"
            "    let block = (codepoint >> BLOCK_SHIFT) as usize;\n"
            "    let leaf = STAGE1[block] as usize;\n"
            "    let offset = (codepoint as usize) & (BLOCK_SIZE - 1);\n"
            "    LEAVES[leaf * BLOCK_SIZE + offset]\n"
            "}",
            format_array("STAGE1", "u16", stage1, 16),
            format_array("LEAVES", "u16", flat_leaves, 16),
        ]
    ) + "\n"


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(generate(), encoding="utf-8")
    subprocess.run(
        ["rustfmt", "--edition", "2021", str(OUTPUT)],
        check=True,
    )


if __name__ == "__main__":
    main()
