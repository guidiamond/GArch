#!/bin/sh
# Output names come from the proprietary nvidia driver (DP-0/HDMI-0). This file
# used to name eDP-1/HDMI-1 from the old laptop on modesetting, so every --output
# missed and xrandr configured nothing.
xrandr \
  --output DP-0   --primary --mode 1920x1080 --pos 0x0    --rotate normal \
  --output HDMI-0           --mode 2560x1080 --pos 1920x0 --rotate normal \
  --output DP-1 --off \
  --output DP-2 --off \
  --output DP-3 --off \
  --output DP-4 --off \
  --output DP-5 --off \
  --output HDMI-1 --off
