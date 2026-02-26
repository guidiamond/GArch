#!/usr/bin/env bash

# monitor_watcher.sh — Listens for bspwm monitor add/remove events
# and triggers the hotplug handler. Start from bspwmrc.
#
# This is a complement to the udev rule. bspwm fires these events when
# `remove_unplugged_monitors` is enabled and X detects output changes.

HOTPLUG="$HOME/.scripts/monitor/monitor_hotplug.sh"
LOGFILE="/tmp/monitor_hotplug.log"

log() { echo "[$(date '+%H:%M:%S')] watcher: $*" >> "$LOGFILE"; }

log "Monitor watcher started (PID $$)"

bspc subscribe monitor_add monitor_remove | while read -r event; do
    log "bspc event: $event"

    # Debounce: wait a bit for X/xrandr to settle
    sleep 1.5

    case "$event" in
        monitor_add*)
            log "Monitor added, running connect handler"
            "$HOTPLUG" connect 2>> "$LOGFILE"
            ;;
        monitor_remove*)
            log "Monitor removed, running disconnect handler"
            "$HOTPLUG" disconnect 2>> "$LOGFILE"
            ;;
    esac
done
