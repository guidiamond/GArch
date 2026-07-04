#!/usr/bin/env bash
# dodo-dashboard.sh — create-or-toggle the persistent 'dodo' sidebar session.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/dodo-lib.sh"

SESSION="dodo"

# Ensure the GH daemon loop is running (single instance via its own flock; the
# loop performs its first poll immediately on start). Fully detached so it never
# blocks this keybind.
setsid "$HERE/dodo-gh-daemon.sh" >/dev/null 2>&1 < /dev/null &

if tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux switch-client -t "$SESSION"
  exit 0
fi

# Create the dashboard: one window running the sidebar UI.
tmux new-session -d -s "$SESSION" -c "$DODO_DIR" -n agents
tmux send-keys -t "$SESSION:agents" "exec $HERE/dodo-sidebar.sh" C-m
tmux switch-client -t "$SESSION"
