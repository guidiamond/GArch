#!/usr/bin/env bash

## Author  : Aditya Shakya
## Mail    : adi1090x@gmail.com
## Github  : @adi1090x
## Twitter : @adi1090x

style="$("$HOME/.config/rofi_working/applets/applets/style.sh")"
dir="$HOME/.config/rofi_working/applets/applets/configs/$style"
rofi_command="rofi -theme $dir/screenshot.rasi"

# Error msg
msg() {
	rofi -theme "$HOME/.config/rofi_working/applets/styles/message.rasi" -e "Please install 'scrot' first."
}

# Options
screen=""
area=""
copy_area="X"
window=""

# Screenshot directory
SCREENSHOT_DIR="$HOME/Pictures/screenshots"
mkdir -p "$SCREENSHOT_DIR"

# Variable passed to rofi
options="$copy_area"

copy_shot () {
	tee $1 | xclip -selection clipboard -t image/png
}

chosen="$(echo -e "$options" | $rofi_command -p 'scrot' -dmenu -selected-row 1)"
case $chosen in
    $screen)
		if command -v scrot &> /dev/null; then
			sleep 1
			scrot "$SCREENSHOT_DIR/Screenshot_%Y-%m-%d-%S_\$wx\$h.png" && \
      latest_screenshot="$(ls -t "$SCREENSHOT_DIR"/Screenshot_*.png | head -n1)"
      feh "$latest_screenshot" -R 0.01
		else
			msg
		fi
        ;;
    $area)
		if command -v scrot &> /dev/null; then
			scrot -s "$SCREENSHOT_DIR/Screenshot_%Y-%m-%d-%S_\$wx\$h.png" && \
      latest_screenshot="$(ls -t "$SCREENSHOT_DIR"/Screenshot_*.png | head -n1)"
      feh "$latest_screenshot" -R 0.01
		else
			msg
		fi
        ;;
    $copy_area)
		if command -v scrot &> /dev/null; then
			scrot -s "$SCREENSHOT_DIR/Screenshot_%Y-%m-%d-%S_\$wx\$h.png"
      latest_screenshot="$(ls -t "$SCREENSHOT_DIR"/Screenshot_*.png | head -n1)"
      cat "$latest_screenshot" | xclip -selection clipboard -t image/png
      # copy_shot "$latest_screenshot"
		else
			msg
		fi
        ;;
    $window)
		if command -v scrot &> /dev/null; then
			sleep 1
			scrot -u "$SCREENSHOT_DIR/Screenshot_%Y-%m-%d-%S_\$wx\$h.png" && \
			feh "$SCREENSHOT_DIR" --start-at "$(ls -t "$SCREENSHOT_DIR"/Screenshot_*.png | head -n1)"
		else
			msg
		fi
        ;;
esac
