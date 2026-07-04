#!/usr/bin/env bash
# dodo-dashboard.sh — prefix+a launcher.
# The sidebar lives embedded in each agent's claude window (added by
# _create_session). This launcher is how you summon the list from ANYWHERE
# (including editor/server windows that have no embedded sidebar) to jump to or
# create an agent. It also makes sure the GitHub status daemon is running.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# Ensure the GH daemon loop is running (single instance via its own flock; the
# loop polls immediately on start). Fully detached so it never blocks the keybind.
setsid "$HERE/dodo-gh-daemon.sh" >/dev/null 2>&1 < /dev/null &

# Open the sidebar as a centered popup launcher.
tmux display-popup -E -w 75% -h 75% "exec $HERE/dodo-sidebar.sh --popup"
