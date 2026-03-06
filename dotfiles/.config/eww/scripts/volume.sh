#!/usr/bin/env bash

# Outputs JSON with volume info on each PulseAudio sink event
# Format: {"volume":75,"muted":false,"icon":""}

get_volume() {
  local vol muted icon

  vol=$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+%' | head -1 | tr -d '%')
  vol=${vol:-0}

  muted_str=$(pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | grep -oP '(yes|no)')
  if [[ "$muted_str" == "yes" ]]; then
    muted=true
    icon="󰝟"
  else
    muted=false
    if (( vol >= 66 )); then
      icon="󰕾"
    elif (( vol >= 33 )); then
      icon="󰖀"
    elif (( vol > 0 )); then
      icon="󰕿"
    else
      icon="󰝟"
    fi
  fi

  echo "{\"volume\":$vol,\"muted\":$muted,\"icon\":\"$icon\"}"
}

# Initial output
get_volume

# Subscribe to PulseAudio events
pactl subscribe 2>/dev/null | grep --line-buffered "sink" | while read -r _; do
  get_volume
done
