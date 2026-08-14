#!/usr/bin/env bash

# Toggle calendar popup on the focused monitor, positioned under the clock

visible=$(eww get calendar-visible 2>/dev/null)
monitor=$(bspc query -M -m focused --names 2>/dev/null)

if [ "$visible" = "true" ]; then
  eww update calendar-visible=false
  eww close calendar-popup 2>/dev/null
else
  eww update calendar-visible=true
  eww open calendar-popup --screen "$monitor" 2>/dev/null
fi
