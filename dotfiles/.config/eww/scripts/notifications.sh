#!/usr/bin/env bash

# Outputs JSON with notification state for eww.
# Polls dunstctl and emits on each change.
# Format: {"count":3,"icon":"󰂚","visible":true,"paused":false}

get_notif_data() {
  local displayed waiting history paused icon visible count

  displayed=$(dunstctl count displayed 2>/dev/null || echo 0)
  waiting=$(dunstctl count waiting 2>/dev/null || echo 0)
  history=$(dunstctl count history 2>/dev/null || echo 0)
  paused=$(dunstctl is-paused 2>/dev/null || echo false)

  count=$((displayed + waiting))

  if [[ "$paused" == "true" ]]; then
    icon="󰂛"
    visible=true
  elif (( count > 0 )); then
    icon="󱅫"
    visible=true
  else
    icon="󰂚"
    visible=false
  fi

  echo "{\"count\":$count,\"history\":$history,\"icon\":\"$icon\",\"visible\":$visible,\"paused\":$paused}"
}

# Initial output
get_notif_data

# Re-check every second for new notifications
while true; do
  sleep 1
  get_notif_data
done
