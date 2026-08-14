#!/usr/bin/env bash

# Toggle media player-selector popup on the focused monitor
EWW_DIR="$HOME/.config/eww"

current=$(eww get media-popup-visible --config "$EWW_DIR" 2>/dev/null)

if [[ "$current" == "true" ]]; then
  eww close media-popup --config "$EWW_DIR" 2>/dev/null
  eww update media-popup-visible=false --config "$EWW_DIR"
else
  focused_monitor=$(bspc query -M -m focused --names 2>/dev/null)

  eww open media-popup \
    --config "$EWW_DIR" \
    --screen "$focused_monitor" 2>/dev/null

  eww update media-popup-visible=true --config "$EWW_DIR"
fi
