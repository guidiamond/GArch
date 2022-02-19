#! /bin/sh

function genWorkspaces() {
	bspc monitor ${1} -d 1 2 3 4 5 6 7 8 9 10
}

MONITORS=$(xrandr --query | grep ' connected ')

PRIMARY=$(echo "${MONITORS}" | grep ' connected primary ' | awk '{ print$1 }')
OTHERS=$(echo "${MONITORS}" | grep -v ' connected primary ' | awk '{ print$1 }')


genWorkspaces ${PRIMARY}

for m in $OTHERS;do
	if [ "$m" != "HDMI-0" ];then
		genWorkspaces ${m}
	fi
done
