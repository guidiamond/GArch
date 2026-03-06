#!/usr/bin/env bash

# Outputs the focused window title for a specific monitor on each bspc event.
# Usage: window_title.sh <monitor_name>

MONITOR="${1:?Usage: window_title.sh <monitor_name>}"

get_title() {
  # Get the focused desktop on our monitor, then its focused node
  local node
  node=$(bspc query -N -n newest.focused.local -m "$MONITOR" 2>/dev/null | head -1)

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

# Re-emit on any focus/node/desktop change
bspc subscribe node_focus node_remove desktop_focus node_transfer 2>/dev/null | while read -r _; do
  get_title
done
