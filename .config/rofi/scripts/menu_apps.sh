#!/usr/bin/env bash

## Author : Aditya Shakya (adi1090x)
## Mail : adi1090x@gmail.com
## browser : @adi1090x
## music : @adi1090x

rofi_command="rofi -theme themes/menu/apps.rasi"

# Links
terminal=""
files="ﱮ"
browser=""
screenshot=""
settings="漣"

# Variable passed to rofi
options="$terminal\n$files\n$browser\n$screenshot\n$settings"

chosen="$(echo -e "$options" | $rofi_command -p "Most Used" -dmenu -selected-row 0)"
case $chosen in
    $terminal)
        alacritty &
        ;;
    $files)
        pcmanfm &
        ;;
    $browser)
        google-chrome-stable &
        ;;
    $screenshot)
        /home/damndiamond/.config/rofi/scripts/menu_screenshot.sh &
        ;;
    $settings)
        /home/damndiamond/.config/rofi/scripts/menu_settings.sh &
        ;;
esac

