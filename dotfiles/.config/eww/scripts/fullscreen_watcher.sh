#!/usr/bin/env bash

# Watch for fullscreen state changes and hide/show eww bar windows accordingly.
# Uses debouncing to prevent flicker from rapid event bursts.

EWW_DIR="$HOME/.config/eww"

# Cache bar window IDs at startup (refreshed if empty)
BAR_WIDS=""

ensure_wids() {
  [[ -n "$BAR_WIDS" ]] && return
  BAR_WIDS="$(xdotool search --name "^Eww - " 2>/dev/null)"
}

hide_bars() {
  ensure_wids
  for wid in $BAR_WIDS; do
    xdotool windowunmap "$wid" 2>/dev/null
  done
}

show_bars() {
  ensure_wids
  for wid in $BAR_WIDS; do
    xdotool windowmap "$wid" 2>/dev/null
  done
}

has_fullscreen() {
  bspc query -N -n .fullscreen -d focused >/dev/null 2>&1
}

# Track state to avoid redundant calls
last_state=""

update() {
  if has_fullscreen; then
    [[ "$last_state" == "hidden" ]] && return
    last_state="hidden"
    hide_bars
  else
    [[ "$last_state" == "visible" ]] && return
    last_state="visible"
    show_bars
  fi
}

# Initial check
update

# Debounced event loop: drain burst events before acting
bspc subscribe node_state desktop_focus node_remove node_transfer 2>/dev/null | while read -r _; do
  # Drain any events that arrive within 30ms (prevents flicker)
  while read -r -t 0.03 _; do :; done
  update
done
