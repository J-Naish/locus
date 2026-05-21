#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CORE_DIR="$ROOT_DIR/core"
DERIVED_DATA_PATH="${LOCUS_DERIVED_DATA_PATH:-$ROOT_DIR/.build/xcode-derived}"
WORKSPACE_DIR="${LOCUS_PERF_WORKSPACE:-}"

ENTRY_COUNT="${LOCUS_PERF_ENTRY_COUNT:-1000}"
ITERATIONS="${LOCUS_PERF_ITERATIONS:-5}"
LIST_BUDGET_MS="${LOCUS_PERF_LIST_BUDGET_MS:-50}"
LIST_MAX_BUDGET_MS="${LOCUS_PERF_LIST_MAX_BUDGET_MS:-150}"
STATICLIB_BUDGET_BYTES="${LOCUS_PERF_STATICLIB_BUDGET_BYTES:-25000000}"
APP_BUDGET_KB="${LOCUS_PERF_APP_BUDGET_KB:-10240}"
SKIP_MAC_BUILD="${LOCUS_PERF_SKIP_MAC_BUILD:-0}"

# Local baseline on 2026-05-22:
# - generated workspace: 1,006 visible entries, avg 4.255 ms, max 5.688 ms
# - core/target/release/libapp_ffi.a: 17,687,384 bytes
# - .build/xcode-derived/Build/Products/Release/Locus.app: 648 KiB
# Defaults intentionally leave CI headroom while still catching obvious regressions.

cleanup() {
    if [ -n "${TEMP_WORKSPACE:-}" ] && [ -d "$TEMP_WORKSPACE" ]; then
        rm -rf "$TEMP_WORKSPACE"
    fi
}

trap cleanup EXIT

if [ -z "$WORKSPACE_DIR" ]; then
    TEMP_WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/locus-perf-workspace.XXXXXX")"
    WORKSPACE_DIR="$TEMP_WORKSPACE"
    mkdir -p \
        "$WORKSPACE_DIR/Client Notes" \
        "$WORKSPACE_DIR/Exports" \
        "$WORKSPACE_DIR/Images" \
        "$WORKSPACE_DIR/.agents" \
        "$WORKSPACE_DIR/.claude"

    printf 'API_TOKEN=local-test\n' > "$WORKSPACE_DIR/.env"
    printf 'ignored\n' > "$WORKSPACE_DIR/.DS_Store"
    printf 'ignored\n' > "$WORKSPACE_DIR/Thumbs.db"
    printf 'ignored\n' > "$WORKSPACE_DIR/~\$budget.xlsx"

    i=1
    while [ "$i" -le "$ENTRY_COUNT" ]; do
        case $((i % 10)) in
            0) file="$WORKSPACE_DIR/report-$i.md" ;;
            1) file="$WORKSPACE_DIR/brief-$i.pdf" ;;
            2) file="$WORKSPACE_DIR/proposal-$i.docx" ;;
            3) file="$WORKSPACE_DIR/screenshot-$i.png" ;;
            4) file="$WORKSPACE_DIR/config-$i.json" ;;
            5) file="$WORKSPACE_DIR/settings-$i.toml" ;;
            6) file="$WORKSPACE_DIR/table-$i.csv" ;;
            7) file="$WORKSPACE_DIR/deck-$i.pptx" ;;
            8) file="$WORKSPACE_DIR/budget-$i.xlsx" ;;
            *) file="$WORKSPACE_DIR/notes-$i.txt" ;;
        esac
        printf 'Locus performance fixture %04d\n' "$i" > "$file"
        i=$((i + 1))
    done
fi

echo "== Rust release build =="
cargo build --manifest-path "$CORE_DIR/Cargo.toml" -p app-cli -p app-ffi --release

echo
echo "== Folder listing smoke =="
"$CORE_DIR/target/release/locus-core" perf-list-directory "$WORKSPACE_DIR" \
    --iterations "$ITERATIONS" \
    --budget-ms "$LIST_BUDGET_MS" \
    --max-budget-ms "$LIST_MAX_BUDGET_MS"

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
