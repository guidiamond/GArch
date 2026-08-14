#!/usr/bin/env bash

# Rofi-based WiFi selector using nmcli

# Rescan networks
nmcli device wifi rescan 2>/dev/null

# Get list of available networks (SSID, signal, security)
networks=$(nmcli -t -f SSID,SIGNAL,SECURITY device wifi list 2>/dev/null | sort -t: -k2 -rn | awk -F: '
  !seen[$1]++ && $1 != "" {
    lock = ($3 != "" && $3 != "--") ? " 󰌾" : ""
    printf "%s  %s%%%s\n", $1, $2, lock
  }
')

if [[ -z "$networks" ]]; then
  notify-send "WiFi" "No networks found" -i network-wireless
  exit 0
fi

# Show in rofi
chosen=$(echo "$networks" | rofi -dmenu -i -p "󰤨  WiFi" -theme-str 'window {width: 400px;}')

if [[ -z "$chosen" ]]; then
  exit 0
fi

# Extract SSID (everything before the last "  " separator)
ssid=$(echo "$chosen" | sed 's/  [0-9]*%.*$//')

# Check if already connected
current_ssid=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes:' | cut -d: -f2-)

if [[ "$ssid" == "$current_ssid" ]]; then
  # Already connected — offer to disconnect
  action=$(echo -e "Disconnect\nCancel" | rofi -dmenu -p "Connected to $ssid")
  if [[ "$action" == "Disconnect" ]]; then
    nmcli device disconnect wifi 2>/dev/null
    notify-send "WiFi" "Disconnected from $ssid" -i network-wireless-disconnected
  fi
  exit 0
fi

# Check if we have a saved connection for this SSID
if nmcli connection show "$ssid" &>/dev/null; then
  nmcli connection up "$ssid" 2>/dev/null
  if [[ $? -eq 0 ]]; then
    notify-send "WiFi" "Connected to $ssid" -i network-wireless
  else
    notify-send "WiFi" "Failed to connect to $ssid" -i network-wireless-disconnected
  fi
else
  # Need password
  password=$(rofi -dmenu -p "󰌾  Password for $ssid" -password)
  if [[ -n "$password" ]]; then
    nmcli device wifi connect "$ssid" password "$password" 2>/dev/null
    if [[ $? -eq 0 ]]; then
      notify-send "WiFi" "Connected to $ssid" -i network-wireless
    else
      notify-send "WiFi" "Failed to connect to $ssid" -i network-wireless-disconnected
    fi
  fi
fi
