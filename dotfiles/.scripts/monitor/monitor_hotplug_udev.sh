#!/usr/bin/env bash

# Wrapper called by udev (runs as root).
# Finds the logged-in user's X session and runs the hotplug script as them.

HOTPLUG_SCRIPT="/home/guidiamond/.scripts/monitor/monitor_hotplug.sh"
TARGET_USER="guidiamond"
LOG="/tmp/monitor_hotplug_udev.log"

echo "[$(date '+%H:%M:%S')] udev event triggered" >> "$LOG"

# Find the user's display
DISPLAY=":0"
XAUTHORITY="/home/${TARGET_USER}/.Xauthority"
DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$TARGET_USER")/bus"

export DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS

# Run as the target user
su - "$TARGET_USER" -c "DISPLAY=$DISPLAY XAUTHORITY=$XAUTHORITY DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS $HOTPLUG_SCRIPT auto" >> "$LOG" 2>&1 &

exit 0
