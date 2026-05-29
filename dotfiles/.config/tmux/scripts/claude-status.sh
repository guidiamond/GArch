#!/usr/bin/env bash
# Prints a compact summary of Claude panes in a tmux session.
# Output examples:
#   "2c"   — two Claude panes, none idle
#   "2c*"  — two Claude panes, at least one idle (waiting for input)
# Empty output if no Claude panes are detected.
#
# Detection: a pane is considered a Claude pane if its window is named
# "claude" (the dodo-palette convention) OR its current command is `node`
# and the pane contains a Claude UI marker. A Claude pane is considered
# BUSY when its recent output contains "esc to interrupt"; otherwise IDLE.

set -uo pipefail

session="${1:-}"
[[ -z "$session" ]] && exit 0

total=0
idle=0

while IFS=$'\t' read -r pane_id win_name pane_cmd; do
  [[ -z "$pane_id" ]] && continue

  is_claude=0
  case "$win_name" in
    *claude*) is_claude=1 ;;
  esac
  if (( is_claude == 0 )) && [[ "$pane_cmd" == "node" ]]; then
    if tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -25 \
       | grep -qE 'for shortcuts|esc to interrupt'; then
      is_claude=1
    fi
  fi
  (( is_claude == 0 )) && continue

  ((total++))
  content=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -8)
  if [[ "$content" != *"esc to interrupt"* ]]; then
    ((idle++))
  fi
done < <(tmux list-panes -s -t "$session" -F '#{pane_id}'$'\t''#{window_name}'$'\t''#{pane_current_command}' 2>/dev/null)

(( total == 0 )) && exit 0

marker=""
(( idle > 0 )) && marker="*"
printf '%dc%s' "$total" "$marker"
