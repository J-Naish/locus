#!/bin/zsh
set -euo pipefail

input="$(cat)"
project_dir="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
core_dir="${project_dir}/core"

if [[ ! -f "${core_dir}/Cargo.toml" ]]; then
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

should_run=false
while IFS= read -r changed_path; do
  [[ -z "$changed_path" ]] && continue

  if [[ "$changed_path" != /* ]]; then
    changed_path="${project_dir}/${changed_path}"
  fi

  if [[ "$changed_path" == "${core_dir}/"* ]] &&
     [[ "$changed_path" == *.rs || "${changed_path:t}" == "Cargo.toml" ]]; then
    should_run=true
    break
  fi
done <<< "$changed_paths"

if [[ "$should_run" != true ]]; then
  exit 0
fi

cd "$core_dir"

fmt_output="$(mktemp)"
clippy_output="$(mktemp)"
trap 'rm -f "$fmt_output" "$clippy_output"' EXIT

if ! cargo fmt >"$fmt_output" 2>&1; then
  {
    printf 'Rust formatting failed after editing Rust sources.\n\n'
    cat "$fmt_output"
  } >&2
  exit 2
fi

if ! cargo clippy --all-targets --all-features -- -D warnings >"$clippy_output" 2>&1; then
  {
    printf 'Rust lint failed after editing Rust sources.\n\n'
    cat "$clippy_output"
  } >&2
  exit 2
fi
