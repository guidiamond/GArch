#!/usr/bin/env bash

# Resize notification feed height by a delta.
# Usage: resize_notif.sh up|down
# Persists the height to a state file.

EWW_DIR="$HOME/.config/eww"
STATE_FILE="$EWW_DIR/.notif_height"
STEP=40
MIN_HEIGHT=200
MAX_HEIGHT=800

# Read current height
height=400
if [[ -f "$STATE_FILE" ]]; then
  height=$(cat "$STATE_FILE")
fi

if [[ "$1" == "up" ]]; then
  height=$((height + STEP))
elif [[ "$1" == "down" ]]; then
  height=$((height - STEP))
fi

# Clamp
(( height < MIN_HEIGHT )) && height=$MIN_HEIGHT
(( height > MAX_HEIGHT )) && height=$MAX_HEIGHT

echo "$height" > "$STATE_FILE"
eww update notif-feed-height="$height" --config "$EWW_DIR"
