#!/usr/bin/env bash
# Pomodoro timer for eww stats overlay
# Main mode: runs as deflisten, outputs JSON every second
# Control: pomodoro.sh toggle | pomodoro.sh skip

STATE_DIR="$HOME/.config/eww"
CMD_FILE="$STATE_DIR/.pomodoro_cmd"

WORK_SECS=2700      # 45 min
REST_SECS=600       # 10 min
LONG_REST_SECS=1500 # 25 min

case "$1" in
  toggle)
    echo "toggle" > "$CMD_FILE"
    exit 0
    ;;
  skip)
    echo "skip" > "$CMD_FILE"
    exit 0
    ;;
  reset)
    echo "reset" > "$CMD_FILE"
    exit 0
    ;;
esac

# ── Main loop (deflisten mode) ──────────────────────────────────────

: > "$CMD_FILE"

secs=$WORK_SECS
mode="work"
running=false
cycle=1
notified=false

output_json() {
  local abs_secs=$secs time_str neg="false"
  if (( secs < 0 )); then
    abs_secs=$(( -secs ))
    neg="true"
  fi
  local m=$(( abs_secs / 60 ))
  local s=$(( abs_secs % 60 ))
  if [[ "$neg" == "true" ]]; then
    time_str="-${m}:$(printf '%02d' "$s")"
  else
    time_str="${m}:$(printf '%02d' "$s")"
  fi

  local icon
  if [[ "$mode" == "work" ]]; then
    icon="󰔟"
  else
    icon="󰒳"
  fi

  local paused="false"
  [[ "$running" == "false" ]] && paused="true"

  echo "{\"time\":\"$time_str\",\"running\":$running,\"paused\":$paused,\"mode\":\"$mode\",\"cycle\":$cycle,\"icon\":\"$icon\",\"negative\":$neg}"
}

while true; do
  # Process commands
  if [[ -s "$CMD_FILE" ]]; then
    cmd=$(cat "$CMD_FILE")
    : > "$CMD_FILE"
    case "$cmd" in
      toggle)
        if [[ "$running" == "true" ]]; then
          running=false
        else
          running=true
        fi
        ;;
      skip)
        if [[ "$mode" == "work" ]]; then
          mode="rest"
          if (( cycle % 4 == 0 )); then
            secs=$LONG_REST_SECS
          else
            secs=$REST_SECS
          fi
        else
          mode="work"
          cycle=$(( cycle + 1 ))
          secs=$WORK_SECS
        fi
        notified=false
        running=true
        ;;
      reset)
        secs=$WORK_SECS
        mode="work"
        running=false
        cycle=1
        notified=false
        ;;
    esac
  fi

  output_json
  sleep 1

  # Tick
  if [[ "$running" == "true" ]]; then
    secs=$(( secs - 1 ))
  fi

  # Notify on reaching zero
  if (( secs <= 0 )) && [[ "$notified" == "false" ]]; then
    notified=true
    if [[ "$mode" == "work" ]]; then
      notify-send -u normal -a "Pomodoro" "Work session #$cycle done" "Right-click the timer to start rest."
    else
      notify-send -u normal -a "Pomodoro" "Rest over" "Right-click the timer to start work session #$(( cycle + 1 ))."
    fi
  fi
done
