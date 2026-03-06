#!/usr/bin/env bash

# Outputs JSON with WiFi connection info
# Format: {"connected":true,"ssid":"MyNet","signal":72,"ip":"192.168.1.100","icon":"󰤨"}

get_wifi() {
  local connected=false ssid="" signal=0 ip="" icon="󰤭"

  # Get active WiFi connection
  ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2-)

  if [[ -n "$ssid" ]]; then
    connected=true
    signal=$(nmcli -t -f active,signal dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2)
    signal=${signal:-0}
    ip=$(nmcli -t -f IP4.ADDRESS dev show 2>/dev/null | head -1 | cut -d: -f2 | cut -d/ -f1)
    ip=${ip:-"N/A"}

    if (( signal >= 75 )); then
      icon="󰤨"
    elif (( signal >= 50 )); then
      icon="󰤥"
    elif (( signal >= 25 )); then
      icon="󰤢"
    else
      icon="󰤟"
    fi
  else
    # Check if ethernet is connected
    if nmcli -t -f TYPE,STATE dev 2>/dev/null | grep -q "ethernet:connected"; then
      connected=true
      ssid="Ethernet"
      signal=100
      ip=$(nmcli -t -f IP4.ADDRESS dev show 2>/dev/null | head -1 | cut -d: -f2 | cut -d/ -f1)
      ip=${ip:-"N/A"}
      icon="󰈁"
    fi
  fi

  # Escape ssid for JSON
  ssid=$(echo "$ssid" | sed 's/"/\\"/g')

  echo "{\"connected\":$connected,\"ssid\":\"$ssid\",\"signal\":$signal,\"ip\":\"$ip\",\"icon\":\"$icon\"}"
}

get_wifi
