#!/bin/sh
# Autostart for the X session.
#
# Only startx/xinit read this file directly. LightDM logins reach it through
# ~/.xprofile, which sources it. Keep every command here idempotent: the file
# gets re-sourced by hand often enough that blind re-launches stack duplicates.
#xinput set-prop 'Logitech Gaming Mouse G502' 'libinput Accel Speed' 1

CONFIG_FOLDER="${XDG_CONFIG_HOME:-$HOME/.config}"

# Synchronous, and first: feh picks a wallpaper per monitor and bspwm assigns
# desktops per monitor, so both need the layout already settled.
"${CONFIG_FOLDER}/screenlayout/home-monitor.sh"

# Configure background
feh --bg-scale --randomize "$HOME/Pictures/Backgrounds" &

# Start polybar
# "${CONFIG_FOLDER}/polybar_ex/launch.sh" &

# Configure picom
pgrep -x picom >/dev/null || picom --config "${CONFIG_FOLDER}/picom/picom.conf" &
#xmobar -x 0 "${CONFIG_FOLDER}/xmobar/xmobarrc" &
#xmobar -x 1 "${CONFIG_FOLDER}/xmobar/xmobarrc" &


# Start Gestures
#touchegg &

# Start applets
pgrep -x nm-applet >/dev/null || nm-applet &

pgrep -x blueman-applet >/dev/null || blueman-applet &
