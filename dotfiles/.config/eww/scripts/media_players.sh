#!/usr/bin/env bash

# On-demand list of all active players as JSON array
# Called by the media popup widget

get_icon() {
  case "$1" in
    spotify*) echo "" ;;
    firefox*) echo "󰈹" ;;
    chromium*|brave*) echo "󰖟" ;;
    *) echo "󰝚" ;;
  esac
}

if ! command -v playerctl &>/dev/null; then
  echo "[]"
  exit 0
fi

players=$(playerctl --list-all 2>/dev/null)

if [[ -z "$players" ]]; then
  echo "[]"
  exit 0
fi

first=true
echo -n "["

while IFS= read -r name; do
  status=$(playerctl -p "$name" status 2>/dev/null) || continue
  [[ "$status" == "Stopped" || -z "$status" ]] && continue
  title=$(playerctl -p "$name" metadata --format '{{title}} - {{artist}}' 2>/dev/null || echo "")
  icon=$(get_icon "$name")

  # Escape for JSON
  title="${title//\\/\\\\}"
  title="${title//\"/\\\"}"
  name_esc="${name//\\/\\\\}"
  name_esc="${name_esc//\"/\\\"}"

  if $first; then
    first=false
  else
    echo -n ","
  fi

  echo -n "{\"name\":\"$name_esc\",\"title\":\"$title\",\"status\":\"$status\",\"icon\":\"$icon\"}"
done <<< "$players"

echo "]"
