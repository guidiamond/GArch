#!/usr/bin/env sh

export POLYBAR_FOLDER=$HOME/.config/polybar_ex
BAR_CFG=$HOME/.config/polybar_ex/config.ini
declare -a BAR_NAMES=("top" "bottom")

PRIMARY_MONITOR=$(polybar -m | grep 'primary' | cut -d ':' -f1)
OTHER_MONITORS=$(polybar -m | grep -v 'primary' | cut -d ':' -f1)

# Terminate already running bar instances
killall -q polybar
# Wait until the processes have been shut down
while pgrep -u $UID -x polybar >/dev/null; do sleep 1; done

for bar_name in "${BAR_NAMES[@]}"; do
  MONITOR=$PRIMARY_MONITOR polybar -c $BAR_CFG $bar_name &
done
sleep 1

for bar_name in "${BAR_NAMES[@]}"; do
  for other_monitor_name in $OTHER_MONITORS; do
    MONITOR=$other_monitor_name polybar -c $BAR_CFG $bar_name &
  done
done
