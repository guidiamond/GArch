#!/bin/sh
xinput set-prop 'Logitech Gaming Mouse G502' 'libinput Accel Speed' 1

USERNAME=$(echo $USER)
# xmonad
CONFIG_FOLDER="/home/${USERNAME}/.config"
xrandr --setprovideroutputsource modesetting NVIDIA-0
xrandr --auto

# Configure monitor
. "${CONFIG_FOLDER}/screenlayout/home-monitor.sh" &&

# Configure background
feh --bg-scale --randomize ~/Pictures/Backgrounds &&

# Start polybar
# "${CONFIG_FOLDER}/polybar_ex/launch.sh" &

# Configure picom
picom --config "${CONFIG_FOLDER}/picom/picom.conf" &
#xmobar -x 0 "${CONFIG_FOLDER}/xmobar/xmobarrc" &
#xmobar -x 1 "${CONFIG_FOLDER}/xmobar/xmobarrc" &

# Start applets
nm-applet &
