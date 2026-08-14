#!/usr/bin/env bash

# Outputs JSON with battery info
# Format: {"capacity":85,"status":"Charging","time_remaining":"1h30m","icon":"","visible":true}

get_battery() {
  local bat_path="/sys/class/power_supply/BAT0"

  # Check if battery exists (desktop won't have one)
  if [[ ! -d "$bat_path" ]]; then
    # Try BAT1
    bat_path="/sys/class/power_supply/BAT1"
    if [[ ! -d "$bat_path" ]]; then
      echo '{"capacity":0,"status":"N/A","time_remaining":"","icon":"","visible":false}'
      return
    fi
  fi

  local capacity status time_remaining icon

  capacity=$(cat "$bat_path/capacity" 2>/dev/null || echo 0)
  status=$(cat "$bat_path/status" 2>/dev/null || echo "Unknown")

  # Calculate time remaining from energy/power
  local energy_now power_now
  energy_now=$(cat "$bat_path/energy_now" 2>/dev/null || cat "$bat_path/charge_now" 2>/dev/null || echo 0)
  power_now=$(cat "$bat_path/power_now" 2>/dev/null || cat "$bat_path/current_now" 2>/dev/null || echo 0)

  if (( power_now > 0 )); then
    local hours_raw
    if [[ "$status" == "Charging" ]]; then
      local energy_full
      energy_full=$(cat "$bat_path/energy_full" 2>/dev/null || cat "$bat_path/charge_full" 2>/dev/null || echo 0)
      hours_raw=$(( (energy_full - energy_now) * 100 / power_now ))
    else
      hours_raw=$(( energy_now * 100 / power_now ))
    fi
    local hours=$(( hours_raw / 100 ))
    local mins=$(( (hours_raw % 100) * 60 / 100 ))
    time_remaining="${hours}h${mins}m"
  else
    time_remaining=""
  fi

  # Icon based on status and capacity
  if [[ "$status" == "Charging" || "$status" == "Full" ]]; then
    icon="󰂄"
  elif (( capacity >= 90 )); then
    icon="󰁹"
  elif (( capacity >= 70 )); then
    icon="󰂁"
  elif (( capacity >= 50 )); then
    icon="󰁿"
  elif (( capacity >= 30 )); then
    icon="󰁽"
  elif (( capacity >= 15 )); then
    icon="󰁻"
  else
    icon="󰂃"
  fi

  echo "{\"capacity\":$capacity,\"status\":\"$status\",\"time_remaining\":\"$time_remaining\",\"icon\":\"$icon\",\"visible\":true}"
}

get_battery
