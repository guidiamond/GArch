#!/usr/bin/env bash

# Outputs JSON with system stats

get_system() {
  local cpu mem_used mem_total mem_percent temp temp_icon

  # CPU usage (from /proc/stat - compare two snapshots 500ms apart)
  read -r _ user1 nice1 sys1 idle1 _ < /proc/stat
  sleep 0.5
  read -r _ user2 nice2 sys2 idle2 _ < /proc/stat

  local total1=$(( user1 + nice1 + sys1 + idle1 ))
  local total2=$(( user2 + nice2 + sys2 + idle2 ))
  local idle_diff=$(( idle2 - idle1 ))
  local total_diff=$(( total2 - total1 ))

  local cpu_precise
  if (( total_diff > 0 )); then
    cpu=$(( (total_diff - idle_diff) * 100 / total_diff ))
    cpu_precise=$(awk "BEGIN {printf \"%.2f\", ($total_diff - $idle_diff) * 100 / $total_diff}")
  else
    cpu=0
    cpu_precise="0.00"
  fi

  # Memory from /proc/meminfo
  local meminfo mem_used_gb mem_total_gb
  meminfo=$(</proc/meminfo)
  mem_total=$(echo "$meminfo" | awk '/^MemTotal:/ {print int($2 / 1024)}')
  local mem_available
  mem_available=$(echo "$meminfo" | awk '/^MemAvailable:/ {print int($2 / 1024)}')
  mem_used=$(( mem_total - mem_available ))
  local mem_precise
  if (( mem_total > 0 )); then
    mem_percent=$(( mem_used * 100 / mem_total ))
    mem_precise=$(awk "BEGIN {printf \"%.2f\", $mem_used * 100 / $mem_total}")
  else
    mem_percent=0
    mem_precise="0.00"
  fi
  mem_used_gb=$(awk "BEGIN {printf \"%.2f\", $mem_used / 1024}")
  mem_total_gb=$(awk "BEGIN {printf \"%.2f\", $mem_total / 1024}")

  # Temperature (keep raw millidegree for precision)
  temp=0
  local temp_raw=0
  for zone in /sys/class/thermal/thermal_zone*/temp; do
    if [[ -f "$zone" ]]; then
      local t
      t=$(cat "$zone" 2>/dev/null || echo 0)
      if (( t > temp_raw )); then
        temp_raw=$t
      fi
    fi
  done
  temp=$(( temp_raw / 1000 ))
  local temp_precise
  temp_precise=$(awk "BEGIN {printf \"%.2f\", $temp_raw / 1000}")

  if (( temp >= 80 )); then
    temp_icon="󰸁"
  elif (( temp >= 60 )); then
    temp_icon="󰔏"
  else
    temp_icon="󰸃"
  fi

  echo "{\"cpu\":$cpu,\"cpu_precise\":\"$cpu_precise\",\"memory\":{\"used_mb\":$mem_used,\"total_mb\":$mem_total,\"percent\":$mem_percent,\"percent_precise\":\"$mem_precise\",\"used_gb\":\"$mem_used_gb\",\"total_gb\":\"$mem_total_gb\"},\"temp\":$temp,\"temp_precise\":\"$temp_precise\",\"temp_icon\":\"$temp_icon\"}"

  # Send notifications on high resource usage (60s cooldown per alert type)
  local now cooldown=60
  now=$(date +%s)

  local lock_dir="/tmp/eww-res-alerts"
  mkdir -p "$lock_dir"

  if (( cpu >= 90 )); then
    local last_cpu="${lock_dir}/cpu_critical"
    if [[ ! -f "$last_cpu" ]] || (( now - $(cat "$last_cpu") >= cooldown )); then
      notify-send -u critical "CPU Critical" "CPU usage at ${cpu}%" -i dialog-warning
      echo "$now" > "$last_cpu"
    fi
  elif (( cpu >= 75 )); then
    local last_cpu="${lock_dir}/cpu_warning"
    if [[ ! -f "$last_cpu" ]] || (( now - $(cat "$last_cpu") >= cooldown )); then
      notify-send -u normal "CPU High" "CPU usage at ${cpu}%" -i dialog-warning
      echo "$now" > "$last_cpu"
    fi
  fi

  if (( mem_percent >= 90 )); then
    local last_mem="${lock_dir}/mem_critical"
    if [[ ! -f "$last_mem" ]] || (( now - $(cat "$last_mem") >= cooldown )); then
      notify-send -u critical "Memory Critical" "RAM usage at ${mem_percent}% (${mem_used_gb}/${mem_total_gb} GB)" -i dialog-warning
      echo "$now" > "$last_mem"
    fi
  elif (( mem_percent >= 75 )); then
    local last_mem="${lock_dir}/mem_warning"
    if [[ ! -f "$last_mem" ]] || (( now - $(cat "$last_mem") >= cooldown )); then
      notify-send -u normal "Memory High" "RAM usage at ${mem_percent}% (${mem_used_gb}/${mem_total_gb} GB)" -i dialog-warning
      echo "$now" > "$last_mem"
    fi
  fi
}

get_system
