#!/usr/bin/env bash

count=0
wireless_disconnected="睊"
ethernet_disconnected=""
wireless_connected=""
ethernet_connected=""

SSID_NAME=$(iwgetid -r)
ID="$(ip link | awk '/state UP/ {print $2}')"

while true; do
    if (ping -c 1 archlinux.org || ping -c 1 google.com || ping -c 1 bitbucket.org || ping -c 1 github.com || ping -c 1 sourceforge.net) &>/dev/null; then
        if [[ $ID == e* ]]; then
            echo "$ethernet_connected" ;
        else
            echo "$wireless_connected" "${SSID_NAME}";
        fi
    else
        if [[ $ID == e* ]]; then
            echo "$ethernet_disconnected" ;
        else
            echo "$wireless_disconnected" ;
        fi
    fi
done

