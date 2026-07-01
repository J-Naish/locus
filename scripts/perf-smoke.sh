#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
DERIVED_DATA_PATH="${LOCUS_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-derived}"
WORKSPACE_DIR="${LOCUS_PERF_WORKSPACE:-}"
PERF_FIXTURE_ROOT="${LOCUS_PERF_FIXTURE_ROOT:-$ROOT_DIR/target/perf-fixtures}"

ENTRY_COUNT="${LOCUS_PERF_ENTRY_COUNT:-1000}"
SYMLINK_ENTRY_COUNT="${LOCUS_PERF_SYMLINK_ENTRY_COUNT:-200}"
ITERATIONS="${LOCUS_PERF_ITERATIONS:-5}"
LIST_BUDGET_MS="${LOCUS_PERF_LIST_BUDGET_MS:-50}"
LIST_MAX_BUDGET_MS="${LOCUS_PERF_LIST_MAX_BUDGET_MS:-150}"
SYMLINK_LIST_BUDGET_MS="${LOCUS_PERF_SYMLINK_LIST_BUDGET_MS:-50}"
SYMLINK_LIST_MAX_BUDGET_MS="${LOCUS_PERF_SYMLINK_LIST_MAX_BUDGET_MS:-150}"
STATICLIB_BUDGET_BYTES="${LOCUS_PERF_STATICLIB_BUDGET_BYTES:-25000000}"
APP_BUDGET_KB="${LOCUS_PERF_APP_BUDGET_KB:-102400}"
BUFFER_SIZE_BYTES="${LOCUS_PERF_BUFFER_SIZE_BYTES:-262144}"
BUFFER_OPEN_BUDGET_MS="${LOCUS_PERF_BUFFER_OPEN_BUDGET_MS:-50}"
BUFFER_SCROLL_BUDGET_MS="${LOCUS_PERF_BUFFER_SCROLL_BUDGET_MS:-20}"
BUFFER_EDIT_BUDGET_MS="${LOCUS_PERF_BUFFER_EDIT_BUDGET_MS:-50}"
SKIP_MAC_BUILD="${LOCUS_PERF_SKIP_MAC_BUILD:-0}"

# Local baseline on 2026-06-10:
# - generated workspace: 1,010 visible entries, avg 3.104 ms, max 4.067 ms
# - symlink-heavy workspace: 200 visible entries, avg 1.041 ms, max 1.082 ms
# - core/target/release/libapp_ffi.a: 17,805,224 bytes
# - .build/xcode-derived/Build/Products/Release/Locus.app: 5,988 KiB
# - text buffer @256KB (release): open 0.195 ms, scroll 0.005 ms, edit 0.032 ms/op
#   (persistent rope: for normal-length lines, edit and scroll stay flat as
#   total size grows — e.g. at 64 MB edit ~0.14 ms, scroll ~0.05 ms. Cost scales
#   with the longest line in the viewport, not the file; only open is O(size)
#   until mmap lands. This generated fixture uses short fixed-length lines.)
# Defaults intentionally leave CI headroom while still catching obvious regressions.

if [ -z "$WORKSPACE_DIR" ]; then
    echo "== Generate performance fixture =="
    LOCUS_PERF_FIXTURE_ROOT="$PERF_FIXTURE_ROOT" \
        LOCUS_PERF_ENTRY_COUNT="$ENTRY_COUNT" \
        "$ROOT_DIR/scripts/generate-performance-fixtures.sh"
    WORKSPACE_DIR="$PERF_FIXTURE_ROOT/listing-$ENTRY_COUNT"
    echo
fi

case "$SYMLINK_ENTRY_COUNT" in
    ''|*[!0-9]*)
        echo "error: LOCUS_PERF_SYMLINK_ENTRY_COUNT must be a positive integer" >&2
        exit 2
        ;;
    0)
        echo "error: LOCUS_PERF_SYMLINK_ENTRY_COUNT must be greater than zero" >&2
        exit 2
        ;;
esac

SYMLINK_WORKSPACE_DIR="$PERF_FIXTURE_ROOT/symlink-listing-$SYMLINK_ENTRY_COUNT"
SYMLINK_TARGET_DIR="$PERF_FIXTURE_ROOT/symlink-targets-$SYMLINK_ENTRY_COUNT"

echo "== Rust release build =="
cargo build --manifest-path "$CORE_DIR/Cargo.toml" -p app-cli -p app-ffi --release

echo
echo "== Folder listing smoke =="
"$CORE_DIR/target/release/locus-core" perf-list-directory "$WORKSPACE_DIR" \
    --iterations "$ITERATIONS" \
    --budget-ms "$LIST_BUDGET_MS" \
    --max-budget-ms "$LIST_MAX_BUDGET_MS"

if command -v ln >/dev/null 2>&1; then
    echo
    echo "== Generate symlink performance fixture =="
    rm -rf "$SYMLINK_WORKSPACE_DIR" "$SYMLINK_TARGET_DIR"
    mkdir -p "$SYMLINK_WORKSPACE_DIR" "$SYMLINK_TARGET_DIR/files" "$SYMLINK_TARGET_DIR/folders"

    i=1
    while [ "$i" -le "$SYMLINK_ENTRY_COUNT" ]; do
        if [ $((i % 2)) -eq 0 ]; then
            target="$SYMLINK_TARGET_DIR/folders/folder-$i"
            mkdir -p "$target"
            ln -s "$target" "$SYMLINK_WORKSPACE_DIR/linked-folder-$i"
        else
            target="$SYMLINK_TARGET_DIR/files/file-$i.md"
            printf 'Symlink target %04d\n' "$i" > "$target"
            ln -s "$target" "$SYMLINK_WORKSPACE_DIR/linked-file-$i.md"
        fi
        i=$((i + 1))
    done
    echo "workspace: $SYMLINK_WORKSPACE_DIR"
    echo "generated_symlinks: $SYMLINK_ENTRY_COUNT"

    echo
    echo "== Symlink-heavy folder listing smoke =="
    "$CORE_DIR/target/release/locus-core" perf-list-directory "$SYMLINK_WORKSPACE_DIR" \
        --iterations "$ITERATIONS" \
        --budget-ms "$SYMLINK_LIST_BUDGET_MS" \
        --max-budget-ms "$SYMLINK_LIST_MAX_BUDGET_MS"
else
    echo
    echo "== Symlink-heavy folder listing smoke =="
    echo "skipped: ln unavailable"
fi

echo
echo "== Text buffer smoke =="
"$CORE_DIR/target/release/locus-core" perf-buffer \
    --size-bytes "$BUFFER_SIZE_BYTES" \
    --iterations "$ITERATIONS" \
    --open-budget-ms "$BUFFER_OPEN_BUDGET_MS" \
    --scroll-budget-ms "$BUFFER_SCROLL_BUDGET_MS" \
    --edit-budget-ms "$BUFFER_EDIT_BUDGET_MS"

STATICLIB_PATH="$CORE_DIR/target/release/libapp_ffi.a"
STATICLIB_BYTES="$(wc -c < "$STATICLIB_PATH" | tr -d ' ')"

echo
echo "== Rust FFI static library size =="
echo "path: $STATICLIB_PATH"
echo "bytes: $STATICLIB_BYTES"
echo "budget_bytes: $STATICLIB_BUDGET_BYTES"
if [ "$STATICLIB_BYTES" -gt "$STATICLIB_BUDGET_BYTES" ]; then
    echo "error: static library size exceeded budget" >&2
    exit 1
fi

if [ "$SKIP_MAC_BUILD" = "1" ]; then
    echo
    echo "== macOS app size =="
    echo "skipped: LOCUS_PERF_SKIP_MAC_BUILD=1"
    exit 0
fi

echo
echo "== macOS release build =="
xcodebuild \
    -quiet \
    -project "$ROOT_DIR/apps/mac/Locus/Locus.xcodeproj" \
    -scheme Locus \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination 'platform=macOS' \
    build

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/Locus.app"
APP_KB="$(du -sk "$APP_PATH" | awk '{print $1}')"

echo
echo "== macOS app bundle size =="
echo "path: $APP_PATH"
echo "kilobytes: $APP_KB"
echo "budget_kilobytes: $APP_BUDGET_KB"
if [ "$APP_KB" -gt "$APP_BUDGET_KB" ]; then
    echo "error: app bundle size exceeded budget" >&2
    exit 1
fi
