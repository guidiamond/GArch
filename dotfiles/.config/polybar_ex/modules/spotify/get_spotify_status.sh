#!/bin/bash

if [ "$(playerctl --player=playerctld status 2>/dev/null)" = "Paused"  ]; then
    polybar-msg -p "$(pgrep -f "polybar now-playing")" hook spotify-play-pause 2 1>/dev/null 2>&1
    playerctl --player=spotify metadata --format "{{ title }} - {{ artist }}"
elif [ "$(playerctl --player=playerctld status 2>/dev/null)" = "Playing"  ]; then
    polybar-msg -p "$(pgrep -f "polybar now-playing")" hook spotify-play-pause 1 1>/dev/null 2>&1
    playerctl --player=spotify metadata --format "{{ title }} - {{ artist }}"
else # Can be configured to output differently when player is paused
    echo ""
fi
