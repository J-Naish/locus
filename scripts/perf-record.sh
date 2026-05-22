#!/bin/sh
set -u

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN_DIR="${LOCUS_PERF_RUN_DIR:-$ROOT_DIR/target/perf-runs}"
JSONL_PATH="${LOCUS_PERF_RECORD_JSONL:-$RUN_DIR/perf-records.jsonl}"
SUMMARY_PATH="${LOCUS_PERF_RECORD_SUMMARY:-$ROOT_DIR/docs/performance/perf-log.md}"
LABEL=""
NOTES=""
APPEND_SUMMARY=0

usage() {
    cat <<'USAGE'
Usage:
  scripts/perf-record.sh [--label LABEL] [--notes TEXT] [--append-summary]

Runs scripts/perf-smoke.sh, prints its output, and records the measured result
as JSONL under target/perf-runs/ by default.

Options:
  --label LABEL       Short label for the implementation or module being measured.
  --notes TEXT        Short human note stored with the run.
  --append-summary    Append a compact Markdown entry to docs/performance/perf-log.md.
  -h, --help          Show this help.

Environment:
  LOCUS_PERF_RUN_DIR          Raw run directory. Defaults to target/perf-runs.
  LOCUS_PERF_RECORD_JSONL     JSONL output path.
  LOCUS_PERF_RECORD_SUMMARY   Markdown summary path.

All LOCUS_PERF_* overrides accepted by scripts/perf-smoke.sh are forwarded.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)
            [ "$#" -ge 2 ] || {
                echo "error: --label requires a value" >&2
                exit 2
            }
            LABEL="$2"
            shift 2
            ;;
        --notes)
            [ "$#" -ge 2 ] || {
                echo "error: --notes requires a value" >&2
                exit 2
            }
            NOTES="$2"
            shift 2
            ;;
        --append-summary)
            APPEND_SUMMARY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

json_escape() {
    # Keep this dependency-free; performance labels and notes are short.
    printf '%s' "$1" \
        | sed \
            -e 's/\\/\\\\/g' \
            -e 's/"/\\"/g' \
            -e 's/	/\\t/g'
}

json_number() {
    case "$1" in
        ''|*[!0-9.]*)
            printf 'null'
            ;;
        *)
            printf '%s' "$1"
            ;;
    esac
}

extract_first_value() {
    awk -F': ' -v key="$1" '$1 == key { print $2; exit }' "$2"
}

extract_section_value() {
    awk -v section="$1" -v key="$2" '
        $0 == section { in_section = 1; next }
        /^== / && in_section { exit }
        in_section && index($0, key ": ") == 1 {
            sub("^" key ": ", "")
            print
            exit
        }
    ' "$3"
}

mkdir -p "$RUN_DIR"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
SAFE_LABEL="$(printf '%s' "${LABEL:-run}" | tr -c 'A-Za-z0-9._-' '-')"
OUTPUT_PATH="$RUN_DIR/$RUN_ID-$SAFE_LABEL.log"
TMP_OUTPUT="$RUN_DIR/$RUN_ID-$SAFE_LABEL.tmp"

set +e
"$ROOT_DIR/scripts/perf-smoke.sh" >"$TMP_OUTPUT" 2>&1
STATUS=$?
set -e

cat "$TMP_OUTPUT"
mv "$TMP_OUTPUT" "$OUTPUT_PATH"

COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
BRANCH="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || printf 'unknown')"
if [ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]; then
    DIRTY="true"
else
    DIRTY="false"
fi

MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || printf 'unknown')"
MACHINE="$(hostname 2>/dev/null || printf 'unknown')"
ARCH="$(uname -m 2>/dev/null || printf 'unknown')"

ENTRIES="$(extract_first_value "entries" "$OUTPUT_PATH")"
AVG_MS="$(extract_first_value "avg_ms" "$OUTPUT_PATH")"
MAX_MS="$(extract_first_value "max_ms" "$OUTPUT_PATH")"
AVG_BUDGET_MS="$(extract_first_value "avg_budget_ms" "$OUTPUT_PATH")"
MAX_BUDGET_MS="$(extract_first_value "max_budget_ms" "$OUTPUT_PATH")"
STATICLIB_BYTES="$(extract_section_value "== Rust FFI static library size ==" "bytes" "$OUTPUT_PATH")"
STATICLIB_BUDGET_BYTES="$(extract_section_value "== Rust FFI static library size ==" "budget_bytes" "$OUTPUT_PATH")"
APP_KB="$(extract_section_value "== macOS app bundle size ==" "kilobytes" "$OUTPUT_PATH")"
APP_BUDGET_KB="$(extract_section_value "== macOS app bundle size ==" "budget_kilobytes" "$OUTPUT_PATH")"

DATE_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
LABEL_JSON="$(json_escape "$LABEL")"
NOTES_JSON="$(json_escape "$NOTES")"
OUTPUT_JSON="$(json_escape "$OUTPUT_PATH")"
BRANCH_JSON="$(json_escape "$BRANCH")"
COMMIT_JSON="$(json_escape "$COMMIT")"
MACOS_JSON="$(json_escape "$MACOS_VERSION")"
MACHINE_JSON="$(json_escape "$MACHINE")"
ARCH_JSON="$(json_escape "$ARCH")"
ENTRIES_JSON="$(json_number "$ENTRIES")"
AVG_MS_JSON="$(json_number "$AVG_MS")"
MAX_MS_JSON="$(json_number "$MAX_MS")"
AVG_BUDGET_MS_JSON="$(json_number "$AVG_BUDGET_MS")"
MAX_BUDGET_MS_JSON="$(json_number "$MAX_BUDGET_MS")"
STATICLIB_BYTES_JSON="$(json_number "$STATICLIB_BYTES")"
STATICLIB_BUDGET_BYTES_JSON="$(json_number "$STATICLIB_BUDGET_BYTES")"
APP_KB_JSON="$(json_number "$APP_KB")"
APP_BUDGET_KB_JSON="$(json_number "$APP_BUDGET_KB")"

cat >>"$JSONL_PATH" <<JSON
{"schema_version":1,"run_id":"$RUN_ID","date":"$DATE_ISO","label":"$LABEL_JSON","notes":"$NOTES_JSON","status":$STATUS,"git":{"commit":"$COMMIT_JSON","branch":"$BRANCH_JSON","dirty":$DIRTY},"machine":{"hostname":"$MACHINE_JSON","macos":"$MACOS_JSON","arch":"$ARCH_JSON"},"folder_listing":{"entries":$ENTRIES_JSON,"avg_ms":$AVG_MS_JSON,"max_ms":$MAX_MS_JSON,"avg_budget_ms":$AVG_BUDGET_MS_JSON,"max_budget_ms":$MAX_BUDGET_MS_JSON},"sizes":{"staticlib_bytes":$STATICLIB_BYTES_JSON,"staticlib_budget_bytes":$STATICLIB_BUDGET_BYTES_JSON,"app_kilobytes":$APP_KB_JSON,"app_budget_kilobytes":$APP_BUDGET_KB_JSON},"output_log":"$OUTPUT_JSON"}
JSON

echo
echo "== Performance record =="
echo "jsonl: $JSONL_PATH"
echo "log: $OUTPUT_PATH"

if [ "$APPEND_SUMMARY" -eq 1 ]; then
    mkdir -p "$(dirname "$SUMMARY_PATH")"
    if [ ! -f "$SUMMARY_PATH" ]; then
        cat >"$SUMMARY_PATH" <<'MD'
# Performance Log

Use this file for curated performance notes that explain meaningful changes.
Raw machine-local run data belongs in `target/perf-runs/` and is not committed.

MD
    fi

    {
        echo "## $DATE_ISO ${LABEL:-Performance run}"
        echo
        echo "- commit: \`$COMMIT\`"
        echo "- branch: \`$BRANCH\`"
        echo "- dirty tree: \`$DIRTY\`"
        echo "- status: \`$STATUS\`"
        echo "- folder listing: entries \`$ENTRIES\`, avg \`${AVG_MS:-n/a} ms\`, max \`${MAX_MS:-n/a} ms\`"
        echo "- Rust FFI static library: \`${STATICLIB_BYTES:-n/a} bytes\`"
        echo "- macOS app bundle: \`${APP_KB:-n/a} KiB\`"
        if [ -n "$NOTES" ]; then
            echo "- notes: $NOTES"
        fi
        echo
    } >>"$SUMMARY_PATH"

    echo "summary: $SUMMARY_PATH"
fi

exit "$STATUS"
