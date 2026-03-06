#!/usr/bin/env bash

# Toggle notification feed popup and refresh history data

EWW_DIR="$HOME/.config/eww"
STATE=$(eww get notif-feed-visible --config "$EWW_DIR" 2>/dev/null)
HEIGHT_FILE="$EWW_DIR/.notif_height"

if [[ "$STATE" == "true" ]]; then
  eww update notif-feed-visible=false --config "$EWW_DIR"
  eww close notif-feed 2>/dev/null --config "$EWW_DIR"
else
  # Load saved height
  height=400
  if [[ -f "$HEIGHT_FILE" ]]; then
    height=$(cat "$HEIGHT_FILE")
  fi
  eww update notif-feed-height="$height" --config "$EWW_DIR"

  # Refresh history before showing
  eww update notif-history="$(~/.config/eww/scripts/notif_history.sh)" --config "$EWW_DIR"
  eww update notif-feed-visible=true --config "$EWW_DIR"
  eww open notif-feed --config "$EWW_DIR" --screen "$(bspc query -M -m focused --names)"
fi
