#!/usr/bin/env bash

# Toggle power popup on the focused monitor
EWW_DIR="$HOME/.config/eww"

current=$(eww get power-visible --config "$EWW_DIR" 2>/dev/null)

if [[ "$current" == "true" ]]; then
  eww close power-popup --config "$EWW_DIR" 2>/dev/null
  eww update power-visible=false --config "$EWW_DIR"
else
  # Get focused monitor name
  focused_monitor=$(bspc query -M -m focused --names 2>/dev/null)

  eww open power-popup \
    --config "$EWW_DIR" \
    --screen "$focused_monitor" 2>/dev/null

  eww update power-visible=true --config "$EWW_DIR"
fi
