#!/bin/zsh
set -euo pipefail

tool="${1:-codex}"
event="${2:-stop}"

if [[ "$tool" != "codex" && "$tool" != "claude" ]]; then
  event="$tool"
  tool="codex"
fi

case "$tool:$event" in
  codex:permission)
    title="Codex needs approval"
    message="A permission request is waiting."
    sound="Submarine"
    ;;
  codex:stop)
    title="Codex finished"
    message="The current task has stopped."
    sound="Glass"
    ;;
  claude:permission)
    title="Claude Code needs approval"
    message="A permission request is waiting."
    sound="Submarine"
    ;;
  claude:stop)
    title="Claude Code finished"
    message="The current task has stopped."
    sound="Glass"
    ;;
  *)
    title="Agent hook"
    message="$tool hook event: $event"
    sound="Glass"
    ;;
esac

if ! /usr/bin/osascript - "$title" "$message" "$sound" <<'APPLESCRIPT'
on run argv
  set notificationTitle to item 1 of argv
  set notificationMessage to item 2 of argv
  set notificationSound to item 3 of argv
  display notification notificationMessage with title notificationTitle sound name notificationSound
end run
APPLESCRIPT
then
  true
fi

if [[ "$tool" == "codex" && "$event" == "stop" ]]; then
  printf '{}\n'
fi
