#!/usr/bin/env bash

# Outputs the focused window title for a specific monitor on each bspc event.
# Usage: window_title.sh <monitor_name>

MONITOR="${1:?Usage: window_title.sh <monitor_name>}"
RELAY="$(dirname "$(readlink -f "$0")")/eww_relay.py"

get_title() {
  # `timeout` guard: bspwm is single-threaded and delivers subscribe events
  # synchronously. If a query ever races with a backed-up subscribe pipe, the
  # query is killed after 1s instead of deadlocking the whole WM.
  local node
  node=$(timeout 1 bspc query -N -n newest.focused.local -m "$MONITOR" 2>/dev/null | head -1)

  if [[ -z "$node" ]]; then
    echo ""
    return
  fi

  # Get window name via xprop
  local title
  title=$(timeout 1 xprop -id "$node" _NET_WM_NAME 2>/dev/null | sed 's/.*= "//;s/"$//' | head -c 60)
  echo "${title:-}"
}

emit_stream() {
  # Initial output
  get_title

  # Re-emit on any focus/node/desktop change.
  # Drain burst events first: focus_follows_pointer fires node_focus rapidly when
  # the pointer sweeps across windows. Coalescing to the latest event keeps the
  # subscribe pipe drained and is correct for a title bar.
  bspc subscribe node_focus node_remove desktop_focus node_transfer 2>/dev/null | while read -r _; do
    while read -r -t 0.03 _; do :; done
    get_title
  done
}

# All output goes through the relay, which never blocks on eww's pipe.
# Writing to eww directly is what froze the WM: eww stalls -> this script
# blocks in write() -> it stops draining `bspc subscribe` -> bspwm's blocking
# event write fills up -> bspwm's single-threaded loop stops reading X input
# and answering queries (dead mouse, dead keybinds). See eww_relay.py.
emit_stream | exec python3 "$RELAY"
