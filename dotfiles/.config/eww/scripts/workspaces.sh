#!/usr/bin/env bash

# Outputs JSON array of workspaces for a specific monitor on each bspc event.
# Usage: workspaces.sh <monitor_name>
# Desktop "10" is displayed as "0" via the "label" field.
#
# Format: [{"name":"1","label":"1","occupied":true,"focused":true,"urgent":false}, ...]
#
# Uses "bspc subscribe report" for streaming and awk for fast parsing.
# Zero subprocesses per event — awk parses the report line directly from the pipe.

MONITOR="${1:?Usage: workspaces.sh <monitor_name>}"
RELAY="$(dirname "$(readlink -f "$0")")/eww_relay.py"

AWK_PARSER='
{
  in_mon = 0; printf "["; sep = ""
  for (i = 1; i <= NF; i++) {
    t = substr($i, 1, 1); n = substr($i, 2)
    if (t == "W") { in_mon = (substr(n, 2) == mon) }
    else if (t == "M" || t == "m") { in_mon = (n == mon) }
    else if (t == "L" || t == "T" || t == "G") { in_mon = 0 }
    else if (in_mon && index("oOfFuU", t)) {
      f = "false"; o = "false"; u = "false"
      if (t == "O") { f = "true"; o = "true" }
      else if (t == "o") { o = "true" }
      else if (t == "F") { f = "true" }
      else if (t == "U") { f = "true"; u = "true" }
      else if (t == "u") { u = "true" }
      lbl = n; if (n == "10") lbl = "0"
      printf "%s{\"name\":\"%s\",\"label\":\"%s\",\"occupied\":%s,\"focused\":%s,\"urgent\":%s}", sep, n, lbl, o, f, u
      sep = ","
    }
  }
  print "]"
  fflush()
}'

emit_stream() {
  # Initial output
  timeout 2 bspc wm -g | awk -F: -v mon="$MONITOR" "$AWK_PARSER"

  # Stream updates — awk parses each report line with no subprocess overhead
  bspc subscribe report 2>/dev/null | awk -F: -v mon="$MONITOR" "$AWK_PARSER"
}

# All output goes through the relay, which never blocks on eww's pipe.
# Writing to eww directly is what froze the WM: eww stalls -> awk blocks in
# write() -> it stops draining `bspc subscribe` -> bspwm's blocking event
# write fills up -> bspwm's single-threaded loop stops reading X input and
# answering queries (dead mouse, dead keybinds). See eww_relay.py.
emit_stream | exec python3 "$RELAY"
