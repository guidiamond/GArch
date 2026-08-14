#!/usr/bin/env bash

# Event-driven media info via playerctl --follow
# Outputs JSON on every change for eww deflisten

EMPTY='{"visible":false,"status":"","title":"","artist":"","player":"","icon":""}'

get_icon() {
  case "$1" in
    spotify*) echo "" ;;
    firefox*) echo "󰈹" ;;
    chromium*|brave*) echo "󰖟" ;;
    *) echo "󰝚" ;;
  esac
}

# If playerctl is not installed, emit empty forever
if ! command -v playerctl &>/dev/null; then
  echo "$EMPTY"
  sleep infinity
  exit 0
fi

# Emit current state, then follow changes
playerctl metadata --follow --format '{{playerName}}	{{status}}	{{title}}	{{artist}}' 2>/dev/null | while IFS=$'\t' read -r player status title artist; do
  if [[ -z "$player" || "$status" == "Stopped" ]]; then
    echo "$EMPTY"
    continue
  fi

  icon=$(get_icon "$player")

  # Escape strings for JSON
  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  artist="${artist//\\/\\\\}"
  artist="${artist//\"/\\\"}"
  player_name="${player//\\/\\\\}"
  player_name="${player_name//\"/\\\"}"

  echo "{\"visible\":true,\"status\":\"$status\",\"title\":\"$title\",\"artist\":\"$artist\",\"player\":\"$player_name\",\"icon\":\"$icon\"}"
done

# If playerctl exits (no players), emit empty
echo "$EMPTY"
sleep infinity
