#!/bin/sh
scrot --overwrite /tmp/screen.png

set -e
xset s off dpms 0 10 0
convert /tmp/screen.png -paint 3 /tmp/screen.png
[[ -f ~/.config/i3/lock.png ]] && convert /tmp/screen.png ~/.config/i3/lock.png -gravity center -composite -matte /tmp/screen.png
i3lock -e -f -i /tmp/screen.png --nofork
xset s off -dpms
