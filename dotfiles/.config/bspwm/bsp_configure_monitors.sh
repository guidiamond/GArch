#! /bin/sh

function genWorkspaces() {
	bspc monitor ${1} -d 1 2 3 4 5 6 7 8 9 10
}

MONITORS=($(xrandr --listactivemonitors | awk '{print $4}'))

for m in "${MONITORS[@]}"; do
  genWorkspaces ${m}
done
