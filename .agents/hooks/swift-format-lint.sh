#!/bin/zsh
set -euo pipefail

input="$(cat)"
project_dir="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
mac_dir="${project_dir}/apps/mac/Locus"

if [[ ! -d "$mac_dir" ]]; then
  exit 0
fi

changed_paths="$(
  /usr/bin/python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(0)

tool_input = payload.get("tool_input") or {}
paths = []

for key in ("file_path", "path"):
    value = tool_input.get(key)
    if isinstance(value, str) and value:
        paths.append(value)

command = tool_input.get("command")
if isinstance(command, str):
    for line in command.splitlines():
        for prefix in ("*** Add File: ", "*** Update File: ", "*** Delete File: "):
            if line.startswith(prefix):
                paths.append(line[len(prefix):].strip())

print("\n".join(dict.fromkeys(paths)))
' <<< "$input"
)"

if [[ -z "$changed_paths" ]]; then
  exit 0
fi

swift_files=()
while IFS= read -r changed_path; do
  [[ -z "$changed_path" ]] && continue

  if [[ "$changed_path" != /* ]]; then
    changed_path="${project_dir}/${changed_path}"
  fi

  if [[ "$changed_path" == "${mac_dir}/"* && "$changed_path" == *.swift && -f "$changed_path" ]]; then
    swift_files+=("$changed_path")
  fi
done <<< "$changed_paths"

if (( ${#swift_files[@]} == 0 )); then
  exit 0
fi

swift_format="$(xcrun --find swift-format 2>/dev/null || true)"
if [[ -z "$swift_format" ]]; then
  printf 'swift-format was not found in the active Xcode toolchain.\n' >&2
  exit 2
fi

format_output="$(mktemp)"
lint_output="$(mktemp)"
trap 'rm -f "$format_output" "$lint_output"' EXIT

if ! "$swift_format" format --in-place --parallel --no-color-diagnostics "${swift_files[@]}" >"$format_output" 2>&1; then
  {
    printf 'Swift formatting failed.\n\n'
    cat "$format_output"
  } >&2
  exit 2
fi

if ! "$swift_format" lint --strict --parallel --no-color-diagnostics "${swift_files[@]}" >"$lint_output" 2>&1; then
  {
    printf 'Swift format lint failed.\n\n'
    cat "$lint_output"
  } >&2
  exit 2
fi
