#!/usr/bin/env bash

# Toggle eww bar between top and bottom positions.
# Reads/writes state from ~/.config/eww/.bar_position

EWW_DIR="$HOME/.config/eww"
POSITION_FILE="$EWW_DIR/.bar_position"

current="top"
if [[ -f "$POSITION_FILE" ]]; then
  current=$(cat "$POSITION_FILE")
fi

if [[ "$current" == "top" ]]; then
  echo "bottom" > "$POSITION_FILE"
else
  echo "top" > "$POSITION_FILE"
fi

"$EWW_DIR/launch_bar.sh"
