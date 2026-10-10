#!/usr/bin/env bash

# Outputs the focused window title for a specific monitor on each bspc event.
# Usage: window_title.sh <monitor_name>

MONITOR="${1:?Usage: window_title.sh <monitor_name>}"

# Latest-value slot. The subscribe loop publishes here; the emitter below is the
# only thing that touches stdout. Writing a regular file never blocks, so a
# stalled reader on our stdout cannot back-pressure the subscribe loop.
STATE=$(mktemp -t "eww_window_title_${MONITOR//\//_}.XXXXXX")
EMITTER_PID=""
cleanup() {
  [[ -n "$EMITTER_PID" ]] && kill "$EMITTER_PID" 2>/dev/null
  rm -f "$STATE" "$STATE.tmp"
}
trap cleanup EXIT INT TERM

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

# Atomic publish, so a half-written slot is never observed by the emitter.
publish() {
  printf '%s\n' "$1" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
}

# Emitter: the ONLY writer to stdout. If eww stops draining its deflisten pipe,
# this process blocks here and nothing else does -- the subscribe loop keeps
# draining bspwm's socket regardless, and simply overwrites the slot.
#
# This isolation is the whole point. Previously a stalled eww blocked the write
# in get_title, which stopped this script reading `bspc subscribe`, which filled
# bspwm's synchronous event writer (213KB of send queue) and froze the entire
# single-threaded WM until the subscriber was killed.
(
  last=$'\001'   # sentinel that no real title can equal, so the first read emits
  while :; do
    cur=$(< "$STATE") || cur=""
    if [[ "$cur" != "$last" ]]; then
      printf '%s\n' "$cur"
      last="$cur"
    fi
    sleep 0.1
  done
) &
EMITTER_PID=$!

# Initial output
publish "$(get_title)"

# Re-emit on any focus/node/desktop change.
# Drain burst events first: focus_follows_pointer fires node_focus rapidly when
# the pointer sweeps across windows. If we ran get_title per event, the per-event
# `bspc query` would fall behind, the subscribe pipe would fill, and bspwm's
# synchronous event writer would block -> the entire WM freezes. Coalescing to
# the latest event keeps the pipe drained and is correct for a title bar.
bspc subscribe node_focus node_remove desktop_focus node_transfer 2>/dev/null | while read -r _; do
  while read -r -t 0.03 _; do :; done
  publish "$(get_title)"
done
