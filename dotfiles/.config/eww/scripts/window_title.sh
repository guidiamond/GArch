#!/usr/bin/env bash

# Outputs the focused window title for a specific monitor on each bspc event.
# Usage: window_title.sh <monitor_name>

MONITOR="${1:?Usage: window_title.sh <monitor_name>}"

get_title() {
  # Get the focused desktop on our monitor, then its focused node.
  # `timeout` guard: bspwm is single-threaded and delivers subscribe events
  # synchronously. If a query ever races with a backed-up subscribe pipe, the
  # query is killed after 1s instead of deadlocking the whole WM. See the
  # drain loop below.
  local node
  node=$(timeout 1 bspc query -N -n newest.focused.local -m "$MONITOR" 2>/dev/null | head -1)

  if [[ -z "$node" ]]; then
    echo ""
    return
  fi

  # Get window name via xprop
  local title
  title=$(xprop -id "$node" _NET_WM_NAME 2>/dev/null | sed 's/.*= "//;s/"$//' | head -c 60)
  echo "${title:-}"
}

# Initial output
get_title

# Re-emit on any focus/node/desktop change.
# Drain burst events first: focus_follows_pointer fires node_focus rapidly when
# the pointer sweeps across windows. If we ran get_title per event, the per-event
# `bspc query` would fall behind, the subscribe pipe would fill, and bspwm's
# synchronous event writer would block -> the entire WM freezes. Coalescing to
# the latest event keeps the pipe drained and is correct for a title bar.
bspc subscribe node_focus node_remove desktop_focus node_transfer 2>/dev/null | while read -r _; do
  while read -r -t 0.03 _; do :; done
  get_title
done
