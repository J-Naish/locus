#!/bin/sh
set -eu

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_ROOT="${LOCUS_PERF_FIXTURE_ROOT:-$ROOT_DIR/target/perf-fixtures}"
ENTRY_COUNT="${LOCUS_PERF_ENTRY_COUNT:-1000}"
WORKSPACE_DIR="$FIXTURE_ROOT/listing-$ENTRY_COUNT"

case "$ENTRY_COUNT" in
    ''|*[!0-9]*)
        echo "error: LOCUS_PERF_ENTRY_COUNT must be a positive integer" >&2
        exit 2
        ;;
    0)
        echo "error: LOCUS_PERF_ENTRY_COUNT must be greater than zero" >&2
        exit 2
        ;;
esac

rm -rf "$WORKSPACE_DIR"
mkdir -p \
    "$WORKSPACE_DIR/Client Notes" \
    "$WORKSPACE_DIR/Exports" \
    "$WORKSPACE_DIR/Images" \
    "$WORKSPACE_DIR/Reports 2" \
    "$WORKSPACE_DIR/Reports 10" \
    "$WORKSPACE_DIR/.agents" \
    "$WORKSPACE_DIR/.claude"

printf '# Agents\n' > "$WORKSPACE_DIR/.agents/README.md"
printf '# Claude\n' > "$WORKSPACE_DIR/.claude/README.md"
printf 'LOCUS_FIXTURE=true\n' > "$WORKSPACE_DIR/.env"

# Ignored entries exercise filtering without affecting the visible entry count.
printf 'ignored\n' > "$WORKSPACE_DIR/.DS_Store"
printf 'ignored\n' > "$WORKSPACE_DIR/Thumbs.db"
printf 'ignored\n' > "$WORKSPACE_DIR/desktop.ini"
printf 'ignored\n' > "$WORKSPACE_DIR/._Project Brief.md"
printf 'ignored\n' > "$WORKSPACE_DIR/~\$budget.xlsx"

# A small nested shape confirms shallow listing does not accidentally recurse.
printf '# Nested\n' > "$WORKSPACE_DIR/Client Notes/nested-note.md"
printf '# Export\n' > "$WORKSPACE_DIR/Exports/export-001.md"
printf 'not real image data\n' > "$WORKSPACE_DIR/Images/preview-001.png"

i=1
while [ "$i" -le "$ENTRY_COUNT" ]; do
    case $((i % 14)) in
        0) file="$WORKSPACE_DIR/report-$i.md" ;;
        1) file="$WORKSPACE_DIR/brief-$i.pdf" ;;
        2) file="$WORKSPACE_DIR/proposal-$i.docx" ;;
        3) file="$WORKSPACE_DIR/screenshot-$i.png" ;;
        4) file="$WORKSPACE_DIR/config-$i.json" ;;
        5) file="$WORKSPACE_DIR/settings-$i.toml" ;;
        6) file="$WORKSPACE_DIR/table-$i.csv" ;;
        7) file="$WORKSPACE_DIR/deck-$i.pptx" ;;
        8) file="$WORKSPACE_DIR/budget-$i.xlsx" ;;
        9) file="$WORKSPACE_DIR/notes-$i.txt" ;;
        10) file="$WORKSPACE_DIR/file$i.md" ;;
        11) file="$WORKSPACE_DIR/file0$i.md" ;;
        12) file="$WORKSPACE_DIR/資料-$i.md" ;;
        *) file="$WORKSPACE_DIR/space name $i.txt" ;;
    esac
    printf 'Locus performance fixture %04d\n' "$i" > "$file"
    i=$((i + 1))
done

if command -v ln >/dev/null 2>&1; then
    ln -s "Client Notes" "$WORKSPACE_DIR/linked-client-notes" 2>/dev/null || true
    ln -s "report-14.md" "$WORKSPACE_DIR/linked-report.md" 2>/dev/null || true
fi

visible_count="$(find "$WORKSPACE_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')"
listed_count=$((ENTRY_COUNT + 10))

echo "workspace: $WORKSPACE_DIR"
echo "generated_files: $ENTRY_COUNT"
echo "expected_listed_entries: $listed_count"
echo "top_level_entries_including_ignored: $visible_count"
