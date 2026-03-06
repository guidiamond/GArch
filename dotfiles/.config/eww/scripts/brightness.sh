#!/usr/bin/env bash

# Outputs JSON with brightness info on each change
# Format: {"level":60,"icon":"󰃟","visible":true}
#
# Usage: brightness.sh <monitor>    (e.g. eDP-1, HDMI-1)
#        brightness.sh set <monitor> <+5%|-5%>

MONITOR="${1:-}"
BACKLIGHT_DIR="/sys/class/backlight/intel_backlight"
PIDFILE="/tmp/eww-brightness-${MONITOR}.pid"

is_internal() {
  [[ "$1" == eDP-* || "$1" == LVDS-* ]]
}

get_icon() {
  local level=$1
  if (( level >= 75 )); then
    echo "󰃠"
  elif (( level >= 50 )); then
    echo "󰃟"
  elif (( level >= 25 )); then
    echo "󰃞"
  else
    echo "󰃝"
  fi
}

get_brightness_internal() {
  local level
  if command -v brightnessctl &>/dev/null; then
    local max cur
    max=$(brightnessctl max 2>/dev/null)
    cur=$(brightnessctl get 2>/dev/null)
    if [[ -n "$max" && "$max" -gt 0 ]]; then
      level=$(( cur * 100 / max ))
    fi
  fi

  if [[ -z "$level" ]]; then
    echo '{"level":0,"icon":"󰃟","visible":false}'
    return
  fi

  local icon
  icon=$(get_icon "$level")
  echo "{\"level\":$level,\"icon\":\"$icon\",\"visible\":true}"
}

get_brightness_external() {
  local mon="$1"
  local raw
  raw=$(xrandr --verbose 2>/dev/null | awk "
    /^${mon} connected/ { found=1 }
    found && /Brightness:/ { print \$2; exit }
  ")

  if [[ -z "$raw" ]]; then
    echo '{"level":0,"icon":"󰃟","visible":false}'
    return
  fi

  # Convert 0.0-1.0 float to 0-100 integer
  local level
  level=$(awk "BEGIN { printf \"%d\", ${raw} * 100 }")

  local icon
  icon=$(get_icon "$level")
  echo "{\"level\":$level,\"icon\":\"$icon\",\"visible\":true}"
}

set_brightness() {
  local mon="$1" delta="$2"

  if is_internal "$mon"; then
    local max cur pct
    max=$(brightnessctl max 2>/dev/null)
    cur=$(brightnessctl get 2>/dev/null)
    if [[ -n "$max" && "$max" -gt 0 ]]; then
      pct=$(( cur * 100 / max ))
      # Block decrease if already at or below 5%
      if [[ "$delta" == *-* ]] && (( pct <= 5 )); then
        return 0
      fi
      brightnessctl set "${delta}" &>/dev/null
      # Clamp to 5% if we went below
      cur=$(brightnessctl get 2>/dev/null)
      pct=$(( cur * 100 / max ))
      if (( pct < 5 )); then
        brightnessctl set "5%" &>/dev/null
      fi
    else
      brightnessctl set "${delta}" &>/dev/null
    fi
  else
    # External: adjust xrandr brightness by delta percentage
    local cur
    cur=$(xrandr --verbose 2>/dev/null | awk "
      /^${mon} connected/ { found=1 }
      found && /Brightness:/ { print \$2; exit }
    ")
    cur="${cur:-1.0}"

    local step=0.05
    local new
    if [[ "$delta" == +* ]]; then
      new=$(awk "BEGIN { v = ${cur} + ${step}; if (v > 1.0) v = 1.0; printf \"%.2f\", v }")
    else
      new=$(awk "BEGIN { v = ${cur} - ${step}; if (v < 0.05) v = 0.05; printf \"%.2f\", v }")
    fi

    xrandr --output "$mon" --brightness "$new"
  fi

  # Signal the monitoring process to emit an update immediately
  local pidfile="/tmp/eww-brightness-${mon}.pid"
  if [[ -f "$pidfile" ]]; then
    kill -USR1 "$(cat "$pidfile")" 2>/dev/null
  fi
}

# ── "set" subcommand ─────────────────────────────────────────────────
if [[ "$1" == "set" ]]; then
  set_brightness "$2" "$3"
  exit 0
fi

# ── Monitoring mode ──────────────────────────────────────────────────
get_brightness() {
  if is_internal "$MONITOR"; then
    get_brightness_internal
  else
    get_brightness_external "$MONITOR"
  fi
}

# Initial output
get_brightness

if is_internal "$MONITOR"; then
  # Watch for hardware backlight changes
  if [[ -f "$BACKLIGHT_DIR/brightness" ]]; then
    inotifywait -m -e modify "$BACKLIGHT_DIR/brightness" 2>/dev/null | while read -r _; do
      get_brightness
    done
  fi
else
  # Write PID so the "set" subcommand can signal us
  echo $$ > "$PIDFILE"
  trap 'rm -f "$PIDFILE"' EXIT

  # SIGUSR1 interrupts sleep, causing an immediate re-read
  trap 'get_brightness' USR1

  while true; do
    sleep 5 &
    wait $!
  done
fi
