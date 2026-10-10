#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════╗
# ║  Rename the agent you are on - prefix+shift+A        ║
# ║  Sets the visible row label verbatim and derives     ║
# ║  the CLI handle used by `herdr agent prompt <name>`. ║
# ╚══════════════════════════════════════════════════════╝
set -euo pipefail

die() {
  printf '\033[31m%s\033[0m\n' "$*" >&2
  read -rsn1 -p 'press any key to close…' _
  exit 1
}

# The popup is its own pane, so HERDR_PANE_ID may be the popup rather than the
# agent that launched it. agent list only contains agent panes, which lets us
# reject that case and fall back to whichever agent the UI has focused.
target=$(herdr agent list | HERDR_PANE_ID="${HERDR_PANE_ID:-}" python3 -c '
import json, os, sys

agents = json.load(sys.stdin)["result"]["agents"]
by_pane = {a["pane_id"]: a for a in agents}
caller = by_pane.get(os.environ.get("HERDR_PANE_ID", ""))
focused = next((a for a in agents if a.get("focused")), None)

a = caller or focused
if a:
    print("\t".join([a["pane_id"], a.get("name") or "", a.get("terminal_title_stripped") or a.get("cwd", "")]))
') || die "Could not read the agent list. If herdr was just updated, restart the server."

[[ -n "$target" ]] || die "Could not tell which agent you are on."

IFS=$'\t' read -r pane handle title <<<"$target"

# herdr rejects anything outside [a-z][a-z0-9_-]{0,31} for the CLI handle, so the
# typed label is slugified rather than refused. The label itself is stored as typed.
slugify() {
  python3 -c '
import re, sys
s = re.sub(r"[^a-z0-9]+", "-", sys.argv[1].lower()).strip("-")
s = re.sub(r"^[^a-z]+", "", s)[:32].rstrip("-")
print(s)
' "$1"
}

printf '\033[1mRenaming %s\033[0m  %s\n' "$pane" "$title"
printf 'CLI handle: %s\n\n' "${handle:--}"
printf '\033[2mspaces are fine, empty clears both names\033[0m\n'
read -rep 'New name ❯ ' -i "$handle" label

if [[ -z "$label" ]]; then
  herdr pane rename "$pane" --clear >/dev/null || die "Clearing the row label failed."
  herdr agent rename "$pane" --clear >/dev/null || die "Clearing the CLI handle failed."
  printf '\033[32mCleared both names on %s.\033[0m\n' "$pane"
else
  slug=$(slugify "$label")
  [[ -n "$slug" ]] || die "'$label' has no letters to build a CLI handle from."
  herdr pane rename "$pane" "$label" >/dev/null || die "Setting the row label failed."
  herdr agent rename "$pane" "$slug" >/dev/null || die "CLI handle '$slug' is already taken."
  printf '\033[32m%s\033[0m  \033[2mcli: %s\033[0m\n' "$label" "$slug"
fi
sleep 0.8
