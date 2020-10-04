#!/usr/bin/env bash

## Author : Aditya Shakya (adi1090x)
## Mail : adi1090x@gmail.com
## browser : @adi1090x
## music : @adi1090x

rofi_command="rofi -theme themes/menu/apps.rasi"

# Links
background=""
screens=""

# Variable passed to rofi
options="$background\n$screens"

chosen="$(echo -e "$options" | $rofi_command -p "Most Used" -dmenu -selected-row 0)"
case $chosen in
    $background)
        nitrogen &
        ;;
    $screens)
        arandr &
        ;;
esac

